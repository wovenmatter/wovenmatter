import { existsSync } from "node:fs";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createServer } from "node:net";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import {
  BotEnvironment,
  containerName,
  IMAGE_LABEL,
  snapshotImage,
  snapshotVolumeName,
  volumeName,
} from "../src/environment/container.ts";
import { HELPER_LABEL, SHARED_VOLUME } from "../src/environment/images.ts";
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
    // The base image and the toolchain image.
    expect(engine.builds).toBe(2);
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
      { Type: "volume", Source: SHARED_VOLUME, Target: "/opt/woven", ReadOnly: true },
    ]);
    expect(container?.labels).toEqual({ "woven.bot": BOT, "woven.bots.machine": "machine-1", [IMAGE_LABEL]: await env.image() });
    // Its helper and toolchain are links into the shared volume, both filled and complete.
    const shared = await env.shared();
    expect(Object.fromEntries(container?.links ?? [])).toEqual({
      "/opt/woven-bot": `/opt/woven/helper/${shared.helper}`,
      "/opt/woven-toolchain": `/opt/woven/toolchain/${shared.toolchain}`,
    });
    expect(existsSync(join(engine.volumeDir(SHARED_VOLUME), "helper", shared.helper, ".complete"))).toBe(true);
    expect(existsSync(join(engine.volumeDir(SHARED_VOLUME), "helper", shared.helper, "agent.mjs"))).toBe(true);
    expect(existsSync(join(engine.volumeDir(SHARED_VOLUME), "toolchain", shared.toolchain, ".complete"))).toBe(true);
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

  it("waits for a preview port that is still starting, as after a wake", async () => {
    // Reserve a free port, then start the service only after the connection was opened.
    const probe = createServer();
    await new Promise<void>((resolve) => probe.listen(0, "127.0.0.1", resolve));
    const port = (probe.address() as { port: number }).port;
    await new Promise<void>((resolve) => probe.close(() => resolve()));
    const service = createServer((socket) => socket.end("late pong"));
    try {
      const stream = await env.connectPort(BOT, port);
      const chunks: Buffer[] = [];
      const done = new Promise<void>((resolve, reject) => {
        stream.on("data", (chunk: Buffer) => chunks.push(chunk));
        stream.on("end", () => resolve());
        stream.on("error", reject);
      });
      stream.end("ping");
      await new Promise((resolve) => setTimeout(resolve, 1000));
      await new Promise<void>((resolve) => service.listen(port, "127.0.0.1", resolve));
      await done;
      expect(Buffer.concat(chunks).toString()).toBe("late pong");
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

  it("updates in place behind a snapshot, keeping the container, and rolls back to it when the health check fails", async () => {
    must(await shell().writeFile("state.txt", "before", ctx));
    const id = engine.containers.get(containerName(BOT))?.id;
    const ok = await env.updateBot(BOT);
    expect(ok).toEqual({ botId: BOT, ok: true });
    expect(engine.images.has(snapshotImage(BOT))).toBe(true);
    expect(engine.volumes.has(snapshotVolumeName(BOT))).toBe(true);
    // The same container: everything the bot installed in it stays, and no commit becomes its base.
    expect(engine.containers.get(containerName(BOT))?.id).toBe(id);
    expect(engine.containers.get(containerName(BOT))?.image).toBe(await env.image());
    expect(engine.temporaries.map((entry) => entry.kind)).not.toContain("capture");
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
    expect(engine.containers.get(containerName(BOT))?.image).toBe(snapshotImage(BOT));
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

  it("moves to a new toolchain in place: relinks, checks Chromium, rebuilds the bot's own packages", async () => {
    must(await shell().writeFile("keep.txt", "kept", ctx));
    const container = engine.containers.get(containerName(BOT));
    if (!container) throw new Error("no container");
    container.links.set("/opt/woven-toolchain", "/opt/woven/toolchain/older");
    expect((await env.imageStatus()).outdatedBots).toEqual([BOT]);
    expect((await env.imageStatus()).staleBots).toEqual([]);
    // Chromium needs a newer system library first: its dependencies are installed once.
    engine.chromiumExits = [1, 0];
    expect(await env.updateBot(BOT)).toEqual({ botId: BOT, ok: true });
    const after = engine.containers.get(containerName(BOT));
    expect(after?.id).toBe(container.id);
    expect(after?.links.get("/opt/woven-toolchain")).toBe(`/opt/woven/toolchain/${(await env.shared()).toolchain}`);
    const scripts = engine.scripts.map((entry) => entry.script);
    expect(scripts.some((script) => script.includes("install-deps"))).toBe(true);
    expect(scripts.some((script) => script.includes("npm rebuild"))).toBe(true);
    expect((await env.imageStatus()).outdatedBots).toEqual([]);
    expect(must(await shell().readTextFile("keep.txt", ctx))).toBe("kept");

    // Chromium that never starts rolls the bot back to its previous toolchain.
    after?.links.set("/opt/woven-toolchain", "/opt/woven/toolchain/older");
    engine.chromiumExits = [1, 1];
    const failed = await env.updateBot(BOT);
    expect(failed).toMatchObject({ ok: false, rolledBack: true, error: expect.stringMatching(/Chromium did not start/) });
    expect(engine.containers.get(containerName(BOT))?.links.get("/opt/woven-toolchain")).toBe("/opt/woven/toolchain/older");
  });

  it("moves a bot made from an older base image, carrying its own changes and keeping its storage", async () => {
    must(await shell().writeFile("keep.txt", "kept", ctx));
    const container = engine.containers.get(containerName(BOT));
    if (!container) throw new Error("no container");
    container.labels[IMAGE_LABEL] = "woven-bots-test:older";
    engine.images.add("woven-bots-test:older");
    const before = await env.imageStatus();
    expect(before.staleBots).toEqual([BOT]);
    expect(before.tools.playwright).toMatch(/^\d+\.\d+/);
    expect(before.tools.node).toMatch(/^\d+\.\d+/);
    const moved = await env.updateBot(BOT);
    expect(moved).toEqual({ botId: BOT, ok: true, movedToImage: true });
    // The old base image is the baseline; the snapshot is what the bot's container held.
    expect(engine.temporaries).toEqual(
      expect.arrayContaining([
        { kind: "baseline", image: "woven-bots-test:older" },
        { kind: "capture", image: snapshotImage(BOT) },
      ]),
    );
    expect(engine.scripts.some((entry) => entry.script.includes("update-report.md"))).toBe(true);
    expect(engine.containers.get(containerName(BOT))?.image).toBe(await env.image());
    expect(engine.containers.get(containerName(BOT))?.links.size).toBe(2);
    expect(must(await shell().readTextFile("keep.txt", ctx))).toBe("kept");
    expect((await env.imageStatus()).staleBots).toEqual([]);
    // Already on the current image: the next update stays in place behind its snapshot.
    expect(await env.updateBot(BOT)).toEqual({ botId: BOT, ok: true });
  });

  it("moves a container from before the shared volume, and rolls one back with its old mounts", async () => {
    must(await shell().writeFile("keep.txt", "kept", ctx));
    const container = engine.containers.get(containerName(BOT));
    if (!container) throw new Error("no container");
    // The layout before the shared volume: its own helper volume at /opt/woven-bot, no links.
    engine.volumes.set("woven-bots-helper-own", { [HELPER_LABEL]: "woven-bots-helper-own", "woven.bots.machine": "machine-1" });
    container.labels[HELPER_LABEL] = "woven-bots-helper-own";
    container.links.clear();
    (container.spec.HostConfig as { Mounts: unknown[] }).Mounts = [
      { Type: "volume", Source: volumeName(BOT), Target: "/workspace" },
      { Type: "volume", Source: "woven-bots-helper-own", Target: "/opt/woven-bot", ReadOnly: true },
    ];
    expect((await env.imageStatus()).staleBots).toEqual([BOT]);
    // A failed move restores the old container exactly, old helper volume and all.
    env.close();
    env = make({
      healthCheck: async () => {
        throw new Error("forced failure");
      },
    });
    expect(await env.updateBot(BOT)).toMatchObject({ ok: false, rolledBack: true });
    const restored = engine.containers.get(containerName(BOT));
    expect((restored?.spec.HostConfig as { Mounts: unknown[] }).Mounts).toEqual([
      { Type: "volume", Source: volumeName(BOT), Target: "/workspace" },
      { Type: "volume", Source: "woven-bots-helper-own", Target: "/opt/woven-bot", ReadOnly: true },
    ]);
    expect(engine.volumes.has("woven-bots-helper-own")).toBe(true);
    // A move that works puts it in the current layout, and the old helper volume can go.
    env.close();
    env = make();
    expect(await env.updateBot(BOT)).toMatchObject({ ok: true, movedToImage: true });
    expect((engine.containers.get(containerName(BOT))?.spec.HostConfig as { Mounts: unknown[] }).Mounts).toEqual([
      { Type: "volume", Source: volumeName(BOT), Target: "/workspace" },
      { Type: "volume", Source: SHARED_VOLUME, Target: "/opt/woven", ReadOnly: true },
    ]);
    expect((await env.imageStatus()).staleBots).toEqual([]);
    expect(must(await shell().readTextFile("keep.txt", ctx))).toBe("kept");
    // Pruned once the update finished.
    await expect.poll(() => engine.volumes.has("woven-bots-helper-own")).toBe(false);
  });

  it("treats a container the current release made as current: it is told by its mounts, with or without the engine listing them", async () => {
    must(await shell().writeFile("keep.txt", "kept", ctx));
    const container = engine.containers.get(containerName(BOT));
    if (!container) throw new Error("no container");
    // The label the current release put on its containers. Nothing reads it; it stays where it is.
    container.labels["woven.bots.layout"] = "2";
    for (const listsMounts of [true, false]) {
      engine.listsMounts = listsMounts;
      expect(await env.imageStatus()).toMatchObject({ staleBots: [], outdatedBots: [] });
      // Its links are healed when missing, and the directories it links to survive a prune.
      await env.stop(BOT);
      container.links.clear();
      expect(must(await shell().readTextFile("keep.txt", ctx))).toBe("kept");
      expect(container.links.size).toBe(2);
      const toolchain = container.links.get("/opt/woven-toolchain") ?? "";
      container.links.set("/opt/woven-toolchain", "/opt/woven/toolchain/older");
      engine.lastPrune = undefined;
      await env.pruneShared();
      expect(engine.lastPrune ?? "").toContain("'toolchain/older'");
      container.links.set("/opt/woven-toolchain", toolchain);
      // A move that stopped after this container was made is resumed on its next start.
      const pending = join(engine.volumeDir(volumeName(BOT)), ".woven/system/carry/.pending");
      await mkdir(join(pending, ".."), { recursive: true });
      await writeFile(pending, "");
      await env.stop(BOT);
      expect(must(await shell().readTextFile("keep.txt", ctx))).toBe("kept");
      expect(existsSync(pending)).toBe(false);
    }
    // Its update stays in place: the same container, still carrying the label it was made with.
    const id = container.id;
    expect(await env.updateBot(BOT)).toEqual({ botId: BOT, ok: true });
    expect(engine.containers.get(containerName(BOT))?.id).toBe(id);
    expect(engine.containers.get(containerName(BOT))?.labels["woven.bots.layout"]).toBe("2");
    expect((await env.imageStatus()).staleBots).toEqual([]);
  });

  it("rebuilds from a clean image behind a snapshot, carrying its installs, and purges everything", async () => {
    must(await shell().writeFile("keep.txt", "kept", ctx));
    await env.updateBot(BOT);
    const id = engine.containers.get(containerName(BOT))?.id;
    await env.rebuild(BOT);
    const rebuilt = engine.containers.get(containerName(BOT));
    expect(rebuilt?.id).not.toBe(id);
    expect(rebuilt?.image).toBe(await env.image());
    expect(engine.temporaries.map((entry) => entry.kind)).toContain("capture");
    expect(engine.images.has(snapshotImage(BOT))).toBe(true);
    expect(must(await shell().readTextFile("keep.txt", ctx))).toBe("kept");
    // A capture that fails leaves the bot as it was.
    engine.temporaryExit = { capture: 1 };
    await expect(env.rebuild(BOT)).rejects.toThrow(/rolled back/);
    expect(must(await shell().readTextFile("keep.txt", ctx))).toBe("kept");
    engine.temporaryExit = {};
    await env.purge(BOT);
    expect(engine.containers.has(containerName(BOT))).toBe(false);
    expect(engine.volumes.has(volumeName(BOT))).toBe(false);
    expect(engine.volumes.has(snapshotVolumeName(BOT))).toBe(false);
    expect(engine.images.has(snapshotImage(BOT))).toBe(false);
  });

  it("prunes this machine's unused helper volumes and keeps the shared directories bots link to", async () => {
    must(await shell().writeFile("x", "1", ctx));
    engine.volumes.set("woven-bots-helper-old", { "woven.bots.helper": "x", "woven.bots.machine": "machine-1" });
    engine.volumes.set("woven-bots-helper-other", { "woven.bots.helper": "x", "woven.bots.machine": "elsewhere" });
    expect(await env.pruneHelpers()).toEqual(["woven-bots-helper-old"]);
    expect(engine.volumes.has("woven-bots-helper-other")).toBe(true);
    expect(engine.volumes.has(SHARED_VOLUME)).toBe(true);
    // An older toolchain a bot still links to is kept; the prune runs in a container of the base.
    engine.containers.get(containerName(BOT))?.links.set("/opt/woven-toolchain", "/opt/woven/toolchain/older");
    engine.temporaries.length = 0;
    await env.pruneShared();
    expect(engine.temporaries).toEqual([{ kind: "prune", image: await env.image() }]);
    const shared = await env.shared();
    const kept = engine.lastPrune ?? "";
    for (const dir of ["toolchain/older", `toolchain/${shared.toolchain}`, `helper/${shared.helper}`]) {
      expect(kept).toContain(`'${dir}'`);
    }
  });

  it("prunes nothing when it cannot tell what a bot links to", async () => {
    must(await shell().writeFile("x", "1", ctx));
    engine.temporaries.length = 0;
    engine.statStatus = 500;
    expect(await env.pruneShared()).toEqual([]);
    expect(engine.temporaries).toEqual([]);
    engine.statStatus = undefined;
  });

  it("restores a stopped container's missing links before starting it", async () => {
    must(await shell().writeFile("x", "1", ctx));
    await env.stop(BOT);
    engine.containers.get(containerName(BOT))?.links.clear();
    expect(must(await shell().readTextFile("x", ctx))).toBe("1");
    expect(engine.containers.get(containerName(BOT))?.links.size).toBe(2);
  });

  it("applies captured changes a move left waiting when the runtime stopped partway", async () => {
    must(await shell().writeFile("x", "1", ctx));
    // The runtime stopped after the capture and before the new container applied it.
    const pending = join(engine.volumeDir(volumeName(BOT)), ".woven/system/carry/.pending");
    await mkdir(join(pending, ".."), { recursive: true });
    await writeFile(pending, "");
    await env.stop(BOT);
    engine.containers.delete(containerName(BOT));
    expect(must(await shell().readTextFile("x", ctx))).toBe("1");
    expect(engine.scripts.some((entry) => entry.script.includes("update-report.md"))).toBe(true);
    expect(existsSync(pending)).toBe(false);

    // Or after its new container was made: the bot shows an update waiting, and its next start
    // applies the changes.
    await writeFile(pending, "");
    await env.stop(BOT);
    engine.scripts.length = 0;
    expect((await env.imageStatus()).outdatedBots).toEqual([BOT]);
    expect(must(await shell().readTextFile("x", ctx))).toBe("1");
    expect(engine.scripts.some((entry) => entry.script.includes("update-report.md"))).toBe(true);
    expect(existsSync(pending)).toBe(false);
    expect((await env.imageStatus()).outdatedBots).toEqual([]);
  });

  it("leaves other machines' containers alone and stops deleted bots' at startup", async () => {
    must(await shell().writeFile("x", "1", ctx));
    env.close();
    env = make();
    await env.reconcile([], [BOT]);
    expect(engine.containers.get(containerName(BOT))?.running).toBe(false);
  });
});
