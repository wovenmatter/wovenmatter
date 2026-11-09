import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord";
import { Duplex } from "node:stream";
import type { BotEnvironmentAdapter, HarnessEnvFactory } from "../env.ts";
import { type DockerEngineAPI, EngineError, type ExecProcess } from "./engine-api.ts";
import {
  ensureHelperVolume,
  ensureImage,
  HELPER_LABEL,
  HELPER_MOUNT,
  helperArchive,
  IMAGE_DIR,
} from "./images.ts";
import { AgentConnection, type AgentProcess, RemoteExecutionEnv } from "./remote.ts";

export const CONTAINER_USER = "bot";
export const WORKSPACE = "/workspace";
export const BOT_LABEL = "woven.bot";
export const MACHINE_LABEL = "woven.bots.machine";
/** The contract's fixed idle period: a bot stops fully after 15 minutes idle. */
export const IDLE_STOP_MS = 15 * 60_000;
const AGENT_COMMAND = ["node", `${HELPER_MOUNT}/agent.mjs`];
const SHM_BYTES = 512 * 1024 * 1024;
const STOP_SECONDS = 20;
const DEFAULT_UPGRADE = [
  "sh",
  "-c",
  "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get -y -o Dpkg::Options::=--force-confold upgrade && rm -rf /var/lib/apt/lists/*",
];

export const containerName = (botId: string) => `woven-bot-${botId}`;
export const volumeName = (botId: string) => `woven-bot-${botId}-workspace`;
export const snapshotVolumeName = (botId: string) => `woven-bot-${botId}-snapshot`;
export const SNAPSHOT_REPO = "woven-bot-snapshot";
export const snapshotImage = (botId: string) => `${SNAPSHOT_REPO}:${botId}`;

/** What the runtime knows about a bot's activity outside its container. */
export type IdleProbe = {
  /** A reason the bot is not idle (a turn running, a viewer, a timer due soon), if any. */
  readonly busy?: string;
};

export type UpdateResult = {
  readonly botId: string;
  readonly ok: boolean;
  /** Nothing to update: the bot never had a container. */
  readonly skipped?: boolean;
  readonly rolledBack?: boolean;
  readonly error?: string;
};

export type BotEnvironmentOptions = {
  readonly engine: DockerEngineAPI;
  readonly kind: "linux-dockerd" | "mac-vm";
  /** `image.tag` from the runtime config. */
  readonly imageName: string;
  readonly imageDir?: string;
  /** Per-bot container memory limit; null: no cap. */
  readonly memoryBytes: number | null;
  readonly machineId: string;
  /** The runtime's own view: a bot with a turn running or a viewer is never stopped. */
  readonly probe?: (botId: string) => Promise<IdleProbe>;
  /** Override the fixed idle period (tests only). */
  readonly idleMs?: number;
  /** How often idle bots are looked for. */
  readonly sweepMs?: number;
  /** The in-place update command, run as root (tests replace the apt upgrade). */
  readonly upgradeCommand?: readonly string[];
  /** Extra health check after an update (tests force a failure). */
  readonly healthCheck?: (botId: string) => Promise<void>;
  readonly log?: (message: string) => void;
};

/**
 * Pids that count as work: anything but PID 1 (tini), the supervisor and everything under it
 * (the restart list and the browser), env agents (but not their children: running commands),
 * preview forwarders and the inspecting `ps` itself. Orphans re-parented to PID 1 count.
 */
export function runningWork(psOutput: string): string[] {
  const rows = psOutput
    .split("\n")
    .map((line) => /^\s*(\d+)\s+(\d+)\s+(.*)$/.exec(line))
    .filter((match): match is RegExpExecArray => match !== null)
    .map(([, pid, ppid, args]) => ({ pid: Number(pid), ppid: Number(ppid), args: args ?? "" }));
  const parent = new Map(rows.map((row) => [row.pid, row.ppid]));
  const supervisors = new Set(
    rows
      .filter((row) => row.pid !== 1 && row.args.includes(`${HELPER_MOUNT}/supervisor.mjs`))
      .map((row) => row.pid),
  );
  const under = (pid: number, roots: Set<number>) => {
    for (let current: number | undefined = pid, hops = 0; current && hops < 64; hops++) {
      if (roots.has(current)) return true;
      current = parent.get(current);
    }
    return false;
  };
  return rows
    .filter((row) => {
      if (row.pid === 1) return false;
      if (under(row.pid, supervisors)) return false;
      if (row.args.includes(`${HELPER_MOUNT}/agent.mjs`)) return false;
      if (row.args.includes(`${HELPER_MOUNT}/forward.mjs`)) return false;
      if (/^ps -eo /.test(row.args)) return false;
      return true;
    })
    .map((row) => `${row.pid} ${row.args}`);
}

