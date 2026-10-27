import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, openSync, readSync, closeSync } from 'node:fs'
import { createReadStream } from 'node:fs'
import { resolve } from 'node:path'
import { createHash, randomUUID } from 'node:crypto'
import { createInterface } from 'node:readline'
import { durableJSON } from './durable-json.mjs'
import { assemblePresentationFrame } from './presentation-frames.mjs'

const bundled = new URL('../default-agent/src/native-journal.mjs', import.meta.url)
const { sanitizeNativeTransportBytes } = await import(existsSync(bundled) ? bundled.href : new URL('../../default-agent/src/native-journal.mjs', import.meta.url).href)
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
const hash = value => createHash('sha256').update(value).digest('hex')
const stableID = value => { const h=hash('woven-retained-v1\0'+value); return `${h.slice(0,8)}-${h.slice(8,12)}-5${h.slice(13,16)}-a${h.slice(17,20)}-${h.slice(20,32)}` }
const read = (path, fallback) => { try { return JSON.parse(readFileSync(path,'utf8')) } catch(error) { if(error.code==='ENOENT')return fallback;throw error } }
const textParts = value => { const result=[];for(let start=0;start<value.length;) {let end=Math.min(start+16384,value.length);if(end<value.length&&/[\uD800-\uDBFF]/.test(value[end-1]))end--;result.push(value.slice(start,end));start=end}return result.length?result:[''] }

