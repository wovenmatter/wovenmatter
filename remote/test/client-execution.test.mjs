import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, readFileSync, realpathSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createClientExecution } from '../src/client-execution.mjs'

const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject}}
const turn=()=>new Promise(resolve=>setImmediate(resolve))
function fixture(t) {
  const directory=mkdtempSync(join(tmpdir(),'wm-direct-'))
  const runs=[],calls=[]
  const runtime={providers:async()=>[{id:'default_agent',runtimeKind:'default_agent',available:true,canStart:true}],create:async()=>({sessionID:randomUUID()}),
    run:async input=>{const done=deferred();runs.push({...input,done});calls.push(input.command.commandID);await done.promise},
    stop:async({command})=>runs.find(item=>item.command.runID===command.runID)?.done.resolve(),
    respond:async()=>{},steer:async()=>{},close:async()=>{for(const run of runs)run.done.resolve()}}
  const create=()=>createClientExecution({directory,runtime})
  let service=create()
  const enrollment={libraryID:randomUUID(),workspaceID:randomUUID(),ownerDeviceID:randomUUID(),deviceID:randomUUID(),scopes:['execution'],endpoint:'https://machine.tail.ts.net:8443/wovenmatter-execution/test'}
  const grant=service.provision(enrollment),principal=service.principal('Bearer '+grant.token,'execution')
  const command=(kind,values={})=>({commandID:randomUUID(),deviceID:enrollment.deviceID,libraryID:enrollment.libraryID,workspaceID:enrollment.workspaceID,kind,...values})
  t.after(async()=>{await service.close();rmSync(directory,{recursive:true,force:true})})
  return {directory,runs,calls,runtime,enrollment,grant,principal,command,get service(){return service},async restart(){await service.close();service=create()},create}
}

test('per-device bearer grants never expose administration or another device receipts',async t=>{
  const f=fixture(t)
  assert.equal(f.service.principal('Bearer '+f.grant.token,'inference'),null)
  assert.equal(f.service.principal('Bearer wrong','execution'),null)
  const command=f.command('createSession'),receipt=await f.service.command(command,f.principal)
  assert.equal(receipt.status,'completed')
  assert.throws(()=>f.service.receipt(command.commandID,randomUUID()),{statusCode:404})
  assert.equal(readFileSync(join(f.directory,'execution.sqlite')).includes(Buffer.from(f.grant.token)),false)
  f.service.revoke(f.enrollment.deviceID)
  assert.equal(f.service.principal('Bearer '+f.grant.token,'execution'),null)
})

test('concurrent retransmission has one execution and changed-payload retries fail',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  const input=f.command('send',{conversationID:opened.conversationID,text:'hello'})
  const receipts=await Promise.all([f.service.command(input,f.principal),f.service.command(input,f.principal)])
  await turn()
  assert.equal(f.calls.length,1)
  assert.equal(receipts[0].commandID,receipts[1].commandID)
  await assert.rejects(f.service.command({...input,text:'different'},f.principal),{statusCode:409})
  f.runs[0].publish({sessionUpdate:'agent_message_chunk',content:{text:'answer'}})
  f.runs[0].done.resolve();await turn()
  assert.equal(f.service.receipt(input.commandID,f.enrollment.deviceID).status,'completed')
  const page=f.service.events()
  assert.ok(page.entries.some(item=>item.kind==='nativeRecord'))
  assert.ok(page.entries.some(item=>item.transcript?.messages.some(message=>message.content==='answer')))
  assert.equal(new Set(page.entries.map(item=>item.eventID)).size,page.entries.length)
  assert.deepEqual(page.entries.map(item=>item.originSequence),page.entries.map((_,index)=>index+1))
  await f.restart()
  assert.equal((await f.service.command(input,f.principal)).status,'completed')
  assert.equal(f.calls.length,1)
})

