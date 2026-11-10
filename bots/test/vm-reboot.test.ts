import { type ChildProcess, execFile, spawn } from "node:child_process";
import { lstat, mkdir, readFile, readlink, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { BotEnvironment, containerName, volumeName } from "../src/environment/container.ts";
import { DockerEngineAPI } from "../src/environment/engine-api.ts";
import type { RemoteExecutionEnv } from "../src/environment/remote.ts";
import type { ServerMessage } from "../src/protocol.ts";
import { FakeEngine } from "./fake-engine.ts";
import { echoModels, socketDirectory, tempDir } from "./helpers.ts";
import { openClient, startTestRuntime } from "./runtime.ts";

// A Mac VM update or reboot kills every bot container at once, without SIGTERM grace, and the
// engine socket answers 503 until the VM is back. Containers have restart policy `no`. These
// tests check that each bot's restart list and browser tabs come back anyway.

const HELPER = fileURLToPath(new URL("../helper/", import.meta.url));
const FAKE_PLAYWRIGHT = fileURLToPath(new URL("./fake-playwright.cjs", import.meta.url));
const LOCKS = ["SingletonLock", "SingletonSocket", "SingletonCookie"];
const ctx = BACKGROUND_CONTEXT;
const run = promisify(execFile);
const BOT = "0b0b0b0b-0000-4000-8000-0000000000aa";

function must<T>(result: { ok: true; value: T } | { ok: false; error: Error }): T {
  if (!result.ok) throw result.error;
  return result.value;
}

const sleep = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

async function savedTabs(browserState: string): Promise<string[] | undefined> {
  try {
    return JSON.parse(await readFile(join(browserState, "tabs.json"), "utf8")).tabs;
  } catch {
    return undefined;
  }
}

async function lockPresent(profile: string): Promise<boolean[]> {
  return Promise.all(LOCKS.map((name) => lstat(join(profile, name)).then(() => true, () => false)));
}

/** The pid that holds the profile lock ("<hostname>-<pid>", as Chromium writes it). */
async function lockHolder(profile: string): Promise<number> {
  return Number((await readlink(join(profile, "SingletonLock"))).split("-").at(-1));
}

describe("supervisor and browser after a kill without grace", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let sockets: string;
  let socket: string;
  let state: string;
  let supervisor: ChildProcess | undefined;
  const profile = () => join(state, "browser", "profile");
  const start = () => {
    supervisor = spawn(process.execPath, [join(HELPER, "supervisor.mjs")], {
      env: {
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        WOVEN_STATE_DIR: state,
        WOVEN_CONTROL_SOCKET: socket,
        WOVEN_PLAYWRIGHT_MODULE: FAKE_PLAYWRIGHT,
      },
      stdio: ["ignore", "ignore", "pipe"],
      cwd: dir.path,
    });
  };
  const control = async <T>(method: string, args: Record<string, unknown> = {}): Promise<T> => {
    const { stdout } = await run(process.execPath, [join(HELPER, "ctl.mjs"), method, JSON.stringify(args)], {
      env: { PATH: process.env.PATH ?? "", WOVEN_CONTROL_SOCKET: socket },
    });
    return JSON.parse(stdout) as T;
  };
  const tabURLs = async () => (await control<{ url: string }[]>("browser.tabs")).map((tab) => tab.url);
  const servicePid = async () =>
    (await control<{ name: string; pid?: number }[]>("services.list")).find((s) => s.name === "web")?.pid;
  /** Everything in the "container" dies at once: supervisor, browser and services. */
  const powerCut = async (pids: number[]) => {
    for (const pid of [supervisor?.pid, ...pids]) {
      if (pid) process.kill(pid, "SIGKILL");
    }
    supervisor = undefined;
    await sleep(100);
  };

  beforeEach(async () => {
    dir = await tempDir();
    sockets = socketDirectory(dir.path);
    socket = join(sockets, "c.sock");
    state = join(dir.path, "state");
  });
  afterEach(async () => {
    const child = supervisor;
    supervisor = undefined;
    if (child && child.exitCode === null) {
      await new Promise<void>((resolve) => {
        child.once("exit", () => resolve());
        child.kill("SIGTERM");
      });
    }
    await dir.cleanup();
    if (sockets !== dir.path) await rm(sockets, { recursive: true, force: true });
  });

  it("saves tabs on every change, clears the stale profile lock, and reopens the tabs and the restart list", async () => {
    start();
    await control("services.add", { name: "web", command: "exec sleep 30", cwd: dir.path });
    await control("browser.navigate", { url: "https://example.test/a" });
    await control("browser.new_tab", { url: "https://example.test/b" });
    // Saved without any shutdown: a power cut right now keeps both.
    await expect
      .poll(() => savedTabs(join(state, "browser")), { timeout: 5000 })
      .toEqual(["https://example.test/a", "https://example.test/b"]);
    const service = await servicePid();
    const browser = await lockHolder(profile());
    expect(service).toBeGreaterThan(0);

    await powerCut([browser, service as number]);
    // Chromium had no chance to remove its lock, and the restart list is still on disk.
    expect(await lockPresent(profile())).toEqual([true, true, true]);
    expect(JSON.parse(await readFile(join(state, "services.json"), "utf8"))).toEqual([
      { name: "web", command: "exec sleep 30", cwd: dir.path },
    ]);

    // The container starts again: the restart list and the browser come back by themselves.
    start();
    await expect.poll(servicePid, { timeout: 10_000, interval: 200 }).toBeGreaterThan(0);
    expect(await servicePid()).not.toBe(service);
    await expect
      .poll(async () => (await control<{ browser: boolean }>("ping")).browser, { timeout: 10_000, interval: 100 })
      .toBe(true);
    await expect.poll(tabURLs, { timeout: 10_000, interval: 200 }).toEqual([
      "https://example.test/a",
      "https://example.test/b",
    ]);
    // The browser that reopened them is a new process holding a fresh lock.
    expect(await lockHolder(profile())).not.toBe(browser);
  });

  it("keeps tabs that fail to reopen, and keeps the list when Chromium dies", async () => {
    await mkdir(join(state, "browser", "profile"), { recursive: true });
    await writeFile(
      join(state, "browser", "tabs.json"),
      JSON.stringify({ tabs: ["https://unreachable.test/x", "https://example.test/c"] }),
    );
    start();
    // The site is still unreachable after the reboot: the tab shows an error but stays listed.
    await expect.poll(tabURLs, { timeout: 10_000, interval: 200 }).toEqual([
      "chrome-error://chromewebdata/",
      "https://example.test/c",
    ]);
    const opened = await control<{ tab: number }>("browser.new_tab", { url: "https://example.test/d" });
    const expected = ["https://unreachable.test/x", "https://example.test/c", "https://example.test/d"];
    await expect.poll(() => savedTabs(join(state, "browser")), { timeout: 5000 }).toEqual(expected);

    // Chromium dies on its own (a crash, the OOM killer): closing pages must not empty the list.
    const browser = await lockHolder(profile());
    await control("browser.navigate", { url: "https://crash.test/", tab: opened.tab });
    await expect
      .poll(async () => (await control<{ browser: boolean }>("ping")).browser, { timeout: 10_000, interval: 100 })
      .toBe(false);
    expect(await savedTabs(join(state, "browser"))).toEqual(expected);
    // The next browser call starts a fresh one over the dead one's lock and reopens the list.
    expect(await tabURLs()).toEqual(["chrome-error://chromewebdata/", "https://example.test/c", "https://example.test/d"]);
    expect(await lockHolder(profile())).not.toBe(browser);
  });
});

