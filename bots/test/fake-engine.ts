import { type ChildProcess, execFile, spawn } from "node:child_process";
import { rmSync } from "node:fs";
import { mkdir, rm } from "node:fs/promises";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Socket } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";
import { socketDirectory } from "./helpers.ts";

const HELPER = fileURLToPath(new URL("../helper/", import.meta.url));

type Container = {
  id: string;
  name: string;
  spec: Record<string, unknown>;
  running: boolean;
  image: string;
  labels: Record<string, string>;
  supervisor?: ChildProcess;
  /** Exit code after it stopped; 137 after a `crash`. */
  exitCode?: number;
  /** Exec streams into it, dropped by a `crash`. */
  streams: Set<{ socket: Socket; child?: ChildProcess }>;
};

/**
 * A Docker Engine API stand-in on a Unix socket, for portable tests: images, volumes and
 * containers in memory; a container "runs" the real helper supervisor locally (its storage
 * volume is a temp directory); exec runs real local processes over the same hijacked,
 * multiplexed stream protocol Docker uses. Commands are mapped by `exec`.
 */
export class FakeEngine {
  readonly socketPath: string;
  readonly root: string;
  /** Holds the engine and supervisor sockets; see `socketDirectory`. */
  readonly socketDir: string;
  /** stderr of every helper process, for diagnosing a failed test. */
  readonly helperLog: string[] = [];
  readonly images = new Set<string>();
  readonly volumes = new Map<string, Record<string, string>>();
  readonly containers = new Map<string, Container>();
  readonly requests: string[] = [];
  readonly execs = new Map<string, { container: string; cmd: string[]; user?: string; env?: string[]; exitCode: number | null; running: boolean }>();
  /** Output for `ps -eo pid=,ppid=,args=`; undefined makes the check fail. */
  ps: string | undefined = "    1     0 /usr/bin/tini -- node /opt/woven-bot/supervisor.mjs\n";
  /** Exit code of the update's upgrade command. */
  upgradeExit = 0;
  builds = 0;
  /** Answer every request 503, as a Mac VM's socket does while the VM boots. */
  unavailable = false;
  /** Extra environment for each container's supervisor (and so its browser). */
  supervisorEnv: Record<string, string> = {};
  #server: Server | undefined;
  #next = 1;

  constructor(root: string) {
    this.root = root;
    this.socketDir = socketDirectory(root);
    this.socketPath = join(this.socketDir, "engine.sock");
  }

  volumeDir(name: string): string {
    return join(this.root, "volumes", name);
  }

  controlSocket(name: string): string {
    return join(this.socketDir, `${(this.containers.get(name)?.id ?? name).slice(0, 8)}.sock`);
  }

