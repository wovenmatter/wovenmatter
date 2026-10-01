import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { readFile } from 'node:fs/promises'
import { resolve, isAbsolute } from 'node:path'
import { randomUUID } from 'node:crypto'
import { supportedOpenCodeVersion } from './workspace-instances.mjs'

const before = text => Object.assign(new Error(text), { beforePrompt: true })
const approval = () => Object.assign(new Error('This task needs approval. Open its session to continue.'), { needsApproval: true })
const parseRegistration = bytes => { try { return JSON.parse(String(bytes)) } catch { throw before('The native service registration is invalid.') } }
const pause = ms => new Promise(done => setTimeout(done, ms))
const textUpdate = text => ({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } })
const prompt = run => '[Woven Matter background task: use native workspace tools with the saved permissions. Mac notes, calendar, and other Woven Matter tools are unavailable while the Mac is disconnected.]\n\n' + run.task.prompt
const deferred = () => { let resolve, reject; const promise = new Promise((a,b)=>{resolve=a;reject=b}); promise.catch(()=>{}); return {promise,resolve,reject} }

export function createNativeTaskExecutor({workspaceRoot, environment, launch = spawn, hermes, instances, fetchRequest = fetch, WebSocketClass = WebSocket, read = readFile}) {
  return async context => {
    const config = context.run.task.configuration
    const cwd = config.nativeWorkingDirectory ?? workspaceRoot
    if (!isAbsolute(cwd) || cwd.includes('\0')) throw before('The task working directory is invalid.')
    if (context.signal.aborted) throw before('Background execution was turned off.')
    if (config.runtimeKind === 'pi') return runPi({...context,config,cwd,environment,launch})
    if (config.runtimeKind === 'hermes') return runHermes({...context,config,cwd,environment,hermes,read,WebSocketClass})
    if (config.runtimeKind === 'opencode') return runOpenCode({...context,config,cwd,instances,read,fetchRequest})
    throw before('This native agent is not supported.')
  }
}

