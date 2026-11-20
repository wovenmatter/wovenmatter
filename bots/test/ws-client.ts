import WebSocket from "ws";
import type { HostMethod, HostMethods, HostRequest, ServerMessage } from "../src/protocol.ts";

/** How the test server answers one host method (a throw becomes `host.error`). */
export type HostHandlers = {
  [M in HostMethod]?: (params: HostMethods[M]["params"]) => HostMethods[M]["data"] | Promise<HostMethods[M]["data"]>;
};

/**
 * The server's side of the one connection, for tests: it sends requests, collects pushes, and
 * answers the runtime's host requests from `handlers` (each one is recorded in `hostCalls`).
 */
export class FakeServer {
  readonly messages: ServerMessage[] = [];
  readonly hostCalls: HostRequest[] = [];
  handlers: HostHandlers;
  readonly #socket: WebSocket;
  readonly #waiters = new Set<() => void>();
  #next = 1;

  private constructor(socket: WebSocket, handlers: HostHandlers) {
    this.#socket = socket;
    this.handlers = handlers;
    socket.on("message", (data) => {
      const message = JSON.parse(data.toString()) as ServerMessage;
      if (message.type === "host") void this.#answer(message);
      else this.messages.push(message);
      for (const wake of this.#waiters) wake();
    });
  }

  static open(socketPath: string, handlers: HostHandlers = {}): Promise<FakeServer> {
    const socket = new WebSocket(`ws+unix://${socketPath}:/`);
    return new Promise((resolve, reject) => {
      const server = new FakeServer(socket, handlers);
      socket.once("open", () => resolve(server));
      socket.once("error", reject);
    });
  }

  async #answer(request: HostRequest): Promise<void> {
    this.hostCalls.push(request);
    const handler = this.handlers[request.method] as ((params: unknown) => unknown) | undefined;
    try {
      if (!handler) throw new Error(`no handler for ${request.method}`);
      const data = await handler(request.params);
      this.#socket.send(JSON.stringify({ type: "host.result", id: request.id, data }));
    } catch (error) {
      this.#socket.send(JSON.stringify({ type: "host.error", id: request.id, message: (error as Error).message }));
    }
  }

  /** Host requests of one method so far. */
  calls<M extends HostMethod>(method: M): HostMethods[M]["params"][] {
    return this.hostCalls.flatMap((call) => (call.method === method ? [call.params as HostMethods[M]["params"]] : []));
  }

  waitFor<T extends ServerMessage>(predicate: (message: ServerMessage) => boolean, timeout = 5000) {
    return new Promise<T>((resolve, reject) => {
      const check = () => {
        const found = this.messages.find(predicate);
        if (!found) return;
        this.#waiters.delete(check);
        clearTimeout(timer);
        resolve(found as T);
      };
      const timer = setTimeout(() => {
        this.#waiters.delete(check);
        reject(new Error("timed out waiting for message"));
      }, timeout);
      this.#waiters.add(check);
      check();
    });
  }

  /** Wait until `check` holds, looking again after every message. */
  until(check: () => boolean, timeout = 5000): Promise<void> {
    return new Promise((resolve, reject) => {
      const look = () => {
        if (!check()) return;
        this.#waiters.delete(look);
        clearTimeout(timer);
        resolve();
      };
      const timer = setTimeout(() => {
        this.#waiters.delete(look);
        reject(new Error("timed out"));
      }, timeout);
      this.#waiters.add(look);
      look();
    });
  }

  async request<T>(type: string, payload: Record<string, unknown> = {}): Promise<T> {
    const id = this.#next++;
    this.#socket.send(JSON.stringify({ id, type, ...payload }));
    const reply = await this.waitFor(
      (message) => (message.type === "result" || message.type === "error") && message.id === id,
    );
    if (reply.type === "error") throw new Error(reply.message);
    return (reply as Extract<ServerMessage, { type: "result" }>).data as T;
  }

  close(): Promise<void> {
    return new Promise((resolve) => {
      if (this.#socket.readyState === WebSocket.CLOSED) return resolve();
      this.#socket.once("close", () => resolve());
      this.#socket.close();
    });
  }
}
