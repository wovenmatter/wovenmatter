import type { Context } from "@earendil-works/chord";
import {
  type BinaryReader,
  type DirReader,
  type ExecutionEnv,
  ExecutionError,
  type ExecutionErrorCode,
  FileError,
  type FileErrorCode,
  type FileWatcher,
  type TextLineReader,
} from "@earendil-works/pi-durable/env";

/** The child process the agent runs in (an Engine API exec of `node agent.mjs`, or plain node in tests). */
export type AgentProcess = {
  readonly stdin: NodeJS.WritableStream;
  readonly stdout: NodeJS.ReadableStream;
  readonly stderr?: NodeJS.ReadableStream | null;
  once(event: "exit", listener: (code: number | null) => void): unknown;
  once(event: "error", listener: (error: Error) => void): unknown;
  kill(): unknown;
};

type Pending = {
  readonly resolve: (value: unknown) => void;
  readonly reject: (error: Error) => void;
  readonly context: Context;
  readonly callbacks: number[];
};

type RemoteHandle = { readonly $handle: number; readonly mode?: string };

/**
 * One connection to an environment agent (`helper/agent.mjs`) for one bot. Started lazily by the
 * first call; if the agent exits, in-flight calls fail and the next call starts a new one.
 */
export class AgentConnection {
  readonly #start: () => Promise<AgentProcess>;
  readonly #log: (message: string) => void;
  #process: Promise<AgentProcess> | undefined;
  #generation = 0;
  #nextId = 1;
  #nextCallback = 1;
  readonly #pending = new Map<number, Pending>();
  readonly #callbacks = new Map<number, (...args: unknown[]) => void>();
  readonly #handleCallbacks = new Map<number, number[]>();
  readonly #onActivity: () => void;

  constructor(
    start: () => Promise<AgentProcess>,
    log: (message: string) => void = () => {},
    onActivity: () => void = () => {},
  ) {
    this.#start = start;
    this.#log = log;
    this.#onActivity = onActivity;
  }

  /** A call in flight or a live watcher: stopping the agent now would lose it. */
  get busy(): boolean {
    return this.#pending.size > 0 || this.#handleCallbacks.size > 0;
  }

  /** Call `method` on the env for `cwd` (or on a handle); `context` is appended agent-side. */
  call(
    cwd: string,
    handle: number | undefined,
    method: string,
    args: readonly unknown[],
    context: Context,
  ): Promise<unknown> {
    const id = this.#nextId++;
    this.#onActivity();
    const callbacks: number[] = [];
    const encoded = args.map((arg) => this.#encode(arg, callbacks));
    return new Promise<unknown>((resolve, reject) => {
      const signal = context.abortSignal;
      const onAbort = () => void this.#write({ id, cancel: true }).catch(() => {});
      signal?.addEventListener("abort", onAbort, { once: true });
      this.#pending.set(id, {
        resolve: (value) => {
          signal?.removeEventListener("abort", onAbort);
          resolve(value);
        },
        reject: (error) => {
          signal?.removeEventListener("abort", onAbort);
          reject(error);
        },
        context,
        callbacks,
      });
      this.#write({ id, cwd, ...(handle ? { handle } : {}), method, args: encoded })
        .then(() => {
          if (signal?.aborted) onAbort();
        })
        .catch((error: unknown) => this.#fail(id, error));
    });
  }

