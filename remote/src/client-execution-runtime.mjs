import { join, isAbsolute } from 'node:path'
import { ensureScratchDirectory, scratchFolderName } from './projects.mjs'
import { randomUUID, createHash } from 'node:crypto'
import { applyTaskConfiguration } from './task-gateway-runner.mjs'
import { clientInteraction, clientInteractionResponse } from './client-interactions.mjs'
import { createNativeClientSessions } from './client-native-sessions.mjs'
import { createNativeTaskExecutor } from './task-gateway-native.mjs'
import { runtimeConfiguration, workspacePermission, workspaceExecutionConfiguration, presentPermissionChoices, fullAccessPermissions, supportedPermissions, supportedPermission } from './config.mjs'
import { openEphemeralACP, ephemeralSession } from './ephemeral-acp.mjs'
import { promptBlocks, textWithFiles } from './execution-attachments.mjs'

const delay = milliseconds => new Promise(resolve => setTimeout(resolve,milliseconds))
const fail = message => Object.assign(new Error(message), { statusCode: 409 })
// Pi Durable's vault opens only with a Mac's unlock key. The code lets a
// caller unlock it (`POST /v1/default-agent/unlock`) and retry.
const locked = message => Object.assign(new Error(message), { statusCode: 423, code: 'default_agent_locked' })
const lockedMessage = 'Pi Durable is locked. A Mac unlocks it with its key for this workspace, then retry.'
const deferred = () => { let resolve,reject; const promise = new Promise((a,b)=>{resolve=a;reject=b}); promise.catch(()=>{}); return {promise,resolve,reject} }

// Match the desktop's ACP usage contract. Missing counts stay unknown.
export function clientRunTokens(result) {
  const usage=result?.usage
  if(!usage)return undefined
  if(Number.isSafeInteger(usage.totalTokens)&&usage.totalTokens>=0)return usage.totalTokens
  if(!Number.isSafeInteger(usage.inputTokens)||usage.inputTokens<0||!Number.isSafeInteger(usage.outputTokens)||usage.outputTokens<0)return undefined
  const values=[usage.inputTokens,usage.outputTokens,usage.cachedReadTokens??0,usage.cachedWriteTokens??0]
  if(values.some(value=>!Number.isSafeInteger(value)||value<0))return undefined
  const total=values.reduce((sum,value)=>sum+value,0)
  return Number.isSafeInteger(total)?total:undefined
}
// OpenCode takes attachments as file URIs it reads itself.
const openCodeFiles = files => files.map(file => ({uri:'file://'+encodeURI(file.path),name:file.name}))
function publishRunUsage(result,publish) {
  const totalTokens=clientRunTokens(result)
  if(totalTokens!=null)publish({sessionUpdate:'woven_usage',usage:{totalTokens}})
}

