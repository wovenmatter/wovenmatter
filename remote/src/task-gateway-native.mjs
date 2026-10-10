import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { readFile } from 'node:fs/promises'
import { resolve, isAbsolute } from 'node:path'
import { randomUUID, createHash } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { supportsOpenCodeVersion } from './opencode-compatibility.mjs'
import { createTaskNativeArchive, piRunEvent, hermesRunEvent, publishNativePresentation, isolateTaskEnvironment } from './task-native-archive.mjs'

const before = text => Object.assign(new Error(text), { beforePrompt: true })
const approval = () => Object.assign(new Error('This task needs approval. Open its session to continue.'), { needsApproval: true })
const parseRegistration = bytes => { try { return JSON.parse(String(bytes)) } catch { throw before('The native service registration is invalid.') } }
const pause = ms => new Promise(done => setTimeout(done, ms))
const textUpdate = text => ({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text } })
const prompt = run => run.task.prompt
const deferred = () => { let resolve, reject; const promise = new Promise((a,b)=>{resolve=a;reject=b}); promise.catch(()=>{}); return {promise,resolve,reject} }

export function createNativeTaskExecutor({workspaceRoot, environment, launch = spawn, hermes, instances, fetchRequest = fetch, WebSocketClass = WebSocket, read = readFile}) {
  return async context => {
    const config = context.run.task.configuration
    const cwd = config.nativeWorkingDirectory ?? workspaceRoot
    if (!isAbsolute(cwd) || cwd.includes('\0')) throw before('The task working directory is invalid.')
    if (context.signal.aborted) throw before('Background execution was turned off.')
    if (config.runtimeKind === 'pi') return runPi({...context,config,cwd,environment,launch})
    if (config.runtimeKind === 'hermes') return runHermes({...context,config,cwd,environment,hermes,read,WebSocketClass,fetchRequest})
    if (config.runtimeKind === 'opencode') return runOpenCode({...context,config,cwd,instances,read,fetchRequest})
    throw before('This native agent is not supported.')
  }
}

