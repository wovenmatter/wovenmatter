import WebSocket from "ws";
import type { ServerMessage, StreamEvent } from "../src/protocol.ts";

/** Minimal test client for the Pi Bot WebSocket API. */
export class Client {
  readonly messages: ServerMessage[] = [];
  readonly #socket: WebSocket;
  readonly #waiters = new Set<() => void>();
  #next = 1;

  private constructor(socket: WebSocket) {
    this.#socket = socket;
    socket.on("message", (data) => {
      this.messages.push(JSON.parse(data.toString()) as ServerMessage);
      for (const wake of this.#waiters) wake();
    });
  }

  static open(url: string, headers: Record<string, string> = {}): Promise<Client> {
    const socket = new WebSocket(url, { headers });
    return new Promise((resolve, reject) => {
      const client = new Client(socket);
      socket.once("open", () => resolve(client));
      socket.once("error", reject);
      socket.once("unexpected-response", (_request, response) =>
        reject(new Error(`HTTP ${response.statusCode}`)),
      );
    });
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

  async request<T>(type: string, payload: Record<string, unknown> = {}): Promise<T> {
    const id = this.#next++;
    this.#socket.send(JSON.stringify({ id, type, ...payload }));
    const reply = await this.waitFor(
      (message) => (message.type === "result" || message.type === "error") && message.id === id,
    );
    if (reply.type === "error") throw new Error(reply.message);
    return (reply as Extract<ServerMessage, { type: "result" }>).data as T;
  }

  events(conversationId: number): StreamEvent[] {
    return this.messages.flatMap((message) =>
      message.type === "event" && message.conversationId === conversationId ? [message.event] : [],
    );
  }

  close() {
    this.#socket.close();
  }
}
