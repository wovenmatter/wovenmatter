import { randomUUID } from "node:crypto";
import type { SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import type { VisualReply } from "../protocol.ts";

/** The Forum's shared tables. Bot tables start with `bot_<32 hex>_`, so these never collide. */
export const FORUM_ROOMS_TABLE = "bot_forum_rooms";
export const FORUM_POSTS_TABLE = "bot_forum_posts";
export const FORUM_BOTS_TABLE = "bot_forum_bots";
export const FORUM_SEATS_TABLE = "bot_forum_seats";
export const FORUM_OWED_TABLE = "bot_forum_owed";
export const FORUM_UNANSWERED_TABLE = "bot_forum_unanswered";
export const FORUM_SCHEDULES_TABLE = "bot_forum_schedules";
/** The visual reply a bot's post carries (`render_html` from its seat): a reference, the HTML is the server's. */
export const FORUM_VISUAL_REPLIES_TABLE = "bot_forum_visual_replies";

/** The entry kind of a seat's inputs; its data says how far the input takes the seat. */
export const DELIVERY_KIND = "forum.delivery";

/** The place of a seat that hears nothing: its bot was switched out or deleted. */
export const AWAY = Number.MAX_SAFE_INTEGER;

/** A room: the Forum itself (no parent post) or a thread started from one Forum post. */
export type ForumRoom = {
  readonly id: number;
  readonly parentPostId?: number;
  /** Generated from a thread's first post; "" until then, and always for the Forum. */
  readonly title: string;
  readonly createdAt: string;
  readonly pinned: boolean;
};

export type ForumPostRecord = {
  readonly id: number;
  readonly roomId: number;
  /** `agent`: an agent session posted for the user through the Woven tools; `name` is its name. */
  readonly author: "user" | "bot" | "agent";
  readonly botId?: string;
  /** The author's name when it posted, so a renamed or deleted bot's posts keep theirs. */
  readonly name: string;
  readonly text: string;
  /** Bots the user asked for a reply (user posts only). */
  readonly mentions: readonly string[];
  readonly scheduled: boolean;
  /** Posted by the runtime from the bot's final message, because it owed the user a reply. */
  readonly auto: boolean;
  /** The bot conversation a bot's post was made from. */
  readonly origin?: number;
  /** A visual reply the bot published from its seat; the post has no text then. */
  readonly visualReply?: VisualReply;
  readonly createdAt: string;
};

/** A bot's place in a room: the conversation it hears the room through, and how far it has heard. */
export type ForumSeat = {
  readonly roomId: number;
  readonly botId: string;
  readonly conversationId?: number;
  /** The newest post when the bot joined: it hears the room from the next one. */
  readonly baseline: number;
  /** The newest post handed to the bot's conversation. */
  readonly cursor: number;
};

export type ForumUnanswered = {
  readonly postId: number;
  readonly botId: string;
  readonly name: string;
  readonly reason: string;
  readonly issue?: "signIn" | "limit";
};

export type ForumRepeat = "once" | "daily" | "weekdays" | "weekly";

export type ForumSchedule = {
  readonly id: string;
  readonly text: string;
  readonly mentions: readonly string[];
  readonly everyone: boolean;
  readonly repeat: ForumRepeat;
  /** `HH:MM` in `timeZone` (repeating posts). */
  readonly time?: string;
  /** 0 (Sunday) to 6, for `weekly`. */
  readonly weekday?: number;
  /** Epoch ms, for `once`. */
  readonly at?: number;
  readonly timeZone: string;
  /** The local day a repeating post last fired on, so each of its days fires once. */
  readonly lastRun?: string;
  readonly createdAt: string;
};

type RoomRow = {
  id: number;
  parent_post_id: number | null;
  title: string;
  created_at: string;
  is_pinned: number;
};
type PostRow = {
  id: number;
  room_id: number;
  author: string;
  bot_id: string | null;
  name: string;
  text: string;
  mentions: string;
  is_scheduled: number;
  is_auto: number;
  origin_conversation: number | null;
  created_at: string;
  reply_title: string | null;
  reply_height: number | null;
  reply_digest: string | null;
  reply_size: number | null;
};
type SeatRow = {
  room_id: number;
  bot_id: string;
  conversation_id: number | null;
  baseline: number;
  cursor: number;
};
type ScheduleRow = {
  id: string;
  text: string;
  mentions: string;
  everyone: number;
  repeat: string;
  time: string | null;
  weekday: number | null;
  at: number | null;
  time_zone: string;
  last_run: string | null;
  created_at: string;
};

/** A post's columns with its visual reply's, from `FROM ${POSTS}`. */
const POSTS = `${FORUM_POSTS_TABLE} LEFT JOIN ${FORUM_VISUAL_REPLIES_TABLE} ON post_id = id`;
const POST_COLUMNS =
  "id, room_id, author, bot_id, name, text, mentions, is_scheduled, is_auto, origin_conversation, created_at, reply_title, reply_height, reply_digest, reply_size";

function stringList(json: string): string[] {
  try {
    const parsed: unknown = JSON.parse(json);
    return Array.isArray(parsed)
      ? parsed.filter((item): item is string => typeof item === "string")
      : [];
  } catch {
    return [];
  }
}

const toRoom = (row: RoomRow): ForumRoom => ({
  id: row.id,
  ...(row.parent_post_id === null ? {} : { parentPostId: row.parent_post_id }),
  title: row.title,
  createdAt: row.created_at,
  pinned: row.is_pinned === 1,
});

const toPost = (row: PostRow): ForumPostRecord => ({
  id: row.id,
  roomId: row.room_id,
  author: row.author === "bot" || row.author === "agent" ? row.author : "user",
  ...(row.bot_id ? { botId: row.bot_id } : {}),
  name: row.name,
  text: row.text,
  mentions: stringList(row.mentions),
  scheduled: row.is_scheduled === 1,
  auto: row.is_auto === 1,
  ...(row.origin_conversation === null ? {} : { origin: row.origin_conversation }),
  ...(row.reply_digest === null
    ? {}
    : {
        visualReply: {
          title: row.reply_title ?? "",
          height: row.reply_height ?? 0,
          digest: row.reply_digest,
          size: row.reply_size ?? 0,
        },
      }),
  createdAt: row.created_at,
});

const toSeat = (row: SeatRow): ForumSeat => ({
  roomId: row.room_id,
  botId: row.bot_id,
  ...(row.conversation_id === null ? {} : { conversationId: row.conversation_id }),
  baseline: row.baseline,
  cursor: row.cursor,
});

const REPEATS: readonly string[] = ["once", "daily", "weekdays", "weekly"];

const toSchedule = (row: ScheduleRow): ForumSchedule => ({
  id: row.id,
  text: row.text,
  mentions: stringList(row.mentions),
  everyone: row.everyone === 1,
  repeat: REPEATS.includes(row.repeat) ? (row.repeat as ForumRepeat) : "once",
  ...(row.time === null ? {} : { time: row.time }),
  ...(row.weekday === null ? {} : { weekday: row.weekday }),
  ...(row.at === null ? {} : { at: row.at }),
  timeZone: row.time_zone,
  ...(row.last_run === null ? {} : { lastRun: row.last_run }),
  createdAt: row.created_at,
});

/** Forum posts, rooms, membership and scheduled posts, in the shared database. */
export class ForumStore {
  readonly #db: SqliteDatabase;

  constructor(db: SqliteDatabase) {
    this.#db = db;
  }

  /** Creates the tables and the Forum room itself. */
  async createTables(at = new Date().toISOString()): Promise<void> {
    await this.#db.transaction(async (tx) => {
      await tx.exec(`
        CREATE TABLE IF NOT EXISTS ${FORUM_ROOMS_TABLE} (
          id INTEGER PRIMARY KEY AUTOINCREMENT, parent_post_id INTEGER UNIQUE,
          title TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, is_pinned INTEGER NOT NULL DEFAULT 0
        ) STRICT;
        CREATE TABLE IF NOT EXISTS ${FORUM_POSTS_TABLE} (
          id INTEGER PRIMARY KEY AUTOINCREMENT, room_id INTEGER NOT NULL, author TEXT NOT NULL,
          bot_id TEXT, name TEXT NOT NULL, text TEXT NOT NULL, mentions TEXT NOT NULL DEFAULT '[]',
          is_scheduled INTEGER NOT NULL DEFAULT 0, is_auto INTEGER NOT NULL DEFAULT 0,
          origin_conversation INTEGER, created_at TEXT NOT NULL
        ) STRICT;
        CREATE INDEX IF NOT EXISTS ${FORUM_POSTS_TABLE}_room ON ${FORUM_POSTS_TABLE} (room_id, id);
        CREATE TABLE IF NOT EXISTS ${FORUM_BOTS_TABLE} (
          bot_id TEXT PRIMARY KEY, active INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS ${FORUM_SEATS_TABLE} (
          room_id INTEGER NOT NULL, bot_id TEXT NOT NULL, conversation_id INTEGER,
          baseline INTEGER NOT NULL DEFAULT 0, cursor INTEGER NOT NULL DEFAULT 0,
          PRIMARY KEY (room_id, bot_id)
        ) STRICT;
        CREATE TABLE IF NOT EXISTS ${FORUM_OWED_TABLE} (
          room_id INTEGER NOT NULL, bot_id TEXT NOT NULL, post_id INTEGER NOT NULL,
          PRIMARY KEY (room_id, bot_id, post_id)
        ) STRICT;
        CREATE TABLE IF NOT EXISTS ${FORUM_UNANSWERED_TABLE} (
          post_id INTEGER NOT NULL, bot_id TEXT NOT NULL, name TEXT NOT NULL, reason TEXT NOT NULL,
          issue TEXT, PRIMARY KEY (post_id, bot_id)
        ) STRICT;
        CREATE TABLE IF NOT EXISTS ${FORUM_SCHEDULES_TABLE} (
          id TEXT PRIMARY KEY, text TEXT NOT NULL, mentions TEXT NOT NULL DEFAULT '[]',
          everyone INTEGER NOT NULL DEFAULT 0, repeat TEXT NOT NULL, time TEXT, weekday INTEGER,
          at INTEGER, time_zone TEXT NOT NULL, last_run TEXT, created_at TEXT NOT NULL
        ) STRICT;
        CREATE TABLE IF NOT EXISTS ${FORUM_VISUAL_REPLIES_TABLE} (
          post_id INTEGER PRIMARY KEY, reply_title TEXT NOT NULL, reply_height INTEGER NOT NULL,
          reply_digest TEXT NOT NULL, reply_size INTEGER NOT NULL
        ) STRICT;
      `);
      await tx.run(
        `INSERT INTO ${FORUM_ROOMS_TABLE} (created_at) SELECT ? WHERE NOT EXISTS (SELECT 1 FROM ${FORUM_ROOMS_TABLE} WHERE parent_post_id IS NULL)`,
        at,
      );
    });
  }

  /** The Forum itself: the one room without a parent post. */
  async mainRoom(): Promise<ForumRoom> {
    const row = await this.#db.get<RoomRow>(
      `SELECT * FROM ${FORUM_ROOMS_TABLE} WHERE parent_post_id IS NULL ORDER BY id LIMIT 1`,
    );
    if (!row) throw new Error("the Forum has no room; run createTables() first");
    return toRoom(row);
  }

  async room(id: number): Promise<ForumRoom | undefined> {
    const row = await this.#db.get<RoomRow>(
      `SELECT * FROM ${FORUM_ROOMS_TABLE} WHERE id = ?`,
      id,
    );
    return row ? toRoom(row) : undefined;
  }

  /** Every room, the Forum itself first, then threads oldest first. */
  async rooms(): Promise<ForumRoom[]> {
    const rows = await this.#db.all<RoomRow>(
      `SELECT * FROM ${FORUM_ROOMS_TABLE} ORDER BY parent_post_id IS NOT NULL, id`,
    );
    return rows.map(toRoom);
  }

  /** Every thread, newest first. */
  async threads(): Promise<ForumRoom[]> {
    const rows = await this.#db.all<RoomRow>(
      `SELECT * FROM ${FORUM_ROOMS_TABLE} WHERE parent_post_id IS NOT NULL ORDER BY id DESC`,
    );
    return rows.map(toRoom);
  }

  async threadOf(postId: number): Promise<ForumRoom | undefined> {
    const row = await this.#db.get<RoomRow>(
      `SELECT * FROM ${FORUM_ROOMS_TABLE} WHERE parent_post_id = ?`,
      postId,
    );
    return row ? toRoom(row) : undefined;
  }

  /** The post's thread, created when it has none (one thread per post). */
  async createThread(postId: number, at = new Date().toISOString()): Promise<ForumRoom> {
    await this.#db.run(
      `INSERT OR IGNORE INTO ${FORUM_ROOMS_TABLE} (parent_post_id, created_at) VALUES (?, ?)`,
      postId,
      at,
    );
    const thread = await this.threadOf(postId);
    if (!thread) throw new Error(`no thread for post ${postId}`);
    return thread;
  }

  /** Set the title only while it is still empty, like a bot thread's. */
  async setRoomTitleIfUntitled(roomId: number, title: string): Promise<boolean> {
    const changed = await this.#db.runCounted(
      `UPDATE ${FORUM_ROOMS_TABLE} SET title = ? WHERE id = ? AND title = ''`,
      title,
      roomId,
    );
    return changed > 0;
  }

  async setRoomTitle(roomId: number, title: string): Promise<void> {
    await this.#db.run(`UPDATE ${FORUM_ROOMS_TABLE} SET title = ? WHERE id = ?`, title.trim(), roomId);
  }

  async setRoomPinned(roomId: number, pinned: boolean): Promise<void> {
    await this.#db.run(
      `UPDATE ${FORUM_ROOMS_TABLE} SET is_pinned = ? WHERE id = ?`,
      pinned ? 1 : 0,
      roomId,
    );
  }

  /**
   * Delete a thread with its posts, its seats, the replies owed in it and the notes on its posts,
   * in one transaction. Its parent post stays, and may start a thread again. False when `roomId`
   * is not a thread.
   */
  async deleteThread(roomId: number): Promise<boolean> {
    return this.#db.transaction(async (tx) => {
      const room = await tx.get<{ id: number }>(
        `DELETE FROM ${FORUM_ROOMS_TABLE} WHERE id = ? AND parent_post_id IS NOT NULL RETURNING id`,
        roomId,
      );
      if (!room) return false;
      await tx.run(
        `DELETE FROM ${FORUM_UNANSWERED_TABLE} WHERE post_id IN (SELECT id FROM ${FORUM_POSTS_TABLE} WHERE room_id = ?)`,
        roomId,
      );
      await tx.run(
        `DELETE FROM ${FORUM_VISUAL_REPLIES_TABLE} WHERE post_id IN (SELECT id FROM ${FORUM_POSTS_TABLE} WHERE room_id = ?)`,
        roomId,
      );
      await tx.run(`DELETE FROM ${FORUM_OWED_TABLE} WHERE room_id = ?`, roomId);
      await tx.run(`DELETE FROM ${FORUM_SEATS_TABLE} WHERE room_id = ?`, roomId);
      await tx.run(`DELETE FROM ${FORUM_POSTS_TABLE} WHERE room_id = ?`, roomId);
      return true;
    });
  }

  /**
   * Store a post, with the replies its mentions ask for (`owed`) and the thread seats they add
   * (`join`), in one transaction.
   */
  async addPost(
    post: Omit<ForumPostRecord, "id" | "createdAt"> & { readonly createdAt?: string },
    options: { readonly join?: readonly string[] } = {},
  ): Promise<ForumPostRecord> {
    const createdAt = post.createdAt ?? new Date().toISOString();
    return this.#db.transaction(async (tx) => {
      const row = await tx.get<{ id: number }>(
        `INSERT INTO ${FORUM_POSTS_TABLE} (room_id, author, bot_id, name, text, mentions, is_scheduled, is_auto, origin_conversation, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) RETURNING id`,
        post.roomId,
        post.author,
        post.botId ?? null,
        post.name,
        post.text,
        JSON.stringify(post.mentions),
        post.scheduled ? 1 : 0,
        post.auto ? 1 : 0,
        post.origin ?? null,
        createdAt,
      );
      if (!row) throw new Error("the post was not stored");
      const reply = post.visualReply;
      if (reply) {
        await tx.run(
          `INSERT INTO ${FORUM_VISUAL_REPLIES_TABLE} (post_id, reply_title, reply_height, reply_digest, reply_size) VALUES (?, ?, ?, ?, ?)`,
          row.id,
          reply.title,
          reply.height,
          reply.digest,
          reply.size,
        );
      }
      for (const botId of options.join ?? []) {
        await tx.run(
          `INSERT OR IGNORE INTO ${FORUM_SEATS_TABLE} (room_id, bot_id) VALUES (?, ?)`,
          post.roomId,
          botId,
        );
      }
      for (const botId of post.mentions) {
        await tx.run(
          `INSERT OR IGNORE INTO ${FORUM_OWED_TABLE} (room_id, bot_id, post_id) VALUES (?, ?, ?)`,
          post.roomId,
          botId,
          row.id,
        );
      }
      return { ...post, id: row.id, createdAt };
    });
  }

  async post(id: number): Promise<ForumPostRecord | undefined> {
    const row = await this.#db.get<PostRow>(
      `SELECT ${POST_COLUMNS} FROM ${POSTS} WHERE id = ?`,
      id,
    );
    return row ? toPost(row) : undefined;
  }

  /** A room's posts after post `after`, oldest first. */
  async postsAfter(roomId: number, after: number): Promise<ForumPostRecord[]> {
    const rows = await this.#db.all<PostRow>(
      `SELECT ${POST_COLUMNS} FROM ${POSTS} WHERE room_id = ? AND id > ? ORDER BY id`,
      roomId,
      after,
    );
    return rows.map(toPost);
  }

  /** Up to `limit` posts of every room after post `after`, oldest first. */
  async postsAbove(after: number, limit: number): Promise<ForumPostRecord[]> {
    const rows = await this.#db.all<PostRow>(
      `SELECT ${POST_COLUMNS} FROM ${POSTS} WHERE id > ? ORDER BY id LIMIT ?`,
      after,
      limit,
    );
    return rows.map(toPost);
  }

  /** Up to `limit` of a room's posts before post `before` (all when undefined), oldest first. */
  async postsBefore(
    roomId: number,
    before: number | undefined,
    limit: number,
  ): Promise<ForumPostRecord[]> {
    const rows = await this.#db.all<PostRow>(
      `SELECT ${POST_COLUMNS} FROM ${POSTS} WHERE room_id = ? AND id < ? ORDER BY id DESC LIMIT ?`,
      roomId,
      before ?? Number.MAX_SAFE_INTEGER,
      limit,
    );
    return rows.map(toPost).reverse();
  }

  /** The newest post's id, in one room or (without `roomId`) anywhere; 0 when there is none. */
  async latestPostId(roomId?: number): Promise<number> {
    const row =
      roomId === undefined
        ? await this.#db.get<{ id: number | null }>(
            `SELECT MAX(id) AS id FROM ${FORUM_POSTS_TABLE}`,
          )
        : await this.#db.get<{ id: number | null }>(
            `SELECT MAX(id) AS id FROM ${FORUM_POSTS_TABLE} WHERE room_id = ?`,
            roomId,
          );
    return row?.id ?? 0;
  }

  async firstPost(roomId: number): Promise<ForumPostRecord | undefined> {
    const row = await this.#db.get<PostRow>(
      `SELECT ${POST_COLUMNS} FROM ${POSTS} WHERE room_id = ? ORDER BY id LIMIT 1`,
      roomId,
    );
    return row ? toPost(row) : undefined;
  }

  /** Each room's first post. */
  async firstPosts(): Promise<Map<number, ForumPostRecord>> {
    const rows = await this.#db.all<PostRow>(
      `SELECT ${POST_COLUMNS} FROM ${POSTS} WHERE id IN (SELECT MIN(id) FROM ${FORUM_POSTS_TABLE} GROUP BY room_id)`,
    );
    return new Map(rows.map((row) => [row.room_id, toPost(row)]));
  }

  async postsById(ids: readonly number[]): Promise<Map<number, ForumPostRecord>> {
    const found = new Map<number, ForumPostRecord>();
    for (let start = 0; start < ids.length; start += 400) {
      const slice = ids.slice(start, start + 400);
      const rows = await this.#db.all<PostRow>(
        `SELECT ${POST_COLUMNS} FROM ${POSTS} WHERE id IN (${slice.map(() => "?").join(", ")})`,
        ...slice,
      );
      for (const row of rows) found.set(row.id, toPost(row));
    }
    return found;
  }

  /** How many posts each room holds. */
  async postCounts(): Promise<Map<number, number>> {
    const rows = await this.#db.all<{ room_id: number; count: number }>(
      `SELECT room_id, COUNT(*) AS count FROM ${FORUM_POSTS_TABLE} GROUP BY room_id`,
    );
    return new Map(rows.map((row) => [row.room_id, row.count]));
  }

  /** The user's explicit choice for a bot (in or out), if they made one. */
  async activeChoices(): Promise<Map<string, boolean>> {
    const rows = await this.#db.all<{ bot_id: string; active: number }>(
      `SELECT bot_id, active FROM ${FORUM_BOTS_TABLE}`,
    );
    return new Map(rows.map((row) => [row.bot_id, row.active === 1]));
  }

  async setActive(botId: string, active: boolean): Promise<void> {
    await this.#db.run(
      `INSERT INTO ${FORUM_BOTS_TABLE} (bot_id, active) VALUES (?, ?) ON CONFLICT(bot_id) DO UPDATE SET active = excluded.active`,
      botId,
      active ? 1 : 0,
    );
  }

  async seat(roomId: number, botId: string): Promise<ForumSeat | undefined> {
    const row = await this.#db.get<SeatRow>(
      `SELECT * FROM ${FORUM_SEATS_TABLE} WHERE room_id = ? AND bot_id = ?`,
      roomId,
      botId,
    );
    return row ? toSeat(row) : undefined;
  }

  async seats(roomId?: number): Promise<ForumSeat[]> {
    const rows =
      roomId === undefined
        ? await this.#db.all<SeatRow>(`SELECT * FROM ${FORUM_SEATS_TABLE} ORDER BY room_id, bot_id`)
        : await this.#db.all<SeatRow>(
            `SELECT * FROM ${FORUM_SEATS_TABLE} WHERE room_id = ? ORDER BY bot_id`,
            roomId,
          );
    return rows.map(toSeat);
  }

  async seatsOf(botId: string): Promise<ForumSeat[]> {
    const rows = await this.#db.all<SeatRow>(
      `SELECT * FROM ${FORUM_SEATS_TABLE} WHERE bot_id = ? ORDER BY room_id`,
      botId,
    );
    return rows.map(toSeat);
  }

  /** The seat a bot hears through `conversationId`, if that conversation is one. */
  async seatOfConversation(botId: string, conversationId: number): Promise<ForumSeat | undefined> {
    const row = await this.#db.get<SeatRow>(
      `SELECT * FROM ${FORUM_SEATS_TABLE} WHERE bot_id = ? AND conversation_id = ?`,
      botId,
      conversationId,
    );
    return row ? toSeat(row) : undefined;
  }

  /** Give a bot a seat when it has none; an existing seat is left as it is. */
  async addSeat(roomId: number, botId: string, baseline: number): Promise<void> {
    await this.#db.run(
      `INSERT OR IGNORE INTO ${FORUM_SEATS_TABLE} (room_id, bot_id, baseline, cursor) VALUES (?, ?, ?, ?)`,
      roomId,
      botId,
      baseline,
      baseline,
    );
  }

  /** Seat a bot from the post after `baseline`, whatever it had heard before. */
  async reseat(roomId: number, botId: string, baseline: number): Promise<void> {
    await this.#db.run(
      `INSERT INTO ${FORUM_SEATS_TABLE} (room_id, bot_id, baseline, cursor) VALUES (?, ?, ?, ?) ON CONFLICT(room_id, bot_id) DO UPDATE SET baseline = excluded.baseline, cursor = excluded.cursor`,
      roomId,
      botId,
      baseline,
      baseline,
    );
  }

  async setSeatConversation(roomId: number, botId: string, conversationId: number): Promise<void> {
    await this.#db.run(
      `UPDATE ${FORUM_SEATS_TABLE} SET conversation_id = ? WHERE room_id = ? AND bot_id = ?`,
      conversationId,
      roomId,
      botId,
    );
  }

  async setSeatCursor(roomId: number, botId: string, cursor: number): Promise<void> {
    await this.#db.run(
      `UPDATE ${FORUM_SEATS_TABLE} SET cursor = ? WHERE room_id = ? AND bot_id = ?`,
      cursor,
      roomId,
      botId,
    );
  }

  /**
   * Take a bot out: it leaves its threads, owes no replies, and its Forum seat (`mainRoomId`)
   * hears nothing (`AWAY`) until it is seated again. The seat keeps its conversation.
   */
  async unseat(botId: string, mainRoomId: number): Promise<void> {
    await this.#db.transaction(async (tx) => {
      await tx.run(
        `DELETE FROM ${FORUM_SEATS_TABLE} WHERE bot_id = ? AND room_id <> ?`,
        botId,
        mainRoomId,
      );
      await tx.run(`DELETE FROM ${FORUM_OWED_TABLE} WHERE bot_id = ?`, botId);
      await tx.run(
        `UPDATE ${FORUM_SEATS_TABLE} SET baseline = ?, cursor = ? WHERE bot_id = ? AND room_id = ?`,
        AWAY,
        AWAY,
        botId,
        mainRoomId,
      );
    });
  }

  /** The user's posts a bot still owes a reply to in a room, oldest first. */
  async owed(roomId: number, botId: string): Promise<number[]> {
    const rows = await this.#db.all<{ post_id: number }>(
      `SELECT post_id FROM ${FORUM_OWED_TABLE} WHERE room_id = ? AND bot_id = ? ORDER BY post_id`,
      roomId,
      botId,
    );
    return rows.map((row) => row.post_id);
  }

  /** Every (room, bot) with a reply still owed. */
  async owedSeats(): Promise<{ roomId: number; botId: string }[]> {
    const rows = await this.#db.all<{ room_id: number; bot_id: string }>(
      `SELECT DISTINCT room_id, bot_id FROM ${FORUM_OWED_TABLE}`,
    );
    return rows.map((row) => ({ roomId: row.room_id, botId: row.bot_id }));
  }

  /** The bot answered: drop what it owed in the room up to post `upTo`. */
  async clearOwed(roomId: number, botId: string, upTo: number): Promise<void> {
    await this.#db.run(
      `DELETE FROM ${FORUM_OWED_TABLE} WHERE room_id = ? AND bot_id = ? AND post_id <= ?`,
      roomId,
      botId,
      upTo,
    );
  }

  /**
   * Settle what a bot owed in a room up to post `upTo`, in one transaction: with `post` its reply
   * is stored, otherwise each owed post gets an `unanswered` note. Returns the stored reply and
   * the posts that got a note; nothing when another settle (or the bot's own post) came first.
   */
  async settleOwed(
    roomId: number,
    botId: string,
    upTo: number,
    outcome:
      | { readonly post: Omit<ForumPostRecord, "id" | "createdAt"> }
      | { readonly unanswered: Omit<ForumUnanswered, "postId" | "botId"> },
    at = new Date().toISOString(),
  ): Promise<{ readonly post?: ForumPostRecord; readonly noted: number[] }> {
    return this.#db.transaction(async (tx) => {
      const rows = await tx.all<{ post_id: number }>(
        `SELECT post_id FROM ${FORUM_OWED_TABLE} WHERE room_id = ? AND bot_id = ? AND post_id <= ? ORDER BY post_id`,
        roomId,
        botId,
        upTo,
      );
      if (!rows.length) return { noted: [] };
      await tx.run(
        `DELETE FROM ${FORUM_OWED_TABLE} WHERE room_id = ? AND bot_id = ? AND post_id <= ?`,
        roomId,
        botId,
        upTo,
      );
      if ("post" in outcome) {
        const post = outcome.post;
        const row = await tx.get<{ id: number }>(
          `INSERT INTO ${FORUM_POSTS_TABLE} (room_id, author, bot_id, name, text, mentions, is_scheduled, is_auto, origin_conversation, created_at) VALUES (?, ?, ?, ?, ?, '[]', 0, 1, ?, ?) RETURNING id`,
          post.roomId,
          post.author,
          post.botId ?? null,
          post.name,
          post.text,
          post.origin ?? null,
          at,
        );
        if (!row) throw new Error("the reply was not stored");
        return { post: { ...post, id: row.id, createdAt: at }, noted: [] };
      }
      for (const { post_id } of rows) {
        await tx.run(
          `INSERT OR REPLACE INTO ${FORUM_UNANSWERED_TABLE} (post_id, bot_id, name, reason, issue) VALUES (?, ?, ?, ?, ?)`,
          post_id,
          botId,
          outcome.unanswered.name,
          outcome.unanswered.reason,
          outcome.unanswered.issue ?? null,
        );
      }
      return { noted: rows.map((row) => row.post_id) };
    });
  }

  /** Mark one post unanswered by a bot, dropping that reply from what the bot owes. */
  async addUnanswered(roomId: number, note: ForumUnanswered): Promise<void> {
    await this.#db.transaction(async (tx) => {
      await tx.run(
        `DELETE FROM ${FORUM_OWED_TABLE} WHERE room_id = ? AND bot_id = ? AND post_id = ?`,
        roomId,
        note.botId,
        note.postId,
      );
      await tx.run(
        `INSERT OR REPLACE INTO ${FORUM_UNANSWERED_TABLE} (post_id, bot_id, name, reason, issue) VALUES (?, ?, ?, ?, ?)`,
        note.postId,
        note.botId,
        note.name,
        note.reason,
        note.issue ?? null,
      );
    });
  }

  /** The `unanswered` notes of some posts, by post. */
  async unanswered(postIds: readonly number[]): Promise<Map<number, ForumUnanswered[]>> {
    const found = new Map<number, ForumUnanswered[]>();
    for (let start = 0; start < postIds.length; start += 400) {
      const slice = postIds.slice(start, start + 400);
      const rows = await this.#db.all<{
        post_id: number;
        bot_id: string;
        name: string;
        reason: string;
        issue: string | null;
      }>(
        `SELECT post_id, bot_id, name, reason, issue FROM ${FORUM_UNANSWERED_TABLE} WHERE post_id IN (${slice.map(() => "?").join(", ")}) ORDER BY post_id, name`,
        ...slice,
      );
      for (const row of rows) {
        const notes = found.get(row.post_id) ?? [];
        notes.push({
          postId: row.post_id,
          botId: row.bot_id,
          name: row.name,
          reason: row.reason,
          ...(row.issue === "signIn" || row.issue === "limit" ? { issue: row.issue } : {}),
        });
        found.set(row.post_id, notes);
      }
    }
    return found;
  }

  /** A purged bot leaves nothing but its posts and the notes on the user's. */
  async forgetBot(botId: string): Promise<void> {
    await this.#db.transaction(async (tx) => {
      await tx.run(`DELETE FROM ${FORUM_BOTS_TABLE} WHERE bot_id = ?`, botId);
      await tx.run(`DELETE FROM ${FORUM_SEATS_TABLE} WHERE bot_id = ?`, botId);
      await tx.run(`DELETE FROM ${FORUM_OWED_TABLE} WHERE bot_id = ?`, botId);
    });
  }

  async schedules(): Promise<ForumSchedule[]> {
    const rows = await this.#db.all<ScheduleRow>(
      `SELECT * FROM ${FORUM_SCHEDULES_TABLE} ORDER BY created_at, id`,
    );
    return rows.map(toSchedule);
  }

  /** Add a scheduled post, or replace the one with the same id (which then may fire again). */
  async saveSchedule(
    schedule: Omit<ForumSchedule, "id" | "createdAt" | "lastRun"> & { readonly id?: string },
    at = new Date().toISOString(),
  ): Promise<ForumSchedule> {
    const id = schedule.id ?? randomUUID();
    await this.#db.run(
      `INSERT INTO ${FORUM_SCHEDULES_TABLE} (id, text, mentions, everyone, repeat, time, weekday, at, time_zone, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET text = excluded.text, mentions = excluded.mentions, everyone = excluded.everyone, repeat = excluded.repeat, time = excluded.time, weekday = excluded.weekday, at = excluded.at, time_zone = excluded.time_zone, last_run = NULL`,
      id,
      schedule.text,
      JSON.stringify(schedule.mentions),
      schedule.everyone ? 1 : 0,
      schedule.repeat,
      schedule.time ?? null,
      schedule.weekday ?? null,
      schedule.at ?? null,
      schedule.timeZone,
      at,
    );
    const saved = (await this.schedules()).find((item) => item.id === id);
    if (!saved) throw new Error("the scheduled post was not stored");
    return saved;
  }

  async deleteSchedule(id: string): Promise<boolean> {
    return (
      (await this.#db.runCounted(`DELETE FROM ${FORUM_SCHEDULES_TABLE} WHERE id = ?`, id)) > 0
    );
  }

  /** Claim a repeating post's occurrence (its local day): false when it already fired. */
  async claimScheduleRun(id: string, run: string): Promise<boolean> {
    const changed = await this.#db.runCounted(
      `UPDATE ${FORUM_SCHEDULES_TABLE} SET last_run = ? WHERE id = ? AND (last_run IS NULL OR last_run <> ?)`,
      run,
      id,
      run,
    );
    return changed > 0;
  }
}
