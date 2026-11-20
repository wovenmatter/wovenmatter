import type { AssistantMessage, ToolResultMessage } from "@earendil-works/pi-ai";
import { contentText } from "@earendil-works/pi-ai";
import { type EntryRecord, ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import type { Bot, BotManager } from "./bots.ts";
import type { HostChannel } from "./host/channel.ts";
import type { MirrorBot, MirrorConversation, MirrorForum, MirrorItem } from "./protocol.ts";
import type { ForumStore } from "./storage/forum.ts";
import type { BotRecord } from "./storage/registry.ts";
import { hiddenInput, messageText, publishedPage } from "./transcript.ts";

/** Items (or posts) in one push. */
export const MIRROR_BATCH = 200;
const FORUM = "forum";

type Built = { readonly item: MirrorItem; readonly entry: number; readonly n: number };
type ForumUsage = NonNullable<MirrorBot["forumUsage"]>[number];

const usageOf = (message: AssistantMessage): MirrorItem["usage"] | undefined => {
  const usage = message.usage;
  if (!usage || !(usage.input || usage.output || usage.cacheRead || usage.cacheWrite)) return undefined;
  return {
    model: `${message.provider}/${message.model}`,
    input: usage.input,
    output: usage.output,
    cacheRead: usage.cacheRead,
    cacheWrite: usage.cacheWrite,
    cost: usage.cost?.total ?? 0,
  };
};

/**
 * The library items of one conversation's own entries, oldest first: user text, assistant text,
 * each tool call with its result, an error, a stop. A tool call whose result is not among the
 * entries yet (and the conversation has not moved on) holds back its entry and everything after:
 * `heldAt` is that entry's id.
 */
export function mirrorItems(entries: readonly EntryRecord[]): { items: Built[]; heldAt?: number } {
  const results = new Map<string, ToolResultMessage>();
  for (const entry of entries) {
    for (const message of entry.model ?? []) {
      if (message.role === "toolResult") results.set(message.toolCallId, message as ToolResultMessage);
    }
  }
  const spoken = (entry: EntryRecord) =>
    (entry.model ?? []).some((message) => message.role === "user" || message.role === "assistant");
  const items: Built[] = [];
  for (const [index, entry] of entries.entries()) {
    if (hiddenInput(entry)) continue;
    const built: MirrorItem[] = [];
    for (const message of entry.model ?? []) {
      if (message.role === "user") {
        const text = messageText(message);
        if (text) built.push({ key: "", conversationId: entry.conversationId, createdAt: message.timestamp, kind: "user", text });
        continue;
      }
      if (message.role !== "assistant") continue;
      const createdAt = typeof message.timestamp === "number" ? message.timestamp : Date.now();
      const usage = usageOf(message);
      const first = built.length;
      let text = "";
      const flush = () => {
        if (text) built.push({ key: "", conversationId: entry.conversationId, createdAt, kind: "assistant", text });
        text = "";
      };
      for (const block of message.content) {
        if (block.type === "text") text += block.text;
        if (block.type !== "toolCall") continue;
        flush();
        const result = results.get(block.id);
        if (!result && !entries.slice(index + 1).some(spoken)) return { items, heldAt: entry.id };
        // A page `render_html` published is saved in place of the call, once.
        const page = publishedPage(result);
        if (page) {
          built.push({ key: "", conversationId: entry.conversationId, createdAt, kind: "page", page });
          continue;
        }
        const output = result ? contentText(result.content) : undefined;
        built.push({
          key: "",
          conversationId: entry.conversationId,
          createdAt,
          kind: "tool",
          tool: {
            name: block.name,
            input: JSON.stringify(block.arguments ?? {}),
            ...(output !== undefined ? { output } : {}),
            failed: result ? result.isError : true,
          },
        });
      }
      flush();
      if (message.stopReason === "error") {
        built.push({
          key: "",
          conversationId: entry.conversationId,
          createdAt,
          kind: "error",
          text: message.errorMessage ?? "model error",
        });
      } else if (message.stopReason === "aborted") {
        built.push({ key: "", conversationId: entry.conversationId, createdAt, kind: "stopped" });
      }
      // The turn's usage rides on its text, or its first item when it has none.
      const carrier = built.slice(first).find((item) => item.kind === "assistant") ?? built[first];
      if (usage && carrier) carrier.usage = usage;
    }
    for (const [n, item] of built.entries()) {
      item.key = n === 0 ? String(entry.id) : `${entry.id}.${n}`;
      items.push({ item, entry: entry.id, n });
    }
  }
  return { items };
}

/** Consecutive slices of at most `size`, each with the entry (or post) id it covers through. */
function batches<T>(list: readonly T[], idOf: (value: T) => number, upTo: number, size = MIRROR_BATCH) {
  const out: { slice: T[]; upTo: number }[] = [];
  for (let index = 0; index < list.length; index += size) {
    const next = list[index + size];
    out.push({ slice: list.slice(index, index + size), upTo: next === undefined ? upTo : idOf(next) - 1 });
  }
  return out;
}

/**
 * The library copy of the bots: each bot's main channel and threads, and the Forum, pushed to the
 * server above the checkpoints the server keeps (nothing about the copy is stored here). On every
 * connection, and after any failure, the checkpoints are asked for again; then work follows
 * commits (debounced) plus a slow sweep. The server skips items it already has, so a resend is
 * harmless.
 */
export class LibraryMirror {
  readonly #manager: BotManager;
  readonly #forum: ForumStore;
  readonly #host: HostChannel;
  readonly #log: (message: string) => void;
  readonly #debounceMs: number;
  readonly #timers = new Map<string, NodeJS.Timeout>();
  readonly #running = new Map<string, Promise<void>>();
  readonly #again = new Set<string>();
  /** What was last pushed of each bot's (and the Forum's) names and conversations. */
  readonly #meta = new Map<string, string>();
  readonly #sweep: NodeJS.Timeout;
  readonly #stopListening: () => void;
  #checkpoints: Promise<{ bots: Map<string, number>; forum: { at: number } }> | undefined;
  #closed = false;

  constructor(options: {
    manager: BotManager;
    forum: ForumStore;
    host: HostChannel;
    log?: (message: string) => void;
    debounceMs?: number;
    sweepMs?: number;
  }) {
    this.#manager = options.manager;
    this.#forum = options.forum;
    this.#host = options.host;
    this.#log = options.log ?? (() => {});
    this.#debounceMs = options.debounceMs ?? 1000;
    this.#sweep = setInterval(() => void this.sweep(), options.sweepMs ?? 60_000);
    this.#sweep.unref();
    this.#stopListening = options.host.onConnected(() => {
      this.#forget();
      void this.sweep();
    });
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

  schedule(key: string): void {
    if (this.#closed || this.#timers.has(key)) return;
    const timer = setTimeout(() => {
      this.#timers.delete(key);
      void this.flush(key);
    }, this.#debounceMs);
    timer.unref();
    this.#timers.set(key, timer);
  }

  scheduleForum(): void {
    this.schedule(FORUM);
  }

  /** Every bot (deleted ones too) and the Forum. */
  async sweep(): Promise<void> {
    const registry = this.#manager.registry;
    const ids = [
      ...(await registry.list().catch(() => [])),
      ...(await registry.listDeleted().catch(() => [])),
    ].map((record) => record.id);
    for (const id of ids) await this.flush(id);
    await this.flush(FORUM);
  }

  /** The user purged a bot: the server drops its copy. A failure is retried on the next connection. */
  async purged(botId: string): Promise<void> {
    try {
      await this.#host.call("mirror.purge", { botId });
      (await this.#checkpoints)?.bots.delete(botId);
      this.#meta.delete(botId);
    } catch (error) {
      this.#log(`bot ${botId}: library copy not removed yet: ${(error as Error).message}`);
    }
  }

  /** Send everything new for one bot (or the Forum); one flush at a time per key. */
  flush(key: string): Promise<void> {
    const running = this.#running.get(key);
    if (running) {
      this.#again.add(key);
      return running;
    }
    const work = (key === FORUM ? this.#flushForum() : this.#flushBot(key))
      .catch((error: unknown) => {
        this.#forget();
        this.#log(`${key === FORUM ? "forum" : `bot ${key}`}: library copy: ${(error as Error).message}`);
      })
      .finally(() => {
        this.#running.delete(key);
        if (this.#again.delete(key)) this.schedule(key);
      });
    this.#running.set(key, work);
    return work;
  }

  /** Ask the server for its checkpoints again before the next push. */
  #forget(): void {
    this.#checkpoints = undefined;
    this.#meta.clear();
  }

  #loadCheckpoints() {
    this.#checkpoints ??= (async () => {
      const reply = await this.#host.call("mirror.checkpoints", {});
      const bots = new Map(Object.entries(reply.bots ?? {}).map(([id, at]) => [id, Number(at) || 0]));
      // A bot the server holds that is gone here was purged while the server was away.
      const registry = this.#manager.registry;
      for (const id of bots.keys()) {
        if (!(await registry.get(id)) && !(await registry.deletedAt(id))) void this.purged(id);
      }
      return { bots, forum: { at: Number(reply.forum) || 0 } };
    })();
    const pending = this.#checkpoints;
    pending.catch(() => {
      if (this.#checkpoints === pending) this.#checkpoints = undefined;
    });
    return pending;
  }

  async #flushBot(botId: string): Promise<void> {
    if (this.#closed || !this.#host.connected) return;
    const registry = this.#manager.registry;
    const live = await registry.get(botId);
    const record: (BotRecord & { deletedAt?: string }) | undefined =
      live ?? (await registry.listDeleted()).find((bot) => bot.id === botId);
    if (!record) return;
    const checkpoints = await this.#loadCheckpoints();
    const from = checkpoints.bots.get(botId) ?? 0;
    const conversations: MirrorConversation[] = [
      { conversationId: ROOT_CONVERSATION_ID, kind: "main", createdAt: record.createdAt },
      ...(await registry.listThreads(botId)).map((thread) => ({
        conversationId: thread.conversationId,
        kind: "thread" as const,
        parentConversationId: thread.parentConversationId,
        ...(thread.title ? { title: thread.title } : {}),
        pinned: thread.pinned === true,
        createdAt: thread.createdAt,
      })),
    ];
    const bot: MirrorBot["bot"] = {
      id: record.id,
      name: record.name,
      kind: record.kind,
      manager: record.manager,
      ...(record.managerId ? { managerId: record.managerId } : {}),
      orchestrator: record.orchestrator,
      deleted: !live,
      createdAt: record.createdAt,
    };
    let items: Built[] = [];
    let forumUsage: (ForumUsage & { entry: number })[] = [];
    let upTo = from;
    if (live) {
      const open = await this.#manager.get(botId);
      // Everything up to this watermark is committed; later commits get higher ids.
      const watermark = await open.latestEntryId();
      if (watermark > from) {
        upTo = watermark;
        for (const { conversationId } of conversations) {
          const entries: EntryRecord[] = [];
          for await (const entry of open.ownEntries(conversationId, from)) {
            if (entry.id > watermark) break;
            entries.push(entry);
          }
          const built = mirrorItems(entries);
          items.push(...built.items);
          if (built.heldAt !== undefined) upTo = Math.min(upTo, built.heldAt - 1);
        }
        items = items.filter((built) => built.entry <= upTo).sort((a, b) => a.entry - b.entry || a.n - b.n);
        // A Forum reply's turn runs in the bot's seat, which is not mirrored: only its usage is.
        for (const seat of await this.#forum.seatsOf(botId)) {
          if (seat.conversationId === undefined) continue;
          for await (const entry of open.ownEntries(seat.conversationId, from)) {
            if (entry.id > upTo) break;
            let n = 0;
            for (const message of entry.model ?? []) {
              if (message.role !== "assistant") continue;
              const usage = usageOf(message as AssistantMessage);
              if (usage) {
                const createdAt = typeof message.timestamp === "number" ? message.timestamp : Date.now();
                forumUsage.push({ key: n ? `${entry.id}.${n}` : String(entry.id), roomId: seat.roomId, createdAt, usage, entry: entry.id });
              }
              n += 1;
            }
          }
        }
        forumUsage = forumUsage.sort((a, b) => a.entry - b.entry);
      }
    }
    const meta = JSON.stringify([bot, conversations]);
    if (upTo <= from && this.#meta.get(botId) === meta) return;
    const pushes = items.length ? batches(items, (built) => built.entry, upTo) : [{ slice: [], upTo }];
    let after = from;
    for (const push of pushes) {
      if (this.#closed) return;
      const usage = forumUsage
        .filter((entry) => entry.entry > after && entry.entry <= push.upTo)
        .map(({ entry: _entry, ...rest }) => rest);
      await this.#host.call("mirror.bot", {
        bot,
        conversations,
        items: push.slice.map((built) => built.item),
        ...(usage.length ? { forumUsage: usage } : {}),
        upTo: push.upTo,
      });
      after = push.upTo;
      checkpoints.bots.set(botId, push.upTo);
    }
    this.#meta.set(botId, meta);
  }

  async #flushForum(): Promise<void> {
    if (this.#closed || !this.#host.connected) return;
    const checkpoints = await this.#loadCheckpoints();
    const rooms: MirrorForum["rooms"] = (await this.#forum.rooms()).map((room) => ({
      roomId: room.id,
      ...(room.parentPostId !== undefined ? { parentPostId: room.parentPostId, pinned: room.pinned } : {}),
      ...(room.title ? { title: room.title } : {}),
      createdAt: room.createdAt,
    }));
    const meta = JSON.stringify(rooms);
    for (;;) {
      if (this.#closed) return;
      const from = checkpoints.forum.at;
      const posts = await this.#forum.postsAbove(from, MIRROR_BATCH);
      if (!posts.length && this.#meta.get(FORUM) === meta) return;
      const upTo = posts.at(-1)?.id ?? from;
      await this.#host.call("mirror.forum", {
        rooms,
        posts: posts.map((post) => ({
          id: post.id,
          roomId: post.roomId,
          author: post.author,
          ...(post.botId ? { botId: post.botId } : {}),
          name: post.name,
          text: post.text,
          ...(post.visualReply ? { visualReply: post.visualReply } : {}),
          createdAt: Date.parse(post.createdAt),
        })),
        upTo,
      });
      checkpoints.forum.at = upTo;
      this.#meta.set(FORUM, meta);
      if (posts.length < MIRROR_BATCH) return;
    }
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#stopListening();
    clearInterval(this.#sweep);
    for (const timer of this.#timers.values()) clearTimeout(timer);
    this.#timers.clear();
    await Promise.allSettled([...this.#running.values()]);
  }
}
