import { randomUUID, createHash } from 'node:crypto'
import { applyTaskConfiguration } from './task-gateway-runner.mjs'
import { clientInteraction, clientInteractionResponse } from './client-interactions.mjs'
import { createTaskNativeArchive, piRunEvent, publishNativePresentation } from './task-native-archive.mjs'
import { createNativeClientSessions } from './client-native-sessions.mjs'
import { createNativeTaskExecutor } from './task-gateway-native.mjs'

const delay = milliseconds => new Promise(resolve => setTimeout(resolve,milliseconds))
const fail = message => Object.assign(new Error(message), { statusCode: 409 })
const deferred = () => { let resolve,reject; const promise = new Promise((a,b)=>{resolve=a;reject=b}); promise.catch(()=>{}); return {promise,resolve,reject} }

// Native runtimes remain the execution owners. This adapter projects their
// output into the common client contract without lending a client process any
// ownership over the run or replaying a prompt on reconnect.
export function createClientExecutionRuntime({ defaultAgent, durableACP, catalog, workspaceRoot, harnessStatus,
  environment, hermes, instances, isExecutionEnabled = () => true }) {
  const channels = new Map(), builtIn = new Map(), nativeJobs = new Map(), activeRuns = new Map()
  const nativeExecutor = createNativeTaskExecutor({workspaceRoot,environment,hermes,instances})
  const nativeSessions = createNativeClientSessions({workspaceRoot,environment,hermes,instances})
  let closed = false
  async function invoke(native,method,params) {
    return (await defaultAgent.invoke({method,attachmentToken:native.attachmentToken,params:{sessionId:native.sessionID,...params}})).result
  }
  async function attach(native,runtimeKind) {
    if (channels.has(native.channelID) && !channels.get(native.channelID).stopped) return channels.get(native.channelID)
    channels.delete(native.channelID)
    let recovered=false
    let page = await durableACP.handle('POST','/v1/durable-acp/attach',{channelID:native.channelID,harnessID:runtimeKind,cwd:workspaceRoot,attachmentProtocol:1})
    if (page.state === 'stopped' && native.sessionID) {
      page=await durableACP.handle('POST','/v1/durable-acp/recover',{channelID:native.channelID,harnessID:runtimeKind,cwd:workspaceRoot,attachmentProtocol:1,nativeSessionID:native.sessionID})
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
    if(recovered) {
      try {
        if(runtimeKind==='pi')native.configuration=await rpc(channel,'get_state')
        else {
          const initialized=await rpc(channel,'initialize',{protocolVersion:1,clientCapabilities:{fs:{readTextFile:false,writeTextFile:false},terminal:false,elicitation:{form:{}}},clientInfo:{name:'Woven Matter Workspace',version:'1'}})
          if(initialized.protocolVersion!==1)throw fail('Unsupported native agent protocol.')
          native.steeringSupported=initialized._meta?.steering?.supported===true
          native.configuration=await rpc(channel,'session/load',{sessionId:native.sessionID,cwd:workspaceRoot,mcpServers:[]})
        }
        if(native.configuration.sessionId!==native.sessionID)throw fail('The reopened native session has a different identity.')
      } catch(error){channel.stopped=true;channels.delete(native.channelID);throw error}
    }
    return channel
  }
  function receive(channel,message) {
    const run=channel.run
    if (message.id != null && (!message.method || message.type==='response')) {
      const request=channel.pending.get(String(message.id))
      if(request){channel.pending.delete(String(message.id));if(message.error||message.success===false)request.reject(fail('The native agent rejected this operation.'));else request.resolve(message.result??message.data??{})}
    }
    if(!run)return
    if(message.method==='session/update' && message.params?.sessionId===channel.native.sessionID)run.publish(message.params.update)
    if(message.method==='session/request_permission' && message.params?.sessionId===channel.native.sessionID) {
      const id=String(message.id)+':'+createHash('sha256').update(JSON.stringify(message)).digest('hex')
      channel.callbacks.set(id,message)
      run.interaction({id,kind:'approval',title:message.params?.toolCall?.title??'Agent needs approval',options:(message.params?.options??[]).map(option=>({id:option.optionId,label:option.name})),questions:[]})
    } else if(['elicitation/create','cursor/ask_question','cursor/create_plan'].includes(message.method)&&message.id!=null) {
      try {
        if(message.params?.sessionId&&message.params.sessionId!==channel.native.sessionID)throw fail('Interaction belongs to another session.')
        const projection=clientInteraction(message),id=String(message.id)+':'+createHash('sha256').update(JSON.stringify(message)).digest('hex')
        channel.callbacks.set(id,message)
        run.publish({sessionUpdate:'woven_interaction',request:message})
        run.interaction({id,...projection})
      } catch {
        void write(channel,{jsonrpc:'2.0',id:message.id,error:{code:-32602,message:'Unsupported interaction schema; use the native desktop interface.'}},randomUUID()).catch(error=>run.completion.reject(error))
      }
    } else if(channel.runtimeKind!=='pi' && message.method && message.id!=null) {
      // Do not expose arbitrary host filesystem/client RPC calls through the
      // direct API. Native workspace tools run in the execution host itself.
      void write(channel,{jsonrpc:'2.0',id:message.id,error:{code:-32601,message:'This client operation is unavailable.'}},randomUUID()).catch(error=>run.completion.reject(error))
    }
    if(run.archive && piRunEvent(message.type))void run.archive.capture(message,{kind:message.type,present:safe=>{
      const update=safe.assistantMessageEvent
      if(safe.type==='message_update'&&update?.type==='text_delta')publishNativePresentation({sessionUpdate:'agent_message_chunk',content:{type:'text',text:update.delta??''}},run.publish)
      if(safe.type==='message_update'&&update?.type==='thinking_delta')publishNativePresentation({sessionUpdate:'agent_thought_chunk',content:{type:'text',text:update.delta??''}},run.publish)
      if(['tool_execution_start','tool_execution_update','tool_execution_end'].includes(safe.type))publishNativePresentation({sessionUpdate:'tool_call_update',toolCallId:safe.toolCallId,title:safe.toolName,status:safe.type==='tool_execution_end'?(safe.isError?'failed':'completed'):'running',content:[{type:'content',content:{type:'text',text:JSON.stringify(safe.result??safe.partialResult??safe.args??{})}}]},run.publish)
    }}).catch(error=>run.completion.reject(error))
    if(message.type==='extension_ui_request') {
      const id=String(message.id)+':'+createHash('sha256').update(JSON.stringify(message)).digest('hex');channel.callbacks.set(id,message)
      const options=(message.options??[]).map(option=>({id:typeof option==='string'?option:option.value??option.label,label:typeof option==='string'?option:option.label}))
      run.interaction({id,kind:message.method==='confirm'?'approval':'question',title:message.title??'Agent question',options:message.method==='confirm'?[{id:'yes',label:'Allow'},{id:'no',label:'Deny'}]:[],questions:message.method==='confirm'?[]:[{id:'answer',prompt:message.message??message.title??'Response',options,allowsMultiple:false,allowsFreeText:!options.length}]})
    }
    if(message.type==='agent_settled')run.completion.resolve({})
    if(message.type==='message_end'&&['error','aborted'].includes(message.message?.stopReason))run.completion.reject(fail('The native agent stopped before completion.'))
  }
  async function write(channel,message,deliveryID) {
    return durableACP.handle('POST','/v1/durable-acp/message',{channelID:channel.native.channelID,attachmentToken:channel.token,deliveryID,message})
  }
  async function rpc(channel,method,params={},deliveryID=randomUUID()) {
    const id=randomUUID(), pending=deferred();channel.pending.set(id,pending)
    try {
      await write(channel,channel.runtimeKind==='pi'?{id,type:method,...params}:{jsonrpc:'2.0',id,method,params},deliveryID)
      let timer
      try {return await Promise.race([pending.promise,new Promise((_,reject)=>{timer=setTimeout(()=>reject(fail('The native agent did not acknowledge this operation.')),method==='session/prompt'?24*3600000:30000);timer.unref()})])}
      finally{clearTimeout(timer)}
    } finally {channel.pending.delete(id)}
  }
  async function create({runtimeKind,conversationID,workspaceID}) {
    if(!isExecutionEnabled())throw fail('Background execution is disabled for this workspace.')
    if(runtimeKind==='default_agent') {
      const status=await defaultAgent.status()
      if(status.locked)throw fail('Pi Durable is locked. Reconnect the central Mac to unlock its configured accounts.')
      const opened=await defaultAgent.invoke({method:'session/new',attachmentProtocol:1,params:{cwd:workspaceRoot}})
      return {sessionID:opened.result.sessionId,attachmentToken:opened.result._meta?.attachmentToken,epoch:status.epoch,configuration:opened.result}
    }
    if(['hermes','opencode'].includes(runtimeKind))return nativeSessions.perform(runtimeKind,{sessionID:null,conversationID,workspaceID},'create')
    const harness=catalog.get(runtimeKind)
    if(!harness||!['acp','agent-stdio','acp-and-gateway','rpc'].includes(harness.transport))throw fail('This native runtime is unavailable for direct execution.')
    const native={channelID:conversationID,sessionID:null}
    const channel=await attach(native,runtimeKind)
    if(runtimeKind==='pi'){native.configuration=await rpc(channel,'get_state');native.sessionID=native.configuration.sessionId}
    else {
      const initialized=await rpc(channel,'initialize',{protocolVersion:1,clientCapabilities:{fs:{readTextFile:false,writeTextFile:false},terminal:false,elicitation:{form:{}},...(runtimeKind==='cursor'?{_meta:{parameterizedModelPicker:true}}:{})},clientInfo:{name:'Woven Matter Workspace',version:'1'}})
      native.steeringSupported=initialized._meta?.steering?.supported===true
      if(initialized.protocolVersion!==1)throw fail('Unsupported native agent protocol.')
      native.configuration=await rpc(channel,'session/new',{cwd:workspaceRoot,mcpServers:[]});native.sessionID=native.configuration.sessionId
    }
    if(typeof native.sessionID!=='string'||!native.sessionID)throw fail('The native agent did not create a session.')
    return native
  }
  async function adopt({native,runtimeKind}) {
    if(typeof native?.sessionID!=='string'||!native.sessionID||native.sessionID.length>4096)throw fail('A native session identity is required.')
    if(runtimeKind==='default_agent') {
      const status=await defaultAgent.status()
      if(status.locked)throw fail('Unlock Pi Durable before moving client ownership.')
      const opened=await defaultAgent.invoke({method:'woven/adopt',attachmentProtocol:1,params:{sessionId:native.sessionID}})
      if(opened.result.sessionId!==native.sessionID)throw fail('Native session identity changed.')
      return {sessionID:native.sessionID,epoch:status.epoch,attachmentToken:opened.result._meta?.attachmentToken,configuration:opened.result}
    }
    if(['hermes','opencode'].includes(runtimeKind))return nativeSessions.perform(runtimeKind,native,'adopt')
    if(typeof native.channelID!=='string')throw fail('The native durable channel identity is required.')
    const page=await durableACP.handle('POST','/v1/durable-acp/adopt',{channelID:native.channelID,harnessID:runtimeKind,cwd:workspaceRoot,attachmentProtocol:1,expectedNativeSessionID:native.sessionID})
    const actual=runtimeKind==='pi'?page.snapshot.piState?.sessionId:page.snapshot.session?.sessionId
    if(actual!==native.sessionID)throw fail('The durable channel belongs to a different native session.')
    const result={sessionID:native.sessionID,channelID:native.channelID,configuration:page.snapshot.session??page.snapshot.piState,steeringSupported:page.snapshot.initialized?._meta?.steering?.supported===true}
    await attach(result,runtimeKind)
    return result
  }
  async function run(options) {
    const fence = { stopped: false, stopping: null }
    activeRuns.set(options.command.runID, fence)
    try { return await runAccepted(options, fence) }
    finally { activeRuns.delete(options.command.runID) }
  }
  function requireActive(fence) {
    if (closed || fence.stopped) throw fail('This run stopped before native dispatch.')
  }
  async function runAccepted({native,runtimeKind,command,publish,interaction}, fence) {
    if(!isExecutionEnabled())throw fail('Background execution is disabled for this workspace.')
    if(runtimeKind==='default_agent') {
      const job={native,command};builtIn.set(command.runID,job)
      try {
        await ensureBuiltIn(native)
        await fence.stopping?.promise; requireActive(fence)
        publish({sessionUpdate:'woven_execution_binding',native})
        const reply=await defaultAgent.invoke({operationID:command.runID,method:'session/prompt',attachmentToken:native.attachmentToken,
          params:{sessionId:native.sessionID,prompt:[{type:'text',text:command.text}],_meta:{wovenRunID:command.runID,wovenInputID:command.commandID}}})
        let after=0
        while(!closed) {
          const page=await defaultAgent.poll(reply.operationID,after)
          for(const update of page.updates)publish(update)
          after=page.cursor
          if(page.done){if(page.error)throw fail('Pi Durable could not complete this run. Its accepted input will not be replayed.');return}
          await delay(100)
        }
      } finally {builtIn.delete(command.runID)}
      return
    }
    if(['hermes','opencode'].includes(runtimeKind)) {
      const controller=new AbortController(),job={controller,native,control:null};nativeJobs.set(command.runID,job)
      try {return await nativeExecutor({run:{id:command.runID,title:command.text.slice(0,100),task:{prompt:command.text,configuration:{runtimeKind,workspaceID:native.workspaceID,nativeWorkingDirectory:native.nativeWorkingDirectory}}},nativeSessionID:native.sessionID,signal:controller.signal,publish,
        bindSession:id=>{native.sessionID=id;publish({sessionUpdate:'woven_execution_binding',native})},
        interactive:{publish:interaction,bind:control=>{job.control=control}}})}
      finally {nativeJobs.delete(command.runID)}
    }
    const channel=await attach(native,runtimeKind),completion=deferred()
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
    channel.run={command,publish,interaction,completion}
    let archive
    try {
      if(runtimeKind==='pi') {
        const state=await rpc(channel,'get_state')
        if(state.sessionId!==native.sessionID)throw fail('Pi returned a different native session.')
        archive=await createTaskNativeArchive({sourceID:'pi:'+(state.sessionFile??workspaceRoot),nativeSessionID:native.sessionID,runID:command.runID,publish})
        channel.run.archive=archive
        const captureEntries=async(currentRun,since)=>{
          const snapshot=await rpc(channel,'get_entries',since?{since}:{})
          if(!Array.isArray(snapshot.entries))throw fail('Pi returned an incomplete native entry export.')
          const seen=new Set()
          for(const entry of snapshot.entries){
            if(typeof entry.id!=='string'||!entry.id||seen.has(entry.id))throw fail('Pi returned duplicate or missing native entry identities.')
            seen.add(entry.id)
            await archive.capture(entry,{id:'entry:'+entry.id,kind:entry.type??'entry',contentMode:'snapshot',completeness:'native-export',currentRun})
          }
          return snapshot.entries.at(-1)?.id
        }
        const cursor=await captureEntries(false)
        await fence.stopping?.promise; requireActive(fence)
        await rpc(channel,'prompt',{message:command.text,_meta:{wovenRunID:command.runID}},command.commandID)
        await completion.promise
        await archive.drain()
        await captureEntries(true,cursor)
      }
      else await Promise.race([(async()=>{
        let failure
        await fence.stopping?.promise; requireActive(fence)
        try {await rpc(channel,'session/prompt',{sessionId:native.sessionID,prompt:[{type:'text',text:command.text}],_meta:{wovenRunID:command.runID}},command.commandID)} catch(error){failure=error}
        while(!closed&&!channel.stopped&&(channel.busy||channel.pendingInputs))await delay(25)
        if(closed||channel.stopped)throw fail('The native workspace session stopped.')
        if(failure||channel.run?.nativeError)throw failure??channel.run.nativeError
      })(),completion.promise])
    } finally {await archive?.close();channel.run=null;channel.callbacks.clear()}
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
    if(['hermes','opencode'].includes(runtimeKind)){const job=nativeJobs.get(command.runID);if(!job)throw fail('The native run is no longer active.');job.controller.abort();return}
    const channel=await attach(native,runtimeKind)
    if(runtimeKind==='pi')await write(channel,{type:'abort',_meta:{wovenStopPreflight:true}},command.commandID)
    else await write(channel,{jsonrpc:'2.0',method:'session/cancel',params:{sessionId:native.sessionID}},command.commandID)
  }
  async function steer({native,runtimeKind,command}) {
    if(runtimeKind==='default_agent') {
      const result=await invoke(native,'_session/steering',{prompt:[{type:'text',text:command.text}],_meta:{wovenRunID:command.runID,wovenInputID:command.commandID}})
      if(result.outcome==='promptRequired')throw fail('That run has finished. Send a new message.')
      return
    }
    if(['hermes','opencode'].includes(runtimeKind)){const control=nativeJobs.get(command.runID)?.control;if(!control?.steer)throw fail('This native run does not support steering.');return control.steer(command.text,command.commandID)}
    const channel=await attach(native,runtimeKind)
    if(runtimeKind==='pi')return rpc(channel,'prompt',{message:command.text,streamingBehavior:'steer',_meta:{wovenRunID:command.runID}},command.commandID)
    if(!channel.run||channel.run.command.runID!==command.runID)throw fail('That run has finished. Send a new message.')
    if(['cursor','openclaw'].includes(runtimeKind)) {
      // Concurrent native prompts acknowledge durable dispatch immediately, so
      // Stop is not trapped behind an entire native turn in the command queue.
      const id=randomUUID(),request=deferred(),run=channel.run
      channel.pending.set(id,request);channel.pendingInputs++
      try {await write(channel,{jsonrpc:'2.0',id,method:'session/prompt',params:{sessionId:native.sessionID,prompt:[{type:'text',text:command.text}],_meta:{wovenRunID:command.runID}}},command.commandID)}
      catch(error){channel.pending.delete(id);channel.pendingInputs--;throw error}
      const timer=setTimeout(()=>request.reject(fail('The native agent did not finish this input.')),24*3600000);timer.unref()
      void request.promise.catch(error=>{run.nativeError=error}).finally(()=>{clearTimeout(timer);channel.pending.delete(id);channel.pendingInputs--})
      return
    }
    if(runtimeKind==='grok_build')return rpc(channel,'_x.ai/interject',{sessionId:native.sessionID,text:command.text},command.commandID)
    if(!native.steeringSupported)throw fail('This native agent does not support steering.')
    const result=await rpc(channel,'_session/steering',{sessionId:native.sessionID,prompt:[{type:'text',text:command.text}],_meta:{wovenRunID:command.runID,steering:{idleBehavior:'promptRequired'}}},command.commandID)
    if(!['injected','startedNewTurn'].includes(result.outcome))throw fail('That run has finished. Send a new message.')
    return result
  }
  async function respond({native,runtimeKind,command}) {
    if(runtimeKind==='default_agent')throw fail('Pi Durable has no pending approval for this run.')
    if(['hermes','opencode'].includes(runtimeKind)){const control=nativeJobs.get(command.runID)?.control;if(!control?.respond)throw fail('This interaction is no longer active.');return control.respond(command.interactionID,command.response)}
    const channel=await attach(native,runtimeKind),request=channel.callbacks.get(command.interactionID)
    if(!request)throw fail('This interaction is no longer active.')
    const response=command.response
    if(runtimeKind==='pi')await write(channel,{type:'extension_ui_response',id:request.id,...(request.method==='confirm'?{confirmed:!response.cancelled&&response.optionID==='yes'}:{value:Object.values(response.answers??{}).flat().join('\n')}),cancelled:response.cancelled},command.commandID)
    else {
      const result=['elicitation/create','cursor/ask_question','cursor/create_plan'].includes(request.method)?clientInteractionResponse(request,response):{outcome:response.cancelled?{outcome:'cancelled'}:{outcome:'selected',optionId:response.optionID}}
      channel.run?.publish({sessionUpdate:'woven_interaction_response',requestID:command.interactionID,response:result})
      await write(channel,{jsonrpc:'2.0',id:request.id,result},command.commandID)
    }
    channel.callbacks.delete(command.interactionID)
  }
  async function ensureBuiltIn(native) {
    const status=await defaultAgent.status()
    if(status.locked)throw fail('Pi Durable is locked. Reconnect an authorized client to restore the workspace account grant.')
    if(native.epoch===status.epoch)return
    const opened=await defaultAgent.invoke({method:'session/load',attachmentProtocol:1,params:{cwd:workspaceRoot,sessionId:native.sessionID}})
    if(opened.result.sessionId!==native.sessionID)throw fail('Pi Durable reopened a different native session.')
    native.attachmentToken=opened.result._meta?.attachmentToken;native.epoch=status.epoch;native.configuration=opened.result
  }
  const selections = options => (options??[]).flatMap(item=>item.value!=null?[{id:String(item.value),label:item.name??String(item.value)}]:selections(item.options))
  async function settings({native,runtimeKind}) {
    if(['hermes','opencode'].includes(runtimeKind))return nativeSessions.perform(runtimeKind,native,'settings')
    let initial=native.configuration??{}
    if(runtimeKind==='default_agent'){await ensureBuiltIn(native);initial=native.configuration}
    if(runtimeKind==='pi') {
      const channel=await attach(native,runtimeKind),state=await rpc(channel,'get_state'),available=await rpc(channel,'get_available_models'),thinking=await rpc(channel,'get_available_thinking_levels')
      return {model:state.model?`${state.model.provider}/${state.model.id}`:null,thinking:state.thinkingLevel,models:(available.models??[]).map(item=>({id:`${item.provider}/${item.id}`,label:item.name??item.id})),thinkingLevels:(thinking.levels??[]).map(id=>({id,label:id})),permissions:[],availableTools:[],enabledTools:[],canConfigure:true}
    }
    const model=initial.configOptions?.find(item=>item.id==='model'||item.category==='model')
    const thinking=initial.configOptions?.find(item=>['effort','thinking','reasoning_effort'].includes(item.id)||item.category==='thought_level')
    const permission=initial.configOptions?.find(item=>['permission_mode','approval_mode','mode'].includes(item.id))
    return {model:model?.currentValue??initial.models?.currentModelId,thinking:thinking?.currentValue,permission:permission?.currentValue,
      models:model?selections(model.options):(initial.models?.availableModels??[]).map(item=>({id:item.modelId,label:item.name??item.modelId})),
      thinkingLevels:selections(thinking?.options),permissions:selections(permission?.options),availableTools:[],enabledTools:[],canConfigure:!['hermes','opencode'].includes(runtimeKind)}
  }
  async function configure({native,runtimeKind,options}) {
    if(['hermes','opencode'].includes(runtimeKind))return nativeSessions.perform(runtimeKind,native,'configure',options)
    if(runtimeKind==='default_agent')await ensureBuiltIn(native)
    const channel=runtimeKind==='default_agent'?null:await attach(native,runtimeKind)
    if(runtimeKind==='pi') {
      if(options.permission)throw fail('Pi does not offer a permission selector.')
      if(options.model){const index=options.model.indexOf('/');if(index<1)throw fail('Invalid Pi model.');await rpc(channel,'set_model',{provider:options.model.slice(0,index),modelId:options.model.slice(index+1)})}
      if(options.thinking)await rpc(channel,'set_thinking_level',{level:options.thinking})
      native.configuration=await rpc(channel,'get_state');return
    }
    const call=async(method,params)=>{
      const result=runtimeKind==='default_agent'?await invoke(native,method,params):await rpc(channel,method,params)
      native.configuration={...native.configuration,...result};return result
    }
    await applyTaskConfiguration(call,native.sessionID,native.configuration??{},{runtimeKind,...options})
  }
  async function providers() {
    const agent=await defaultAgent.status()
    const statuses=await Promise.all([...catalog.values()].map(harnessStatus))
    const values=[{id:'default_agent',runtimeKind:'default_agent',displayName:'Pi Durable',routeName:'This workspace',available:!agent.locked,canStart:!agent.locked,canResume:true,canSteer:true,canStop:true,supportsApprovals:false,supportsQuestions:false,activeInputMode:'steer',...(agent.locked?{unavailableReason:'Reconnect the central Mac to unlock configured accounts.'}:{})},
      ...statuses.map(status=>({id:status.id,runtimeKind:status.id,displayName:status.displayName,routeName:'This workspace',available:status.state==='ready',canStart:status.state==='ready',canResume:true,canSteer:status.id!=='opencode',canStop:true,supportsApprovals:true,supportsQuestions:['pi','hermes','claude_code','cursor'].includes(status.id),activeInputMode:status.id==='opencode'?'notNegotiated':'steer'}))]
    return isExecutionEnabled()?values:values.map(value=>({...value,available:false,canStart:false,unavailableReason:'Background execution is disabled for this workspace.'}))
  }
  return {create,adopt,run,stop,steer,respond,providers,settings,configure,
    async capabilities({native,runtimeKind}){const value=(await providers()).find(item=>item.runtimeKind===runtimeKind);return value&&(['codex','claude_code'].includes(runtimeKind)?{...value,canSteer:native.steeringSupported===true,activeInputMode:native.steeringSupported?'steer':'notNegotiated'}:value)},async cancelActive(){for(const fence of activeRuns.values())fence.stopped=true;for(const job of nativeJobs.values())job.controller.abort();await Promise.all([defaultAgent.cancelActive(),durableACP.stopAll()])},async close(){closed=true;for(const channel of channels.values()){channel.stopped=true;const error=fail('The native workspace service is shutting down.');for(const request of channel.pending.values())request.reject(error);channel.pending.clear();channel.run?.completion.reject(error)}for(const job of nativeJobs.values())job.controller.abort();await defaultAgent.cancelActive();await durableACP.stopAll();await Promise.allSettled([...channels.values()].map(channel=>channel.pump))}}
}
