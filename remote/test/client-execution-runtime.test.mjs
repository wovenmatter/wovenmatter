import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync,writeFileSync,rmSync,chmodSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createDurableACP } from '../src/durable-acp.mjs'
import { createClientExecutionRuntime } from '../src/client-execution-runtime.mjs'
import { createClientExecution } from '../src/client-execution.mjs'

const pause=()=>new Promise(resolve=>setTimeout(resolve,25))
async function until(read,accept){for(let i=0;i<100;i++){const value=await read();if(accept(value))return value;await pause()}throw new Error('fixture timed out')}

test('direct clients run an actual fixture ACP process, answer approvals and replay saved output',async t=>{
  const workspaceRoot=mkdtempSync(join(tmpdir(),'wm-direct-acp-'))
  const executable=join(workspaceRoot,'fixture.mjs')
  writeFileSync(executable,`import {createInterface} from 'node:readline';let prompt;let sid='fixture_session_'+process.pid;const out=v=>process.stdout.write(JSON.stringify(v)+'\\n');
  createInterface({input:process.stdin}).on('line',line=>{const v=JSON.parse(line);
    if(v.method==='initialize')out({jsonrpc:'2.0',id:v.id,result:{protocolVersion:1}});
    else if(v.method==='session/new')out({jsonrpc:'2.0',id:v.id,result:{sessionId:sid}});
    else if(v.method==='session/load'){sid=v.params.sessionId;out({jsonrpc:'2.0',id:v.id,result:{sessionId:sid}});}
    else if(v.method==='session/prompt'){prompt=v;out({jsonrpc:'2.0',method:'session/update',params:{sessionId:sid,update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'before approval'}}}});out({jsonrpc:'2.0',id:'approval',method:'session/request_permission',params:{sessionId:sid,toolCall:{title:'Fixture tool'},options:[{optionId:'once',name:'Allow Once'}]}});}
    else if(v.id==='approval'){out({jsonrpc:'2.0',method:'session/update',params:{sessionId:sid,update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:' after approval'}}}});out({jsonrpc:'2.0',id:prompt.id,result:{stopReason:'end_turn'}});}
  });`)
  const harness={id:'fixture',displayName:'Fixture',transport:'acp',command:process.execPath,arguments:[executable]},catalog=new Map([['fixture',harness]])
  const relay=createDurableACP({catalog,workspaceRoot,environment:()=>process.env})
  const runtime=createClientExecutionRuntime({defaultAgent:{status:async()=>({locked:true}),cancelActive:async()=>{}},durableACP:relay,catalog,workspaceRoot,harnessStatus:async()=>({...harness,state:'ready'}),environment:()=>process.env})
  let service=createClientExecution({directory:join(workspaceRoot,'store'),runtime})
  t.after(async()=>{await service.close();rmSync(workspaceRoot,{recursive:true,force:true})})
  const ids={libraryID:randomUUID(),workspaceID:randomUUID(),ownerDeviceID:randomUUID(),deviceID:randomUUID()}
  const grant=service.provision({...ids,scopes:['execution']}),principal=service.principal('Bearer '+grant.token,'execution')
  const command=(kind,args={})=>({commandID:randomUUID(),deviceID:ids.deviceID,kind,...args})
  const opened=await service.command(command('createSession',{runtimeKind:'fixture'}),principal)
  assert.equal(opened.status,'completed',JSON.stringify(opened))
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
  const legacyID=randomUUID(),legacy=await relay.handle('POST','/v1/durable-acp/attach',{channelID:legacyID,harnessID:'fixture',cwd:workspaceRoot,attachmentProtocol:1})
  const legacySend=message=>relay.handle('POST','/v1/durable-acp/message',{channelID:legacyID,attachmentToken:legacy.attachmentToken,deliveryID:randomUUID(),message})
  await legacySend({jsonrpc:'2.0',id:randomUUID(),method:'initialize',params:{protocolVersion:1}})
  await legacySend({jsonrpc:'2.0',id:randomUUID(),method:'session/new',params:{cwd:workspaceRoot}})
  const legacySession=(await until(()=>relay.handle('POST','/v1/durable-acp/poll',{channelID:legacyID,after:0}),value=>!!value.snapshot.session?.sessionId)).snapshot.session.sessionId
  const oldRun=randomUUID(),adoption={workspaceID:ids.workspaceID,conversation:{id:legacyID,title:'Existing desktop conversation',preview:'',updatedAt:'',runtimeKind:'fixture'},runtimeKind:'fixture',nativeSessionID:legacySession,knownRunIDs:[oldRun]}
  await legacySend({jsonrpc:'2.0',id:randomUUID(),method:'session/prompt',params:{sessionId:legacySession,prompt:[{type:'text',text:'existing run'}],_meta:{wovenRunID:oldRun}}})
  await until(()=>relay.handle('POST','/v1/durable-acp/poll',{channelID:legacyID,after:0}),value=>value.snapshot.pendingRequests.length>0)
  await assert.rejects(service.adopt(adoption),/not idle/)
  await legacySend({jsonrpc:'2.0',id:'approval',result:{outcome:{outcome:'selected',optionId:'once'}}})
  await until(()=>relay.handle('POST','/v1/durable-acp/poll',{channelID:legacyID,after:0}),value=>!value.snapshot.busy)
  await assert.rejects(service.adopt({...adoption,nativeSessionID:'different-session'}),/different native session/)
  await legacySend({jsonrpc:'2.0',id:randomUUID(),method:'initialize',params:{protocolVersion:1}})
  const adopted=await service.adopt(adoption)
  assert.equal(adopted.id,legacyID)
  assert.equal((await service.adopt(adoption)).id,legacyID)
  await assert.rejects(legacySend({jsonrpc:'2.0',id:randomUUID(),method:'session/prompt',params:{sessionId:legacySession,prompt:[]}}),/attachment was replaced/)
  const stale=await service.command(command('send',{conversationID:legacyID,runID:oldRun,text:'never replay'}),principal)
  assert.equal(stale.status,'rejected')
  await service.close()
  const reopenedRuntime=createClientExecutionRuntime({defaultAgent:{cancelActive:async()=>{}},durableACP:createDurableACP({catalog,workspaceRoot,environment:()=>process.env}),catalog,workspaceRoot,environment:()=>process.env})
  service=createClientExecution({directory:join(workspaceRoot,'store'),runtime:reopenedRuntime})
  const next=command('send',{conversationID:opened.conversationID,text:'new input after clean restart'}),nextReceipt=await service.command(next,principal)
  const [nextPending]=await until(()=>service.interactions(),items=>items.length===1)
  await service.command(command('respond',{conversationID:opened.conversationID,runID:nextReceipt.runID,interactionID:nextPending.id,response:{optionID:'once',answers:{},cancelled:false}}),principal)
  await until(()=>service.receipt(next.commandID,ids.deviceID),value=>value.status==='completed')
  assert.equal(service.transcript(opened.conversationID).messages.filter(item=>item.role==='user').length,2)
})

