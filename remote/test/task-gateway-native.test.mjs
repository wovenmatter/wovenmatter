import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { PassThrough, Writable } from 'node:stream'
import { createNativeTaskExecutor } from '../src/task-gateway-native.mjs'
import { supportedOpenCodeVersion } from '../src/workspace-instances.mjs'

const base = runtimeKind => ({run:{id:'run-1',title:'Fixture',task:{prompt:'fixture only',configuration:{runtimeKind,tools:{}}}},nativeSessionID:null,signal:new AbortController().signal,publish:()=>{},bindSession:()=>{}})
const options = {workspaceRoot:'/workspace',environment:()=>({HOME:'/home'})}

test('Pi applies and confirms model/thinking before a single prompt, preserving recurring identity',async()=>{
  const calls=[],updates=[],ids=[]
  const launch=(_command,args)=>{
    assert.deepEqual(args,['--mode','rpc','--session','pi-session'])
    const child=new EventEmitter();child.stdout=new PassThrough();child.stderr=new PassThrough()
    let model={provider:'lab',id:'model'},thinkingLevel='low'
    child.stdin=new Writable({write(bytes,_encoding,done){const command=JSON.parse(String(bytes));calls.push(command.type);let data={};if(command.type==='get_state'){data={sessionId:'pi-session',model,thinkingLevel};child.stdout.write(JSON.stringify({type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'old'}})+'\n');child.stdout.write('{"type":"agent_settled"}\n')};if(command.type==='set_model')model={provider:command.provider,id:command.modelId};if(command.type==='set_thinking_level')thinkingLevel=command.level;child.stdout.write(JSON.stringify({type:'response',id:command.id,success:true,data})+'\n');if(command.type==='prompt'){child.stdout.write(JSON.stringify({type:'message_update',assistantMessageEvent:{type:'text_delta',delta:'done'}})+'\n');child.stdout.write('{"type":"agent_settled"}\n')}done()}})
    child.kill=()=>{child.emit('exit',0);return true};return child
  }
  const context=base('pi');context.nativeSessionID='pi-session';context.run.task.configuration.model='lab/next';context.run.task.configuration.thinking='high';context.publish=x=>updates.push(x);context.bindSession=x=>ids.push(x)
  const result=await createNativeTaskExecutor({...options,launch})(context)
  assert.equal(result.stopReason,'end_turn');assert.equal(calls.filter(x=>x==='prompt').length,1)
  assert.ok(calls.indexOf('set_thinking_level')<calls.indexOf('prompt'));assert.deepEqual(ids,['pi-session']);assert.equal(updates[0].content.text,'done')
})

test('native unsupported saved permission fails before spawning or submitting',async()=>{
  let launched=false
  const context=base('pi');context.run.task.configuration.permission='full'
  await assert.rejects(createNativeTaskExecutor({...options,launch:()=>{launched=true}})(context),error=>error.beforePrompt===true)
  assert.equal(launched,false)
})

test('OpenCode preserves existing session, checks selection and projects completed native response',async()=>{
  const calls=[],updates=[];let selected={providerID:'lab',id:'old'},submitted=false
  const fetchRequest=async(url,request)=>{
    calls.push([request.method,url.pathname]);assert.equal(request.headers.authorization,'Basic '+Buffer.from('opencode:fixture').toString('base64'))
    let data={}
    if(url.pathname==='/api/health')data={healthy:true,pid:42,version:supportedOpenCodeVersion}
    else if(url.pathname==='/api/session/ses_fixture/model'){selected=JSON.parse(request.body).model}
    else if(url.pathname==='/api/session/ses_fixture')data={data:{id:'ses_fixture',model:selected}}
    else if(url.pathname.endsWith('/message'))data={data:submitted?[{id:'msg_answer',type:'assistant',content:[{type:'text',text:'result'}]}]:[]}
    else if(url.pathname.endsWith('/prompt')){submitted=true;data={data:{id:JSON.parse(request.body).id}}}
    else if(url.pathname==='/api/session/active')data={data:{}}
    else if(url.pathname.endsWith('/permission')||url.pathname.endsWith('/form'))data={data:[]}
    else throw Error('unexpected '+url.pathname)
    return {ok:true,status:200,json:async()=>data}
  }
  const context=base('opencode');context.nativeSessionID='ses_fixture';context.run.task.configuration.model='lab/new';context.run.task.configuration.thinking='high';context.publish=x=>updates.push(x)
  await createNativeTaskExecutor({...options,instances:{action:async()=>{},registrationPath:'/private/fixture'},read:async()=>JSON.stringify({url:'http://127.0.0.1:4000',password:'fixture',pid:42}),fetchRequest})(context)
  assert.equal(calls.filter(x=>x[1].endsWith('/prompt')).length,1);assert.equal(updates[0].content.text,'result');assert.deepEqual(selected,{providerID:'lab',id:'new',variant:'high'})
})

