import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { DatabaseSync } from 'node:sqlite'
import { createClientExecution } from '../src/client-execution.mjs'
import { enroll } from './fixtures/execution.mjs'

const tick=()=>new Promise(resolve=>setTimeout(resolve,5))
async function until(predicate){for(let n=0;n<200;n++){if(predicate())return;await tick()}assert.fail('owner publisher did not retry')}
// History goes into this machine's library host through its `/v1/publisher/*`
// socket routes; `online` stands for the host answering them.
function fixture(t,{automatic=false}={}) {
  const directory=mkdtempSync(join(tmpdir(),'wm-owner-publish-')),events=new Map(),artifacts=new Map(),requests=[]
  let online=false,loseReply=false,loseRetainedReply=false,cursor=0,rejectJournal=false,rejectArtifacts=false
  const publisher=async(url,body,headers)=>{
    requests.push({url,body,headers});if(!online)throw Error('Library host offline')
    if((rejectJournal&&url.endsWith('journal'))||(rejectArtifacts&&url.startsWith('artifacts/')))throw Object.assign(Error('Unavailable'),{statusCode:503})
    let result
    if(url.endsWith('retained/settle')) {
      result={libraryID:body.libraryID,acceptedEventIDs:body.entries.map(entry=>entry.eventID),cursor:0}
      if(loseRetainedReply){loseRetainedReply=false;throw Error('Retained receipt lost')}
    } else if(url.endsWith('journal')) {
      for(const entry of body.entries){const previous=events.get(entry.eventID);if(previous)assert.deepEqual(previous,entry);else{events.set(entry.eventID,entry);cursor++}}
      result={libraryID:body.libraryID,acceptedEventIDs:body.entries.map(x=>x.eventID),cursor}
      if(loseReply){loseReply=false;throw Error('Reply lost after commit')}
    } else if(url.endsWith('artifacts/register')) {
      let item=artifacts.get(body.manifest.id)
      if(!item){item={manifest:{...body.manifest,revision:1},bytes:Buffer.alloc(0),complete:false};artifacts.set(body.manifest.id,item)}
      result={manifest:item.manifest,nextOffset:item.bytes.length,complete:item.complete}
    } else if(url.endsWith('artifacts/chunk')) {
      const item=artifacts.get(body.id);assert.equal(body.offset,item.bytes.length);item.bytes=Buffer.concat([item.bytes,Buffer.from(body.data,'base64')]);result={manifest:item.manifest,nextOffset:item.bytes.length,complete:false}
    } else if(url.endsWith('artifacts/commit')) {const item=artifacts.get(body.id);item.complete=true;result=item.manifest}
    else throw Error('Unexpected publisher capability')
    return result
  }
  const runtime={providers:async()=>[{id:'default_agent',runtimeKind:'default_agent',available:true,canStart:true}],create:async()=>({sessionID:randomUUID()}),run:async()=>{},close:async()=>{}}
  const library={available:()=>true,client:{publisher}}
  const create=()=>createClientExecution({directory,runtime,publisherIntervalMilliseconds:automatic?5:0,library})
  let service=create()
  const {enrollment,principal}=enroll(service)
  const createSession=()=>service.command({commandID:randomUUID(),deviceID:enrollment.deviceID,libraryID:enrollment.libraryID,workspaceID:enrollment.workspaceID,kind:'createSession'},principal)
  t.after(async()=>{await service.close();rmSync(directory,{recursive:true,force:true})})
  return {directory,events,artifacts,requests,enrollment,createSession,get service(){return service},set online(x){online=x},set loseReply(x){loseReply=x},set loseRetainedReply(x){loseRetainedReply=x},set rejectJournal(x){rejectJournal=x},set rejectArtifacts(x){rejectArtifacts=x},async restart(){await service.close();service=create()}}
}
test('owner executes offline and restart retries original immutable events without any observer',async t=>{
  const f=fixture(t,{automatic:true})
  const local=await f.createSession();assert.equal(local.status,'completed')
  await until(()=>f.requests.length>0);assert.equal(f.events.size,0)
  const before=f.service.events().entries;await f.restart();f.online=true
  assert.equal(f.service.publisherStatus().configured,true);assert.equal(f.service.publisherStatus().target,'local')
  await until(()=>f.events.size===before.length)
  assert.deepEqual([...f.events.values()],before)
  assert.ok(f.requests.every(x=>x.headers['x-woven-workspace-id']===f.enrollment.workspaceID))
  assert.equal(f.service.descriptor().journalDeviceIDs.length,0)
})
test('lost acknowledgement and restart re-send the same IDs then advance durable origin cursor',async t=>{
  const f=fixture(t);await f.createSession();f.online=true;f.loseReply=true
  await assert.rejects(f.service.synchronizePublisher(),/Reply lost/)
  const accepted=[...f.events.values()];await f.restart();await f.service.synchronizePublisher()
  assert.deepEqual([...f.events.values()],accepted)
  const calls=f.requests.length;await f.restart();await f.service.synchronizePublisher();assert.equal(f.requests.length,calls)
})
test('retained origin importer deduplicates immutable IDs and rejects foreign or changed entries',async t=>{
  const f=fixture(t),id=randomUUID(),conversationID=randomUUID()
  const entry={eventID:id,conversationID,kind:'conversation',conversation:{id:conversationID,title:'Retained',updatedAt:''}}
  f.service.importRetainedEvents([entry]);f.service.importRetainedEvents([entry])
  assert.equal(f.service.events().entries.length,1)
  assert.throws(()=>f.service.importRetainedEvents([{...entry,conversation:{...entry.conversation,title:'Changed'}}]),{statusCode:409})
  assert.throws(()=>f.service.importRetainedEvents([{...entry,eventID:randomUUID(),workspaceID:randomUUID()}]),{statusCode:400})
  f.online=true;await f.service.synchronizePublisher();assert.equal(f.events.size,1)
})

