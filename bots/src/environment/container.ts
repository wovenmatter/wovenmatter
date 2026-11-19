import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Context } from "@earendil-works/chord/context";
import { randomUUID } from "node:crypto";
import { Duplex } from "node:stream";
import type { BotEnvironmentAdapter, HarnessEnvFactory } from "../env.ts";
import { type ContainerInfo, type ContainerSummary, type DockerEngineAPI, EngineError, type ExecProcess } from "./engine-api.ts";
import {
  BASELINE,
  CAPTURE,
  CARRY_DIR,
  HOME_DIR,
  CHROMIUM_DEPS,
  CHROMIUM_PROBE,
  PENDING_MARKER,
  REAPPLY,
  REBUILD_SYSTEM_PACKAGES,
  REBUILD_USER_PACKAGES,
} from "./carry.ts";
import {
  contentHash,
  ensureImage,
  ensureSharedHelper,
  ensureSharedToolchain,
  HELPER_LABEL,
  HELPER_MOUNT,
  helperArchive,
  helperDir,
  IMAGE_DIR,
  imageContext,
  imageTag,
  type ImageTools,
  imageTools,
  pruneShared,
  SHARED_MOUNT,
  SHARED_VOLUME,
  TOOLCHAIN_PATH,
  toolchainContext,
  toolchainDir,
  toolchainImageName,
} from "./images.ts";
import { createTar } from "./tar.ts";
import { createInterface } from "node:readline";
import { CONTAINER_GIT_DIRECTORY, type GitSetup, gitAgentSocket, gitDigest, gitEnvironment, gitFiles, WRITE_GIT_FILES } from "../host/git.ts";
import { AgentConnection, type AgentProcess, RemoteExecutionEnv } from "./remote.ts";

export const CONTAINER_USER = "bot";
export const WORKSPACE = "/workspace";
export const BOT_LABEL = "woven.bot";
/** The bot image a container was made from (its tag), kept through in-place updates. */
export const IMAGE_LABEL = "woven.bots.image";
export const MACHINE_LABEL = "woven.bots.machine";
/**
 * Whether a container is in the current layout: it mounts the shared volume at /opt/woven (its
 * helper and toolchain are links into it, and its home folder is in storage). One that does not
 * was made before that and moves on its next update. The container itself says so, in what the
 * engine reports of its mounts.
 */
export const usesSharedVolume = (mounts: ContainerInfo["Mounts"]): boolean =>
  (mounts ?? []).some((mount) => mount.Name === SHARED_VOLUME && mount.Destination === SHARED_MOUNT);
/** The contract's fixed idle period: a bot stops fully after 15 minutes idle. */
export const IDLE_STOP_MS = 15 * 60_000;
const AGENT_COMMAND = ["node", `${HELPER_MOUNT}/agent.mjs`];
const SHM_BYTES = 512 * 1024 * 1024;
/**
 * Default capabilities a bot never needs. Without NET_RAW a bot cannot forge packets or spoof ARP
 * on the bot network (ping stops working); MKNOD is device creation. sudo (SETUID, SETGID,
 * AUDIT_WRITE), apt (CHOWN, DAC_OVERRIDE, FOWNER, SETFCAP) and Chromium (Playwright launches it
 * without its sandbox) keep everything else Docker grants by default.
 */
export const DROPPED_CAPABILITIES = ["NET_RAW", "MKNOD"] as const;
const STOP_SECONDS = 20;
/** How long a container start waits for an engine that is coming back (a Mac VM rebooting). */
const ENGINE_WAIT_MS = 90_000;
const ENGINE_POLL_MS = 500;
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
  /**
   * It moved to a new base image (a new Ubuntu release or system libraries): its own system
   * changes were carried across. Node, Playwright and Chromium update without moving.
   */
  readonly movedToImage?: boolean;
  readonly rolledBack?: boolean;
  readonly error?: string;
};

/** What a rollback needs to recreate the old container from its snapshot. */
type ContainerSpecCopy = {
  readonly labels: Record<string, string>;
  readonly mounts: readonly { Type: string; Source: string; Target: string; ReadOnly?: boolean }[];
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
  /** How long a container start waits for an unavailable engine (tests shorten it). */
  readonly engineWaitMs?: number;
  /** Settings → GitHub for one bot, from the host (undefined: no answer yet), written into its container. */
  readonly git?: (botId: string) => Promise<GitSetup | undefined>;
  /** Where in the container the files go (tests use a host path). */
  readonly gitDirectory?: string;
  /** One SSH agent request from a bot's relay, answered by the machine's signing agent. */
  readonly sshAgent?: (botId: string, message: Buffer) => Promise<Buffer>;
  readonly log?: (message: string) => void;
};

