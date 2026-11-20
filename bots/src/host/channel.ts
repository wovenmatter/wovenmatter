import { randomUUID } from "node:crypto";
import type { HostMethod, HostMethods, HostReply, HostRequest } from "../protocol.ts";

export const HOST_TIMEOUT_MS = 20_000;

export class HostError extends Error {
  override name = "HostError";
}

type Pending = {
  readonly resolve: (data: unknown) => void;
  readonly reject: (error: Error) => void;
  readonly timer: NodeJS.Timeout;
};

/** The host side of a calling module: one method of the server's host interface. */
export type HostCall = <M extends HostMethod>(
  method: M,
  params: HostMethods[M]["params"],
) => Promise<HostMethods[M]["data"]>;

/**
 * The server's host interface, carried on the server's own connection to the runtime: a request
 * goes out as `{type: "host", id, method, params}` and its `host.result` or `host.error` comes back
 * on the same connection. With no server connected a call fails at once; a reply that does not
 * arrive in time fails the call, and a lost connection fails every call still waiting.
 */
export class HostChannel {
  readonly #timeoutMs: number;
  readonly #pending = new Map<string, Pending>();
  readonly #connected = new Set<() => void>();
  #send: ((request: HostRequest) => void) | undefined;

  constructor(options: { readonly timeoutMs?: number } = {}) {
    this.#timeoutMs = options.timeoutMs ?? HOST_TIMEOUT_MS;
  }

  get connected(): boolean {
    return this.#send !== undefined;
  }

  /**
   * The server connected: calls go out through `send` until the returned function says the
   * connection ended. A later connection replaces an earlier one.
   */
  attach(send: (request: HostRequest) => void): () => void {
    this.#send = send;
    for (const listener of this.#connected) listener();
    return () => {
      if (this.#send !== send) return;
      this.#send = undefined;
      for (const [id, pending] of this.#pending) {
        this.#pending.delete(id);
        clearTimeout(pending.timer);
        pending.reject(new HostError("The Woven server disconnected."));
      }
    };
  }

  /** Called on every server connection (the mirror asks for its checkpoints again). */
  onConnected(listener: () => void): () => void {
    this.#connected.add(listener);
    return () => this.#connected.delete(listener);
  }

  /** A `host.result` or `host.error` from the server. */
  deliver(reply: HostReply): void {
    const pending = this.#pending.get(reply.id);
    if (!pending) return;
    this.#pending.delete(reply.id);
    clearTimeout(pending.timer);
    if (reply.type === "host.result") pending.resolve(reply.data);
    else pending.reject(new HostError(reply.message || "The Woven server refused the request."));
  }

  readonly call: HostCall = (method, params) => {
    const send = this.#send;
    if (!send) return Promise.reject(new HostError("The Woven server is not connected."));
    const id = randomUUID();
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id);
        reject(new HostError(`The Woven server did not answer ${method} in time.`));
      }, this.#timeoutMs);
      timer.unref?.();
      this.#pending.set(id, { resolve: resolve as (data: unknown) => void, reject, timer });
      try {
        send({ type: "host", id, method, params } as HostRequest);
      } catch (error) {
        this.#pending.delete(id);
        clearTimeout(timer);
        reject(new HostError(`The Woven server is unreachable: ${(error as Error).message}`));
      }
    });
  };
}
