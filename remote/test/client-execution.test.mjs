import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createClientExecution } from '../src/client-execution.mjs'

const deferred=()=>{let resolve,reject;const promise=new Promise((a,b)=>{resolve=a;reject=b});return {promise,resolve,reject}}
const turn=()=>new Promise(resolve=>setImmediate(resolve))
function fixture(t) {
  const directory=mkdtempSync(join(tmpdir(),'wm-direct-'))
  const runs=[],calls=[]
  const runtime={providers:async()=>[],create:async()=>({sessionID:randomUUID()}),
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

test('workspace enrollment refuses a different library and noncanonical identities',async t=>{
  const f=fixture(t)
  assert.throws(()=>f.service.provision({...f.enrollment,libraryID:randomUUID()}),{statusCode:409})
  await assert.rejects(f.service.command(f.command('createSession',{commandID:'not-a-uuid'}),f.principal),{statusCode:400})
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
