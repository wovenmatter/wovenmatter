import { type ChildProcess, spawn } from "node:child_process";
import { mkdir, rm } from "node:fs/promises";
import { createServer, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import type { Socket } from "node:net";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const HELPER = fileURLToPath(new URL("../helper/", import.meta.url));

type Container = {
  id: string;
  name: string;
  spec: Record<string, unknown>;
  running: boolean;
  image: string;
  labels: Record<string, string>;
  supervisor?: ChildProcess;
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
  readonly images = new Set<string>();
  readonly volumes = new Map<string, Record<string, string>>();
  readonly containers = new Map<string, Container>();
  readonly requests: string[] = [];
  readonly execs = new Map<string, { container: string; cmd: string[]; user?: string; exitCode: number | null; running: boolean }>();
  /** Output for `ps -eo pid=,ppid=,args=`; undefined makes the check fail. */
  ps: string | undefined = "    1     0 /usr/bin/tini -- node /opt/woven-bot/supervisor.mjs\n";
  /** Exit code of the update's upgrade command. */
  upgradeExit = 0;
  builds = 0;
  #server: Server | undefined;
  #next = 1;

  constructor(root: string) {
    this.root = root;
    this.socketPath = join(root, "engine.sock");
  }

  volumeDir(name: string): string {
    return join(this.root, "volumes", name);
  }

  controlSocket(name: string): string {
    return join(this.root, `${(this.containers.get(name)?.id ?? name).slice(0, 8)}.sock`);
  }

  async start(): Promise<void> {
    this.#server = createServer((request, response) => void this.#handle(request, response));
    this.#server.on("upgrade", (request: IncomingMessage, socket: Socket, head: Buffer) => this.#upgrade(request, socket, head));
    await new Promise<void>((resolve) => this.#server?.listen(this.socketPath, resolve));
  }

  async close(): Promise<void> {
    for (const container of this.containers.values()) container.supervisor?.kill("SIGKILL");
    await new Promise<void>((resolve) => (this.#server ? this.#server.close(() => resolve()) : resolve()));
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
      },
      cwd: state,
      stdio: "ignore",
    });
  }

  async #stopContainer(container: Container): Promise<void> {
    const child = container.supervisor;
    container.supervisor = undefined;
    container.running = false;
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
    if (path === "/volumes/create") {
      const spec = json();
      this.volumes.set(spec.Name, spec.Labels ?? {});
      await mkdir(this.volumeDir(spec.Name), { recursive: true });
      return this.#json(response, 201, { Name: spec.Name });
    }
    if ((match = /^\/volumes\/(.+)$/.exec(path))) {
      const name = decodeURIComponent(match[1] ?? "");
      if (method === "DELETE") {
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
      this.containers.set(name, { id, name, spec, running: false, image: spec.Image, labels: spec.Labels ?? {} });
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
          State: { Running: container.running, Status: container.running ? "running" : "exited" },
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
        this.execs.set(id, { container: name, cmd: spec.Cmd, user: spec.User, exitCode: null, running: false });
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
      spawn(process.execPath, [join(HELPER, file), ...args], { env, cwd, stdio: ["pipe", "pipe", "pipe"] });
    const [first, second] = cmd;
    if (first === "node" && second === "/opt/woven-bot/agent.mjs") return helper("agent.mjs");
    if (first === "node" && second === "/opt/woven-bot/forward.mjs") return helper("forward.mjs", cmd.slice(2));
    if (first === "node" && second === "/opt/woven-bot/ctl.mjs") return helper("ctl.mjs", cmd.slice(2));
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
