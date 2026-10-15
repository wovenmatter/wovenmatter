import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, mkdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { randomUUID } from 'node:crypto'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { createClientExecution } from '../src/client-execution.mjs'
const exec = promisify(execFile)
const turn=()=>new Promise(resolve=>setImmediate(resolve))
function fixture(t, runtimeKind='default_agent') {
  const directory=mkdtempSync(join(tmpdir(),'wm-goals-')),runs=[]
  const runtime={providers:async()=>[{id:runtimeKind,runtimeKind,available:true,canStart:true}],
    create:async()=>({sessionID:randomUUID(),nativeWorkingDirectory:directory}),settings:async()=>({permission:'default',canConfigure:true}),
    run:async input=>{let end;const completion=new Promise(resolve_=>{end=resolve_});runs.push({...input,end});await completion},
    stop:async({command})=>runs.find(run=>run.command.runID===command.runID)?.end(),close:async()=>{for(const run of runs)run.end()}}
  let service=createClientExecution({directory,runtime,goalIntervalMilliseconds:3600000})
  const enrollment={libraryID:randomUUID(),workspaceID:randomUUID(),ownerDeviceID:randomUUID(),deviceID:randomUUID(),scopes:['execution']}
  const grant=service.provision(enrollment),principal=service.principal('Bearer '+grant.token,'execution')
  const command=(kind,values={})=>({commandID:randomUUID(),deviceID:principal.id,kind,...values})
  const read=async id=>(await service.readWorkspace({session:{id}})).session._0.goal
  const mutate=(id,mutation)=>service.command(command('workspace',{conversationID:id,workspaceAction:{goal:{id,mutation}}}),principal)
  const cliWith=async (context,cwd,...args)=>JSON.parse((await exec('python3',[fileURLToPath(new URL('../src/wovenmatter',import.meta.url)),'goals',...args],{cwd,env:{...process.env,WOVENMATTER_SOCKET:context.socketPath,WOVENMATTER_CONTEXT_ID:context.captureID}})).stdout)
  const cli=async (...args)=>cliWith(runs.at(-1).command.goalToolContext,directory,...args)
  t.after(async()=>{await service.close();rmSync(directory,{recursive:true,force:true})})
  return {directory,runs,runtime,command,principal,read,mutate,cli,cliWith,get service(){return service},async restart(){await service.close();service=createClientExecution({directory,runtime,goalIntervalMilliseconds:3600000})}}
}
for(const kind of ['default_agent','codex','claude_code','grok_build','opencode'])test(`owner goal controls and ordinary continuation dispatch: ${kind}`,async t=>{
  const f=fixture(t,kind),opened=await f.service.command(f.command('createSession',{providerID:kind}),f.principal),id=opened.conversationID
  assert.equal((await f.mutate(id,{set:{objective:'Verify',turnBudget:2}})).status,'completed')
  await f.service.tickGoals();await turn()
  assert.equal(f.runs.length,1);assert.equal(f.runs[0].runtimeKind,kind)
  assert.match(f.runs[0].command.text,/When the user explicitly requests a goal/)
  assert.equal(f.service.transcript(id).messages[0].content,'Continuing toward the goal.')
  const goal=await f.read(id),requestID=randomUUID()
  const args=['checkpoint','--id',goal.id,'--evidence','Changed and verified one issue','--request-id',requestID]
  assert.equal((await f.cli(...args)).success,true)
  assert.equal((await f.cli(...args)).success,true)
  f.runs[0].publish({sessionUpdate:'usage_update',usage:{totalTokens:100}})
  f.runs[0].end();await turn()
  assert.equal((await f.read(id)).completedTurns,1)
  await f.service.tickGoals();await turn()
  assert.equal(f.runs.length,2)
  await f.cli('checkpoint','--id',goal.id,'--evidence','Second verified improvement','--request-id',randomUUID())
  f.runs[1].publish({sessionUpdate:'usage_update',usage:{totalTokens:50}})
  f.runs[1].end();await turn()
  const result=await f.read(id)
  assert.equal(result.status,'budget_limited');assert.equal(result.completedTurns,2);assert.equal(result.tokensUsed,150)
  assert.equal((await f.mutate(id,{resume:{id:goal.id}})).status,'rejected')
  await f.service.tickGoals();assert.equal(f.runs.length,2)
})
test('missing or duplicate progress cannot continue forever; stale bindings are rejected',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify'}});await f.service.tickGoals();await turn()
  const goal=await f.read(id)
  await f.cli('checkpoint','--id',goal.id,'--evidence','Progress','--request-id',randomUUID())
  f.runs[0].end();await turn();await f.service.tickGoals();await turn()
  await f.cli('checkpoint','--id',goal.id,'--evidence','Progress','--request-id',randomUUID())
  f.runs[1].end();await turn()
  assert.equal((await f.read(id)).status,'blocked')
  await assert.rejects(f.cli('get'))
  await f.service.tickGoals();assert.equal(f.runs.length,2)
})
test('Stop, edit and restart require explicit resume and preserve accounting',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify'}});await f.service.tickGoals();await turn()
  let goal=await f.read(id)
  await f.service.command(f.command('stop',{conversationID:id,runID:f.runs[0].command.runID}),f.principal);await turn()
  assert.equal((await f.read(id)).status,'paused');await f.service.tickGoals();assert.equal(f.runs.length,1)
  assert.equal((await f.mutate(id,{edit:{id:goal.id,objective:'Verify final'}})).status,'completed')
  const edited=await f.read(id);assert.notEqual(edited.id,goal.id);assert.equal(edited.status,'paused')
  assert.equal((await f.mutate(id,{resume:{id:goal.id}})).status,'rejected')
  await f.mutate(id,{resume:{id:edited.id}});await f.restart()
  assert.equal((await f.read(id)).status,'paused');await f.service.tickGoals();assert.equal(f.runs.length,1)
})
test('token budget without provider accounting blocks before a second run',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify',tokenBudget:10}});await f.service.tickGoals();await turn()
  const goal=await f.read(id)
  await f.cli('checkpoint','--id',goal.id,'--evidence','Progress','--request-id',randomUUID())
  f.runs[0].end();await turn();await f.service.tickGoals()
  assert.equal((await f.read(id)).status,'blocked');assert.match((await f.read(id)).evidence,/usage is unavailable/);assert.equal(f.runs.length,1)
})
test('plan mode and a queued human input gate automatic work while goals stay enabled',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify'}})
  f.runtime.settings=async()=>({permission:'plan'});await f.service.tickGoals();assert.equal(f.runs.length,0)
  await f.service.command(f.command('workspace',{conversationID:id,workspaceAction:{sessionTools:{id,enabled:[]}}}),f.principal)
  assert.equal((await f.read(id)).status,'active')
  f.runtime.settings=async()=>({permission:'default'})
  assert.equal((await f.mutate(id,{resume:{id:(await f.read(id)).id}})).status,'completed')
  assert.deepEqual((await f.service.readWorkspace({session:{id}})).session._0.enabledTools,['goals'])
  let release;const waiting=new Promise(resolve_=>{release=resolve_});f.runtime.settings=async()=>{await waiting;return {permission:'default'}}
  const tick=f.service.tickGoals();await turn()
  const human=f.service.command(f.command('send',{conversationID:id,text:'New instruction'}),f.principal)
  release();await tick;await human;await turn()
  assert.equal(f.runs.length,1);assert.match(f.runs[0].command.text,/^New instruction/)
})

