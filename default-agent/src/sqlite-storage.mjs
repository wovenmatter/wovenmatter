import { chmod, lstat, mkdir } from 'node:fs/promises';
import { dirname, isAbsolute } from 'node:path';
import { SqliteStorage } from '@earendil-works/pi-durable/storage/sqlite';
import { openNodeSqliteDatabase } from '@earendil-works/pi-durable/storage/sqlite/node';

const uuid = value => typeof value === 'string' && /^[0-9a-f-]{36}$/i.test(value);
async function exists(path) {
  try { return await lstat(path); } catch(error) { if (error.code === 'ENOENT') return null; throw error; }
}
export async function openWorkspacePiStorage({databasePath, manifest, context, beforeActivation}) {
  if (!isAbsolute(databasePath) || !uuid(manifest.storeID) || !uuid(manifest.sessionID)) throw new Error('Invalid Pi SQLite store identity.');
  const parent = dirname(databasePath);
  await mkdir(parent, {recursive:true,mode:0o700});
  const info = await exists(databasePath);
  if (info && (!info.isFile() || info.isSymbolicLink())) throw new Error('The Pi execution database must be a regular file.');
  const database = await openNodeSqliteDatabase(databasePath, {busyTimeoutMs:5000});
  const prefix = `wm_pi_${manifest.storeID.replaceAll('-','')}_`;
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
      await database.transaction(async transaction => {
        // Every schema change and the activation receipt share one SQLite
        // transaction. Failure leaves no partially created execution store.
        const facade = {...Object.fromEntries(['exec','run','runCounted','get','all'].map(name=>[name,(...args)=>transaction[name](...args)])),
          transaction: operation=>operation(transaction),close:async()=>{}};
        const target = await SqliteStorage.open(facade,{prefix});
        await beforeActivation?.(target);
        await transaction.run('INSERT INTO wm_pi_runtime_stores VALUES (?,?,?,?,?)',manifest.storeID,manifest.sessionID,prefix,1,new Date().toISOString());
        await target.close(context);
      });
    }
    return await SqliteStorage.open(database,{prefix});
  } catch(error) {
    await database.close().catch(()=>{});
    throw error;
  }
}
