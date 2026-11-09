import { EventEmitter } from "node:events";
import { type IncomingMessage, request as httpRequest } from "node:http";
import type { Socket } from "node:net";
import { PassThrough, type Readable } from "node:stream";

/**
 * A Docker Engine API client over its Unix socket: plain HTTP for everything, and a hijacked
 * connection for exec stdio (`Upgrade: tcp`). No `docker` CLI is involved. Paths are versioned
 * with the API version the daemon reports.
 */

export class EngineError extends Error {
  override name = "EngineError";
  readonly status: number | undefined;
  constructor(message: string, status?: number) {
    super(message);
    this.status = status;
  }
}

export type RequestOptions = {
  readonly query?: Record<string, string | number | boolean | readonly string[] | undefined>;
  readonly body?: unknown;
  /** A raw body (a tar archive) with its content type. */
  readonly raw?: { readonly data: Buffer; readonly type: string };
  readonly timeoutMs?: number;
  readonly signal?: AbortSignal;
};

export type EngineResponse = { readonly status: number; readonly body: Buffer };

export type ExecOptions = {
  readonly user?: string;
  readonly workdir?: string;
  readonly env?: readonly string[];
};

export type ExecResult = { readonly code: number; readonly stdout: string; readonly stderr: string };

/** A long-lived exec: stdio streams like a child process; `kill()` closes its connection. */
export class ExecProcess extends EventEmitter {
  readonly stdin = new PassThrough();
  readonly stdout = new PassThrough();
  readonly stderr = new PassThrough();
  #socket: Socket | undefined;
  #exited = false;
  #killed = false;

  attach(socket: Socket, head: Buffer, onEnd: () => Promise<number | null>): void {
    this.#socket = socket;
    if (this.#killed) {
      socket.destroy();
      return;
    }
    const demux = new StreamDemuxer(
      (chunk) => this.stdout.write(chunk),
      (chunk) => this.stderr.write(chunk),
    );
    if (head.length) demux.push(head);
    socket.on("data", (chunk: Buffer) => demux.push(chunk));
    // stdin → the process; ending stdin half-closes the connection (Docker then closes the
    // process's stdin) while its output keeps flowing back.
    this.stdin.on("data", (chunk: Buffer) => {
      if (!socket.destroyed) socket.write(chunk);
    });
    this.stdin.on("end", () => {
      if (!socket.destroyed) socket.end();
    });
    let finished = false;
    const finish = () => {
      if (finished) return;
      finished = true;
      this.stdout.end();
      this.stderr.end();
      void onEnd()
        .catch(() => null)
        .then((code) => this.#exit(code));
    };
    socket.on("end", finish);
    socket.on("close", finish);
    socket.on("error", (error) => {
      this.emit("error", error);
      finish();
    });
  }

  fail(error: Error): void {
    this.emit("error", error);
    this.stdout.end();
    this.stderr.end();
    this.#exit(null);
  }

  #exit(code: number | null): void {
    if (this.#exited) return;
    this.#exited = true;
    this.emit("exit", code);
  }

  get exited(): boolean {
    return this.#exited;
  }

  kill(): void {
    this.#killed = true;
    this.#socket?.destroy();
  }
}

/** Docker's multiplexed exec stream: 8-byte headers (stream, 0, 0, 0, size BE) then payload. */
export class StreamDemuxer {
  #buffer: Buffer = Buffer.alloc(0);
  readonly #out: (chunk: Buffer) => void;
  readonly #err: (chunk: Buffer) => void;

  constructor(out: (chunk: Buffer) => void, err: (chunk: Buffer) => void) {
    this.#out = out;
    this.#err = err;
  }

  push(chunk: Buffer): void {
    this.#buffer = this.#buffer.length ? Buffer.concat([this.#buffer, chunk]) : chunk;
    while (this.#buffer.length >= 8) {
      const size = this.#buffer.readUInt32BE(4);
      if (this.#buffer.length < 8 + size) return;
      const stream = this.#buffer[0];
      const payload = this.#buffer.subarray(8, 8 + size);
      this.#buffer = this.#buffer.subarray(8 + size);
      if (stream === 2) this.#err(payload);
      else this.#out(payload);
    }
  }
}

function queryString(query: RequestOptions["query"]): string {
  if (!query) return "";
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(query)) {
    if (value === undefined) continue;
    if (Array.isArray(value)) for (const item of value) params.append(key, String(item));
    else params.append(key, String(value));
  }
  const text = params.toString();
  return text ? `?${text}` : "";
}

export class DockerEngineAPI {
  readonly socketPath: string;
  #version: Promise<string> | undefined;

