import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { DatabaseSync } from 'node:sqlite';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { createModels } from '@earendil-works/pi-ai/models';
import { Harness, createRegistry, defineDoc, defineTask } from '@earendil-works/pi-durable';
import { openNodeJsonlStorage } from '@earendil-works/pi-durable/storage/jsonl/node';
import { openWorkspacePiStorage } from '../src/sqlite-storage.mjs';

const State = defineDoc({kind:'fixture.state',version:1,scope:'conversation',checkpointWhen:()=>false,
  history:'rewindable',fork:'asOf',initial:()=>({text:'initial'})});
const Latest = defineDoc({kind:'fixture.latest',version:1,scope:'conversation',checkpointWhen:()=>false,
  history:'latest',fork:'current',initial:()=>({value:0})});

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(),'woven-pi-sqlite-'));
  t.after(()=>rm(directory,{recursive:true,force:true}));
  const root = join(directory,'session'), manifest = {storeID:randomUUID(),sessionID:randomUUID()};
  await mkdir(root,{recursive:true});
  return {databasePath:join(directory,'workspace.sqlite'),root,manifest,context};
}
async function seedLegacy(options) {
  const storage = await openNodeJsonlStorage(join(options.root,'native'),context,{fsync:true});
  const harness = await Harness.open(storage,{models:createModels(),registry:createRegistry()},context);
  const root = await harness.root(context);
  let childID, taskID, firstSeq;
  await root.commit(async tx=>{
    (await tx.doc(State,root.id)).text='first 🧶\u0000';
    await tx.doc(Latest,root.id);
    const task = defineTask({name:'fixture.sleep',version:1,initial:()=>({phase:'wait'}),phases:{wait:()=>{throw Error('Migration must not run this task');}}});
    taskID = await tx.createTask(task,{}, {conversationId:root.id,ownership:{kind:'conversation'},background:true});
    const child = await tx.createConversation({ownership:{kind:'task',taskId:taskID}});
    childID=child.id;
    await tx.appendEntry(childID,{kind:'fixture.child',data:{text:'child transcript'},edits:[]});
  },context);
  firstSeq = (await storage.findDocument({kind:'fixture.state',scope:{kind:'conversation',conversationId:root.id}},'current',context)).createdAt;
  await root.commit(async tx=>{
    (await tx.doc(State,root.id)).text='second';
    (await tx.doc(Latest,root.id)).value=2;
  },context);
  const receipt = await root.submit({type:'write',requestId:'fixture-receipt',entry:{kind:'fixture.receipt',data:{text:'never duplicate'}}},context);
  const expectedReceipt = await storage.submission(receipt.id,context);
  const expectedConversations = await storage.scanConversations({},100,undefined,context);
  const expectedTasks = await storage.scanTasks({},100,undefined,context);
  const document = await storage.findDocument({kind:'fixture.state',scope:{kind:'conversation',conversationId:root.id}},'current',context);
  const historical = await storage.document(document.id,firstSeq,context);
  await harness.close(context);
  return {rootID:root.id,childID,taskID,expectedReceipt,expectedConversations,expectedTasks,document,historical,firstSeq};
}

test('migration preserves native child ownership, checkpoints, rewind history and reclaimed latest documents',async t=>{
  const options = await fixture(t), expected=await seedLegacy(options);
  const source = await readFile(join(options.root,'native/main.jsonl'));
  const storage = await openWorkspacePiStorage(options);
  assert.deepEqual(await storage.scanConversations({},100,undefined,context),expected.expectedConversations);
  assert.deepEqual(await storage.scanTasks({},100,undefined,context),expected.expectedTasks);
  assert.deepEqual(await storage.document(expected.document.id,expected.firstSeq,context),expected.historical);
  assert.equal((await storage.document(expected.document.id,'current',context)).value.text,'second');
  assert.deepEqual(await storage.submissionByRequest(expected.rootID,'fixture-receipt',context),expected.expectedReceipt);
  assert.equal((await storage.conversation(expected.childID,context)).owner.taskId,expected.taskID);
  assert.ok((await storage.scanEntries({conversationId:expected.childID},100,undefined,context)).items.some(entry=>entry.data?.text==='child transcript'));
  await storage.close(context);
  assert.deepEqual(await readFile(join(options.root,'native/main.jsonl')),source);
  assert.equal((await stat(join(options.root,'native/main.jsonl'))).mode & 0o222,0);
  const reopened=await openWorkspacePiStorage(options);
  assert.deepEqual(await reopened.scanTasks({},100,undefined,context),expected.expectedTasks);
  await reopened.close(context);
});

test('failed import rolls back every native table and receipt and can retry from the preserved source',async t=>{
  const options=await fixture(t); await seedLegacy(options);
  await assert.rejects(openWorkspacePiStorage({...options,beforeActivation:()=>{throw Error('fixture failure')}}),/fixture failure/);
  const database=new DatabaseSync(options.databasePath);
  assert.equal(database.prepare('SELECT count(*) AS n FROM wm_pi_runtime_stores').get().n,0);
  assert.equal(database.prepare("SELECT count(*) AS n FROM sqlite_schema WHERE name LIKE 'wm_pi_%durable_metadata'").get().n,0);
  database.close();
  const storage=await openWorkspacePiStorage(options); await storage.close(context);
});

test('independent native stores share the workspace file without sharing records or altering host tables',async t=>{
  const first=await fixture(t), second={...first,root:join(first.root,'other'),manifest:{storeID:randomUUID(),sessionID:randomUUID()}};
  const host=new DatabaseSync(first.databasePath); host.exec('CREATE TABLE host_notes (text TEXT); INSERT INTO host_notes VALUES (\'preserve\')'); host.close();
  const a=await openWorkspacePiStorage(first), b=await openWorkspacePiStorage(second);
  const harness=await Harness.open(a,{models:createModels(),registry:createRegistry()},context);
  await harness.root(context);
  assert.equal((await b.scanConversations({},100,undefined,context)).items.length,0);
  await harness.close(context); await b.close(context);
  const verify=new DatabaseSync(first.databasePath); assert.equal(verify.prepare('SELECT text FROM host_notes').get().text,'preserve'); verify.close();
});


test('committed SQLite state survives abrupt owner-process death without close or replay',async t=>{
  const options=await fixture(t);
  const module=new URL('../src/sqlite-storage.mjs',import.meta.url).href;
  const script=`
    import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
    import { Harness,createRegistry,defineDoc } from '@earendil-works/pi-durable';
    import { createModels } from '@earendil-works/pi-ai/models';
    const {openWorkspacePiStorage}=await import(${JSON.stringify(module)});
    const options=${JSON.stringify({databasePath:options.databasePath,root:options.root,manifest:options.manifest})};
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