test('stale stop, old response and reused run identity cannot affect a newer run',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  const first=await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'first'}),f.principal)
  await turn();f.runs[0].done.resolve();await turn()
  const second=await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'second'}),f.principal)
  await turn()
  assert.equal((await f.service.command(f.command('stop',{conversationID:opened.conversationID,runID:first.runID}),f.principal)).status,'rejected')
  assert.equal(f.service.transcript(opened.conversationID).activeRunID,second.runID)
  await f.service.command(f.command('stop',{conversationID:opened.conversationID,runID:second.runID}),f.principal);await turn()
  assert.equal((await f.service.command(f.command('send',{conversationID:opened.conversationID,runID:first.runID,text:'reuse'}),f.principal)).status,'rejected')
})

test('large native output retains complete history in bounded transport entries',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'work'}),f.principal);await turn()
  const content='x'+'🙂'.repeat(250000)
  f.runs[0].publish({sessionUpdate:'agent_message_chunk',content:{text:content}})
  f.runs[0].done.resolve();await turn()
  let cursor=0,entries=[]
  for(;;){const page=f.service.events(cursor);entries.push(...page.entries);cursor=page.cursor;if(!page.hasMore)break}
  assert.ok(entries.every(item=>Buffer.byteLength(JSON.stringify(item))<1024*1024))
  assert.ok(entries.flatMap(item=>item.transcript?.messages??[]).every(message=>message.content.isWellFormed()))
  const parts=entries.filter(item=>item.nativeRecord).map(item=>item.nativeRecord).sort((a,b)=>a.partIndex-b.partIndex)
  const update=JSON.parse(Buffer.concat(parts.map(part=>Buffer.from(part.data,'base64'))))
  assert.equal(update.content.text,content)
  let before, messages=[]
  do {const page=f.service.transcript(opened.conversationID,before);messages=[...page.messages,...messages];before=page.olderCursor}while(before)
  assert.equal(messages.filter(message=>message.role==='assistant').map(message=>message.content).join(''),content)
})

test('restart fences accepted unfinished commands without executing them again',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  const input=f.command('send',{conversationID:opened.conversationID,text:'once'})
  await f.service.command(input,f.principal);await turn()
  f.runs[0].publish({sessionUpdate:'tool_call',toolCallId:'running-tool',title:'Read',status:'running'})
  await f.restart()
  assert.equal(f.service.receipt(input.commandID,f.enrollment.deviceID).status,'outcomeUnknown')
  assert.equal((await f.service.command(input,f.principal)).status,'outcomeUnknown')
  assert.equal(f.calls.length,1)
  assert.equal(f.service.transcript(opened.conversationID).activities[0].status,'interrupted')
  assert.equal(f.service.transcript(opened.conversationID).activeRunID,undefined)
})

test('device vault grants survive restart encrypted and remain token and identity bound',async t=>{
  const f=fixture(t),material={workspace:'private-workspace-scope',unlockKey:'test-only-very-private-unlock-material'}
  f.service.rememberUnlockMaterial(material)
  const grant=f.service.provision(f.enrollment)
  assert.deepEqual(f.service.unlockMaterial('Bearer '+grant.token),material)
  assert.equal(f.service.unlockMaterial('Bearer wrong'),null)
  await f.restart()
  assert.deepEqual(f.service.unlockMaterial('Bearer '+grant.token),material)
  const {DatabaseSync}=await import('node:sqlite')
  const db=new DatabaseSync(join(f.directory,'execution.sqlite'))
  const row=db.prepare('SELECT body FROM devices WHERE id=?').get(f.enrollment.deviceID)
  const body=JSON.parse(row.body)
  assert.equal(row.body.includes(material.unlockKey),false)
  body.unlockEnvelope.tag=Buffer.alloc(16).toString('base64')
  db.prepare('UPDATE devices SET body=? WHERE id=?').run(JSON.stringify(body),f.enrollment.deviceID)
  assert.throws(()=>f.service.unlockMaterial('Bearer '+grant.token),{statusCode:403})
  db.close()
  f.service.revoke(f.enrollment.deviceID)
  assert.equal(f.service.unlockMaterial('Bearer '+grant.token),null)
  for(const suffix of ['', '-wal']) {
    let bytes;try{bytes=readFileSync(join(f.directory,'execution.sqlite'+suffix))}catch{continue}
    assert.equal(bytes.includes(Buffer.from(material.unlockKey)),false)
    assert.equal(bytes.includes(Buffer.from(grant.token)),false)
  }
})

