import type { AssistantMessage } from "@earendil-works/pi-ai";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { JsonValue } from "@earendil-works/chord/json";
import {
  type Conversation,
  type Cursor,
  InboxDoc,
  LiveDoc,
  type SettledSubmissionRecord,
} from "@earendil-works/pi-durable";
import { type Bot, type BotManager, NO_MODEL_MESSAGE, NotFoundError } from "./bots.ts";
import { conversationId as toConversationId, entryId as toEntryId } from "./ids.ts";
import { errorIssue } from "./issues.ts";
import type {
  ForumPost,
  ForumRoomSnapshot,
  ForumScheduleSummary,
  ForumState,
  ForumThreadSummary,
} from "./protocol.ts";
import {
  AWAY,
  DELIVERY_KIND,
  type ForumPostRecord,
  type ForumRepeat,
  type ForumRoom,
  type ForumSchedule,
  type ForumSeat,
  ForumStore,
} from "./storage/forum.ts";
import type { BotRecord, BotRegistry } from "./storage/registry.ts";
import type { TitleGenerator } from "./titles.ts";
import { assistantText } from "./transcript.ts";
import { isTimeZone, parseTimeOfDay, zonedEpoch, zonedTime } from "./zoned-time.ts";

const ctx = BACKGROUND_CONTEXT;

/** What bots call the user (`bot_notes`); unset: "the user". */
export const USER_NAME = "user.name";
const PAUSED = "forum.paused";
export { DELIVERY_KIND };

const HISTORY_LIMIT = 200;
/** A bot that fell further behind gets the newest of what it missed and a count. */
const MAX_UNSEEN = 50;
/** Forum posts before a thread's starting post that a thread seat starts with. */
const THREAD_CONTEXT_POSTS = 20;
const MAX_POST_CHARS = 100_000;
const READ_POST_CHARS = 2000;
const PREVIEW_CHARS = 80;
/** A repeating post still fires this long after its minute, for a check that ran late. */
const SCHEDULE_GRACE_MS = 5 * 60_000;
const SCHEDULE_CHECK_MS = 20_000;

/** A request the Forum refuses: the reason is for the user or the bot that asked. */
export class ForumError extends Error {
  override name = "ForumError";
}

export type ForumEvents = {
  /** A post is new, or its thread or notes changed. */
  readonly post?: (post: ForumPost) => void;
  /** The bots with a turn running in a room changed. */
  readonly thinking?: (roomId: number, botIds: string[]) => void;
  /** What `state()` returns changed. */
  readonly changed?: () => void;
};

export type ForumOptions = {
  readonly store: ForumStore;
  readonly registry: BotRegistry;
  /** Late-bound: the manager opens bots, and they ask the Forum for their seats. */
  readonly manager: () => BotManager;
  /** Titles for threads, from their first post; without it they stay untitled. */
  readonly titles?: TitleGenerator;
  readonly events?: ForumEvents;
  readonly log?: (message: string) => void;
  readonly now?: () => number;
};

export type ScheduleInput = {
  readonly id?: string;
  readonly text: string;
  readonly mentions?: readonly string[];
  readonly everyone?: boolean;
  readonly repeat: ForumRepeat;
  readonly time?: string;
  readonly weekday?: number;
  readonly at?: number;
  readonly timeZone: string;
};

type SeatState = {
  /** Deliveries and settles of one seat run one at a time. */
  chain: Promise<void>;
  /** Inputs handed to the seat whose turn has not ended. */
  waiting: number;
  /** The stored place was checked against the conversation since this process started. */
  checked: boolean;
  /** The answer last posted for the bot, so two inputs one answer settles post it once. */
  posted?: number;
};

/** How a turn that owed the user a reply ended: with a message to post, or without one. */
type Outcome =
  | { readonly text: string }
  | { readonly reason: string; readonly issue?: "signIn" | "limit" };

const clip = (text: string, max: number) => (text.length > max ? `${text.slice(0, max)}…` : text);

const oneLine = (text: string) => text.replace(/\s+/g, " ").trim();

const list = (items: readonly string[]) =>
  items.length <= 1
    ? (items[0] ?? "")
    : `${items.slice(0, -1).join(", ")} and ${items[items.length - 1]}`;

function deliveryTo(data: JsonValue | undefined): number {
  if (!data || typeof data !== "object" || Array.isArray(data)) return 0;
  const to = data.to;
  return typeof to === "number" && Number.isSafeInteger(to) && to > 0 ? to : 0;
}

/** Whether a repeating post fires on that day of the week. */
function repeatsOn(schedule: ForumSchedule, weekday: number): boolean {
  if (schedule.repeat === "daily") return true;
  if (schedule.repeat === "weekdays") return weekday >= 1 && weekday <= 5;
  return schedule.repeat === "weekly" && schedule.weekday === weekday;
}

/**
 * The local day whose occurrence of a repeating post is due at `now`: its time has come, no more
 * than the grace period ago. Yesterday counts too, for a post due just before midnight.
 */
function dueDay(schedule: ForumSchedule, now: number): string | undefined {
  const time = parseTimeOfDay(schedule.time ?? "");
  if (!time) return undefined;
  const today = zonedTime(now, schedule.timeZone);
  for (const offset of [0, -1]) {
    const date = new Date(Date.UTC(today.year, today.month - 1, today.day + offset));
    if (!repeatsOn(schedule, date.getUTCDay())) continue;
    const [year, month, day] = [date.getUTCFullYear(), date.getUTCMonth() + 1, date.getUTCDate()];
    const due = zonedEpoch(year, month, day, time.hour, time.minute, schedule.timeZone);
    if (now >= due && now - due <= SCHEDULE_GRACE_MS) return `${year}-${month}-${day}`;
  }
  return undefined;
}

/** When a scheduled post next fires after `now` (epoch ms), if it does. */
export function nextScheduledAt(schedule: ForumSchedule, now: number): number | undefined {
  if (schedule.repeat === "once") return schedule.at;
  const time = parseTimeOfDay(schedule.time ?? "");
  if (!time) return undefined;
  const today = zonedTime(now, schedule.timeZone);
  for (let offset = 0; offset <= 7; offset += 1) {
    const date = new Date(Date.UTC(today.year, today.month - 1, today.day + offset));
    if (!repeatsOn(schedule, date.getUTCDay())) continue;
    const at = zonedEpoch(
      date.getUTCFullYear(),
      date.getUTCMonth() + 1,
      date.getUTCDate(),
      time.hour,
      time.minute,
      schedule.timeZone,
    );
    if (at > now) return at;
  }
  return undefined;
}

/**
 * The Forum: one group chat of the user and every bot on this machine, with threads. Posts live
 * in the shared database. Each bot hears a room through a conversation of its own (its seat) and
 * speaks with `forum_post`; nothing a bot says in its seat reaches the room otherwise, except the
 * reply it owes the user after a mention.
 */