/**
 * The engine is not there right now but may come back: a Mac VM answers 503 while it boots, and
 * its socket refuses connections while the helper restarts. Other errors are real failures.
 */
export function engineUnavailable(error: unknown): boolean {
  return error instanceof EngineError && (error.status === undefined || error.status === 503);
}

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
      // The SSH agent relay waits for git; it is not work of its own.
      if (row.args.includes(`${HELPER_MOUNT}/ssh-agent.mjs`)) return false;
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
  #toolchainImage: Promise<string> | undefined;
  #currentTag: Promise<string> | undefined;
  #currentToolchain: Promise<string> | undefined;
  #shared: Promise<{ readonly helper: string; readonly toolchain: string }> | undefined;
  #helperHash: Promise<string> | undefined;
  /** Updates and rebuilds in progress: pruning waits until none is (a rollback needs its mounts). */
  #changing = 0;
  /** Volumes an update in progress may restore its old container with; never pruned meanwhile. */
  readonly #restoring = new Set<string>();
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
      return new RemoteExecutionEnv(`woven:${containerName(botId)}`, cwd, this.#connection(botId), () =>
        this.#syncGit(botId),
      );
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
          // A new agent may be in a new (or restarted) container: always write before it starts.
          await this.#syncGit(botId, true);
          return this.#engine.spawn(containerName(botId), AGENT_COMMAND, {
            user: CONTAINER_USER,
            workdir: WORKSPACE,
            ...(this.#options.git
              ? { env: Object.entries(gitEnvironment(this.#options.gitDirectory)).map(([key, value]) => `${key}=${value}`) }
              : {}),
          }) as unknown as AgentProcess;
        },
        this.#log,
        () => this.touch(botId),
      );
      this.#connections.set(botId, connection);
    }
    return connection;
  }

  /** Each bot's SSH agent relay (helper/ssh-agent.mjs) and whether it is listening. */
  readonly #relays = new Map<string, { readonly process: AgentProcess; readonly ready: Promise<boolean> }>();
  /** When a bot's relay last failed to start, so the next attempt waits a minute. */
  readonly #relayFailed = new Map<string, number>();

  /**
   * The bot's relay, started if needed; true once it listens. git's ssh in the container asks it,
   * it asks here, and the machine's signing agent answers (the key never enters the container).
   */
  #relay(botId: string): Promise<boolean> {
    const answer = this.#options.sshAgent;
    if (!answer) return Promise.resolve(false);
    const current = this.#relays.get(botId);
    if (current) return current.ready;
    if (Date.now() - (this.#relayFailed.get(botId) ?? 0) < 60_000) return Promise.resolve(false);
    let relay: AgentProcess;
    try {
      relay = this.#engine.spawn(containerName(botId), ["node", `${HELPER_MOUNT}/ssh-agent.mjs`, gitAgentSocket(this.#options.gitDirectory)], {
        user: CONTAINER_USER,
      }) as unknown as AgentProcess;
    } catch {
      this.#relayFailed.set(botId, Date.now());
      return Promise.resolve(false);
    }
    let settle: (ready: boolean) => void = () => {};
    const ready = new Promise<boolean>((resolve) => {
      settle = resolve;
    });
    let listening = false;
    // Not listening in time: stop it and try again later, rather than keep a relay that may
    // start listening after its answer was already "no".
    const timeout = setTimeout(() => {
      if (listening) return;
      this.#relayFailed.set(botId, Date.now());
      settle(false);
      if (this.#relays.get(botId)?.process === relay) this.#relays.delete(botId);
      relay.kill();
    }, 20_000);
    timeout.unref?.();
    this.#relays.set(botId, { process: relay, ready });
    const ended = () => {
      clearTimeout(timeout);
      if (!listening) this.#relayFailed.set(botId, Date.now());
      settle(false);
      if (this.#relays.get(botId)?.process === relay) this.#relays.delete(botId);
      // github.conf names a socket nobody answers now: write the files again before the next command.
      this.#gitWritten.delete(botId);
    };
    relay.once("exit", ended);
    relay.once("error", ended);
    createInterface({ input: relay.stdout }).on("line", (line) => {
      let request: { id?: unknown; m?: unknown; ready?: unknown };
      try {
        request = JSON.parse(line) as { id?: unknown; m?: unknown; ready?: unknown };
      } catch {
        return;
      }
      if (request.ready === true) {
        listening = true;
        clearTimeout(timeout);
        this.#relayFailed.delete(botId);
        settle(true);
        return;
      }
      if (typeof request.id !== "number" || typeof request.m !== "string") return;
      const id = request.id;
      answer(botId, Buffer.from(request.m, "base64"))
        .catch(() => Buffer.from([5]))
        .then((reply) => relay.stdin.write(`${JSON.stringify({ id, m: reply.toString("base64") })}\n`))
        .catch(() => {});
    });
    return ready;
  }

  /** The setup digest last written into each running bot's container. */
  readonly #gitWritten = new Map<string, string>();

  /**
   * Writes Settings → GitHub into the bot's container when it changed (the host is asked at most
   * once a minute). Never fails a tool call: a bot without the files just uses its own git setup.
   */
  async #syncGit(botId: string, force = false): Promise<void> {
    if (!this.#options.git) return;
    if (force) this.#gitWritten.delete(botId);
    try {
      const answered = await this.#options.git(botId);
      if (!answered) return;
      // github.conf names the relay's socket: without a listening relay, the files keep the
      // user's own SSH settings and HTTPS remotes as they are.
      const setup = answered.publicKey && !(await this.#relay(botId)) ? { ...answered, publicKey: null } : answered;
      const digest = gitDigest(setup);
      if (!force && this.#gitWritten.get(botId) === digest) return;
      const directory = this.#options.gitDirectory ?? CONTAINER_GIT_DIRECTORY;
      const input = JSON.stringify({ directory, files: gitFiles(setup, directory) });
      const result = await this.#engine.run(containerName(botId), WRITE_GIT_FILES, {
        user: CONTAINER_USER,
        input,
        timeoutMs: 20_000,
      });
      if (result.code !== 0) throw new Error(result.stderr.trim() || `exit ${result.code}`);
      this.#gitWritten.set(botId, digest);
    } catch (error) {
      this.#log(`bot ${botId}: GitHub settings not written: ${error instanceof Error ? error.message : String(error)}`);
    }
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

  /** The toolchain image (Node, npm, Playwright, Chromium), built from bots/image/toolchain. */
  toolchainImage(): Promise<string> {
    if (!this.#toolchainImage) {
      const dir = this.#options.imageDir ?? IMAGE_DIR;
      const pending = (async () =>
        ensureImage(this.#engine, toolchainImageName(this.#options.imageName), this.#log, dir, await toolchainContext(dir)))();
      this.#toolchainImage = pending;
      pending.catch(() => {
        if (this.#toolchainImage === pending) this.#toolchainImage = undefined;
      });
    }
    return this.#toolchainImage;
  }

  /** This runtime's helper and toolchain in the shared volume (each named by its content hash). */
  shared(): Promise<{ readonly helper: string; readonly toolchain: string }> {
    if (!this.#shared) {
      const pending = (async () => {
        const [image, toolchain] = await Promise.all([this.image(), this.toolchainImage()]);
        return {
          helper: await ensureSharedHelper(this.#engine, image, this.#labels(), await helperArchive()),
          toolchain: await ensureSharedToolchain(this.#engine, toolchain, this.#labels(), await this.currentToolchain()),
        };
      })();
      this.#shared = pending;
      pending.catch(() => {
        if (this.#shared === pending) this.#shared = undefined;
      });
    }
    return this.#shared;
  }

  /** This runtime's helper (its shared directory's hash). */
  async helper(): Promise<string> {
    return (await this.shared()).helper;
  }

  /** The links that select a helper and toolchain, extracted at the container's root. */
  #links(shared: { readonly helper: string; readonly toolchain: string }): Buffer {
    return createTar([
      { path: HELPER_MOUNT.slice(1), link: helperDir(shared.helper) },
      { path: TOOLCHAIN_PATH.slice(1), link: toolchainDir(shared.toolchain) },
    ]);
  }

  async state(botId: string): Promise<"missing" | "running" | "stopped"> {
    const info = await this.#engine.inspectContainer(containerName(botId));
    if (!info) return "missing";
    return info.State.Running ? "running" : "stopped";
  }

  /** The current bot image's tag, without building it. */
  async currentImageTag(): Promise<string> {
    this.#currentTag ??= imageContext(this.#options.imageDir ?? IMAGE_DIR).then((context) =>
      imageTag(this.#options.imageName, context),
    );
    return this.#currentTag;
  }

  /** The current toolchain's shared directory name, without building it. */
  async currentToolchain(): Promise<string> {
    const dir = this.#options.imageDir ?? IMAGE_DIR;
    // Named by content even for an explicitly tagged image, so a changed recipe is never mistaken
    // for the directory an older one filled.
    this.#currentToolchain ??= toolchainContext(dir).then(contentHash);
    return this.#currentToolchain;
  }

  /**
   * The current image's tools; the bots that move to a new base image on their next update
   * (`staleBots`); and every bot whose next update changes something (`outdatedBots`: those, and
   * the ones on an older toolchain or helper).
   */
  async imageStatus(): Promise<{ tag: string; tools: ImageTools; staleBots: string[]; outdatedBots: string[] }> {
    const tag = await this.currentImageTag();
    const toolchain = toolchainDir(await this.currentToolchain());
    this.#helperHash ??= helperArchive().then((archive) => archive.hash);
    const helper = helperDir(await this.#helperHash);
    const staleBots: string[] = [];
    const outdatedBots: string[] = [];
    for (const container of await this.#engine.listContainers(BOT_LABEL)) {
      const botId = container.Labels[BOT_LABEL];
      if (!botId || container.Labels[MACHINE_LABEL] !== this.#options.machineId) continue;
      if (!usesSharedVolume(await this.#mountsOf(container)) || container.Labels[IMAGE_LABEL] !== tag) {
        staleBots.push(botId);
        outdatedBots.push(botId);
        continue;
      }
      const name = containerName(botId);
      const [tools, runtime, pending] = await Promise.all([
        this.#engine.linkTarget(name, TOOLCHAIN_PATH).catch(() => undefined),
        this.#engine.linkTarget(name, HELPER_MOUNT).catch(() => undefined),
        this.#engine.pathExists(name, PENDING_MARKER).catch(() => false),
      ]);
      if (tools !== toolchain || runtime !== helper || pending) outdatedBots.push(botId);
    }
    return { tag, tools: await imageTools(this.#options.imageDir ?? IMAGE_DIR), staleBots, outdatedBots };
  }

  /** A listed container's mounts; an engine whose list leaves them out is asked for them. */
  async #mountsOf(container: ContainerSummary): Promise<ContainerInfo["Mounts"]> {
    return container.Mounts ?? (await this.#engine.inspectContainer(container.Id))?.Mounts;
  }

  /** A new container of the base image `image`, in the current layout. */
  async #create(botId: string, image: string): Promise<void> {
    const memory = this.#options.memoryBytes;
    await this.#engine.createContainer(containerName(botId), {
      Image: image,
      Hostname: `bot-${botId.slice(0, 8)}`,
      User: CONTAINER_USER,
      WorkingDir: WORKSPACE,
      // Settings → GitHub: every process in the container (keep_running services too) finds the files.
      Env: [
        `WOVEN_BOT_ID=${botId}`,
        ...(this.#options.git
          ? Object.entries(gitEnvironment(this.#options.gitDirectory)).map(([key, value]) => `${key}=${value}`)
          : []),
      ],
      Labels: { ...this.#labels(), [BOT_LABEL]: botId, [IMAGE_LABEL]: image },
      StopTimeout: STOP_SECONDS,
      HostConfig: {
        Mounts: [
          { Type: "volume", Source: volumeName(botId), Target: WORKSPACE },
          { Type: "volume", Source: SHARED_VOLUME, Target: SHARED_MOUNT, ReadOnly: true },
        ],
        RestartPolicy: { Name: "no" },
        CapDrop: [...DROPPED_CAPABILITIES],
        ShmSize: SHM_BYTES,
        ...(memory ? { Memory: memory, MemorySwap: memory } : {}),
      },
    });
  }

  /** The container a rollback restores: the snapshot, with the old container's own mounts and labels. */
  async #restore(botId: string, previous: ContainerSpecCopy): Promise<void> {
    const memory = this.#options.memoryBytes;
    await this.#engine.createContainer(containerName(botId), {
      Image: snapshotImage(botId),
      Hostname: `bot-${botId.slice(0, 8)}`,
      User: CONTAINER_USER,
      WorkingDir: WORKSPACE,
      Env: [`WOVEN_BOT_ID=${botId}`],
      Labels: previous.labels,
      StopTimeout: STOP_SECONDS,
      HostConfig: {
        Mounts: previous.mounts,
        RestartPolicy: { Name: "no" },
        CapDrop: [...DROPPED_CAPABILITIES],
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

  /**
   * Inspect, waiting a bounded time for an engine that is unavailable (a VM reboot or update), so
   * a tool call made meanwhile resumes once it is back instead of failing. Nothing about the
   * outage is remembered: a call after a longer one simply asks the engine again.
   */
  async #inspectWhenAvailable(name: string) {
    const deadline = Date.now() + (this.#options.engineWaitMs ?? ENGINE_WAIT_MS);
    for (;;) {
      try {
        return await this.#engine.inspectContainer(name);
      } catch (error) {
        if (!engineUnavailable(error) || Date.now() >= deadline || this.#closed) throw error;
      }
      await new Promise((resolve) => setTimeout(resolve, ENGINE_POLL_MS));
    }
  }

  async #ensureUnlocked(botId: string): Promise<void> {
    const name = containerName(botId);
    // A container found stopped (idle, stopped by the user, or killed with the engine's VM) is
    // started as it is: its filesystem and storage are intact, and its supervisor brings the
    // restart list and saved tabs back. Only a missing container is created.
    let info = await this.#inspectWhenAvailable(name);
    if (!info) {
      const [image, shared] = [await this.image(), await this.shared()];
      if (!(await this.#engine.volumeExists(volumeName(botId)))) {
        await this.#engine.createVolume(volumeName(botId), { ...this.#labels(), [BOT_LABEL]: botId });
      }
      await this.#create(botId, image);
      try {
        await this.#engine.putArchive(name, "/", this.#links(shared));
      } catch (error) {
        // A container without its links could never start: leave none behind.
        await this.#engine.removeContainer(name).catch(() => {});
        throw error;
      }
      this.#log(`bot ${botId}: created container ${name}`);
      info = await this.#engine.inspectContainer(name);
      if (!info?.State.Running) await this.#engine.startContainer(name);
      // A move that stopped partway left its captured changes waiting: apply them now.
      await this.#resumePending(botId);
      this.#log(`bot ${botId}: started container ${name}`);
      this.touch(botId);
      return;
    }
    if (!info.State.Running) {
      const current = usesSharedVolume(info.Mounts);
      if (current) await this.#healLinks(botId);
      await this.#engine.startContainer(name);
      // A move that stopped after its new container was made: apply what it captured, then start
      // again so the restart list comes back with it.
      if (current && (await this.#resumePending(botId))) {
        await this.#engine.stopContainer(name, STOP_SECONDS);
        await this.#engine.startContainer(name);
      }
      this.#log(`bot ${botId}: started container ${name}`);
    }
    this.touch(botId);
  }

  /**
   * A current-layout container whose links are missing (interrupted while they were written)
   * gets the current ones, so it can start.
   */
  async #healLinks(botId: string): Promise<void> {
    const name = containerName(botId);
    const [runtime, tools] = await Promise.all([
      this.#engine.linkTarget(name, HELPER_MOUNT),
      this.#engine.linkTarget(name, TOOLCHAIN_PATH),
    ]);
    if (runtime && tools) return;
    await this.#engine.putArchive(name, "/", this.#links(await this.shared()));
    this.#log(`bot ${botId}: restored its helper and toolchain links`);
  }

  /** Apply captured changes a move left waiting (the runtime stopped before it applied them). */
  async #resumePending(botId: string): Promise<boolean> {
    const name = containerName(botId);
    if (!(await this.#engine.pathExists(name, PENDING_MARKER).catch(() => false))) return false;
    this.#log(`bot ${botId}: applying the changes carried from its previous container`);
    await this.#engine.run(name, ["sh", "-c", REAPPLY], { user: "root", timeoutMs: 60 * 60_000 });
    return true;
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
        // Stopped from outside (a VM reboot): drop an agent stream that may not have noticed, so
        // the next call starts the container and a fresh agent. A call that just touched the bot
        // may be waiting for this lock to start it; leave that one alone.
        const touched = this.#lastUse.get(botId);
        if (touched !== undefined && Date.now() - touched < this.idleMs) return false;
        this.#connections.get(botId)?.close();
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
    void this.shared()
      .then(() => this.#prune())
      .catch((error: unknown) => this.#log(`bot image: ${(error as Error).message}`));
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

  /** Prune helper volumes and shared directories, unless an update or rebuild is running. */
  async #prune(): Promise<void> {
    if (this.#changing > 0) return;
    await this.pruneHelpers();
    await this.pruneShared();
  }

  /**
   * Remove this machine's helper volumes from before the shared volume that no container uses any
   * more (a container that still mounts one keeps it until it moves).
   */
  async pruneHelpers(): Promise<string[]> {
    if (this.#changing > 0) return [];
    const removed: string[] = [];
    for (const volume of await this.#engine.listVolumes(HELPER_LABEL)) {
      // An update that started meanwhile may need this volume to roll its bot back.
      if (this.#changing > 0) break;
      if (this.#restoring.has(volume.Name)) continue;
      if (volume.Labels?.[MACHINE_LABEL] !== this.#options.machineId) continue;
      if (await this.#engine.removeVolume(volume.Name).catch(() => false)) removed.push(volume.Name);
    }
    return removed;
  }

  /** Remove shared helper and toolchain directories that neither this runtime nor any bot uses. */
  async pruneShared(): Promise<string[]> {
    if (this.#changing > 0) return [];
    const shared = await this.shared();
    const keep = new Set([`helper/${shared.helper}`, `toolchain/${shared.toolchain}`]);
    try {
      for (const container of await this.#engine.listContainers(BOT_LABEL)) {
        // Every container on this engine (any machine's) that mounts the shared volume.
        if (!container.Labels[BOT_LABEL] || !usesSharedVolume(await this.#mountsOf(container))) continue;
        for (const path of [HELPER_MOUNT, TOOLCHAIN_PATH]) {
          const target = await this.#engine.linkTarget(container.Id, path);
          if (target?.startsWith(`${SHARED_MOUNT}/`)) keep.add(target.slice(SHARED_MOUNT.length + 1));
        }
      }
    } catch (error) {
      // An unknown link might name a directory a bot runs from: prune nothing.
      this.#log(`bot image: not pruning shared directories: ${(error as Error).message}`);
      return [];
    }
    // A container being created or updated right now links to the current directories, kept above.
    if (this.#changing > 0) return [];
    return pruneShared(this.#engine, await this.image(), this.#labels(), keep);
  }

  // --- updates ---------------------------------------------------------------------------------

  /** Copy one volume's contents over another's, through a short-lived container. */
  async #copyVolume(from: string, to: string, image: string): Promise<void> {
    const name = `woven-bots-copy-${Date.now().toString(36)}`;
    await this.#engine.createContainer(name, {
      Image: image,
      User: "root",
      Entrypoint: ["sh", "-c"],
      // Into a staging folder first: a copy that fails (a full disk) leaves the destination whole.
      Cmd: [
        "set -e; rm -rf /dst/.woven-incoming; mkdir /dst/.woven-incoming; cp -a /src/. /dst/.woven-incoming/; " +
          "find /dst -mindepth 1 -maxdepth 1 ! -name .woven-incoming -exec rm -rf {} +; " +
          "find /dst/.woven-incoming -mindepth 1 -maxdepth 1 -exec mv {} /dst/ \\;; rmdir /dst/.woven-incoming",
      ],
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

  /** Run `script` as root in a short-lived container of `image`, with the bot's storage. */
  async #runWithStorage(botId: string, image: string, script: string, kind: string): Promise<void> {
    const name = `woven-bots-${kind}-${randomUUID().slice(0, 8)}`;
    await this.#engine.createContainer(name, {
      Image: image,
      User: "root",
      Entrypoint: ["sh", "-c"],
      Cmd: [script],
      // A snapshot's labels say it is a bot; this container is not one.
      Labels: { ...this.#labels(), [BOT_LABEL]: "", "woven.bots.temporary": kind },
      HostConfig: {
        Mounts: [{ Type: "volume", Source: volumeName(botId), Target: WORKSPACE }],
        NetworkMode: "none",
      },
    });
    try {
      await this.#engine.startContainer(name);
      const code = await this.#engine.waitContainer(name);
      if (code !== 0) throw new Error(`${kind} exited ${code}`);
    } finally {
      await this.#engine.removeContainer(name).catch(() => {});
    }
  }

  /**
   * Record what the bot changed in its old container (from its snapshot) in its storage, against
   * the base image that container came from (or, when that image is gone, the new one).
   */
  async #capture(botId: string, previousBase: string, base: string): Promise<void> {
    const baseline =
      previousBase !== "unknown" && (await this.#engine.imageExists(previousBase).catch(() => false)) ? previousBase : base;
    await this.#runWithStorage(botId, baseline, BASELINE, "baseline");
    await this.#runWithStorage(botId, snapshotImage(botId), CAPTURE, "capture");
  }

  /** Chromium starts with the bot's toolchain; installing its system libraries once if not. */
  async #checkChromium(botId: string): Promise<void> {
    const name = containerName(botId);
    const probe = () => this.#engine.run(name, ["sh", "-c", CHROMIUM_PROBE], { user: CONTAINER_USER, timeoutMs: 120_000 });
    if ((await probe()).code === 0) return;
    this.#log(`bot ${botId}: Chromium did not start; installing its system libraries`);
    const deps = await this.#engine.run(name, ["sh", "-c", CHROMIUM_DEPS], { user: "root", timeoutMs: 20 * 60_000 });
    const again = deps.code === 0 ? await probe() : deps;
    if (again.code !== 0) {
      throw new Error(`Chromium did not start: ${again.stderr.trim().split("\n").slice(-2).join(" ").slice(0, 300) || `exit ${again.code}`}`);
    }
  }

  /**
   * Update one bot behind a snapshot (a container commit and a copy of its storage, replacing the
   * previous one), rolling back to it on any failure.
   *
   * - **In place** (same base image): its links move to the current helper and toolchain (Node,
   *   npm, Playwright, Chromium) and its Ubuntu packages are upgraded. The container stays, with
   *   everything the bot installed in it.
   * - **Moving** (a new base image, a container from before the current layout, or a rebuild):
   *   what the bot changed in its container is recorded in its storage from the snapshot, the
   *   container is recreated from the base image, and those changes are applied there. Storage,
   *   home folder and browser profile stay as they are.
   */
  updateBot(botId: string): Promise<UpdateResult> {
    return this.#locked(botId, () => this.#update(botId, false));
  }

  async #update(botId: string, rebuild: boolean): Promise<UpdateResult> {
    const name = containerName(botId);
    const info = await this.#engine.inspectContainer(name);
    if (!info) return { botId, ok: true, skipped: true };
    this.#changing += 1;
    try {
      const labels = info.Config.Labels ?? {};
      const previous: ContainerSpecCopy = {
        labels,
        mounts: (info.Mounts ?? []).map((mount) => ({
          Type: "volume",
          Source: mount.Name ?? "",
          Target: mount.Destination,
          ...(mount.RW === false ? { ReadOnly: true } : {}),
        })),
      };
      for (const mount of previous.mounts) this.#restoring.add(mount.Source);
      const previousBase = labels[IMAGE_LABEL] ?? "unknown";
      const wasRunning = info.State.Running;
      const base = await this.image();
      const shared = await this.shared();
      const moving = rebuild || !usesSharedVolume(info.Mounts) || previousBase !== base;
      const previousToolchain = moving ? undefined : await this.#engine.linkTarget(name, TOOLCHAIN_PATH).catch(() => undefined);
      this.#connections.get(botId)?.close();
      this.#gitWritten.delete(botId);
      await this.#engine.stopContainer(name, STOP_SECONDS);
      // Snapshot: only the last one is kept. It is a rollback point, never a base for the update.
      await this.#engine.removeImage(snapshotImage(botId));
      await this.#engine.commitContainer(name, SNAPSHOT_REPO, botId);
      if (!(await this.#engine.volumeExists(snapshotVolumeName(botId)))) {
        await this.#engine.createVolume(snapshotVolumeName(botId), { ...this.#labels(), [BOT_LABEL]: botId });
      }
      await this.#copyVolume(volumeName(botId), snapshotVolumeName(botId), base);
      this.#log(`bot ${botId}: snapshot taken`);
      try {
        if (moving) {
          await this.#capture(botId, previousBase, base);
          await this.#engine.removeContainer(name);
          await this.#create(botId, base);
        }
        await this.#engine.putArchive(name, "/", this.#links(shared));
        await this.#engine.startContainer(name);
        const upgrade = this.#options.upgradeCommand ?? DEFAULT_UPGRADE;
        const upgraded = await this.#engine.run(name, upgrade, { user: "root", timeoutMs: 30 * 60_000 });
        if (upgraded.code !== 0) {
          throw new Error(`upgrade failed (exit ${upgraded.code}): ${upgraded.stderr.trim().split("\n").slice(-3).join(" ").slice(0, 300)}`);
        }
        // A move applies what it captured (the capture left it pending); an earlier move that
        // stopped partway resumes here.
        if (await this.#resumePending(botId)) {
          // Its restart list comes back with everything it relies on installed.
          await this.#engine.stopContainer(name, STOP_SECONDS);
          await this.#engine.startContainer(name);
        }
        if (moving || previousToolchain !== toolchainDir(shared.toolchain)) {
          await this.#checkChromium(botId);
          if (!moving) {
            await this.#engine.run(name, ["sh", "-c", REBUILD_SYSTEM_PACKAGES], { user: "root", timeoutMs: 30 * 60_000 });
            await this.#engine.run(name, ["sh", "-c", REBUILD_USER_PACKAGES], { user: CONTAINER_USER, timeoutMs: 30 * 60_000 });
          }
        }
        await this.#healthCheck(botId);
        this.touch(botId);
        this.#log(
          rebuild
            ? `bot ${botId}: rebuilt from ${base}`
            : moving
              ? `bot ${botId}: updated and moved to ${base}`
              : `bot ${botId}: updated`,
        );
        return moving && !rebuild ? { botId, ok: true, movedToImage: true } : { botId, ok: true };
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        this.#log(`bot ${botId}: ${rebuild ? "rebuild" : "update"} failed, rolling back: ${message}`);
        this.#connections.get(botId)?.close();
        await this.#engine.removeContainer(name);
        // The container comes back even when its storage cannot (the copy leaves it whole).
        let storage: string | undefined;
        try {
          await this.#copyVolume(snapshotVolumeName(botId), volumeName(botId), base);
        } catch (copyError) {
          storage = copyError instanceof Error ? copyError.message : String(copyError);
          this.#log(`bot ${botId}: restoring its storage failed; it keeps its current files: ${storage}`);
          // What this attempt added to storage must not outlive it: a home folder copied in for
          // the old container (which still uses its own) would be taken as current next time.
          await this.#runWithStorage(
            botId,
            base,
            `if [ -f ${CARRY_DIR}/home-migrated ]; then rm -rf ${HOME_DIR}; fi; rm -rf ${CARRY_DIR} ${WORKSPACE}/.woven-incoming`,
            "discard",
          ).catch(() => {});
        }
        await this.#restore(botId, previous);
        if (wasRunning) {
          await this.#engine.startContainer(name);
          this.touch(botId);
        }
        return {
          botId,
          ok: false,
          rolledBack: true,
          error: storage ? `${message} (its storage could not be restored and kept its current files: ${storage})` : message,
        };
      }
    } finally {
      for (const mount of info.Mounts ?? []) if (mount.Name) this.#restoring.delete(mount.Name);
      this.#changing -= 1;
      if (this.#changing === 0) void this.#prune().catch(() => {});
    }
  }

  /**
   * Recreate a bot from a clean base image, behind a snapshot, keeping its storage, home folder
   * and browser profile, and carrying over what it installed in its container (as a move does).
   */
  rebuild(botId: string): Promise<void> {
    return this.#locked(botId, async () => {
      const result = await this.#update(botId, true);
      if (result.skipped) await this.#ensureUnlocked(botId);
      else if (!result.ok) throw new Error(`rebuild failed and was rolled back: ${result.error ?? "unknown error"}`);
    });
  }

  /** Drop agent connections (runtime shutdown); containers keep running. */
  close(): void {
    this.#closed = true;
    if (this.#idleTimer) clearInterval(this.#idleTimer);
    this.#idleTimer = undefined;
    for (const connection of this.#connections.values()) connection.close();
    this.#connections.clear();
    for (const relay of this.#relays.values()) relay.process.kill();
    this.#relays.clear();
  }

  async shutdown(): Promise<void> {
    this.close();
  }
}