async function runPi({run,config,cwd,environment,launch,nativeSessionID,signal,publish,bindSession}) {
  if (config.permission) throw before('Pi does not support the saved permission selection.')
  const env = {...environment(), WOVENMATTER_LOCAL_PI:'1'}
  for (const key of Object.keys(env)) if (key.startsWith('WOVENMATTER_SESSION_') || key.startsWith('WOVENMATTER_TOOL_')) delete env[key]
  const child = launch('pi',['--mode','rpc',...(nativeSessionID?['--session',nativeSessionID]:[])],{cwd,env,stdio:['pipe','pipe','pipe']})
  const pending = new Map(), finished = deferred()
  let accepted=false, exited=false, serial=0, outputBytes=0, needsApproval=false, turnFailed=false
  const send = object => child.stdin.write(JSON.stringify(object)+'\n')
  const fail = error => { for (const entry of pending.values()) {clearTimeout(entry.timer);entry.reject(error)}; pending.clear(); finished.reject(error) }
  const rpc = (type, params={}) => new Promise((resolve,reject)=>{
    const id=String(++serial), timer=setTimeout(()=>{pending.delete(id);reject(new Error('Pi did not acknowledge the task operation.'))},30000)
    pending.set(id,{resolve,reject,timer}); send({id,type,...params})
  })
  const lines=createInterface({input:child.stdout})
  const receiveLine = line => {
    outputBytes+=Buffer.byteLength(line)
    if(outputBytes>64*1024*1024 || line.length>1048576) {fail(new Error('The task exceeded its response limit.'));child.kill('SIGTERM');return}
    let value;try{value=JSON.parse(line)}catch{return}
    if (!value || typeof value !== 'object' || Array.isArray(value)) return
    if(value.type==='response' && pending.has(value.id)) {
      const entry=pending.get(value.id);pending.delete(value.id);clearTimeout(entry.timer)
      if(value.success===false) entry.reject(new Error('Pi rejected the saved task configuration or prompt.'))
      else entry.resolve(value.data ?? {})
    } else if(value.type==='message_update' && accepted) {
      const update=value.assistantMessageEvent
      if(update?.type==='text_delta') publish(textUpdate(update.delta ?? ''))
      if(update?.type==='error')turnFailed=true
      if(update?.type==='thinking_delta') publish({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:update.delta ?? ''}})
    } else if(value.type==='message_end' && accepted) {
      if(value.message?.errorMessage || ['error','aborted'].includes(value.message?.stopReason))turnFailed=true
    } else if(value.type==='extension_ui_request') {
      needsApproval=true;send({type:'extension_ui_response',id:value.id,cancelled:true})
    } else if(value.type==='agent_settled' && accepted) {
      if(needsApproval)finished.reject(approval());else if(turnFailed)finished.reject(new Error('Pi could not complete this task.'));else finished.resolve({stopReason:'end_turn'})
    }
  }
  lines.on('line', line => {
    try { receiveLine(line) }
    catch {
      fail(new Error('The task output could not be retained.'))
      child.kill('SIGTERM')
    }
  })
  child.stderr.on('data',()=>{})
  child.stdin.on('error',()=>fail(new Error('Pi input connection closed.')))
  child.on('error',()=>fail(new Error('Pi could not be started.')))
  child.on('exit',()=>{exited=true;fail(new Error('Pi stopped before completing the task.'))})
  const abort=()=>{try{send({type:'abort'})}catch{};child.kill('SIGTERM');fail(new Error('Background execution was turned off.'))}
  signal.addEventListener('abort',abort,{once:true})
  try {
    let state=await rpc('get_state')
    if(config.model) {
      const split=config.model.indexOf('/'); if(split<1)throw before('The saved Pi model is invalid.')
      await rpc('set_model',{provider:config.model.slice(0,split),modelId:config.model.slice(split+1)})
    }
    if(config.thinking)await rpc('set_thinking_level',{level:config.thinking})
    state=await rpc('get_state')
    if(config.model && `${state.model?.provider}/${state.model?.id}`!==config.model)throw before('Pi did not confirm the saved model.')
    if(config.thinking && state.thinkingLevel!==config.thinking)throw before('Pi did not confirm the saved thinking level.')
    const id=state.sessionId ?? state.session_id
    if(!id || (nativeSessionID && id!==nativeSessionID))throw before('Pi did not confirm the recurring session identity.')
    bindSession(id)
    if(signal.aborted)throw before('Background execution was turned off.')
    accepted=true;await rpc('prompt',{message:prompt(run)})
    return await finished.promise
  } catch(error) {if(!accepted)error.beforePrompt=true;throw error}
  finally {
    signal.removeEventListener('abort',abort);lines.close();fail(new Error('Pi task connection closed.'));child.kill('SIGTERM')
    if(!exited){await Promise.race([new Promise(done=>child.once('exit',done)),pause(1500)]);if(!exited)child.kill('SIGKILL')}
  }
}

