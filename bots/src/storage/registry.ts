import { randomUUID } from "node:crypto";
import { validateSqliteSchemaPrefix } from "@earendil-works/chord/sqlite";
import type { SqliteDatabase, SqliteExecutor } from "@earendil-works/pi-durable/storage/sqlite";
import type { LimitEntry } from "../limits.ts";

/** Shared tables. Bot tables all start with `pibot_<32 hex>_`, so these can never collide. */
export type SidebarGroup = { id: string; name: string; position: number };
export const GROUPS_TABLE = "pibot_groups";
export const DELIVERIES_TABLE = "pibot_host_deliveries";
/** Hosts retry within minutes; a month is far past any retry and bounds the table. */
const DELIVERY_RETENTION_MS = 30 * 24 * 60 * 60 * 1000;

export const BOTS_TABLE = "pibot_bots";
export const THREADS_TABLE = "pibot_threads";
/** Free-text notes, e.g. the user's plans and comfort spend (`account`), which Admin Bot reads. */
export const NOTES_TABLE = "pibot_notes";
/** Marked main-model usage limits (`ModelAvailability`), so they outlive a restart. */
export const LIMITS_TABLE = "pibot_limits";
/** Each bot's extracted memory (one fact per line) and its extraction checkpoint. */
export const MEMORY_TABLE = "pibot_memory";

/** A bot's memory: facts oldest first, and the newest entry id extraction has read. */
export type BotMemory = {
  readonly facts: readonly string[];
  /** Entry ids are per bot session and only grow, so one checkpoint covers every conversation. */
  readonly checkpoint: number;
  readonly updatedAt?: string;
};

export type BotRecord = {
  readonly id: string;
  readonly name: string;
  /** Table prefix of this bot's Pi Durable session, `pibot_<id without dashes>_`. */
  readonly prefix: string;
  readonly createdAt: string;
  /** `admin`: the one built-in account/config bot (never deleted, renamed or on a team). */
  readonly kind: BotKind;
  /** Manages a team (one level: a manager has no manager). */
  readonly manager: boolean;
  /** The bot's team manager, if it is on a team. */
  readonly managerId?: string;
  /**
   * The optional orchestrator: at most one, above every team (never on one, but it may manage its
   * own). Never Admin Bot.
   */
  readonly orchestrator: boolean;
  /** Sidebar placement, independent of teams and authority. */
  readonly groupId?: string;
  /** The model profile the bot runs (`[profiles.<id>]`); unset: the default profile. */
  readonly profile?: string;
};

export type BotKind = "admin" | "bot";

/** A soft-deleted bot, as listed in Settings → Bots → Deleted bots. */
export type DeletedBotRecord = BotRecord & { readonly deletedAt: string };

export type ThreadRecord = {
  readonly botId: string;
  readonly conversationId: number;
  readonly parentConversationId: number;
  /** Entry the thread was forked at; the thread inherits context up to and including it. */
  readonly forkedAt: number;
  /**
   * Generated from the thread's first message (`[models.titles]`); "" until then. Metadata only:
   * thread listing and search use it, the UI never shows it, and nothing renames a thread.
   */
  readonly title: string;
  readonly createdAt: string;
  readonly pinned?: true;
};

type BotRow = {
  id: string;
  name: string;
  schema_prefix: string;
  created_at: string;
  kind: string;
  is_manager: number;
  manager_id: string | null;
  is_orchestrator: number;
  profile: string | null;
  group_id: string | null;
};
const BOT_COLUMNS =
  "id, name, schema_prefix, created_at, kind, is_manager, manager_id, is_orchestrator, profile, group_id";
type ThreadRow = {
  bot_id: string;
  conversation_id: number;
  parent_conversation_id: number;
  forked_at_entry: number;
  title: string;
  created_at: string;
  is_pinned: number;
};

const BOT_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;

/** Per-bot table prefix, mirroring Woven's `wm_pi_<id>_`. */
export function botPrefix(botId: string): string {
  if (!BOT_ID.test(botId)) throw new Error(`invalid bot id ${JSON.stringify(botId)}`);
  const prefix = `pibot_${botId.replaceAll("-", "")}_`;
  validateSqliteSchemaPrefix(prefix);
  return prefix;
}

