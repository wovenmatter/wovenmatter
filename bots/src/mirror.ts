import { createHash } from "node:crypto";
import type { Bot, BotManager } from "./bots.ts";
import type { HostAPI, MirrorConversation, MirrorEntry } from "./host/client.ts";
import { displayEntry } from "./transcript.ts";

const CHECKPOINT = "mirror.checkpoint.";
const META = "mirror.meta.";
const BATCH = 200;

/**
 * Mirrors each bot's conversations (main channel and threads, chat-visible messages only) to
 * the host, which writes them into its library copy so they sync everywhere. The host upserts by
 * (bot, entry id), so a resend after a crash is harmless. Work is driven by commits (debounced)
 * plus a slow sweep that retries after a failure.
 */
export class ConversationMirror {
  readonly #manager: BotManager;
  readonly #host: Pick<HostAPI, "mirror">;
  readonly #log: (message: string) => void;
  readonly #debounceMs: number;
  readonly #timers = new Map<string, NodeJS.Timeout>();
  readonly #running = new Map<string, Promise<void>>();
  readonly #again = new Set<string>();
  readonly #sweep: NodeJS.Timeout;
  #closed = false;

  constructor(options: {
    manager: BotManager;
    host: Pick<HostAPI, "mirror">;
    log?: (message: string) => void;
    debounceMs?: number;
    sweepMs?: number;
  }) {
    this.#manager = options.manager;
    this.#host = options.host;
    this.#log = options.log ?? (() => {});
    this.#debounceMs = options.debounceMs ?? 1000;
    this.#sweep = setInterval(() => void this.sweep(), options.sweepMs ?? 60_000);
    this.#sweep.unref();
  }

  /** Follow a bot's commits. */
  attach(bot: Bot): void {
    const observation = bot.harness.observeCommits({
      advance: () => this.schedule(bot.id),
      end: () => {},
    });
    void bot.harness.closed.then(() => observation.detach());
    this.schedule(bot.id);
  }

  schedule(botId: string): void {
    if (this.#closed || this.#timers.has(botId)) return;
    const timer = setTimeout(() => {
      this.#timers.delete(botId);
      void this.flush(botId);
    }, this.#debounceMs);
    timer.unref();
    this.#timers.set(botId, timer);
  }

  async sweep(): Promise<void> {
    for (const record of await this.#manager.list().catch(() => [])) await this.flush(record.id);
  }

  /** Send everything new for one bot; one flush at a time per bot. */
  flush(botId: string): Promise<void> {
    const running = this.#running.get(botId);
    if (running) {
      this.#again.add(botId);
      return running;
    }
    const work = this.#flush(botId)
      .catch((error: unknown) => this.#log(`bot ${botId}: mirror: ${(error as Error).message}`))
      .finally(() => {
        this.#running.delete(botId);
        if (this.#again.delete(botId)) this.schedule(botId);
      });
    this.#running.set(botId, work);
    return work;
  }

  async #flush(botId: string): Promise<void> {
    if (this.#closed) return;
    const bot = await this.#manager.get(botId);
    const registry = this.#manager.registry;
    const checkpoint = Number((await registry.note(`${CHECKPOINT}${botId}`))?.text ?? 0) || 0;
    // Everything up to this watermark is committed; later commits get higher ids.
    const watermark = await bot.latestEntryId();
    const main = await bot.main();
    const threads = await registry.listThreads(botId);
    const conversations: MirrorConversation[] = [
      { conversationId: main.id, kind: "main" },
      ...threads.map((thread) => ({
        conversationId: thread.conversationId,
        kind: "thread" as const,
        parentConversationId: thread.parentConversationId,
        forkedAt: thread.forkedAt,
        ...(thread.title ? { title: thread.title } : {}),
        ...(thread.pinned ? { pinned: true } : {}),
        createdAt: thread.createdAt,
      })),
    ];
    const metaHash = createHash("sha256")
      .update(JSON.stringify([bot.record.name, conversations]))
      .digest("hex");
    const metaChanged = (await registry.note(`${META}${botId}`))?.text !== metaHash;
    const entries: MirrorEntry[] = [];
    if (watermark > checkpoint) {
      for (const { conversationId } of conversations) {
        for await (const entry of bot.ownEntries(conversationId, checkpoint)) {
          if (entry.id > watermark) break;
          const shown = displayEntry(entry);
          if (!shown) continue;
          const timestamp = entry.model?.find((message) => "timestamp" in message)?.timestamp;
          entries.push({
            id: shown.id,
            conversationId: shown.conversationId,
            role: shown.role,
            text: shown.text,
            ...(shown.error ? { error: shown.error } : {}),
            ...(shown.stopped ? { stopped: true as const } : {}),
            createdAt: new Date(typeof timestamp === "number" ? timestamp : Date.now()).toISOString(),
          });
        }
      }
    }
    if (!entries.length && !metaChanged) {
      if (watermark > checkpoint) await registry.setNote(`${CHECKPOINT}${botId}`, String(watermark));
      return;
    }
    entries.sort((a, b) => a.id - b.id);
    const identity = { id: bot.id, name: bot.record.name };
    if (!entries.length) await this.#host.mirror(botId, { bot: identity, conversations, entries: [] });
    for (let index = 0; index < entries.length; index += BATCH) {
      const slice = entries.slice(index, index + BATCH);
      await this.#host.mirror(botId, { bot: identity, conversations, entries: slice });
      const last = slice.at(-1)?.id ?? checkpoint;
      const next = index + BATCH >= entries.length ? watermark : last;
      await registry.setNote(`${CHECKPOINT}${botId}`, String(next));
    }
    if (entries.length && watermark > checkpoint) {
      await registry.setNote(`${CHECKPOINT}${botId}`, String(watermark));
    }
    await registry.setNote(`${META}${botId}`, metaHash);
  }

  async close(): Promise<void> {
    this.#closed = true;
    clearInterval(this.#sweep);
    for (const timer of this.#timers.values()) clearTimeout(timer);
    this.#timers.clear();
    await Promise.allSettled([...this.#running.values()]);
  }
}
