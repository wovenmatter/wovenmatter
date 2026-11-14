import { type ChildProcess, execFile, spawn } from "node:child_process";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { createServer, connect } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { BACKGROUND_CONTEXT, withCancel } from "@earendil-works/chord/context";
import { FileError } from "@earendil-works/pi-durable/env";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { runningWork } from "../src/environment/container.ts";
import { EngineError, StreamDemuxer } from "../src/environment/engine-api.ts";
import { BUILD_OUTPUT_TAIL_BYTES, ensureImage, helperArchive, imageContext, imageTag } from "../src/environment/images.ts";
import { PreviewManager } from "../src/environment/previews.ts";
import { AgentConnection, RemoteExecutionEnv } from "../src/environment/remote.ts";
import { createTar } from "../src/environment/tar.ts";
import { openSharedDatabase } from "../src/storage/database.ts";
import { BotRegistry } from "../src/storage/registry.ts";
import { socketDirectory, tempDir } from "./helpers.ts";
import { FakeHost } from "./runtime.ts";

const HELPER = fileURLToPath(new URL("../helper/", import.meta.url));
const ctx = BACKGROUND_CONTEXT;
const run = promisify(execFile);

/** The real env agent as a local child (what the container's exec runs). */
function localAgent(env: Record<string, string> = {}) {
  return spawn(process.execPath, [join(HELPER, "agent.mjs")], {
    env: { PATH: process.env.PATH ?? "/usr/bin:/bin", ...env },
    stdio: ["pipe", "pipe", "pipe"],
  });
}

function must<T>(result: { ok: true; value: T } | { ok: false; error: Error }): T {
  if (!result.ok) throw result.error;
  return result.value;
}

describe("environment agent bridge", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let connection: AgentConnection;
  let env: RemoteExecutionEnv;
  let spawned = 0;
  beforeEach(async () => {
    dir = await tempDir();
    spawned = 0;
    connection = new AgentConnection(async () => {
      spawned++;
      return localAgent();
    });
    env = new RemoteExecutionEnv("test", dir.path, connection);
  });
  afterEach(async () => {
    connection.close();
    await dir.cleanup();
  });

  it("runs file and shell operations in the agent, lazily", async () => {
    expect(spawned).toBe(0);
    must(await env.createDir("a", { recursive: true }, ctx));
    must(await env.writeFile("a/b.txt", "hello\nworld\n", ctx));
    expect(spawned).toBe(1);
    expect(await readFile(join(dir.path, "a/b.txt"), "utf8")).toBe("hello\nworld\n");
    expect(must(await env.readTextFile("a/b.txt", ctx))).toBe("hello\nworld\n");
    must(await env.writeFile("bin", new Uint8Array([0, 1, 254, 255]), ctx));
    expect([...must(await env.readBinaryFile("bin", ctx))]).toEqual([0, 1, 254, 255]);
    const missing = await env.readTextFile("nope.txt", ctx);
    expect(missing.ok).toBe(false);
    if (!missing.ok) {
      expect(missing.error).toBeInstanceOf(FileError);
      expect(missing.error.code).toBe("not_found");
    }
    const output: string[] = [];
    const result = must(
      await env.exec(
        "echo out; echo err >&2; pwd; exit 3",
        { onOutput: (text, _context, info) => output.push(`${info.stream}:${text}`) },
        ctx,
      ),
    );
    expect(result.exitCode).toBe(3);
    expect(output.join("")).toContain("stdout:out");
    expect(output.join("")).toContain("stderr:err");
    expect(spawned).toBe(1);
  });

  it("contains child spawn failures and can start a replacement", async () => {
    connection.close();
    let attempts = 0;
    connection = new AgentConnection(async () =>
      ++attempts === 1
        ? spawn("/woven-bots-test-does-not-exist", [], { stdio: ["pipe", "pipe", "pipe"] })
        : localAgent(),
    );
    env = new RemoteExecutionEnv("test", dir.path, connection);
    await expect(env.exists(".", ctx)).rejects.toThrow();
    expect(must(await env.exists(".", ctx))).toBe(true);
  });

  it("does not inherit the runtime's environment", async () => {
    process.env.WOVEN_BOTS_TEST_SECRET = "should-not-leak";
    try {
      const output: string[] = [];
      must(await env.exec("env", { onOutput: (text) => output.push(text) }, ctx));
      expect(output.join("")).not.toContain("should-not-leak");
    } finally {
      delete process.env.WOVEN_BOTS_TEST_SECRET;
    }
  });

  it("cancels a running command through the context", async () => {
    const { context, cancel } = withCancel(ctx);
    const started = Date.now();
    const pending = env.exec("sleep 20", undefined, context);
    setTimeout(() => cancel(new Error("stop")), 300);
    const result = await pending;
    expect(result.ok).toBe(false);
    expect(Date.now() - started).toBeLessThan(10_000);
  });

  it("starts a new agent after the old one exits", async () => {
    must(await env.exists(".", ctx));
    connection.close();
    expect(must(await env.exists(".", ctx))).toBe(true);
    expect(spawned).toBe(2);
  });
});