export class Forum {
  readonly store: ForumStore;
  readonly #registry: BotRegistry;
  readonly #manager: () => BotManager;
  readonly #titles: TitleGenerator | undefined;
  readonly #events: ForumEvents;
  readonly #log: (message: string) => void;
  readonly #now: () => number;
  readonly #seats = new Map<string, SeatState>();
  readonly #titling = new Set<number>();
  /** Bots whose seats are held while their environment updates, with the rooms that were stopped. */
  readonly #held = new Map<string, Set<number>>();
  readonly #abort = new AbortController();
  #timer: NodeJS.Timeout | undefined;
  #ticking = false;
  #started = false;
  #closed = false;

  constructor(options: ForumOptions) {
    this.store = options.store;
    this.#registry = options.registry;
    this.#manager = options.manager;
    this.#titles = options.titles;
    this.#events = options.events ?? {};
    this.#log = options.log ?? (() => {});
    this.#now = options.now ?? Date.now;
  }

  /**
   * Seat every bot, pick up turns that were running before a restart, hand out posts that were
   * stored but not delivered, and start the scheduled posts' clock.
   */
  async start(options: { readonly scheduleCheckMs?: number } = {}): Promise<void> {
    if (this.#started) return;
    this.#started = true;
    await this.#seatBots();
    for (const record of await this.#registry.list()) {
      const bot = await this.#manager()
        .get(record.id)
        .catch(() => undefined);
      if (bot) await this.#adopt(bot);
    }
    this.#timer = setInterval(() => {
      if (this.#ticking) return;
      this.#ticking = true;
      this.tick()
        .catch((error: unknown) => this.#log(`forum schedules: ${String(error)}`))
        .finally(() => {
          this.#ticking = false;
        });
    }, options.scheduleCheckMs ?? SCHEDULE_CHECK_MS);
    this.#timer.unref?.();
  }

  async close(): Promise<void> {
    this.#closed = true;
    this.#abort.abort();
    if (this.#timer) clearInterval(this.#timer);
    await this.idle();
  }

  /** Resolves once every seat's queued delivery and settle has run (tests, shutdown). */
  async idle(): Promise<void> {
    for (;;) {
      const before = [...this.#seats.values()].map((seat) => seat.chain);
      await Promise.all(before);
      const after = [...this.#seats.values()].map((seat) => seat.chain);
      const same = after.length === before.length;
      if (same && after.every((chain, index) => chain === before[index])) return;
    }
  }

  // MARK: The user and the roster

  async userName(): Promise<string | undefined> {
    const name = (await this.#registry.note(USER_NAME))?.text.trim();
    return name || undefined;
  }

  async paused(): Promise<boolean> {
    return (await this.#registry.note(PAUSED))?.text === "1";
  }

  /** Whether a bot is in the Forum: the user's choice, else every bot but Admin Bot. */
  async isActive(record: BotRecord): Promise<boolean> {
    return (await this.store.activeChoices()).get(record.id) ?? record.kind !== "admin";
  }

  /** Live bots that are in the Forum. */
  async #activeBots(): Promise<BotRecord[]> {
    const choices = await this.store.activeChoices();
    return (await this.#registry.list()).filter(
      (record) => choices.get(record.id) ?? record.kind !== "admin",
    );
  }

  /** The bots that hear a room: everyone in the Forum, or of those the ones seated in a thread. */
  async #hearers(room: ForumRoom): Promise<BotRecord[]> {
    const active = await this.#activeBots();
    if (room.parentPostId === undefined) return active;
    const seated = new Set((await this.store.seats(room.id)).map((seat) => seat.botId));
    return active.filter((record) => seated.has(record.id));
  }

  /**
   * Give every bot in the Forum its seat. A new bot, and one that was away (deleted, then
   * restored), hears the Forum from the next post. Returns the bots that were away.
   */
  async #seatBots(): Promise<string[]> {
    const main = await this.store.mainRoom();
    const latest = await this.store.latestPostId(main.id);
    const seats = new Map((await this.store.seats(main.id)).map((seat) => [seat.botId, seat]));
    const back: string[] = [];
    for (const record of await this.#activeBots()) {
      const seat = seats.get(record.id);
      if (!seat) await this.store.addSeat(main.id, record.id, latest);
      else if (seat.baseline === AWAY) {
        await this.store.reseat(main.id, record.id, latest);
        back.push(record.id);
      }
    }
    return back;
  }

  /** The conversations a bot hears the Forum through (memory extraction reads them). */
  async conversationsOf(botId: string): Promise<number[]> {
    return (await this.store.seatsOf(botId)).flatMap((seat) =>
      seat.conversationId === undefined ? [] : [seat.conversationId],
    );
  }

  // MARK: Bot lifecycle

  /** A bot's harness opened: a new bot is seated, and turns it was running are picked up. */
  async botOpened(bot: Bot): Promise<void> {
    if (!this.#started || this.#closed) return;
    const back = await this.#seatBots();
    if (back.includes(bot.id)) {
      // Deleting it closed its harness mid-turn: that turn must not pick up where it left off.
      const seats = await this.store.seatsOf(bot.id);
      await Promise.all(
        seats.map((seat) =>
          this.#enqueue(seat.roomId, bot.id, async () => void (await this.#stop(seat))),
        ),
      );
    }
    await this.#adopt(bot);
    this.#events.changed?.();
  }

  /** A bot was deleted: it leaves its threads, owes nothing, and hears nothing until restored. */
  async botDeleted(botId: string): Promise<void> {
    const main = await this.store.mainRoom();
    await this.store.unseat(botId, main.id);
    this.#forgetSeats(botId);
    this.#events.changed?.();
  }

  async botPurged(botId: string): Promise<void> {
    await this.store.forgetBot(botId);
    this.#forgetSeats(botId);
    this.#events.changed?.();
  }

  #forgetSeats(botId: string): void {
    const rooms = new Set<number>();
    for (const [key, seat] of this.#seats) {
      const [roomId, id] = this.#parse(key);
      if (id !== botId) continue;
      if (seat.waiting > 0) rooms.add(roomId);
      this.#seats.delete(key);
    }
    for (const roomId of rooms) this.#emitThinking(roomId);
  }

  /**
   * After a start: follow the inputs a seat's conversation still holds (queued or in a running
   * turn) to their end, settle what ended while nobody watched, and deliver what waits.
   */
  async #adopt(bot: Bot): Promise<void> {
    const seats = await this.store.seatsOf(bot.id);
    if (!seats.length) return;
    const live = await bot.harness.inspect(ctx).catch(() => undefined);
    for (const seat of seats) {
      const id = seat.conversationId;
      const conversation =
        id === undefined
          ? undefined
          : await bot.harness.conversation(toConversationId(id), ctx).catch(() => undefined);
      let watched = false;
      for (const record of live?.submissions ?? []) {
        if (!conversation || record.conversationId !== id || record.type !== "input") continue;
        const to = await this.#deliveredTo(bot, conversation, record.id, record.entry);
        const submission = to ? await bot.harness.submission(record.id, ctx) : undefined;
        if (!submission || !to) continue;
        this.#watch(seat.roomId, bot.id, to, submission.wait(ctx));
        watched = true;
      }
      if (!watched) void this.#enqueue(seat.roomId, bot.id, () => this.#settleIdle(seat.roomId, bot.id));
      void this.#deliver(seat.roomId, bot.id);
    }
  }

  /** How far a seat input takes the seat: from its entry once placed, else from the inbox. */
  async #deliveredTo(
    bot: Bot,
    conversation: Conversation,
    submissionId: number,
    entry: number | undefined,
  ): Promise<number> {
    if (entry !== undefined) {
      const id = toEntryId(entry);
      const page = await conversation.entries({ minEntryId: id, maxEntryId: id }, 1, undefined, ctx);
      const found = page.items[0];
      return found?.kind === DELIVERY_KIND ? deliveryTo(found.data) : 0;
    }
    const inbox = await bot.harness.snapshot(InboxDoc, conversation.id, ctx);
    const item = (inbox?.items ?? []).find((queued) => queued.id === submissionId);
    return item && item.mode !== "write" && item.entry?.kind === DELIVERY_KIND
      ? deliveryTo(item.entry.data)
      : 0;
  }

  // MARK: State for clients

  async state(): Promise<ForumState> {
    const main = await this.store.mainRoom();
    const choices = await this.store.activeChoices();
    const live = await this.#registry.list();
    const rooms = await this.store.threads();
    const counts = await this.store.postCounts();
    const firsts = await this.store.firstPosts();
    const parents = await this.store.postsById(rooms.flatMap((room) => room.parentPostId ?? []));
    const liveIds = new Set(live.map((record) => record.id));
    const seated = new Map<number, string[]>();
    for (const seat of await this.store.seats()) {
      if (!liveIds.has(seat.botId)) continue;
      seated.set(seat.roomId, [...(seated.get(seat.roomId) ?? []), seat.botId]);
    }
    const threads: ForumThreadSummary[] = rooms.map((room) => ({
      roomId: room.id,
      parentPostId: room.parentPostId ?? 0,
      ...(room.title ? { title: room.title } : {}),
      preview: clip(
        oneLine((firsts.get(room.id) ?? parents.get(room.parentPostId ?? 0))?.text ?? ""),
        PREVIEW_CHARS,
      ),
      createdAt: room.createdAt,
      ...(room.pinned ? { pinned: true as const } : {}),
      replies: counts.get(room.id) ?? 0,
      botIds: seated.get(room.id) ?? [],
    }));
    return {
      mainRoomId: main.id,
      paused: await this.paused(),
      latestPostId: await this.store.latestPostId(),
      bots: live.map((record) => ({
        botId: record.id,
        active: choices.get(record.id) ?? record.kind !== "admin",
      })),
      threads,
    };
  }

  /** Stored posts as clients see them, with each Forum post's thread and each post's notes. */
  async #wire(records: readonly ForumPostRecord[]): Promise<ForumPost[]> {
    if (!records.length) return [];
    const notes = await this.store.unanswered(records.map((record) => record.id));
    const threads = new Map(
      (await this.store.threads()).map((room) => [room.parentPostId ?? 0, room]),
    );
    const counts = threads.size ? await this.store.postCounts() : new Map<number, number>();
    return records.map((record) => {
      const thread = threads.get(record.id);
      const unanswered = notes.get(record.id);
      return {
        id: record.id,
        roomId: record.roomId,
        author: record.author,
        ...(record.botId ? { botId: record.botId } : {}),
        name: record.name,
        text: record.text,
        ...(record.mentions.length ? { mentions: [...record.mentions] } : {}),
        ...(record.scheduled ? { scheduled: true as const } : {}),
        ...(record.auto ? { auto: true as const } : {}),
        createdAt: record.createdAt,
        ...(thread ? { thread: { roomId: thread.id, replies: counts.get(thread.id) ?? 0 } } : {}),
        ...(unanswered?.length
          ? {
              unanswered: unanswered.map((note) => ({
                botId: note.botId,
                name: note.name,
                reason: note.reason,
                ...(note.issue ? { issue: note.issue } : {}),
              })),
            }
          : {}),
      };
    });
  }

