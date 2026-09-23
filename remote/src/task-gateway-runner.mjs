import { createNativeTaskExecutor } from './task-gateway-native.mjs'
import { spawn } from 'node:child_process'
import { createInterface } from 'node:readline'
import { isAbsolute } from 'node:path'

const before = message => Object.assign(new Error(message), { beforePrompt:true })
const values = options => (options ?? []).flatMap(o => o.value == null ? values(o.options) : [o.value])
const delay = ms => new Promise(done => setTimeout(done,ms))

// Only apply options actually advertised by the native agent. Unsupported
// saved selections fail before submission rather than silently widening policy.
export async function applyTaskConfiguration(rpc, sessionID, initial, configuration) {
  let current = initial
  for (const [category,wanted] of [['model',configuration.runtimeKind==='cursor' && configuration.model ? configuration.model.trim().split('[')[0] : configuration.model],['thinking',configuration.thinking],['permission',configuration.permission]]) {
    if (!wanted) continue
    if (category === 'permission' && configuration.runtimeKind === 'grok_build') continue // explicit CLI policy
    if (category === 'permission' && configuration.runtimeKind === 'cursor') {
      if (!['normal','auto'].includes(wanted)) throw before('The saved Cursor permission is unavailable.')
      continue
    }
    const option = (current.configOptions ?? []).find(o => category === 'model' ? o.id === 'model' || o.category === 'model'
      : category === 'thinking' ? ['effort','reasoning_effort','thinking'].includes(o.id) || o.category === 'thought_level'
        : ['permission_mode','approval_mode'].includes(o.id) || (o.id === 'mode' && ['codex','claude_code'].includes(configuration.runtimeKind)))
    if (option) {
      if (!values(option.options).includes(wanted)) throw before(`The saved ${category} is no longer available.`)
      if (option.currentValue !== wanted) {
        const result = await rpc('session/set_config_option',{sessionId:sessionID,configId:option.id,value:wanted})
        current = { ...current,...result }
        if (result?.configOptions?.find(x=>x.id===option.id)?.currentValue !== wanted) throw before(`The agent did not confirm the saved ${category}.`)
      }
    } else if (category === 'model' && current.models?.availableModels?.some(x=>x.modelId===wanted)) {
      if (current.models.currentModelId !== wanted) await rpc('session/set_model',{sessionId:sessionID,modelId:wanted})
    } else if (category === 'permission' && current.modes?.availableModes?.some(x=>x.id===wanted)) {
      if (current.modes.currentModeId !== wanted) await rpc('session/set_mode',{sessionId:sessionID,modeId:wanted})
    } else throw before(`This agent cannot apply the task's saved ${category}.`)
  }
}

