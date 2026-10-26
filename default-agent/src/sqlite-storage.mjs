import { chmod, lstat, mkdir, open } from 'node:fs/promises';
import { dirname, isAbsolute, join } from 'node:path';
import { SqliteStorage } from '@earendil-works/pi-durable/storage/sqlite';
import { openNodeSqliteDatabase } from '@earendil-works/pi-durable/storage/sqlite/node';
import { openNodeJsonlStorage } from '@earendil-works/pi-durable/storage/jsonl/node';
import { legacyCommits } from './legacy-jsonl-migration.mjs';

const uuid = value => typeof value === 'string' && /^[0-9a-f-]{36}$/i.test(value);
async function exists(path) {
  try { return await lstat(path); } catch(error) { if (error.code === 'ENOENT') return null; throw error; }
}
async function protectLegacy(path) {
  if (!await exists(path)) return;
  // Older app versions cannot append a second execution history after SQLite
  // becomes authoritative. The complete legacy store remains a readable backup.
  await chmod(path, 0o400);
  const file = await open(path, 'r');
  try { await file.sync(); } finally { await file.close(); }
}

export async function openWorkspacePiStorage({databasePath, root, manifest, context, beforeActivation}) {
  if (!isAbsolute(databasePath) || !uuid(manifest.storeID) || !uuid(manifest.sessionID)) throw new Error('Invalid Pi SQLite store identity.');
  const parent = dirname(databasePath);
  await mkdir(parent, {recursive:true,mode:0o700});
  const info = await exists(databasePath);
  if (info && (!info.isFile() || info.isSymbolicLink())) throw new Error('The Pi execution database must be a regular file.');
  const database = await openNodeSqliteDatabase(databasePath, {busyTimeoutMs:5000});
  const prefix = `wm_pi_${manifest.storeID.replaceAll('-','')}_`;
  const legacyDirectory = join(root,'native'), legacyMain = join(legacyDirectory,'main.jsonl');
  let legacy;
  try {
    if (!info) await chmod(databasePath,0o600);
    // Match fsync-before-acknowledgement, including power loss, rather than the
    // upstream SQLite adapter's less durable NORMAL default.
    await database.exec('PRAGMA synchronous = FULL');
    await database.exec('PRAGMA foreign_keys = ON');
    await database.exec('CREATE TABLE IF NOT EXISTS wm_pi_runtime_stores (store_id TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE, schema_prefix TEXT NOT NULL UNIQUE, format INTEGER NOT NULL, activated_at TEXT NOT NULL)');
    const installed = await database.get('SELECT * FROM wm_pi_runtime_stores WHERE store_id = ?',manifest.storeID);
    if (installed) {
      if (installed.session_id !== manifest.sessionID || installed.schema_prefix !== prefix || installed.format !== 1) throw new Error('The Pi SQLite store identity changed.');
    } else {
      // This holds no scheduler. Opening Storage alone validates and repairs
      // uncommitted JSONL tails without replaying a model request or tool.
      if (await exists(legacyMain)) legacy = await openNodeJsonlStorage(legacyDirectory,context,{fsync:true});
      const commits = legacy ? await legacyCommits(legacyDirectory) : [];
      await database.transaction(async transaction => {
        // Every schema change, commit and activation receipt shares one SQLite
        // transaction. Failure leaves no partially imported execution store.
        const facade = {...Object.fromEntries(['exec','run','get','all'].map(name=>[name,(...args)=>transaction[name](...args)])),
          transaction: operation=>operation(transaction),close:async()=>{}};
        const target = await SqliteStorage.open(facade,{prefix});
        for (const commit of commits) {
          const seq = await target.commit(commit.writes,context);
          if (seq !== commit.seq) throw new Error('Legacy commit identities could not be preserved.');
        }
        await beforeActivation?.(target);
        await transaction.run('INSERT INTO wm_pi_runtime_stores VALUES (?,?,?,?,?)',manifest.storeID,manifest.sessionID,prefix,1,new Date().toISOString());
        await target.close(context);
      });
    }
    await legacy?.close(context); legacy = undefined;
    await protectLegacy(legacyMain);
    return await SqliteStorage.open(database,{prefix});
  } catch(error) {
    await legacy?.close(context).catch(()=>{});
    await database.close().catch(()=>{});
    throw error;
  }
}