  async #room(roomId: number | undefined): Promise<ForumRoom> {
    if (roomId === undefined) return this.store.mainRoom();
    const room = await this.store.room(roomId);
    if (!room) throw new NotFoundError(`no Forum room ${roomId}`);
    return room;
  }

  /** A room as a client opens it: its newest posts and who is working there. */
  async snapshot(roomId?: number): Promise<ForumRoomSnapshot> {
    const main = await this.store.mainRoom();
    const room = await this.#room(roomId);
    const page = await this.posts(room.id, undefined, HISTORY_LIMIT);
    const parent =
      room.parentPostId === undefined ? undefined : await this.store.post(room.parentPostId);
    return {
      roomId: room.id,
      mainRoomId: main.id,
      ...(parent ? { parent: (await this.#wire([parent]))[0] as ForumPost } : {}),
      posts: page.posts,
      hasEarlier: page.hasEarlier,
      thinking: this.thinking(room.id),
    };
  }

  /** Up to `limit` posts of a room before post `before` (the newest when undefined). */
  async posts(
    roomId: number,
    before: number | undefined,
    limit = HISTORY_LIMIT,
  ): Promise<{ posts: ForumPost[]; hasEarlier: boolean }> {
    const room = await this.#room(roomId);
    const size = Math.min(Math.max(limit, 1), HISTORY_LIMIT);
    const records = await this.store.postsBefore(room.id, before, size + 1);
    const hasEarlier = records.length > size;
    return { posts: await this.#wire(hasEarlier ? records.slice(1) : records), hasEarlier };
  }

  /** Bots with a turn running in a room. */
  thinking(roomId: number): string[] {
    const bots: string[] = [];
    for (const [key, seat] of this.#seats) {
      const [room, botId] = this.#parse(key);
      if (room === roomId && seat.waiting > 0) bots.push(botId);
    }
    return bots.sort();
  }

  #emitThinking(roomId: number): void {
    this.#events.thinking?.(roomId, this.thinking(roomId));
  }

  async #emitPost(record: ForumPostRecord | undefined): Promise<void> {
    if (!record) return;
    const [post] = await this.#wire([record]);
    if (post) this.#events.post?.(post);
  }

  // MARK: Posting

  /** The user's post (or one the runtime posts for them on a schedule). */
  async postAsUser(input: {
    readonly roomId?: number;
    readonly text: string;
    readonly mentions?: readonly string[];
    readonly everyone?: boolean;
    readonly scheduled?: boolean;
    /** An agent session that posts for the user, by its name. */
    readonly agent?: string;
  }): Promise<ForumPost> {
    if (!input.text.trim()) throw new ForumError("a post needs some text");
    if (input.text.length > MAX_POST_CHARS) throw new ForumError("that post is too long");
    const room = await this.#room(input.roomId);
    await this.#seatBots();
    const hearers = await this.#hearers(room);
    const inForum = new Set((await this.#activeBots()).map((record) => record.id));
    // Only bots that are in the Forum can be asked; in a thread, asking one adds it.
    const mentions = input.everyone
      ? hearers.map((record) => record.id)
      : [...new Set(input.mentions ?? [])].filter((id) => inForum.has(id));
    const hearing = new Set(hearers.map((record) => record.id));
    const join =
      room.parentPostId === undefined ? [] : mentions.filter((id) => !hearing.has(id));
    const record = await this.store.addPost(
      {
        roomId: room.id,
        author: input.agent ? "agent" : "user",
        name: input.agent ?? (await this.userName()) ?? "",
        text: input.text,
        mentions,
        scheduled: input.scheduled === true,
        auto: false,
      },
      { join },
    );
    await this.#published(record, room);
    return (await this.#wire([record]))[0] as ForumPost;
  }

  /**
   * A bot's `forum_post`, made from `conversationId`: to that seat's room, or from any other
   * conversation of the bot to the Forum, or to a thread it is in (`threadId`).
   */
  async postAsBot(
    botId: string,
    input: { readonly text: string; readonly threadId?: number; readonly conversationId: number },
  ): Promise<ForumPostRecord> {
    const record = await this.#registry.get(botId);
    if (!record) throw new NotFoundError(`no bot ${botId}`);
    if (!input.text.trim()) throw new ForumError("a post needs some text");
    if (input.text.length > MAX_POST_CHARS) throw new ForumError("that post is too long");
    if (!(await this.isActive(record))) {
      throw new ForumError(
        "You are not in the Forum. The user can add you from the Forum's member list.",
      );
    }
    if (await this.paused()) {
      throw new ForumError(
        "The Forum is paused. Nothing can be posted until the user resumes it.",
      );
    }
    await this.#seatBots();
    const here = await this.store.seatOfConversation(botId, input.conversationId);
    const room = await this.#room(input.threadId ?? here?.roomId);
    const seat = await this.store.seat(room.id, botId);
    if (!seat) throw new ForumError("You are not in that thread.");
    const fromSeat = seat.conversationId === input.conversationId;
    // Its post answers the mentions it had been shown, which only its own seat tells.
    if (fromSeat) {
      const bot = await this.#manager().get(botId);
      const conversation = await bot.harness.conversation(
        toConversationId(input.conversationId),
        ctx,
      );
      const shown = conversation ? (await this.#newestDelivery(conversation))?.to : undefined;
      if (shown) await this.store.clearOwed(room.id, botId, shown);
    }
    const post = await this.store.addPost({
      roomId: room.id,
      author: "bot",
      botId,
      name: record.name,
      text: input.text,
      mentions: [],
      scheduled: false,
      auto: false,
      origin: input.conversationId,
    });
    await this.#published(post, room);
    return post;
  }

  /** A room read back for a bot's `forum_read`, newest last. */
  async read(
    botId: string,
    input: {
      readonly threadId?: number;
      readonly before?: number;
      readonly limit?: number;
      readonly conversationId: number;
    },
  ): Promise<string> {
    const record = await this.#registry.get(botId);
    if (!record) throw new NotFoundError(`no bot ${botId}`);
    if (!(await this.isActive(record))) {
      throw new ForumError(
        "You are not in the Forum. The user can add you from the Forum's member list.",
      );
    }
    await this.#seatBots();
    const here = await this.store.seatOfConversation(botId, input.conversationId);
    const room = await this.#room(input.threadId ?? here?.roomId);
    if (!(await this.store.seat(room.id, botId))) {
      throw new ForumError("You are not in that thread.");
    }
    const limit = Math.min(Math.max(input.limit ?? 40, 1), HISTORY_LIMIT);
    const records = await this.store.postsBefore(room.id, input.before, limit + 1);
    const more = records.length > limit;
    const shown = more ? records.slice(1) : records;
    const user = (await this.userName()) ?? "The user";
    const where = room.parentPostId === undefined ? "The Forum" : `Forum thread ${room.id}`;
    if (!shown.length) return `${where} has no ${input.before ? "earlier " : ""}posts.`;
    const lines = shown.map((post) => {
      const who = this.#author(post, botId, user);
      return `#${post.id} ${who} (${post.createdAt}): ${clip(post.text, READ_POST_CHARS)}`;
    });
    const first = shown[0]?.id;
    const earlier = more ? ` (earlier ones: forum_read with before ${first})` : "";
    return [`${where}, posts #${first} to #${shown.at(-1)?.id}${earlier}:`, ...lines].join("\n");
  }

  #author(post: ForumPostRecord, readerId: string, user: string): string {
    if (post.author === "user") return post.scheduled ? `${user} (scheduled post)` : user;
    if (post.author === "agent") return `${post.name} (an agent session of ${user}'s)`;
    return post.botId === readerId ? "You" : post.name;
  }

  /** Tell clients about a stored post, title its thread, and hand it to the bots that hear it. */
  async #published(record: ForumPostRecord, room: ForumRoom): Promise<void> {
    await this.#emitPost(record);
    if (room.parentPostId !== undefined) {
      // The parent's reply count.
      await this.#emitPost(await this.store.post(room.parentPostId));
      this.#title(room, record);
    }
    // The newest post's id, and a thread's reply count in the thread list.
    this.#events.changed?.();
    for (const hearer of await this.#hearers(room)) void this.#deliver(room.id, hearer.id);
  }

  /** Title a thread from its first post, in the background, as bot threads are titled. */
  #title(room: ForumRoom, post: ForumPostRecord): void {
    const titles = this.#titles;
    if (!titles || room.title || this.#titling.has(room.id) || this.#closed) return;
    this.#titling.add(room.id);
    void titles
      .generate(post.text, this.#abort.signal)
      .then(async (title) => {
        if (title && (await this.store.setRoomTitleIfUntitled(room.id, title))) {
          this.#events.changed?.();
        }
      })
      .catch((error: unknown) => {
        if (!this.#abort.signal.aborted) this.#log(`forum thread title: ${String(error)}`);
      })
      .finally(() => this.#titling.delete(room.id));
  }

  // MARK: Threads, pause, membership

  /** The thread of a Forum post, started with the post's author in it when there was none. */
  async createThread(postId: number): Promise<ForumThreadSummary> {
    const post = await this.store.post(postId);
    const main = await this.store.mainRoom();
    if (!post) throw new NotFoundError(`no Forum post ${postId}`);
    if (post.roomId !== main.id) throw new ForumError("threads start from a Forum post");
    const existing = await this.store.threadOf(postId);
    const thread = existing ?? (await this.store.createThread(postId));
    if (!existing) {
      const author = post.botId ? await this.#registry.get(post.botId) : undefined;
      if (author && (await this.isActive(author))) {
        await this.store.addSeat(thread.id, author.id, 0);
      }
      await this.#emitPost(post);
      this.#events.changed?.();
    }
    return this.#thread(thread.id);
  }

  async setThreadTitle(roomId: number, title: string): Promise<ForumThreadSummary> {
    const room = await this.#room(roomId);
    if (room.parentPostId === undefined) throw new ForumError("only threads can be renamed");
    await this.store.setRoomTitle(room.id, title);
    this.#events.changed?.();
    return this.#thread(room.id);
  }

  async setThreadPinned(roomId: number, pinned: boolean): Promise<ForumThreadSummary> {
    const room = await this.#room(roomId);
    if (room.parentPostId === undefined) throw new ForumError("only threads can be pinned");
    await this.store.setRoomPinned(room.id, pinned);
    this.#events.changed?.();
    return this.#thread(room.id);
  }

  async #thread(roomId: number): Promise<ForumThreadSummary> {
    const thread = (await this.state()).threads.find((item) => item.roomId === roomId);
    if (!thread) throw new NotFoundError(`no Forum thread ${roomId}`);
    return thread;
  }

  /**
   * Pause: stop every running Forum turn and hold deliveries. Resume: each bot gets what it missed
   * as one input, with a reminder of any mention it had been shown and still owes a reply.
   */
  async setPaused(paused: boolean): Promise<ForumState> {
    if (paused !== (await this.paused())) {
      await this.#registry.setNote(PAUSED, paused ? "1" : "");
      const seats = await this.store.seats();
      if (paused) {
        // On each seat's own line: a delivery under way finishes first and is then stopped.
        await Promise.all(
          seats.map((seat) =>
            this.#enqueue(seat.roomId, seat.botId, async () => void (await this.#stop(seat))),
          ),
        );
      } else {
        await this.#seatBots();
        for (const seat of await this.store.seats()) {
          void this.#deliver(seat.roomId, seat.botId, { missed: true });
        }
      }
      this.#events.changed?.();
    }
    return this.state();
  }

  /** Switch a bot in or out. Out: its Forum turns stop and it leaves its threads. */
  async setBotActive(botId: string, active: boolean): Promise<ForumState> {
    const record = await this.#manager().record(botId);
    if (active !== (await this.isActive(record))) {
      const main = await this.store.mainRoom();
      await this.store.setActive(botId, active);
      if (active) {
        await this.store.reseat(main.id, botId, await this.store.latestPostId(main.id));
      } else {
        const seats = await this.store.seatsOf(botId);
        await this.store.unseat(botId, main.id);
        await Promise.all(
          seats.map((seat) =>
            this.#enqueue(seat.roomId, botId, async () => void (await this.#stop(seat))),
          ),
        );
      }
      this.#events.changed?.();
    }
    return this.state();
  }

  /**
   * Stop a seat's turn and take its place back to what its conversation was really given. Returns
   * whether a turn was running or waiting.
   */
  async #stop(seat: ForumSeat): Promise<boolean> {
    if (seat.conversationId === undefined) return false;
    const bot = await this.#manager()
      .get(seat.botId)
      .catch(() => undefined);
    const conversation = await bot?.harness.conversation(
      toConversationId(seat.conversationId),
      ctx,
    );
    if (!bot || !conversation) return false;
    const working = await this.#busy(bot, conversation);
    // Aborting withdraws inputs that were still queued, so those posts are unseen again.
    await conversation
      .abort(ctx)
      .catch((error: unknown) => this.#log(`forum: stopping ${seat.botId}: ${String(error)}`));
    const current = await this.store.seat(seat.roomId, seat.botId);
    if (current) await this.#reconcile(bot, conversation, current);
    return working;
  }

  /**
   * A bot's environment is about to be updated: stop its Forum turns and hold its seats, so
   * nothing runs in its container meanwhile. `release()` ends the hold.
   */
  async hold(botId: string): Promise<void> {
    const stopped = this.#held.get(botId) ?? new Set<number>();
    this.#held.set(botId, stopped);
    await Promise.all(
      (await this.store.seatsOf(botId)).map((seat) =>
        this.#enqueue(seat.roomId, botId, async () => {
          if (await this.#stop(seat)) stopped.add(seat.roomId);
        }),
      ),
    );
  }

  /**
   * The update is over: the bot's seats hear again. A seat whose turn was stopped is told so
   * (`note`), with what it missed and the replies it still owes.
   */
  async release(botId: string, note: string): Promise<void> {
    const stopped = this.#held.get(botId);
    if (!stopped) return;
    this.#held.delete(botId);
    for (const seat of await this.store.seatsOf(botId)) {
      if (stopped.has(seat.roomId)) {
        void this.#deliver(seat.roomId, botId, { note });
        continue;
      }
      // A turn that ended just as the hold began was not settled then.
      void this.#enqueue(seat.roomId, botId, () => this.#settleIdle(seat.roomId, botId));
      void this.#deliver(seat.roomId, botId);
    }
  }

  // MARK: Seats and delivery

  #key(roomId: number, botId: string): string {
    return `${roomId}:${botId}`;
  }

  #parse(key: string): [number, string] {
    const at = key.indexOf(":");
    return [Number(key.slice(0, at)), key.slice(at + 1)];
  }

  #seatState(roomId: number, botId: string): SeatState {
    const key = this.#key(roomId, botId);
    let state = this.#seats.get(key);
    if (!state) {
      state = { chain: Promise.resolve(), waiting: 0, checked: false };
      this.#seats.set(key, state);
    }
    return state;
  }

  #enqueue(roomId: number, botId: string, work: () => Promise<void>): Promise<void> {
    const state = this.#seatState(roomId, botId);
    const next = state.chain.then(work).catch((error: unknown) => {
      if (!this.#closed) this.#log(`forum: room ${roomId}, bot ${botId}: ${String(error)}`);
    });
    state.chain = next;
    return next;
  }

  /**
   * Follow one seat input (it took the seat to post `to`) until its turn ends, then settle what
   * the bot owes from how that turn ended.
   */
  #watch(roomId: number, botId: string, to: number, done: Promise<SettledSubmissionRecord>): void {
    const state = this.#seatState(roomId, botId);
    state.waiting += 1;
    if (state.waiting === 1) this.#emitThinking(roomId);
    void done
      .then(
        (record) => record,
        () => undefined,
      )
      .then((record) => {
        // A deleted bot's seat state is gone; its count no longer matters.
        if (this.#seats.get(this.#key(roomId, botId)) !== state) return;
        state.waiting -= 1;
        if (state.waiting === 0) this.#emitThinking(roomId);
        void this.#enqueue(roomId, botId, () => this.#ended(roomId, botId, to, record));
      });
  }

  /** The seat's conversation, created on first use; its stored place is checked once per start. */
  async #conversation(bot: Bot, seat: ForumSeat): Promise<Conversation> {
    const state = this.#seatState(seat.roomId, bot.id);
    const existing =
      seat.conversationId === undefined
        ? undefined
        : await bot.harness.conversation(toConversationId(seat.conversationId), ctx);
    if (existing) {
      if (!state.checked) await this.#reconcile(bot, existing, seat);
      state.checked = true;
      return existing;
    }
    // A plain conversation of the bot's own, not a fork: it starts empty and follows its profile.
    const created = await bot.harness.createConversation({ ownership: { kind: "ownerless" } }, ctx);
    await this.store.setSeatConversation(seat.roomId, bot.id, created.id);
    // Created on the profile's main model: move it to the fallback the bot runs now, if any.
    await this.#manager().applyProfile(bot.id);
    state.checked = true;
    return created;
  }

  /** The newest input a seat's conversation holds, and how far it took the seat. */
  async #newestDelivery(
    conversation: Conversation,
  ): Promise<{ readonly entryId: number; readonly to: number } | undefined> {
    let cursor: Cursor | undefined;
    do {
      const page = await conversation.entries({ order: "descending" }, 200, cursor, ctx);
      for (const entry of page.items) {
        if (entry.kind === DELIVERY_KIND) return { entryId: entry.id, to: deliveryTo(entry.data) };
      }
      cursor = page.next;
    } while (cursor !== undefined);
    return undefined;
  }

  /**
   * Set a seat's place from its conversation: the newest post an input there carries, placed or
   * still queued, and never before where the bot joined. A crash between handing an input over
   * and recording it, or an abort that withdrew queued inputs, leaves the stored place wrong.
   */
  async #reconcile(bot: Bot, conversation: Conversation, seat: ForumSeat): Promise<void> {
    const placed = (await this.#newestDelivery(conversation))?.to ?? 0;
    const inbox = await bot.harness.snapshot(InboxDoc, conversation.id, ctx);
    let queued = 0;
    for (const item of inbox?.items ?? []) {
      if (item.mode !== "write" && item.entry?.kind === DELIVERY_KIND) {
        queued = Math.max(queued, deliveryTo(item.entry.data));
      }
    }
    const place = Math.max(seat.baseline, placed, queued);
    if (place !== seat.cursor) await this.store.setSeatCursor(seat.roomId, seat.botId, place);
  }

  async #busy(bot: Bot, conversation: Conversation): Promise<boolean> {
    const live = await bot.harness.snapshot(LiveDoc, conversation.id, ctx);
    if (live?.run !== undefined) return true;
    const inbox = await bot.harness.snapshot(InboxDoc, conversation.id, ctx);
    return (inbox?.items ?? []).some((item) => item.mode !== "write");
  }

  /**
   * Hand a bot the posts of a room it has not seen, as one input to its seat: a new turn when it
   * is idle, a steer when it is working. After a pause (`missed`) or a stopped turn (`note`, which
   * is always delivered) it is also reminded of mentions it had been shown and still owes a reply.
   */
  #deliver(
    roomId: number,
    botId: string,
    options: { readonly missed?: boolean; readonly note?: string } = {},
  ): Promise<void> {
    return this.#enqueue(roomId, botId, async () => {
      if (this.#closed || this.#held.has(botId) || (await this.paused())) return;
      const record = await this.#registry.get(botId);
      const room = await this.store.room(roomId);
      const seated = await this.store.seat(roomId, botId);
      if (!record || !room || !seated || !(await this.isActive(record))) return;
      const bot = await this.#manager().get(botId);
      const conversation = await this.#conversation(bot, seated);
      // The check above may have moved the seat's place.
      const seat = (await this.store.seat(roomId, botId)) ?? seated;
      const unseen = (await this.store.postsAfter(roomId, seat.cursor)).filter(
        (post) => !(post.botId === botId && post.origin === conversation.id),
      );
      const owed = await this.store.owed(roomId, botId);
      const reminders =
        options.missed || options.note ? owed.filter((id) => id <= seat.cursor) : [];
      // The bot's own posts from another conversation ride along; they never start a turn.
      if (!unseen.some((post) => post.botId !== botId) && !reminders.length && !options.note) {
        return;
      }
      const agent = await conversation.agent(ctx);
      if (!agent.model) {
        // It cannot answer: say so on the mentions, and keep the posts for when it has a model.
        const asked = new Set([...reminders, ...unseen.map((post) => post.id)]);
        for (const postId of owed.filter((id) => asked.has(id))) {
          await this.store.addUnanswered(roomId, {
            postId,
            botId,
            name: record.name,
            reason: NO_MODEL_MESSAGE,
          });
          await this.#emitPost(await this.store.post(postId));
        }
        return;
      }
      const user = (await this.userName()) ?? "the user";
      const instructions = await this.#instructions(room, botId, user);
      if (agent.instructions !== instructions) await conversation.configure({ instructions }, ctx);
      const to = unseen.at(-1)?.id ?? seat.cursor;
      const submission = await conversation.submit(
        {
          type: "input",
          content: await this.#input({
            room,
            seat,
            botId,
            user,
            unseen,
            owed,
            reminders,
            missed: options.missed === true,
            ...(options.note ? { note: options.note } : {}),
          }),
          // A working bot gets it at its next step; `steeringMode: "all"` places all that queued.
          whenBusy: "steer",
          entry: { kind: DELIVERY_KIND, data: { room: roomId, to } },
        },
        ctx,
      );
      await this.store.setSeatCursor(roomId, botId, to);
      this.#watch(roomId, botId, to, submission.wait(ctx));
    });
  }

  /** What a seat's conversation is told the room is. No topic: only what it is and how it works. */
  async #instructions(room: ForumRoom, botId: string, user: string): Promise<string> {
    const others = (await this.#hearers(room))
      .filter((record) => record.id !== botId)
      .map((record) => record.name);
    const company = others.length
      ? `${user} and ${others.length === 1 ? "one other bot" : "these bots"}: ${list(others)}`
      : `${user}; no other bot is in it yet`;
    const rules = `You do not have to answer everything, and staying quiet is fine: what you write here without forum_post stays private to you. When ${user} @mentions you, reply with forum_post. forum_read shows earlier posts.`;
    if (room.parentPostId !== undefined) {
      return `This conversation is your seat in a Forum thread: a side conversation that ${user} started from one Forum post, with ${company}. Every post made in the thread is shown to you here, and forum_post from here posts to the thread. ${rules}`;
    }
    return `This conversation is your seat in the Forum: a group chat with ${company}. Every post made there is shown to you here. Post with forum_post when you have something to say. ${rules} You can use your timers to come back later.`;
  }

  async #input(input: {
    readonly room: ForumRoom;
    readonly seat: ForumSeat;
    readonly botId: string;
    readonly user: string;
    readonly unseen: readonly ForumPostRecord[];
    /** The user's posts the bot owes a reply to. */
    readonly owed: readonly number[];
    readonly reminders: readonly number[];
    readonly missed: boolean;
    /** Said first: why the seat's last turn was stopped. */
    readonly note?: string;
  }): Promise<string> {
    const { room, seat, botId, user, unseen, owed, reminders, missed } = input;
    const User = user === "the user" ? "The user" : user;
    const line = (post: ForumPostRecord) =>
      `#${post.id} ${this.#author(post, botId, User)}: ${post.text}`;
    // Its own unseen posts are the ones it made elsewhere: its seat does not know of them.
    const unseenLine = (post: ForumPostRecord) =>
      post.botId === botId
        ? `#${post.id} You (from another of your conversations): ${post.text}`
        : line(post);
    const thread = room.parentPostId !== undefined;
    const parts: string[] = [];
    const tag = thread ? `[Forum thread ${room.id}]` : "[Forum]";
    /** The first part says which room this is. */
    const lead = (text: string) => (parts.length ? text : `${tag} ${text}`);
    if (input.note) parts.push(lead(input.note));
    const starting = thread && seat.cursor === 0;
    if (starting) {
      // A thread seat starts with the post the thread came from and what led up to it.
      const parent = await this.store.post(room.parentPostId ?? 0);
      if (parent) {
        const before = await this.store.postsBefore(parent.roomId, parent.id, THREAD_CONTEXT_POSTS);
        parts.push(`${lead(`${User} started this thread from a Forum post`)}:\n${line(parent)}`);
        if (before.length) {
          parts.push(`Forum posts just before it:\n${before.map(line).join("\n")}`);
        }
      }
    }
    const shown = unseen.slice(-MAX_UNSEEN);
    const hidden = unseen.length - shown.length;
    if (shown.length) {
      const heading = missed
        ? "While the Forum was paused you missed these posts"
        : starting
          ? "Posts in this thread"
          : "New posts";
      const earlier = hidden
        ? ` (the newest ${shown.length}; ${hidden} earlier ones are not shown, forum_read shows them)`
        : "";
      parts.push(`${lead(heading)}${earlier}:\n${shown.map(unseenLine).join("\n")}`);
    }
    // Only replies still owed: a mention already noted as unanswered is not asked again.
    const asked = unseen.filter((post) => owed.includes(post.id)).map((post) => `#${post.id}`);
    if (asked.length) {
      parts.push(`${User} mentioned you in ${list(asked)}: reply with forum_post.`);
    }
    if (reminders.length) {
      const where = list(reminders.map((id) => `#${id}`));
      parts.push(
        lead(`You have not replied to ${user}'s mention in ${where} yet: reply with forum_post.`),
      );
    }
    return parts.join("\n\n");
  }

  /**
   * One seat input's turn ended (`record`; undefined when its wait failed with the harness).
   * Inputs a failed turn left queued are taken back, and the replies the bot owes for posts up
   * to `to` are settled from that turn: its answer is posted for it, or the user's post gets a
   * note saying why there is none.
   */
  async #ended(
    roomId: number,
    botId: string,
    to: number,
    record: SettledSubmissionRecord | undefined,
  ): Promise<void> {
    // Paused or held, the stop already took queued inputs back, and resuming reminds the bot.
    if (this.#closed || this.#held.has(botId) || (await this.paused())) return;
    const seat = await this.store.seat(roomId, botId);
    const bot = await this.#manager()
      .get(botId)
      .catch(() => undefined);
    const conversation =
      seat?.conversationId === undefined
        ? undefined
        : await bot?.harness.conversation(toConversationId(seat.conversationId), ctx);
    if (!seat || !bot || !conversation) return;
    // A turn that failed leaves later inputs queued until the next one arrives. Take them back,
    // so nothing looks busy, and hand those posts out again.
    const stranded = await this.#stranded(bot, conversation);
    if (stranded) {
      await conversation.abort(ctx).catch(() => {});
      await this.#reconcile(bot, conversation, seat);
    }
    // An input that was never placed showed the bot nothing: its posts are unseen again.
    if (record?.entry !== undefined) await this.#settleInput(bot, conversation, roomId, to, record);
    if (stranded) void this.#deliver(roomId, botId);
  }

  /** No turn is running, yet seat inputs are still queued: the turn before them failed. */
  async #stranded(bot: Bot, conversation: Conversation): Promise<boolean> {
    const live = await bot.harness.snapshot(LiveDoc, conversation.id, ctx);
    if (live?.run !== undefined) return false;
    const inbox = await bot.harness.snapshot(InboxDoc, conversation.id, ctx);
    return (inbox?.items ?? []).some(
      (item) => item.mode !== "write" && item.entry?.kind === DELIVERY_KIND,
    );
  }

  async #settleInput(
    bot: Bot,
    conversation: Conversation,
    roomId: number,
    to: number,
    record: SettledSubmissionRecord,
  ): Promise<void> {
    if (!(await this.store.owed(roomId, bot.id)).some((id) => id <= to)) return;
    const state = this.#seatState(roomId, bot.id);
    if (record.status === "done") {
      const answer = record.type === "input" ? record.answer : undefined;
      // One answer may settle two inputs (a steer placed mid-turn): it is posted once.
      if (answer !== undefined && state.posted === answer) {
        await this.store.clearOwed(roomId, bot.id, to);
        return;
      }
      const page =
        answer === undefined
          ? undefined
          : await conversation.entries({ minEntryId: answer, maxEntryId: answer }, 1, undefined, ctx);
      const message = (page?.items[0]?.model ?? []).find(
        (item): item is AssistantMessage => item.role === "assistant",
      );
      const text = assistantText(message).trim();
      if (text && answer !== undefined) state.posted = answer;
      await this.#settleOwed(
        bot,
        conversation,
        roomId,
        to,
        text ? { text } : { reason: "its turn ended without a message" },
      );
      return;
    }
    await this.#settleOwed(bot, conversation, roomId, to, await this.#failure(bot, conversation, record));
  }

  /** Why an input went unanswered, in words for the user, with the fix Settings has for it. */
  async #failure(
    bot: Bot,
    conversation: Conversation,
    record: Extract<SettledSubmissionRecord, { status: "unanswered" }>,
  ): Promise<Exclude<Outcome, { readonly text: string }>> {
    if (record.reason === "no_model") return { reason: NO_MODEL_MESSAGE };
    if (record.reason === "aborted") return { reason: "its reply was stopped" };
    // The failed response itself says more than the settlement: what the provider attached.
    const detail = typeof record.detail === "string" ? record.detail : undefined;
    const failed = await this.#lastAssistant(conversation, record.entry ?? 0);
    if (failed?.stopReason === "error") {
      const issue = errorIssue(failed);
      const reason = failed.errorMessage ?? detail ?? "the model failed";
      return { reason, ...(issue ? { issue } : {}) };
    }
    const live = await bot.harness.snapshot(LiveDoc, conversation.id, ctx);
    return { reason: detail ?? live?.runFailure?.detail ?? record.reason };
  }

  /** The newest assistant message after entry `after` that is not a tool call. */
  async #lastAssistant(
    conversation: Conversation,
    after: number,
  ): Promise<AssistantMessage | undefined> {
    let cursor: Cursor | undefined;
    do {
      const page = await conversation.entries({ order: "descending" }, 100, cursor, ctx);
      for (const entry of page.items) {
        if (entry.id <= after) return undefined;
        const message = (entry.model ?? []).find(
          (item): item is AssistantMessage => item.role === "assistant",
        );
        // Text before a tool call is not the turn's message.
        if (message && message.stopReason !== "toolUse") return message;
      }
      cursor = page.next;
    } while (cursor !== undefined);
    return undefined;
  }

  /** Store the outcome for every reply the bot owes for posts up to `to`, and tell clients. */
  async #settleOwed(
    bot: Bot,
    conversation: Conversation,
    roomId: number,
    to: number,
    outcome: Outcome,
  ): Promise<void> {
    const name = bot.record.name;
    const settled = await this.store.settleOwed(
      roomId,
      bot.id,
      to,
      "text" in outcome
        ? {
            post: {
              roomId,
              author: "bot",
              botId: bot.id,
              name,
              text: outcome.text,
              mentions: [],
              scheduled: false,
              auto: true,
              origin: conversation.id,
            },
          }
        : {
            unanswered: {
              name,
              reason: outcome.reason,
              ...(outcome.issue ? { issue: outcome.issue } : {}),
            },
          },
    );
    const room = await this.store.room(roomId);
    if (settled.post && room) await this.#published(settled.post, room);
    for (const postId of settled.noted) await this.#emitPost(await this.store.post(postId));
  }

  /**
   * Settle from the transcript alone, for a turn that ended while nothing followed it (a restart,
   * an update's hold): once the seat is idle, the bot's newest message since its newest input is
   * its reply to what that input and the ones before it asked.
   */
  async #settleIdle(roomId: number, botId: string): Promise<void> {
    if (this.#closed || this.#held.has(botId) || (await this.paused())) return;
    const owed = await this.store.owed(roomId, botId);
    if (!owed.length) return;
    const seat = await this.store.seat(roomId, botId);
    if (seat?.conversationId === undefined) return;
    const bot = await this.#manager()
      .get(botId)
      .catch(() => undefined);
    const conversation = await bot?.harness.conversation(
      toConversationId(seat.conversationId),
      ctx,
    );
    if (!bot || !conversation || (await this.#busy(bot, conversation))) return;
    const delivery = await this.#newestDelivery(conversation);
    if (!delivery || !owed.some((id) => id <= delivery.to)) return;
    const message = await this.#lastAssistant(conversation, delivery.entryId);
    let outcome: Outcome;
    if (message?.stopReason === "error") {
      const issue = errorIssue(message);
      outcome = { reason: message.errorMessage ?? "the model failed", ...(issue ? { issue } : {}) };
    } else if (message?.stopReason === "aborted") {
      outcome = { reason: "its reply was stopped" };
    } else {
      const text = message ? assistantText(message).trim() : "";
      const failure = (await bot.harness.snapshot(LiveDoc, conversation.id, ctx))?.runFailure;
      outcome = text
        ? { text }
        : failure?.reason === "no_model"
          ? { reason: NO_MODEL_MESSAGE }
          : failure?.reason === "aborted"
            ? { reason: "its reply was stopped" }
            : { reason: failure?.detail ?? failure?.reason ?? "its turn ended without a message" };
    }
    await this.#settleOwed(bot, conversation, roomId, delivery.to, outcome);
  }

  // MARK: Scheduled posts

  async schedules(): Promise<ForumScheduleSummary[]> {
    const now = this.#now();
    return (await this.store.schedules()).map((schedule) => {
      const nextAt = nextScheduledAt(schedule, now);
      return {
        id: schedule.id,
        text: schedule.text,
        ...(schedule.mentions.length ? { mentions: [...schedule.mentions] } : {}),
        ...(schedule.everyone ? { everyone: true as const } : {}),
        repeat: schedule.repeat,
        ...(schedule.time !== undefined ? { time: schedule.time } : {}),
        ...(schedule.weekday !== undefined ? { weekday: schedule.weekday } : {}),
        ...(schedule.at !== undefined ? { at: schedule.at } : {}),
        timeZone: schedule.timeZone,
        ...(nextAt !== undefined ? { nextAt } : {}),
      };
    });
  }

  async saveSchedule(input: ScheduleInput): Promise<ForumScheduleSummary[]> {
    if (!input.text.trim()) throw new ForumError("a scheduled post needs some text");
    if (input.text.length > MAX_POST_CHARS) throw new ForumError("that post is too long");
    if (!isTimeZone(input.timeZone)) throw new ForumError(`unknown time zone ${input.timeZone}`);
    const once = input.repeat === "once";
    if (once && !(typeof input.at === "number" && Number.isSafeInteger(input.at) && input.at > 0)) {
      throw new ForumError("a one-time post needs its date and time");
    }
    if (!once && !parseTimeOfDay(input.time ?? "")) {
      throw new ForumError("a repeating post needs its time of day as HH:MM");
    }
    const weekday = input.weekday ?? -1;
    if (input.repeat === "weekly" && !(Number.isInteger(weekday) && weekday >= 0 && weekday <= 6)) {
      throw new ForumError("a weekly post needs its day of the week");
    }
    const known = input.id === undefined ? [] : await this.store.schedules();
    if (input.id !== undefined && !known.some((item) => item.id === input.id)) {
      throw new NotFoundError("no such scheduled post");
    }
    const saved = await this.store.saveSchedule({
      ...(input.id !== undefined ? { id: input.id } : {}),
      text: input.text,
      mentions: input.everyone ? [] : [...new Set(input.mentions ?? [])],
      everyone: input.everyone === true,
      repeat: input.repeat,
      ...(once ? { at: input.at as number } : { time: input.time as string }),
      ...(input.repeat === "weekly" ? { weekday: input.weekday as number } : {}),
      timeZone: input.timeZone,
    });
    // Saved just after its time of day, it waits for the next one instead of posting at once.
    const due = once ? undefined : dueDay(saved, this.#now());
    if (due) await this.store.claimScheduleRun(saved.id, due);
    return this.schedules();
  }

  async deleteSchedule(id: string): Promise<ForumScheduleSummary[]> {
    if (!(await this.store.deleteSchedule(id))) throw new NotFoundError("no such scheduled post");
    return this.schedules();
  }

  /**
   * Post what is due. A one-time post fires once, however late. A repeating one fires once on each
   * of its days, and is skipped when the runtime was not running around its time.
   */
  async tick(): Promise<void> {
    if (this.#closed) return;
    const now = this.#now();
    for (const schedule of await this.store.schedules()) {
      if (schedule.repeat === "once") {
        if (schedule.at === undefined || schedule.at > now) continue;
        // Removed first, so a failed post is not repeated forever.
        if (!(await this.store.deleteSchedule(schedule.id))) continue;
      } else {
        const day = dueDay(schedule, now);
        if (!day || !(await this.store.claimScheduleRun(schedule.id, day))) continue;
      }
      await this.postAsUser({
        text: schedule.text,
        mentions: schedule.mentions,
        everyone: schedule.everyone,
        scheduled: true,
      }).catch((error: unknown) =>
        this.#log(`forum: scheduled post ${schedule.id}: ${String(error)}`),
      );
    }
  }
}

/** Open the Forum over the shared database: its tables exist and it has its room. */
export async function openForum(options: ForumOptions): Promise<Forum> {
  await options.store.createTables(new Date((options.now ?? Date.now)()).toISOString());
  return new Forum(options);
}