test('native adoption has one conversation owner and retries preserve an active run',async t=>{
  const f=fixture(t),id=randomUUID(),sessionID='existing-native',gate=deferred()
  let calls=0
  f.runtime.adopt=async({native})=>{calls++;await gate.promise;return native}
  const body={workspaceID:f.enrollment.workspaceID,conversation:{id,title:'Existing',preview:'',updatedAt:'',runtimeKind:'default_agent'},runtimeKind:'default_agent',nativeSessionID:sessionID,knownRunIDs:[randomUUID()]}
  const first=f.service.adopt(body),duplicateOwner=f.service.adopt({...body,conversation:{...body.conversation,id:randomUUID()}})
  const rejected=assert.rejects(duplicateOwner,/another conversation/)
  gate.resolve();await first;await rejected
  assert.equal(calls,1)
  const input=await f.service.command(f.command('send',{conversationID:id,text:'still running'}),f.principal)
  await turn()
  const repeated=await f.service.adopt(body)
  assert.equal(repeated.activeRunID,input.runID)
  assert.equal(calls,1)
  assert.equal(f.service.transcript(id).messages.at(-1).status,'running')
})

test('interaction response never overwrites streaming or completion while awaiting native acknowledgement',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  const sent=await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'work'}),f.principal)
  await turn()
  f.runs[0].interaction({id:'permission-1',kind:'approval',title:'Allow tool?',options:[{id:'once',label:'Allow'}],questions:[]})
  const ack=deferred();f.runtime.respond=async()=>{await ack.promise}
  const responding=f.service.command(f.command('respond',{conversationID:opened.conversationID,runID:sent.runID,interactionID:'permission-1',response:{optionID:'once',answers:{},cancelled:false}}),f.principal)
  await turn();f.runs[0].publish({sessionUpdate:'agent_message_chunk',content:{text:'finished'}});f.runs[0].done.resolve();await turn()
  ack.resolve();await responding
  const transcript=f.service.transcript(opened.conversationID)
  assert.equal(transcript.activeRunID,undefined)
  assert.equal(transcript.messages.at(-1).content,'finished')
  assert.equal(transcript.messages.at(-1).status,'completed')
})

test('client provider selection determines the exact native runtime and rejects invalid routes',async t=>{
  const f=fixture(t),created=[]
  f.runtime.providers=async()=>[{id:'default_agent',runtimeKind:'default_agent',available:true,canStart:true},
    {id:'codex',runtimeKind:'codex',available:true,canStart:true},{id:'disabled',runtimeKind:'pi',available:false,canStart:false}]
  f.runtime.create=async request=>{created.push(request);return {sessionID:randomUUID()}}
  // This is the providerID-only shape emitted by both the iOS and Mac clients.
  const opened=await f.service.command(f.command('createSession',{providerID:'codex'}),f.principal)
  assert.equal(opened.status,'completed')
  assert.equal(created[0].runtimeKind,'codex')
  assert.equal(f.service.conversations()[0].runtimeKind,'codex')
  for(const route of [{providerID:'unknown'},{providerID:'disabled'},{providerID:'codex',runtimeKind:'default_agent'}]) {
    const rejected=await f.service.command(f.command('createSession',route),f.principal)
    assert.equal(rejected.status,'rejected')
  }
  assert.equal(created.length,1)
});

test('transcript pagination retains all tool activity even when there are few messages',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'work'}),f.principal);await turn()
  for(let index=0;index<95;index++)f.runs[0].publish({sessionUpdate:'tool_call',toolCallId:String(index),title:'Tool '+index,status:'completed',content:[{text:'Result '+index}]})
  f.runs[0].done.resolve();await turn()
  let before,messages=[],activities=[]
  do {
    const page=f.service.transcript(opened.conversationID,before)
    assert.ok(page.messages.length<=40 && page.activities.length<=40)
    messages=[...page.messages,...messages];activities=[...page.activities,...activities];before=page.olderCursor
  } while(before)
  assert.equal(messages.length,2)
  assert.deepEqual(activities.map(item=>item.detail),Array.from({length:95},(_,i)=>'Result '+i))
  assert.equal(new Set(activities.map(item=>item.id)).size,95)
  assert.throws(()=>f.service.transcript(opened.conversationID,'invalid'),{statusCode:400})
});