test('OpenCode rejects identity mismatch before prompt',async()=>{
  const context=base('opencode');let prompts=0
  await assert.rejects(createNativeTaskExecutor({...options,instances:{action:async()=>{},registrationPath:'fixture'},read:async()=>JSON.stringify({url:'http://127.0.0.1:4000',password:'fixture',pid:42}),fetchRequest:async(url)=>{if(url.pathname.endsWith('/prompt'))prompts++;return {ok:true,status:200,json:async()=>({healthy:true,pid:99,version:supportedOpenCodeVersion})}}})(context),error=>error.beforePrompt===true)
  assert.equal(prompts,0)
})

test('Hermes reuses durable session, confirms model and settles without interactive approval',async()=>{
  const calls=[],updates=[],bound=[]
  class FixtureSocket extends EventTarget {
    constructor(){super();queueMicrotask(()=>this.dispatchEvent(new Event('open')))}
    send(bytes){const frame=JSON.parse(bytes);calls.push(frame.method);let result={};if(frame.method==='config.get')result=frame.params.key==='profile'?{home:'/home/.hermes'}:{value:'model'};if(frame.method==='session.resume')result={session_id:'runtime',stored_session_id:'stored',running:false};if(frame.method==='session.events.since')result={latest_seq:5};queueMicrotask(()=>{if(frame.method==='config.set')this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({method:'event',params:{session_id:'runtime',seq:1,type:'message.complete',payload:{text:'old',status:'success'}}})}));this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({id:frame.id,result})}));if(frame.method==='prompt.submit')this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({method:'event',params:{session_id:'runtime',seq:6,type:'message.complete',payload:{text:'finished',status:'success'}}})}))})}
    close(){}
  }
  const context=base('hermes');context.nativeSessionID='stored';context.run.task.configuration.model='model';context.publish=x=>updates.push(x);context.bindSession=x=>bound.push(x)
  await createNativeTaskExecutor({...options,hermes:{start:async()=>{}},read:async()=>JSON.stringify({port:4000,token:'fixture'}),WebSocketClass:FixtureSocket})(context)
  assert.equal(calls.filter(x=>x==='prompt.submit').length,1);assert.ok(calls.indexOf('config.set')<calls.indexOf('prompt.submit'));assert.equal(updates[0].content.text,'finished');assert.match(bound[0],/^hermes-gateway:/)
})

test('OpenCode approval policy never auto-approves authentication and interrupts the task',async()=>{
  const context=base('opencode');context.nativeSessionID='ses_fixture';context.run.task.configuration.permission='full'
  let interrupted=false,replied=false,submitted=false
  const fetchRequest=async(url,request)=>{
    let data={data:[]}
    if(url.pathname==='/api/health')data={healthy:true,pid:42,version:supportedOpenCodeVersion}
    else if(url.pathname==='/api/session/ses_fixture')data={data:{id:'ses_fixture'}}
    else if(url.pathname==='/api/session/active')data={data:{}}
    else if(url.pathname.endsWith('/prompt')){submitted=true;data={data:{id:JSON.parse(request.body).id}}}
    else if(url.pathname.endsWith('/permission'))data={data:[{sessionID:'ses_fixture',id:'per_auth',action:'oauth',resources:[]}]}
    else if(url.pathname.endsWith('/reply'))replied=true
    else if(url.pathname.endsWith('/interrupt'))interrupted=true
    return {ok:true,status:200,json:async()=>data}
  }
  await assert.rejects(createNativeTaskExecutor({...options,instances:{action:async()=>{},registrationPath:'fixture'},read:async()=>JSON.stringify({url:'http://127.0.0.1:4000',password:'fixture',pid:42}),fetchRequest})(context),error=>error.needsApproval===true&&!error.beforePrompt)
  assert.equal(submitted,true);assert.equal(replied,false);assert.equal(interrupted,true)
})


test('Pi output persistence failures stop the child and remain inside the task result', async () => {
  let killed = false
  const launch = () => {
    const child = new EventEmitter()
    child.stdout = new PassThrough(); child.stderr = new PassThrough()
    child.kill = () => { killed = true; queueMicrotask(() => child.emit('exit', 0)); return true }
    child.stdin = new Writable({ write(bytes, _encoding, done) {
      const request = JSON.parse(String(bytes))
      setImmediate(() => {
        child.stdout.write(JSON.stringify({ type: 'response', id: request.id, success: true, data: { sessionId: 'native' } }) + '\n')
        if (request.type === 'prompt') {
          child.stdout.write('null\n')
          child.stdout.write(JSON.stringify({ type: 'message_update', assistantMessageEvent: { type: 'text_delta', delta: 'hello' } }) + '\n')
        }
      })
      done()
    } })
    return child
  }
  const context = base('pi')
  context.publish = () => { throw new Error('fixture journal failure') }
  await assert.rejects(createNativeTaskExecutor({ ...options, launch })(context), /output could not be retained/)
  assert.equal(killed, true)
})
