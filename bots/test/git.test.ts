import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, rmSync, statSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { BotEnvironment, containerName } from "../src/environment/container.ts";
import { DockerEngineAPI } from "../src/environment/engine-api.ts";
import type { RemoteExecutionEnv } from "../src/environment/remote.ts";
import { HostClient } from "../src/host/client.ts";
import {
  CONTAINER_GIT_DIRECTORY,
  type GitSetup,
  gitAgentSocket,
  gitEnvironment,
  gitFiles,
  HostGitSource,
  NO_GIT,
  validGitSetup,
  WRITE_GIT_FILES,
} from "../src/host/git.ts";
import { FakeEngine } from "./fake-engine.ts";

const PUBLIC_KEY = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFixture woven-matter";
const SETUP: GitSetup = { publicKey: PUBLIC_KEY, identity: { name: "Ada", email: "ada@example.com" } };
const BOT = "0b0b0b0b-0000-4000-8000-000000000001";

type Agent = {
  agentReply: (message: Buffer, key: unknown) => Buffer;
  parseOpenSSHPrivateKey: (text: string) => unknown;
};
// The Linux host's signing agent, from the same checkout, stands in for the machine.
const linuxAgent = () => import(new URL("../../remote/src/ssh-agent.mjs", import.meta.url).href) as Promise<Agent>;

function run(command: string, args: string[], env: NodeJS.ProcessEnv): Promise<{ status: number | null; stdout: string }> {
  return new Promise((resolve) => {
    const child = spawn(command, args, { env });
    let stdout = "";
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
    });
    child.on("close", (status) => resolve({ status, stdout }));
    child.stdin.end();
  });
}

describe("Settings → GitHub for bots", () => {
  it("writes the same files as the Linux host", async () => {
    // The Linux host's module, from the same checkout.
    const path = new URL("../../remote/src/github-identity.mjs", import.meta.url).href;
    const remote = (await import(path)) as { githubFiles: (setup: GitSetup, directory: string) => Record<string, string | null> };
    for (const setup of [SETUP, NO_GIT, { publicKey: null, identity: { name: "Ada", email: "" } }]) {
      expect(gitFiles(setup, "/home/bot/.woven/github")).toEqual(remote.githubFiles(setup, "/home/bot/.woven/github"));
    }
  });

  it("never writes a private key, and names the relay as github.com's agent", () => {
    const files = gitFiles(SETUP);
    expect(files.id_github).toBeNull();
    expect(files["id_github.pub"]).toBe(`${PUBLIC_KEY}\n`);
    expect(files["github.conf"]).toContain(`IdentityAgent "${gitAgentSocket()}"`);
    expect(gitAgentSocket()).toBe(`${CONTAINER_GIT_DIRECTORY}/agent.sock`);
  });

  it("accepts only well-formed replies from the host", () => {
    expect(validGitSetup(undefined)).toEqual(NO_GIT);
    expect(validGitSetup({ publicKey: "ssh-ed25519 AAAA\nInclude /etc/passwd", identity: { name: "A\nB", email: "" } })).toEqual(NO_GIT);
    expect(validGitSetup(SETUP)).toEqual(SETUP);
  });

  it("asks the host for the setup and for signatures through its own routes", async () => {
    const fetcher = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      expect(init?.method).toBe("POST");
      const body = JSON.parse(String(init?.body)) as { botID: string; message?: string };
      expect(body.botID).toBe(BOT);
      if (String(url) === "http://127.0.0.1:1/v1/bots-host/git") return new Response(JSON.stringify(SETUP), { status: 200 });
      expect(String(url)).toBe("http://127.0.0.1:1/v1/bots-host/ssh-agent");
      expect(body.message).toBe(Buffer.from([11]).toString("base64"));
      return new Response(JSON.stringify({ message: Buffer.from([12, 0, 0, 0, 0]).toString("base64") }), { status: 200 });
    });
    const client = new HostClient("http://127.0.0.1:1", "token", fetcher as typeof fetch);
    expect(await client.gitSetup(BOT)).toEqual(SETUP);
    expect(await client.sshAgent(BOT, Buffer.from([11]))).toEqual(Buffer.from([12, 0, 0, 0, 0]));
  });

  it("keeps each bot's last answer when the host is briefly unreachable", async () => {
    let fail = false;
    const asked: string[] = [];
    const source = new HostGitSource(async (botId) => {
      asked.push(botId);
      if (fail) throw new Error("down");
      return botId === BOT ? SETUP : NO_GIT;
    }, 0);
    expect(await source.current(BOT)).toEqual(SETUP);
    expect(await source.current("other")).toEqual(NO_GIT);
    fail = true;
    expect(await source.current(BOT)).toEqual(SETUP);
    expect(asked).toEqual([BOT, "other", BOT]);
    // With no answer yet there is nothing to write, and a failure is not retried at once.
    let calls = 0;
    const never = new HostGitSource(async () => {
      calls += 1;
      throw new Error("down");
    }, 60_000);
    expect(await never.current(BOT)).toBeUndefined();
    expect(await never.current(BOT)).toBeUndefined();
    expect(calls).toBe(1);
  });

  it("runs ssh as usual until the files are there, then asks the agent", async () => {
    const directory = await mkdtemp(join(tmpdir(), "woven-bot-ssh-"));
    try {
      // git runs a command with shell syntax as `sh -c '<command> "$@"' <command> <arguments>`.
      const command = gitEnvironment(directory).GIT_SSH_COMMAND ?? "";
      const ssh = () => spawnSync("sh", ["-c", `${command} "$@"`, command, "-G", "github.com"], { encoding: "utf8" });
      const plain = ssh();
      if (plain.status !== 0) return; // No ssh client here.
      expect(plain.stdout).not.toContain("agent.sock");
      const write = spawnSync(WRITE_GIT_FILES[0], WRITE_GIT_FILES.slice(1), { input: JSON.stringify({ directory, files: gitFiles(SETUP, directory) }) });
      expect(write.status).toBe(0);
      expect(ssh().stdout).toContain(`identityagent ${join(directory, "agent.sock")}`);
    } finally {
      await rm(directory, { recursive: true, force: true });
    }
  });

  it("writes private files and removes the public key when the bot is turned off", async () => {
    const directory = join(await mkdtemp(join(tmpdir(), "woven-bot-git-")), "github");
    try {
      const write = (setup: GitSetup) =>
        spawnSync(WRITE_GIT_FILES[0], WRITE_GIT_FILES.slice(1), { input: JSON.stringify({ directory, files: gitFiles(setup, directory) }) });
      expect(write(SETUP).status).toBe(0);
      expect(readFileSync(join(directory, "id_github.pub"), "utf8")).toBe(`${PUBLIC_KEY}\n`);
      expect(statSync(join(directory, "github.conf")).mode & 0o777).toBe(0o600);
      expect(statSync(directory).mode & 0o777).toBe(0o700);
      expect(existsSync(join(directory, "id_github"))).toBe(false);
      expect(write(NO_GIT).status).toBe(0);
      expect(existsSync(join(directory, "id_github.pub"))).toBe(false);
      expect(existsSync(join(directory, "github.conf"))).toBe(false);
      expect(existsSync(join(directory, "ssh_config"))).toBe(true);
    } finally {
      await rm(join(directory, ".."), { recursive: true, force: true });
    }
  });
});

