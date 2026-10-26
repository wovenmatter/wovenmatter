import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createClientExecution } from '../src/client-execution.mjs'
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
  const toolWith=async (context,action,values={})=>{
    const scope=service.mcp.resolvePrincipal('Bearer '+context.bearerToken)
    const response=await service.mcp.handle(scope,{jsonrpc:'2.0',id:randomUUID(),method:'tools/call',params:{name:'woven_goals_'+action,arguments:values}})
    if(response.error)throw new Error(response.error.message)
    return response.result.structuredContent
  }
  const tool=async (action,values={})=>toolWith(runs.at(-1).command.mcpConnection,action,values)
  t.after(async()=>{await service.close();rmSync(directory,{recursive:true,force:true})})
  return {directory,runs,runtime,command,principal,read,mutate,tool,toolWith,get service(){return service},async restart(){await service.close();service=createClientExecution({directory,runtime,goalIntervalMilliseconds:3600000})}}
}
for(const kind of ['default_agent','codex','claude_code','grok_build','opencode'])test(`owner goal controls and ordinary continuation dispatch: ${kind}`,async t=>{
  const f=fixture(t,kind),opened=await f.service.command(f.command('createSession',{providerID:kind}),f.principal),id=opened.conversationID
  assert.equal((await f.mutate(id,{set:{objective:'Verify',turnBudget:2}})).status,'completed')
  await f.service.tickGoals();await turn()
  assert.equal(f.runs.length,1);assert.equal(f.runs[0].runtimeKind,kind)
  assert.match(f.runs[0].command.text,/When the user explicitly requests a goal/)
  assert.equal(f.service.transcript(id).messages[0].content,'Continuing toward the goal.')
  const goal=await f.read(id),requestID=randomUUID()
  const values={id:goal.id,evidence:'Changed and verified one issue',requestID}
  assert.equal((await f.tool('checkpoint',values)).success,true)
  assert.equal((await f.tool('checkpoint',values)).success,true)
  f.runs[0].publish({sessionUpdate:'usage_update',usage:{totalTokens:100}})
  f.runs[0].end();await turn()
  assert.equal((await f.read(id)).completedTurns,1)
  await f.service.tickGoals();await turn()
  assert.equal(f.runs.length,2)
  await f.tool('checkpoint',{id:goal.id,evidence:'Second verified improvement',requestID:randomUUID()})
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
  await f.tool('checkpoint',{id:goal.id,evidence:'Progress',requestID:randomUUID()})
  f.runs[0].end();await turn();await f.service.tickGoals();await turn()
  await f.tool('checkpoint',{id:goal.id,evidence:'Progress',requestID:randomUUID()})
  f.runs[1].end();await turn()
  assert.equal((await f.read(id)).status,'blocked')
  f.service.mcp.revokeSession(id)
  await assert.rejects(f.tool('get'))
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
  await f.tool('checkpoint',{id:goal.id,evidence:'Progress',requestID:randomUUID()})
  f.runs[0].end();await turn();await f.service.tickGoals()
  assert.equal((await f.read(id)).status,'blocked');assert.match((await f.read(id)).evidence,/usage is unavailable/);assert.equal(f.runs.length,1)
  assert.equal((await f.mutate(id,{resume:{id:goal.id}})).status,'rejected')
  await f.service.tickGoals();assert.equal(f.runs.length,1)
  await f.mutate(id,{edit:{id:goal.id,objective:'Verify',tokenBudget:null}})
  await f.mutate(id,{resume:{id:(await f.read(id)).id}})
  await f.service.tickGoals();await turn();assert.equal(f.runs.length,2)
})

test('out-of-order cumulative usage reports cannot reduce the consumed token budget',async t=>{
  const f=fixture(t),opened=await f.service.command(f.command('createSession'),f.principal),id=opened.conversationID
  await f.mutate(id,{set:{objective:'Verify',tokenBudget:100}});await f.service.tickGoals();await turn()
  const goal=await f.read(id)
  await f.tool('checkpoint',{id:goal.id,evidence:'Verified change',requestID:randomUUID()})
  f.runs[0].publish({sessionUpdate:'woven_usage',usage:{totalTokens:120}})
  f.runs[0].publish({sessionUpdate:'usage_update',usage:{totalTokens:20}})
  f.runs[0].end();await turn();await f.service.tickGoals()
  assert.equal((await f.read(id)).tokensUsed,120);assert.equal((await f.read(id)).status,'budget_limited');assert.equal(f.runs.length,1)
})

test('native usage accounting includes caches and leaves missing reports unknown',async()=>{
  const {clientRunTokens}=await import('../src/client-execution-runtime.mjs')
  assert.equal(clientRunTokens({usage:{inputTokens:3,outputTokens:5,cachedReadTokens:7,cachedWriteTokens:11}}),26)
  assert.equal(clientRunTokens({usage:{totalTokens:4,inputTokens:3,outputTokens:5}}),4)
  assert.equal(clientRunTokens({}),undefined)
  assert.equal(clientRunTokens({usage:{inputTokens:3}}),undefined)
  assert.equal(clientRunTokens({usage:{inputTokens:-1,outputTokens:2}}),undefined)
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