  constructor(socketPath: string) {
    this.socketPath = socketPath;
  }

  /** The `/vX.Y` prefix for the daemon's API version, negotiated once. */
  #prefix(): Promise<string> {
    if (!this.#version) {
      const pending = this.#raw("GET", "/version", { timeoutMs: 10_000 }).then((response) => {
        if (response.status !== 200) throw new EngineError("Docker Engine version check failed", response.status);
        const version = JSON.parse(response.body.toString("utf8")).ApiVersion;
        if (typeof version !== "string" || !/^\d+\.\d+$/.test(version)) {
          throw new EngineError("Docker Engine reported no API version");
        }
        return `/v${version}`;
      });
      this.#version = pending;
      pending.catch(() => {
        if (this.#version === pending) this.#version = undefined;
      });
    }
    return this.#version;
  }

  #raw(method: string, path: string, options: RequestOptions = {}): Promise<EngineResponse> {
    return new Promise((resolve, reject) => {
      const body = options.raw
        ? options.raw.data
        : options.body === undefined
          ? undefined
          : Buffer.from(JSON.stringify(options.body));
      const req = httpRequest(
        {
          socketPath: this.socketPath,
          method,
          path: `${path}${queryString(options.query)}`,
          headers: {
            host: "docker",
            ...(body
              ? {
                  "content-type": options.raw ? options.raw.type : "application/json",
                  "content-length": body.length,
                }
              : {}),
          },
          ...(options.signal ? { signal: options.signal } : {}),
        },
        (response: IncomingMessage) => {
          const chunks: Buffer[] = [];
          response.on("data", (chunk: Buffer) => chunks.push(chunk));
          response.on("end", () =>
            resolve({ status: response.statusCode ?? 0, body: Buffer.concat(chunks) }),
          );
          response.on("error", reject);
        },
      );
      if (options.timeoutMs) {
        req.setTimeout(options.timeoutMs, () => req.destroy(new EngineError(`Docker Engine ${method} ${path} timed out`)));
      }
      req.on("error", (error) =>
        reject(error instanceof EngineError ? error : new EngineError(`Docker Engine is unreachable: ${error.message}`)),
      );
      req.end(body);
    });
  }

  async request(method: string, path: string, options: RequestOptions = {}): Promise<EngineResponse> {
    return this.#raw(method, `${await this.#prefix()}${path}`, options);
  }

  /** JSON result of a successful call; `allow` statuses resolve undefined instead of failing. */
  async json<T>(
    method: string,
    path: string,
    options: RequestOptions & { readonly allow?: readonly number[] } = {},
  ): Promise<T | undefined> {
    const response = await this.request(method, path, options);
    if (options.allow?.includes(response.status)) return undefined;
    if (response.status < 200 || response.status >= 300) {
      throw new EngineError(`Docker Engine ${method} ${path}: ${engineMessage(response)}`, response.status);
    }
    const text = response.body.toString("utf8").trim();
    return text ? (JSON.parse(text) as T) : (undefined as T);
  }

  async ping(): Promise<void> {
    const response = await this.#raw("GET", "/_ping", { timeoutMs: 10_000 });
    if (response.status !== 200) throw new EngineError("Docker Engine ping failed", response.status);
    await this.#prefix();
  }

  async imageExists(name: string): Promise<boolean> {
    const found = await this.json("GET", `/images/${encodeURIComponent(name)}/json`, { allow: [404] });
    return found !== undefined;
  }

  async removeImage(name: string): Promise<void> {
    await this.json("DELETE", `/images/${encodeURIComponent(name)}`, {
      query: { force: true },
      allow: [404, 409],
    });
  }

  /** Build from a tar context; resolves once the daemon reports success, else throws its error. */
  async build(context: Buffer, tags: readonly string[], options: { readonly pull?: boolean; readonly signal?: AbortSignal; readonly log?: (line: string) => void } = {}): Promise<void> {
    const response = await this.request("POST", "/build", {
      query: { t: tags, rm: true, forcerm: true, pull: options.pull ?? true },
      raw: { data: context, type: "application/x-tar" },
      ...(options.signal ? { signal: options.signal } : {}),
    });
    if (response.status !== 200) {
      throw new EngineError(`image build failed: ${engineMessage(response)}`, response.status);
    }
    let failure: string | undefined;
    for (const line of response.body.toString("utf8").split("\n")) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line) as { stream?: string; error?: string; errorDetail?: { message?: string } };
        if (event.error || event.errorDetail) failure = event.errorDetail?.message ?? event.error;
        else if (event.stream?.trim()) options.log?.(event.stream.trim());
      } catch {
        // Progress lines that are not JSON carry nothing we need.
      }
    }
    if (failure) throw new EngineError(`image build failed: ${failure.slice(-500)}`);
  }

  inspectContainer(name: string): Promise<ContainerInfo | undefined> {
    return this.json<ContainerInfo>("GET", `/containers/${encodeURIComponent(name)}/json`, { allow: [404] });
  }

  async createContainer(name: string, spec: Record<string, unknown>): Promise<string> {
    const created = await this.json<{ Id: string }>("POST", "/containers/create", {
      query: { name },
      body: spec,
    });
    if (!created?.Id) throw new EngineError("container create returned no id");
    return created.Id;
  }

  async startContainer(name: string): Promise<void> {
    await this.json("POST", `/containers/${encodeURIComponent(name)}/start`, { allow: [304] });
  }

  async stopContainer(name: string, seconds = 20): Promise<void> {
    await this.json("POST", `/containers/${encodeURIComponent(name)}/stop`, {
      query: { t: seconds },
      allow: [304, 404],
      timeoutMs: (seconds + 30) * 1000,
    });
  }

  async removeContainer(name: string): Promise<void> {
    await this.json("DELETE", `/containers/${encodeURIComponent(name)}`, {
      query: { force: true, v: false },
      allow: [404],
    });
  }

  /** Wait for a container to exit; its status code. */
  async waitContainer(name: string, timeoutMs = 30 * 60_000): Promise<number> {
    const result = await this.json<{ StatusCode: number }>("POST", `/containers/${encodeURIComponent(name)}/wait`, { timeoutMs });
    return result?.StatusCode ?? -1;
  }

  async commitContainer(name: string, repo: string, tag: string): Promise<string> {
    const result = await this.json<{ Id: string }>("POST", "/commit", {
      query: { container: name, repo, tag, pause: false },
      body: {},
    });
    return result?.Id ?? "";
  }

  async listContainers(label: string): Promise<ContainerSummary[]> {
    return (
      (await this.json<ContainerSummary[]>("GET", "/containers/json", {
        query: { all: true, filters: JSON.stringify({ label: [label] }) },
      })) ?? []
    );
  }

  async volumeExists(name: string): Promise<boolean> {
    return (await this.json("GET", `/volumes/${encodeURIComponent(name)}`, { allow: [404] })) !== undefined;
  }

  async createVolume(name: string, labels: Record<string, string> = {}): Promise<void> {
    await this.json("POST", "/volumes/create", { body: { Name: name, Labels: labels } });
  }

  /** Remove a volume; one still used by a container is left (409) and reported as false. */
  async removeVolume(name: string): Promise<boolean> {
    const response = await this.request("DELETE", `/volumes/${encodeURIComponent(name)}`);
    if (response.status === 409) return false;
    if (response.status !== 204 && response.status !== 200 && response.status !== 404) {
      throw new EngineError(`Docker Engine DELETE /volumes/${name}: ${engineMessage(response)}`, response.status);
    }
    return true;
  }

  async listVolumes(label: string): Promise<{ Name: string; Labels: Record<string, string> | null }[]> {
    const result = await this.json<{ Volumes: { Name: string; Labels: Record<string, string> | null }[] | null }>(
      "GET",
      "/volumes",
      { query: { filters: JSON.stringify({ label: [label] }) } },
    );
    return result?.Volumes ?? [];
  }

  /** Extract a tar archive into `path` of a (created or running) container. */
  async putArchive(container: string, path: string, tar: Buffer): Promise<void> {
    await this.json("PUT", `/containers/${encodeURIComponent(container)}/archive`, {
      query: { path },
      raw: { data: tar, type: "application/x-tar" },
    });
  }

  async pathExists(container: string, path: string): Promise<boolean> {
    const response = await this.request("HEAD", `/containers/${encodeURIComponent(container)}/archive`, { query: { path } });
    return response.status === 200;
  }

  async #createExec(container: string, cmd: readonly string[], options: ExecOptions): Promise<string> {
    const created = await this.json<{ Id: string }>("POST", `/containers/${encodeURIComponent(container)}/exec`, {
      body: {
        AttachStdin: true,
        AttachStdout: true,
        AttachStderr: true,
        Tty: false,
        Cmd: cmd,
        ...(options.user ? { User: options.user } : {}),
        ...(options.workdir ? { WorkingDir: options.workdir } : {}),
        ...(options.env ? { Env: options.env } : {}),
      },
    });
    if (!created?.Id) throw new EngineError("exec create returned no id");
    return created.Id;
  }

  async execExitCode(id: string): Promise<number | null> {
    // The exit code can lag the stream's end by a moment.
    for (let attempt = 0; attempt < 20; attempt++) {
      const info = await this.json<{ Running: boolean; ExitCode: number | null }>("GET", `/exec/${id}/json`);
      if (info && !info.Running) return info.ExitCode;
      await new Promise((resolve) => setTimeout(resolve, 50));
    }
    return null;
  }

  /** Start an exec with its stdio on a hijacked connection. */
  spawn(container: string, cmd: readonly string[], options: ExecOptions = {}): ExecProcess {
    const process = new ExecProcess();
    void (async () => {
      const id = await this.#createExec(container, cmd, options);
      const prefix = await this.#prefix();
      const body = Buffer.from(JSON.stringify({ Detach: false, Tty: false }));
      await new Promise<void>((resolve, reject) => {
        const req = httpRequest({
          socketPath: this.socketPath,
          method: "POST",
          path: `${prefix}/exec/${id}/start`,
          headers: {
            host: "docker",
            "content-type": "application/json",
            "content-length": body.length,
            connection: "Upgrade",
            upgrade: "tcp",
          },
        });
        req.on("upgrade", (_response, socket: Socket, head: Buffer) => {
          socket.setNoDelay(true);
          process.attach(socket, head, () => this.execExitCode(id));
          resolve();
        });
        req.on("response", (response: IncomingMessage) => {
          const chunks: Buffer[] = [];
          response.on("data", (chunk: Buffer) => chunks.push(chunk));
          response.on("end", () =>
            reject(new EngineError(`exec start: ${engineMessage({ status: response.statusCode ?? 0, body: Buffer.concat(chunks) })}`, response.statusCode)),
          );
        });
        req.on("error", reject);
        req.end(body);
      });
    })().catch((error: unknown) => process.fail(error instanceof Error ? error : new Error(String(error))));
    return process;
  }

  /** Run a command to completion: optional stdin (then half-closed), collected output. */
  run(
    container: string,
    cmd: readonly string[],
    options: ExecOptions & { readonly input?: string | Buffer; readonly timeoutMs?: number } = {},
  ): Promise<ExecResult> {
    return new Promise((resolve, reject) => {
      const child = this.spawn(container, cmd, options);
      const out: Buffer[] = [];
      const err: Buffer[] = [];
      child.stdout.on("data", (chunk: Buffer) => out.push(chunk));
      child.stderr.on("data", (chunk: Buffer) => err.push(chunk));
      let failed: Error | undefined;
      child.once("error", (error: Error) => {
        failed = error;
      });
      const timer = options.timeoutMs
        ? setTimeout(() => {
            failed = new EngineError(`command timed out: ${cmd[0]}`);
            child.kill();
          }, options.timeoutMs)
        : undefined;
      child.once("exit", (code: number | null) => {
        if (timer) clearTimeout(timer);
        if (failed) return reject(failed);
        resolve({
          code: code ?? -1,
          stdout: Buffer.concat(out).toString("utf8"),
          stderr: Buffer.concat(err).toString("utf8"),
        });
      });
      child.stdin.end(options.input ?? "");
    });
  }
}

export type ContainerInfo = {
  readonly Id: string;
  readonly Name: string;
  readonly Image: string;
  readonly Config: { readonly Image: string; readonly Labels?: Record<string, string> };
  readonly State: { readonly Running: boolean; readonly Status: string };
  readonly HostConfig?: { readonly Memory?: number };
  readonly Mounts?: readonly { readonly Name?: string; readonly Destination: string }[];
};

export type ContainerSummary = {
  readonly Id: string;
  readonly Names: readonly string[];
  readonly State: string;
  readonly Labels: Record<string, string>;
};

function engineMessage(response: EngineResponse): string {
  const text = response.body.toString("utf8");
  try {
    const message = (JSON.parse(text) as { message?: unknown }).message;
    if (typeof message === "string") return `${message.slice(0, 500)} (HTTP ${response.status})`;
  } catch {
    // Not JSON.
  }
  return `HTTP ${response.status}`;
}

/** Collect a readable stream into a buffer (tests and archives). */
export async function collect(stream: Readable): Promise<Buffer> {
  const chunks: Buffer[] = [];
  for await (const chunk of stream) chunks.push(Buffer.from(chunk));
  return Buffer.concat(chunks);
}