test('history and saved artifact failures retry independently with durable backoff and acknowledgements',async t=>{
  const f=fixture(t);await f.createSession();f.online=true;f.rejectJournal=true
  const saved=f.service.saveArtifact({title:'Output',mediaType:'text/plain',data:Buffer.from('saved')})
  await assert.rejects(f.service.synchronizePublisher(),{statusCode:503})
  assert.equal(f.artifacts.get(saved.id).complete,true);assert.equal(f.events.size,0)
  const before=f.service.publisherStatus()
  assert.equal(before.journal.failureCount,1);assert.equal(before.journal.lastErrorCode,'http_503')
  assert.equal(before.artifacts.failureCount,0);assert.ok(before.artifacts.lastSuccessAt)
  assert.equal(before.pendingArtifacts,0);assert.equal(before.acknowledgedOriginSequence,0)
  await f.restart();assert.deepEqual(f.service.publisherStatus(),before)
  await assert.rejects(f.service.synchronizePublisher(),{statusCode:503})
  assert.equal(f.service.publisherStatus().journal.failureCount,2)
  assert.ok(f.service.publisherStatus().journal.nextAttemptAt-before.journal.nextAttemptAt>=4500)
  f.rejectJournal=false;f.rejectArtifacts=true
  f.service.saveArtifact({title:'Next output',mediaType:'text/plain',data:Buffer.from('next')})
  await assert.rejects(f.service.synchronizePublisher(),{statusCode:503})
  const after=f.service.publisherStatus()
  assert.equal(after.journal.failureCount,0);assert.ok(after.journal.lastSuccessAt)
  assert.equal(after.acknowledgedOriginSequence,f.service.events().cursor)
  assert.equal(after.artifacts.failureCount,1);assert.equal(after.pendingArtifacts,1)
  assert.ok(f.events.size>0)
})

test('retained terminal preflight retries exact proofs before chronological journal publication',async t=>{
  const f=fixture(t),conversationID=randomUUID()
  const entries=[randomUUID(),randomUUID()].map(runID=>({eventID:randomUUID(),conversationID,runID,kind:'conversation',
    conversation:{id:conversationID,title:'Historical',runtimeKind:'default_agent',updatedAt:''},
    retainedExecution:{source:'default-agent-rpc',nativeSessionID:'same-native',runtimeKind:'default_agent',runID,status:'completed'}}))
  f.service.importRetainedEvents(entries);f.online=true;f.loseRetainedReply=true
  await assert.rejects(f.service.synchronizePublisher(),/Retained receipt lost/)
  assert.equal(f.events.size,0)
  const first=f.requests[0].body
  await f.restart();await f.service.synchronizePublisher()
  const proofs=f.requests.filter(request=>request.url.endsWith('retained/settle'))
  assert.equal(proofs.length,2);assert.deepEqual(proofs[1].body,first)
  assert.deepEqual([...f.events.keys()],entries.map(entry=>entry.eventID))
  const count=f.requests.length;await f.restart();await f.service.synchronizePublisher();assert.equal(f.requests.length,count)
})

// A v0.4.2 store also published to one designated Mac and kept a library MCP
// grant: opening it drops both (with that Mac's bearer) and keeps the lanes.
test('a v0.4.2 execution store loses its single-Mac publication and keeps its lanes', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'wm-v042-store-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const db = new DatabaseSync(join(directory, 'execution.sqlite'))
  db.exec(`CREATE TABLE central_publication (id INTEGER PRIMARY KEY CHECK(id=1), envelope TEXT NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0);
    INSERT INTO central_publication VALUES (1, 'sealed-bearer', 7);
    CREATE TABLE retained_publication_receipts (event_id TEXT PRIMARY KEY);
    CREATE TABLE central_publication_lanes (name TEXT PRIMARY KEY, failures INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0, last_success TEXT, last_error_code TEXT);
    INSERT INTO central_publication_lanes(name,failures) VALUES ('journal',3),('artifacts',0);
    CREATE TABLE saved_execution_artifacts (id TEXT PRIMARY KEY, manifest TEXT NOT NULL, bytes BLOB NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
    INSERT INTO saved_execution_artifacts VALUES ('artifact', '{}', x'01', 1);
    CREATE TABLE mcp_library_connection (id INTEGER PRIMARY KEY CHECK(id=1), envelope TEXT NOT NULL);
    INSERT INTO mcp_library_connection VALUES (1, 'sealed-grant');`)
  db.close()
  const runtime = { providers: async () => [], create: async () => ({ sessionID: randomUUID() }), run: async () => {}, close: async () => {} }
  const service = createClientExecution({ directory, runtime, publisherIntervalMilliseconds: 0 })
  await service.close()
  const store = new DatabaseSync(join(directory, 'execution.sqlite'))
  t.after(() => store.close())
  const tables = store.prepare("SELECT name FROM sqlite_master WHERE type='table'").all().map(row => row.name)
  for (const name of ['central_publication', 'retained_publication_receipts', 'central_publication_lanes', 'mcp_library_connection']) assert.ok(!tables.includes(name), name)
  assert.equal(store.prepare("SELECT failures FROM publication_lanes WHERE name='journal'").get().failures, 3)
  assert.deepEqual(store.prepare('PRAGMA table_info(saved_execution_artifacts)').all().map(column => column.name), ['id', 'manifest', 'bytes'])
  assert.equal(store.prepare('SELECT count(*) AS n FROM saved_execution_artifacts').get().n, 1)
})
