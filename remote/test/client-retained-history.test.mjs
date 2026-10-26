import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, mkdirSync, readFileSync, readdirSync, writeFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createClientExecution } from '../src/client-execution.mjs'
import { createTaskGateway } from '../src/task-gateway.mjs'
import { createRetainedExecutionCapture } from '../src/client-retained-history.mjs'
import { createDefaultAgentService } from '../../default-agent/src/service.mjs'


const turn=()=>new Promise(done=>setTimeout(done,5))
async function until(test){for(let n=0;n<200;n++){if(test())return;await turn()}assert.fail('Timed out waiting for retained capture')}
function fixture(t){
  const root=mkdtempSync(join(tmpdir(),'wm-retained-')),directory=join(root,'capture'),defaultDirectory=join(root,'default')
  mkdirSync(defaultDirectory,{recursive:true})
  const runtime={providers:async()=>[],close:async()=>{}}
  let execution=createClientExecution({directory:join(root,'execution'),runtime})
  execution.provision({libraryID:randomUUID(),workspaceID:randomUUID(),ownerDeviceID:randomUUID(),deviceID:randomUUID(),scopes:['execution']})
  t.after(async()=>{await execution.close();rmSync(root,{recursive:true,force:true})})
  return {root,directory,defaultDirectory,get execution(){return execution},async restart(){await execution.close();execution=createClientExecution({directory:join(root,'execution'),runtime})}}
}
function entries(execution){let all=[],after=0;for(;;){const page=execution.events(after);all.push(...page.entries);if(!page.hasMore)return all;after=page.cursor}}
function capture(f,options={}){return createRetainedExecutionCapture({directory:f.directory,defaultDirectory:f.defaultDirectory,
  execution:f.execution,taskGateway:{results:()=>({entries:[],cursor:'0'}),retainedRunIDs:()=>[]},defaultAgent:{poll:async()=>assert.fail('Historical replay invoked the agent')},...options})}
function rawUpdateBytes(events){const records=new Map();for(const item of events){const part=item.nativeRecord;if(part){const parts=records.get(part.recordID)??[];parts[part.partIndex]=Buffer.from(part.data,'base64');records.set(part.recordID,parts)}}return [...records.values()].map(parts=>Buffer.concat(parts).toString('utf8'))}

test('workspace startup captures durable scheduled output without a client, survives ACK loss and restart',async t=>{
  const f=fixture(t),clock=Date.parse('2026-01-01T12:00:00Z');let sends=0
  const large='complete tool result '+ 'α'.repeat(400000)
  const gateway=createTaskGateway({directory:join(f.root,'tasks'),now:()=>clock,execute:async({publish,bindSession})=>{
    sends++;bindSession('native-task');publish({sessionUpdate:'agent_message_chunk',content:{text:'Task answer'}})
    publish({sessionUpdate:'tool_call',toolCallId:'one',title:'Read',status:'completed',content:[{text:large}]});return {stopReason:'end_turn'}
  }})
  gateway.publish({publicationID:'publication',knownRuns:[],schedules:[{id:'scheduled',title:'Scheduled work',startsAt:new Date(clock).toISOString(),nextFireAt:new Date(clock).toISOString(),
    timeZoneID:'UTC',revision:1,excludedOccurrences:[],task:{prompt:'Run once',sessionMode:'new',configuration:{runtimeKind:'codex'}}}]})
  gateway.tick();await until(()=>gateway.status().activeRuns===0)
  const result=gateway.results().entries[0]
  let lost=true
  const importer={descriptor:()=>f.execution.descriptor(),importRetainedEvents:async batch=>{f.execution.importRetainedEvents(batch);if(lost&&batch.some(item=>item.nativeRecord)){lost=false;throw new Error('lost acknowledgement')}}}
  let bridge=capture(f,{taskGateway:gateway,execution:importer})
  await assert.rejects(()=>bridge.pump(),/lost acknowledgement/)
  await bridge.close();await f.restart()
  const restoredGateway=createTaskGateway({directory:join(f.root,'tasks'),execute:async()=>assert.fail('Restart replayed execution')})
  bridge=capture(f,{taskGateway:restoredGateway,intervalMilliseconds:5});bridge.start()
  await until(()=>entries(f.execution).some(item=>item.transcript?.runs?.[0]?.id===result.run.id))
  await bridge.close();await restoredGateway.close();await gateway.close()
  const saved=entries(f.execution),ids=saved.map(item=>item.eventID)
  assert.equal(sends,1);assert.equal(new Set(ids).size,ids.length)
  assert.deepEqual(saved.map(item=>item.originSequence),saved.map((_,n)=>n+1))
  assert.ok(saved.every(item=>item.conversationID===result.run.sessionID))
  assert.equal(saved[0].retainedExecution.nativeSessionID,'native-task')
  assert.ok(saved.some(item=>item.transcript?.messages?.some(message=>message.content==='Task answer')))
  assert.ok(rawUpdateBytes(saved).some(bytes=>JSON.parse(bytes).content?.[0]?.text===large))
  bridge=capture(f,{taskGateway:restoredGateway});await bridge.pump();await bridge.close()
  assert.deepEqual(entries(f.execution).map(item=>item.eventID),ids)
})