class ExecDuplex extends Duplex {
  readonly #child: ExecProcess;
  constructor(child: ExecProcess) {
    super();
    this.#child = child;
    child.stdout.on("data", (chunk: Buffer) => {
      if (!this.push(chunk)) child.stdout.pause();
    });
    child.stdout.on("end", () => this.push(null));
    child.once("error", (error: Error) => this.destroy(error));
  }
  override _read(): void {
    this.#child.stdout.resume();
  }
  override _write(chunk: Buffer, _encoding: BufferEncoding, done: (error?: Error | null) => void): void {
    this.#child.stdin.write(chunk, done);
  }
  override _final(done: (error?: Error | null) => void): void {
    this.#child.stdin.end();
    done();
  }
  override _destroy(error: Error | null, done: (error?: Error | null) => void): void {
    this.#child.kill();
    done(error);
  }
}

/**
 * One container per bot on a Woven-owned Docker Engine, reached over its API socket. A bot's
 * container is created and started on its first tool call, runs the bot's restart list and browser
 * through the mounted supervisor, and stops after the fixed idle period. Its storage volume
 * outlives the container: soft delete stops it, purge removes both. No Docker socket is mounted
 * and no port is published; previews are carried over exec streams.
 */
export class BotEnvironment implements BotEnvironmentAdapter {
  readonly kind: string;
  readonly #engine: DockerEngineAPI;
  readonly #options: BotEnvironmentOptions;
  readonly #log: (message: string) => void;
  readonly #connections = new Map<string, AgentConnection>();
  readonly #locks = new Map<string, Promise<unknown>>();
  /** Bots whose container this process saw running, with their last activity. */
  readonly #lastUse = new Map<string, number>();
  #idleTimer: NodeJS.Timeout | undefined;
  #image: Promise<string> | undefined;
  #helper: Promise<string> | undefined;
  #closed = false;

  constructor(options: BotEnvironmentOptions) {
    this.#options = options;
    this.#engine = options.engine;
    this.kind = options.kind;
    this.#log = options.log ?? (() => {});
  }

  get idleMs(): number {
    return this.#options.idleMs ?? IDLE_STOP_MS;
  }

  #labels(): Record<string, string> {
    return { [MACHINE_LABEL]: this.#options.machineId };
  }

