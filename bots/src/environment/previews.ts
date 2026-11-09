import { createServer, type Server, type Socket } from "node:net";
import type { Duplex } from "node:stream";
import type { HostAPI } from "../host/client.ts";
import type { BotRegistry } from "../storage/registry.ts";

/**
 * How preview traffic reaches a port inside a bot's container. The default carries each client
 * connection over a Docker exec stream (works on every engine with no published ports); a host
 * integration may substitute its own (for example a direct path on the engine host).
 */
export interface PreviewTransport {
  connect(botId: string, containerPort: number): Promise<Duplex>;
}

export type Preview = {
  readonly botId: string;
  readonly containerPort: number;
  /** The runtime's loopback activity proxy, which the host publishes. */
  readonly port: number;
  readonly url: string;
  readonly createdAt: string;
};

const NOTE = "previews.";

type Live = { preview: Preview; server: Server; sockets: Set<Socket> };

/**
 * Previews: for each shared container port, a small TCP proxy on a loopback port that counts
 * every connection and byte as the bot's activity (so a viewed preview keeps it awake and wakes a
 * stopped container), published by the host (Tailscale Serve, inbound only) at a URL for the user.
 * HTTP and WebSocket both pass through unchanged.
 */
export class PreviewManager {
  readonly #host: Pick<HostAPI, "publishPreview" | "unpublishPreview">;
  readonly #transport: PreviewTransport;
  readonly #registry: BotRegistry;
  readonly #activity: (botId: string) => void;
  readonly #log: (message: string) => void;
  readonly #live = new Map<string, Live>();
  readonly #lastTraffic = new Map<string, number>();

  constructor(options: {
    host: Pick<HostAPI, "publishPreview" | "unpublishPreview">;
    transport: PreviewTransport;
    registry: BotRegistry;
    activity: (botId: string) => void;
    log?: (message: string) => void;
  }) {
    this.#host = options.host;
    this.#transport = options.transport;
    this.#registry = options.registry;
    this.#activity = options.activity;
    this.#log = options.log ?? (() => {});
  }

  /** When the bot's previews last carried traffic (epoch ms). */
  lastTraffic(botId: string): number | undefined {
    return this.#lastTraffic.get(botId);
  }

  list(botId: string): Preview[] {
    return [...this.#live.values()].map((live) => live.preview).filter((preview) => preview.botId === botId);
  }

  #touch(botId: string): void {
    this.#lastTraffic.set(botId, Date.now());
    this.#activity(botId);
  }

  async #listen(botId: string, containerPort: number, port = 0): Promise<{ server: Server; sockets: Set<Socket> }> {
    const sockets = new Set<Socket>();
    const server = createServer((client) => {
      sockets.add(client);
      client.on("close", () => sockets.delete(client));
      this.#touch(botId);
      client.pause();
      let last = 0;
      const count = () => {
        // At most one activity mark per second per connection.
        const now = Date.now();
        if (now - last > 1000) {
          last = now;
          this.#touch(botId);
        }
      };
      this.#transport.connect(botId, containerPort).then(
        (upstream) => {
          if (client.destroyed) {
            upstream.destroy();
            return;
          }
          client.on("data", count);
          upstream.on("data", count);
          client.pipe(upstream);
          upstream.pipe(client);
          client.resume();
          const close = () => {
            client.destroy();
            upstream.destroy();
          };
          client.on("error", close);
          upstream.on("error", close);
          upstream.on("close", () => client.end());
          client.on("close", () => upstream.destroy());
        },
        (error: unknown) => {
          this.#log(`bot ${botId}: preview ${containerPort}: ${(error as Error).message}`);
          client.destroy();
        },
      );
    });
    await new Promise<void>((resolve, reject) => {
      server.once("error", reject);
      server.listen(port, "127.0.0.1", () => {
        server.off("error", reject);
        resolve();
      });
    });
    return { server, sockets };
  }

  async #save(botId: string): Promise<void> {
    await this.#registry.setNote(`${NOTE}${botId}`, JSON.stringify(this.list(botId)));
  }

  /** Share a container port; the same port again returns its existing preview. */
  async share(botId: string, containerPort: number): Promise<Preview> {
    if (!Number.isInteger(containerPort) || containerPort < 1 || containerPort > 65535) {
      throw new Error("port must be 1–65535");
    }
    const key = `${botId}:${containerPort}`;
    const existing = this.#live.get(key);
    if (existing) return existing.preview;
    const { server, sockets } = await this.#listen(botId, containerPort);
    const port = (server.address() as { port: number }).port;
    try {
      const { url } = await this.#host.publishPreview(botId, port, containerPort);
      const preview = { botId, containerPort, port, url, createdAt: new Date().toISOString() };
      this.#live.set(key, { preview, server, sockets });
      await this.#save(botId);
      return preview;
    } catch (error) {
      server.close();
      throw error;
    }
  }

  async unshare(botId: string, containerPort: number): Promise<boolean> {
    const key = `${botId}:${containerPort}`;
    const live = this.#live.get(key);
    if (!live) return false;
    this.#live.delete(key);
    await this.#host.unpublishPreview(botId, live.preview.port).catch((error: unknown) =>
      this.#log(`bot ${botId}: unpublish preview: ${(error as Error).message}`),
    );
    for (const socket of live.sockets) socket.destroy();
    live.server.close();
    await this.#save(botId);
    return true;
  }

  async unshareAll(botId: string): Promise<void> {
    for (const preview of this.list(botId)) await this.unshare(botId, preview.containerPort);
    await this.#registry.setNote(`${NOTE}${botId}`, "");
  }

  /** Startup: bring back each bot's previews on their old ports where possible, republished. */
  async restore(botIds: readonly string[]): Promise<void> {
    for (const botId of botIds) {
      const note = await this.#registry.note(`${NOTE}${botId}`);
      if (!note?.text) continue;
      let saved: Preview[] = [];
      try {
        saved = JSON.parse(note.text) as Preview[];
      } catch {
        continue;
      }
      for (const old of saved) {
        try {
          const { server, sockets } = await this.#listen(botId, old.containerPort, old.port).catch(() =>
            this.#listen(botId, old.containerPort),
          );
          const port = (server.address() as { port: number }).port;
          const { url } = await this.#host.publishPreview(botId, port, old.containerPort);
          this.#live.set(`${botId}:${old.containerPort}`, {
            preview: { ...old, port, url },
            server,
            sockets,
          });
        } catch (error) {
          this.#log(`bot ${botId}: restore preview ${old.containerPort}: ${(error as Error).message}`);
        }
      }
      await this.#save(botId);
    }
  }

  close(): void {
    for (const live of this.#live.values()) {
      for (const socket of live.sockets) socket.destroy();
      live.server.close();
    }
    this.#live.clear();
  }
}
