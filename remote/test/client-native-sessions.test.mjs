import test from 'node:test'
import assert from 'node:assert/strict'
import { createNativeClientSessions } from '../src/client-native-sessions.mjs'

const options={workspaceRoot:'/workspace',environment:()=>({HOME:'/home'})}
function openCodeFixture() {
  const calls=[],session={id:'ses_fixture',location:{directory:'/workspace/project'},model:{providerID:'lab',id:'model'},permissions:[]}
  let busy=false
  const control=createNativeClientSessions({...options,instances:{action:async()=>{},registrationPath:'fixture'},read:async()=>JSON.stringify({url:'http://127.0.0.1:4000',password:'fixture',pid:42}),fetchRequest:async(url,request)=>{
    assert.equal(request.headers.authorization,'Basic '+Buffer.from('opencode:fixture').toString('base64'))
    assert.equal(request.redirect,'error')
    const body=request.body&&JSON.parse(request.body);calls.push({path:url.pathname,method:request.method,body})
    let value
    if(url.pathname==='/api/info')value={pid:42,version:'2.0.22'}
    else if(url.pathname==='/api/session/active')value={data:busy?{ses_fixture:{}}:{}}
    else if(url.pathname==='/api/session/ses_fixture/model'){session.model=body.model;value={}}
    else if(url.pathname==='/api/session/ses_fixture'){if(request.method==='PATCH')session.permissions=body.permissions;value={data:session}}
    else if(url.pathname==='/api/model')value={data:[{providerID:'lab',id:'model',name:'Fixture model',enabled:true,variants:[{id:'high',name:'High'}]},{providerID:'hidden',id:'model',enabled:false}]}
    else if(url.pathname==='/api/model/default')value={data:{providerID:'lab',id:'model'}}
    else assert.fail('Unexpected operation '+url.pathname)
    return {ok:true,status:200,json:async()=>structuredClone(value)}
  }})
  return {control,calls,session,setBusy:value=>{busy=value}}
}

test('OpenCode adoption verifies idle identity and settings retain the native policy',async()=>{
  const f=openCodeFixture(),native={sessionID:'ses_fixture'}
  f.setBusy(true);await assert.rejects(f.control.perform('opencode',native,'adopt'),/not idle/)
  f.setBusy(false);const adopted=await f.control.perform('opencode',native,'adopt')
  assert.equal(adopted.nativeWorkingDirectory,'/workspace/project')
  const initial=await f.control.perform('opencode',adopted,'settings')
  assert.deepEqual(initial.models,[{id:'lab/model',label:'Fixture model'}])
  assert.equal(initial.canConfigure,true)
  const settings=await f.control.perform('opencode',adopted,'configure',{model:'lab/model',thinking:'high',permission:'deny'})
  assert.equal(settings.thinking,'high');assert.equal(settings.permission,'deny')
  assert.deepEqual(f.session.permissions,[{action:'*',resource:'*',effect:'deny'}])
  await assert.rejects(f.control.perform('opencode',adopted,'configure',{model:'missing/model'}),/available OpenCode model/)
  assert.ok(!f.calls.some(call=>call.path.endsWith('/prompt')))
})

function hermesFixture() {
  const calls=[],state={model:'fixture --provider lab',reasoning:'medium',yolo:false,mode:'manual',busy:false}
  class Socket extends EventTarget {
    constructor(){super();queueMicrotask(()=>this.dispatchEvent(new Event('open')))}
    close(){}
    send(bytes) {
      const frame=JSON.parse(bytes);calls.push(frame);const p=frame.params
      let result
      if(frame.method==='config.get')result=p.key==='profile'?{home:'/home/.hermes'}:{value:state[p.key]}
      else if(frame.method==='session.resume')result={session_id:'live',stored_session_id:'stored',running:state.busy}
      else if(frame.method==='session.activate')result={session_id:'live',info:{yolo:state.yolo,approval_mode:state.mode}}
      else if(frame.method==='model.options')result={model:'fixture',provider:'lab',providers:[{slug:'lab',models:['fixture'],capabilities:{fixture:{reasoning:true}}}]}
      else if(frame.method==='config.set'){state[p.key]=p.key==='yolo'?p.value==='1':p.value;result={scope:'session',value:p.value}}
      else assert.fail('Unexpected Hermes method '+frame.method)
      queueMicrotask(()=>this.dispatchEvent(new MessageEvent('message',{data:JSON.stringify({id:frame.id,result})})))
    }
  }
  const control=createNativeClientSessions({...options,hermes:{start:async()=>{}},WebSocketClass:Socket,read:async()=>JSON.stringify({port:4000,token:'fixture'})})
  return {control,calls,state}
}

test('Hermes idle adoption validates profile and configures only per-session settings',async()=>{
  const f=hermesFixture(),workspaceID='00000000-0000-0000-0000-000000000001',home='/remote-workspaces/'+workspaceID+'/home/.hermes'
  const native={workspaceID,sessionID:'hermes-gateway:'+Buffer.from(home).toString('base64')+':stored'}
  f.state.busy=true;await assert.rejects(f.control.perform('hermes',native,'adopt'),/not idle/)
  f.state.busy=false;assert.equal((await f.control.perform('hermes',native,'adopt')).sessionID,native.sessionID)
  const initial=await f.control.perform('hermes',native,'settings')
  assert.equal(initial.model,'fixture --provider lab');assert.equal(initial.permission,'default')
  const changed=await f.control.perform('hermes',native,'configure',{model:'fixture --provider lab',thinking:'high',permission:'full'})
  assert.equal(changed.thinking,'high');assert.equal(changed.permission,'full')
  f.state.mode='off';await assert.rejects(f.control.perform('hermes',native,'configure',{permission:'default'}),/profile forces/)
  await assert.rejects(f.control.perform('hermes',{...native,workspaceID:'another'},'adopt'),/another workspace profile/)
  assert.ok(f.calls.filter(call=>call.method==='config.set').every(call=>call.params.scope==='session'))
  assert.ok(!f.calls.some(call=>call.method==='prompt.submit'))
})