  /** Ask the in-container supervisor (restart list, browser) through the agent. */
  control(method: string, args: Record<string, unknown>, context: Context): Promise<unknown> {
    const id = this.#nextId++;
    this.#onActivity();
    return new Promise<unknown>((resolve, reject) => {
      const signal = context.abortSignal;
      const onAbort = () => void this.#write({ id, cancel: true }).catch(() => {});
      signal?.addEventListener("abort", onAbort, { once: true });
      const settle =
        <T>(fn: (value: T) => void) =>
        (value: T) => {
          signal?.removeEventListener("abort", onAbort);
          fn(value);
        };
      this.#pending.set(id, {
        resolve: settle(resolve),
        reject: settle(reject),
        context,
        callbacks: [],
      });
      this.#write({ id, control: method, args }).catch((error: unknown) => this.#fail(id, error));
    });
  }

  /** Stop the agent; pending calls fail. */
  close(): void {
    const current = this.#process;
    this.#retire(new Error("environment agent closed"));
    void current?.then((child) => child.kill()).catch(() => {});
  }

  /** End the current agent generation: its calls fail and a later call starts a new agent. */
  #retire(error: Error): void {
    this.#generation++;
    this.#process = undefined;
    for (const id of [...this.#pending.keys()]) this.#fail(id, error);
    this.#callbacks.clear();
    this.#handleCallbacks.clear();
  }

  get started(): boolean {
    return this.#process !== undefined;
  }

  async #write(message: object): Promise<void> {
    const child = await this.#ensure();
    child.stdin.write(`${JSON.stringify(message)}\n`);
  }

  #ensure(): Promise<AgentProcess> {
    if (!this.#process) {
      const generation = this.#generation;
      const started = this.#start().then((child) => {
        if (generation !== this.#generation) {
          child.kill();
          throw new Error("environment agent closed");
        }
        return this.#attach(child, generation);
      });
      this.#process = started;
      started.catch(() => {
        if (this.#process === started) this.#process = undefined;
      });
    }
    return this.#process;
  }

  #attach(child: AgentProcess, generation: number): AgentProcess {
    const failed = (error: Error) => {
      if (generation !== this.#generation) return;
      this.#retire(error);
      child.kill();
    };
    child.once("error", failed);
    child.stdin.on("error", failed);
    child.stdout.on("error", failed);
    child.stderr?.on("error", failed);
    let buffer = "";
    child.stdout.setEncoding?.("utf8");
    child.stdout.on("data", (chunk: Buffer | string) => {
      if (generation !== this.#generation) return;
      buffer += chunk.toString();
      let newline = buffer.indexOf("\n");
      while (newline >= 0) {
        const line = buffer.slice(0, newline);
        buffer = buffer.slice(newline + 1);
        if (line.trim()) this.#receive(line);
        newline = buffer.indexOf("\n");
      }
    });
    child.stderr?.on("data", (chunk: Buffer | string) => {
      const text = chunk.toString().trim();
      if (text) this.#log(`environment agent: ${text.slice(0, 500)}`);
    });
    child.once("exit", (code) => {
      // A retired agent (closed, or replaced) exiting late must not touch the new one's calls.
      if (generation !== this.#generation) return;
      this.#retire(new Error(`environment agent exited (${code ?? "signal"})`));
    });
    return child;
  }

  #receive(line: string): void {
    let message: {
      id?: number;
      value?: unknown;
      thrown?: string;
      callback?: number;
      args?: unknown[];
    };
    try {
      message = JSON.parse(line);
    } catch {
      this.#log("environment agent: unreadable message");
      return;
    }
    if (typeof message.callback === "number") {
      const callback = this.#callbacks.get(message.callback);
      const owner = [...this.#pending.values()].find((entry) =>
        entry.callbacks.includes(message.callback ?? -1),
      );
      const context = owner?.context;
      try {
        callback?.(...(message.args ?? []).map((arg) => this.#decode(arg, context, [])));
      } catch (error) {
        this.#log(`environment callback failed: ${String(error)}`);
      }
      return;
    }
    if (typeof message.id !== "number") return;
    const entry = this.#pending.get(message.id);
    if (!entry) return;
    this.#pending.delete(message.id);
    this.#onActivity();
    if (message.thrown !== undefined) {
      this.#release(entry.callbacks);
      entry.reject(new Error(`environment: ${message.thrown}`));
      return;
    }
    const handles: number[] = [];
    const value = this.#decode(message.value, entry.context, handles);
    // Callbacks live as long as a handle they produced (a watcher); otherwise they end with the call.
    if (handles.length && entry.callbacks.length) {
      for (const handle of handles) this.#handleCallbacks.set(handle, entry.callbacks);
    } else {
      this.#release(entry.callbacks);
    }
    entry.resolve(value);
  }

  #fail(id: number, error: unknown): void {
    const entry = this.#pending.get(id);
    if (!entry) return;
    this.#pending.delete(id);
    this.#release(entry.callbacks);
    entry.reject(error instanceof Error ? error : new Error(String(error)));
  }

  #release(callbacks: readonly number[]): void {
    for (const token of callbacks) this.#callbacks.delete(token);
  }

  releaseHandle(handle: number): void {
    this.#release(this.#handleCallbacks.get(handle) ?? []);
    this.#handleCallbacks.delete(handle);
  }

  #encode(value: unknown, callbacks: number[]): unknown {
    if (typeof value === "function") {
      const token = this.#nextCallback++;
      this.#callbacks.set(token, value as (...args: unknown[]) => void);
      callbacks.push(token);
      return { $callback: token };
    }
    if (value === null || typeof value !== "object") return value;
    if (value instanceof Uint8Array) return { $bytes: Buffer.from(value).toString("base64") };
    if (Array.isArray(value)) return value.map((item) => this.#encode(item, callbacks));
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(value)) {
      if (item !== undefined) out[key] = this.#encode(item, callbacks);
    }
    return out;
  }

  #decode(value: unknown, context: Context | undefined, handles: number[]): unknown {
    if (value === null || typeof value !== "object") return value;
    if (Array.isArray(value)) return value.map((item) => this.#decode(item, context, handles));
    const record = value as Record<string, unknown>;
    if (typeof record.$bytes === "string") {
      return new Uint8Array(Buffer.from(record.$bytes, "base64"));
    }
    if (record.$ctx === 1) return context;
    if (record.$error && typeof record.$error === "object") {
      return decodeError(record.$error as Record<string, unknown>);
    }
    if (typeof record.$handle === "number") {
      handles.push(record.$handle);
      return this.handle(record as RemoteHandle);
    }
    const out: Record<string, unknown> = {};
    for (const [key, item] of Object.entries(record)) {
      out[key] = this.#decode(item, context, handles);
    }
    return out;
  }

  /** A proxy for a reader or watcher living in the agent. */
  handle(remote: RemoteHandle): TextLineReader & BinaryReader & DirReader & FileWatcher {
    const id = remote.$handle;
    let stopped: Promise<void> | undefined;
    const forward =
      (method: string) =>
      (...args: unknown[]) => {
        const context = args.pop() as Context;
        return this.call("", id, method, args, context) as Promise<never>;
      };
    return {
      mode: remote.mode === "native" ? "native" : "polling",
      readLine: forward("readLine"),
      info: forward("info"),
      read: forward("read"),
      scanLines: forward("scanLines"),
      next: forward("next"),
      stop: (context: Context) => {
        stopped ??= this.call("", id, "stop", [], context)
          .then(() => {})
          .finally(() => this.releaseHandle(id));
        return stopped;
      },
      close: async (context: Context) => {
        try {
          await this.call("", id, "close", [], context);
        } finally {
          this.releaseHandle(id);
        }
      },
    };
  }
}