test('identical native chunks keep distinct journal record identities within and across runs',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  for(let index=0;index<2;index++) {
    await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'again'}),f.principal);await turn()
    for(let chunk=0;chunk<2;chunk++)f.runs[index].publish({sessionUpdate:'agent_message_chunk',content:{text:'identical'}})
    f.runs[index].done.resolve();await turn()
  }
  const records=f.service.events().entries.flatMap(entry=>entry.nativeRecord?[entry.nativeRecord]:[])
  assert.equal(records.length,4)
  assert.equal(new Set(records.map(record=>record.recordID)).size,4)
  assert.equal(new Set(records.map(record=>record.sha256)).size,1)
})

test('tool and thinking activities remain scoped to each run and settle with it',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  for(let index=0;index<2;index++) {
    await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'work'}),f.principal);await turn()
    f.runs[index].publish({sessionUpdate:'agent_thought_chunk',content:{text:'Thinking '+index},_meta:{wovenThoughtID:'reused-native-id'}})
    f.runs[index].publish({sessionUpdate:'tool_call',toolCallId:'reused-tool',title:'Read',status:'running'})
    f.runs[index].done.resolve();await turn()
  }
  const activities=f.service.transcript(opened.conversationID).activities
  assert.equal(activities.length,4)
  assert.equal(new Set(activities.map(item=>item.id)).size,4)
  assert.ok(activities.every(item=>item.status==='completed'))
  assert.deepEqual(activities.filter(item=>item.title==='Thinking').map(item=>item.detail),['Thinking 0','Thinking 1'])
})

test('workspace edits and live buffered output become durable before a turn finishes and survive restart', { timeout: 5000 }, async t => {
  const f = fixture(t)
  const opened = await f.service.command(f.command('createSession'), f.principal)
  const conversationID = opened.conversationID, folderID = randomUUID()
  for (const action of [{ action: 'move', folderID }, { action: 'pin' }]) {
    const input = f.command('workspace', { conversationID, workspaceAction: { conversation: { id: conversationID, ...action } } })
    assert.equal((await f.service.command(input, f.principal)).status, 'completed')
    assert.equal((await f.service.command(input, f.principal)).status, 'completed')
  }
  const input = f.command('send', { conversationID, text: 'keep this exact input' })
  await f.service.command(input, f.principal); await turn()
  const cursor = f.service.events().cursor
  f.runs[0].publish({ sessionUpdate: 'agent_message_chunk', content: { text: 'buffered 🌱 output' } })
  const deadline = Date.now() + 3000
  let journal
  do {
    journal = f.service.events(cursor)
    if (journal.entries.some(entry => entry.transcript?.messages.some(message => message.content === 'buffered 🌱 output'))) break
    await new Promise(resolve => setTimeout(resolve, 10))
  } while (Date.now() < deadline)
  assert.ok(journal.entries.some(entry => entry.transcript?.messages.some(message => message.content === 'buffered 🌱 output')), 'live output must publish while the native turn is still running')
  assert.equal(f.service.transcript(conversationID).activeRunID, f.runs[0].command.runID)
  const busyRename = f.command('workspace', { conversationID, workspaceAction: { conversation: { id: conversationID, action: 'rename', title: 'Café 🌱' } } })
  assert.equal((await f.service.command(busyRename, f.principal)).status, 'rejected')
  assert.equal(f.service.conversations().find(value => value.id === conversationID).title, input.text)
  f.runs[0].done.resolve(); await turn()
  assert.equal((await f.service.command(busyRename, f.principal)).status, 'rejected', 'a failed request receipt cannot silently acquire authority after the turn ends')
  const rename = { ...busyRename, commandID: randomUUID() }
  assert.equal((await f.service.command(rename, f.principal)).status, 'completed')
  assert.equal((await f.service.command(rename, f.principal)).status, 'completed')
  await f.restart()
  const conversation = f.service.conversations().find(value => value.id === conversationID)
  assert.equal(conversation.title, 'Café 🌱')
  assert.equal(conversation.folderID, folderID)
  assert.equal(conversation.isPinned, true)
  assert.deepEqual(f.service.transcript(conversationID).messages.map(message => message.content), [input.text, 'buffered 🌱 output'])
  assert.equal((await f.service.command(input, f.principal)).status, 'completed')
  assert.equal(f.calls.length, 1)
})