test('restart recovers exact legacy spool associations and preserves an incomplete trailing write',async t=>{
  const f=fixture(t),operationID=randomUUID(),runID=randomUUID(),conversationID=randomUUID(),epoch=randomUUID()
  const file=join(f.defaultDirectory,`run-${epoch}-${operationID}.jsonl`)
  const bytes=JSON.stringify({sessionUpdate:'woven_native_record',recordBatch:{nativeSessionID:'old-native',records:[{id:'record',runID,payload:'saved'}]}})+'\n'
    +JSON.stringify({sessionUpdate:'agent_message_chunk',content:{text:'Already saved'}})+'\n'+ '{"unfinished":'
  writeFileSync(file,bytes)
  let calls=0
  const bridge=capture(f,{resolveAssociation:async request=>{calls++;assert.equal(request.runID,runID);assert.equal(request.nativeSessionID,'old-native');return {conversationID,runID,nativeSessionID:'old-native',runtimeKind:'default_agent'}}})
  await bridge.pump();await bridge.close()
  assert.equal(calls,1);assert.equal(readFileSync(file,'utf8'),bytes)
  const saved=entries(f.execution)
  assert.ok(saved.every(item=>item.conversationID===conversationID&&item.runID===runID))
  assert.ok(saved.some(item=>item.transcript?.runs?.[0]?.status==='interrupted'))
  assert.ok(saved.some(item=>item.transcript?.messages?.some(message=>message.content==='Already saved')))
})

test('active task and direct execution spools are never re-imported as legacy RPC histories',async t=>{
  const f=fixture(t),taskID=randomUUID(),directID=randomUUID();let imports=0
  for(const id of [taskID,directID])writeFileSync(join(f.defaultDirectory,`run-${randomUUID()}-${id}.jsonl`),'{"sessionUpdate":"agent_message_chunk","content":{"text":"owned"}}\n')
  const bridge=capture(f,{execution:{descriptor:()=>f.execution.descriptor(),hasRun:id=>id===directID,importRetainedEvents:()=>{imports++}},
    taskGateway:{results:()=>({entries:[],cursor:'0'}),retainedRunIDs:()=>[taskID]},resolveAssociation:()=>assert.fail('Already owned run queried central')})
  await bridge.pump();assert.equal(imports,0);assert.equal(bridge.status().pendingAssociationCount,0);await bridge.close()
})