function decodeError(error: Record<string, unknown>): Error {
  const message = typeof error.message === "string" ? error.message : "environment error";
  if (error.kind === "file") {
    return new FileError(
      (error.code as FileErrorCode) ?? "unknown",
      message,
      typeof error.path === "string" ? error.path : undefined,
    );
  }
  if (error.kind === "exec") {
    const result = new ExecutionError((error.code as ExecutionErrorCode) ?? "unknown", message);
    if (typeof error.spillPath === "string") result.spillPath = error.spillPath;
    return result;
  }
  return new Error(message);
}

/**
 * An `ExecutionEnv` whose every filesystem and shell operation runs in the agent behind
 * `connection` (inside the bot's container). Paths are container paths.
 */
export class RemoteExecutionEnv implements ExecutionEnv {
  readonly id: string;
  cwd: string;
  readonly #connection: AgentConnection;

  constructor(id: string, cwd: string, connection: AgentConnection) {
    this.id = id;
    this.cwd = cwd;
    this.#connection = connection;
  }

  #call<T>(method: string, args: readonly unknown[], context: Context): Promise<T> {
    return this.#connection.call(this.cwd, undefined, method, args, context) as Promise<T>;
  }

  absolutePath: ExecutionEnv["absolutePath"] = (path, context) =>
    this.#call("absolutePath", [path], context);
  joinPath: ExecutionEnv["joinPath"] = (parts, context) => this.#call("joinPath", [parts], context);
  readTextFile: ExecutionEnv["readTextFile"] = (path, context) =>
    this.#call("readTextFile", [path], context);
  openTextLineReader: ExecutionEnv["openTextLineReader"] = (path, context) =>
    this.#call("openTextLineReader", [path], context);
  readTextLines: ExecutionEnv["readTextLines"] = (path, options, context) =>
    this.#call("readTextLines", [path, options], context);
  readBinaryFile: ExecutionEnv["readBinaryFile"] = (path, context) =>
    this.#call("readBinaryFile", [path], context);
  openBinaryReader: ExecutionEnv["openBinaryReader"] = (path, options, context) =>
    this.#call("openBinaryReader", [path, options], context);
  writeFile: ExecutionEnv["writeFile"] = (path, content, context) =>
    this.#call("writeFile", [path, content], context);
  appendFile: ExecutionEnv["appendFile"] = (path, content, context) =>
    this.#call("appendFile", [path, content], context);
  truncateFile: ExecutionEnv["truncateFile"] = (path, size, context) =>
    this.#call("truncateFile", [path, size], context);
  flushFile: ExecutionEnv["flushFile"] = (path, context) =>
    this.#call("flushFile", [path], context);
  renameFile: ExecutionEnv["renameFile"] = (source, destination, context) =>
    this.#call("renameFile", [source, destination], context);
  fileInfo: ExecutionEnv["fileInfo"] = (path, context) => this.#call("fileInfo", [path], context);
  listDir: ExecutionEnv["listDir"] = (path, context) => this.#call("listDir", [path], context);
  listFiles: NonNullable<ExecutionEnv["listFiles"]> = (path, options, context) =>
    this.#call("listFiles", [path, options], context);
  openDirReader: ExecutionEnv["openDirReader"] = (path, context) =>
    this.#call("openDirReader", [path], context);
  watch: ExecutionEnv["watch"] = (targets, onChange, context) =>
    this.#call("watch", [targets, onChange], context);
  canonicalPath: ExecutionEnv["canonicalPath"] = (path, context) =>
    this.#call("canonicalPath", [path], context);
  exists: ExecutionEnv["exists"] = (path, context) => this.#call("exists", [path], context);
  createDir: ExecutionEnv["createDir"] = (path, options, context) =>
    this.#call("createDir", [path, options], context);
  remove: ExecutionEnv["remove"] = (path, options, context) =>
    this.#call("remove", [path, options], context);
  createTempDir: ExecutionEnv["createTempDir"] = (prefix, context) =>
    this.#call("createTempDir", [prefix], context);
  createTempFile: ExecutionEnv["createTempFile"] = (options, context) =>
    this.#call("createTempFile", [options], context);
  exec: ExecutionEnv["exec"] = (command, options, context) =>
    this.#call("exec", [command, options], context);
  /** Temp files live in the agent; the agent process (and container) outlive one env use. */
  cleanup: ExecutionEnv["cleanup"] = async (context) => {
    if (this.#connection.started) await this.#call("cleanup", [], context);
  };
}
