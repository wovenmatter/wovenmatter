import type { AssistantMessage, ToolResultMessage } from "@earendil-works/pi-ai";
import { contentText } from "@earendil-works/pi-ai";
import { type EntryRecord, ROOT_CONVERSATION_ID } from "@earendil-works/pi-durable";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { Bot, BotManager } from "./bots.ts";
import { conversationId as toConversationId } from "./ids.ts";
import type { HostChannel } from "./host/channel.ts";
import type { MirrorBot, MirrorConversation, MirrorForum, MirrorItem, MirrorSeatUsage } from "./protocol.ts";
import type { ForumStore } from "./storage/forum.ts";
import type { BotRecord } from "./storage/registry.ts";
import { hiddenInput, messageText, publishedVisualReply } from "./transcript.ts";

/** Items (or posts) in one push. */
export const MIRROR_BATCH = 200;
const FORUM = "forum";

type Built = { readonly item: MirrorItem; readonly entry: number; readonly n: number };

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

/** The agent session a chat message came from (`message_bot`), when not the person. */
function sender(entry: EntryRecord): MirrorItem["from"] {
  const data = entry.data as { from?: { name?: unknown; sessionId?: unknown } } | undefined;
  const from = data && typeof data === "object" && !Array.isArray(data) ? data.from : undefined;
  return typeof from?.name === "string" && typeof from.sessionId === "string"
    ? { name: from.name, sessionId: from.sessionId }
    : undefined;
}

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
        const from = sender(entry);
        if (text) {
          built.push({
            key: "",
            conversationId: entry.conversationId,
            createdAt: message.timestamp,
            kind: "user",
            text,
            ...(from ? { from } : {}),
          });
        }
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
        if (block.type === "thinking" && block.thinking.trim()) {
          flush();
          built.push({ key: "", conversationId: entry.conversationId, createdAt, kind: "thinking", text: block.thinking });
        }
        if (block.type !== "toolCall") continue;
        flush();
        const result = results.get(block.id);
        if (!result && !entries.slice(index + 1).some(spoken)) return { items, heldAt: entry.id };
        // A visual reply `render_html` published is saved in place of the call, once.
        const visualReply = publishedVisualReply(result);
        if (visualReply) {
          built.push({ key: "", conversationId: entry.conversationId, createdAt, kind: "visualReply", visualReply });
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
  #checkpoints:
    | Promise<{ bots: Map<string, number>; forum: { at: number }; seats: Map<string, number> }>
    | undefined;
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
      // A commit may be a seat's: its work goes with the Forum.
      advance: () => {
        this.schedule(bot.id);
        this.schedule(FORUM);
      },
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
      const seats = new Map(Object.entries(reply.seats ?? {}).map(([id, at]) => [id, Number(at) || 0]));
      return { bots, forum: { at: Number(reply.forum) || 0 }, seats };
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
      }
    }
    const meta = JSON.stringify([bot, conversations]);
    if (upTo <= from && this.#meta.get(botId) === meta) return;
    const pushes = items.length ? batches(items, (built) => built.entry, upTo) : [{ slice: [], upTo }];
    for (const push of pushes) {
      if (this.#closed) return;
      await this.#host.call("mirror.bot", {
        bot,
        conversations,
        items: push.slice.map((built) => built.item),
        upTo: push.upTo,
      });
      checkpoints.bots.set(botId, push.upTo);
    }
    this.#meta.set(botId, meta);
  }

  /**
   * The Forum's rooms and posts above the Forum's checkpoint, with what bots did in their seats
   * above each bot's seat checkpoint: their tool calls and thinking, and every model turn's usage.
   * Seat work is saved in its room in time order with the posts, so one push carries both, up to a
   * time both reach. Every conversation a bot ever heard a room through is read, so the work of a
   * seat that is gone (its thread deleted, the bot switched out) is still saved.
   */
  async #flushForum(): Promise<void> {
    if (this.#closed || !this.#host.connected) return;
    const checkpoints = await this.#loadCheckpoints();
    for (;;) {
      if (this.#closed) return;
      const known = await this.#forum.rooms();
      const roomIds = new Set(known.map((room) => room.id));
      const rooms: MirrorForum["rooms"] = known.map((room) => ({
        roomId: room.id,
        ...(room.parentPostId !== undefined ? { parentPostId: room.parentPostId, pinned: room.pinned } : {}),
        ...(room.title ? { title: room.title } : {}),
        createdAt: room.createdAt,
      }));
      const meta = JSON.stringify(rooms);
      const from = checkpoints.forum.at;
      const posts = await this.#forum.postsAbove(from, MIRROR_BATCH);
      // A full batch of posts reaches only as far as its last; so does a full batch of seat work.
      let until = posts.length === MIRROR_BATCH ? Date.parse(posts.at(-1)?.createdAt ?? "") : Number.POSITIVE_INFINITY;
      const seats = [];
      for (const record of await this.#manager.registry.list()) {
        const seat = await this.#seatWork(record, roomIds, checkpoints.seats.get(record.id) ?? 0);
        if (!seat) continue;
        if (seat.next !== undefined) until = Math.min(until, seat.next);
        seats.push(seat);
      }
      const shownPosts = posts.filter((post) => Date.parse(post.createdAt) <= until);
      const upTo = shownPosts.length === posts.length ? (posts.at(-1)?.id ?? from) : (shownPosts.at(-1)?.id ?? from);
      const seatItems: NonNullable<MirrorForum["seatItems"]> = [];
      const seatUsage: MirrorSeatUsage[] = [];
      const covered: Record<string, number> = {};
      for (const seat of seats) {
        // Work after `until` waits for the next push, and so does every entry after it.
        const late = [...seat.items.map((built) => built), ...seat.usage].filter((work) => work.createdAt > until);
        const through = Math.min(seat.upTo, ...late.map((work) => work.entry - 1));
        for (const built of seat.items) {
          if (built.entry <= through) seatItems.push({ botId: seat.botId, name: seat.name, item: built.item });
        }
        for (const { entry, ...usage } of seat.usage) if (entry <= through) seatUsage.push(usage);
        if (through > seat.from) covered[seat.botId] = through;
      }
      const moved = upTo > from || Object.keys(covered).length > 0;
      if (!moved && this.#meta.get(FORUM) === meta) return;
      await this.#host.call("mirror.forum", {
        rooms,
        posts: shownPosts.map((post) => ({
          id: post.id,
          roomId: post.roomId,
          author: post.author,
          ...(post.botId ? { botId: post.botId } : {}),
          name: post.name,
          text: post.text,
          ...(post.visualReply ? { visualReply: post.visualReply } : {}),
          createdAt: Date.parse(post.createdAt),
        })),
        ...(seatItems.length ? { seatItems } : {}),
        ...(seatUsage.length ? { seatUsage } : {}),
        ...(Object.keys(covered).length ? { seats: covered } : {}),
        upTo,
      });
      checkpoints.forum.at = upTo;
      for (const [botId, through] of Object.entries(covered)) checkpoints.seats.set(botId, through);
      this.#meta.set(FORUM, meta);
      if (!moved) return;
    }
  }

  /**
   * One bot's seat work above `from`: its tool calls and thinking in rooms that still exist (a
   * deleted thread keeps only its usage), each model turn's usage, how far that is complete
   * (`upTo`), and when the first piece left out of a full batch happened (`next`).
   */
  async #seatWork(record: BotRecord, rooms: ReadonlySet<number>, from: number) {
    const conversations = await this.#forum.seatConversations(record.id);
    if (!conversations.length) return undefined;
    const open = await this.#manager.get(record.id);
    // The bot's own watermark covers only the seats it has now; a gone seat's entries count too.
    let watermark = await open.latestEntryId();
    for (const { conversationId } of conversations) {
      const conversation = await open.harness.conversation(toConversationId(conversationId), BACKGROUND_CONTEXT);
      const page = await conversation?.entries({ order: "descending" }, 1, undefined, BACKGROUND_CONTEXT);
      watermark = Math.max(watermark, page?.items[0]?.id ?? 0);
    }
    if (watermark <= from) return undefined;
    let upTo = watermark;
    const items: { item: MirrorItem; entry: number; createdAt: number }[] = [];
    const usage: (MirrorSeatUsage & { entry: number })[] = [];
    for (const { conversationId, roomId } of conversations) {
      const entries: EntryRecord[] = [];
      for await (const entry of open.ownEntries(conversationId, from)) {
        if (entry.id > watermark) break;
        entries.push(entry);
      }
      const built = mirrorItems(entries);
      if (built.heldAt !== undefined) upTo = Math.min(upTo, built.heldAt - 1);
      if (rooms.has(roomId)) {
        for (const { item, entry } of built.items) {
          // Posts and visual replies are the Forum's own; what the bot said in its seat is its own.
          if (item.kind === "thinking" || (item.kind === "tool" && item.tool?.name !== "forum_post")) {
            const { usage: _usage, ...work } = item;
            items.push({ item: { ...work, conversationId: roomId }, entry, createdAt: item.createdAt });
          }
        }
      }
      for (const entry of entries) {
        let n = 0;
        for (const message of entry.model ?? []) {
          if (message.role !== "assistant") continue;
          const used = usageOf(message as AssistantMessage);
          if (used) {
            const createdAt = typeof message.timestamp === "number" ? message.timestamp : Date.now();
            const key = n ? `${entry.id}.${n}` : String(entry.id);
            usage.push({ botId: record.id, key, roomId, createdAt, usage: used, entry: entry.id });
          }
          n += 1;
        }
      }
    }
    const work = [...items, ...usage].sort((a, b) => a.entry - b.entry).filter((piece) => piece.entry <= upTo);
    let next: number | undefined;
    if (work.length > MIRROR_BATCH) {
      const cut = work[MIRROR_BATCH] as { entry: number; createdAt: number };
      upTo = cut.entry - 1;
      next = cut.createdAt;
    }
    return {
      botId: record.id,
      name: record.name,
      from,
      upTo,
      next,
      items: items.filter((piece) => piece.entry <= upTo).sort((a, b) => a.entry - b.entry),
      usage: usage.filter((piece) => piece.entry <= upTo),
    };
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
