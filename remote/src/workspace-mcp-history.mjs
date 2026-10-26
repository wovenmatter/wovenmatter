const fail = (statusCode, message, code) => Object.assign(new Error(message), {statusCode, ...(code ? {code} : {})})
const text = value => typeof value === 'string' ? value : value == null ? '' : JSON.stringify(value)
const sequence = value => Number.isSafeInteger(value) && value > 0 ? value : null
const coverage = 'Owner-local retained journal and transcript projections. Complete native JSON records up to 16 MiB are searchable; incomplete or larger native bodies require direct event reads. Missing native metadata is never inferred.'
const boundedText = (value, maximum = 1000) => Array.from(text(value)).slice(0, maximum).join('')
const bodyWindow = (value, input, prefix) => {
  const content = Array.from(text(value)), start = input.offset ?? 0, end = Math.min(content.length, start + (input.characters ?? 16000))
  return {[prefix]:content.slice(start,end).join(''),[prefix+'_characters']:content.length,[prefix+'_offset']:start,[prefix+'_has_more']:end<content.length,
    ...(end<content.length?{nextOffset:end}:{})}
}
function dateFilter(value, label) {
  if(value == null)return null
  if(typeof value !== 'string' || !/(?:Z|[+-]\d\d:\d\d)$/i.test(value) || !Number.isFinite(Date.parse(value)))throw fail(400,label+' requires an ISO-8601 timestamp with a time zone.')
  return Date.parse(value)
}
function page(rows,input,{descending=false,offset=false,map=value=>value,scope='workspace'}={}) {
  const after=input.after??0,limit=input.limit??40
  const ordered=[...rows].sort((a,b)=>descending?b.sequence-a.sequence:a.sequence-b.sequence)
    .filter(row=>!after||(descending?row.sequence<after:row.sequence>after))
  const selected=offset?ordered.slice(input.offset??0):ordered,output=[]
  let bytes=0,index=0
  while(index<selected.length&&output.length<limit) {
    const row=map(selected[index]),size=Buffer.byteLength(JSON.stringify(row))
    if(size>800000)throw fail(413,'This record exceeds the history page budget. Read its body in smaller character windows.')
    if(output.length&&bytes+size>800000)break
    output.push(row);bytes+=size;index++
  }
  return {schemaVersion:1,rows:output,hasMore:index<selected.length,nextCursor:index?selected[index-1].sequence:after,
    ...(offset?{nextOffset:(input.offset??0)+index}:{}),scope,historicalCoverage:coverage}
}