describe("in-container supervisor", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let supervisor: ChildProcess | undefined;
  let socket: string;
  let sockets: string;
  let state: string;
  const start = async () => {
    supervisor = spawn(process.execPath, [join(HELPER, "supervisor.mjs")], {
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin", WOVEN_STATE_DIR: state, WOVEN_CONTROL_SOCKET: socket },
      stdio: ["ignore", "ignore", "pipe"],
      cwd: dir.path,
    });
  };
  const stop = async () => {
    const child = supervisor;
    supervisor = undefined;
    if (!child || child.exitCode !== null) return;
    await new Promise<void>((resolve) => {
      child.once("exit", () => resolve());
      child.kill("SIGTERM");
    });
  };
  /** One control call through a real env agent, as the runtime makes them. */
  const control = async (method: string, args: Record<string, unknown> = {}) => {
    const connection = new AgentConnection(async () => localAgent({ WOVEN_CONTROL_SOCKET: socket }));
    try {
      return await connection.control(method, args, ctx);
    } finally {
      connection.close();
    }
  };
  beforeEach(async () => {
    dir = await tempDir();
    sockets = socketDirectory(dir.path);
    socket = join(sockets, "c.sock");
    state = join(dir.path, "state");
    await start();
  });
  afterEach(async () => {
    await stop();
    await dir.cleanup();
    if (sockets !== dir.path) await rm(sockets, { recursive: true, force: true });
  });

  it("keeps the restart list running, restarts on exit and on every start, and serves logs", async () => {
    expect(await control("ping")).toMatchObject({ ok: true, services: 0 });
    await expect(control("services.add", { name: "bad name", command: "true" })).rejects.toThrow(/name/);
    const added = (await control("services.add", {
      name: "ticker",
      command: "echo started $WOVEN_SERVICE; exec sleep 30",
      cwd: dir.path,
    })) as { running: boolean };
    expect(added.running).toBe(true);
    const pid = async () =>
      ((await control("services.list")) as { name: string; pid?: number }[]).find((s) => s.name === "ticker")?.pid;
    const first = await pid();
    expect(first).toBeGreaterThan(0);
    // Killed: the supervisor brings it back.
    process.kill(first as number, "SIGKILL");
    await expect
      .poll(async () => {
        const next = await pid();
        return next !== undefined && next !== first;
      }, { timeout: 10_000, interval: 200 })
      .toBe(true);
    // The kill can land before the first start writes its line, so wait for
    // the restarted process's output.
    const logs = async () => ((await control("services.logs", { name: "ticker" })) as { text: string }).text;
    await expect.poll(logs, { timeout: 10_000, interval: 200 }).toContain("started ticker");
    expect(await logs()).toMatch(/exited/);
    expect(JSON.parse(await readFile(join(state, "services.json"), "utf8"))).toEqual([
      { name: "ticker", command: "echo started $WOVEN_SERVICE; exec sleep 30", cwd: dir.path },
    ]);
    // A container stop stops services; the next start brings them back from the list.
    const before = await pid();
    await stop();
    expect(() => process.kill(before as number, 0)).toThrow();
    await start();
    await expect.poll(pid, { timeout: 10_000, interval: 200 }).toBeGreaterThan(0);
    await control("services.remove", { name: "ticker" });
    expect(await control("services.list")).toEqual([]);
  });

  it("answers a health check through ctl.mjs", async () => {
    const { stdout } = await run(process.execPath, [join(HELPER, "ctl.mjs"), "ping"], {
      env: { PATH: process.env.PATH ?? "", WOVEN_CONTROL_SOCKET: socket },
    });
    expect(JSON.parse(stdout)).toMatchObject({ ok: true });
  });

  it("exits with a reason when its socket cannot be bound", async () => {
    // Longer than sun_path on every platform.
    const unbindable = join(dir.path, "x".repeat(120), "c.sock");
    const child = spawn(process.execPath, [join(HELPER, "supervisor.mjs")], {
      env: { PATH: process.env.PATH ?? "/usr/bin:/bin", WOVEN_STATE_DIR: state, WOVEN_CONTROL_SOCKET: unbindable },
      stdio: ["ignore", "ignore", "pipe"],
    });
    let stderr = "";
    child.stderr?.on("data", (chunk: Buffer) => (stderr += chunk.toString("utf8")));
    const code = await new Promise<number | null>((resolve) => child.once("exit", resolve));
    expect(code).toBe(1);
    expect(stderr).toMatch(/woven supervisor:/);
  });
});