async function runHermes({run,config,cwd,environment,hermes,read,WebSocketClass,nativeSessionID,signal,publish,bindSession}) {
  if(config.permission && !['default','full'].includes(config.permission))throw before('The saved Hermes permission is unavailable.')
  let accepted=false, socket, heartbeat, liveID, serial=0, needsApproval=false, text='', lastSeq=0
  const finished=deferred(), pending=new Map()
  const fail=error=>{for(const entry of pending.values()){clearTimeout(entry.timer);entry.reject(error)};pending.clear();finished.reject(error)}
  let send, rpc
  try {
    await hermes.start()
    const home=environment().HERMES_HOME ?? resolve(environment().HOME,'.hermes')
    const registration=parseRegistration(await read(resolve(home,'.woven-matter/service.json'),'utf8'))
    if(!Number.isInteger(registration.port)||registration.port<1||registration.port>65535||typeof registration.token!=='string'||!registration.token)throw before('Hermes service registration is unavailable.')
    socket=new WebSocketClass(`ws://127.0.0.1:${registration.port}/api/ws?token=${encodeURIComponent(registration.token)}`)
    send=object=>socket.send(JSON.stringify(object))
    rpc=(method,params={})=>new Promise((resolve,reject)=>{const id=String(++serial),timer=setTimeout(()=>{pending.delete(id);reject(new Error('Hermes did not acknowledge the task operation.'))},30000);pending.set(id,{resolve,reject,timer});send({jsonrpc:'2.0',id,method,params})})
    const receiveEvent = event => {
      for(const line of String(event.data).split('\n')) {
        let value;try{value=JSON.parse(line)}catch{continue}
        if (!value || typeof value !== 'object' || Array.isArray(value)) continue
        if(value.id!=null && value.method) {needsApproval=true;send({jsonrpc:'2.0',id:value.id,result:{choice:'deny',cancelled:true}});finished.reject(approval());continue}
        if(pending.has(value.id)) {const entry=pending.get(value.id);pending.delete(value.id);clearTimeout(entry.timer);value.error?entry.reject(new Error('Hermes rejected the saved task settings or prompt.')):entry.resolve(value.result);continue}
        const event=value.params
        if(value.method!=='event'||event?.session_id!==liveID||!accepted)continue
        if(event.seq!=null){if(event.seq<=lastSeq)continue;lastSeq=event.seq}
        const payload=event.payload ?? {}
        if(['approval.request','clarify.request','sudo.request','secret.request'].includes(event.type)){needsApproval=true;if(event.type==='approval.request')void rpc('approval.respond',{session_id:liveID,request_id:payload.request_id,choice:'deny'}).catch(()=>{});finished.reject(approval());continue}
        if(event.type==='message.delta'){text+=payload.text??'';publish(textUpdate(payload.text??''))}
        if(['thinking.delta','reasoning.delta'].includes(event.type))publish({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:payload.text??''}})
        if(event.type==='message.complete') {
          if(!text && payload.text)publish(textUpdate(payload.text))
          if(needsApproval)finished.reject(approval())
          else if(payload.status==='error')finished.reject(new Error('Hermes could not complete this task.'))
          else finished.resolve({stopReason:payload.status==='interrupted'?'cancelled':'end_turn'})
        }
      }
    }
    socket.addEventListener('message', event => {
      try { receiveEvent(event) }
      catch { fail(new Error('The task output could not be retained.')) }
    })
    socket.addEventListener('close',()=>fail(new Error('Hermes disconnected before the task completed.')))
    socket.addEventListener('error',()=>fail(new Error('Hermes connection failed.')))
    await Promise.race([new Promise((done,reject)=>{socket.addEventListener('open',done,{once:true});socket.addEventListener('error',()=>reject(before('Hermes connection failed.')),{once:true})}),new Promise((_,reject)=>setTimeout(()=>reject(before('Hermes connection timed out.')),10000).unref())])
    heartbeat=setInterval(()=>void rpc('ping').catch(()=>fail(new Error('Hermes connection was interrupted.'))),15000);heartbeat.unref()
    const profile=await rpc('config.get',{key:'profile'})
    if(profile.home!==home)throw before('Hermes connected to a different profile.')
    const identityHome=config.workspaceID?'/remote-workspaces/'+config.workspaceID.toLowerCase()+home:home
    let previous=nativeSessionID
    if(previous?.startsWith('hermes-gateway:')||previous?.startsWith('hermes-import:')) {
      const parts=previous.split(':');if(Buffer.from(parts[1],'base64').toString()!==identityHome)throw before('This Hermes task belongs to another profile.');previous=parts.slice(2).join(':')
    }
    const session=await rpc(previous?'session.resume':'session.create',{source:'desktop',close_on_disconnect:false,cwd,title:run.title,...(previous?{session_id:previous,defer_history:true}:{})})
    if(session.running)throw before('The recurring Hermes task is already running.')
    liveID=session.session_id
    const stored=previous??session.stored_session_id??session.session_key
    if(!liveID||!stored)throw before('Hermes did not return a durable session.')
    bindSession(`hermes-gateway:${Buffer.from(identityHome).toString('base64')}:${stored}`)
    const replay = await rpc('session.events.since',{session_id:liveID,last_seen:0})
    lastSeq = replay.latest_seq ?? 0
    await rpc('session.cwd.set',{session_id:liveID,cwd})
    for(const [key,value] of [['model',config.model],['reasoning',config.thinking]])if(value){const result=await rpc('config.set',{session_id:liveID,key,value,scope:'session'});if(result.confirm_required)throw before('Hermes requires confirmation for this model.');const confirmed=await rpc('config.get',{session_id:liveID,key});if((confirmed.value??confirmed[key])!==value)throw before(`Hermes did not confirm the saved ${key}.`)}
    if(config.permission){const value=config.permission==='full'?'1':'0';const confirmed=await rpc('config.set',{session_id:liveID,key:'yolo',value,scope:'session'});if(confirmed.scope!=='session'||String(confirmed.value)!==value)throw before('Hermes did not confirm the saved permission.');const state=await rpc('session.activate',{session_id:liveID,omit_messages:true});if(config.permission==='default'&&(state.info?.approval_mode==='off'||state.info?.yolo===true))throw before('Hermes cannot apply the requested approval policy.')}
    const abort=()=>{void rpc('session.interrupt',{session_id:liveID}).catch(()=>{});finished.reject(new Error('Background execution was turned off.'))}
    signal.addEventListener('abort',abort,{once:true})
    try {if(signal.aborted)throw before('Background execution was turned off.');accepted=true;await rpc('prompt.submit',{session_id:liveID,text:prompt(run)});return await finished.promise}
    finally {signal.removeEventListener('abort',abort)}
  } catch(error){if(accepted&&liveID&&rpc)try{await rpc('session.interrupt',{session_id:liveID})}catch{};if(!accepted)error.beforePrompt=true;throw error}
  finally {clearInterval(heartbeat);fail(new Error('Hermes task connection closed.'));socket?.close()}
}