// Pure projection of one execution owner's retained data. Numeric cursors use
// durable origin sequences (or append positions for one conversation's messages),
// not mutable timestamps or an offset hidden from the public schema.
export function queryWorkspaceMCPHistory(name,input,{records,events,callerID,workspace,providers=[],relationship,readableConversationIDs}={}) {
  for(const key of ['after','offset'])if(input[key]!=null&&(!Number.isSafeInteger(input[key])||input[key]<0))throw fail(400,key+' must be a nonnegative integer.')
  if(input.limit!=null&&(!Number.isSafeInteger(input.limit)||input.limit<1||input.limit>200))throw fail(400,'limit must be between 1 and 200.')
  if(input.characters!=null&&(!Number.isSafeInteger(input.characters)||input.characters<1||input.characters>65536))throw fail(400,'characters must be between 1 and 65536.')
  const since=dateFilter(input.since,'since'),until=dateFilter(input.until,'until')
  if(since!=null&&until!=null&&until<since)throw fail(400,'until must be at or after since.')
  if(input.sort!=null&&!['newest','oldest'].includes(input.sort))throw fail(400,'sort must be newest or oldest.')
  if(input.workspace!=null&&!['local',workspace.id].includes(input.workspace))throw fail(409,'This endpoint reads only its execution workspace; use the requested owner endpoint.')
  if(readableConversationIDs) {
    const readable=new Set(readableConversationIDs)
    const explicit=input.conversation??(['woven_history_conversation','woven_sessions_status'].includes(name)?input.id:undefined)
    if(explicit&&!readable.has(explicit))throw fail(403,'This caller may read only its own conversation and sessions it currently coordinates.')
    records=records.filter(record=>readable.has(record.conversation.id))
    events=events.filter(event=>readable.has(event.conversationID))
  }
  const byID=new Map(records.map(record=>[record.conversation.id,record]))
  const caller=byID.get(callerID)
  if(!caller)throw fail(404,'The authenticated caller is absent from this execution workspace.')
  const durable=events.map((event,index)=>({...event,sequence:sequence(event.originSequence)??sequence(event.sequence)??index+1})).sort((a,b)=>a.sequence-b.sequence)
  const firstSequence=new Map()
  for(const event of durable)if(event.conversationID&&!firstSequence.has(event.conversationID))firstSequence.set(event.conversationID,event.sequence)
  const target=id=>{const found=byID.get(id);if(!found||found.conversation.deleted)throw fail(404,'Conversation not found in this execution workspace.');return found}
  const ordinal=(record,index)=>firstSequence.get(record.conversation.id)??sequence(record._sequence)??index+1
  const conversationRows=records.filter(record=>!record.conversation.deleted).map((record,index)=>({record,sequence:ordinal(record,index)}))
  const folderMatches=(record,folder)=>folder==='all'||(folder==='ungrouped'?(record?.conversation.folderID??null)===null:record?.conversation.folderID===folder)
  const conversationMetadata=({record,sequence})=>({...record.conversation,sequence,harness:record.conversation.runtimeKind,
    folder_id:record.conversation.folderID??null,workspace_id:workspace.id,
    ...(record.goal?{goal:{status:record.goal.status,objective:boundedText(record.goal.objective)}}:{})})

  if(name==='woven_sessions_harnesses')return page(providers.map((provider,index)=>({provider,sequence:index+1})),input,{offset:true,map:row=>({...row.provider,sequence:row.sequence,workspace:workspace.id})})
  if(name==='woven_sessions_folders')throw fail(503,'Folder names and empty folders are not retained by this execution owner; query the central library folder catalog.','metadata_unavailable')
  if(name==='woven_sessions_status') {
    const record=target(input.id),row={record,sequence:ordinal(record,records.indexOf(record))}
    return {...page([row],{} ,{map:conversationMetadata}),...(relationship?{relationship:relationship(input.id)}:{relationship:{sessionID:input.id,available:false,reason:'Coordination metadata is unavailable on this execution owner.'}})}
  }
  if(name==='woven_sessions_list'||name==='woven_history_conversations') {
    const match=row=>(input.folder==null||folderMatches(row.record,input.folder))&&(!input.search||text(row.record.conversation.title).toLowerCase().includes(input.search.toLowerCase()))
    let rows=conversationRows.filter(match),scope=input.folder==null?'workspace':'folder'
    if(!input.allWorkspace&&input.folder==null&&input.search&&caller.conversation.folderID!=null) {
      const nearby=rows.filter(row=>folderMatches(row.record,caller.conversation.folderID))
      if(nearby.length){rows=nearby;scope='folder'}
    }
    return page(rows,input,{descending:input.sort!=='oldest',map:conversationMetadata,scope})
  }
  if(name==='woven_history_conversation') {
    const record=target(input.id)
    const rows=(record.transcript.messages??[]).map((message,index)=>({...message,sequence:index+1,conversation_id:record.conversation.id,
      ...bodyWindow(message.content,input,'content')}))
    return {...page(rows,input),conversationID:record.conversation.id}
  }
  if(name==='woven_history_message') {
    for(const record of records) {
      const index=(record.transcript.messages??[]).findIndex(message=>message.id===input.id)
      if(index>=0){const message=record.transcript.messages[index];return page([{...message,sequence:index+1,conversation_id:record.conversation.id,...bodyWindow(message.content,input,'content')}],{})}
    }
    throw fail(404,'Message not found in this execution workspace.')
  }
  if(name==='woven_history_runs') {
    if(input.conversation)target(input.conversation)
    const runs=new Map()
    for(const event of durable) {
      if(input.conversation&&event.conversationID!==input.conversation)continue
      const known=[event.runID,...(event.transcript?.runs??[]).map(run=>run.id),...(event.transcript?.messages??[]).map(message=>message.runID)].filter(Boolean)
      for(const id of known)if(!runs.has(id))runs.set(id,{id,sequence:runs.size+1,conversation_id:event.conversationID,status:'unknown'})
      for(const run of event.transcript?.runs??[])if(runs.has(run.id))Object.assign(runs.get(run.id),run,{sequence:runs.get(run.id).sequence})
    }
    for(const record of records) {
      if(input.conversation&&record.conversation.id!==input.conversation)continue
      for(const message of record.transcript.messages??[])if(message.runID&&runs.has(message.runID)) {
        const row=runs.get(message.runID)
        row.conversation_id=record.conversation.id
        if(message.role==='assistant'&&message.status)row.status=message.status
        if(message.role==='user')row.started_at??=message.createdAt
      }
      if(record.conversation.activeRunID&&runs.has(record.conversation.activeRunID))runs.get(record.conversation.activeRunID).status='running'
    }
    return page([...runs.values()],input)
  }

  const nativeParts=new Map(),nativeValues=new Map()
  for(const event of durable)if(event.nativeRecord?.recordID) {
    const id=event.conversationID+'\0'+event.nativeRecord.recordID,parts=nativeParts.get(id)??[]
    parts.push(event.nativeRecord);nativeParts.set(id,parts)
  }
  const nativeValue=event=>{
    if(!event.nativeRecord?.recordID)return null
    const id=event.conversationID+'\0'+event.nativeRecord.recordID
    if(nativeValues.has(id))return nativeValues.get(id)
    const parts=(nativeParts.get(id)??[]).sort((a,b)=>a.partIndex-b.partIndex),first=parts[0]
    let value=null
    if(first&&Number.isSafeInteger(first.byteCount)&&first.byteCount<=16*1024*1024&&parts.length===first.partCount&&parts.every((part,index)=>part.partIndex===index&&typeof part.data==='string')) {
      try {value=JSON.parse(Buffer.concat(parts.map(part=>Buffer.from(part.data,'base64'))).toString('utf8'))} catch {}
    }
    nativeValues.set(id,value);return value
  }
  const metadata=event=>{
    const record=byID.get(event.conversationID),native=event.nativeRecord??{},raw=nativeValue(event)??{},projection=native.projection??event.projection??raw.projection??raw._meta??{}
    return {sourceID:event.sourceID??native.sourceID??raw.sourceID, nativeRecordID:event.nativeRecordID??native.recordID,
      nativeSessionID:event.nativeSessionID??native.nativeSessionID??raw.nativeSessionID??record?.native?.sessionID,
      nativeConversationID:event.nativeConversationID??native.nativeConversationID??raw.nativeConversationID??projection.nativeConversationID,
      harness:event.harness??record?.conversation.runtimeKind,
      recordedAt:event.recordedAt??event.recorded_at??(event.kind==='conversation'?event.conversation?.updatedAt:undefined)}
  }
  const summary=event=>{
    const info=metadata(event),payload=JSON.stringify(event)
    return {sequence:event.sequence,id:event.eventID??event.id,eventID:event.eventID??event.id,conversation_id:event.conversationID,
      run_id:event.runID,harness:info.harness,kind:event.kind,recorded_at:info.recordedAt,
      source_id:info.sourceID,native_session_id:info.nativeSessionID,native_record_id:info.nativeRecordID,native_conversation_id:info.nativeConversationID,
      payload_characters:Array.from(payload).length,...(Array.from(payload).length<=8192?{payload}:{payload:null,payload_has_more:true})}
  }
  if(name==='woven_history_event') {
    const event=durable.find(event=>(event.eventID??event.id)===input.id)
    if(!event)throw fail(404,'Event not found in this execution workspace.')
    return page([{...summary(event),...bodyWindow(JSON.stringify(event),input,'payload')}],{})
  }
  if(!['woven_history_events','woven_history_search','woven_history_trace'].includes(name))throw fail(400,'Unknown owner-local history tool.')
  if(input.nativeConversationID&&(!input.sourceID||!input.nativeSessionID))throw fail(400,'nativeConversationID requires sourceID and nativeSessionID.')
  if(input.conversation)target(input.conversation)
  let rows=durable.filter(event=>(!input.conversation||event.conversationID===input.conversation)
    &&(!input.run||event.runID===input.run)&&(!input.kind||event.kind===input.kind)
    &&(!input.harness||metadata(event).harness===input.harness)
    &&(input.folder==null||folderMatches(byID.get(event.conversationID),input.folder))
    &&(name!=='woven_history_trace'||event.runID===input.id))
  for(const field of ['sourceID','nativeSessionID','nativeRecordID','nativeConversationID'])if(input[field]!=null) {
    if(rows.length&&!rows.some(event=>metadata(event)[field]!=null))throw fail(503,field+' metadata is unavailable in the retained records for this query.','metadata_unavailable')
    rows=rows.filter(event=>metadata(event)[field]===input[field])
  }
  if(since!=null||until!=null) {
    if(rows.some(event=>!Number.isFinite(Date.parse(metadata(event).recordedAt))))throw fail(503,'Recorded timestamps are unavailable for part of this retained journal; the requested time filter cannot be applied completely.','metadata_unavailable')
    rows=rows.filter(event=>{const at=Date.parse(metadata(event).recordedAt);return(since==null||at>=since)&&(until==null||at<=until)})
  }
  if(input.search)rows=rows.filter(event=>{
    const needle=input.search.toLowerCase()
    if(JSON.stringify(event).toLowerCase().includes(needle))return true
    const raw=nativeValue(event)
    return raw!=null&&JSON.stringify(raw).toLowerCase().includes(needle)
  })
  let scope=input.folder==null?'workspace':'folder'
  if(name==='woven_history_search'&&!input.allWorkspace&&!input.folder&&!input.conversation&&caller.conversation.folderID!=null) {
    const nearby=rows.filter(event=>folderMatches(byID.get(event.conversationID),caller.conversation.folderID))
    if(nearby.length){rows=nearby;scope='folder'}
  }
  if(name==='woven_history_trace'&&!rows.length&&!durable.some(event=>event.runID===input.id))throw fail(404,'Run trace not found in this execution workspace.')
  return page(rows,input,{map:summary,scope})
}