async function runPi({run,config,cwd,environment,launch,nativeSessionID,signal,publish,bindSession}) {
  if (config.permission) throw before('Pi does not support the saved permission selection.')
  const env = {...isolateTaskEnvironment(environment()), WOVENMATTER_LOCAL_PI:'1'}
  const child = launch('pi',['--mode','rpc',...(nativeSessionID?['--session',nativeSessionID]:[])],{cwd,env,stdio:['pipe','pipe','pipe']})
  const pending = new Map(), finished = deferred()
  let accepted=false, exited=false, serial=0, needsApproval=false, turnFailed=false, settled=false, archive
  const send = object => child.stdin.write(JSON.stringify(object)+'\n')
  const fail = error => { for (const entry of pending.values()) {clearTimeout(entry.timer);entry.reject(error)}; pending.clear(); finished.reject(error) }
  const rpc = (type, params={}) => new Promise((resolve,reject)=>{
    const id=String(++serial), timer=setTimeout(()=>{pending.delete(id);reject(new Error('Pi did not acknowledge the task operation.'))},30000)
    pending.set(id,{resolve,reject,timer}); send({id,type,...params})
  })
  const lines=createInterface({input:child.stdout})
  const receiveLine = line => {
    let value;try{value=JSON.parse(line)}catch{return}
    if (!value || typeof value !== 'object' || Array.isArray(value)) return
    if (accepted && archive && piRunEvent(value.type)) {
      void archive.capture(value, {kind: value.type, present: safe => {
        const update = safe.assistantMessageEvent
        if (safe.type === 'message_update' && update?.type === 'text_delta') publishNativePresentation(textUpdate(update.delta ?? ''), publish)
        if (safe.type === 'message_update' && update?.type === 'thinking_delta') publishNativePresentation({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:update.delta ?? ''}}, publish)
      }}).catch(error => { fail(error); child.kill('SIGTERM') })
    }
    if(value.type==='response' && pending.has(value.id)) {
      const entry=pending.get(value.id);pending.delete(value.id);clearTimeout(entry.timer)
      if(value.success===false) entry.reject(new Error('Pi rejected the saved task configuration or prompt.'))
      else entry.resolve(value.data ?? {})
    } else if(value.type==='message_update' && accepted) {
      const update=value.assistantMessageEvent
      if(update?.type==='error')turnFailed=true
    } else if(value.type==='message_end' && accepted) {
      if(value.message?.errorMessage || ['error','aborted'].includes(value.message?.stopReason))turnFailed=true
    } else if(value.type==='extension_ui_request') {
      needsApproval=true;send({type:'extension_ui_response',id:value.id,cancelled:true})
    } else if(value.type==='agent_settled' && accepted) {
      settled=true
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
    archive = await createTaskNativeArchive({sourceID: 'pi:' + (state.sessionFile ?? cwd), nativeSessionID: id, runID: run.id, publish})
    const captureEntries = async (currentRun, since) => {
      if (signal.aborted) throw new Error('Background execution was turned off.')
      const snapshot = await rpc('get_entries', since ? {since} : {})
      if (!Array.isArray(snapshot.entries)) throw new Error('Pi returned an incomplete native entry export.')
      const seen = new Set()
      for (const entry of snapshot.entries) {
        if (typeof entry.id !== 'string' || !entry.id || seen.has(entry.id)) throw new Error('Pi returned duplicate or missing native entry identities.')
        seen.add(entry.id)
        await archive.capture(entry, {id: 'entry:' + entry.id, kind: entry.type ?? 'entry', contentMode: 'snapshot', completeness: 'native-export', currentRun})
      }
      return snapshot.entries.at(-1)?.id
    }
    const entryCursor = await captureEntries(false)
    if(signal.aborted)throw before('Background execution was turned off.')
    accepted=true;await rpc('prompt',{message:prompt(run)})
    let result, failure
    try { result = await finished.promise } catch (error) { failure = error }
    if (!settled) throw failure
    await archive.drain()
    await captureEntries(true, entryCursor)
    if (failure) throw failure
    if (signal.aborted) throw new Error('Background execution was turned off.')
    return result
  } catch(error) {if(!accepted)error.beforePrompt=true;throw error}
  finally {
    signal.removeEventListener('abort',abort);lines.close();fail(new Error('Pi task connection closed.'));child.kill('SIGTERM')
    if(!exited){await Promise.race([new Promise(done=>child.once('exit',done)),pause(1500)]);if(!exited)child.kill('SIGKILL')}
    await archive?.close()
  }
}

