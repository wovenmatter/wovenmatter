import { readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  BotEnvironment,
  containerName,
  snapshotImage,
  snapshotVolumeName,
  volumeName,
} from "../src/environment/container.ts";
import { DockerEngineAPI } from "../src/environment/engine-api.ts";
import { RemoteExecutionEnv } from "../src/environment/remote.ts";
import { FakeEngine } from "./fake-engine.ts";
import { tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;
const BOT = "0b0b0b0b-0000-4000-8000-000000000001";

function must<T>(result: { ok: true; value: T } | { ok: false; error: Error }): T {
  if (!result.ok) throw result.error;
  return result.value;
}

describe("bot containers on the Engine API", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  let engine: FakeEngine;
  let env: BotEnvironment;
  let busy: string | undefined;
  const make = (options: Partial<ConstructorParameters<typeof BotEnvironment>[0]> = {}) =>
    new BotEnvironment({
      engine: new DockerEngineAPI(engine.socketPath),
      kind: "linux-dockerd",
      imageName: "woven-bots-test",
      memoryBytes: 2 * 1024 * 1024 * 1024,
      machineId: "machine-1",
      idleMs: 50,
      sweepMs: 60_000,
      probe: async () => (busy ? { busy } : {}),
      ...options,
    });
  beforeEach(async (context) => {
    dir = await tempDir();
    engine = new FakeEngine(dir.path);
    const current = engine;
    // Helpers run as child processes; their stderr is the only trace of why one failed.
    context.onTestFailed(() => {
      if (current.helperLog.length) console.error(`helper output:\n${current.helperLog.join("\n")}`);
    });
    await engine.start();
    busy = undefined;
    env = make();
  });
  afterEach(async () => {
    env.close();
    await engine.close();
    await dir.cleanup();
  });

  const shell = (cwd = "/workspace") => env.harnessEnv(BOT)({ cwd } as never, ctx as never) as RemoteExecutionEnv;

  it("creates and starts the container on the first tool call, with limits, labels and the read-only helper", async () => {
    expect(engine.containers.size).toBe(0);
    const tools = shell();
    must(await tools.writeFile("hello.txt", "hi", ctx));
    expect(engine.builds).toBe(1);
    const container = engine.containers.get(containerName(BOT));
    expect(container?.running).toBe(true);
    const host = container?.spec.HostConfig as Record<string, unknown>;
    expect(host).toMatchObject({
      Memory: 2 * 1024 * 1024 * 1024,
      MemorySwap: 2 * 1024 * 1024 * 1024,
      RestartPolicy: { Name: "no" },
      CapDrop: ["NET_RAW", "MKNOD"],
    });
    expect(host.PortBindings).toBeUndefined();
    expect(host.Privileged).toBeUndefined();
    expect(host.CapAdd).toBeUndefined();
    expect(JSON.stringify(host)).not.toContain("docker.sock");
    expect(host.Mounts).toEqual([
      { Type: "volume", Source: volumeName(BOT), Target: "/workspace" },
      { Type: "volume", Source: expect.stringMatching(/^woven-bots-helper-/), Target: "/opt/woven-bot", ReadOnly: true },
    ]);
    expect(container?.labels).toMatchObject({ "woven.bot": BOT, "woven.bots.machine": "machine-1" });
    expect(container?.spec.User).toBe("bot");
    expect(await readFile(join(engine.volumeDir(volumeName(BOT)), "hello.txt"), "utf8")).toBe("hi");
    // No memory cap configured: no limit at all.
    const uncapped = make({ memoryBytes: null });
    await uncapped.rebuild(BOT);
    expect((engine.containers.get(containerName(BOT))?.spec.HostConfig as Record<string, unknown>).Memory).toBeUndefined();
    uncapped.close();
  });

  it("stops an idle container, treats a failed process check as busy, and starts again on the next call", async () => {
    must(await shell().writeFile("a.txt", "1", ctx));
    await new Promise((resolve) => setTimeout(resolve, 80));
    // A failed check is never idle.
    engine.ps = undefined;
    expect(await env.sweepIdle()).toEqual([]);
    expect(engine.containers.get(containerName(BOT))?.running).toBe(true);
    // A running command is not idle either.
    engine.ps = "    1     0 tini\n   40     0 node /opt/woven-bot/agent.mjs\n   41    40 make build\n";
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(await env.sweepIdle()).toEqual([]);
    // Nor is a bot the runtime sees working or watched.
    engine.ps = "    1     0 tini\n";
    busy = "someone has its chat open";
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(await env.sweepIdle()).toEqual([]);
    busy = undefined;
    await new Promise((resolve) => setTimeout(resolve, 80));
    expect(await env.sweepIdle()).toEqual([BOT]);
    expect(engine.containers.get(containerName(BOT))?.running).toBe(false);
    expect(must(await shell().readTextFile("a.txt", ctx))).toBe("1");
    expect(engine.containers.get(containerName(BOT))?.running).toBe(true);
  });

  it("forwards a preview stream to a port inside the container", async () => {
    const service = createServer((socket) => socket.end("pong"));
    await new Promise<void>((resolve) => service.listen(0, "127.0.0.1", resolve));
    try {
      const stream = await env.connectPort(BOT, (service.address() as { port: number }).port);
      const chunks: Buffer[] = [];
      await new Promise<void>((resolve, reject) => {
        stream.on("data", (chunk: Buffer) => chunks.push(chunk));
        stream.on("end", () => resolve());
        stream.on("error", reject);
        stream.end("ping");
      });
      expect(Buffer.concat(chunks).toString()).toBe("pong");
    } finally {
      service.close();
    }
  });

  it("runs the restart list through the supervisor across stops", async () => {
    await env.control(BOT, "services.add", { name: "web", command: "exec sleep 30", cwd: "/tmp" }, ctx);
    const list = async () => (await env.control(BOT, "services.list", {}, ctx)) as { running: boolean }[];
    expect((await list())[0]?.running).toBe(true);
    await env.stop(BOT);
    expect(engine.containers.get(containerName(BOT))?.running).toBe(false);
    await expect.poll(async () => (await list())[0]?.running, { timeout: 10_000 }).toBe(true);
  });

  it("updates in place behind a snapshot, and rolls back to it when the health check fails", async () => {
    must(await shell().writeFile("state.txt", "before", ctx));
    const ok = await env.updateBot(BOT);
    expect(ok).toEqual({ botId: BOT, ok: true });
    expect(engine.images.has(snapshotImage(BOT))).toBe(true);
    expect(engine.volumes.has(snapshotVolumeName(BOT))).toBe(true);
    expect(engine.containers.get(containerName(BOT))?.image).toBe(snapshotImage(BOT));
    expect(await readFile(join(engine.volumeDir(snapshotVolumeName(BOT)), "state.txt"), "utf8")).toBe("before");

    // The next update fails its health check: storage and container go back to the snapshot.
    must(await shell().writeFile("state.txt", "after", ctx));
    env.close();
    env = make({
      healthCheck: async () => {
        throw new Error("forced failure");
      },
    });
    const failed = await env.updateBot(BOT);
    expect(failed).toMatchObject({ botId: BOT, ok: false, rolledBack: true, error: "forced failure" });
    expect(await readFile(join(engine.volumeDir(volumeName(BOT)), "state.txt"), "utf8")).toBe("after");
    expect(engine.containers.get(containerName(BOT))?.running).toBe(true);
    // A failing upgrade rolls back too, restoring the storage it snapshotted.
    env.close();
    env = make();
    engine.upgradeExit = 100;
    await writeFile(join(engine.volumeDir(volumeName(BOT)), "state.txt"), "pre-upgrade");
    const upgrade = await env.updateBot(BOT);
    expect(upgrade).toMatchObject({ ok: false, rolledBack: true, error: expect.stringMatching(/upgrade failed/) });
    expect(await readFile(join(engine.volumeDir(volumeName(BOT)), "state.txt"), "utf8")).toBe("pre-upgrade");
    // A bot that never had a container has nothing to update.
    expect(await env.updateBot("0b0b0b0b-0000-4000-8000-000000000099")).toMatchObject({ skipped: true });
  });

  it("rebuilds from a clean image keeping storage, and purges everything", async () => {
    must(await shell().writeFile("keep.txt", "kept", ctx));
    await env.updateBot(BOT);
    await env.rebuild(BOT);
    const image = engine.containers.get(containerName(BOT))?.image;
    expect(image).toMatch(/^woven-bots-test:/);
    expect(must(await shell().readTextFile("keep.txt", ctx))).toBe("kept");
    await env.purge(BOT);
    expect(engine.containers.has(containerName(BOT))).toBe(false);
    expect(engine.volumes.has(volumeName(BOT))).toBe(false);
    expect(engine.volumes.has(snapshotVolumeName(BOT))).toBe(false);
    expect(engine.images.has(snapshotImage(BOT))).toBe(false);
  });

  it("prunes this machine's unused helper volumes and keeps the current one", async () => {
    must(await shell().writeFile("x", "1", ctx));
    engine.volumes.set("woven-bots-helper-old", { "woven.bots.helper": "x", "woven.bots.machine": "machine-1" });
    engine.volumes.set("woven-bots-helper-other", { "woven.bots.helper": "x", "woven.bots.machine": "elsewhere" });
    expect(await env.pruneHelpers()).toEqual(["woven-bots-helper-old"]);
    expect(engine.volumes.has("woven-bots-helper-other")).toBe(true);
    expect(engine.volumes.has(await env.helper())).toBe(true);
  });

  it("leaves other machines' containers alone and stops deleted bots' at startup", async () => {
    must(await shell().writeFile("x", "1", ctx));
    env.close();
    env = make();
    await env.reconcile([], [BOT]);
    expect(engine.containers.get(containerName(BOT))?.running).toBe(false);
  });
});