export function createTaskExecutor({ catalog,workspaceRoot,environment,defaultAgent,hermes,instances,launch = spawn,isEnabled = async()=>true }) {
  const native = createNativeTaskExecutor({workspaceRoot,environment,launch,hermes,instances})
  return async ({run,nativeSessionID,signal,publish,bindSession}) => {
    const config = run.task.configuration
    if (signal.aborted) throw before('Background execution was turned off.')
    if (config.runtimeKind === 'default_agent') return runBuiltIn({run,nativeSessionID,signal,publish,bindSession,defaultAgent,workspaceRoot})
    if (['pi','hermes','opencode'].includes(config.runtimeKind)) {
      if (!await isEnabled(config.runtimeKind)) throw before('This agent is disabled in the workspace.')
      return native({run,nativeSessionID,signal,publish,bindSession})
    }
    const harness = catalog.get(config.runtimeKind)
    if (!harness || !['acp','agent-stdio','acp-and-gateway'].includes(harness.transport)) throw before('This agent does not yet support autonomous workspace tasks. Use a connected session for this agent.')
    if (!await isEnabled(harness.id)) throw before('This agent is disabled in the workspace.')
    if (signal.aborted) throw before('Background execution was turned off.')
    const directory = config.nativeWorkingDirectory ?? workspaceRoot
    if (!isAbsolute(directory) || directory.includes('\0')) throw before('The task working directory is invalid.')
    let args = [...harness.arguments]
    if (harness.id === 'grok_build' && config.permission) {
      if (!['default','acceptEdits','auto','bypassPermissions','dontAsk'].includes(config.permission)) throw before('The saved Grok permission is unavailable.')
      const index = args.indexOf('--permission-mode'); if (index >= 0) args.splice(index,2)
      args.unshift('--permission-mode',config.permission)
      const agentIndex=args.indexOf('agent');if(agentIndex>=0)args.splice(agentIndex+1,0,'--no-leader')
    }
    const env = { ...environment() }
    // Never lend a connected Mac session's identity/tool authority to a task.
    for (const key of Object.keys(env)) if (key.startsWith('WOVENMATTER_SESSION_') || key.startsWith('WOVENMATTER_TOOL_')) delete env[key]
    const child = launch(harness.command,args,{cwd:directory,env,stdio:['pipe','pipe','pipe']})
    let count=0, sessionID, accepted=false, terminal=false, bufferBytes=0, needsApproval=false
    const pending = new Map()
    const failAll = error => { for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(error) }; pending.clear() }
    const send = message => { if (!child.stdin.writable || terminal) throw new Error('The agent disconnected.'); child.stdin.write(JSON.stringify(message)+'\n') }
    const rpc = (method,params) => new Promise((done,reject) => {
      const id=++count
      const timer=setTimeout(()=>{ pending.delete(id); reject(new Error('The agent did not respond in time.')) },method==='session/prompt'?24*3600000:30000)
      pending.set(id,{done,reject,timer})
      try { send({jsonrpc:'2.0',id,method,params}) } catch(error) { clearTimeout(timer);pending.delete(id);reject(error) }
    })
    child.stdin.on('error',()=>failAll(new Error('The agent input connection closed.')))
    child.stderr.on('data',()=>{}) // Provider output can contain secrets; don't copy it into result errors.
    const lines=createInterface({input:child.stdout})
    const receiveLine = line => {
      bufferBytes+=Buffer.byteLength(line)
      if (line.length>1048576 || bufferBytes>64*1024*1024) { child.kill('SIGTERM');failAll(new Error('The task exceeded its response limit.'));return }
      let message;try { message=JSON.parse(line) } catch { return }
      if (!message || typeof message !== 'object' || Array.isArray(message)) return
      if (message.method && message.id != null) {
        if (message.method==='session/request_permission') {
          const allow=config.runtimeKind==='cursor' && config.permission==='auto' && message.params?.options?.find(o=>o.kind==='allow_once')
          send({jsonrpc:'2.0',id:message.id,result:{outcome:allow?{outcome:'selected',optionId:allow.optionId}:{outcome:'cancelled'}}})
          if (!allow) { needsApproval=true; publish({sessionUpdate:'agent_message_chunk',content:{type:'text',text:'\nThis task needs approval. Open its session to continue.\n'}}) }
        } else send({jsonrpc:'2.0',id:message.id,error:{code:-32601,message:'This background task cannot access interactive client tools.'}})
      } else if (message.method==='session/update' && message.params?.update) publish(message.params.update)
      else if (message.id!=null && pending.has(message.id)) {
        const entry=pending.get(message.id);pending.delete(message.id);clearTimeout(entry.timer)
        if (message.error) entry.reject(new Error('The agent could not complete this operation. Check its account and saved task settings.'))
        else entry.done(message.result ?? {})
      }
    }
    lines.on('line', line => {
      try { receiveLine(line) }
      catch {
        failAll(new Error('The task output could not be retained.'))
        child.kill('SIGTERM')
      }
    })
    child.on('error',()=>{terminal=true;failAll(new Error('The scheduled agent could not be started.'))})
    child.on('exit',()=>{terminal=true;failAll(new Error('The scheduled agent stopped before completing.'))})
    const abort=()=>{
      if(sessionID) try { send({jsonrpc:'2.0',method:'session/cancel',params:{sessionId:sessionID}}) } catch {}
      child.kill('SIGTERM');failAll(new Error('Background execution was turned off.'))
    }
    signal.addEventListener('abort',abort,{once:true})
    try {
      const initialized=await rpc('initialize',{protocolVersion:1,clientCapabilities:{fs:{readTextFile:false,writeTextFile:false},terminal:false},clientInfo:{name:'Woven Matter Task Gateway',version:'1'}})
      if (initialized.protocolVersion!==1) throw before('The scheduled agent uses an unsupported protocol.')
      if (nativeSessionID && initialized.agentCapabilities?.loadSession!==true) throw before('This agent cannot reopen the recurring task session.')
      const opened=await rpc(nativeSessionID?'session/load':'session/new',{cwd:directory,mcpServers:[],...(nativeSessionID?{sessionId:nativeSessionID}:{}),_meta:{sessionTitle:run.title}})
      sessionID=opened.sessionId ?? nativeSessionID
      if (typeof sessionID!=='string' || !sessionID) throw before('The agent did not create a session.')
      bindSession(sessionID)
      await applyTaskConfiguration(rpc,sessionID,opened,config)
      if (signal.aborted) throw before('Background execution was turned off.')
      accepted=true
      const result = await rpc('session/prompt',{sessionId:sessionID,prompt:[{type:'text',text:backgroundPrompt(run)}],_meta:{wovenRunID:run.id}})
      if (needsApproval) throw Object.assign(new Error('This task needs approval. Open its session to continue.'),{needsApproval:true})
      return result
    } catch(error) { if(!accepted) error.beforePrompt=true;throw error }
    finally {
      signal.removeEventListener('abort',abort);lines.close();failAll(new Error('The scheduled agent connection closed.'))
      child.kill('SIGTERM')
      if(!terminal) { await Promise.race([new Promise(done=>child.once('exit',done)),delay(1500)]);if(!terminal)child.kill('SIGKILL') }
    }
  }
}