test('native usage accounting includes caches and leaves missing reports unknown',async()=>{
  const {clientRunTokens}=await import('../src/client-execution-runtime.mjs')
  assert.equal(clientRunTokens({usage:{inputTokens:3,outputTokens:5,cachedReadTokens:7,cachedWriteTokens:11}}),26)
  assert.equal(clientRunTokens({usage:{totalTokens:4,inputTokens:3,outputTokens:5}}),4)
  assert.equal(clientRunTokens({}),undefined)
  assert.equal(clientRunTokens({usage:{inputTokens:3}}),undefined)
  assert.equal(clientRunTokens({usage:{inputTokens:-1,outputTokens:2}}),undefined)
})
test('adoption retains the paused goal and carries prior accounting forward',async t=>{
  const f=fixture(t),id=randomUUID(),goalID=randomUUID()
  f.runtime.adopt=async({native})=>native
  const adoption={workspaceID:f.service.descriptor().id,conversation:{id,title:'Transferred',preview:'',updatedAt:''},runtimeKind:'codex',nativeSessionID:'native',nativeWorkingDirectory:f.directory,knownRunIDs:[],
    goal:{id:goalID,sessionID:id,objective:'Finish transfer',status:'paused',completedTurns:2,tokensUsed:40,createdAt:0,updatedAt:0,baselineRunSequence:0,observedRunSequence:0,enrolledRunSequence:0,progressRevision:2,pendingProgressRevision:1}}
  await f.service.adopt(adoption)
  assert.equal((await f.read(id)).id,goalID);await f.service.tickGoals();assert.equal(f.runs.length,0)
  await f.mutate(id,{resume:{id:goalID}});await f.service.tickGoals();await turn()
  f.runs[0].publish({sessionUpdate:'woven_usage',usage:{totalTokens:10}})
  // This test verifies accounting, without requiring another continuation.
  f.runs[0].end();await turn()
  assert.equal((await f.read(id)).completedTurns,3);assert.equal((await f.read(id)).tokensUsed,50)
})

