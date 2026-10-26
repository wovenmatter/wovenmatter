import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync,rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createClientExecution } from '../src/client-execution.mjs'

const turn=()=>new Promise(resolve=>setImmediate(resolve))
async function fixture(t,{kind='opencode',sourcePermission='ask',destinationPermission='allow',permissionOptions=['ask','allow']}={}) {
  const directory=mkdtempSync(join(tmpdir(),'woven-mcp-orchestration-')),created=[],runs=[],selections=new Map()
  const runtime={providers:async()=>[...new Set([kind,'default_agent','codex'])].map(id=>({id,runtimeKind:id,available:true})),
    create:async input=>{created.push(input);const sessionID=randomUUID();selections.set(sessionID,{permission:created.length===1?sourcePermission:destinationPermission,permissions:permissionOptions.map(id=>({id}))});return {sessionID,nativeWorkingDirectory:input.nativeWorkingDirectory??directory}},
    settings:async({native})=>selections.get(native.sessionID),configure:async({native,options})=>Object.assign(selections.get(native.sessionID),options),capabilities:async()=>({canSteer:false}),
    run:async input=>{let end;const promise=new Promise(resolve=>end=resolve);runs.push({...input,end});await promise},
    close:async()=>{for(const run of runs)run.end()}}
  const service=createClientExecution({directory,runtime,publisherKey:'owner'.repeat(10),publisherIntervalMilliseconds:0})
  const enrollment=service.provision({libraryID:randomUUID(),workspaceID:randomUUID(),ownerDeviceID:randomUUID(),deviceID:randomUUID(),scopes:['execution']})
  const principal=service.principal('Bearer '+enrollment.token,'execution')
  const command=(kind,values={})=>service.command({commandID:randomUUID(),deviceID:principal.id,kind,...values},principal)
  const source=(await command('createSession',{providerID:kind})).conversationID,connection=service.mcp.sessionConnection(source),scope=service.mcp.resolvePrincipal('Bearer '+connection.bearerToken)
  const call=(name,input={},caller=scope)=>service.mcp.handle(caller,{jsonrpc:'2.0',id:randomUUID(),method:'tools/call',params:{name,arguments:{requestID:randomUUID(),...input}}})
  t.after(async()=>{await service.close();rmSync(directory,{recursive:true,force:true})})
  return {directory,service,source,scope,command,call,created,runs,selections}
}

test('Linux MCP creates source-owned children once, applies destination defaults within the permission ceiling, and enforces fanout',async t=>{
  const f=await fixture(t)
  f.service.mcp.configureSettings({enabledByDefault:['notes','history','sessions'],maximumManagedSessions:1,maximumRunningSessions:3,
    harnessDefaults:{opencode:{model:'destination-model',thinking:'high',permission:'allow',tools:[]}}})
  const input={title:'Investigate',text:'Inspect the fixture',purpose:'Research the issue',requestID:randomUUID()}
  const first=await f.call('woven_sessions_create',input);assert.equal(first.result.isError,false)
  await turn()
  const value=first.result.structuredContent.result,child=value.session
  assert.equal(child.workspaceID,f.service.descriptor().id);assert.equal(child.runtimeKind,'opencode')
  assert.equal(f.created.length,2);assert.equal(f.created[1].nativeWorkingDirectory,f.directory)
  assert.equal(f.runs.length,1);assert.equal(f.runs[0].command.conversationID,child.id)
  assert.equal(f.selections.get(f.runs[0].native.sessionID).permission,'ask')
  assert.equal(f.selections.get(f.runs[0].native.sessionID).model,'destination-model')
  const childSettings=(await f.service.readWorkspace({session:{id:child.id}})).session._0
  assert.deepEqual(childSettings.enabledTools,['goals'])
  assert.equal(value.relationship.coordinatorID,f.source)
  assert.equal((await f.call('woven_sessions_create',input)).result.structuredContent.result.session.id,child.id)
  assert.equal(f.created.length,2);assert.equal(f.runs.length,1)
  const fanout=await f.call('woven_sessions_create',{...input,requestID:randomUUID()})
  assert.equal(fanout.result.isError,true);assert.match(fanout.result.content[0].text,/managed-session limit/)
  const escalation=await f.call('woven_sessions_create',{...input,requestID:randomUUID(),permission:'allow'})
  assert.equal(escalation.error.code,-32602)
  await assert.rejects(f.command('send',{conversationID:f.source,text:'Forged message',agentSourceID:child.id}),/provenance/)
})

test('queued cross-session messages wait for idle, management epochs fence stale release, and completion wakes the coordinator',async t=>{
  const f=await fixture(t)
  const first=await f.call('woven_sessions_create',{title:'Worker',text:'First task',purpose:'Test coordination'})
  const value=first.result.structuredContent.result,child=value.session.id
  await turn();assert.equal(f.runs.length,1)
  const sent=await f.call('woven_sessions_send',{id:child,text:'Follow-up'})
  assert.equal(sent.result.structuredContent.result.receipt.status,'queued')
  f.runs[0].end();await turn();await turn()
  assert.ok(f.runs.some(run=>run.command.conversationID===child&&run.command.text.startsWith('Follow-up')))
  assert.ok(f.runs.some(run=>run.command.conversationID===f.source&&run.command.text.includes('finished a turn')))
  const stale=await f.call('woven_sessions_release',{id:child,epoch:randomUUID()})
  assert.equal(stale.result.isError,true)
  const released=await f.call('woven_sessions_release',{id:child,epoch:value.relationship.coordinationEpoch})
  assert.equal(released.result.isError,false);assert.equal(released.result.structuredContent.result.coordinatorID,undefined)
})

test('Pi Durable full permission is recognized for source-owned delegation',async t=>{
  const f=await fixture(t,{kind:'default_agent',sourcePermission:'full',destinationPermission:'full',permissionOptions:['full']})
  const reply=await f.call('woven_sessions_create',{title:'Built-in child',text:'Controlled fixture',purpose:'Verify Pi permission contract'})
  assert.equal(reply.result.isError,false)
  await turn();assert.equal(f.runs.length,1)
  assert.equal(f.selections.get(f.runs[0].native.sessionID).permission,'full')
})

test('management access approval survives the requesting turn and only a user response grants scoped history',async t=>{
  const f=await fixture(t)
  await f.command('workspace',{conversationID:f.source,workspaceAction:{sessionTools:{id:f.source,enabled:['sessions']}}})
  const target=(await f.command('createSession',{providerID:'opencode'})).conversationID
  await f.command('send',{conversationID:f.source,text:'Request management access'});await turn()
  const input={id:target,purpose:'Coordinate after user approval',requestID:randomUUID()}
  const pending=await f.call('woven_sessions_manage',input)
  assert.equal(pending.result.structuredContent.result.pending,true)
  assert.equal((await f.call('woven_history_conversation',{id:target})).result.isError,true)
  const approval=f.service.interactions().find(item=>item.mcpManageAccessID)
  assert.ok(approval)
  f.runs[0].end();await turn();await turn()
  assert.ok(f.service.interactions().some(item=>item.id===approval.id))
  const receipt=await f.command('respond',{conversationID:f.source,runID:approval.runID,interactionID:approval.id,response:{optionID:'allow_once'}})
  assert.equal(receipt.status,'completed')
  const managed=await f.call('woven_sessions_manage',input)
  assert.equal(managed.result.isError,false);assert.equal(managed.result.structuredContent.result.coordinatorID,f.source)
  assert.equal((await f.call('woven_history_conversation',{id:target})).result.isError,false)
})