function toBot(row: BotRow): BotRecord {
  return {
    id: row.id,
    name: row.name,
    prefix: row.schema_prefix,
    createdAt: row.created_at,
    kind: row.kind === "admin" ? "admin" : "bot",
    manager: row.is_manager === 1,
    ...(row.manager_id ? { managerId: row.manager_id } : {}),
    orchestrator: row.is_orchestrator === 1,
    ...(row.group_id ? { groupId: row.group_id } : {}),
    ...(row.profile ? { profile: row.profile } : {}),
  };
}

function toThread(row: ThreadRow): ThreadRecord {
  return {
    botId: row.bot_id,
    conversationId: row.conversation_id,
    parentConversationId: row.parent_conversation_id,
    forkedAt: row.forked_at_entry,
    title: row.title,
    createdAt: row.created_at,
    ...(row.is_pinned === 1 ? { pinned: true as const } : {}),
  };
}

/** Names of every schema object owned by one prefix. */
export async function prefixedObjects(
  db: SqliteExecutor,
  prefix: string,
): Promise<{ type: string; name: string }[]> {
  return db.all<{ type: string; name: string }>(
    "SELECT type, name FROM sqlite_master WHERE substr(name, 1, ?) = ? AND name NOT LIKE 'sqlite_%' ORDER BY type, name",
    prefix.length,
    prefix,
  );
}

/** Stored facts are one per line. */
const splitFacts = (text: string) => text.split("\n").filter((fact) => fact.trim());

async function writeMemory(
  db: SqliteExecutor,
  botId: string,
  facts: readonly string[],
  checkpoint: number,
  at: string,
): Promise<void> {
  await db.run(
    `INSERT INTO ${MEMORY_TABLE} (bot_id, facts, checkpoint, updated_at) VALUES (?, ?, ?, ?) ON CONFLICT(bot_id) DO UPDATE SET facts = excluded.facts, checkpoint = excluded.checkpoint, updated_at = excluded.updated_at`,
    botId,
    facts.join("\n"),
    checkpoint,
    at,
  );
}

/** The bots registry plus thread metadata, in the shared database. */
export class BotRegistry {
  readonly #db: SqliteDatabase;

  constructor(db: SqliteDatabase) {
    this.#db = db;
  }

