import { stat } from "node:fs/promises";
import { join } from "node:path";
import { BACKGROUND_CONTEXT } from "@earendil-works/chord/context";
import type { SqliteExecutor } from "@earendil-works/pi-durable/storage/sqlite";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { openSharedDatabase, sharedDatabaseView } from "../src/storage/database.ts";
import {
  BOTS_TABLE,
  BotRegistry,
  botPrefix,
  DELIVERIES_TABLE,
  GROUPS_TABLE,
  LIMITS_TABLE,
  MEMORY_TABLE,
  NOTES_TABLE,
  prefixedObjects,
  THREADS_TABLE,
} from "../src/storage/registry.ts";
import { openTestManager, tempDir } from "./helpers.ts";

const ctx = BACKGROUND_CONTEXT;

describe("shared storage", () => {
  let dir: Awaited<ReturnType<typeof tempDir>>;
  beforeEach(async () => {
    dir = await tempDir();
  });
  afterEach(async () => {
    await dir.cleanup();
  });

  it("forwards affected row counts without closing the shared connection", async () => {
    const db = await openSharedDatabase(":memory:");
    try {
      const view = sharedDatabaseView(db);
      await view.exec("CREATE TABLE counted (id INTEGER PRIMARY KEY)");
      expect(await view.runCounted("INSERT INTO counted VALUES (?)", 1)).toBe(1);
      expect(await view.runCounted("DELETE FROM counted WHERE id = ?", 2)).toBe(0);
      await view.close();
      expect(await db.get("SELECT COUNT(*) AS total FROM counted")).toEqual({ total: 1 });
    } finally {
      await db.close();
    }
  });

  it("migrates legacy threads, persists pins, and keeps newest-first order within each group", async () => {
    const path = join(dir.path, "pins.sqlite");
    let db = await openSharedDatabase(path);
    let registry = new BotRegistry(db);
    await registry.migrate();
    const botId = "0b9e1c2d-3f4a-4b5c-8d6e-7f8091a2b3c4";
    await db.run(
      `INSERT INTO ${BOTS_TABLE} (id, name, schema_prefix, created_at) VALUES (?, ?, ?, ?)`,
      botId,
      "Test",
      botPrefix(botId),
      "2026-01-01",
    );
    // Reproduce a pre-pin table with real existing thread rows.
    await db.exec(`ALTER TABLE ${THREADS_TABLE} DROP COLUMN is_pinned`);
    for (const [id, created] of [
      [2, "2026-01-01"],
      [3, "2026-01-02"],
      [4, "2026-01-03"],
    ] as const)
      await registry.addThread({
        botId,
        conversationId: id,
        parentConversationId: 1,
        forkedAt: 1,
        title: `Thread ${id}`,
        createdAt: created,
      });
    await registry.migrate();
    await registry.migrate();
    expect((await registry.listThreads(botId)).map((t) => t.conversationId)).toEqual([4, 3, 2]);
    expect(await registry.setThreadPinned(botId, 2, true)).toMatchObject({ pinned: true });
    await registry.setThreadPinned(botId, 3, true);
    await expect(registry.setThreadPinned("another-bot", 2, true)).rejects.toThrow(
      "Thread not found",
    );
    await db.close();
    db = await openSharedDatabase(path);
    registry = new BotRegistry(db);
    try {
      expect((await registry.listThreads(botId)).map((t) => t.conversationId)).toEqual([3, 2, 4]);
      expect((await registry.searchThreads(botId, "Thread")).map((t) => t.conversationId)).toEqual([
        3, 2, 4,
      ]);
      await registry.setThreadPinned(botId, 2, false);
      expect((await registry.listThreads(botId)).map((t) => t.conversationId)).toEqual([3, 4, 2]);
      expect((await registry.getThread(botId, 2))?.pinned).toBeUndefined();
    } finally {
      await db.close();
    }
  });

  it("derives Woven-style per-bot prefixes", () => {
    expect(botPrefix("0b9e1c2d-3f4a-4b5c-8d6e-7f8091a2b3c4")).toBe(
      "pibot_0b9e1c2d3f4a4b5c8d6e7f8091a2b3c4_",
    );
    expect(() => botPrefix("../evil")).toThrow();
    expect(() => botPrefix("bots")).toThrow();
  });

  it("creates the database 0600 in a 0700 directory", async () => {
    const dbPath = join(dir.path, "state", "pi-bot.sqlite");
    const t = await openTestManager(dbPath);
    try {
      expect((await stat(dbPath)).mode & 0o777).toBe(0o600);
      expect((await stat(join(dir.path, "state"))).mode & 0o777).toBe(0o700);
    } finally {
      await t.close();
    }
  });

  it("keeps every bot's durable tables under its own prefix", async () => {
    const t = await openTestManager(join(dir.path, "pi-bot.sqlite"));
    try {
      const a = await t.manager.create("Alpha");
      const b = await t.manager.create("Beta");
      expect(a.prefix).not.toBe(b.prefix);

      const all = await t.db.all<{ name: string }>(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
      );
      const names = all.map((row) => row.name);
      expect(names).toContain(BOTS_TABLE);
      expect(names).toContain(THREADS_TABLE);
      // Nothing outside the shared tables escapes a bot prefix.
      for (const name of names) {
        if (
          [
            BOTS_TABLE,
            THREADS_TABLE,
            NOTES_TABLE,
            LIMITS_TABLE,
            MEMORY_TABLE,
            GROUPS_TABLE,
            DELIVERIES_TABLE,
          ].includes(name)
        )
          continue;
        expect(name.startsWith(a.prefix) || name.startsWith(b.prefix), name).toBe(true);
      }
      const aTables = await prefixedObjects(t.db, a.prefix);
      const bTables = await prefixedObjects(t.db, b.prefix);
      expect(aTables.length).toBeGreaterThan(0);
      expect(aTables.map((o) => o.name.slice(a.prefix.length))).toEqual(
        bTables.map((o) => o.name.slice(b.prefix.length)),
      );

      const rows = await t.db.all<{ id: string; schema_prefix: string }>(
        `SELECT id, schema_prefix FROM ${BOTS_TABLE} ORDER BY created_at`,
      );
      expect(rows).toEqual([
        { id: a.id, schema_prefix: a.prefix },
        { id: b.id, schema_prefix: b.prefix },
      ]);
    } finally {
      await t.close();
    }
  });

  it("soft-deletes a bot: its tables, data and thread rows stay", async () => {
    const t = await openTestManager(join(dir.path, "pi-bot.sqlite"));
    try {
      const a = await t.manager.create("Alpha");
      const b = await t.manager.create("Beta");
      const alpha = await t.manager.get(a.id);
      const sent = await alpha.send("remember me");
      await expect(sent.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
      const main = await alpha.main();
      const last = (await main.entries({ order: "descending" }, 1, undefined, ctx)).items[0];
      if (!last) throw new Error("empty main");
      const thread = await alpha.fork({ entryId: last.id as unknown as number });
      const objectsBefore = await prefixedObjects(t.db, a.prefix);
      const rowsBefore = await rowCounts(t.db, objectsBefore);
      expect(Object.values(rowsBefore).some((count) => count > 0)).toBe(true);
      const betaBefore = (await prefixedObjects(t.db, b.prefix)).length;

      expect(await t.manager.delete(a.id)).toBe(true);
      await alpha.harness.closed;

      // No DROP and no DELETE: every object and every row is still there.
      const objectsAfter = await prefixedObjects(t.db, a.prefix);
      expect(objectsAfter).toEqual(objectsBefore);
      expect(await rowCounts(t.db, objectsAfter)).toEqual(rowsBefore);
      expect(await t.manager.registry.listThreads(a.id)).toEqual([
        expect.objectContaining({ conversationId: thread.conversationId }),
      ]);
      const row = await t.db.get<{ deleted_at: string | null }>(
        `SELECT deleted_at FROM ${BOTS_TABLE} WHERE id = ?`,
        a.id,
      );
      expect(row?.deleted_at).toMatch(/^\d{4}-/);

      // Hidden and unopenable, with a clear error; a second delete is a no-op.
      expect((await t.manager.list()).map((bot) => bot.id)).toEqual([b.id]);
      expect(await t.manager.registry.get(a.id)).toBeUndefined();
      await expect(t.manager.get(a.id)).rejects.toThrow(`bot ${a.id} was deleted`);
      expect(await t.manager.delete(a.id)).toBe(false);
      expect((await prefixedObjects(t.db, b.prefix)).length).toBe(betaBefore);

      // The surviving bot still works.
      const beta = await t.manager.get(b.id);
      const sub = await beta.send("still here?");
      await expect(sub.submission.wait(ctx)).resolves.toMatchObject({ status: "done" });
    } finally {
      await t.close();
    }
  });

  it("adds the orchestrator column to a team-era database and keeps its bots", async () => {
    const dbPath = join(dir.path, "pi-bot.sqlite");
    const db = await openSharedDatabase(dbPath);
    const ids = ["0b9e1c2d-3f4a-4b5c-8d6e-7f8091a2b3c4", "1b9e1c2d-3f4a-4b5c-8d6e-7f8091a2b3c4"];
    const [adminId, botId] = ids as [string, string];
    // The registry as it was before the orchestrator: kind, teams, profiles, no is_orchestrator.
    await db.exec(
      `CREATE TABLE ${BOTS_TABLE} (id TEXT PRIMARY KEY, name TEXT NOT NULL, schema_prefix TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL, deleted_at TEXT, kind TEXT NOT NULL DEFAULT 'bot', is_manager INTEGER NOT NULL DEFAULT 0, manager_id TEXT, model TEXT, profile TEXT) STRICT`,
    );
    await db.run(
      `INSERT INTO ${BOTS_TABLE} (id, name, schema_prefix, created_at, kind, profile) VALUES (?, ?, ?, ?, 'admin', 'fast')`,
      adminId,
      "Admin Bot",
      botPrefix(adminId),
      "2026-01-01T00:00:00.000Z",
    );
    await db.run(
      `INSERT INTO ${BOTS_TABLE} (id, name, schema_prefix, created_at, is_manager) VALUES (?, ?, ?, ?, 1)`,
      botId,
      "Lead",
      botPrefix(botId),
      "2026-01-02T00:00:00.000Z",
    );
    const registry = new BotRegistry(db);
    try {
      await registry.migrate();
      await registry.migrate();
      expect(await registry.list()).toEqual([
        expect.objectContaining({
          id: adminId,
          kind: "admin",
          profile: "fast",
          orchestrator: false,
        }),
        expect.objectContaining({ id: botId, name: "Lead", manager: true, orchestrator: false }),
      ]);
      await registry.setOrchestrator(botId);
      expect(await registry.get(botId)).toMatchObject({ orchestrator: true, manager: true });
      // The unique index allows at most one orchestrator.
      await expect(
        db.run(`UPDATE ${BOTS_TABLE} SET is_orchestrator = 1 WHERE id = ?`, adminId),
      ).rejects.toThrow();
      await registry.setOrchestrator(undefined);
      expect((await registry.list()).filter((bot) => bot.orchestrator)).toEqual([]);
    } finally {
      await db.close();
    }
  });

  it("renames the top-bot column to is_orchestrator and keeps who holds it", async () => {
    const dbPath = join(dir.path, "pi-bot.sqlite");
    const db = await openSharedDatabase(dbPath);
    const ids = ["0b9e1c2d-3f4a-4b5c-8d6e-7f8091a2b3c4", "1b9e1c2d-3f4a-4b5c-8d6e-7f8091a2b3c4"];
    const [adminId, botId] = ids as [string, string];
    // The registry as it was with the first "top bot": is_top and its unique index.
    await db.exec(
      `CREATE TABLE ${BOTS_TABLE} (id TEXT PRIMARY KEY, name TEXT NOT NULL, schema_prefix TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL, deleted_at TEXT, kind TEXT NOT NULL DEFAULT 'bot', is_manager INTEGER NOT NULL DEFAULT 0, manager_id TEXT, model TEXT, profile TEXT, is_top INTEGER NOT NULL DEFAULT 0) STRICT;
      CREATE UNIQUE INDEX pibot_bots_one_top ON ${BOTS_TABLE}(is_top) WHERE is_top = 1`,
    );
    await db.run(
      `INSERT INTO ${BOTS_TABLE} (id, name, schema_prefix, created_at, kind) VALUES (?, ?, ?, ?, 'admin')`,
      adminId,
      "Admin Bot",
      botPrefix(adminId),
      "2026-01-01T00:00:00.000Z",
    );
    await db.run(
      `INSERT INTO ${BOTS_TABLE} (id, name, schema_prefix, created_at, is_manager, is_top, profile) VALUES (?, ?, ?, ?, 1, 1, 'fast')`,
      botId,
      "Chief",
      botPrefix(botId),
      "2026-01-02T00:00:00.000Z",
    );
    const registry = new BotRegistry(db);
    try {
      await registry.migrate();
      await registry.migrate();
      const columns = (await db.all<{ name: string }>(`PRAGMA table_info(${BOTS_TABLE})`)).map(
        (column) => column.name,
      );
      expect(columns).toContain("is_orchestrator");
      expect(columns).not.toContain("is_top");
      const indexes = (
        await db.all<{ name: string }>(
          `SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = '${BOTS_TABLE}'`,
        )
      ).map((index) => index.name);
      expect(indexes).toContain("pibot_bots_one_orchestrator");
      expect(indexes).not.toContain("pibot_bots_one_top");
      expect(await registry.list()).toEqual([
        expect.objectContaining({ id: adminId, name: "Admin Bot", orchestrator: false }),
        expect.objectContaining({
          id: botId,
          name: "Chief",
          manager: true,
          orchestrator: true,
          profile: "fast",
        }),
      ]);
      await expect(
        db.run(`UPDATE ${BOTS_TABLE} SET is_orchestrator = 1 WHERE id = ?`, adminId),
      ).rejects.toThrow();
    } finally {
      await db.close();
    }
  });

  it("adds deleted_at and team columns to a registry created before them", async () => {
    const dbPath = join(dir.path, "pi-bot.sqlite");
    const db = await openSharedDatabase(dbPath);
    const id = "0b9e1c2d-3f4a-4b5c-8d6e-7f8091a2b3c4";
    await db.exec(
      `CREATE TABLE ${BOTS_TABLE} (id TEXT PRIMARY KEY, name TEXT NOT NULL, schema_prefix TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL) STRICT`,
    );
    await db.run(
      `INSERT INTO ${BOTS_TABLE} (id, name, schema_prefix, created_at) VALUES (?, ?, ?, ?)`,
      id,
      "Old",
      botPrefix(id),
      "2026-01-01T00:00:00.000Z",
    );
    const registry = new BotRegistry(db);
    try {
      await registry.migrate();
      await registry.migrate();
      expect(await registry.list()).toEqual([
        expect.objectContaining({ name: "Old", kind: "bot", manager: false, orchestrator: false }),
      ]);
      expect(await registry.admin()).toBeUndefined();
      await registry.setTeam(id, { manager: true });
      await registry.setProfile(id, "fast");
      expect(await registry.get(id)).toMatchObject({ manager: true, profile: "fast" });
      expect(await registry.clearProfile("fast")).toEqual([id]);
      expect((await registry.get(id))?.profile).toBeUndefined();
      expect(await registry.note("account")).toBeUndefined();
      await registry.setNote("account", "first");
      await registry.setNote("account", "second");
      expect(await registry.note("account")).toMatchObject({ text: "second" });
      await registry.setTeam(id, { manager: false });
      expect(await registry.markDeleted(id)).toBe(true);
      expect(await registry.markDeleted(id)).toBe(false);
      expect(await registry.list()).toEqual([]);
      expect(await registry.deletedAt(id)).toMatch(/^\d{4}-/);
      expect(await registry.markDeleted("00000000-0000-4000-8000-000000000000")).toBe(false);
      expect(await registry.listDeleted()).toEqual([
        expect.objectContaining({ id, name: "Old", deletedAt: expect.any(String) }),
      ]);
      expect(await registry.restore(id)).toBe(true);
      expect(await registry.restore(id)).toBe(false);
      expect(await registry.listDeleted()).toEqual([]);
      expect((await registry.list()).map((bot) => bot.id)).toEqual([id]);
      expect(await registry.deletedAt(id)).toBeUndefined();
    } finally {
      await db.close();
    }
  });
});

async function rowCounts(
  db: SqliteExecutor,
  objects: readonly { type: string; name: string }[],
): Promise<Record<string, number>> {
  const counts: Record<string, number> = {};
  for (const { type, name } of objects) {
    if (type !== "table") continue;
    const row = await db.get<{ n: number }>(`SELECT count(*) AS n FROM "${name}"`);
    counts[name] = row?.n ?? 0;
  }
  return counts;
}
