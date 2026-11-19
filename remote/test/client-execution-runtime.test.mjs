import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync,writeFileSync,rmSync,readdirSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createDurableACP } from '../src/durable-acp.mjs'
import { createClientExecutionRuntime } from '../src/client-execution-runtime.mjs'
import { createClientExecution } from '../src/client-execution.mjs'
import { loadRuntimeConfiguration } from '../src/config.mjs'
import { enroll } from './fixtures/execution.mjs'

const pause=()=>new Promise(resolve=>setTimeout(resolve,25))
async function until(read,accept){for(let i=0;i<100;i++){const value=await read();if(accept(value))return value;await pause()}throw new Error('fixture timed out')}

test('full-root direct Pi sessions apply workspace permissions on creation and later configuration', async t => {
  const root = mkdtempSync(join(tmpdir(), 'woven-full-root-pi-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const calls = [], permission = { id: 'permission_mode', currentValue: 'ask', options: [{ value: 'ask' }, { value: 'full' }] }
  const defaultAgent = {
    async status() { return { locked: false, epoch: 'epoch' } },
    async invoke(value) {
      calls.push(value)
      if (value.method === 'session/new') return { result: { sessionId: 'session', configOptions: [permission] } }
      if (value.method === 'session/set_config_option') {
        permission.currentValue = value.params.value
        return { result: { configOptions: [permission] } }
      }
      return { result: {} }
    },
    async cancelActive() {},
  }
  const runtime = createClientExecutionRuntime({ defaultAgent, durableACP: { async stopAll() {} }, catalog: new Map(), workspaceRoot: root,
    configuration: loadRuntimeConfiguration({ WOVENMATTER_ACCESS_MODE: 'fullRoot' }) })
  t.after(() => runtime.close())
  const native = await runtime.create({ runtimeKind: 'default_agent', conversationID: randomUUID(), nativeWorkingDirectory: root, permission: 'ask' })
  assert.equal(calls.find(value => value.method === 'session/set_config_option').params.value, 'full')
  permission.currentValue = 'ask'
  await runtime.configure({ native, runtimeKind: 'default_agent', options: { permission: 'ask' } })
  assert.equal(calls.filter(value => value.method === 'session/set_config_option').at(-1).params.value, 'full')
})

test('a new session starts in Full access unless a mode Woven offers is asked for; any other is refused', async t => {
  const root = mkdtempSync(join(tmpdir(), 'woven-no-ask-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const calls = [], permission = { id: 'permission_mode', currentValue: 'ask', options: [{ value: 'ask' }, { value: 'full' }] }
  const defaultAgent = {
    async status() { return { locked: false, epoch: 'epoch' } },
    async invoke(value) {
      calls.push(value)
      if (['session/new', 'woven/adopt'].includes(value.method)) return { result: { sessionId: value.params.sessionId ?? 'session', configOptions: [permission] } }
      if (value.method === 'session/set_config_option') {
        permission.currentValue = value.params.value
        return { result: { configOptions: [permission] } }
      }
      return { result: {} }
    },
    async cancelActive() {},
  }
  const runtime = createClientExecutionRuntime({ defaultAgent, durableACP: { async stopAll() {} }, catalog: new Map(), workspaceRoot: root,
    configuration: loadRuntimeConfiguration({ HOME: root }) })
  t.after(() => runtime.close())
  const changes = () => calls.filter(value => value.method === 'session/set_config_option').map(value => value.params.value)
  await assert.rejects(runtime.create({ runtimeKind: 'default_agent', conversationID: randomUUID(), nativeWorkingDirectory: root, permission: 'ask' }), /not offered/)
  assert.deepEqual(calls, [], 'a mode Woven does not offer starts nothing')
  await runtime.create({ runtimeKind: 'default_agent', conversationID: randomUUID(), nativeWorkingDirectory: root })
  assert.deepEqual(changes(), ['full'], 'with no mode asked for, the session is created in Full access')
  // Reattaching a session leaves its permission as it is.
  permission.currentValue = 'ask'
  await runtime.adopt({ native: { sessionID: 'adopted', nativeWorkingDirectory: root }, runtimeKind: 'default_agent' })
  assert.deepEqual(changes(), ['full'])
})

test('direct clients run an actual fixture ACP process, answer approvals and replay saved output',async t=>{
  const workspaceRoot=mkdtempSync(join(tmpdir(),'wm-direct-acp-'))
  const executable=join(workspaceRoot,'fixture.mjs')
  writeFileSync(executable,`import {realpathSync} from 'node:fs';import {createInterface} from 'node:readline';let prompt;let sid='fixture_session_'+process.pid;const out=v=>process.stdout.write(JSON.stringify(v)+'\\n');
  createInterface({input:process.stdin}).on('line',line=>{const v=JSON.parse(line);
    if(['session/new','session/load'].includes(v.method)&&realpathSync(v.params.cwd)!==process.cwd()){out({jsonrpc:'2.0',id:v.id,error:{code:-32602,message:'Wrong process directory'}});return;}
    if(v.method==='initialize')out({jsonrpc:'2.0',id:v.id,result:{protocolVersion:1}});
    else if(v.method==='session/new'){out({jsonrpc:'2.0',id:v.id,result:{sessionId:sid}});}
    else if(v.method==='session/load'){sid=v.params.sessionId;out({jsonrpc:'2.0',id:v.id,result:{sessionId:sid}});}
    else if(v.method==='session/prompt'){prompt=v;out({jsonrpc:'2.0',method:'session/update',params:{sessionId:sid,update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'before approval'}}}});out({jsonrpc:'2.0',id:'approval',method:'session/request_permission',params:{sessionId:sid,toolCall:{title:'Fixture tool'},options:[{optionId:'once',name:'Allow Once'}]}});}
    else if(v.id==='approval'){out({jsonrpc:'2.0',method:'session/update',params:{sessionId:sid,update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:' after approval'}}}});out({jsonrpc:'2.0',id:prompt.id,result:{stopReason:'end_turn'}});}
  });`)
  const harness={id:'fixture',displayName:'Fixture',transport:'acp',command:process.execPath,arguments:[executable]},catalog=new Map([['fixture',harness]])
  const relay=createDurableACP({catalog,workspaceRoot,environment:()=>process.env})
  const runtime=createClientExecutionRuntime({defaultAgent:{status:async()=>({}),cancelActive:async()=>{}},durableACP:relay,catalog,workspaceRoot,harnessStatus:async()=>({...harness,state:'ready'}),environment:()=>process.env})
  let service=createClientExecution({directory:join(workspaceRoot,'store'),runtime})
  t.after(async()=>{await service.close();rmSync(workspaceRoot,{recursive:true,force:true})})
  const {enrollment:ids,principal}=enroll(service)
  const command=(kind,args={})=>({commandID:randomUUID(),deviceID:ids.deviceID,kind,...args})
  const opened=await service.command(command('createSession',{runtimeKind:'fixture'}),principal)
  assert.equal(opened.status,'completed',JSON.stringify(opened))
  const scratchDirectories=readdirSync(join(workspaceRoot,'scratch'))
  assert.equal(scratchDirectories.length,1)
  const input=command('send',{conversationID:opened.conversationID,text:'fixture'})
  const accepted=await service.command(input,principal)
  const pending=await until(()=>service.interactions(),items=>items.length>0)
  assert.equal(pending[0].title,'Fixture tool')
  const response=await service.command(command('respond',{conversationID:opened.conversationID,runID:accepted.runID,interactionID:pending[0].id,response:{optionID:'once',answers:{},cancelled:false}}),principal)
  assert.equal(response.status,'completed')
  await until(()=>service.receipt(input.commandID,ids.deviceID),value=>value.status==='completed')
  assert.equal(service.transcript(opened.conversationID).messages.at(-1).content,'before approval after approval')
  assert.equal(service.interactions().length,0)
  assert.ok(service.events().entries.some(entry=>entry.nativeRecord))
  const adoptedID=randomUUID(),attached=await relay.handle('POST','/durable-acp/attach',{channelID:adoptedID,harnessID:'fixture',cwd:workspaceRoot,attachmentTokens:true})
  const adoptedSend=message=>relay.handle('POST','/durable-acp/message',{channelID:adoptedID,attachmentToken:attached.attachmentToken,deliveryID:randomUUID(),message})
  await adoptedSend({jsonrpc:'2.0',id:randomUUID(),method:'initialize',params:{protocolVersion:1}})
  await adoptedSend({jsonrpc:'2.0',id:randomUUID(),method:'session/new',params:{cwd:workspaceRoot}})
  const adoptedSession=(await until(()=>relay.handle('POST','/durable-acp/poll',{channelID:adoptedID,after:0}),value=>!!value.snapshot.session?.sessionId)).snapshot.session.sessionId
  // A session whose channel another attachment holds is taken over only while it is idle, and only as the session it is.
  const adopt=(sessionID=adoptedSession)=>runtime.adopt({native:{sessionID,channelID:adoptedID,nativeWorkingDirectory:workspaceRoot},runtimeKind:'fixture'})
  await adoptedSend({jsonrpc:'2.0',id:randomUUID(),method:'session/prompt',params:{sessionId:adoptedSession,prompt:[{type:'text',text:'existing run'}],_meta:{wovenRunID:randomUUID()}}})
  await until(()=>relay.handle('POST','/durable-acp/poll',{channelID:adoptedID,after:0}),value=>value.snapshot.pendingRequests.length>0)
  await assert.rejects(adopt(),/not idle/)
  await adoptedSend({jsonrpc:'2.0',id:'approval',result:{outcome:{outcome:'selected',optionId:'once'}}})
  await until(()=>relay.handle('POST','/durable-acp/poll',{channelID:adoptedID,after:0}),value=>!value.snapshot.busy)
  await assert.rejects(adopt('different-session'),/different native session/)
  await adoptedSend({jsonrpc:'2.0',id:randomUUID(),method:'initialize',params:{protocolVersion:1}})
  assert.equal((await adopt()).sessionID,adoptedSession)
  await assert.rejects(adoptedSend({jsonrpc:'2.0',id:randomUUID(),method:'session/prompt',params:{sessionId:adoptedSession,prompt:[]}}),/attachment was replaced/)
  await service.close()
  const reopenedRuntime=createClientExecutionRuntime({defaultAgent:{cancelActive:async()=>{}},durableACP:createDurableACP({catalog,workspaceRoot,environment:()=>process.env}),catalog,workspaceRoot,environment:()=>process.env})
  service=createClientExecution({directory:join(workspaceRoot,'store'),runtime:reopenedRuntime})
  const next=command('send',{conversationID:opened.conversationID,text:'new input after clean restart'}),nextReceipt=await service.command(next,principal)
  const [nextPending]=await until(()=>service.interactions(),items=>items.length===1)
  await service.command(command('respond',{conversationID:opened.conversationID,runID:nextReceipt.runID,interactionID:nextPending.id,response:{optionID:'once',answers:{},cancelled:false}}),principal)
  await until(()=>service.receipt(next.commandID,ids.deviceID),value=>value.status==='completed')
  assert.equal(service.transcript(opened.conversationID).messages.filter(item=>item.role==='user').length,2)
  assert.deepEqual(readdirSync(join(workspaceRoot,'scratch')),scratchDirectories)
})

for (const stopFails of [false, true]) test(`Stop during Pi Durable setup fences dispatch (stop fails: ${stopFails})`, async t => {
  let release, enteredResolve, hold = false;
  const gate = new Promise(resolve => { release = resolve }), entered = new Promise(resolve => { enteredResolve = resolve }), calls = [];
  const defaultAgent = {
    async status() { if (hold) { hold = false; enteredResolve(); await gate } return { locked: false, epoch: 'fixture' } },
    async invoke(value) {
      calls.push(value.method);
      if (value.method === 'session/cancel' && stopFails) throw Error('Synthetic cancellation failure');
      return value.method === 'session/new' ? { result: { sessionId: 'fixture-session', _meta: { attachmentToken: 'fixture-token' } } }
        : value.method === 'session/prompt' ? { operationID: value.operationID } : { result: {} };
    },
    async poll() { return { updates: [], cursor: 0, done: true } }, async cancelActive() {},
  };
  const root = mkdtempSync(join(tmpdir(), 'woven-stop-setup-'));
  const runtime = createClientExecutionRuntime({ defaultAgent, durableACP: { async stopAll() {} }, catalog: new Map(),
    workspaceRoot: root, environment: () => process.env, harnessStatus: async () => ({}) });
  const service = createClientExecution({ directory: root, runtime });
  t.after(async () => { release(); await service.close(); rmSync(root, { recursive: true, force: true }) });
  const { enrollment: { deviceID }, principal } = enroll(service);
  const command = (kind, args = {}) => ({ commandID: randomUUID(), deviceID, kind, ...args });
  const created = await service.command(command('createSession', { providerID: 'default_agent' }), principal);
  hold = true;
  const input = command('send', { conversationID: created.conversationID, text: 'Synthetic input' });
  const accepted = await service.command(input, principal); await entered;
  const stop = await service.command(command('stop', { conversationID: created.conversationID, runID: accepted.runID }), principal);
  assert.equal(stop.status, stopFails ? 'rejected' : 'completed');
  release();
  await until(() => service.receipt(input.commandID, deviceID), value => value.status !== 'accepted');
  assert.equal(calls.filter(value => value === 'session/prompt').length, stopFails ? 1 : 0);
  assert.equal(service.transcript(created.conversationID).messages.at(-1).status, stopFails ? 'completed' : 'cancelled');
  const next = command('send', { conversationID: created.conversationID, text: 'Fresh later input' });
  await service.command(next, principal);
  await until(() => service.receipt(next.commandID, deviceID), value => value.status !== 'accepted');
  assert.equal(calls.filter(value => value === 'session/prompt').length, stopFails ? 2 : 1);
});