  async migrate(): Promise<void> {
    await this.#db.exec(`
      CREATE TABLE IF NOT EXISTS ${GROUPS_TABLE} (
        id TEXT PRIMARY KEY, name TEXT NOT NULL, position INTEGER NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS ${DELIVERIES_TABLE} (
        id TEXT PRIMARY KEY, created_at INTEGER NOT NULL, accepted INTEGER NOT NULL DEFAULT 0
      ) STRICT;
      CREATE TABLE IF NOT EXISTS ${BOTS_TABLE} (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        schema_prefix TEXT NOT NULL UNIQUE,
        created_at TEXT NOT NULL,
        deleted_at TEXT
      ) STRICT;
      CREATE TABLE IF NOT EXISTS ${THREADS_TABLE} (
        bot_id TEXT NOT NULL REFERENCES ${BOTS_TABLE}(id) ON DELETE CASCADE,
        conversation_id INTEGER NOT NULL,
        parent_conversation_id INTEGER NOT NULL,
        forked_at_entry INTEGER NOT NULL,
        title TEXT NOT NULL,
        created_at TEXT NOT NULL,
        PRIMARY KEY (bot_id, conversation_id)
      ) STRICT;
      CREATE TABLE IF NOT EXISTS ${NOTES_TABLE} (
        name TEXT PRIMARY KEY,
        text TEXT NOT NULL,
        updated_at TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS ${LIMITS_TABLE} (
        key TEXT PRIMARY KEY,
        entry TEXT NOT NULL
      ) STRICT;
      CREATE TABLE IF NOT EXISTS ${MEMORY_TABLE} (
        bot_id TEXT PRIMARY KEY,
        facts TEXT NOT NULL,
        checkpoint INTEGER NOT NULL,
        updated_at TEXT NOT NULL
      ) STRICT;
    `);
    const threadColumns = await this.#db.all<{ name: string }>(
      `PRAGMA table_info(${THREADS_TABLE})`,
    );
    if (!threadColumns.some((column) => column.name === "is_pinned"))
      await this.#db.exec(
        `ALTER TABLE ${THREADS_TABLE} ADD COLUMN is_pinned INTEGER NOT NULL DEFAULT 0`,
      );
    // Older databases lack later columns: add each missing one (existing bots are plain bots).
    const columns = new Set(
      (await this.#db.all<{ name: string }>(`PRAGMA table_info(${BOTS_TABLE})`)).map(
        (column) => column.name,
      ),
    );
    const deliveryColumns = await this.#db.all<{ name: string }>(
      `PRAGMA table_info(${DELIVERIES_TABLE})`,
    );
    if (!deliveryColumns.some((column) => column.name === "accepted")) {
      await this.#db.exec(
        `ALTER TABLE ${DELIVERIES_TABLE} ADD COLUMN accepted INTEGER NOT NULL DEFAULT 0`,
      );
    }
    const added: [string, string][] = [
      ["deleted_at", "TEXT"],
      ["kind", "TEXT NOT NULL DEFAULT 'bot'"],
      ["is_manager", "INTEGER NOT NULL DEFAULT 0"],
      ["manager_id", "TEXT"],
      ["profile", "TEXT"],
      ["group_id", `TEXT REFERENCES ${GROUPS_TABLE}(id) ON DELETE SET NULL`],
      ["is_orchestrator", "INTEGER NOT NULL DEFAULT 0"],
    ];
    for (const [name, type] of added) {
      if (!columns.has(name))
        await this.#db.exec(`ALTER TABLE ${BOTS_TABLE} ADD COLUMN ${name} ${type}`);
    }
    // At most one Admin Bot.
    await this.#db.exec(
      `CREATE UNIQUE INDEX IF NOT EXISTS pibot_bots_one_admin ON ${BOTS_TABLE}(kind) WHERE kind = 'admin'`,
    );
    // At most one orchestrator.
    await this.#db.exec(
      `CREATE UNIQUE INDEX IF NOT EXISTS pibot_bots_one_orchestrator ON ${BOTS_TABLE}(is_orchestrator) WHERE is_orchestrator = 1`,
    );
  }

  async installationId(): Promise<string> {
    await this.#db.run(
      `INSERT OR IGNORE INTO ${NOTES_TABLE} (name, text, updated_at) VALUES ('installationId', ?, ?)`,
      randomUUID(),
      new Date().toISOString(),
    );
    const stored = await this.note("installationId");
    if (!stored) throw new Error("installation identity was not persisted");
    return stored.text;
  }

  /**
   * False once a host delivery id has been accepted. A crash before `acceptDelivery` lets the host's
   * retry through: repeating a notification is better than losing it.
   */
  async claimDelivery(id: string): Promise<boolean> {
    const now = Date.now();
    await this.#db.run(
      `DELETE FROM ${DELIVERIES_TABLE} WHERE created_at < ?`,
      now - DELIVERY_RETENTION_MS,
    );
    const seen = await this.#db.get<{ accepted: number }>(
      `SELECT accepted FROM ${DELIVERIES_TABLE} WHERE id = ?`,
      id,
    );
    if (seen?.accepted === 1) return false;
    await this.#db.run(
      `INSERT OR IGNORE INTO ${DELIVERIES_TABLE} (id, created_at) VALUES (?, ?)`,
      id,
      now,
    );
    return true;
  }

  async acceptDelivery(id: string): Promise<void> {
    await this.#db.run(`UPDATE ${DELIVERIES_TABLE} SET accepted = 1 WHERE id = ?`, id);
  }

  async releaseDelivery(id: string): Promise<void> {
    await this.#db.run(`DELETE FROM ${DELIVERIES_TABLE} WHERE id = ?`, id);
  }

  async listGroups(): Promise<SidebarGroup[]> {
    return this.#db.all<SidebarGroup>(
      `SELECT id, name, position FROM ${GROUPS_TABLE} ORDER BY position, id`,
    );
  }

  async createGroup(name: string): Promise<SidebarGroup> {
    const id = randomUUID();
    await this.#db.run(
      `INSERT INTO ${GROUPS_TABLE} (id, name, position) VALUES (?, ?, (SELECT COALESCE(MAX(position), -1) + 1 FROM ${GROUPS_TABLE}))`,
      id,
      name,
    );
    const group = (await this.listGroups()).find((group) => group.id === id);
    if (!group) throw new Error("group was not persisted");
    return group;
  }

  async renameGroup(id: string, name: string): Promise<SidebarGroup> {
    const row = await this.#db.get<SidebarGroup>(
      `UPDATE ${GROUPS_TABLE} SET name = ? WHERE id = ? RETURNING id, name, position`,
      name,
      id,
    );
    if (!row) throw new Error("no such group");
    return row;
  }

  async deleteGroup(id: string): Promise<void> {
    await this.#db.transaction(async (tx) => {
      await tx.run(`UPDATE ${BOTS_TABLE} SET group_id = NULL WHERE group_id = ?`, id);
      await tx.run(`DELETE FROM ${GROUPS_TABLE} WHERE id = ?`, id);
    });
  }

  async reorderGroups(ids: readonly string[]): Promise<SidebarGroup[]> {
    await this.#db.transaction(async (tx) => {
      const rows = await tx.all<{ id: string }>(`SELECT id FROM ${GROUPS_TABLE}`);
      if (
        new Set(ids).size !== ids.length ||
        rows.length !== ids.length ||
        rows.some((row) => !ids.includes(row.id))
      )
        throw new Error("groupIds must contain every group exactly once");
      for (const [position, id] of ids.entries())
        await tx.run(`UPDATE ${GROUPS_TABLE} SET position = ? WHERE id = ?`, position, id);
    });
    return this.listGroups();
  }

  async setGroup(botId: string, groupId: string | null): Promise<void> {
    await this.#db.run(`UPDATE ${BOTS_TABLE} SET group_id = ? WHERE id = ?`, groupId, botId);
  }

  /** The Admin Bot, live or not; undefined before it is created. */
  async admin(): Promise<BotRecord | undefined> {
    const row = await this.#db.get<BotRow>(
      `SELECT ${BOT_COLUMNS} FROM ${BOTS_TABLE} WHERE kind = 'admin'`,
    );
    return row ? toBot(row) : undefined;
  }

  /** Rename a live bot (no rule checks: see `BotManager`). */
  async rename(id: string, name: string): Promise<void> {
    await this.#db.run(
      `UPDATE ${BOTS_TABLE} SET name = ? WHERE id = ? AND deleted_at IS NULL`,
      name,
      id,
    );
  }

  /** Startup migration: give the admin-kind bot its current built-in name. */
  async renameAdmin(name: string): Promise<void> {
    await this.#db.run(
      `UPDATE ${BOTS_TABLE} SET name = ? WHERE kind = 'admin' AND name <> ?`,
      name,
      name,
    );
  }

  /** Set or clear a bot's manager flag and team (no rule checks: see `BotManager`). */
  async setTeam(id: string, team: { manager: boolean; managerId?: string }): Promise<void> {
    await this.#db.run(
      `UPDATE ${BOTS_TABLE} SET is_manager = ?, manager_id = ? WHERE id = ?`,
      team.manager ? 1 : 0,
      team.managerId ?? null,
      id,
    );
  }

  /**
   * Make `id` the orchestrator, taking it off any team it was on, or clear the orchestrator with
   * `undefined`. The previous orchestrator becomes a normal bot (no rule checks: see `BotManager`).
   */
  async setOrchestrator(id: string | undefined): Promise<void> {
    await this.#db.run(
      `UPDATE ${BOTS_TABLE} SET is_orchestrator = 0 WHERE is_orchestrator = 1 AND id != ?`,
      id ?? "",
    );
    if (id !== undefined) {
      await this.#db.run(
        `UPDATE ${BOTS_TABLE} SET is_orchestrator = 1, manager_id = NULL WHERE id = ?`,
        id,
      );
    }
  }

  /** Move every member of `managerId`'s team to `to` (undefined: off any team). */
  async moveMembers(managerId: string, to: string | undefined, except?: string): Promise<void> {
    await this.#db.run(
      `UPDATE ${BOTS_TABLE} SET manager_id = ? WHERE manager_id = ? AND id != ?`,
      to ?? null,
      managerId,
      except ?? "",
    );
  }

  /** Assign a profile (undefined: the default). */
  async setProfile(id: string, profile: string | undefined): Promise<void> {
    await this.#db.run(`UPDATE ${BOTS_TABLE} SET profile = ? WHERE id = ?`, profile ?? null, id);
  }

  /** Every bot (live or deleted) on `profile` goes back to the default profile. */
  async clearProfile(profile: string): Promise<string[]> {
    const rows = await this.#db.all<{ id: string }>(
      `UPDATE ${BOTS_TABLE} SET profile = NULL WHERE profile = ? RETURNING id`,
      profile,
    );
    return rows.map((row) => row.id);
  }

  async note(name: string): Promise<{ text: string; updatedAt: string } | undefined> {
    const row = await this.#db.get<{ text: string; updated_at: string }>(
      `SELECT text, updated_at FROM ${NOTES_TABLE} WHERE name = ?`,
      name,
    );
    return row ? { text: row.text, updatedAt: row.updated_at } : undefined;
  }

  async setNote(name: string, text: string, at = new Date().toISOString()): Promise<void> {
    await this.#db.run(
      `INSERT INTO ${NOTES_TABLE} (name, text, updated_at) VALUES (?, ?, ?) ON CONFLICT(name) DO UPDATE SET text = excluded.text, updated_at = excluded.updated_at`,
      name,
      text,
      at,
    );
  }

  /** A bot's memory; empty with checkpoint 0 before its first extraction. */
  async memory(botId: string): Promise<BotMemory> {
    const row = await this.#db.get<{ facts: string; checkpoint: number; updated_at: string }>(
      `SELECT facts, checkpoint, updated_at FROM ${MEMORY_TABLE} WHERE bot_id = ?`,
      botId,
    );
    if (!row) return { facts: [], checkpoint: 0 };
    return {
      facts: splitFacts(row.facts),
      checkpoint: row.checkpoint,
      updatedAt: row.updated_at,
    };
  }

  async saveMemory(
    botId: string,
    facts: readonly string[],
    checkpoint: number,
    at = new Date().toISOString(),
  ): Promise<void> {
    await writeMemory(this.#db, botId, facts, checkpoint, at);
  }

  /**
   * Read, change and save a bot's memory in one transaction, so extraction and the user's edits
   * never overwrite each other. `update` returns the new facts and checkpoint (or throws to leave
   * it unchanged); the saved memory is returned.
   */
  async updateMemory(
    botId: string,
    update: (memory: BotMemory) => { facts: readonly string[]; checkpoint: number },
  ): Promise<BotMemory> {
    return this.#db.transaction(async (tx) => {
      const row = await tx.get<{ facts: string; checkpoint: number; updated_at: string }>(
        `SELECT facts, checkpoint, updated_at FROM ${MEMORY_TABLE} WHERE bot_id = ?`,
        botId,
      );
      const current: BotMemory = row
        ? { facts: splitFacts(row.facts), checkpoint: row.checkpoint, updatedAt: row.updated_at }
        : { facts: [], checkpoint: 0 };
      const next = update(current);
      const at = new Date().toISOString();
      await writeMemory(tx, botId, next.facts, next.checkpoint, at);
      return { facts: [...next.facts], checkpoint: next.checkpoint, updatedAt: at };
    });
  }

  /** Stored usage limits; `entry` is whatever was saved (`ModelAvailability.load` checks it). */
  async limits(): Promise<{ key: string; entry: unknown }[]> {
    const rows = await this.#db.all<{ key: string; entry: string }>(
      `SELECT key, entry FROM ${LIMITS_TABLE} ORDER BY key`,
    );
    return rows.map((row) => {
      try {
        return { key: row.key, entry: JSON.parse(row.entry) as unknown };
      } catch {
        return { key: row.key, entry: undefined };
      }
    });
  }

  async saveLimit(key: string, entry: LimitEntry): Promise<void> {
    await this.#db.run(
      `INSERT INTO ${LIMITS_TABLE} (key, entry) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET entry = excluded.entry`,
      key,
      JSON.stringify(entry),
    );
  }

  async deleteLimit(key: string): Promise<void> {
    await this.#db.run(`DELETE FROM ${LIMITS_TABLE} WHERE key = ?`, key);
  }

  /** Live bots only; soft-deleted bots are hidden. */
  async list(): Promise<BotRecord[]> {
    const rows = await this.#db.all<BotRow>(
      `SELECT ${BOT_COLUMNS} FROM ${BOTS_TABLE} WHERE deleted_at IS NULL ORDER BY created_at, id`,
    );
    return rows.map(toBot);
  }

  /** A live bot; undefined for an unknown or soft-deleted one. */
  async get(id: string): Promise<BotRecord | undefined> {
    const row = await this.#db.get<BotRow>(
      `SELECT ${BOT_COLUMNS} FROM ${BOTS_TABLE} WHERE id = ? AND deleted_at IS NULL`,
      id,
    );
    return row ? toBot(row) : undefined;
  }

  /** When the bot was soft-deleted, or undefined if it is live or unknown. */
  async deletedAt(id: string): Promise<string | undefined> {
    const row = await this.#db.get<{ deleted_at: string | null }>(
      `SELECT deleted_at FROM ${BOTS_TABLE} WHERE id = ?`,
      id,
    );
    return row?.deleted_at ?? undefined;
  }

  async insert(record: BotRecord): Promise<void> {
    await this.#db.run(
      `INSERT INTO ${BOTS_TABLE} (id, name, schema_prefix, created_at, kind, is_manager, manager_id, profile) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
      record.id,
      record.name,
      record.prefix,
      record.createdAt,
      record.kind,
      record.manager ? 1 : 0,
      record.managerId ?? null,
      record.profile ?? null,
    );
  }

  /**
   * Soft delete: stamp `deleted_at` and nothing else. The bot's prefixed Pi Durable tables, its
   * thread rows and all its data stay in the database, so `restore()` can bring it back. Only
   * the user's explicit `purge()` removes them.
   * Returns false for an unknown or already deleted bot.
   */
  async markDeleted(id: string, at = new Date().toISOString()): Promise<boolean> {
    const row = await this.#db.get<{ id: string }>(
      `UPDATE ${BOTS_TABLE} SET deleted_at = ? WHERE id = ? AND deleted_at IS NULL RETURNING id`,
      at,
      id,
    );
    return row !== undefined;
  }