  harnessEnv(botId: string): HarnessEnvFactory {
    return (target) => {
      const cwd =
        target.cwd && (target.cwd === WORKSPACE || target.cwd.startsWith(`${WORKSPACE}/`))
          ? target.cwd
          : WORKSPACE;
      return new RemoteExecutionEnv(`woven:${containerName(botId)}`, cwd, this.#connection(botId));
    };
  }

  control(botId: string, method: string, args: Record<string, unknown>, context: Context = BACKGROUND_CONTEXT) {
    return this.#connection(botId).control(method, args, context);
  }

  #connection(botId: string): AgentConnection {
    let connection = this.#connections.get(botId);
    if (!connection) {
      connection = new AgentConnection(
        async () => {
          await this.ensure(botId);
          return this.#engine.spawn(containerName(botId), AGENT_COMMAND, {
            user: CONTAINER_USER,
            workdir: WORKSPACE,
          }) as unknown as AgentProcess;
        },
        this.#log,
        () => this.touch(botId),
      );
      this.#connections.set(botId, connection);
    }
    return connection;
  }

  /** Serialize lifecycle operations per bot. */
  #locked<T>(botId: string, run: () => Promise<T>): Promise<T> {
    const previous = this.#locks.get(botId) ?? Promise.resolve();
    const next = previous.catch(() => {}).then(run);
    this.#locks.set(botId, next);
    const release = () => {
      if (this.#locks.get(botId) === next) this.#locks.delete(botId);
    };
    next.then(release, release);
    return next;
  }

  /** The bot image, built from bots/image when missing. */
  image(): Promise<string> {
    if (!this.#image) {
      const pending = ensureImage(
        this.#engine,
        this.#options.imageName,
        this.#log,
        this.#options.imageDir ?? IMAGE_DIR,
      );
      this.#image = pending;
      pending.catch(() => {
        if (this.#image === pending) this.#image = undefined;
      });
    }
    return this.#image;
  }

  /** This runtime's helper volume (versioned by content). */
  helper(): Promise<string> {
    if (!this.#helper) {
      const pending = (async () =>
        ensureHelperVolume(this.#engine, await this.image(), this.#labels(), await helperArchive()))();
      this.#helper = pending;
      pending.catch(() => {
        if (this.#helper === pending) this.#helper = undefined;
      });
    }
    return this.#helper;
  }

  async state(botId: string): Promise<"missing" | "running" | "stopped"> {
    const info = await this.#engine.inspectContainer(containerName(botId));
    if (!info) return "missing";
    return info.State.Running ? "running" : "stopped";
  }

  async #create(botId: string, image: string, helper: string): Promise<void> {
    const memory = this.#options.memoryBytes;
    await this.#engine.createContainer(containerName(botId), {
      Image: image,
      Hostname: `bot-${botId.slice(0, 8)}`,
      User: CONTAINER_USER,
      WorkingDir: WORKSPACE,
      Env: [`WOVEN_BOT_ID=${botId}`],
      Labels: { ...this.#labels(), [BOT_LABEL]: botId, [HELPER_LABEL]: helper },
      StopTimeout: STOP_SECONDS,
      HostConfig: {
        Mounts: [
          { Type: "volume", Source: volumeName(botId), Target: WORKSPACE },
          { Type: "volume", Source: helper, Target: HELPER_MOUNT, ReadOnly: true },
        ],
        RestartPolicy: { Name: "no" },
        ShmSize: SHM_BYTES,
        ...(memory ? { Memory: memory, MemorySwap: memory } : {}),
      },
    });
  }

  /** Make sure the bot's container exists and runs. */
  ensure(botId: string): Promise<void> {
    if (this.#closed) return Promise.reject(new Error("the bot environment is shut down"));
    return this.#locked(botId, () => this.#ensureUnlocked(botId));
  }

  async #ensureUnlocked(botId: string): Promise<void> {
    const name = containerName(botId);
    let info = await this.#engine.inspectContainer(name);
    if (!info) {
      const [image, helper] = [await this.image(), await this.helper()];
      if (!(await this.#engine.volumeExists(volumeName(botId)))) {
        await this.#engine.createVolume(volumeName(botId), { ...this.#labels(), [BOT_LABEL]: botId });
      }
      await this.#create(botId, image, helper);
      this.#log(`bot ${botId}: created container ${name}`);
      info = await this.#engine.inspectContainer(name);
    }
    if (!info?.State.Running) {
      await this.#engine.startContainer(name);
      this.#log(`bot ${botId}: started container ${name}`);
    }
    this.touch(botId);
  }

  touch(botId: string): void {
    this.#lastUse.set(botId, Date.now());
    if (!this.#idleTimer && !this.#closed) {
      this.#idleTimer = setInterval(
        () => void this.sweepIdle(),
        this.#options.sweepMs ?? Math.min(this.idleMs, 60_000),
      );
      this.#idleTimer.unref();
    }
  }

  /** Look for idle bots now (the timer does this every minute). */
  async sweepIdle(): Promise<string[]> {
    const stopped: string[] = [];
    for (const botId of [...this.#lastUse.keys()]) {
      try {
        if (await this.#stopIfIdle(botId)) stopped.push(botId);
      } catch (error) {
        this.#log(`bot ${botId}: idle stop: ${(error as Error).message}`);
      }
    }
    return stopped;
  }

  /** Why the bot is not idle now, or undefined when it may be stopped. */
  async busyReason(botId: string): Promise<string | undefined> {
    const last = this.#lastUse.get(botId);
    if (last !== undefined && Date.now() - last < this.idleMs) return "recent activity";
    if (this.#connections.get(botId)?.busy) return "a tool call is running";
    const probe = await this.#options.probe?.(botId).catch(() => ({ busy: "status unknown" }));
    if (probe?.busy) return probe.busy;
    const work = await this.runningWork(botId);
    if (work === undefined) return "the process check failed";
    return work.length ? `running: ${work[0]}` : undefined;
  }

  /** Processes that count as work, or undefined when the check failed (which counts as busy). */
  async runningWork(botId: string): Promise<string[] | undefined> {
    try {
      const result = await this.#engine.run(containerName(botId), ["ps", "-eo", "pid=,ppid=,args="], {
        user: "root",
        timeoutMs: 15_000,
      });
      if (result.code !== 0) return undefined;
      return runningWork(result.stdout);
    } catch {
      return undefined;
    }
  }

  #stopIfIdle(botId: string): Promise<boolean> {
    if (this.#closed) return Promise.resolve(false);
    const last = this.#lastUse.get(botId);
    if (last === undefined || Date.now() - last < this.idleMs) return Promise.resolve(false);
    return this.#locked(botId, async () => {
      const state = await this.state(botId);
      if (state !== "running") {
        this.#lastUse.delete(botId);
        return false;
      }
      const reason = await this.busyReason(botId);
      if (reason) {
        // Look again a full period later.
        this.#lastUse.set(botId, Date.now());
        return false;
      }
      this.#connections.get(botId)?.close();
      this.#lastUse.delete(botId);
      await this.#engine.stopContainer(containerName(botId), STOP_SECONDS);
      this.#log(`bot ${botId}: stopped idle container ${containerName(botId)}`);
      return true;
    });
  }

  /** A stream to `port` inside the bot's container over an exec (previews). */
  async connectPort(botId: string, port: number): Promise<Duplex> {
    await this.ensure(botId);
    const child = this.#engine.spawn(
      containerName(botId),
      ["node", `${HELPER_MOUNT}/forward.mjs`, String(port)],
      { user: CONTAINER_USER },
    );
    return new ExecDuplex(child);
  }

  lastActivity(botId: string): number | undefined {
    return this.#lastUse.get(botId);
  }

  /** Stop now (the user asked); the next tool call starts it again. */
  stop(botId: string): Promise<void> {
    this.#connections.get(botId)?.close();
    return this.#locked(botId, async () => {
      this.#lastUse.delete(botId);
      await this.#engine.stopContainer(containerName(botId), STOP_SECONDS);
    });
  }

  /** Soft delete: stop the container and its agent, keep the container and its storage. */
  dispose(botId: string): Promise<void> {
    this.#connections.get(botId)?.close();
    return this.#locked(botId, async () => {
      this.#lastUse.delete(botId);
      await this.#engine.stopContainer(containerName(botId), STOP_SECONDS);
    });
  }

  /** Purge: the container, its storage, its snapshot. Missing pieces are fine. */
  purge(botId: string): Promise<void> {
    this.#connections.get(botId)?.close();
    this.#connections.delete(botId);
    return this.#locked(botId, async () => {
      this.#lastUse.delete(botId);
      await this.#engine.removeContainer(containerName(botId));
      await this.#engine.removeVolume(volumeName(botId));
      await this.#engine.removeVolume(snapshotVolumeName(botId));
      await this.#engine.removeImage(snapshotImage(botId));
      this.#log(`bot ${botId}: removed its container, storage and snapshot`);
    });
  }

  /** Restore: nothing to do up front; the next tool call starts the container. */
  async restore(_botId: string): Promise<void> {}

  async reconcile(activeBotIds: readonly string[], deletedBotIds: readonly string[] = []): Promise<void> {
    await this.#engine.ping();
    // Ready before the first tool call needs it, which then waits only for a container start.
    void this.helper().catch((error: unknown) => this.#log(`bot image: ${(error as Error).message}`));
    const active = new Set(activeBotIds);
    const deleted = new Set(deletedBotIds);
    for (const container of await this.#engine.listContainers(BOT_LABEL)) {
      const botId = container.Labels[BOT_LABEL];
      if (!botId || container.Labels[MACHINE_LABEL] !== this.#options.machineId) continue;
      if (container.State !== "running") continue;
      if (deleted.has(botId)) await this.dispose(botId).catch(() => {});
      // Left running by the last runtime: its idle clock starts now.
      else if (active.has(botId)) this.touch(botId);
    }
  }

  // --- updates ---------------------------------------------------------------------------------

  /** Copy one volume's contents over another's, through a short-lived container. */
  async #copyVolume(from: string, to: string, image: string): Promise<void> {
    const name = `woven-bots-copy-${Date.now().toString(36)}`;
    await this.#engine.createContainer(name, {
      Image: image,
      User: "root",
      Entrypoint: ["sh", "-c"],
      Cmd: ["find /dst -mindepth 1 -delete && cp -a /src/. /dst/"],
      Labels: { ...this.#labels(), "woven.bots.temporary": "copy" },
      HostConfig: {
        Mounts: [
          { Type: "volume", Source: from, Target: "/src", ReadOnly: true },
          { Type: "volume", Source: to, Target: "/dst" },
        ],
        NetworkMode: "none",
      },
    });
    try {
      await this.#engine.startContainer(name);
      const code = await this.#engine.waitContainer(name);
      if (code !== 0) throw new EngineError(`volume copy ${from} → ${to} exited ${code}`);
    } finally {
      await this.#engine.removeContainer(name).catch(() => {});
    }
  }

  async #healthCheck(botId: string): Promise<void> {
    const result = await this.#engine.run(
      containerName(botId),
      ["sh", "-c", "node --version && sudo -n true && test -w /workspace"],
      { user: CONTAINER_USER, timeoutMs: 60_000 },
    );
    if (result.code !== 0) throw new Error(`health check failed: ${result.stderr.trim().slice(0, 300) || `exit ${result.code}`}`);
    // Through a plain exec: the agent connection would wait for this bot's lifecycle lock.
    const ping = await this.#engine.run(
      containerName(botId),
      ["node", `${HELPER_MOUNT}/ctl.mjs`, "ping"],
      { user: CONTAINER_USER, timeoutMs: 60_000 },
    );
    if (ping.code !== 0 || !/"ok":true/.test(ping.stdout)) {
      throw new Error("health check failed: the supervisor did not answer");
    }
    await this.#options.healthCheck?.(botId);
  }

  /**
   * Update one bot in place: snapshot it (container commit + a copy of its storage, replacing the
   * previous snapshot), recreate it from that commit with the current helper, run the upgrade,
   * health-check it, and roll back to the snapshot on any failure.
   */
  updateBot(botId: string): Promise<UpdateResult> {
    return this.#locked(botId, async () => {
      const name = containerName(botId);
      const info = await this.#engine.inspectContainer(name);
      if (!info) return { botId, ok: true, skipped: true };
      const previousHelper = info.Config.Labels?.[HELPER_LABEL] ?? (await this.helper());
      const wasRunning = info.State.Running;
      const baseImage = await this.image();
      this.#connections.get(botId)?.close();
      await this.#engine.stopContainer(name, STOP_SECONDS);
      // Snapshot: only the last one is kept.
      await this.#engine.removeImage(snapshotImage(botId));
      await this.#engine.commitContainer(name, SNAPSHOT_REPO, botId);
      if (!(await this.#engine.volumeExists(snapshotVolumeName(botId)))) {
        await this.#engine.createVolume(snapshotVolumeName(botId), { ...this.#labels(), [BOT_LABEL]: botId });
      }
      await this.#copyVolume(volumeName(botId), snapshotVolumeName(botId), baseImage);
      this.#log(`bot ${botId}: snapshot taken`);
      try {
        const helper = await this.helper();
        await this.#engine.removeContainer(name);
        await this.#create(botId, snapshotImage(botId), helper);
        await this.#engine.startContainer(name);
        const upgrade = this.#options.upgradeCommand ?? DEFAULT_UPGRADE;
        const upgraded = await this.#engine.run(name, upgrade, { user: "root", timeoutMs: 30 * 60_000 });
        if (upgraded.code !== 0) {
          throw new Error(`upgrade failed (exit ${upgraded.code}): ${upgraded.stderr.trim().split("\n").slice(-3).join(" ").slice(0, 300)}`);
        }
        await this.#healthCheck(botId);
        this.touch(botId);
        this.#log(`bot ${botId}: updated`);
        return { botId, ok: true };
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.#log(`bot ${botId}: update failed, rolling back: ${message}`);
        this.#connections.get(botId)?.close();
        await this.#engine.removeContainer(name);
        await this.#copyVolume(snapshotVolumeName(botId), volumeName(botId), baseImage);
        await this.#create(botId, snapshotImage(botId), previousHelper);
        if (wasRunning) {
          await this.#engine.startContainer(name);
          this.touch(botId);
        }
        return { botId, ok: false, rolledBack: true, error: message };
      }
    });
  }

  /** Recreate a bot from a clean image, keeping its storage (and its restart list in it). */
  rebuild(botId: string): Promise<void> {
    return this.#locked(botId, async () => {
      this.#connections.get(botId)?.close();
      await this.#engine.removeContainer(containerName(botId));
      await this.#ensureUnlocked(botId);
      this.#log(`bot ${botId}: rebuilt from ${await this.image()}`);
    });
  }

  /** Drop agent connections (runtime shutdown); containers keep running. */
  close(): void {
    this.#closed = true;
    if (this.#idleTimer) clearInterval(this.#idleTimer);
    this.#idleTimer = undefined;
    for (const connection of this.#connections.values()) connection.close();
    this.#connections.clear();
  }

  async shutdown(): Promise<void> {
    this.close();
  }
}