/// Workspace-owned archive bridge for the pre-client RPC and scheduled-task
/// paths. It reads their existing durable output; it never invokes a prompt,
/// adopts a live native session, or relies on a connected observer's polling.
export function createRetainedExecutionCapture({directory, defaultDirectory, taskGateway, defaultAgent, execution,
  resolveAssociation = async()=>null, now=()=>new Date().toISOString(), intervalMilliseconds=2000}) {
  mkdirSync(directory,{recursive:true,mode:0o700})
  const checkpointPath=resolve(directory,'checkpoint.json')
  let checkpoint=read(checkpointPath,{taskCursor:'0'})
  const active = new Set()
  let timer,pending,closed=false,lastError=null,unmapped=0
  const path = (kind,id)=>resolve(directory,kind+'-'+id+'.json')
  const save = (kind,id,value)=>durableJSON(path(kind,id),value)
  const stateFor = key=>read(path('projection',stableID(key)),{next:0,messages:[],activities:[],finished:false})
  function writeState(key,value){save('projection',stableID(key),value)}
  function event(binding,suffix,kind,payload) {
    return {eventID:stableID(binding.key+':'+suffix),conversationID:binding.conversationID,runID:binding.runID,kind,...payload}
  }
  async function importEntries(entries) {
    let batch=[],bytes=0
    for(const item of entries) {
      const size=Buffer.byteLength(JSON.stringify(item))
      if(size>1024*1024)throw new Error('Retained history record exceeds the publication envelope.')
      if(batch.length && (batch.length>=200 || bytes+size>7*1024*1024)) {await execution.importRetainedEvents(batch);batch=[];bytes=0}
      batch.push(item);bytes+=size
    }
    if(batch.length)await execution.importRetainedEvents(batch)
  }
  async function begin(binding) {
    if(!uuid(binding.conversationID)||!uuid(binding.runID)||typeof binding.nativeSessionID!=='string'||!binding.nativeSessionID)throw new Error('Retained execution has no verified native identity.')
    const workspace=execution.descriptor()
    const conversation={id:binding.conversationID,title:binding.title||'Conversation',runtimeKind:binding.runtimeKind,
      workspaceID:workspace.id,libraryID:workspace.libraryID,routeID:workspace.id,updatedAt:binding.completedAt}
    await importEntries([event(binding,'conversation','conversation',{conversation,retainedExecution:{source:binding.source,
      nativeSessionID:binding.nativeSessionID,runtimeKind:binding.runtimeKind,runID:binding.runID,status:binding.status}})])
    const state=stateFor(binding.key)
    if(state.finished)return state
    if(!state.initialized) {
      const user=textParts(binding.prompt??'').filter(Boolean).map((content,index)=>({id:index?`${binding.inputID??binding.runID+'-input'}-part-${index}`:binding.inputID??binding.runID+'-input',
        conversationID:binding.conversationID,runID:binding.runID,role:'user',content,createdAt:binding.startedAt}))
      if(user.length)await importEntries(user.map((message,index)=>event(binding,'input-'+index,'transcript',{transcript:{conversationID:binding.conversationID,messages:[message],activities:[]}})))
      state.initialized=true;writeState(binding.key,state)
    }
    return state
  }
  async function update(binding,state,value,index) {
    if(index<state.next)return
    if(index!==state.next)throw new Error('Retained history output has an ordinal gap.')
    const safe=await sanitizeNativeTransportBytes(JSON.stringify(value)),bytes=safe.bytes
    const recordID=stableID(binding.key+':native:'+index),sha256=hash(bytes),partCount=Math.max(1,Math.ceil(bytes.length/131072))
    const entries=[]
    for(let partIndex=0;partIndex<partCount;partIndex++)entries.push(event(binding,`native-${index}-${partIndex}`,'nativeRecord',{nativeRecord:{recordID,
      format:'woven-native-update-v1',partIndex,partCount,byteCount:bytes.length,sha256,data:bytes.subarray(partIndex*131072,(partIndex+1)*131072).toString('base64')}}))
    const next=structuredClone(state)
    next.presentationFrames??={}
    const update=assemblePresentationFrame(JSON.parse(bytes.toString('utf8')),next.presentationFrames),kind=update?.sessionUpdate
    if(kind==='agent_message_chunk') {
      const previous=next.messages.map(item=>item.content).join(''),text=update.content?.text??''
      const content=update._meta?.wovenAssistantSnapshot===true?text:previous+text
      const parts=textParts(content)
      next.messages=Array.from({length:Math.max(parts.length,next.messages.length)},(_,part)=>({id:part?`${binding.runID}-part-${part}`:binding.runID,conversationID:binding.conversationID,
        runID:binding.runID,role:'assistant',content:parts[part]??'',status:binding.status,createdAt:binding.startedAt}))
      for(let part=0;part<next.messages.length;part++)entries.push(event(binding,`message-${index}-${part}`,'transcript',{transcript:{conversationID:binding.conversationID,messages:[next.messages[part]],activities:[]}}))
    } else if(kind==='agent_thought_chunk'||kind==='tool_call'||kind==='tool_call_update') {
      const id=binding.runID+':'+(kind==='agent_thought_chunk'?String(update._meta?.wovenThoughtID??'thinking'):String(update.toolCallId??stableID(binding.key+':tool:'+index)))
      let activity=next.activities.find(item=>item.id===id)
      if(!activity){activity={id,runID:binding.runID,title:kind==='agent_thought_chunk'?'Thinking':textParts(update.title??'Tool')[0],status:binding.status};next.activities.push(activity)}
      if(kind==='agent_thought_chunk')activity.detail=textParts(update._meta?.wovenThoughtSnapshot?update.content?.text??'':(activity.detail??'')+(update.content?.text??''))[0]
      else {
        if(update.title)activity.title=textParts(update.title)[0]
        activity.status=update.status==='failed'?'failed':binding.status
        const detail=update.content?.map(item=>item.content?.text??item.text??'').filter(Boolean).join('\n')
        if(detail)activity.detail=textParts(detail)[0]
      }
      entries.push(event(binding,'activity-'+index,'transcript',{transcript:{conversationID:binding.conversationID,messages:[],activities:[activity]}}))
    }
    await importEntries(entries)
    next.next=index+1;writeState(binding.key,next);Object.assign(state,next)
  }
  async function finish(binding,state) {
    if(state.finished)return
    await importEntries([event(binding,'complete','transcript',{transcript:{conversationID:binding.conversationID,messages:[],activities:[],
      runs:[{id:binding.runID,status:binding.status,startedAt:binding.startedAt,completedAt:binding.completedAt}]}})])
    delete state.presentationFrames
    state.finished=true;writeState(binding.key,state)
  }
  async function captureTasks() {
    for(let pages=0;pages<100;pages++) {
      const page=taskGateway.results(checkpoint.taskCursor)
      for(const result of page.entries) {
        const binding={key:'task:'+result.id,source:'task-gateway',conversationID:result.run.sessionID,runID:result.run.id,
          nativeSessionID:result.nativeSessionID,runtimeKind:result.run.task.configuration.runtimeKind,
          title:result.run.title,prompt:result.run.task.prompt,startedAt:result.run.scheduledAt,completedAt:result.completedAt,
          status:result.run.status==='accepted'?'completed':result.run.status==='failed'?'failed':'interrupted'}
        // Failed pre-admission tasks may have no native session. Their durable
        // task receipt remains intact; they cannot claim a native conversation.
        if(!binding.nativeSessionID) {save('unmapped',stableID(binding.key),{source:binding.source,runID:binding.runID,reason:'No native session was admitted.'});continue}
        const state=await begin(binding)
        if(!state.finished) {
          for(const [index,value] of result.updates.entries())await update(binding,state,value,result.updateOffset+index)
          if(result.complete) {
            const {updates,...completion}=result
            await update(binding,state,{sessionUpdate:'woven_retained_completion',completion},result.updateOffset+result.updates.length)
            await finish(binding,state)
          }
        }
      }
      if(page.cursor===checkpoint.taskCursor)return
      checkpoint={...checkpoint,taskCursor:page.cursor};durableJSON(checkpointPath,checkpoint)
      if(!page.entries.length)return
    }
  }
  // Persist only public identity and message text, never attachment tokens,
  // provider configuration, MCP credentials, tool capabilities, or the RPC envelope.
  function prepareRPC(message) {
    if(message.method!=='session/prompt')return message
    const operationID=message.operationID??randomUUID(),meta=message.params?._meta??{}
    if(!uuid(operationID))throw new Error('Invalid retained operation identity.')
    const intent={operationID,conversationID:uuid(meta.wovenConversationID)?meta.wovenConversationID:null,
      runID:uuid(meta.wovenRunID)?meta.wovenRunID:operationID,inputID:uuid(meta.wovenInputID)?meta.wovenInputID:operationID,
      nativeSessionID:message.params?.sessionId,runtimeKind:'default_agent',prompt:(message.params?.prompt??[]).filter(item=>item.type==='text').map(item=>item.text).join('\n')}
    const old=read(path('intent',operationID),null)
    if(old) {
      if(old.fingerprint!==hash(JSON.stringify(intent)))throw new Error('Retained operation identity belongs to different input.')
    } else save('intent',operationID,{...intent,fingerprint:hash(JSON.stringify(intent)),startedAt:now()})
    return {...message,operationID}
  }
  function acceptedRPC(message,result) {if(message.method==='session/prompt'&&result.operationID===message.operationID)active.add(result.operationID)}
  async function* lines(file) {
    // A crash may leave the final JSONL write incomplete. Retain that suffix
    // verbatim on disk, and publish only complete records; never trim the spool.
    const size=statSync(file).size
    let complete=true
    if(size) {const fd=openSync(file,'r'),last=Buffer.alloc(1);try {readSync(fd,last,0,1,size-1);complete=last[0]===10}finally{closeSync(fd)}}
    const stream=createInterface({input:createReadStream(file),crlfDelay:Infinity})
    let previous
    for await(const line of stream) {if(previous?.trim())yield JSON.parse(previous);previous=line}
    if(complete&&previous?.trim())yield JSON.parse(previous)
  }
  async function captureDefault() {
    let names=[]
    const taskRuns=new Set(taskGateway.retainedRunIDs?.()??[])
    try {names=readdirSync(defaultDirectory).filter(name=>/^run-[0-9a-f-]{36}-[0-9a-f-]{36}\.jsonl$/.test(name)).sort()}catch(error){if(error.code!=='ENOENT')throw error}
    for(const name of names) {
      const operationID=name.slice(-42,-6),key='default:'+operationID
      if(stateFor(key).finished || taskRuns.has(operationID) || execution.hasRun?.(operationID))continue
      let intent=read(path('intent',operationID),null)
      if(active.has(operationID)) {
        try {
          const page=await defaultAgent.poll(operationID,0)
          // done describes a page's end, so drain the owner cursor independently
          // of whether any desktop is still polling this run.
          let last=page
          while(last.hasMore)last=await defaultAgent.poll(operationID,last.cursor)
          if(!last.done)continue
          intent={...intent,completedAt:intent?.completedAt??now(),status:last.error?'failed':'completed',completion:{result:last.result,error:last.error}}
          save('intent',operationID,intent);active.delete(operationID)
        } catch(error) {
          if(!error.message?.includes('This operation is no longer available in the workspace process.'))continue
          // A replaced SDK process fences accepted input; retain its stopped
          // spool without attempting to resume or redispatch the old prompt.
          intent={...intent,completedAt:intent?.completedAt??now(),status:'interrupted'}
          save('intent',operationID,intent);active.delete(operationID)
        }
      }
      const file=resolve(defaultDirectory,name),runIDs=new Set()
      let nativeSessionID=intent?.nativeSessionID
      for await(const item of lines(file)) {
        nativeSessionID??=item.recordBatch?.nativeSessionID
        for(const id of [item._meta?.wovenRunID,...(item.recordBatch?.records??[]).map(record=>record.runID)])if(uuid(id))runIDs.add(id)
      }
      let association=intent?.conversationID?intent:read(path('association',operationID),null)
      if(!association) {
        const runID=intent?.runID??(runIDs.size===1?[...runIDs][0]:undefined)
        if(runID||nativeSessionID) {
          try {
            const value=await resolveAssociation({operationID,runID,nativeSessionID})
            if(value && uuid(value.conversationID) && uuid(value.runID) && value.runtimeKind==='default_agent'
              && (!runID||value.runID===runID) && (!nativeSessionID||value.nativeSessionID===nativeSessionID)) {
              association={conversationID:value.conversationID,runID:value.runID,nativeSessionID:value.nativeSessionID,runtimeKind:value.runtimeKind}
              save('association',operationID,association)
            }
          }
          catch { /* Exact mapping can wait; other known identities still archive offline. */ }
        }
      }
      if(!association||!uuid(association.conversationID)||!uuid(association.runID??intent?.runID)||!(association.nativeSessionID??nativeSessionID)){unmapped++;continue}
      const stamp=statSync(resolve(defaultDirectory,name)).mtime.toISOString()
      const binding={...intent,...association,key,source:'default-agent-rpc',runID:association.runID??intent.runID,
        nativeSessionID:association.nativeSessionID??nativeSessionID,runtimeKind:'default_agent',title:intent?.prompt?.slice(0,100)||'Pi Durable',
        startedAt:intent?.startedAt??stamp,completedAt:intent?.completedAt??stamp,status:intent?.status??'interrupted'}
      const state=await begin(binding)
      let index=0
      for await(const value of lines(file))await update(binding,state,value,index++)
      await update(binding,state,{sessionUpdate:'woven_retained_completion',completion:intent?.completion??{status:'interrupted'}},index)
      await finish(binding,state)
    }
  }
  async function pump() {
    if(closed)return
    if(pending)return pending
    pending=(async()=>{
      unmapped=readdirSync(directory).filter(name=>name.startsWith('unmapped-')).length;execution.descriptor()
      const failures=[]
      try {await captureTasks()}catch(error){failures.push(error)}
      try {await captureDefault()}catch(error){failures.push(error)}
      if(failures.length)throw failures[0]
      lastError=null
    })()
    try {await pending}finally {pending=null}
  }
  function tick(){void pump().catch(()=>{lastError='Retained execution history is saved locally and waiting to synchronize.'})}
  return {prepareRPC,acceptedRPC,pump,status:()=>({pendingAssociationCount:unmapped,lastError}),
    start(){if(!timer){timer=setInterval(tick,intervalMilliseconds);timer.unref();tick()}},
    async close(){closed=true;clearInterval(timer);await pending?.catch(()=>{})}}
}
