import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, statSync } from "node:fs";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { BotEnvironment, containerName } from "../src/environment/container.ts";
import { DockerEngineAPI } from "../src/environment/engine-api.ts";
import type { RemoteExecutionEnv } from "../src/environment/remote.ts";
import { HostClient } from "../src/host/client.ts";
import { CONTAINER_GIT_DIRECTORY, CONTAINER_GIT_TMPFS, type GitSetup, gitEnvironment, gitFiles, HostGitSource, NO_GIT, validGitSetup, WRITE_GIT_FILES } from "../src/host/git.ts";
import { FakeEngine } from "./fake-engine.ts";

// Split so the public-tree secret scan matches only real keys.
const KEY = "-----BEGIN OPENSSH " + "PRIVATE KEY-----\nfixture\n-----END OPENSSH " + "PRIVATE KEY-----\n";
const SETUP: GitSetup = { sshKey: { privateKey: KEY, publicKey: "ssh-ed25519 AAAA woven-matter" }, identity: { name: "Ada", email: "ada@example.com" } };
const BOT = "0b0b0b0b-0000-4000-8000-000000000001";

describe("Settings → GitHub for bots", () => {
  it("writes the same files as the Linux host", async () => {
    // The Linux host's module, from the same checkout.
    const path = new URL("../../remote/src/github-identity.mjs", import.meta.url).href;
    const remote = (await import(path)) as { githubFiles: (setup: GitSetup, directory: string) => Record<string, string | null> };
    for (const setup of [SETUP, NO_GIT, { sshKey: null, identity: { name: "Ada", email: "" } }]) {
      expect(gitFiles(setup, "/home/bot/.woven/github")).toEqual(remote.githubFiles(setup, "/home/bot/.woven/github"));
    }
  });

  it("accepts only well-formed replies from the host", () => {
    expect(validGitSetup(undefined)).toEqual(NO_GIT);
    expect(validGitSetup({ sshKey: { privateKey: "nope", publicKey: "x" }, identity: { name: "A\nB", email: "" } })).toEqual(NO_GIT);
    expect(validGitSetup(SETUP)).toEqual(SETUP);
  });

  it("asks the host for the setup through its own route", async () => {
    const fetcher = vi.fn(async (url: string | URL | Request, init?: RequestInit) => {
      expect(String(url)).toBe("http://127.0.0.1:1/v1/bots-host/git");
      expect(init?.method).toBe("POST");
      return new Response(JSON.stringify(SETUP), { status: 200 });
    });
    expect(await new HostClient("http://127.0.0.1:1", "token", fetcher as typeof fetch).gitSetup()).toEqual(SETUP);
  });

  it("keeps the last answer when the host is briefly unreachable", async () => {
    let fail = false;
    const source = new HostGitSource(async () => {
      if (fail) throw new Error("down");
      return SETUP;
    }, 0);
    expect(await source.current()).toEqual(SETUP);
    fail = true;
    expect(await source.current()).toEqual(SETUP);
    // With no answer yet there is nothing to write, and a failure is not retried at once.
    let calls = 0;
    const never = new HostGitSource(async () => {
      calls += 1;
      throw new Error("down");
    }, 60_000);
    expect(await never.current()).toBeUndefined();
    expect(await never.current()).toBeUndefined();
    expect(calls).toBe(1);
  });

  it("writes private files and removes the key when it is removed", async () => {
    const directory = join(await mkdtemp(join(tmpdir(), "woven-bot-git-")), "github");
    try {
      const write = (setup: GitSetup) =>
        spawnSync(WRITE_GIT_FILES[0], WRITE_GIT_FILES.slice(1), { input: JSON.stringify({ directory, files: gitFiles(setup, directory) }) });
      expect(write(SETUP).status).toBe(0);
      expect(readFileSync(join(directory, "id_github"), "utf8")).toBe(KEY);
      expect(statSync(join(directory, "id_github")).mode & 0o777).toBe(0o600);
      expect(statSync(directory).mode & 0o777).toBe(0o700);
      expect(write(NO_GIT).status).toBe(0);
      expect(existsSync(join(directory, "id_github"))).toBe(false);
      expect(existsSync(join(directory, "gitconfig"))).toBe(false);
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
  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "woven-bot-git-engine-"));
    engine = new FakeEngine(dir);
    await engine.start();
    setup = SETUP;
    env = new BotEnvironment({
      engine: new DockerEngineAPI(engine.socketPath),
      kind: "linux-dockerd",
      imageName: "woven-bots-test",
      memoryBytes: null,
      machineId: "machine-1",
      sweepMs: 60_000,
      git: async () => setup,
      gitDirectory: join(dir, "home-github"),
    });
  });
  afterEach(async () => {
    env.close();
    await engine.close();
    await rm(dir, { recursive: true, force: true });
  });

  it("keeps the files on a private tmpfs in real containers", async () => {
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
      const host = engine.containers.get(containerName(BOT))?.spec.HostConfig as Record<string, unknown>;
      expect(host.Tmpfs).toEqual({ [CONTAINER_GIT_DIRECTORY]: CONTAINER_GIT_TMPFS });
    } finally {
      real.close();
    }
  });

  it("writes the files before the agent starts, gives it the environment, and follows changes", async () => {
    const tools = env.harnessEnv(BOT)({ cwd: "/workspace" } as never, BACKGROUND_CONTEXT as never) as RemoteExecutionEnv;
    await tools.writeFile("hello.txt", "hi", BACKGROUND_CONTEXT);
    const github = join(dir, "home-github");
    expect(readFileSync(join(github, "id_github"), "utf8")).toBe(KEY);
    const agent = [...engine.execs.values()].find((exec) => exec.cmd.includes("/opt/woven-bot/agent.mjs"));
    expect(agent?.container).toBe(containerName(BOT));
    expect(agent?.env).toEqual(Object.entries(gitEnvironment(github)).map(([key, value]) => `${key}=${value}`));
    const writers = [...engine.execs.values()].filter((exec) => exec.cmd[1] === "-e");
    expect(writers.every((exec) => exec.user === "bot")).toBe(true);

    // A removal in Settings reaches the container before its next command.
    setup = NO_GIT;
    await tools.exec("true", {}, BACKGROUND_CONTEXT);
    expect(existsSync(join(github, "id_github"))).toBe(false);
  });
});
