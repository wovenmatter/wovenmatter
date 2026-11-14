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