async function runOpenCode({run,config,cwd,instances,read,fetchRequest,nativeSessionID,signal,publish,bindSession}) {
  const permission=config.permission==='auto'?'full':config.permission??'normal'
  if(!['normal','acceptEdits','full'].includes(permission))throw before('The saved OpenCode permission is unavailable.')
  let accepted=false,sessionID=nativeSessionID,call
  try {
    await instances.action('opencode','start')
    const registration=parseRegistration(await read(instances.registrationPath,'utf8')),origin=new URL(registration.url)
    if(origin.protocol!=='http:'||!['127.0.0.1','localhost','[::1]'].includes(origin.hostname)||origin.username||origin.password||origin.pathname!=='/'||origin.search||origin.hash||typeof registration.password!=='string'||!registration.password)throw before('OpenCode service registration is unavailable.')
    const headers={authorization:`Basic ${Buffer.from('opencode:'+registration.password).toString('base64')}`,'content-type':'application/json'}
    call=async(method,path,body,ignoreAbort=false)=>{const result=await fetchRequest(new URL(path,origin),{method,headers,body:body==null?undefined:JSON.stringify(body),redirect:'error',signal:ignoreAbort?AbortSignal.timeout(5000):AbortSignal.any([signal,AbortSignal.timeout(30000)])});if(!result.ok)throw new Error('OpenCode could not complete the task operation.');if(result.status===204)return {};return result.json()}
    const health=await call('GET','/api/health')
    if(health.pid!==registration.pid||health.version!==supportedOpenCodeVersion||health.healthy!==true)throw before('OpenCode service identity changed.')
    sessionID??='ses_'+randomUUID().replaceAll('-','')
    let session=(await call(nativeSessionID?'GET':'POST',nativeSessionID?`/api/session/${encodeURIComponent(sessionID)}`:'/api/session',nativeSessionID?undefined:{id:sessionID,title:run.title,location:{directory:cwd,...(config.nativeWorkspaceID?{workspaceID:config.nativeWorkspaceID}:{})},metadata:{wovenmatter:{origin:'created'}}})).data
    if(session?.id!==sessionID)throw before('OpenCode did not confirm the recurring session identity.')
    const path='/api/session/'+encodeURIComponent(sessionID)
    bindSession(sessionID)
    if(config.model||config.thinking){const model=config.model??[session.model?.providerID,session.model?.id].filter(Boolean).join('/'),split=model.indexOf('/');if(split<1)throw before('The saved OpenCode model is invalid.');const selection={providerID:model.slice(0,split),id:model.slice(split+1),...(config.thinking&&config.thinking!=='default'?{variant:config.thinking}:{})};await call('POST',path+'/model',{model:selection});session=(await call('GET',path)).data;if(session.model?.id!==selection.id||session.model?.providerID!==selection.providerID||(session.model?.variant??'default')!==(selection.variant??'default'))throw before('OpenCode did not confirm the saved model and thinking level.')}
    const messageID='msg_'+run.id.replaceAll(/[^a-zA-Z0-9]/g,'')
    const baseline=new Set(((await call('GET',path+'/message?limit=100&order=desc')).data??[]).map(x=>x.id))
    const active=(await call('GET','/api/session/active')).data??{}
    if(active[sessionID])throw before('The recurring OpenCode task is already running.')
    if(signal.aborted)throw before('Background execution was turned off.')
    accepted=true
    const receipt=await call('POST',path+'/prompt',{id:messageID,text:prompt(run),files:[]})
    if(receipt.data?.id!==messageID)throw new Error('OpenCode did not acknowledge the task prompt. Check its session before retrying.')
    let observed=false
    for(let checks=0;checks<86400;checks++) {
      const permissions=(await call('GET',path+'/permission')).data??[]
      for(const request of permissions){const action=request.action??'',category=action.toLowerCase().split(/[.:/_-]/)[0];const allowed=request.sessionID===sessionID&&request.id?.startsWith('per')&&Array.isArray(request.resources)&&request.resources.every(x=>typeof x==='string')&&request.effect!=='deny'&&(!request.type||request.type==='permission')&&(!request.source?.type||request.source.type==='tool')&&!['auth','authenticate','authentication','login','oauth','credential','credentials','secret','secrets','form','question','questions','ask','askuser','userinput'].includes(category)&&(permission==='full'||permission==='acceptEdits'&&action==='edit');if(!allowed)throw approval();await call('POST',path+'/permission/'+encodeURIComponent(request.id)+'/reply',{reply:'once'})}
      if(((await call('GET',path+'/form')).data??[]).length)throw approval()
      const messages=(await call('GET',path+'/message?limit=100&order=desc')).data??[]
      const incoming=messages.filter(x=>!baseline.has(x.id)&&x.id!==messageID&&(x.type==='assistant'||x.role==='assistant'||x.info?.role==='assistant'))
      if(incoming.length)observed=true
      const running=(await call('GET','/api/session/active')).data??{}
      if(!running[sessionID]&&observed){for(const message of incoming.reverse())for(const part of message.content??message.parts??[]){if(part.type==='text'&&part.text)publish(textUpdate(part.text));if(part.type==='reasoning'&&part.text)publish({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:part.text}});}if(incoming.some(message=>message.error || message.info?.error))throw new Error('OpenCode could not complete this task.');return {stopReason:'end_turn'}}
      await pause(250)
    }
    throw new Error('OpenCode task exceeded its runtime limit.')
  } catch(error){if(accepted&&sessionID&&call)try{await call('POST','/api/session/'+encodeURIComponent(sessionID)+'/interrupt',{},true)}catch{};if(!accepted)error.beforePrompt=true;throw error}
}