test('Pi RPC extension callbacks receive one native response without an ACP error',async t=>{
  const workspaceRoot=mkdtempSync(join(tmpdir(),'wm-direct-pi-')),executable=join(workspaceRoot,'fixture.mjs')
  writeFileSync(executable,`import {createInterface} from 'node:readline';let confirmed=false;const out=v=>process.stdout.write(JSON.stringify(v)+'\\n');
  createInterface({input:process.stdin}).on('line',line=>{const v=JSON.parse(line);
    if(v.jsonrpc){out({type:'message_end',message:{stopReason:'error'}});process.exit(2);}
    if(v.type==='get_state')out({id:v.id,type:'response',success:true,data:{sessionId:'pi_fixture',isStreaming:false,isCompacting:false,pendingMessageCount:0}});
    else if(v.type==='get_entries')out({id:v.id,type:'response',success:true,data:{entries:confirmed?[{id:'entry_tool',type:'message',message:{role:'toolResult',content:[{type:'image',mimeType:'image/png',data:'fixture_native_image'}]}}]:[]}});
    else if(v.type==='prompt'){out({id:v.id,type:'response',success:true,data:{}});out({type:'extension_ui_request',id:'confirm',method:'confirm',title:'Continue?'});}
    else if(v.type==='extension_ui_response'){if(!v.confirmed)process.exit(3);confirmed=true;out({type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'confirmed'}});out({type:'agent_settled'});}
  });`)
  const harness={id:'pi',transport:'rpc',command:process.execPath,arguments:[executable]},catalog=new Map([['pi',harness]])
  const relay=createDurableACP({catalog,workspaceRoot,environment:()=>process.env})
  const runtime=createClientExecutionRuntime({defaultAgent:{cancelActive:async()=>{}},durableACP:relay,catalog,workspaceRoot,environment:()=>process.env})
  const service=createClientExecution({directory:join(workspaceRoot,'store'),runtime})
  t.after(async()=>{await service.close();rmSync(workspaceRoot,{recursive:true,force:true})})
  const deviceID=randomUUID(),grant=service.provision({libraryID:randomUUID(),workspaceID:randomUUID(),ownerDeviceID:randomUUID(),deviceID,scopes:['execution']})
  const principal=service.principal('Bearer '+grant.token,'execution'),command=(kind,args={})=>({commandID:randomUUID(),deviceID,kind,...args})
  const opened=await service.command(command('createSession',{runtimeKind:'pi'}),principal)
  assert.equal(opened.status,'completed',JSON.stringify(opened))
  const input=command('send',{conversationID:opened.conversationID,text:'fixture'}),receipt=await service.command(input,principal)
  const [pending]=await until(()=>service.interactions(),values=>values.length===1)
  assert.equal(pending.title,'Continue?')
  const response=await service.command(command('respond',{conversationID:opened.conversationID,runID:receipt.runID,interactionID:pending.id,response:{optionID:'yes',answers:{},cancelled:false}}),principal)
  assert.equal(response.status,'completed')
  await until(()=>service.receipt(input.commandID,deviceID),value=>value.status==='completed')
  assert.equal(service.transcript(opened.conversationID).messages.at(-1).content,'confirmed')
  const archived=service.events().entries.flatMap(item=>item.nativeRecord?[Buffer.from(item.nativeRecord.data,'base64').toString()]:[]).join('')
  assert.ok(archived.includes('fixture_native_image'))
})