  /** Soft-deleted bots, most recently deleted first. */
  async listDeleted(): Promise<DeletedBotRecord[]> {
    const rows = await this.#db.all<BotRow & { deleted_at: string }>(
      `SELECT ${BOT_COLUMNS}, deleted_at FROM ${BOTS_TABLE} WHERE deleted_at IS NOT NULL ORDER BY deleted_at DESC, id`,
    );
    return rows.map((row) => ({ ...toBot(row), deletedAt: row.deleted_at }));
  }

  /**
   * Undo a soft delete by clearing `deleted_at`; the bot's tables and threads were never touched.
   * Returns false for an unknown or live bot. Bot names are not unique, so nothing can collide.
   */
  async restore(id: string): Promise<boolean> {
    const row = await this.#db.get<{ id: string }>(
      `UPDATE ${BOTS_TABLE} SET deleted_at = NULL WHERE id = ? AND deleted_at IS NOT NULL RETURNING id`,
      id,
    );
    return row !== undefined;
  }

  /**
   * Permanently remove a soft-deleted bot (the user's purge), in one transaction: every schema
   * object under its own prefix (its Pi Durable session: conversations, threads' entries, tasks,
   * documents, schema version), its thread rows and its registry row (profile assignment, team
   * and orchestrator flags). Team links other rows hold to it are cleared. Returns the dropped
   * tables, or undefined (nothing touched) for an unknown, live or Admin bot.
   */
  async purge(id: string): Promise<string[] | undefined> {
    return this.#db.transaction(async (tx) => {
      const row = await tx.get<{ schema_prefix: string; kind: string }>(
        `SELECT schema_prefix, kind FROM ${BOTS_TABLE} WHERE id = ? AND deleted_at IS NOT NULL`,
        id,
      );
      if (!row || row.kind === "admin") return undefined;
      // Only ever the bot's own `pibot_<32 hex>_` prefix, never another bot's or a shared table.
      if (row.schema_prefix !== botPrefix(id)) {
        throw new Error(`bot ${id} has an unexpected table prefix; not purged`);
      }
      const objects = await prefixedObjects(tx, row.schema_prefix);
      const quoted = (name: string) => `"${name.replaceAll('"', '""')}"`;
      // Views and triggers first; indexes go with their tables.
      for (const object of objects) {
        if (object.type === "view" || object.type === "trigger") {
          await tx.exec(`DROP ${object.type.toUpperCase()} IF EXISTS ${quoted(object.name)}`);
        }
      }
      const tables = objects.filter((object) => object.type === "table").map((t) => t.name);
      for (const table of tables) await tx.exec(`DROP TABLE IF EXISTS ${quoted(table)}`);
      await tx.run(`DELETE FROM ${THREADS_TABLE} WHERE bot_id = ?`, id);
      await tx.run(`DELETE FROM ${MEMORY_TABLE} WHERE bot_id = ?`, id);
      await tx.run(`UPDATE ${BOTS_TABLE} SET manager_id = NULL WHERE manager_id = ?`, id);
      await tx.run(`DELETE FROM ${BOTS_TABLE} WHERE id = ?`, id);
      return tables;
    });
  }

  async addThread(thread: ThreadRecord): Promise<void> {
    await this.#db.run(
      `INSERT INTO ${THREADS_TABLE} (bot_id, conversation_id, parent_conversation_id, forked_at_entry, title, created_at) VALUES (?, ?, ?, ?, ?, ?)`,
      thread.botId,
      thread.conversationId,
      thread.parentConversationId,
      thread.forkedAt,
      thread.title,
      thread.createdAt,
    );
  }

  async listThreads(botId: string): Promise<ThreadRecord[]> {
    const rows = await this.#db.all<ThreadRow>(
      `SELECT * FROM ${THREADS_TABLE} WHERE bot_id = ? ORDER BY is_pinned DESC, created_at DESC, conversation_id DESC`,
      botId,
    );
    return rows.map(toThread);
  }

  async setThreadPinned(
    botId: string,
    conversationId: number,
    pinned: boolean,
  ): Promise<ThreadRecord> {
    const row = await this.#db.get<ThreadRow>(
      `UPDATE ${THREADS_TABLE} SET is_pinned = ? WHERE bot_id = ? AND conversation_id = ? RETURNING *`,
      pinned ? 1 : 0,
      botId,
      conversationId,
    );
    if (!row) throw new Error("Thread not found");
    return toThread(row);
  }

  /** Woven's `updateConversationTitleIfCurrent`: set the title only while it is still empty. */
  async setThreadTitleIfUntitled(
    botId: string,
    conversationId: number,
    title: string,
  ): Promise<boolean> {
    const clean = title.trim();
    if (!clean) return false;
    const updated = await this.#db.get<{ conversation_id: number }>(
      `UPDATE ${THREADS_TABLE} SET title = ? WHERE bot_id = ? AND conversation_id = ? AND title = '' RETURNING conversation_id`,
      clean,
      botId,
      conversationId,
    );
    return updated !== undefined;
  }

  /** Threads whose title contains every whitespace-separated term (case-insensitive). */
  async searchThreads(botId: string, query: string): Promise<ThreadRecord[]> {
    const terms = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
    if (terms.length === 0) return this.listThreads(botId);
    const likeEscape = (term: string) => term.replace(/[\\%_]/g, (c) => `\\${c}`);
    const rows = await this.#db.all<ThreadRow>(
      `SELECT * FROM ${THREADS_TABLE} WHERE bot_id = ? ${terms
        .map(() => "AND lower(title) LIKE ? ESCAPE '\\'")
        .join(" ")} ORDER BY is_pinned DESC, created_at DESC, conversation_id DESC`,
      botId,
      ...terms.map((term) => `%${likeEscape(term)}%`),
    );
    return rows.map(toThread);
  }

  async getThread(botId: string, conversationId: number): Promise<ThreadRecord | undefined> {
    const row = await this.#db.get<ThreadRow>(
      `SELECT * FROM ${THREADS_TABLE} WHERE bot_id = ? AND conversation_id = ?`,
      botId,
      conversationId,
    );
    return row ? toThread(row) : undefined;
  }
}