async function runHermes({run,config,cwd,environment,hermes,read,WebSocketClass,fetchRequest,nativeSessionID,signal,publish,bindSession,interactive}) {
  if(config.permission && !['default','full'].includes(config.permission))throw before('The saved Hermes permission is unavailable.')
  let accepted=false, socket, heartbeat, liveID, serial=0, needsApproval=false, text='', lastSeq=0, archive, epoch, completed=false
  const finished=deferred(), pending=new Map()
  const fail=error=>{for(const entry of pending.values()){clearTimeout(entry.timer);entry.reject(error)};pending.clear();finished.reject(error)}
  let send, rpc
  const requests = new Map()
  function interaction(type,payload,responseID) {
    if (!interactive || !['approval.request','clarify.request'].includes(type)) return false
    const id=String(responseID??payload.request_id??'')
    if(!id)return false
    requests.set(id,{type,payload,responseID})
    const batch=payload.questions?.length?payload.questions:[payload]
    interactive.publish(type==='approval.request'
      ? {id,kind:'approval',title:payload.description??'Hermes needs approval',detail:payload.command,
          options:(payload.choices?.length?payload.choices:['once','deny']).map(id=>({id,label:id})),questions:[]}
      : {id,kind:'question',title:'Hermes question',options:[],questions:batch.map((item,index)=>({id:item.qid??String(index),prompt:item.question??'',options:(item.choices??[]).map(id=>({id,label:id})),allowsMultiple:item.multi_select===true,allowsFreeText:true}))})
    return true
  }
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
        if(value.id!=null && value.method) {if(interaction(value.method,value.params??{},value.id))continue;needsApproval=true;send({jsonrpc:'2.0',id:value.id,result:{choice:'deny',cancelled:true}});finished.reject(approval());continue}
        if(pending.has(value.id)) {const entry=pending.get(value.id);pending.delete(value.id);clearTimeout(entry.timer);value.error?entry.reject(new Error('Hermes rejected the saved task settings or prompt.')):entry.resolve(value.result);continue}
        const event=value.params
        if(value.method!=='event'||event?.session_id!==liveID||!accepted)continue
        if(event.seq!=null){if(event.seq<=lastSeq)continue;lastSeq=event.seq}
        const payload=event.payload ?? {}
        const checklistInTurn = !completed
        const needsFinalText = event.type === 'message.complete' && !text
        if(event.type==='message.delta')text+=payload.text??''
        if (archive && hermesRunEvent(event.type)) {
          void archive.capture(event, {id: event.seq == null ? undefined : `event:${epoch}:${event.seq}`, kind: event.type, present: safe => {
            if (safe.type === 'message.delta' || needsFinalText && safe.payload?.text) publishNativePresentation(textUpdate(safe.payload?.text ?? ''), publish)
            if (['thinking.delta','reasoning.delta'].includes(safe.type)) publishNativePresentation({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:safe.payload?.text ?? ''}}, publish)
            if (interactive && ['tool.start','tool.complete'].includes(safe.type)) publishNativePresentation({sessionUpdate:'tool_call_update',toolCallId:safe.payload?.tool_id,title:safe.payload?.name,status:safe.type==='tool.complete'?(safe.payload?.result?.error?'failed':'completed'):'running',content:[{type:'content',content:{type:'text',text:safe.payload?.result_text??safe.payload?.context??JSON.stringify(safe.payload?.result??safe.payload?.args??{})}}]},publish)
            // Keep the paired native args/result for the shared Mac normalizer.
            if (checklistInTurn && safe.type === 'tool.complete' && ['todo_list','todo'].includes(safe.payload?.name)) {
              const {name,args,result} = safe.payload
              publish({sessionUpdate:'woven_hermes_tool_complete',nativeSessionID:boundID,payload:{name,args,result}})
            }
          }}).catch(error => fail(error))
        }
        if(['approval.request','clarify.request','sudo.request','secret.request'].includes(event.type)){if(interaction(event.type,payload))continue;needsApproval=true;if(event.type==='approval.request')void rpc('approval.respond',{session_id:liveID,request_id:payload.request_id,choice:'deny'}).catch(()=>{});finished.reject(approval());continue}
        if(event.type==='message.complete') {
          completed=true
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
    const resolved = session.stored_session_id ?? session.session_key
    const stored = previous ?? resolved
    if (!liveID || !resolved || !stored || (previous && resolved !== previous && session.resumed !== resolved)) throw before('Hermes did not confirm the durable session.')
    const boundID = `hermes-gateway:${Buffer.from(identityHome).toString('base64')}:${stored}`
    bindSession(boundID)
    archive = await createTaskNativeArchive({sourceID: 'hermes:' + identityHome, nativeSessionID: boundID, runID: run.id, publish})
    const replay = await rpc('session.events.since',{session_id:liveID,last_seen:0})
    lastSeq = replay.latest_seq ?? 0
    epoch = replay.epoch ?? `run:${run.id}`
    await rpc('session.cwd.set',{session_id:liveID,cwd})
    for(const [key,value] of [['model',config.model],['reasoning',config.thinking]])if(value){const result=await rpc('config.set',{session_id:liveID,key,value,scope:'session'});if(result.confirm_required)throw before('Hermes requires confirmation for this model.');const confirmed=await rpc('config.get',{session_id:liveID,key});if((confirmed.value??confirmed[key])!==value)throw before(`Hermes did not confirm the saved ${key}.`)}
    if(config.permission){const value=config.permission==='full'?'1':'0';const confirmed=await rpc('config.set',{session_id:liveID,key:'yolo',value,scope:'session'});if(confirmed.scope!=='session'||String(confirmed.value)!==value)throw before('Hermes did not confirm the saved permission.');const state=await rpc('session.activate',{session_id:liveID,omit_messages:true});if(config.permission==='default'&&(state.info?.approval_mode==='off'||state.info?.yolo===true))throw before('Hermes cannot apply the requested approval policy.')}
    const highWater = new Map()
    const captureSnapshot = async currentRun => {
      for (const target of new Set([stored, resolved])) {
        const response = await fetchRequest(`http://127.0.0.1:${registration.port}/api/sessions/${encodeURIComponent(target)}/export`, {
          headers: {authorization: 'Bearer ' + registration.token}, redirect: 'error',
          signal: AbortSignal.any([signal, AbortSignal.timeout(45000)])})
        if (!response.ok) throw new Error('Hermes could not export the current native session.')
        const snapshot = await response.json()
        if (snapshot.id !== target || !Array.isArray(snapshot.messages)) throw new Error('Hermes returned a different or incomplete native session export.')
        const {messages, ...metadata} = snapshot
        await archive.capture(metadata, {id: `session:${target}:export.metadata`, kind: 'session', contentMode: 'snapshot', completeness: 'native-export-metadata', currentRun: false})
        const seen = new Set()
        for (const message of messages) {
          if (!Number.isSafeInteger(message.id) || message.id < 1 || seen.has(message.id)) throw new Error('Hermes export is missing a unique native message identity.')
          seen.add(message.id)
          await archive.capture(message, {id: `session:${target}:message:${message.id}`, kind: 'message', contentMode: 'snapshot', completeness: 'native-export', currentRun: currentRun && message.id > (highWater.get(target) ?? 0)})
        }
        if (!currentRun) highWater.set(target, Array.from(seen).reduce((maximum, id) => Math.max(maximum, id), 0))
      }
    }
    await captureSnapshot(false)
    interactive?.bind({
      async steer(text) { const value=await rpc('session.steer',{session_id:liveID,text}); if(value.status!=='queued')throw new Error('Hermes did not accept steering.') },
      async respond(id,response) {
        if(signal.aborted)throw new Error('The run has stopped.')
        const request=requests.get(id);if(!request)throw new Error('This interaction is no longer pending.')
        const {type,payload,responseID}=request
        if(type==='approval.request') {
          const offered=payload.choices?.length?payload.choices:['once','deny'],choice=response.cancelled?'deny':response.optionID
          if(!offered.includes(choice))throw new Error('Choose an offered approval response.')
          if(responseID!=null)send({jsonrpc:'2.0',id:responseID,result:{choice}})
          else await rpc('approval.respond',{session_id:liveID,request_id:id,choice})
        } else {
          const questions=payload.questions?.length?payload.questions:[payload],answers={}
          for(const [index,item] of questions.entries())answers[item.qid??String(index)]=response.cancelled?'':(response.answers?.[item.qid??String(index)]??[]).join(', ')
          if(responseID!=null)send({jsonrpc:'2.0',id:responseID,result:payload.questions?.length?{answers}:{answer:answers[questions[0].qid??'0']}})
          else for(const [index,item] of questions.entries())await rpc('clarify.respond',{session_id:liveID,request_id:id,...(payload.questions?.length?{question_id:item.qid??String(index)}:{}),answer:answers[item.qid??String(index)]})
        }
        requests.delete(id)
      },
    })
    const abort=()=>{void rpc('session.interrupt',{session_id:liveID}).catch(()=>{});finished.reject(new Error('Background execution was turned off.'))}
    signal.addEventListener('abort',abort,{once:true})
    try {
      if(signal.aborted)throw before('Background execution was turned off.')
      accepted=true;await rpc('prompt.submit',{session_id:liveID,text:prompt(run)})
      let result, failure
      try { result = await finished.promise } catch (error) { failure = error }
      if (failure) try { await rpc('session.interrupt', {session_id: liveID}) } catch {}
      await archive.drain()
      await captureSnapshot(true)
      if (failure) throw failure
      if (signal.aborted) throw new Error('Background execution was turned off.')
      return result
    } finally {signal.removeEventListener('abort',abort)}
  } catch(error){if(accepted&&liveID&&rpc)try{await rpc('session.interrupt',{session_id:liveID})}catch{};if(!accepted)error.beforePrompt=true;throw error}
  finally {clearInterval(heartbeat);fail(new Error('Hermes task connection closed.'));socket?.close();await archive?.close()}
}

