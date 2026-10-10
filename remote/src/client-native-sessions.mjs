import { readFile } from 'node:fs/promises'
import { resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { supportsOpenCodeVersion } from './opencode-compatibility.mjs'

const fail = text => Object.assign(new Error(text), {statusCode:409})
const selection = (id, label = id) => ({id,label})
const emptyTools = {availableTools:[],enabledTools:[],canConfigure:true}
const modelKey = model => model?.providerID && model.id ? `${model.providerID}/${model.id}` : null

// A service-owned, short-lived native connection handles idle configuration.
// It never submits prompts, exports credentials, or adopts a running session.
export function createNativeClientSessions({workspaceRoot,environment,hermes,instances,
  read = readFile,fetchRequest = fetch,WebSocketClass = WebSocket}) {
  async function openCode(native, operation, options = {}) {
    await instances.action('opencode','start')
    const registration = JSON.parse(await read(instances.registrationPath,'utf8'))
    const origin = new URL(registration.url)
    if (origin.protocol !== 'http:' || !['127.0.0.1','localhost','[::1]'].includes(origin.hostname)
      || origin.username || origin.password || origin.pathname !== '/' || origin.search || origin.hash
      || typeof registration.password !== 'string' || !registration.password) throw fail('OpenCode registration is unavailable.')
    const headers = {authorization:'Basic '+Buffer.from('opencode:'+registration.password).toString('base64'),'content-type':'application/json'}
    const call = async (method,path,body) => {
      const response = await fetchRequest(new URL(path,origin),{method,headers,redirect:'error',signal:AbortSignal.timeout(30000),body:body==null?undefined:JSON.stringify(body)})
      if (!response.ok) throw fail('OpenCode did not acknowledge the session operation.')
      return response.status===204 ? {} : response.json()
    }
    const health = await call('GET','/api/info')
    if (health.pid!==registration.pid || !supportsOpenCodeVersion(health.version) || registration.version && registration.version!==health.version) throw fail('OpenCode service identity changed.')
    const id=native.sessionID??'ses_'+randomUUID().replaceAll('-',''),path='/api/session/'+encodeURIComponent(id)
    let session=(await call(native.sessionID?'GET':'POST',native.sessionID?path:'/api/session',native.sessionID?undefined:{id,title:'New conversation',location:{directory:workspaceRoot},metadata:{wovenmatter:{origin:'created'}}})).data
    if (session?.id!==id) throw fail('OpenCode returned a different session.')
    const active=(await call('GET','/api/session/active')).data
    if (!active || typeof active!=='object' || active[id]) throw fail('This OpenCode session is not idle.')
    const result={...native,sessionID:id,nativeWorkingDirectory:session.location?.directory??workspaceRoot}
    if (operation==='adopt'||operation==='create') return result
    const query='?'+new URLSearchParams({'location[directory]':result.nativeWorkingDirectory})
    const catalog=(await call('GET','/api/model'+query)).data
    if (!Array.isArray(catalog)) throw fail('OpenCode model catalog is unavailable.')
    const models=catalog.filter(item=>item.enabled===true&&modelKey(item))
    const fallback=(await call('GET','/api/model/default'+query)).data
    if (operation==='configure') {
      if (options.model||options.thinking) {
        const key=options.model??modelKey(session.model??fallback),choice=models.find(item=>modelKey(item)===key)
        if (!choice) throw fail('Choose an available OpenCode model.')
        const variant=options.thinking??session.model?.variant??'default'
        if (variant!=='default'&&!(choice.variants??[]).some(item=>item.id===variant)) throw fail('Choose a thinking level supported by this model.')
        const model={providerID:choice.providerID,id:choice.id,...(variant==='default'?{}:{variant})}
        await call('POST',path+'/model',{model})
        session=(await call('GET',path)).data
        if (modelKey(session?.model)!==modelKey(model)||(session.model.variant??'default')!==(model.variant??'default')) throw fail('OpenCode did not confirm the model selection.')
      }
      if (options.permission) {
        if (!['ask','allow','deny'].includes(options.permission)) throw fail('Choose an available OpenCode permission policy.')
        const rules=[...(session.permissions??[])],last=rules.at(-1),rule={action:'*',resource:'*',effect:options.permission}
        if (last?.action==='*'&&last.resource==='*'&&['ask','allow','deny'].includes(last.effect)) rules[rules.length-1]=rule
        else rules.push(rule)
        await call('PATCH',path,{permissions:rules})
        session=(await call('GET',path)).data
        if (session?.id!==id||!isDeepStrictEqual(session.permissions,rules)) throw fail('OpenCode did not confirm the permission policy.')
      }
    }
    const current=session.model??fallback,key=modelKey(current),choice=models.find(item=>modelKey(item)===key),variants=choice?.variants??[]
    const last=session.permissions?.at(-1)
    return {...emptyTools,model:key,thinking:current?.variant??(variants.length?'default':null),
      permission:last?.action==='*'&&last.resource==='*'&&['ask','allow','deny'].includes(last.effect)?last.effect:null,models:models.map(item=>selection(modelKey(item),item.name??item.id)),
      thinkingLevels:variants.length?[selection('default'),...variants.map(item=>selection(item.id,item.name??item.id))]:[],
      permissions:[selection('ask','Ask for approval'),selection('allow','Full access'),selection('deny','Deny')]}
  }
  async function hermesSession(native,operation,options={}) {
    await hermes.start()
    const home=environment().HERMES_HOME??resolve(environment().HOME,'.hermes')
    const identityHome=native.workspaceID?'/remote-workspaces/'+native.workspaceID.toLowerCase()+home:home
    const registration=JSON.parse(await read(resolve(home,'.woven-matter/service.json'),'utf8'))
    if (!Number.isInteger(registration.port)||registration.port<1||registration.port>65535||typeof registration.token!=='string'||!registration.token) throw fail('Hermes registration is unavailable.')
    const socket=new WebSocketClass(`ws://127.0.0.1:${registration.port}/api/ws?token=${encodeURIComponent(registration.token)}`)
    const pending=new Map()
    let sequence=0
    const rejectAll=()=>{for(const request of pending.values()){clearTimeout(request.timer);request.reject(fail('Hermes session connection ended.'))};pending.clear()}
    socket.addEventListener('close',rejectAll)
    socket.addEventListener('error',rejectAll)
    socket.addEventListener('message',event=>{
      for(const line of String(event.data).split('\n')) {
        let value;try {value=JSON.parse(line)} catch {continue}
        if(value.method||!pending.has(value.id))continue
        const request=pending.get(value.id);pending.delete(value.id);clearTimeout(request.timer)
        if(value.error)request.reject(fail('Hermes rejected the session operation.'));else request.resolve(value.result)
      }
    })
    const rpc=(method,params={})=>new Promise((resolve,reject)=>{
      const id=String(++sequence),timer=setTimeout(()=>{pending.delete(id);reject(fail('Hermes did not acknowledge the session operation.'))},30000)
      pending.set(id,{resolve,reject,timer});socket.send(JSON.stringify({jsonrpc:'2.0',id,method,params}))
    })
    try {
      await new Promise((resolve,reject)=>{
        const timer=setTimeout(()=>reject(fail('Hermes connection timed out.')),10000)
        socket.addEventListener('open',()=>{clearTimeout(timer);resolve()},{once:true})
        socket.addEventListener('error',()=>{clearTimeout(timer);reject(fail('Hermes connection failed.'))},{once:true})
      })
      const profile=await rpc('config.get',{key:'profile'})
      if(profile.home!==home)throw fail('Hermes connected to a different profile.')
      let previous=native.sessionID
      if(previous?.startsWith('hermes-gateway:')||previous?.startsWith('hermes-import:')) {
        const pieces=previous.split(':')
        if(Buffer.from(pieces[1],'base64').toString()!==identityHome)throw fail('This Hermes session belongs to another workspace profile.')
        previous=pieces.slice(2).join(':')
      }
      const session=await rpc(previous?'session.resume':'session.create',{source:'desktop',close_on_disconnect:false,cwd:workspaceRoot,...(previous?{session_id:previous,defer_history:true}:{title:'New conversation'})})
      if(session.running)throw fail('This Hermes session is not idle.')
      const liveID=session.session_id,resolved=session.stored_session_id??session.session_key,stored=previous??resolved
      if(!liveID||!resolved||!stored||(previous&&resolved!==previous&&session.resumed!==resolved))throw fail('Hermes returned a different durable session.')
      const result={...native,sessionID:native.sessionID??`hermes-gateway:${Buffer.from(identityHome).toString('base64')}:${stored}`}
      if(operation==='create'||operation==='adopt')return result
      const params={session_id:liveID}
      let state=await rpc('session.activate',{...params,omit_messages:true})
      if(state.session_id!==liveID)throw fail('Hermes returned a different session.')
      const modelOptions=await rpc('model.options',{...params,explicit_only:true}),reasoning=await rpc('config.get',{...params,key:'reasoning'})
      const models=(modelOptions.providers??[]).flatMap(provider=>(provider.models??[]).map(id=>selection(provider.slug?id+' --provider '+provider.slug:id,id)))
      const current=modelOptions.provider?modelOptions.model+' --provider '+modelOptions.provider:modelOptions.model
      const selected=options.model??current,provider=(modelOptions.providers??[]).find(item=>(item.models??[]).some(id=>(item.slug?id+' --provider '+item.slug:id)===selected))
      const modelID=(provider?.models??[]).find(id=>(provider.slug?id+' --provider '+provider.slug:id)===selected)
      const capabilities=provider?.capabilities?.[modelID]??{},levels=capabilities.reasoning===false?[]:[...(capabilities.can_disable_reasoning===false?[]:['none']),'minimal','low','medium','high','xhigh','max','ultra']
      if(operation==='configure') {
        if(options.model&&!models.some(item=>item.id===options.model))throw fail('Choose an available Hermes model.')
        if(options.thinking&&!levels.includes(options.thinking))throw fail('Choose a thinking level supported by this model.')
        if(options.permission&&!['default','full'].includes(options.permission))throw fail('Choose an available Hermes permission policy.')
        if(options.permission==='default'&&state.info?.approval_mode==='off')throw fail('The Hermes profile forces full access. Change its profile policy before lowering this session.')
        for(const [key,value] of [['model',options.model],['reasoning',options.thinking],['yolo',options.permission?options.permission==='full'?'1':'0':null]])if(value!=null) {
          const confirmation=await rpc('config.set',{...params,key,value,scope:'session'})
          if(confirmation.confirm_required||confirmation.scope!=='session')throw fail('Hermes did not confirm the session configuration.')
          if(key==='yolo'&&String(confirmation.value)!==value)throw fail('Hermes did not confirm the session permission override.')
          if(key!=='yolo'){const actual=await rpc('config.get',{...params,key});if((actual.value??actual[key])!==value)throw fail('Hermes did not confirm the selected '+key+'.')}
        }
        state=await rpc('session.activate',{...params,omit_messages:true})
        if(state.session_id!==liveID)throw fail('Hermes returned a different session.')
        if(options.permission==='default'&&(state.info?.yolo===true||state.info?.approval_mode==='off'))throw fail('The Hermes process still forces full access.')
        if(options.permission==='full'&&state.info?.yolo!==true&&state.info?.approval_mode!=='off')throw fail('Hermes did not confirm full access.')
      }
      return {...emptyTools,model:options.model??current,thinking:options.thinking??(levels.length?reasoning.value:null),
        permission:state.info?.yolo===true||state.info?.approval_mode==='off'?'full':state.info?.yolo===false?'default':null,
        models,thinkingLevels:levels.map(id=>selection(id)),permissions:state.info?.approval_mode==='off'?[selection('full','Full access')]:[selection('default','Profile default'),selection('full','Full access')]}
    } finally {rejectAll();socket.close()}
  }
  return {async perform(runtimeKind,native,operation,options) {
    if(runtimeKind==='opencode')return openCode(native,operation,options)
    if(runtimeKind==='hermes')return hermesSession(native,operation,options)
    throw fail('This runtime does not use native session configuration.')
  }}
}