describe("container process check", () => {
  const ps = (rows: string[]) => rows.join("\n");
  it("ignores init, the supervisor tree, env agents and the check itself", () => {
    expect(
      runningWork(
        ps([
          "    1     0 /usr/bin/tini -- node /opt/woven-bot/supervisor.mjs",
          "    7     1 node /opt/woven-bot/supervisor.mjs",
          "   20     7 bash -lc npm run dev",
          "   21    20 node vite",
          "   30     7 node /opt/woven-bot/browser.mjs",
          "   31    30 /opt/ms-playwright/chromium/chrome --headless",
          "   40     0 node /opt/woven-bot/agent.mjs",
          "   50     0 node /opt/woven-bot/forward.mjs 3000",
          "   60     0 ps -eo pid=,ppid=,args=",
        ]),
      ),
    ).toEqual([]);
  });
  it("counts running commands and orphaned background jobs as work", () => {
    expect(
      runningWork(
        ps([
          "    1     0 /usr/bin/tini -- node /opt/woven-bot/supervisor.mjs",
          "    7     1 node /opt/woven-bot/supervisor.mjs",
          "   40     0 node /opt/woven-bot/agent.mjs",
          "   41    40 /bin/bash -c make test",
          "   90     1 python3 long_job.py",
        ]),
      ),
    ).toEqual(["41 /bin/bash -c make test", "90 python3 long_job.py"]);
  });
});

