import { readFile } from 'node:fs/promises'
import { isAbsolute } from 'node:path'
import { randomUUID, createHash } from 'node:crypto'
import { isDeepStrictEqual } from 'node:util'
import { supportsOpenCodeVersion } from './opencode-compatibility.mjs'
import { createTaskNativeArchive, publishNativePresentation } from './task-native-archive.mjs'
import { OpenCodeTaskStream } from './opencode-task-stream.mjs'

const before = text => Object.assign(new Error(text), { beforePrompt: true })
const approval = () => Object.assign(new Error('This task needs approval. Open its session to continue.'), { needsApproval: true })
const parseRegistration = bytes => { try { return JSON.parse(String(bytes)) } catch { throw before('The native service registration is invalid.') } }
const pause = ms => new Promise(done => setTimeout(done, ms))
const prompt = run => run.task.prompt

export function createNativeTaskExecutor({workspaceRoot, instances, fetchRequest = fetch, read = readFile}) {
  return async context => {
    const config = context.run.task.configuration
    const cwd = config.nativeWorkingDirectory ?? workspaceRoot
    if (!isAbsolute(cwd) || cwd.includes('\0')) throw before('The task working directory is invalid.')
    if (context.signal.aborted) throw before('Background execution was turned off.')
    if (config.runtimeKind === 'opencode') return runOpenCode({...context,config,cwd,instances,read,fetchRequest})
    throw before('This native agent is not supported.')
  }
}

async function runOpenCode({run,config,cwd,instances,read,fetchRequest,nativeSessionID,signal,publish,bindSession,interactive,mcpConnection}) {
  const permission=config.permission
  if(permission && !['ask','allow','deny'].includes(permission))throw before('The saved OpenCode permission is unavailable.')
  let accepted=false,sessionID=nativeSessionID,call,archive
  const presentation=new OpenCodeTaskStream(update=>publishNativePresentation(update,publish))
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
    if(session.location?.directory!==cwd)throw before('OpenCode did not confirm the saved execution directory.')
    const path='/api/session/'+encodeURIComponent(sessionID)
    await bindSession(sessionID)
    if(mcpConnection) {
      const query=new URLSearchParams({'location[directory]':cwd})
      const proxy=(await call('POST','/api/rpc/woven-mcp/connect?'+query,{input:{sessionID,context:mcpConnection}})).output
      if(!proxy||typeof proxy!=='object'||Array.isArray(proxy)||typeof proxy.endpointURL!=='string'||!proxy.endpointURL||typeof proxy.bearerToken!=='string'||!proxy.bearerToken)throw before('OpenCode did not confirm its Woven MCP connection.')
      const name='woven_'+createHash('sha256').update(sessionID).digest('hex').slice(0,16)
      await call('PUT','/api/experimental/mcp/'+name+'?'+query,{config:{type:'remote',url:proxy.endpointURL,headers:{Authorization:'Bearer '+proxy.bearerToken},oauth:false,codemode:false}})
    }
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
    const receipt=await call('POST',path+'/prompt',{id:messageID,text:prompt(run),files:[],...(mcpConnection?{metadata:{wovenMCP:{captureID:mcpConnection.captureID??''}}}:{})})
    if(receipt.data?.id!==messageID)throw new Error('OpenCode did not acknowledge the task prompt. Check its session before retrying.')
    let observed=false
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
      let incoming=messages.filter(x=>x.id!==messageID&&(x.type==='assistant'||x.role==='assistant'||x.info?.role==='assistant'))
      if(incoming.length)observed=true
      presentation.reconcile([...incoming].reverse())
      const running=(await call('GET','/api/session/active')).data??{}
      if(!running[sessionID]&&observed){if(signal.aborted)throw new Error('Background execution was turned off.');
        // Completion can race the preceding history read. Re-read after idle
        // before committing the task result so the final suffix/tools survive.
        const finalMessages=[]
        for(const message of await currentMessages()) finalMessages.push(await archive.capture(message,{id:'message:'+message.id,kind:'message',contentMode:'snapshot',completeness:'native-export'}))
        incoming=finalMessages.filter(x=>x.id!==messageID&&(x.type==='assistant'||x.role==='assistant'||x.info?.role==='assistant'))
        presentation.reconcile([...incoming].reverse())
        if(incoming.some(message=>message.error || message.info?.error))throw new Error('OpenCode could not complete this task.');
        const reported=incoming.flatMap(message=>(message.content??message.parts??[]).filter(part=>part.type==='step-finish'&&part.tokens).map(part=>part.tokens))
        if(reported.length) {
          const values=reported.map(tokens=>tokens.total??[tokens.input,tokens.output,tokens.cache?.read??0,tokens.cache?.write??0].reduce((sum,value)=>Number.isSafeInteger(value)&&value>=0?sum+value:NaN,0))
          const totalTokens=values.reduce((sum,value)=>sum+value,0)
          if(Number.isSafeInteger(totalTokens)&&totalTokens>=0)publish({sessionUpdate:'woven_usage',usage:{totalTokens}})
        }
        return {stopReason:'end_turn'}}
      await pause(250)
    }
    throw new Error('OpenCode task exceeded its runtime limit.')
  } catch(error){if(accepted&&sessionID&&call)try{await call('POST','/api/session/'+encodeURIComponent(sessionID)+'/interrupt',{},true)}catch{};if(!accepted)error.beforePrompt=true;throw error}
  finally {try{if(accepted)presentation.finish()}finally{await archive?.close()}}
}