describe("bot containers after a VM reboot", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let engine: FakeEngine;
  let env: BotEnvironment;
  const make = (options: Partial<ConstructorParameters<typeof BotEnvironment>[0]> = {}) =>
    new BotEnvironment({
      engine: new DockerEngineAPI(engine.socketPath),
      kind: "mac-vm",
      imageName: "woven-bots-test",
      memoryBytes: null,
      machineId: "machine-1",
      idleMs: 60_000,
      sweepMs: 60_000,
      ...options,
    });
  const browserState = () => join(engine.volumeDir(volumeName(BOT)), ".woven", "browser");
  const shell = () => env.harnessEnv(BOT)({ cwd: "/workspace" } as never, ctx as never) as RemoteExecutionEnv;
  const services = async () => (await env.control(BOT, "services.list", {}, ctx)) as { name: string; running: boolean; pid?: number }[];
  const tabs = async () => ((await env.control(BOT, "browser.tabs", {}, ctx)) as { url: string }[]).map((tab) => tab.url);
  const creates = () => engine.requests.filter((request) => request === "POST /containers/create").length;
  /** A bot with storage, a restart list and an open tab, saved. */
  const setUp = async () => {
    must(await shell().writeFile("notes.txt", "kept", ctx));
    await env.control(BOT, "services.add", { name: "web", command: "exec sleep 30", cwd: "/tmp" }, ctx);
    await env.control(BOT, "browser.navigate", { url: "https://example.test/docs" }, ctx);
    await expect.poll(() => savedTabs(browserState()), { timeout: 5000 }).toEqual(["https://example.test/docs"]);
  };
  const expectBack = async () => {
    await expect
      .poll(async () => (await services()).find((service) => service.name === "web")?.running, { timeout: 10_000, interval: 200 })
      .toBe(true);
    await expect.poll(tabs, { timeout: 10_000, interval: 200 }).toEqual(["https://example.test/docs"]);
  };

  beforeEach(async (context) => {
    dir = await tempDir();
    engine = new FakeEngine(dir.path);
    engine.supervisorEnv = { WOVEN_PLAYWRIGHT_MODULE: FAKE_PLAYWRIGHT };
    const current = engine;
    context.onTestFailed(() => {
      if (current.helperLog.length) console.error(`helper output:\n${current.helperLog.join("\n")}`);
    });
    await engine.start();
    env = make();
  });
  afterEach(async () => {
    env.close();
    await engine.close();
    await dir.cleanup();
  });

  it("starts a killed container again on the next tool call once the engine is back, keeping it and its state", async () => {
    await setUp();
    const before = engine.containers.get(containerName(BOT));
    const createdBefore = creates();

    // The VM reboots: the container dies with its processes and the socket answers 503.
    engine.unavailable = true;
    await engine.crash(containerName(BOT));
    expect(await lockPresent(join(browserState(), "profile"))).toEqual([true, true, true]);
    await expect(env.state(BOT)).rejects.toThrow(/503/);
    await sleep(100);

    // A tool call made during the reboot waits for the engine instead of failing.
    const pending = shell().readTextFile("notes.txt", ctx);
    setTimeout(() => {
      engine.unavailable = false;
    }, 1200);
    expect(must(await pending)).toBe("kept");

    // Started as it was, not recreated: same container, same image.
    const after = engine.containers.get(containerName(BOT));
    expect(after?.id).toBe(before?.id);
    expect(after?.image).toBe(before?.image);
    expect(after?.running).toBe(true);
    expect(creates()).toBe(createdBefore);
    expect(await env.state(BOT)).toBe("running");
    await expectBack();
  });

  it("fails calls while the engine stays away past the wait, then recovers on the next call", async () => {
    env.close();
    env = make({ engineWaitMs: 300 });
    await setUp();
    engine.unavailable = true;
    await engine.crash(containerName(BOT));
    await sleep(100);
    await expect(shell().exists(".", ctx)).rejects.toThrow(/503|starting/);
    await expect(env.control(BOT, "services.list", {}, ctx)).rejects.toThrow();
    // Back: the same runtime picks up without a restart, and nothing is left stale.
    engine.unavailable = false;
    expect(must(await shell().exists("notes.txt", ctx))).toBe(true);
    expect(await env.state(BOT)).toBe("running");
    await expectBack();
  });

  it("drops the agent stream of a container stopped from outside when the idle sweep finds it", async () => {
    env.close();
    env = make({ idleMs: 50 });
    await setUp();
    await engine.crash(containerName(BOT));
    await sleep(80);
    expect(await env.sweepIdle()).toEqual([]);
    expect(env.lastActivity(BOT)).toBeUndefined();
    // Nothing remembers the old container as running: the next call starts it.
    expect(must(await shell().readTextFile("notes.txt", ctx))).toBe("kept");
    expect(engine.containers.get(containerName(BOT))?.running).toBe(true);
  });

  it("brings the restart list and tabs back after an update, after a rollback, and after a power cut", async () => {
    let failHealth = false;
    env.close();
    env = make({
      healthCheck: async () => {
        if (failHealth) throw new Error("forced failure");
      },
    });
    await setUp();
    // An update right after a power cut snapshots a profile with a stale lock.
    await engine.crash(containerName(BOT));
    expect(await env.updateBot(BOT)).toEqual({ botId: BOT, ok: true });
    await expectBack();

    failHealth = true;
    expect(await env.updateBot(BOT)).toMatchObject({ ok: false, rolledBack: true, error: "forced failure" });
    await expectBack();
    expect(must(await shell().readTextFile("notes.txt", ctx))).toBe("kept");
  });

  it("keeps the restart list and tabs through runtime.update over the protocol", async () => {
    let failHealth = false;
    env.close();
    env = make({
      healthCheck: async () => {
        if (failHealth) throw new Error("forced failure");
      },
    });
    const app = await startTestRuntime(join(dir.path, "runtime"), { models: echoModels().models, env });
    const client = await openClient(app.url);
    try {
      const { bot } = await client.request<{ bot: { id: string } }>("bots.create", { name: "Updated" });
      await env.control(bot.id, "services.add", { name: "web", command: "exec sleep 30", cwd: "/tmp" }, ctx);
      await env.control(bot.id, "browser.navigate", { url: "https://example.test/docs" }, ctx);
      const saved = join(engine.volumeDir(volumeName(bot.id)), ".woven", "browser");
      await expect.poll(() => savedTabs(saved), { timeout: 5000 }).toEqual(["https://example.test/docs"]);
      const update = async () => {
        const seen = client.messages.length;
        await client.request("runtime.update", { botIds: [bot.id] });
        await client.waitFor(
          (m) => m.type === "runtime.update" && m.phase === "done" && client.messages.indexOf(m) >= seen,
          30_000,
        );
        return client.messages
          .slice(seen)
          .filter((m): m is Extract<ServerMessage, { type: "runtime.update" }> => m.type === "runtime.update" && m.botId === bot.id)
          .map((m) => m.phase);
      };
      const environment = async () =>
        (await client.request<{ environment: { state: string; services?: { name: string; running: boolean }[] } }>(
          "bots.environment",
          { botId: bot.id },
        )).environment;
      const back = async () => {
        await expect
          .poll(async () => (await environment()).services?.find((s) => s.name === "web")?.running, {
            timeout: 10_000,
            interval: 200,
          })
          .toBe(true);
        await expect
          .poll(async () => ((await env.control(bot.id, "browser.tabs", {}, ctx)) as { url: string }[]).map((t) => t.url), {
            timeout: 10_000,
            interval: 200,
          })
          .toEqual(["https://example.test/docs"]);
      };
      expect(await update()).toEqual(["stopping", "updating", "updated"]);
      await back();
      failHealth = true;
      expect(await update()).toEqual(["stopping", "updating", "rolledBack"]);
      await back();
    } finally {
      client.close();
      await app.close();
    }
  });
});