test('direct execution assembles replacement frames atomically and preserves completed text on interruption',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'work'}),f.principal);await turn()
  const publish=f.runs[0].publish,content=()=>f.service.transcript(opened.conversationID).messages.filter(x=>x.role==='assistant').map(x=>x.content).join('')
  const frame=(text,start,end)=>({sessionUpdate:'agent_message_chunk',content:{text},_meta:{wovenAssistantSnapshot:true,wovenSnapshotStart:start,wovenSnapshotEnd:end}})
  publish({sessionUpdate:'agent_message_chunk',content:{text:'previous'}})
  publish(frame('new ',true,false));assert.equal(content(),'previous')
  publish(frame('🧵',false,true));assert.equal(content(),'new 🧵')
  publish({sessionUpdate:'agent_message_chunk',content:{text:' suffix'}});assert.equal(content(),'new 🧵 suffix')
  publish(frame('',true,true));assert.equal(content(),'')
  publish({sessionUpdate:'agent_message_chunk',content:{text:'retained'}})
  publish(frame('unfinished',true,false));f.runs[0].done.resolve();await turn()
  assert.equal(content(),'retained')
})

test('direct reasoning frames keep separate thought identities and publish only complete replacements',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'work'}),f.principal);await turn()
  const publish=(id,text,start,end)=>f.runs[0].publish({sessionUpdate:'agent_thought_chunk',content:{text},_meta:{wovenThoughtID:id,wovenThoughtSnapshot:true,wovenSnapshotStart:start,wovenSnapshotEnd:end}})
  publish('one','First ',true,false);publish('two','Second',true,true)
  assert.deepEqual(f.service.transcript(opened.conversationID).activities.map(x=>x.detail),['Second'])
  publish('one','thought',false,true)
  assert.deepEqual(f.service.transcript(opened.conversationID).activities.map(x=>x.detail),['Second','First thought'])
})

test('reasoning disclosure retains complete chunked text while snapshots stay bounded',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'reason'}),f.principal);await turn()
  const thought=(text,snapshot=false)=>({sessionUpdate:'agent_thought_chunk',content:{text},_meta:{wovenThoughtID:'trace',wovenThoughtSnapshot:snapshot}})
  const original=thought('🧵'.repeat(80000),true),tail=thought(' tail beyond every preview')
  f.runs[0].publish(original);f.runs[0].publish(tail)
  f.runs[0].done.resolve();await turn()
  const row=()=>f.service.transcript(opened.conversationID).activities[0]
  assert.ok(row().detail.length<=2048);assert.ok(row().projectionJSON.length<5000)
  const recordID=row().detailsRecordID,all=[]
  for(let after=0;;){const page=f.service.events(after);all.push(...page.entries);if(!page.hasMore)break;after=page.cursor}
  const chunks=all.filter(item=>item.nativeRecord?.recordID===recordID).map(item=>item.nativeRecord).sort((a,b)=>a.partIndex-b.partIndex)
  assert.ok(chunks.length>=3)
  const complete=JSON.parse(Buffer.concat(chunks.map(item=>Buffer.from(item.data,'base64'))))
  assert.equal(complete.activity.kind,'thought');assert.equal(complete.activity.content,original.content.text+tail.content.text)
  const raw=all.filter(item=>item.nativeRecord?.format==='woven-native-update-v1'),groups=new Map()
  for(const item of raw){const part=item.nativeRecord,values=groups.get(part.recordID)??[];values[part.partIndex]=Buffer.from(part.data,'base64');groups.set(part.recordID,values)}
  assert.deepEqual([...groups.values()].map(parts=>JSON.parse(Buffer.concat(parts))),[original,tail])
  await f.restart()
  assert.equal(row().detailsRecordID,recordID)
})

