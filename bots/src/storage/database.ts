import { chmod, mkdir, open, stat } from "node:fs/promises";
import { dirname } from "node:path";
import type { SqliteDatabase } from "@earendil-works/pi-durable/storage/sqlite";
import {
  type NodeSqliteDatabase,
  openNodeSqliteDatabase,
} from "@earendil-works/pi-durable/storage/sqlite/node";

const FILE_MODE = 0o600;
const DIR_MODE = 0o700;

async function restrictIfPresent(path: string): Promise<void> {
  try {
    await stat(path);
    await chmod(path, FILE_MODE);
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") throw error;
  }
}

/**
 * Open the one SQLite database every bot shares (Woven's sqlite-storage pattern): the directory
 * is 0700, the database and its WAL/SHM files 0600, `synchronous=FULL` and foreign keys on.
 * `:memory:` is accepted for tests.
 */
export async function openSharedDatabase(path: string): Promise<NodeSqliteDatabase> {
  if (path !== ":memory:") {
    const dir = dirname(path);
    await mkdir(dir, { recursive: true, mode: DIR_MODE });
    await chmod(dir, DIR_MODE);
    await (await open(path, "a", FILE_MODE)).close();
    await chmod(path, FILE_MODE);
  }
  const db = await openNodeSqliteDatabase(path, { busyTimeoutMs: 5_000 });
  await db.exec("PRAGMA synchronous = FULL; PRAGMA foreign_keys = ON;");
  if (path !== ":memory:") {
    await restrictIfPresent(`${path}-wal`);
    await restrictIfPresent(`${path}-shm`);
  }
  return db;
}

/**
 * A view of the shared database whose `close()` is a no-op. Each bot's `SqliteStorage` gets one
 * so closing a bot's storage can never close the database the other bots still use.
 */
export function sharedDatabaseView(db: SqliteDatabase): SqliteDatabase {
  return {
    exec: (sql) => db.exec(sql),
    run: (sql, ...params) => db.run(sql, ...params),
    runCounted: (sql, ...params) => db.runCounted(sql, ...params),
    get: (sql, ...params) => db.get(sql, ...params),
    all: (sql, ...params) => db.all(sql, ...params),
    transaction: (callback) => db.transaction(callback),
    close: async () => {},
  };
}