test('explicit resume after a failed turn authorizes fresh work without replaying the old command',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify'}})
  const original=f.runtime.run
  f.runtime.run=async()=>{throw new Error('Interrupted native attempt')}
  await f.service.tickGoals();await turn()
  const goal=await f.read(id);assert.equal(goal.status,'blocked')
  f.runtime.run=original
  assert.equal((await f.mutate(id,{resume:{id:goal.id}})).status,'completed')
  await f.service.tickGoals();await turn()
  assert.equal(f.runs.length,1);assert.equal((await f.read(id)).status,'active')
})


test('missing token usage cannot be bypassed by resuming with the budget retained',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify',tokenBudget:100}});await f.service.tickGoals();await turn()
  f.runs[0].end();await turn()
  const goal=await f.read(id)
  assert.equal((await f.mutate(id,{resume:{id:goal.id}})).status,'rejected')
  await f.service.tickGoals();assert.equal(f.runs.length,1)
  await f.mutate(id,{edit:{id:goal.id,objective:'Verify',tokenBudget:null}})
  await f.mutate(id,{resume:{id:(await f.read(id)).id}})
  await f.service.tickGoals();await turn();assert.equal(f.runs.length,2)
})

test('goal CLI follows its captured run from subdirectories and rejects an old binding',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify'}});await f.service.tickGoals();await turn()
  const context=f.runs[0].command.goalToolContext,goal=await f.read(id),subdirectory=join(f.directory,'child')
  mkdirSync(subdirectory)
  assert.equal((await f.cliWith(context,subdirectory,'get')).result.id,goal.id)
  await f.cliWith(context,f.directory,'checkpoint','--id',goal.id,'--evidence','First change','--request-id',randomUUID())
  f.runs[0].end();await turn();await f.service.tickGoals();await turn()
  await assert.rejects(f.cliWith(context,f.directory,'checkpoint','--id',goal.id,'--evidence','Stale work','--request-id',randomUUID()))
  assert.equal((await f.cliWith(f.runs[1].command.goalToolContext,subdirectory,'get')).result.id,goal.id)
})

test('slash resume after a failed run asks the agent to resume through its goal CLI',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify'}})
  const original=f.runtime.run;f.runtime.run=async()=>{throw new Error('Interrupted native attempt')}
  await f.service.tickGoals();await turn();assert.equal((await f.read(id)).status,'blocked')
  f.runtime.run=original
  assert.equal((await f.service.command(f.command('send',{conversationID:id,text:'/goal resume'}),f.principal)).status,'accepted')
  await turn();assert.equal(f.runs.length,1)
  assert.match(f.runs[0].command.text,/^Resume the current Woven Matter goal using the goal tools/);assert.doesNotMatch(f.runs[0].command.text,/^\/goal/)
  const goal=await f.read(id);assert.equal(goal.status,'blocked')
  await f.cli('resume','--id',goal.id,'--request-id',randomUUID())
  assert.equal((await f.read(id)).status,'active')
})


test('out-of-order cumulative usage reports cannot reduce the consumed token budget',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify',tokenBudget:100}});await f.service.tickGoals();await turn()
  const goal=await f.read(id)
  await f.cli('checkpoint','--id',goal.id,'--evidence','Verified change','--request-id',randomUUID())
  f.runs[0].publish({sessionUpdate:'woven_usage',usage:{totalTokens:120}})
  f.runs[0].publish({sessionUpdate:'usage_update',usage:{totalTokens:20}})
  f.runs[0].end();await turn();await f.service.tickGoals()
  assert.equal((await f.read(id)).tokensUsed,120);assert.equal((await f.read(id)).status,'budget_limited');assert.equal(f.runs.length,1)
})

test('simultaneous sessions sharing a directory keep independent native goal bindings',async t=>{
  const f=fixture(t),first=await f.service.command(f.command('createSession'),f.principal),second=await f.service.command(f.command('createSession'),f.principal)
  await f.mutate(first.conversationID,{set:{objective:'First'}})
  await f.mutate(second.conversationID,{set:{objective:'Second'}})
  await f.service.tickGoals();await turn()
  for(const run of f.runs) {
    const result=await f.cliWith(run.command.goalToolContext,f.directory,'get')
    assert.equal(result.result.sessionID,run.command.conversationID)
  }
})