// Native runtimes remain the execution owners. This adapter projects their
// output into the common client contract without lending a client process any
// ownership over the run or replaying a prompt on reconnect.
//
// Sessions run whether or not background execution (the task gateway) is
// on: that setting governs scheduled tasks, as it did when the Mac launched
// these harnesses over SSH. `environment` and `spawnProcess` start the
// short-lived harness that lists a harness's options before a session exists.
export function createClientExecutionRuntime({ defaultAgent, durableACP, catalog, workspaceRoot, harnessStatus,
  instances, configuration = runtimeConfiguration, environment = () => process.env, spawnProcess }) {
  const mcpConnections=new Map()
  const mcpServers=connection=>connection?[{type:'http',name:'woven',url:connection.endpointURL,headers:[{name:'Authorization',value:'Bearer '+connection.bearerToken}]}]:[]
  const channels = new Map(), builtIn = new Map(), nativeJobs = new Map(), activeRuns = new Map()
  const nativeExecutor = createNativeTaskExecutor({workspaceRoot,instances})
  const nativeSessions = createNativeClientSessions({workspaceRoot,instances})
  let closed = false
  async function invoke(native,method,params) {
    return (await defaultAgent.invoke({method,attachmentToken:native.attachmentToken,params:{sessionId:native.sessionID,...params}})).result
  }
  // Full root forces Full access. A new session (`creation`) otherwise gets the
  // requested destination default, or the harness's Full access mode when none
  // was saved; an adapter that does not offer it keeps its native mode.
  // Reattaching an existing session changes its permission only to move it off
  // a mode Woven no longer offers (Ask for approval, read only, plan, an older
  // Codex adapter's workspace access, …).
  async function applyWorkspacePolicy(native, runtimeKind, call, creation) {
    const forced = workspacePermission(runtimeKind, undefined, configuration)
    const projected = runtimeKind === 'grok_build' ? undefined : project(runtimeKind, native.configuration ?? {})
    const offered = projected?.permissions?.map(choice => choice.id) ?? []
    const offers = id => id != null && (offered.length ? offered.includes(id) : supportedPermissions(runtimeKind).includes(id))
    const requested = offers(creation?.permission) ? creation.permission : undefined
    const current = projected?.permission
    const unsupported = current != null && !offers(current)
    const permission = forced ?? (creation ? requested ?? fullAccessPermissions[runtimeKind] : unsupported ? fullAccessPermissions[runtimeKind] : undefined)
    if (!permission || runtimeKind === 'grok_build') return
    await applyTaskConfiguration(async (method, params) => {
      const result = await call(method, params)
      native.configuration = { ...native.configuration, ...result }
      return result
    }, native.sessionID, native.configuration ?? {}, { runtimeKind, permission, usesProductPermissionDefault: !forced })
  }
  // `load` reopens the native session (initialize, session/load) on a
  // channel this server just started, as recovery of a stopped one does.
  async function attach(native,runtimeKind,{load=false}={}) {
    if (runtimeKind === 'grok_build') native.permission = grokPermission(native)
    const mcpConnection=mcpConnections.get(native.channelID??native.sessionID)
    if (channels.has(native.channelID) && !channels.get(native.channelID).stopped) return channels.get(native.channelID)
    channels.delete(native.channelID)
    let recovered=false
    let page = await durableACP.handle('POST','/v1/durable-acp/attach',{channelID:native.channelID,harnessID:runtimeKind,cwd:native.nativeWorkingDirectory??workspaceRoot,permission:native.permission,attachmentProtocol:1})
    if (page.state === 'stopped' && native.sessionID) {
      page=await durableACP.handle('POST','/v1/durable-acp/recover',{channelID:native.channelID,harnessID:runtimeKind,cwd:native.nativeWorkingDirectory??workspaceRoot,permission:native.permission,attachmentProtocol:1})
      recovered=true
    }
    if (page.state !== 'running') throw fail('This native session was interrupted. Reopen it on the execution host before sending again.')
    // Drain old output before a new run may publish. A replayed settled event
    // must never complete a newer prompt under the same native session.
    let cursor=0, history=page
    while(history.events.length) {
      cursor=history.events.at(-1).sequence
      history=await durableACP.handle('POST','/v1/durable-acp/poll',{channelID:native.channelID,after:cursor,attachmentToken:page.attachmentToken})
    }
    const channel = { native, runtimeKind, token:page.attachmentToken, cursor, busy:false, pendingInputs:0, pending:new Map(), callbacks:new Map(), run:null, stopped:false }
    channels.set(native.channelID,channel)
    channel.pump = (async () => {
      while (!closed && !channel.stopped) {
        const current = await durableACP.handle('POST','/v1/durable-acp/poll',{channelID:native.channelID,after:channel.cursor,attachmentToken:channel.token})
        for (const event of current.events) {
          if (event.sequence <= channel.cursor) continue
          receive(channel,event.message); channel.cursor=event.sequence
        }
        channel.busy=current.snapshot.busy
        if (current.state !== 'running') throw fail('The native workspace session stopped. Its accepted commands will not be replayed.')
        await delay(100)
      }
    })().catch(error => {
      channel.stopped=true
      for(const request of channel.pending.values())request.reject(error)
      channel.pending.clear();channel.run?.completion.reject(error)
    })
    if(recovered||load) {
      try {
        const initialized=await rpc(channel,'initialize',{protocolVersion:1,clientCapabilities:{fs:{readTextFile:false,writeTextFile:false},terminal:false,elicitation:{form:{}}},clientInfo:{name:'Woven Matter Workspace',version:'1'}})
        if(initialized.protocolVersion!==1)throw fail('Unsupported native agent protocol.')
        native.steeringSupported=initialized._meta?.steering?.supported===true
        native.configuration=await rpc(channel,'session/load',{sessionId:native.sessionID,cwd:native.nativeWorkingDirectory??workspaceRoot,mcpServers:mcpServers(mcpConnection),_meta:{...(mcpConnection?{wovenMCPConnection:mcpConnection}:{})}})
        if(native.configuration.sessionId!==native.sessionID)throw fail('The reopened native session has a different identity.')
      } catch(error){channel.stopped=true;channels.delete(native.channelID);throw error}
    }
    return channel
  }
  function receive(channel,message) {
    const run=channel.run
    if (message.id != null && !message.method) {
      const request=channel.pending.get(String(message.id))
      if(request){channel.pending.delete(String(message.id));if(message.error||message.success===false)request.reject(fail('The native agent rejected this operation.'));else request.resolve(message.result??message.data??{})}
    }
    // The command palette arrives with the session, usually outside a run.
    if(message.method==='session/update'&&message.params?.sessionId===channel.native.sessionID&&message.params.update?.sessionUpdate==='available_commands_update')
      channel.commands=message.params.update.availableCommands
    if(!run)return
    if(message.method==='session/update' && message.params?.sessionId===channel.native.sessionID)run.publish(message.params.update)
    if(message.method==='session/request_permission' && message.params?.sessionId===channel.native.sessionID) {
      const id=String(message.id)+':'+createHash('sha256').update(JSON.stringify(message)).digest('hex')
      channel.callbacks.set(id,message)
      run.interaction({id,kind:'approval',title:message.params?.toolCall?.title??'Agent needs approval',options:(message.params?.options??[]).map(option=>({id:option.optionId,label:option.name})),questions:[]})
    } else if(message.method==='elicitation/create'&&message.id!=null) {
      try {
        if(message.params?.sessionId&&message.params.sessionId!==channel.native.sessionID)throw fail('Interaction belongs to another session.')
        const projection=clientInteraction(message),id=String(message.id)+':'+createHash('sha256').update(JSON.stringify(message)).digest('hex')
        channel.callbacks.set(id,message)
        run.publish({sessionUpdate:'woven_interaction',request:message})
        run.interaction({id,...projection})
      } catch {
        void write(channel,{jsonrpc:'2.0',id:message.id,error:{code:-32602,message:'Unsupported interaction schema; use the native desktop interface.'}},randomUUID()).catch(error=>run.completion.reject(error))
      }
    } else if(message.method && message.id!=null) {
      // Do not expose arbitrary host filesystem/client RPC calls through the
      // direct API. Native workspace tools run in the execution host itself.
      void write(channel,{jsonrpc:'2.0',id:message.id,error:{code:-32601,message:'This client operation is unavailable.'}},randomUUID()).catch(error=>run.completion.reject(error))
    }
  }
  async function write(channel,message,deliveryID) {
    return durableACP.handle('POST','/v1/durable-acp/message',{channelID:channel.native.channelID,attachmentToken:channel.token,deliveryID,message})
  }
  async function rpc(channel,method,params={},deliveryID=randomUUID()) {
    const id=randomUUID(), pending=deferred();channel.pending.set(id,pending)
    try {
      await write(channel,{jsonrpc:'2.0',id,method,params},deliveryID)
      let timer
      try {return await Promise.race([pending.promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(fail('The native agent did not acknowledge this operation.')),method==='session/prompt'?24*3600000:30000);timer.unref()})])}
      finally{clearTimeout(timer)}
    } finally {channel.pending.delete(id)}
  }
  async function create({runtimeKind,conversationID,workspaceID,mcpConnection,nativeWorkingDirectory:requestedDirectory,permission}) {
    const requestedPermission = supportedPermission(runtimeKind, permission)
    permission = workspacePermission(runtimeKind, requestedPermission, configuration)
    if(mcpConnection)mcpConnections.set(conversationID,mcpConnection)
    const nativeWorkingDirectory = requestedDirectory??join(workspaceRoot,'scratch',scratchFolderName(conversationID,'',new Date(),true))
    if(!isAbsolute(nativeWorkingDirectory)||nativeWorkingDirectory.includes('\0'))throw fail('The destination working directory is invalid.')
    if(!requestedDirectory)await ensureScratchDirectory(workspaceRoot,nativeWorkingDirectory)
    if(runtimeKind==='default_agent') {
      const status=await defaultAgent.status()
      if(status.locked)throw locked(lockedMessage)
      const opened=await defaultAgent.invoke({method:'session/new',attachmentProtocol:1,params:{cwd:nativeWorkingDirectory,_meta:{...(mcpConnection?{wovenMCPConnection:mcpConnection}:{})}}})
      const native = {nativeWorkingDirectory,sessionID:opened.result.sessionId,attachmentToken:opened.result._meta?.attachmentToken,epoch:status.epoch,configuration:opened.result}
      await applyWorkspacePolicy(native, runtimeKind, (method, params) => invoke(native, method, params), { permission: requestedPermission })
      return native
    }
    if(runtimeKind==='opencode') {
      const native = await nativeSessions.perform(runtimeKind,{sessionID:null,conversationID,workspaceID,nativeWorkingDirectory},'create')
      await nativeSessions.perform(runtimeKind, native, 'configure', { permission: permission ?? fullAccessPermissions.opencode })
      return native
    }
    const harness=catalog.get(runtimeKind)
    if(!harness||!['acp','agent-stdio'].includes(harness.transport))throw fail('This native runtime is unavailable for direct execution.')
    const native={channelID:conversationID,sessionID:null,nativeWorkingDirectory,...(runtimeKind==='grok_build'?{permission:permission??fullAccessPermissions.grok_build}:{})}
    const channel=await attach(native,runtimeKind)
    const initialized=await rpc(channel,'initialize',{protocolVersion:1,clientCapabilities:{fs:{readTextFile:false,writeTextFile:false},terminal:false,elicitation:{form:{}}},clientInfo:{name:'Woven Matter Workspace',version:'1'}})
    native.steeringSupported=initialized._meta?.steering?.supported===true
    if(initialized.protocolVersion!==1)throw fail('Unsupported native agent protocol.')
    native.configuration=await rpc(channel,'session/new',{cwd:native.nativeWorkingDirectory??workspaceRoot,mcpServers:mcpServers(mcpConnection),_meta:{...(mcpConnection?{wovenMCPConnection:mcpConnection}:{})}});native.sessionID=native.configuration.sessionId
    if(typeof native.sessionID!=='string'||!native.sessionID)throw fail('The native agent did not create a session.')
    await applyWorkspacePolicy(native, runtimeKind, (method, params) => rpc(channel, method, params), { permission: requestedPermission })
    return native
  }
  async function adopt({native,runtimeKind}) {
    if(native?.nativeWorkingDirectory!=null&&(!isAbsolute(native.nativeWorkingDirectory)||native.nativeWorkingDirectory.includes('\0')))throw fail('Invalid native working directory.')
    if(typeof native?.sessionID!=='string'||!native.sessionID||native.sessionID.length>4096)throw fail('A native session identity is required.')
    if(runtimeKind==='default_agent') {
      const status=await defaultAgent.status()
      if(status.locked)throw locked(lockedMessage)
      const opened=await defaultAgent.invoke({method:'woven/adopt',attachmentProtocol:1,params:{sessionId:native.sessionID}})
      if(opened.result.sessionId!==native.sessionID)throw fail('Native session identity changed.')
      const adopted = {nativeWorkingDirectory:native.nativeWorkingDirectory,sessionID:native.sessionID,epoch:status.epoch,attachmentToken:opened.result._meta?.attachmentToken,configuration:opened.result}
      await applyWorkspacePolicy(adopted, runtimeKind, (method, params) => invoke(adopted, method, params))
      return adopted
    }
    if(runtimeKind==='opencode') {
      const adopted = await nativeSessions.perform(runtimeKind,native,'adopt')
      const permission = workspacePermission(runtimeKind, undefined, configuration)
      if (permission) await nativeSessions.perform(runtimeKind, adopted, 'configure', { permission })
      return adopted
    }
    if(typeof native.channelID!=='string')throw fail('The native durable channel identity is required.')
    let known=durableACP.peek?await durableACP.peek(native.channelID):undefined
    if(known?.state==='interrupted') {
      // Its former owner died without recording a stop (an ungraceful host
      // exit), and the SSH relay it last ran under is gone. Once no process
      // of this server holds it, it is recorded stopped and reopened below.
      if(known.live)throw fail('This native session is still running on this host. Wait for it to finish before moving it.')
      if(known.sessionID&&known.sessionID!==native.sessionID)throw fail('The durable channel belongs to a different native session.')
      known=await durableACP.release(native.channelID).catch(error=>{throw fail(error.message)})
    }
    if(known!==undefined&&known?.state!=='running') {
      // The durable process is gone (a host restart stopped it) or never
      // existed (an SSH session with background execution off). Reopen the
      // native session from the harness's own store on a channel this server
      // owns; a session that cannot be reopened leaves no process behind.
      if(known?.sessionID&&known.sessionID!==native.sessionID)throw fail('The durable channel belongs to a different native session.')
      const reopened={nativeWorkingDirectory:native.nativeWorkingDirectory,sessionID:native.sessionID,channelID:native.channelID,...(runtimeKind==='grok_build'?{permission:grokPermission(native)}:{})}
      try {
        const channel=await attach(reopened,runtimeKind,{load:true})
        await applyWorkspacePolicy(reopened, runtimeKind, (method, params) => rpc(channel, method, params))
        return reopened
      } catch(error) {
        const channel=channels.get(native.channelID)
        if(channel){channel.stopped=true;channels.delete(native.channelID)}
        await (known?durableACP.stopAll({except:id=>id!==native.channelID}):durableACP.discard(native.channelID)).catch(()=>{})
        throw error
      }
    }
    const page=await durableACP.handle('POST','/v1/durable-acp/adopt',{channelID:native.channelID,harnessID:runtimeKind,cwd:native.nativeWorkingDirectory??workspaceRoot,permission:runtimeKind==='grok_build'?grokPermission(native):native.permission,attachmentProtocol:1,expectedNativeSessionID:native.sessionID})
    const actual=page.snapshot.session?.sessionId
    if(actual!==native.sessionID)throw fail('The durable channel belongs to a different native session.')
    const result={nativeWorkingDirectory:native.nativeWorkingDirectory,sessionID:native.sessionID,channelID:native.channelID,...(runtimeKind==='grok_build'?{permission:grokPermission(native)}:{}),configuration:page.snapshot.session,steeringSupported:page.snapshot.initialized?._meta?.steering?.supported===true}
    const channel = await attach(result,runtimeKind)
    await applyWorkspacePolicy(result, runtimeKind, (method, params) => rpc(channel, method, params))
    return result
  }
  async function run(options) {
    if(options.command.mcpConnection)mcpConnections.set(options.native.channelID??options.native.sessionID,options.command.mcpConnection)
    const fence = { stopped: false, stopping: null }
    activeRuns.set(options.command.runID, fence)
    try { return await runAccepted(options, fence) }
    finally { activeRuns.delete(options.command.runID) }
  }
  function requireActive(fence) {
    if (closed || fence.stopped) throw fail('This run stopped before native dispatch.')
  }
  // `files` are the message's verified attachments (execution-attachments.mjs).
  async function runAccepted({native,runtimeKind,command,publish,interaction,files=[]}, fence) {
    if(runtimeKind==='default_agent') {
      const job={native,command};builtIn.set(command.runID,job)
      try {
        await ensureBuiltIn(native,command.mcpConnection)
        await applyWorkspacePolicy(native, runtimeKind, (method, params) => invoke(native, method, params))
        await fence.stopping?.promise; requireActive(fence)
        publish({sessionUpdate:'woven_execution_binding',native})
        const reply=await defaultAgent.invoke({operationID:command.runID,method:'session/prompt',attachmentToken:native.attachmentToken,
          params:{sessionId:native.sessionID,prompt:promptBlocks(command.text,files),_meta:{wovenRunID:command.runID,wovenInputID:command.commandID,...(command.mcpConnection?{wovenMCP:command.mcpConnection}:{})}}})
        let after=0
        while(!closed) {
          const page=await defaultAgent.poll(reply.operationID,after)
          for(const update of page.updates)publish(update)
          after=page.cursor
          if(page.done){publishRunUsage(page.result,publish);if(page.error||page.result?.stopReason==='cancelled')throw fail('Pi Durable could not complete this run. Its accepted input will not be replayed.');return}
          await delay(100)
        }
      } finally {builtIn.delete(command.runID)}
      return
    }
    if(runtimeKind==='opencode') {
      const controller=new AbortController(),job={controller,native,control:null};nativeJobs.set(command.runID,job)
      try {return await nativeExecutor({run:{id:command.runID,title:command.text.slice(0,100),task:{prompt:command.text,files:openCodeFiles(files),configuration:workspaceExecutionConfiguration({runtimeKind,workspaceID:native.workspaceID,nativeWorkingDirectory:native.nativeWorkingDirectory},configuration)}},nativeSessionID:native.sessionID,signal:controller.signal,publish,mcpConnection:command.mcpConnection,
        bindSession:id=>{native.sessionID=id;publish({sessionUpdate:'woven_execution_binding',native})},
        interactive:{publish:interaction,bind:control=>{job.control=control}}})}
      finally {nativeJobs.delete(command.runID)}
    }
    const channel=await attach(native,runtimeKind),completion=deferred()
    if(command.mcpConnection)await durableACP.handle('POST','/v1/durable-acp/mcp',{channelID:native.channelID,attachmentToken:channel.token,context:command.mcpConnection})
    if(channel.run)throw fail('This native conversation is already running.')
    // Read the native admission state before assigning this run's projection.
    // An uncertain old command must not have its remaining output attributed
    // to a newer run while the native service refuses that new prompt.
    let before
    do {
      before=await durableACP.handle('POST','/v1/durable-acp/poll',{channelID:native.channelID,after:channel.cursor,attachmentToken:channel.token})
      for(const event of before.events)if(event.sequence>channel.cursor){receive(channel,event.message);channel.cursor=event.sequence}
    } while(before.events.length)
    channel.busy=before.snapshot.busy
    if(channel.busy||before.snapshot.pendingRequests.length)throw fail('The native session still has unfinished work. Reconcile that run before sending again.')
    await applyWorkspacePolicy(native, runtimeKind, (method, params) => rpc(channel, method, params))
    channel.run={command,publish,interaction,completion}
    try {
      await Promise.race([(async()=>{
        let failure
        await fence.stopping?.promise; requireActive(fence)
        try {const result=await rpc(channel,'session/prompt',{sessionId:native.sessionID,prompt:promptBlocks(command.text,files),_meta:{wovenRunID:command.runID,...(command.mcpConnection?{wovenMCP:command.mcpConnection}:{})}},command.commandID);publishRunUsage(result,publish);if(result.stopReason==='cancelled')throw fail('The native run was cancelled.')} catch(error){failure=error}
        while(!closed&&!channel.stopped&&(channel.busy||channel.pendingInputs))await delay(25)
        if(closed||channel.stopped)throw fail('The native workspace session stopped.')
        if(failure||channel.run?.nativeError)throw failure??channel.run.nativeError
      })(),completion.promise])
    } finally {channel.run=null;channel.callbacks.clear()}
  }
  async function stop(options) {
    const fence = activeRuns.get(options.command.runID), stopping = deferred()
    if (fence) fence.stopping = stopping
    try {
      await stopNative(options)
      if (fence) fence.stopped = true
    } finally { if (fence) fence.stopping = null; stopping.resolve() }
  }
  async function stopNative({native,runtimeKind,command}) {
    if(runtimeKind==='default_agent')return invoke(native,'session/cancel',{})
    if(runtimeKind==='opencode'){const job=nativeJobs.get(command.runID);if(!job)throw fail('The native run is no longer active.');job.controller.abort();return}
    const channel=await attach(native,runtimeKind)
    await write(channel,{jsonrpc:'2.0',method:'session/cancel',params:{sessionId:native.sessionID}},command.commandID)
  }
  async function steer({native,runtimeKind,command,files=[]}) {
    if(runtimeKind==='default_agent') {
      const result=await invoke(native,'_session/steering',{prompt:promptBlocks(command.text,files),_meta:{wovenRunID:command.runID,wovenInputID:command.commandID,...(command.mcpConnection?{wovenMCP:command.mcpConnection}:{})}})
      if(result.outcome==='promptRequired')throw fail('That run has finished. Send a new message.')
      return
    }
    if(runtimeKind==='opencode'){const control=nativeJobs.get(command.runID)?.control;if(!control?.steer)throw fail('This OpenCode run is not ready for steering yet. Try again in a moment.');return control.steer(command.text,command.commandID,{files:openCodeFiles(files),mcpConnection:command.mcpConnection})}
    const channel=await attach(native,runtimeKind)
    if(!channel.run||channel.run.command.runID!==command.runID)throw fail('That run has finished. Send a new message.')
    if(runtimeKind==='grok_build')return rpc(channel,'_x.ai/interject',{sessionId:native.sessionID,text:textWithFiles(command.text,files),...(command.mcpConnection?{_meta:{wovenMCP:command.mcpConnection}}:{})},command.commandID)
    if(!native.steeringSupported)throw fail('This native agent does not support steering.')
    const result=await rpc(channel,'_session/steering',{sessionId:native.sessionID,prompt:promptBlocks(command.text,files),_meta:{wovenRunID:command.runID,steering:{idleBehavior:'promptRequired'},...(command.mcpConnection?{wovenMCP:command.mcpConnection}:{})}},command.commandID)
    if(!['injected','startedNewTurn'].includes(result.outcome))throw fail('That run has finished. Send a new message.')
    return result
  }
  async function respond({native,runtimeKind,command}) {
    if(runtimeKind==='default_agent')throw fail('Pi Durable has no pending approval for this run.')
    if(runtimeKind==='opencode'){const control=nativeJobs.get(command.runID)?.control;if(!control?.respond)throw fail('This interaction is no longer active.');return control.respond(command.interactionID,command.response)}
    const channel=await attach(native,runtimeKind),request=channel.callbacks.get(command.interactionID)
    if(!request)throw fail('This interaction is no longer active.')
    const response=command.response
    {
      const result=request.method==='elicitation/create'?clientInteractionResponse(request,response):{outcome:response.cancelled?{outcome:'cancelled'}:{outcome:'selected',optionId:response.optionID}}
      channel.run?.publish({sessionUpdate:'woven_interaction_response',requestID:command.interactionID,response:result})
      await write(channel,{jsonrpc:'2.0',id:request.id,result},command.commandID)
    }
    channel.callbacks.delete(command.interactionID)
  }
  async function ensureBuiltIn(native,mcpConnection) {
    const status=await defaultAgent.status()
    if(status.locked)throw locked(lockedMessage)
    if(native.epoch===status.epoch)return
    const opened=await defaultAgent.invoke({method:'session/load',attachmentProtocol:1,params:{cwd:native.nativeWorkingDirectory??workspaceRoot,sessionId:native.sessionID,_meta:{...(mcpConnection?{wovenMCPConnection:mcpConnection}:{})}}})
    if(opened.result.sessionId!==native.sessionID)throw fail('Pi Durable reopened a different native session.')
    native.attachmentToken=opened.result._meta?.attachmentToken;native.epoch=status.epoch;native.configuration=opened.result
  }
  // The Mac's Grok modes (`LocalACPSessionPermissions.grokMetadata`).
  const grokPermissionChoices=[['auto','Auto',"Grok's safety checker decides which actions may run automatically."],
    ['bypassPermissions','Full access','Allow commands and edits without ordinary approval prompts. Native deny rules, hooks, and administrator policies still apply.']].map(([id,label,description])=>({id,label,description}))
  // Grok's permission is a process flag. A missing or no-longer-offered mode
  // starts Grok in Full access rather than its native ask default.
  function grokPermission(native) {
    return workspacePermission('grok_build', supportedPermission('grok_build', native.permission) ?? fullAccessPermissions.grok_build, configuration)
  }
  const selections = options => (options??[]).flatMap(item=>item.value!=null?[{id:String(item.value),label:item.name??String(item.value),
    ...(typeof item.description==='string'&&item.description?{description:item.description}:{}),...(typeof item._meta?.kind==='string'?{kind:item._meta.kind}:{})}]:selections(item.options))
  const withoutKind = values => values.map(({kind,...value})=>value)
  // A native configuration (`session/new`, `session/load`, config updates)
  // as the session settings every client reads.
  function project(runtimeKind,initial,grokSelected) {
    const model=initial.configOptions?.find(item=>item.id==='model'||item.category==='model')
    const thinking=initial.configOptions?.find(item=>['effort','thinking','reasoning_effort'].includes(item.id)||item.category==='thought_level')
    const permission=initial.configOptions?.find(item=>['permission_mode','approval_mode'].includes(item.id)||(item.id==='mode'&&['codex','claude_code'].includes(runtimeKind)))
      ??initial.configOptions?.find(item=>item.id==='mode')
    const modes=(initial.modes?.availableModes??[]).map(mode=>({id:mode.id,label:mode.name??mode.id,...(typeof mode.description==='string'&&mode.description?{description:mode.description}:{})}))
    return {model:model?.currentValue??initial.models?.currentModelId,thinking:thinking?.currentValue,permission:runtimeKind==='grok_build'?(grokSelected??fullAccessPermissions.grok_build):permission?.currentValue??initial.modes?.currentModeId,
      models:model?withoutKind(selections(model.options)):(initial.models?.availableModels??[]).map(item=>({id:item.modelId,label:item.name??item.modelId,...(typeof item.description==='string'&&item.description?{description:item.description}:{})})),
      thinkingLevels:withoutKind(selections(thinking?.options)),permissions:presentPermissionChoices(runtimeKind,runtimeKind==='grok_build'?grokPermissionChoices:permission?selections(permission.options):modes),availableTools:[],enabledTools:[],canConfigure:!(runtimeKind==='opencode')}
  }
  async function settings({native,runtimeKind}) {
    if(runtimeKind==='opencode')return nativeSessions.perform(runtimeKind,native,'settings')
    let initial=native.configuration??{}
    if(runtimeKind==='default_agent'){await ensureBuiltIn(native);initial=native.configuration}
    const commands=channels.get(native.channelID)?.commands
    return {...project(runtimeKind,initial,runtimeKind==='grok_build'?grokPermission(native):undefined),...(Array.isArray(commands)?{commands:commands.flatMap(item=>typeof item?.name==='string'&&item.name?[{name:item.name,
      ...(typeof item.description==='string'&&item.description?{detail:item.description}:{}),...(typeof item.input?.hint==='string'&&item.input.hint?{argumentHint:item.input.hint}:{})}]:[])}:{})}
  }
  // A harness's choices before any session exists (the calendar editor, the
  // new-chat pickers): a short-lived native session with no Woven tools, as
  // the Mac used to launch over SSH. `model` selects a model first, since
  // thinking levels can depend on it.
  async function sessionOptions({runtimeKind,workingDirectory,model}) {
    const cwd=workingDirectory??workspaceRoot
    if(!isAbsolute(cwd)||cwd.includes('\0'))throw fail('The working directory is invalid.')
    const chosen=async(initial,call)=>{
      const option=initial.configOptions?.find(item=>item.id==='model'||item.category==='model')
      if(!model||(option?option.currentValue===model:initial.models?.currentModelId===model))return initial
      if(option){if(!selections(option.options).some(item=>item.id===model))throw fail('Choose an available model.');return {...initial,...await call('session/set_config_option',{sessionId:initial.sessionId,configId:option.id,value:model})}}
      if(!(initial.models?.availableModels??[]).some(item=>item.modelId===model))throw fail('Choose an available model.')
      await call('session/set_model',{sessionId:initial.sessionId,modelId:model});return {...initial,models:{...initial.models,currentModelId:model}}
    }
    if(runtimeKind==='opencode')return nativeSessions.perform(runtimeKind,{nativeWorkingDirectory:cwd},'options',{model})
    if(runtimeKind==='default_agent') {
      const status=await defaultAgent.status()
      if(status.locked)throw locked(lockedMessage)
      const opened=await defaultAgent.invoke({method:'session/new',attachmentProtocol:1,params:{cwd,_meta:{}}})
      const native={sessionID:opened.result.sessionId,attachmentToken:opened.result._meta?.attachmentToken}
      return project(runtimeKind,await chosen({...opened.result,sessionId:native.sessionID},(method,params)=>invoke(native,method,params)))
    }
    const harness=catalog.get(runtimeKind)
    if(!harness||!['acp','agent-stdio'].includes(harness.transport))throw fail('This native runtime is unavailable on this workspace.')
    const permission=runtimeKind==='grok_build'?workspacePermission(runtimeKind,fullAccessPermissions.grok_build,configuration):undefined
    const connection=openEphemeralACP({harness,runtimeKind,cwd,environment,permission,...(spawnProcess?{spawnProcess}:{})})
    try {
      const initial=await ephemeralSession(connection,cwd)
      return project(runtimeKind,await chosen(initial,(method,params)=>connection.request(method,params)),permission)
    } finally {await connection.close()}
  }
  async function configure({native,runtimeKind,options}) {
    options = workspaceExecutionConfiguration({ runtimeKind, ...options }, configuration)
    if(runtimeKind==='grok_build'&&options.permission&&options.permission!==grokPermission(native))throw fail('Grok permission is fixed when its process starts. Set the destination default before creating a new session.')
    if(runtimeKind==='opencode')return nativeSessions.perform(runtimeKind,native,'configure',options)
    if(runtimeKind==='default_agent')await ensureBuiltIn(native)
    const channel=runtimeKind==='default_agent'?null:await attach(native,runtimeKind)
    const call=async(method,params)=>{
      const result=runtimeKind==='default_agent'?await invoke(native,method,params):await rpc(channel,method,params)
      native.configuration={...native.configuration,...result};return result
    }
    await applyTaskConfiguration(call,native.sessionID,native.configuration??{},{runtimeKind,...options})
  }
  async function providers() {
    const agent=await defaultAgent.status()
    const statuses=await Promise.all([...catalog.values()].map(harnessStatus))
    // `locked` says a Mac must unlock Pi Durable (`POST /v1/default-agent/unlock`).
    return [{id:'default_agent',runtimeKind:'default_agent',displayName:'Pi Durable',routeName:'This workspace',available:!agent.locked,canStart:!agent.locked,canResume:true,canSteer:true,canStop:true,supportsApprovals:false,supportsQuestions:false,activeInputMode:'steer',...(agent.locked?{locked:true,unavailableReason:lockedMessage}:{})},
      ...statuses.map(status=>({id:status.id,runtimeKind:status.id,displayName:status.displayName,routeName:'This workspace',available:status.state==='ready',canStart:status.state==='ready',canResume:true,canSteer:true,canStop:true,supportsApprovals:true,supportsQuestions:status.id==='claude_code',activeInputMode:'steer'}))]
  }
  return {create,adopt,run,stop,steer,respond,providers,settings,configure,sessionOptions,
    async capabilities({native,runtimeKind}){const value=(await providers()).find(item=>item.runtimeKind===runtimeKind);return value&&(['codex','claude_code'].includes(runtimeKind)?{...value,canSteer:native.steeringSupported===true,activeInputMode:native.steeringSupported?'steer':'notNegotiated'}:value)},async cancelActive(){for(const fence of activeRuns.values())fence.stopped=true;for(const job of nativeJobs.values())job.controller.abort();await Promise.all([defaultAgent.cancelActive(),durableACP.stopAll()])},async close(){closed=true;for(const channel of channels.values()){channel.stopped=true;const error=fail('The native workspace service is shutting down.');for(const request of channel.pending.values())request.reject(error);channel.pending.clear();channel.run?.completion.reject(error)}for(const job of nativeJobs.values())job.controller.abort();await defaultAgent.cancelActive();await durableACP.stopAll();await Promise.allSettled([...channels.values()].map(channel=>channel.pump))}}
}
