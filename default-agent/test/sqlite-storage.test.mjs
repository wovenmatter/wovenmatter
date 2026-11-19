import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { DatabaseSync } from 'node:sqlite';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { openWorkspacePiStorage } from '../src/sqlite-storage.mjs';

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(),'woven-pi-sqlite-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  return {databasePath:join(directory,'workspace.sqlite'),manifest:{storeID:randomUUID(),sessionID:randomUUID()},context};
}
test('failed activation rolls back every native table and its receipt and can retry',async t=>{
  const options=await fixture(t);
  await assert.rejects(openWorkspacePiStorage({...options,beforeActivation:()=>{throw Error('fixture failure')}}),/fixture failure/);
  const database=new DatabaseSync(options.databasePath);
  assert.equal(database.prepare('SELECT count(*) AS n FROM wm_pi_runtime_stores').get().n,0);
  assert.equal(database.prepare("SELECT count(*) AS n FROM sqlite_schema WHERE name LIKE 'wm_pi_%durable_metadata'").get().n,0);
  database.close();
  const storage=await openWorkspacePiStorage(options); await storage.close(context);
});

test('a database an earlier build made still opens: its store list loses the column nothing reads, and keeps its rows',async t=>{
  const options=await fixture(t), other={...options,manifest:{storeID:randomUUID(),sessionID:randomUUID()}};
  const {Harness,createRegistry}=await import('@earendil-works/pi-durable');
  const {createModels}=await import('@earendil-works/pi-ai/models');
  const open=async manifest=>{const storage=await openWorkspacePiStorage({...options,manifest});return {storage,harness:await Harness.open(storage,{models:createModels(),registry:createRegistry()},context)}};
  const first=await open(options.manifest), root=await first.harness.root(context);
  const receipt=await root.submit({type:'write',requestId:'kept',entry:{kind:'fixture.commit',data:{text:'written by the earlier build'}}},context);
  await first.storage.close(context);
  // The store list exactly as the earlier build declared and filled it.
  const columns=()=>{const database=new DatabaseSync(options.databasePath);try{return database.prepare('PRAGMA table_info(wm_pi_runtime_stores)').all().map(column=>column.name)}finally{database.close()}};
  const earlier=new DatabaseSync(options.databasePath);
  const activated=earlier.prepare('SELECT * FROM wm_pi_runtime_stores').all();
  earlier.exec(`BEGIN;
    DROP TABLE wm_pi_runtime_stores;
    CREATE TABLE wm_pi_runtime_stores (store_id TEXT PRIMARY KEY, session_id TEXT NOT NULL UNIQUE, schema_prefix TEXT NOT NULL UNIQUE, format INTEGER NOT NULL, activated_at TEXT NOT NULL);
    COMMIT`);
  for(const row of activated)earlier.prepare('INSERT INTO wm_pi_runtime_stores VALUES (?,?,?,?,?)').run(row.store_id,row.session_id,row.schema_prefix,1,row.activated_at);
  earlier.close();
  assert.deepEqual(columns(),['store_id','session_id','schema_prefix','format','activated_at']);
  // Its session reopens with what it committed, and another session activates beside it.
  const reopened=await openWorkspacePiStorage(options);
  assert.equal((await reopened.submissionByRequest(root.id,'kept',context)).id,receipt.id);
  assert.equal((await reopened.scanEntries({conversationId:root.id},100,undefined,context)).items.filter(entry=>entry.data?.text==='written by the earlier build').length,1);
  await reopened.close(context);
  assert.deepEqual(columns(),['store_id','session_id','schema_prefix','activated_at']);
  const second=await open(other.manifest); await second.storage.close(context);
  const database=new DatabaseSync(options.databasePath);
  const rows=database.prepare('SELECT * FROM wm_pi_runtime_stores ORDER BY rowid').all().map(row=>({...row}));
  database.close();
  assert.deepEqual(rows[0],{...activated[0]});
  assert.deepEqual(rows.map(row=>[row.store_id,row.session_id]),[options.manifest,other.manifest].map(manifest=>[manifest.storeID,manifest.sessionID]));
  // A session whose identity differs from the one its store was activated with is still refused.
  await assert.rejects(openWorkspacePiStorage({...options,manifest:{...options.manifest,sessionID:randomUUID()}}),/store identity changed/);
});

test('committed SQLite state survives abrupt owner-process death without close or replay',async t=>{
  const options=await fixture(t);
  const module=new URL('../src/sqlite-storage.mjs',import.meta.url).href;
  const script=`
    import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
    import { Harness,createRegistry,defineDoc } from '@earendil-works/pi-durable';
    import { createModels } from '@earendil-works/pi-ai/models';
    const {openWorkspacePiStorage}=await import(${JSON.stringify(module)});
    const options=${JSON.stringify({databasePath:options.databasePath,manifest:options.manifest})};
    const storage=await openWorkspacePiStorage({...options,context});
    const harness=await Harness.open(storage,{models:createModels(),registry:createRegistry()},context);
    const root=await harness.root(context);
    const receipt=await root.submit({type:'write',requestId:'crash-receipt',entry:{kind:'fixture.commit',data:{text:'committed before crash'}}},context);
    await new Promise(resolve=>process.stdout.write(JSON.stringify({rootID:root.id,receiptID:receipt.id}),resolve));
    process.kill(process.pid,'SIGKILL');
  `;
  let output;
  try { await promisify(execFile)(process.execPath,['--input-type=module','-e',script],{cwd:new URL('..',import.meta.url)}); assert.fail('Fixture did not crash'); }
  catch(error) { assert.equal(error.signal,'SIGKILL'); output=JSON.parse(error.stdout); }
  const storage=await openWorkspacePiStorage(options);
  assert.equal((await storage.submissionByRequest(output.rootID,'crash-receipt',context)).id,output.receiptID);
  const entries=await storage.scanEntries({conversationId:output.rootID},100,undefined,context);
  assert.equal(entries.items.filter(entry=>entry.data?.text==='committed before crash').length,1);
  await storage.close(context);
});