describe("engine streams and archives", () => {
  it("demultiplexes Docker's exec stream across chunk boundaries", () => {
    const out: string[] = [];
    const err: string[] = [];
    const demux = new StreamDemuxer(
      (chunk) => out.push(chunk.toString()),
      (chunk) => err.push(chunk.toString()),
    );
    const frame = (stream: number, text: string) => {
      const body = Buffer.from(text);
      const head = Buffer.alloc(8);
      head[0] = stream;
      head.writeUInt32BE(body.length, 4);
      return Buffer.concat([head, body]);
    };
    const all = Buffer.concat([frame(1, "hello "), frame(2, "oops"), frame(1, "world")]);
    for (let index = 0; index < all.length; index += 5) demux.push(all.subarray(index, index + 5));
    expect(out.join("")).toBe("hello world");
    expect(err.join("")).toBe("oops");
  });

  it("writes tar archives the system tar reads, long paths included", async () => {
    const dir = await tempDir();
    try {
      const long = `${"deep/".repeat(30)}file.txt`;
      const tar = createTar([
        { path: "a", directory: true },
        { path: "a/run.sh", data: Buffer.from("#!/bin/sh\necho hi\n"), mode: 0o755 },
        { path: long, data: Buffer.from("long") },
      ]);
      await writeFile(join(dir.path, "x.tar"), tar);
      await mkdir(join(dir.path, "out"));
      await run("tar", ["-xf", join(dir.path, "x.tar"), "-C", join(dir.path, "out")]);
      expect(await readFile(join(dir.path, "out/a/run.sh"), "utf8")).toContain("echo hi");
      expect(await readFile(join(dir.path, "out", long), "utf8")).toBe("long");
    } finally {
      await dir.cleanup();
    }
  });

  it("tags images by content and keeps an explicit tag", () => {
    expect(imageTag("woven-bots", Buffer.from("a"))).toMatch(/^woven-bots:[0-9a-f]{16}$/);
    expect(imageTag("woven-bots", Buffer.from("a"))).not.toBe(imageTag("woven-bots", Buffer.from("b")));
    expect(imageTag("registry:5000/woven-bots:pinned", Buffer.from("a"))).toBe("registry:5000/woven-bots:pinned");
  });

  it("packs identical verified npm inputs from app and native host layouts and rebuilds on repair changes", async () => {
    const dir = await tempDir();
    try {
      const image = join(dir.path, "image");
      await mkdir(image);
      await writeFile(join(image, "Dockerfile"), "FROM fixture\n");
      const inputs = ["harnesses/prepare-npm.mjs", "harnesses/install-adapter.mjs", "harnesses/npm-version.json",
        "npm-runtime/package.json", "npm-runtime/package-lock.json"];
      for (const layout of ["app", "host"]) {
        for (const input of inputs) {
          const path = join(dir.path, layout, layout === "app" && input.startsWith("npm-runtime/") ? `remote/${input}` : input);
          await mkdir(join(path, ".."), { recursive: true });
          await writeFile(path, input);
        }
      }
      const app = await imageContext(image, join(dir.path, "app"));
      const host = await imageContext(image, join(dir.path, "host"));
      expect(app.equals(host)).toBe(true);
      await writeFile(join(dir.path, "context.tar"), app);
      await mkdir(join(dir.path, "out"));
      await run("tar", ["-xf", join(dir.path, "context.tar"), "-C", join(dir.path, "out")]);
      for (const input of inputs) expect(await readFile(join(dir.path, "out/tooling", input), "utf8")).toBe(input);
      const before = imageTag("woven-bots", host);
      await writeFile(join(dir.path, "host/npm-runtime/package-lock.json"), "new security graph");
      expect(imageTag("woven-bots", await imageContext(image, join(dir.path, "host")))).not.toBe(before);
      await rm(join(dir.path, "host/harnesses/npm-version.json"));
      await expect(imageContext(image, join(dir.path, "host"))).rejects.toThrow(/ENOENT/);
    } finally {
      await dir.cleanup();
    }
  });

  it("packs the helper with the env agent's packages and a completion marker last", async () => {
    const { tar, hash } = await helperArchive();
    expect(hash).toMatch(/^[0-9a-f]{16}$/);
    const text = tar.toString("latin1");
    for (const name of ["agent.mjs", "supervisor.mjs", "browser.mjs", "forward.mjs", "ctl.mjs"]) {
      expect(text).toContain(name);
    }
    expect(text).toContain("node_modules/@earendil-works/pi-durable/package.json");
    expect(text.lastIndexOf(".complete")).toBeGreaterThan(text.lastIndexOf("pi-durable"));
    expect((await helperArchive()).hash).toBe(hash);
  });

  /** An engine whose builds print `lines` and fail with `failures[attempt]`, if any. */
  function buildingEngine(lines: (attempt: number) => string[], failures: (string | undefined)[]) {
    const engine = {
      builds: 0,
      imageExists: async () => false,
      build: async (_context: Buffer, _tags: readonly string[], options: { log?: (line: string) => void } = {}) => {
        const attempt = engine.builds++;
        for (const line of lines(attempt)) options.log?.(line);
        const failure = failures[attempt];
        if (failure) throw new EngineError(`image build failed: ${failure}`);
      },
    };
    return engine;
  }
  const imageDir = fileURLToPath(new URL("../image/", import.meta.url));

  it("keeps the end of a failed image build's output in the log and the error", async () => {
    const noise = Array.from({ length: 4000 }, (_, index) => `step output ${index} ${"x".repeat(40)}`);
    const engine = buildingEngine(
      () => [...noise, "E: Unable to locate package nonexistent-package"],
      ["The command '/bin/sh -c apt-get install -y nonexistent-package' returned a non-zero code: 100"],
    );
    const logs: string[] = [];
    const failure = await ensureImage(engine as never, "woven-bots-test", (line) => logs.push(line), imageDir).catch(
      (error: unknown) => error,
    );
    expect(failure).toBeInstanceOf(EngineError);
    expect((failure as Error).message).toContain("returned a non-zero code: 100");
    expect((failure as Error).message).toContain("Unable to locate package nonexistent-package");
    const output = logs.find((line) => line.includes("build output")) ?? "";
    expect(output).toContain("Unable to locate package nonexistent-package");
    expect(output).not.toContain("step output 0 ");
    expect(Buffer.byteLength(output)).toBeLessThan(BUILD_OUTPUT_TAIL_BYTES + 200);
    expect(engine.builds).toBe(1);
  });

  it("retries an image build once when packages could not be fetched", async () => {
    const fetchFailure = "E: Failed to fetch http://deb.debian.org/debian/pool/main/c/curl.deb  Temporary failure resolving 'deb.debian.org'";
    const engine = buildingEngine((attempt) => (attempt === 0 ? [fetchFailure] : ["ok"]), ["returned a non-zero code: 100"]);
    const logs: string[] = [];
    const tag = await ensureImage(engine as never, "woven-bots-test", (line) => logs.push(line), imageDir);
    expect(tag).toMatch(/^woven-bots-test:/);
    expect(engine.builds).toBe(2);
    expect(logs.some((line) => line.includes("retrying once"))).toBe(true);
    // A second fetch failure is final.
    const stubborn = buildingEngine(() => [fetchFailure], ["code: 100", "code: 100"]);
    await expect(ensureImage(stubborn as never, "woven-bots-test", () => {}, imageDir)).rejects.toThrow(/Temporary failure resolving/);
    expect(stubborn.builds).toBe(2);
  });
});