test('reasoning corrections and empty clear retire old detail pointers',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'reason'}),f.principal);await turn()
  const publish=(text,snapshot)=>f.runs[0].publish({sessionUpdate:'agent_thought_chunk',content:{text},_meta:{wovenThoughtID:'trace',wovenThoughtSnapshot:snapshot}})
  const row=()=>f.service.transcript(opened.conversationID).activities[0]
  publish('x'.repeat(20000),true);assert.ok(row().detailsRecordID)
  publish('corrected',true);assert.equal(row().detailsRecordID,undefined);assert.equal(JSON.parse(row().projectionJSON).content,'corrected')
  publish('',true);assert.equal(row().detail,'');assert.equal(JSON.parse(row().projectionJSON).content,'')
  publish('new',false);assert.equal(JSON.parse(row().projectionJSON).content,'new')
})

for(const terminal of ['completed','failed','cancelled'])test(`rapid dirty flushes coalesce reasoning and ${terminal} preserves the last suffix`,async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal)
  await f.service.command(f.command('send',{conversationID:opened.conversationID,text:'reason'}),f.principal);await turn()
  t.mock.method(Date,'now',()=>1000)
  t.mock.timers.enable({apis:['setTimeout']})
  const text='x'.repeat(20000),publish=value=>f.runs[0].publish({sessionUpdate:'agent_thought_chunk',content:{text:value},_meta:{wovenThoughtID:'trace'}})
  publish(text)
  for(let i=0;i<20;i++){publish(' suffix');t.mock.timers.tick(500)}
  assert.equal(new Set(f.service.events().entries.filter(item=>item.nativeRecord?.format==='wovenmatter.activity.v2').map(item=>item.nativeRecord.recordID)).size,1)
  if(terminal==='failed')f.runs[0].done.reject(new Error('fixture failure'))
  else if(terminal==='cancelled')await f.service.command(f.command('stop',{conversationID:opened.conversationID,runID:f.runs[0].command.runID}),f.principal)
  else f.runs[0].done.resolve()
  await turn()
  const row=f.service.transcript(opened.conversationID).activities[0],parts=f.service.events().entries.filter(item=>item.nativeRecord?.recordID===row.detailsRecordID).map(item=>item.nativeRecord)
  assert.equal(row.status,terminal)
  assert.equal(JSON.parse(Buffer.concat(parts.map(part=>Buffer.from(part.data,'base64')))).activity.content,text+' suffix'.repeat(20))
})


test('device-owned folder requests survive a lost reply and restart and set the native root without central access', async t => {
  const f = fixture(t), id = randomUUID()
  let directory
  f.runtime.create = async input => { directory = input.nativeWorkingDirectory; return { sessionID: randomUUID() } }
  const request = { operationID: randomUUID(), deviceID: f.enrollment.deviceID, kind: 'createFolder', resourceID: id, title: 'Phone project' }
  const [first, retry] = await Promise.all([f.service.createFolder(request, f.principal), f.service.createFolder(request, f.principal)])
  assert.deepEqual(first, retry)
  assert.equal(first.execution.workspaceID, f.enrollment.workspaceID)
  assert.ok(first.execution.rootPath.startsWith(realpathSync(f.directory) + '/projects/'))
  assert.deepEqual(f.service.folders(), [first])
  await assert.rejects(f.service.createFolder({ ...request, title: 'Changed payload' }, f.principal), { statusCode: 409 })
  await assert.rejects(f.service.createFolder({ ...request, operationID: randomUUID(), resourceID: randomUUID(), folderExecution: { workspaceID: randomUUID(), rootPath: '/tmp' } }, f.principal), { statusCode: 400 })
  await f.restart()
  assert.deepEqual(await f.service.createFolder(request, f.principal), first)
  const opened = await f.service.command(f.command('createSession', { folderID: id }), f.principal)
  assert.equal(opened.status, 'completed')
  assert.equal(directory, first.execution.rootPath)
  const missing = await f.service.command(f.command('createSession', { folderID: randomUUID() }), f.principal)
  assert.equal(missing.status, 'rejected')
  assert.equal(f.service.conversations().length, 1)
})
