import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createClientExecution } from '../src/client-execution.mjs'
const tick=()=>new Promise(resolve=>setTimeout(resolve,5))
async function until(predicate){for(let n=0;n<200;n++){if(predicate())return;await tick()}assert.fail('owner publisher did not retry')}
function fixture(t,{automatic=false}={}) {
  const directory=mkdtempSync(join(tmpdir(),'wm-owner-publish-')),events=new Map(),artifacts=new Map(),requests=[]
  let online=false,loseReply=false,loseRetainedReply=false,cursor=0,rejectJournal=false,rejectArtifacts=false
  const token='publisher-token-'+randomUUID(),secret='existing-admin-'+randomUUID()
  const fetchImpl=async(url,options)=>{
    requests.push({url,options});if(!online)throw Error('Central offline')
    assert.equal(options.redirect,'error');assert.equal(options.headers.authorization,'Bearer '+token)
    if((rejectJournal&&url.endsWith('/journal'))||(rejectArtifacts&&url.includes('/artifacts/')))return {ok:false,status:503}
    const body=JSON.parse(options.body);let result
    if(url.endsWith('/retained/settle')) {
      result={libraryID:body.libraryID,acceptedEventIDs:body.entries.map(entry=>entry.eventID),cursor:0}
      if(loseRetainedReply){loseRetainedReply=false;throw Error('Retained receipt lost')}
    } else if(url.endsWith('/journal')) {
      for(const entry of body.entries){const previous=events.get(entry.eventID);if(previous)assert.deepEqual(previous,entry);else{events.set(entry.eventID,entry);cursor++}}
      result={libraryID:body.libraryID,acceptedEventIDs:body.entries.map(x=>x.eventID),cursor}
      if(loseReply){loseReply=false;throw Error('Reply lost after commit')}
    } else if(url.endsWith('/artifacts/register')) {
      let item=artifacts.get(body.manifest.id)
      if(!item){item={manifest:{...body.manifest,revision:1},bytes:Buffer.alloc(0),complete:false};artifacts.set(body.manifest.id,item)}
      result={manifest:item.manifest,nextOffset:item.bytes.length,complete:item.complete}
    } else if(url.endsWith('/artifacts/chunk')) {
      const item=artifacts.get(body.id);assert.equal(body.offset,item.bytes.length);item.bytes=Buffer.concat([item.bytes,Buffer.from(body.data,'base64')]);result={manifest:item.manifest,nextOffset:item.bytes.length,complete:false}
    } else if(url.endsWith('/artifacts/commit')) {const item=artifacts.get(body.id);item.complete=true;result=item.manifest}
    else throw Error('Unexpected publisher capability')
    return {ok:true,status:200,json:async()=>result}
  }
  const runtime={providers:async()=>[{id:'default_agent',runtimeKind:'default_agent',available:true,canStart:true}],create:async()=>({sessionID:randomUUID()}),run:async()=>{},close:async()=>{}}
  const create=()=>createClientExecution({directory,runtime,publisherKey:secret,publisherFetch:fetchImpl,publisherIntervalMilliseconds:automatic?5:0})
  let service=create()
  const enrollment={libraryID:randomUUID(),workspaceID:randomUUID(),ownerDeviceID:randomUUID(),deviceID:randomUUID(),scopes:['execution']}
  const client=service.provision(enrollment),principal=service.principal('Bearer '+client.token,'execution')
  const grant={grantID:randomUUID(),libraryID:enrollment.libraryID,workspaceID:enrollment.workspaceID,executionDeviceID:client.workspace.executionDeviceID,endpoint:'https://central.tail.ts.net/wovenmatter',token}
  service.configurePublisher(grant)
  const createSession=()=>service.command({commandID:randomUUID(),deviceID:enrollment.deviceID,libraryID:enrollment.libraryID,workspaceID:enrollment.workspaceID,kind:'createSession'},principal)
  t.after(async()=>{await service.close();rmSync(directory,{recursive:true,force:true})})
  return {directory,events,artifacts,requests,grant,createSession,get service(){return service},set online(x){online=x},set loseReply(x){loseReply=x},set loseRetainedReply(x){loseRetainedReply=x},set rejectJournal(x){rejectJournal=x},set rejectArtifacts(x){rejectArtifacts=x},async restart(){await service.close();service=create()}}
}
test('owner executes offline and restart retries original immutable events without any observer',async t=>{
  const f=fixture(t,{automatic:true});const local=await f.createSession();assert.equal(local.status,'completed')
  await until(()=>f.requests.length>0);assert.equal(f.events.size,0)
  const before=f.service.events().entries;await f.restart();f.online=true
  await until(()=>f.events.size===before.length)
  assert.deepEqual([...f.events.values()],before)
  assert.ok(f.requests.every(x=>x.url.includes('/v1/federation/publisher/')))
  assert.equal(f.service.descriptor().journalDeviceIDs.length,0)
})
test('lost acknowledgement and restart re-send the same IDs then advance durable origin cursor',async t=>{
  const f=fixture(t);await f.createSession();f.online=true;f.loseReply=true
  await assert.rejects(f.service.synchronizePublisher(),/Reply lost/)
  const accepted=[...f.events.values()];await f.restart();await f.service.synchronizePublisher()
  assert.deepEqual([...f.events.values()],accepted)
  const calls=f.requests.length;await f.restart();await f.service.synchronizePublisher();assert.equal(f.requests.length,calls)
})
test('publisher grants are encrypted on disk and bound to workspace execution identity',async t=>{
  const f=fixture(t)
  assert.throws(()=>f.service.configurePublisher({...f.grant,workspaceID:randomUUID()}),{statusCode:400})
  assert.throws(()=>f.service.configurePublisher({...f.grant,executionDeviceID:randomUUID()}),{statusCode:400})
  assert.throws(()=>f.service.configurePublisher({...f.grant,endpoint:'https://example.com'}),{statusCode:400})
  for(const suffix of ['', '-wal']){let data;try{data=readFileSync(join(f.directory,'execution.sqlite'+suffix))}catch{continue};assert.equal(data.includes(Buffer.from(f.grant.token)),false)}
  await f.restart();assert.equal(f.service.publisherStatus().configured,true);assert.equal(f.service.publisherStatus().grantID,f.grant.grantID)
})
test('explicit saved artifacts self-publish while ordinary workspace files are never scanned',async t=>{
  const f=fixture(t),data=Buffer.alloc(1048576+30,7)
  const saved=f.service.saveArtifact({title:'Saved output',mediaType:'application/octet-stream',data})
  await f.restart();f.online=true;await f.service.synchronizePublisher()
  assert.deepEqual(f.artifacts.get(saved.id).bytes,data);assert.equal(f.artifacts.get(saved.id).complete,true)
  const count=f.requests.length;await f.service.synchronizePublisher();assert.equal(f.requests.length,count)
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
test('automatic attempts respect persisted backoff after restart',async t=>{
  const f=fixture(t);await f.createSession();f.online=true;f.rejectJournal=true
  for(let n=0;n<15;n++)await assert.rejects(f.service.synchronizePublisher())
  const status=f.service.publisherStatus();assert.equal(status.journal.failureCount,15)
  assert.ok(status.journal.nextAttemptAt-Date.now()>290000)
  assert.ok(status.journal.nextAttemptAt-Date.now()<=300000)
  await f.restart();const calls=f.requests.length
  await f.service.synchronizePublisher({automatic:true})
  assert.equal(f.requests.length,calls)
  f.service.configurePublisher(f.grant)
  assert.equal(f.service.publisherStatus().journal.failureCount,0)
  assert.equal(f.service.publisherStatus().journal.nextAttemptAt,0)
})

test('retained terminal preflight retries exact proofs before chronological journal publication',async t=>{
  const f=fixture(t),conversationID=randomUUID()
  const entries=[randomUUID(),randomUUID()].map(runID=>({eventID:randomUUID(),conversationID,runID,kind:'conversation',
    conversation:{id:conversationID,title:'Historical',runtimeKind:'default_agent',updatedAt:''},
    retainedExecution:{source:'default-agent-rpc',nativeSessionID:'same-native',runtimeKind:'default_agent',runID,status:'completed'}}))
  f.service.importRetainedEvents(entries);f.online=true;f.loseRetainedReply=true
  await assert.rejects(f.service.synchronizePublisher(),/Retained receipt lost/)
  assert.equal(f.events.size,0)
  const first=JSON.parse(f.requests[0].options.body)
  await f.restart();await f.service.synchronizePublisher()
  const proofs=f.requests.filter(request=>request.url.endsWith('/retained/settle'))
  assert.equal(proofs.length,2);assert.deepEqual(JSON.parse(proofs[1].options.body),first)
  assert.deepEqual([...f.events.keys()],entries.map(entry=>entry.eventID))
  const count=f.requests.length;await f.restart();await f.service.synchronizePublisher();assert.equal(f.requests.length,count)
})