async function runOpenCode({run,config,cwd,instances,read,fetchRequest,nativeSessionID,signal,publish,bindSession,interactive}) {
  const permission=config.permission
  if(permission && !['ask','allow','deny'].includes(permission))throw before('The saved OpenCode permission is unavailable.')
  let accepted=false,sessionID=nativeSessionID,call,archive
  try {
    await instances.action('opencode','start')
    const registration=parseRegistration(await read(instances.registrationPath,'utf8')),origin=new URL(registration.url)
    if(origin.protocol!=='http:'||!['127.0.0.1','localhost','[::1]'].includes(origin.hostname)||origin.username||origin.password||origin.pathname!=='/'||origin.search||origin.hash||typeof registration.password!=='string'||!registration.password)throw before('OpenCode service registration is unavailable.')
    const headers={authorization:`Basic ${Buffer.from('opencode:'+registration.password).toString('base64')}`,'content-type':'application/json'}
    call=async(method,path,body,ignoreAbort=false)=>{const result=await fetchRequest(new URL(path,origin),{method,headers,body:body==null?undefined:JSON.stringify(body),redirect:'error',signal:ignoreAbort?AbortSignal.timeout(5000):AbortSignal.any([signal,AbortSignal.timeout(30000)])});if(!result.ok)throw new Error('OpenCode could not complete the task operation.');if(result.status===204)return {};return result.json()}
    const health=await call('GET','/api/info')
    if(health.pid!==registration.pid||!supportsOpenCodeVersion(health.version)||(registration.version&&health.version!==registration.version))throw before('OpenCode service identity changed.')
    sessionID??='ses_'+randomUUID().replaceAll('-','')
    let session=(await call(nativeSessionID?'GET':'POST',nativeSessionID?`/api/session/${encodeURIComponent(sessionID)}`:'/api/session',nativeSessionID?undefined:{id:sessionID,title:run.title,location:{directory:cwd,...(config.nativeWorkspaceID?{workspaceID:config.nativeWorkspaceID}:{})},metadata:{wovenmatter:{origin:'created'}}})).data
    if(session?.id!==sessionID)throw before('OpenCode did not confirm the recurring session identity.')
    const path='/api/session/'+encodeURIComponent(sessionID)
    bindSession(sessionID)
    if(config.model||config.thinking){const model=config.model??[session.model?.providerID,session.model?.id].filter(Boolean).join('/'),split=model.indexOf('/');if(split<1)throw before('The saved OpenCode model is invalid.');const selection={providerID:model.slice(0,split),id:model.slice(split+1),...(config.thinking&&config.thinking!=='default'?{variant:config.thinking}:{})};await call('POST',path+'/model',{model:selection});session=(await call('GET',path)).data;if(session.model?.id!==selection.id||session.model?.providerID!==selection.providerID||(session.model?.variant??'default')!==(selection.variant??'default'))throw before('OpenCode did not confirm the saved model and thinking level.')}
    if (permission) {
      const rules = [...(session.permissions ?? [])]
      const last = rules.at(-1)
      const rule = {action: '*', resource: '*', effect: permission}
      if (last?.action === '*' && last?.resource === '*' && ['ask','allow','deny'].includes(last.effect)) rules[rules.length - 1] = rule
      else rules.push(rule)
      await call('PATCH', path, {permissions: rules})
      session = (await call('GET', path)).data
      if (session?.id !== sessionID || !isDeepStrictEqual(session.permissions, rules)) throw before('OpenCode did not confirm the saved native permission policy.')
    }
    archive = await createTaskNativeArchive({sourceID: 'opencode:' + origin.origin, nativeSessionID: sessionID, runID: run.id, publish})
    const messageID='msg_'+run.id.replaceAll(/[^a-zA-Z0-9]/g,'')
    const head = (await call('GET',path+'/message?limit=1&order=desc')).data
    if (!Array.isArray(head) || head.some(message => typeof message.id !== 'string' || !message.id)) throw before('OpenCode returned an incomplete native history page.')
    const baselineID = head[0]?.id
    const currentMessages = async () => {
      const messages = [], cursors = new Set(), ids = new Set()
      let cursor
      do {
        const query = new URLSearchParams({limit: '100', order: 'desc', ...(cursor ? {cursor} : {})})
        const page = await call('GET', path + '/message?' + query)
        if (!Array.isArray(page.data)) throw new Error('OpenCode returned an incomplete native history page.')
        for (const message of page.data) {
          if (typeof message.id !== 'string' || !message.id || ids.has(message.id)) throw new Error('OpenCode returned duplicate or missing native message identities.')
          const owner = message.sessionID ?? message.sessionId ?? message.info?.sessionID
          if (owner && owner !== sessionID) throw new Error('OpenCode returned a message belonging to another session.')
          ids.add(message.id)
          if (message.id === baselineID) return messages
          messages.push(message)
        }
        cursor = page.data.length ? page.cursor?.next : undefined
        if (cursor != null && (typeof cursor !== 'string' || !cursor || cursors.has(cursor))) throw new Error('OpenCode returned a nonadvancing native history cursor.')
        if (cursor) cursors.add(cursor)
      } while (cursor)
      return messages
    }
    const active=(await call('GET','/api/session/active')).data??{}
    if(active[sessionID])throw before('The recurring OpenCode task is already running.')
    if(signal.aborted)throw before('Background execution was turned off.')
    accepted=true
    const receipt=await call('POST',path+'/prompt',{id:messageID,text:prompt(run),files:[]})
    if(receipt.data?.id!==messageID)throw new Error('OpenCode did not acknowledge the task prompt. Check its session before retrying.')
    let observed=false, presentedText
    const presentedActivities=new Map()
    const interactions = new Map()
    interactive?.bind({async respond(id,response) {
      if(signal.aborted)throw new Error('The run has stopped.')
      const item=interactions.get(id);if(!item)throw new Error('This interaction is no longer pending.')
      const current=(await call('GET',path+'/'+item.kind)).data??[]
      if(!current.some(value=>value.id===item.request.id&&isDeepStrictEqual(value,item.request)))throw new Error('The native request changed before the response.')
      if(item.kind==='permission'){if(!item.ordinary&&!response.cancelled)throw new Error('Review this request in the desktop workspace interface.');if(!response.cancelled&&!['once','always','reject'].includes(response.optionID))throw new Error('Choose an offered response.');await call('POST',path+'/permission/'+encodeURIComponent(item.request.id)+'/reply',{reply:response.cancelled?'reject':response.optionID})}
      else {if(!response.cancelled)throw new Error('Complete this native form in the desktop workspace interface.');await call('DELETE',path+'/form/'+encodeURIComponent(item.request.id))}
      interactions.delete(id)
    }})
    for(let checks=0;checks<86400;checks++) {
      if (signal.aborted) throw new Error('Background execution was turned off.')
      const permissions=(await call('GET',path+'/permission')).data??[]
      if (!Array.isArray(permissions)) throw new Error('OpenCode returned an invalid native permission list.')
      for (const request of permissions) {
        if (request.sessionID !== sessionID || typeof request.id !== 'string' || !request.id) throw new Error('OpenCode returned an invalid native permission identity.')
        await archive.capture(request, {id: 'permission:' + request.id, kind: 'permission', contentMode: 'snapshot'})
      }
      const forms = (await call('GET',path+'/form')).data ?? []
      if (!Array.isArray(forms)) throw new Error('OpenCode returned an invalid native form list.')
      for (const form of forms) {
        if (form.sessionID !== sessionID || typeof form.id !== 'string' || !form.id) throw new Error('OpenCode returned an invalid native form identity.')
        await archive.capture(form, {id: 'form:' + form.id, kind: 'form', contentMode: 'snapshot'})
      }
      const messages = []
      for (const message of await currentMessages()) {
        messages.push(await archive.capture(message, {id: 'message:' + message.id, kind: 'message', contentMode: 'snapshot', completeness: 'native-export'}))
      }
      if (permissions.length || forms.length) {
        if (!interactive) throw approval()
        for (const request of permissions) {
          const id='permission:'+request.id+':'+createHash('sha256').update(JSON.stringify(request)).digest('hex')
          interactions.set(id,{kind:'permission',request})
          const category=String(request.action??'').toLowerCase().split(/[.:/_-]/)[0]
          const ordinary=request.id.startsWith('per')&&typeof request.action==='string'&&request.action.length>0&&Array.isArray(request.resources)&&request.resources.every(value=>typeof value==='string')&&request.effect!=='deny'
            && !['auth','authenticate','authentication','login','oauth','credential','credentials','secret','secrets','form','question','questions','ask','askuser','userinput'].includes(category)
            && (request.type==null||request.type==='permission')&&(request.source?.type==null||request.source.type==='tool')
          interactions.set(id,{kind:'permission',request,ordinary})
          interactive.publish({id,kind:'approval',title:ordinary?'Permission: '+request.action:'Review this request on your desktop',detail:ordinary?(request.resources??[]).join('\n'):'This request can be cancelled here.',
            options:ordinary?[{id:'once',label:'Allow Once'},...(request.save?.length?[{id:'always',label:'Always Allow'}]:[]),{id:'reject',label:'Reject'}]:[],questions:[]})
        }
        for (const request of forms) {
          const id='form:'+request.id+':'+createHash('sha256').update(JSON.stringify(request)).digest('hex');interactions.set(id,{kind:'form',request})
          interactive.publish({id,kind:'approval',title:'Complete the native form on your desktop',detail:'This form can be cancelled here.',options:[],questions:[]})
        }
      }
      const incoming=messages.filter(x=>x.id!==messageID&&(x.type==='assistant'||x.role==='assistant'||x.info?.role==='assistant'))
      if(incoming.length)observed=true
      if(interactive) {
        const chronological=[...incoming].reverse(),text=chronological.flatMap(message=>(message.content??message.parts??[]).filter(part=>part.type==='text').map(part=>part.text??'')).join('')
        if(text!==presentedText){publishNativePresentation({...textUpdate(text),_meta:{wovenAssistantSnapshot:true}},publish);presentedText=text}
        for(const message of chronological)for(const [index,part] of (message.content??message.parts??[]).entries()) {
          const id=message.id+':'+(part.id??index),fingerprint=JSON.stringify(part)
          if(presentedActivities.get(id)===fingerprint)continue
          presentedActivities.set(id,fingerprint)
          if(part.type==='reasoning')publishNativePresentation({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:part.text??''},_meta:{wovenThoughtID:id,wovenThoughtSnapshot:true}},publish)
          if(part.type==='tool')publishNativePresentation({sessionUpdate:'tool_call_update',toolCallId:id,title:part.state?.title??part.name,status:part.state?.status??part.state?.type??'running',content:[{type:'content',content:{type:'text',text:part.state?.output??(part.state?.content??[]).map(item=>item.text??'').join('\n')}}]},publish)
        }
      }
      const running=(await call('GET','/api/session/active')).data??{}
      if(!running[sessionID]&&observed){if(signal.aborted)throw new Error('Background execution was turned off.');if(!interactive)for(const message of incoming.reverse())for(const part of message.content??message.parts??[]){if(part.type==='text'&&part.text)publishNativePresentation(textUpdate(part.text), publish);if(part.type==='reasoning'&&part.text)publishNativePresentation({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:part.text}}, publish);}if(incoming.some(message=>message.error || message.info?.error))throw new Error('OpenCode could not complete this task.');return {stopReason:'end_turn'}}
      await pause(250)
    }
    throw new Error('OpenCode task exceeded its runtime limit.')
  } catch(error){if(accepted&&sessionID&&call)try{await call('POST','/api/session/'+encodeURIComponent(sessionID)+'/interrupt',{},true)}catch{};if(!accepted)error.beforePrompt=true;throw error}
  finally {await archive?.close()}
}