describe("previews", () => {
  it("proxies HTTP through the transport, counts traffic as activity, and unpublishes", async () => {
    const db = await openSharedDatabase(":memory:");
    const registry = new BotRegistry(db);
    await registry.migrate();
    const upstream = createServer((socket) => {
      socket.once("data", () =>
        socket.end("HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\ncontent-length: 5\r\nconnection: close\r\n\r\nhello"),
      );
    });
    await new Promise<void>((resolve) => upstream.listen(0, "127.0.0.1", resolve));
    const upstreamPort = (upstream.address() as { port: number }).port;
    const host = new FakeHost();
    const touched: string[] = [];
    const opened: number[] = [];
    const previews = new PreviewManager({
      host,
      registry,
      transport: {
        connect: async (_botId, port) => {
          opened.push(port);
          return connect(upstreamPort, "127.0.0.1");
        },
      },
      activity: (botId) => touched.push(botId),
    });
    try {
      const preview = await previews.share("bot-1", 3000);
      expect(preview.url).toMatch(/^https:\/\//);
      expect(await previews.share("bot-1", 3000)).toBe(preview);
      expect(host.calls).toContainEqual({ method: "publishPreview", args: ["bot-1", preview.port, 3000] });
      const response = await fetch(`http://127.0.0.1:${preview.port}/`);
      expect(await response.text()).toBe("hello");
      expect(opened).toEqual([3000]);
      expect(touched.length).toBeGreaterThan(0);
      expect(previews.lastTraffic("bot-1")).toBeGreaterThan(0);
      expect(await previews.unshare("bot-1", 3000)).toBe(true);
      expect(host.calls).toContainEqual({ method: "unpublishPreview", args: ["bot-1", preview.port] });
      await expect(fetch(`http://127.0.0.1:${preview.port}/`)).rejects.toThrow();
    } finally {
      previews.close();
      upstream.close();
      await db.close();
    }
  });
});