test('verified historical association is durable before import and can finish offline after ACK loss',async t=>{
  const f=fixture(t),runID=randomUUID(),operationID=randomUUID(),conversationID=randomUUID()
  writeFileSync(join(f.defaultDirectory,`run-${randomUUID()}-${operationID}.jsonl`),JSON.stringify({sessionUpdate:'woven_native_record',recordBatch:{nativeSessionID:'verified-native',records:[{runID}]}})+'\n')
  let dropped=false
  let bridge=capture(f,{resolveAssociation:async()=>({conversationID,runID,nativeSessionID:'verified-native',runtimeKind:'default_agent'}),
    execution:{descriptor:()=>f.execution.descriptor(),importRetainedEvents:batch=>{f.execution.importRetainedEvents(batch);if(!dropped){dropped=true;throw new Error('lost')}}}})
  await assert.rejects(()=>bridge.pump(),/lost/);await bridge.close();await f.restart()
  bridge=capture(f,{resolveAssociation:()=>assert.fail('Verified association was not retained')})
  await bridge.pump();await bridge.close()
  assert.ok(entries(f.execution).some(item=>item.transcript?.runs?.[0]?.id===runID))
})

test('mismatched historical association cannot relabel a native record',async t=>{
  const f=fixture(t),runID=randomUUID(),operationID=randomUUID()
  writeFileSync(join(f.defaultDirectory,`run-${randomUUID()}-${operationID}.jsonl`),JSON.stringify({sessionUpdate:'woven_native_record',recordBatch:{nativeSessionID:'native',records:[{runID}]}})+'\n')
  const bridge=capture(f,{resolveAssociation:async()=>({conversationID:randomUUID(),runID:randomUUID(),nativeSessionID:'different',runtimeKind:'default_agent'})})
  await bridge.pump();assert.equal(bridge.status().pendingAssociationCount,1);assert.equal(entries(f.execution).length,0);await bridge.close()
})

test('legacy RPC admission saves identity without credentials and owner polling archives its completed output',async t=>{
  const f=fixture(t),conversationID=randomUUID(),runID=randomUUID(),inputID=randomUUID();let prompts=0
  const service=createDefaultAgentService({cwd:f.root,directory:f.defaultDirectory,attachmentState:{tokens:[['native-rpc','test-private-attachment']]},engineFactory:()=>({handle:async(method,params,publish)=>{
    assert.equal(method,'session/prompt');prompts++;await publish({sessionUpdate:'agent_message_chunk',content:{type:'text',text:'First'}})
    await publish({sessionUpdate:'agent_message_chunk',content:{type:'text',text:' answer'}});return {stopReason:'end_turn'}
  }})})
  const bridge=capture(f,{defaultAgent:service,intervalMilliseconds:5})
  const message=bridge.prepareRPC({method:'session/prompt',operationID:inputID,attachmentToken:'test-private-attachment',params:{sessionId:'native-rpc',prompt:[{type:'text',text:'Hello'}],
    _meta:{wovenConversationID:conversationID,wovenRunID:runID,wovenInputID:inputID,wovenMCP:{endpointURL:'http://127.0.0.1:12345/mcp',bearerToken:'private-capability',captureID:'input-capture'}}}})
  bridge.prepareRPC(message)
  assert.throws(()=>bridge.prepareRPC({...message,params:{...message.params,prompt:[{type:'text',text:'Changed'}]}}),/different input/)
  assert.equal(readdirSync(f.directory).filter(name=>name.startsWith('intent-')).length,1)
  const intent=readFileSync(join(f.directory,'intent-'+inputID+'.json'),'utf8')
  assert.equal(intent.includes('test-private-attachment'),false);assert.equal(intent.includes('private-capability'),false);assert.equal(intent.includes('/test/private/tool'),false)
  bridge.acceptedRPC(message,await service.invoke(message));bridge.start()
  await until(()=>entries(f.execution).some(item=>item.transcript?.runs?.[0]?.status==='completed'))
  await bridge.close()
  assert.equal(prompts,1)
  const saved=entries(f.execution)
  assert.ok(saved.some(item=>item.transcript?.messages?.some(message=>message.id===inputID&&message.content==='Hello')))
  assert.ok(saved.some(item=>item.transcript?.messages?.some(message=>message.id===runID&&message.content==='First answer')))
  assert.equal(saved[0].retainedExecution.status,'completed')
})
