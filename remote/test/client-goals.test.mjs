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