describe("Settings → GitHub in bot containers", () => {
  let dir: string;
  let engine: FakeEngine;
  let env: BotEnvironment;
  let setup: GitSetup;
  let answer: (botId: string, message: Buffer) => Promise<Buffer>;
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "woven-bot-git-engine-"));
    engine = new FakeEngine(dir);
    await engine.start();
    setup = SETUP;
    answer = async () => Buffer.from([5]);
    env = new BotEnvironment({
      engine: new DockerEngineAPI(engine.socketPath),
      kind: "linux-dockerd",
      imageName: "woven-bots-test",
      memoryBytes: null,
      machineId: "machine-1",
      sweepMs: 60_000,
      git: async (botId) => (botId === BOT ? setup : NO_GIT),
      gitDirectory: join(dir, "gh"),
      sshAgent: (botId, message) => answer(botId, message),
    });
  });
  afterEach(async () => {
    env.close();
    await engine.close();
    await rm(dir, { recursive: true, force: true });
  });

  it("keeps the files in the container's memory and gives every process the environment", async () => {
    const real = new BotEnvironment({
      engine: new DockerEngineAPI(engine.socketPath),
      kind: "linux-dockerd",
      imageName: "woven-bots-test",
      memoryBytes: null,
      machineId: "machine-1",
      sweepMs: 60_000,
      git: async () => setup,
    });
    try {
      await real.ensure(BOT);
      const spec = engine.containers.get(containerName(BOT))?.spec as { Env: string[] };
      expect(CONTAINER_GIT_DIRECTORY.startsWith("/dev/shm/")).toBe(true);
      // keep_running services start from the container's own environment.
      expect(spec.Env).toEqual(expect.arrayContaining(Object.entries(gitEnvironment()).map(([key, value]) => `${key}=${value}`)));
    } finally {
      real.close();
    }
  });

  it("writes the files before the agent starts, gives it the environment, and follows changes", async () => {
    const tools = env.harnessEnv(BOT)({ cwd: "/workspace" } as never, BACKGROUND_CONTEXT as never) as RemoteExecutionEnv;
    await tools.writeFile("hello.txt", "hi", BACKGROUND_CONTEXT);
    const github = join(dir, "gh");
    expect(readFileSync(join(github, "id_github.pub"), "utf8")).toBe(`${PUBLIC_KEY}\n`);
    const agent = [...engine.execs.values()].find((exec) => exec.cmd.includes("/opt/woven-bot/agent.mjs"));
    expect(agent?.container).toBe(containerName(BOT));
    expect(agent?.env).toEqual(Object.entries(gitEnvironment(github)).map(([key, value]) => `${key}=${value}`));
    const writers = [...engine.execs.values()].filter((exec) => exec.cmd[1] === "-e");
    expect(writers.every((exec) => exec.user === "bot")).toBe(true);

    // Turned off in Settings: the files lose the key before the bot's next command.
    setup = { publicKey: null, identity: SETUP.identity };
    await tools.exec("true", {}, BACKGROUND_CONTEXT);
    expect(existsSync(join(github, "id_github.pub"))).toBe(false);
  });

  it("keeps the user's own SSH and HTTPS settings in a container whose relay cannot listen", async () => {
    // A directory where the relay's socket goes: it starts, cannot listen, and exits (as an older
    // helper without the relay would fail to start).
    const deep = join(dir, "broken");
    mkdirSync(join(gitAgentSocket(deep), "taken"), { recursive: true });
    const broken = new BotEnvironment({
      engine: new DockerEngineAPI(engine.socketPath),
      kind: "linux-dockerd",
      imageName: "woven-bots-test",
      memoryBytes: null,
      machineId: "machine-1",
      sweepMs: 60_000,
      git: async () => setup,
      gitDirectory: deep,
      sshAgent: async () => Buffer.from([5]),
    });
    try {
      const tools = broken.harnessEnv(BOT)({ cwd: "/workspace" } as never, BACKGROUND_CONTEXT as never) as RemoteExecutionEnv;
      await tools.writeFile("hello.txt", "hi", BACKGROUND_CONTEXT);
      expect(existsSync(join(deep, "github.conf"))).toBe(false);
      expect(readFileSync(join(deep, "gitconfig"), "utf8")).toBe('[user]\n\tname = "Ada"\n\temail = "ada@example.com"\n');
    } finally {
      broken.close();
    }
  });

  it("signs through the relay in the container, and stops the moment the bot is turned off", async () => {
    const key = join(dir, "key");
    if (spawnSync("ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-C", "woven-matter", "-f", key]).status !== 0) return;
    const { agentReply, parseOpenSSHPrivateKey } = await linuxAgent();
    const parsed = parseOpenSSHPrivateKey(readFileSync(key, "utf8"));
    rmSync(key);
    let on = true;
    answer = async (botId, message) => agentReply(message, on && botId === BOT ? parsed : null);
    const tools = env.harnessEnv(BOT)({ cwd: "/workspace" } as never, BACKGROUND_CONTEXT as never) as RemoteExecutionEnv;
    await tools.writeFile("hello.txt", "hi", BACKGROUND_CONTEXT);
    const relay = [...engine.execs.values()].find((exec) => exec.cmd.includes("/opt/woven-bot/ssh-agent.mjs"));
    expect(relay?.user).toBe("bot");

    const socket = gitAgentSocket(join(dir, "gh"));
    const sshEnv = { ...process.env, SSH_AUTH_SOCK: socket };
    let listed = { status: null as number | null, stdout: "" };
    for (let attempt = 0; attempt < 50 && !listed.stdout.trim(); attempt++) {
      listed = await run("ssh-add", ["-L"], sshEnv);
      if (!listed.stdout.trim()) await new Promise((resolve) => setTimeout(resolve, 100));
    }
    const publicKey = readFileSync(`${key}.pub`, "utf8").trim();
    expect(listed.stdout.trim()).toBe(publicKey);
    on = false;
    const off = await run("ssh-add", ["-L"], sshEnv);
    expect(off.status).not.toBe(0);
    expect(off.stdout).not.toContain(publicKey.split(" ")[1]);
    expect(existsSync(join(dir, "gh", "id_github"))).toBe(false);
  });
});