test('concurrent Cursor steering keeps the run owned and Stop responsive until every native input settles',async t=>{
  const workspaceRoot=mkdtempSync(join(tmpdir(),'wm-direct-steer-')),executable=join(workspaceRoot,'fixture.mjs')
  writeFileSync(executable,`#!/usr/bin/env node
import {createInterface} from 'node:readline';const out=v=>process.stdout.write(JSON.stringify(v)+'\\n');let prompts=[];
  createInterface({input:process.stdin}).on('line',line=>{const v=JSON.parse(line);
    if(v.method==='initialize')out({id:v.id,result:{protocolVersion:1}});
    else if(v.method==='session/new')out({id:v.id,result:{sessionId:'cursor_fixture'}});
    else if(v.method==='session/prompt'){prompts.push(v);out({method:'session/update',params:{sessionId:'cursor_fixture',update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:'input '+prompts.length}}}});if(prompts.length===2)out({id:prompts[0].id,result:{stopReason:'end_turn'}});}
    else if(v.method==='session/cancel')for(const p of prompts)out({id:p.id,result:{stopReason:'cancelled'}});
  });`)
  chmodSync(executable,0o700)
  const harness={id:'cursor',transport:'acp',command:executable,arguments:[]},catalog=new Map([['cursor',harness]])
  const relay=createDurableACP({catalog,workspaceRoot,environment:()=>process.env})
  const runtime=createClientExecutionRuntime({defaultAgent:{cancelActive:async()=>{}},durableACP:relay,catalog,workspaceRoot,environment:()=>process.env})
  const service=createClientExecution({directory:join(workspaceRoot,'store'),runtime})
  t.after(async()=>{await service.close();rmSync(workspaceRoot,{recursive:true,force:true})})
  const deviceID=randomUUID(),grant=service.provision({libraryID:randomUUID(),workspaceID:randomUUID(),ownerDeviceID:randomUUID(),deviceID,scopes:['execution']})
  const principal=service.principal('Bearer '+grant.token,'execution'),command=(kind,args={})=>({commandID:randomUUID(),deviceID,kind,...args})
  const opened=await service.command(command('createSession',{runtimeKind:'cursor'}),principal)
  assert.equal(opened.status,'completed',JSON.stringify(opened))
  const input=command('send',{conversationID:opened.conversationID,text:'first'}),sent=await service.command(input,principal)
  await until(()=>service.transcript(opened.conversationID),value=>value.messages.some(item=>item.content==='input 1'))
  const steered=await service.command(command('steer',{conversationID:opened.conversationID,runID:sent.runID,text:'second'}),principal)
  assert.equal(steered.status,'completed')
  await until(()=>service.transcript(opened.conversationID),value=>value.messages.some(item=>item.content.includes('input 2')))
  assert.equal(service.receipt(input.commandID,deviceID).status,'accepted')
  const stopped=await service.command(command('stop',{conversationID:opened.conversationID,runID:sent.runID}),principal)
  assert.equal(stopped.status,'completed')
  await until(()=>service.receipt(input.commandID,deviceID),value=>value.status==='completed')
  assert.equal(service.transcript(opened.conversationID).activeRunID,undefined)
  const unfinished=command('send',{conversationID:opened.conversationID,text:'third'})
  await service.command(unfinished,principal)
  await until(()=>service.transcript(opened.conversationID),value=>value.messages.some(item=>item.content==='input 3'))
  let timer
  try {await Promise.race([runtime.close(),new Promise((_,reject)=>{timer=setTimeout(()=>reject(new Error('shutdown stalled on a native request')),2000)})])}
  finally {clearTimeout(timer)}
  await until(()=>service.receipt(unfinished.commandID,deviceID),value=>value.status==='outcomeUnknown')
})