  async start(): Promise<void> {
    this.#server = createServer((request, response) => void this.#handle(request, response));
    this.#server.on("upgrade", (request: IncomingMessage, socket: Socket, head: Buffer) => this.#upgrade(request, socket, head));
    // A listen error (a path over sun_path, EADDRINUSE) must fail the test, not hang it.
    await new Promise<void>((resolve, reject) => {
      this.#server?.once("error", reject);
      this.#server?.listen(this.socketPath, () => {
        this.#server?.off("error", reject);
        resolve();
      });
    });
  }

  async close(): Promise<void> {
    for (const container of this.containers.values()) container.supervisor?.kill("SIGKILL");
    await new Promise<void>((resolve) => (this.#server ? this.#server.close(() => resolve()) : resolve()));
    if (this.socketDir !== this.root) rmSync(this.socketDir, { recursive: true, force: true });
  }

  #capture(child: ChildProcess, label: string): ChildProcess {
    child.stderr?.on("data", (chunk: Buffer) => {
      if (this.helperLog.length < 200) this.helperLog.push(`${label}: ${chunk.toString("utf8").trimEnd()}`);
    });
    child.on("exit", (code, signal) => {
      if (code !== 0 && signal === null) this.helperLog.push(`${label} exited ${code}`);
    });
    return child;
  }

  #json(response: ServerResponse, status: number, value?: unknown): void {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(value === undefined ? "" : JSON.stringify(value));
  }

  async #body(request: IncomingMessage): Promise<Buffer> {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(chunk as Buffer);
    return Buffer.concat(chunks);
  }

  #mountDir(container: Container, target: string): string | undefined {
    const mounts = ((container.spec.HostConfig as { Mounts?: { Source: string; Target: string }[] })?.Mounts ?? []);
    const mount = mounts.find((entry) => entry.Target === target);
    return mount ? this.volumeDir(mount.Source) : undefined;
  }

  async #startContainer(container: Container): Promise<void> {
    if (container.running) return;
    container.running = true;
    const state = this.#mountDir(container, "/workspace");
    if (!state || container.labels["woven.bots.temporary"]) return;
    await mkdir(state, { recursive: true });
    container.supervisor = spawn(process.execPath, [join(HELPER, "supervisor.mjs")], {
      env: {
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        WOVEN_STATE_DIR: join(state, ".woven"),
        WOVEN_CONTROL_SOCKET: this.controlSocket(container.name),
        ...this.supervisorEnv,
      },
      cwd: state,
      stdio: ["ignore", "ignore", "pipe"],
    });
    this.#capture(container.supervisor, `supervisor ${container.name}`);
  }

  /**
   * A power cut (a Mac VM rebooted under its containers): every process in the container dies at
   * once with no SIGTERM, and its exec streams drop. Nothing gets to clean up.
   */
  async crash(name: string): Promise<void> {
    const container = this.containers.get(name);
    if (!container?.running) return;
    const roots = [container.supervisor, ...[...container.streams].map((stream) => stream.child)]
      .map((child) => child?.pid)
      .filter((pid): pid is number => pid !== undefined);
    // Collect the whole tree first: once a parent dies its children are re-parented away.
    const { stdout } = await promisify(execFile)("ps", ["-A", "-o", "pid=,ppid="]);
    const children = new Map<number, number[]>();
    for (const line of stdout.split("\n")) {
      const [pid, ppid] = line.trim().split(/\s+/).map(Number);
      if (pid && ppid !== undefined) children.set(ppid, [...(children.get(ppid) ?? []), pid]);
    }
    const doomed = new Set<number>();
    const walk = (pid: number) => {
      if (doomed.has(pid)) return;
      doomed.add(pid);
      for (const child of children.get(pid) ?? []) walk(child);
    };
    for (const pid of roots) walk(pid);
    for (const pid of doomed) {
      try {
        process.kill(pid, "SIGKILL");
      } catch {
        // Already gone.
      }
    }
    for (const stream of container.streams) stream.socket.destroy();
    container.streams.clear();
    container.supervisor = undefined;
    container.running = false;
    container.exitCode = 137;
  }

  async #stopContainer(container: Container): Promise<void> {
    const child = container.supervisor;
    container.supervisor = undefined;
    container.running = false;
    container.exitCode = 0;
    if (child && child.exitCode === null) {
      await new Promise<void>((resolve) => {
        child.once("exit", () => resolve());
        child.kill("SIGTERM");
      });
    }
  }

  async #handle(request: IncomingMessage, response: ServerResponse): Promise<void> {
    const url = new URL(request.url ?? "/", "http://docker");
    const path = url.pathname.replace(/^\/v\d+\.\d+/, "");
    const method = request.method ?? "GET";
    this.requests.push(`${method} ${path}`);
    const body = await this.#body(request);
    const json = () => (body.length ? JSON.parse(body.toString("utf8")) : {});
    if (this.unavailable) return this.#json(response, 503, { message: "the Woven VM is starting" });
    let match: RegExpExecArray | null;
    if (path === "/version") return this.#json(response, 200, { ApiVersion: "1.47" });
    if (path === "/_ping") return void response.end("OK");
    if ((match = /^\/images\/(.+)\/json$/.exec(path))) {
      return this.#json(response, this.images.has(decodeURIComponent(match[1] ?? "")) ? 200 : 404, {});
    }
    if (method === "DELETE" && (match = /^\/images\/(.+)$/.exec(path))) {
      this.images.delete(decodeURIComponent(match[1] ?? ""));
      return this.#json(response, 200, []);
    }
    if (path === "/build") {
      this.builds += 1;
      for (const tag of url.searchParams.getAll("t")) this.images.add(tag);
      return void response.end(`${JSON.stringify({ stream: "Successfully built\n" })}\n`);
    }
    if (path === "/volumes" && method === "GET") {
      const label = JSON.parse(url.searchParams.get("filters") ?? "{}").label?.[0];
      return this.#json(response, 200, {
        Volumes: [...this.volumes]
          .filter(([, labels]) => !label || label in labels)
          .map(([Name, Labels]) => ({ Name, Labels })),
      });
    }
    if (path === "/volumes/create") {
      const spec = json();
      this.volumes.set(spec.Name, spec.Labels ?? {});
      await mkdir(this.volumeDir(spec.Name), { recursive: true });
      return this.#json(response, 201, { Name: spec.Name });
    }
    if ((match = /^\/volumes\/(.+)$/.exec(path))) {
      const name = decodeURIComponent(match[1] ?? "");
      if (method === "DELETE") {
        const used = [...this.containers.values()].some((c) =>
          ((c.spec.HostConfig as { Mounts?: { Source: string }[] })?.Mounts ?? []).some((m) => m.Source === name),
        );
        if (used) return this.#json(response, 409, { message: "volume is in use" });
        this.volumes.delete(name);
        await rm(this.volumeDir(name), { recursive: true, force: true });
        return this.#json(response, 204);
      }
      return this.#json(response, this.volumes.has(name) ? 200 : 404, { Name: name });
    }
    if (path === "/containers/create") {
      const name = url.searchParams.get("name") ?? `c${this.#next}`;
      if (this.containers.has(name)) return this.#json(response, 409, { message: "Conflict" });
      const spec = json();
      const id = `${(this.#next++).toString(16).padStart(8, "0")}${"0".repeat(56)}`;
      this.containers.set(name, { id, name, spec, running: false, image: spec.Image, labels: spec.Labels ?? {}, streams: new Set() });
      return this.#json(response, 201, { Id: id });
    }
    if (path === "/containers/json") {
      const label = JSON.parse(url.searchParams.get("filters") ?? "{}").label?.[0];
      return this.#json(
        response,
        200,
        [...this.containers.values()]
          .filter((c) => !label || label in c.labels)
          .map((c) => ({ Id: c.id, Names: [`/${c.name}`], State: c.running ? "running" : "exited", Labels: c.labels })),
      );
    }
    if (path === "/commit") {
      const repo = url.searchParams.get("repo");
      const tag = url.searchParams.get("tag");
      this.images.add(`${repo}:${tag}`);
      return this.#json(response, 201, { Id: `sha256:${repo}` });
    }
    if ((match = /^\/containers\/([^/]+)(\/.*)?$/.exec(path))) {
      const name = decodeURIComponent(match[1] ?? "");
      const action = match[2] ?? "";
      const container = this.containers.get(name);
      if (!container) return this.#json(response, 404, { message: `No such container: ${name}` });
      if (action === "/json" && method === "GET") {
        return this.#json(response, 200, {
          Id: container.id,
          Name: `/${name}`,
          Image: container.image,
          Config: { Image: container.image, Labels: container.labels },
          State: {
            Running: container.running,
            Status: container.running ? "running" : container.exitCode === undefined ? "created" : "exited",
            ExitCode: container.exitCode ?? 0,
          },
          HostConfig: container.spec.HostConfig,
        });
      }
      if (action === "/start") {
        if (container.running) return this.#json(response, 304);
        await this.#startContainer(container);
        return this.#json(response, 204);
      }
      if (action === "/stop") {
        if (!container.running) return this.#json(response, 304);
        await this.#stopContainer(container);
        return this.#json(response, 204);
      }
      if (action === "/wait") {
        // Temporary copy containers: copy the volume contents the way `cp -a` would.
        if (container.labels["woven.bots.temporary"] === "copy") {
          const src = this.#mountDir(container, "/src");
          const dst = this.#mountDir(container, "/dst");
          if (src && dst) {
            await rm(dst, { recursive: true, force: true });
            await mkdir(dst, { recursive: true });
            await new Promise<void>((resolve, reject) =>
              spawn("cp", ["-R", `${src}/.`, dst]).on("exit", (code) => (code === 0 ? resolve() : reject(new Error(`cp ${code}`)))),
            );
          }
        }
        container.running = false;
        return this.#json(response, 200, { StatusCode: 0 });
      }
      if (action === "" && method === "DELETE") {
        await this.#stopContainer(container);
        this.containers.delete(name);
        return this.#json(response, 204);
      }
      if (action === "/archive") {
        if (method === "HEAD") {
          const helper = this.#mountDir(container, "/opt/woven-bot");
          const wanted = url.searchParams.get("path") ?? "";
          const exists = helper && wanted.startsWith("/opt/woven-bot/") && this.volumes.has(helper.split("/").pop() ?? "") && this.#filled.has(helper);
          response.writeHead(exists ? 200 : 404);
          return void response.end();
        }
        const helper = this.#mountDir(container, url.searchParams.get("path") ?? "");
        if (helper) this.#filled.add(helper);
        return this.#json(response, 200);
      }
      if (action === "/exec") {
        const spec = json();
        const id = `exec${this.#next++}`;
        this.execs.set(id, { container: name, cmd: spec.Cmd, user: spec.User, env: spec.Env, exitCode: null, running: false });
        return this.#json(response, 201, { Id: id });
      }
    }
    if ((match = /^\/exec\/([^/]+)\/json$/.exec(path))) {
      const exec = this.execs.get(match[1] ?? "");
      return this.#json(response, exec ? 200 : 404, { Running: exec?.running ?? false, ExitCode: exec?.exitCode ?? null });
    }
    return this.#json(response, 404, { message: `fake engine: ${method} ${path}` });
  }

  readonly #filled = new Set<string>();

  /** What a container command does here. */
  #command(container: Container, cmd: string[]): ChildProcess | number {
    const cwd = this.#mountDir(container, "/workspace");
    const env = {
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      WOVEN_CONTROL_SOCKET: this.controlSocket(container.name),
      ...(cwd ? { WOVEN_WORKSPACE_ROOT: cwd } : {}),
    };
    const helper = (file: string, args: string[] = []) =>
      this.#capture(spawn(process.execPath, [join(HELPER, file), ...args], { env, cwd, stdio: ["pipe", "pipe", "pipe"] }), file);
    const [first, second] = cmd;
    if (first === "node" && second === "/opt/woven-bot/agent.mjs") return helper("agent.mjs");
    if (first === "node" && second === "/opt/woven-bot/forward.mjs") return helper("forward.mjs", cmd.slice(2));
    if (first === "node" && second === "/opt/woven-bot/ctl.mjs") return helper("ctl.mjs", cmd.slice(2));
    // An inline script (Settings → GitHub's file writer) runs as itself, on the host's paths.
    if (first === "node" && second === "-e") return this.#capture(spawn(process.execPath, cmd.slice(1), { env, stdio: ["pipe", "pipe", "pipe"] }), "node -e");
    if (first === "ps") {
      if (this.ps === undefined) return 1;
      return spawn("printf", ["%s", this.ps], { stdio: ["pipe", "pipe", "pipe"] });
    }
    if (first === "sh" && cmd.at(-1)?.includes("node --version")) return 0;
    if (first === "sh" && cmd.at(-1)?.includes("apt-get")) return this.upgradeExit;
    if (first === "true") return 0;
    return 127;
  }

  #upgrade(request: IncomingMessage, socket: Socket, head: Buffer): void {
    const match = /\/exec\/([^/]+)\/start$/.exec(request.url ?? "");
    const exec = match ? this.execs.get(match[1] ?? "") : undefined;
    const container = exec ? this.containers.get(exec.container) : undefined;
    if (this.unavailable) {
      socket.end("HTTP/1.1 503 Service Unavailable\r\ncontent-length: 0\r\n\r\n");
      return;
    }
    if (!exec || !container?.running) {
      socket.end("HTTP/1.1 409 Conflict\r\ncontent-length: 0\r\n\r\n");
      return;
    }
    socket.write("HTTP/1.1 101 UPGRADED\r\nContent-Type: application/vnd.docker.multiplexed-stream\r\nConnection: Upgrade\r\nUpgrade: tcp\r\n\r\n");
    // Node's parser consumes the start request's JSON body; what follows is stdin.
    const frame = (stream: number, chunk: Buffer) => {
      const header = Buffer.alloc(8);
      header[0] = stream;
      header.writeUInt32BE(chunk.length, 4);
      if (!socket.destroyed) socket.write(Buffer.concat([header, chunk]));
    };
    exec.running = true;
    const result = this.#command(container, exec.cmd);
    if (typeof result === "number") {
      exec.running = false;
      exec.exitCode = result;
      socket.end();
      return;
    }
    const child = result;
    const stream = { socket, child };
    container.streams.add(stream);
    socket.on("close", () => container.streams.delete(stream));
    const input = (chunk: Buffer) => {
      if (chunk.length) child.stdin?.write(chunk);
    };
    if (head.length) input(head);
    socket.on("data", input);
    socket.on("end", () => child.stdin?.end());
    socket.on("error", () => child.kill());
    socket.on("close", () => {
      if (child.exitCode === null) child.stdin?.end();
    });
    child.stdout?.on("data", (chunk: Buffer) => frame(1, chunk));
    child.stderr?.on("data", (chunk: Buffer) => frame(2, chunk));
    child.on("exit", (code) => {
      exec.running = false;
      exec.exitCode = code ?? 137;
      socket.end();
    });
    child.on("error", () => {
      exec.running = false;
      exec.exitCode = 127;
      socket.end();
    });
  }
}
