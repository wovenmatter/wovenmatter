import { readFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { supportsOpenCodeVersion } from './opencode-compatibility.mjs'

const fail = text => Object.assign(new Error(text), {statusCode:409})
const selection = (id, label = id) => ({id,label})
const emptyTools = {availableTools:[],enabledTools:[],canConfigure:true}
const modelKey = model => model?.providerID && model.id ? `${model.providerID}/${model.id}` : null

// A service-owned, short-lived native connection handles idle configuration.
// It never submits prompts, exports credentials, or adopts a running session.
export function createNativeClientSessions({workspaceRoot,instances,
  read = readFile,fetchRequest = fetch}) {
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
    let session=(await call(native.sessionID?'GET':'POST',native.sessionID?path:'/api/session',native.sessionID?undefined:{id,title:'New conversation',location:{directory:native.nativeWorkingDirectory??workspaceRoot},metadata:{wovenmatter:{origin:'created'}}})).data
    if (session?.id!==id) throw fail('OpenCode returned a different session.')
    if(native.nativeWorkingDirectory&&session.location?.directory!==native.nativeWorkingDirectory)throw fail('The native session has a different execution root.')
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
  return {async perform(runtimeKind,native,operation,options) {
    if(runtimeKind==='opencode')return openCode(native,operation,options)
    throw fail('This runtime does not use native session configuration.')
  }}
}