async function runBuiltIn({run,nativeSessionID,signal,publish,bindSession,defaultAgent,workspaceRoot}) {
  const cwd = run.task.configuration.nativeWorkingDirectory ?? workspaceRoot
  if (!isAbsolute(cwd) || cwd.includes('\0')) throw before('The task working directory is invalid.')
  let sessionID,accepted=false
  try {
    if((await defaultAgent.status()).locked) throw Object.assign(before('Waiting for Woven Matter to reconnect and unlock the Built-in agent.'),{deferred:true})
    const opened=await defaultAgent.invoke({method:nativeSessionID?'session/load':'session/new',params:{cwd,...(nativeSessionID?{sessionId:nativeSessionID}:{})}})
    const session=opened.result
    sessionID=session?.sessionId ?? nativeSessionID
    if(!sessionID) throw before('The Built-in task session is unavailable.')
    bindSession(sessionID)
    await applyTaskConfiguration(async(method,params)=>(await defaultAgent.invoke({method,params})).result,sessionID,session,run.task.configuration)
    if(signal.aborted) throw before('Background execution was turned off.')
    accepted=true
    const {operationID}=await defaultAgent.invoke({operationID:run.id,method:'session/prompt',params:{sessionId:sessionID,prompt:[{type:'text',text:backgroundPrompt(run)}],_meta:{wovenRunID:run.id}}})
    let cursor=0,cancelled=false,needsApproval=false
    while(true) {
      if(signal.aborted && !cancelled) { cancelled=true;await defaultAgent.invoke({method:'session/cancel',params:{sessionId:sessionID}}) }
      const page=await defaultAgent.poll(operationID,cursor)
      for(const update of page.updates) {
        if(update.sessionUpdate==='woven_permission') { needsApproval=true;await defaultAgent.invoke({method:'woven/permission',params:{id:update.id,result:{outcome:{outcome:'cancelled'}}}}) }
        else publish(update)
      }
      cursor=page.cursor
      if(page.done) { if(needsApproval)throw Object.assign(new Error('This task needs approval. Open its session to continue.'),{needsApproval:true});if(page.error)throw new Error(page.error);if(cancelled)throw new Error('Background execution was turned off.');return page.result }
      await delay(100)
    }
  } catch(error) {
    if (accepted && sessionID) {
      try { await defaultAgent.invoke({method:'session/cancel',params:{sessionId:sessionID}}) } catch {}
    } else error.beforePrompt = true
    throw error
  }
}

function backgroundPrompt(run) {
  return '[Woven Matter background task: native workspace tools use this session’s saved permissions. Woven Matter notes, calendar, and other Mac workspace tools require the Mac app to be connected; do not claim access while it is disconnected.]\n\n' + run.task.prompt
}
