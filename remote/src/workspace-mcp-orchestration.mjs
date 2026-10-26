import { createHash, randomUUID } from 'node:crypto'

const fail=(statusCode,message)=>Object.assign(new Error(message),{statusCode})
const stamp=()=>new Date().toISOString()
const uuid=value=>typeof value==='string'&&/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
const stableID=value=>{const h=createHash('sha256').update('woven-mcp-orchestration-v1\0'+value).digest('hex');return `${h.slice(0,8)}-${h.slice(8,12)}-5${h.slice(13,16)}-a${h.slice(17,20)}-${h.slice(20,32)}`}
const ordered=value=>Array.isArray(value)?value.map(ordered):value&&typeof value==='object'?Object.fromEntries(Object.keys(value).sort().map(key=>[key,ordered(value[key])])):value
const permissionRank=value=> {
  if(value==null)return undefined
  const key=String(value).replaceAll(/[-_\s]/g,'').toLowerCase()
  if(['deny','dontask','readonly','readOnly','plan'].includes(key))return 0
  if(['ask','default','approvalrequired','onrequest','untrusted','askforapproval','supervised','workspacewrite'].includes(key))return 1
  if(['acceptedits','autoacceptedits','autoedit','auto','autoreview','smartapprovals','smartreview','agent'].includes(key))return 2
  if(['allow','full','fullaccess','bypasspermissions','never','agentfullaccess'].includes(key))return 3
  return undefined
}

// These operations use the workspace's existing accepted-command engine. The
// MCP credential selects the source, and no model argument can change it.
export function createWorkspaceMCPOrchestration({db,identity,getRecord,command,runtime,settings,runningSessions=()=>0,policy,notifyApproval}) {
  db.exec(`CREATE TABLE IF NOT EXISTS mcp_session_provenance (target TEXT PRIMARY KEY, caller TEXT NOT NULL, purpose TEXT NOT NULL, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS mcp_session_coordination (target TEXT PRIMARY KEY, caller TEXT NOT NULL, purpose TEXT NOT NULL, epoch TEXT NOT NULL, notify INTEGER NOT NULL, created_at TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS mcp_orchestration_receipts (caller TEXT NOT NULL, request_id TEXT NOT NULL, fingerprint TEXT NOT NULL, intent TEXT, response TEXT, PRIMARY KEY(caller,request_id));
    CREATE TABLE IF NOT EXISTS mcp_session_messages (id TEXT PRIMARY KEY, caller TEXT NOT NULL, target TEXT NOT NULL, text TEXT NOT NULL, status TEXT NOT NULL, receipt TEXT, created_at TEXT NOT NULL, notification INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS mcp_session_access_requests (id TEXT PRIMARY KEY, caller TEXT NOT NULL, target TEXT NOT NULL, interaction_id TEXT NOT NULL, state TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS mcp_coordination_notifications (id TEXT PRIMARY KEY);`)
  if(!db.prepare('PRAGMA table_info(mcp_session_messages)').all().some(column=>column.name==='notification'))db.exec('ALTER TABLE mcp_session_messages ADD COLUMN notification INTEGER NOT NULL DEFAULT 0')
  db.prepare("UPDATE mcp_session_access_requests SET state='rejected' WHERE state='pending'").run()
  for(const row of db.prepare('SELECT id,body FROM conversations').all()){const record=JSON.parse(row.body);if(record.pending?.some(item=>item.mcpManageAccessID)){record.pending=record.pending.filter(item=>!item.mcpManageAccessID);db.prepare('UPDATE conversations SET body=? WHERE id=?').run(JSON.stringify(record),row.id)}}
  const pumps=new Map()
  const own=()=>identity()
  const success=(result,requestID)=>({success:true,result,requestID})
  const baseCommand=(kind,source,requestID,suffix,values)=>{
    const sender=values.agentSourceID?getRecord(values.agentSourceID).conversation:null
    return command({commandID:stableID([source,requestID,suffix].join(':')),deviceID:own().executionDeviceID,kind,...values,...(sender?{senderSessionTitle:sender.title,senderHarness:sender.runtimeKind,senderKind:values.coordinationNotification?'notification':'message'}:{})},{id:own().executionDeviceID})
  }
  function relationship(target) {
    const created=db.prepare('SELECT * FROM mcp_session_provenance WHERE target=?').get(target)
    const managed=db.prepare('SELECT * FROM mcp_session_coordination WHERE target=?').get(target)
    return {sessionID:target,...(created?{createdBy:created.caller}:{}),...(managed?{coordinatorID:managed.caller,purpose:managed.purpose,coordinationEpoch:managed.epoch,coordinationSince:managed.created_at}:{}),notificationsEnabled:managed?.notify===1}
  }
  function readableConversationIDs(caller) {return new Set([caller,...db.prepare('SELECT target FROM mcp_session_coordination WHERE caller=?').all(caller).map(row=>row.target)])}
  function reserve(scope,name,input) {
    const fingerprint=JSON.stringify(ordered({name,input})),row=db.prepare('SELECT * FROM mcp_orchestration_receipts WHERE caller=? AND request_id=?').get(scope.conversationID,input.requestID)
    if(row&&row.fingerprint!==fingerprint)throw fail(409,'This request ID belongs to another session operation.')
    if(!row)db.prepare('INSERT INTO mcp_orchestration_receipts VALUES(?,?,?,NULL,NULL)').run(scope.conversationID,input.requestID,fingerprint)
    return row
  }
  function saveReply(scope,requestID,response) {
    db.prepare('UPDATE mcp_orchestration_receipts SET response=? WHERE caller=? AND request_id=?').run(JSON.stringify(response),scope.conversationID,requestID)
    return response
  }
  function coordinate(caller,target,purpose,notify=true) {
    if(target===caller)throw fail(400,'A session cannot coordinate itself.')
    getRecord(target)
    let ancestor=caller
    for(let depth=0;depth<64;depth++){const parent=db.prepare('SELECT caller FROM mcp_session_coordination WHERE target=?').get(ancestor);if(!parent)break;if(parent.caller===target)throw fail(409,'Coordination cannot form a cycle.');ancestor=parent.caller;if(depth===63)throw fail(409,'The coordination chain is too deep.')}
    const existing=db.prepare('SELECT * FROM mcp_session_coordination WHERE target=?').get(target)
    if(existing&&existing.caller!==caller)throw fail(409,'This session is already coordinated by '+existing.caller+'.')
    if(existing)return relationship(target)
    const count=db.prepare('SELECT count(*) AS count FROM mcp_session_coordination WHERE caller=?').get(caller).count
    if(count>=settings().maximumManagedSessions)throw fail(409,'The coordinator has reached its managed-session limit.')
    db.prepare('INSERT INTO mcp_session_coordination VALUES(?,?,?,?,?,?)').run(target,caller,purpose,randomUUID(),notify?1:0,stamp())
    return relationship(target)
  }
  async function narrowPermissions(source,child,intent) {
    if(!runtime.settings||!runtime.configure)return
    const parent=await runtime.settings({native:source.native,runtimeKind:source.conversation.runtimeKind})
    const target=await runtime.settings({native:child.native,runtimeKind:child.conversation.runtimeKind})
    const ceiling=intent.permissionCeiling??permissionRank(parent.permission)??1,actual=permissionRank(target.permission)
    const options={...(intent.model?{model:intent.model}:{}),...(intent.thinking?{thinking:intent.thinking}:{})}
    const wanted=intent.permission??target.permission,wantedRank=permissionRank(wanted)
    if(wantedRank!==undefined&&wantedRank<=ceiling) {
      if(wanted!==target.permission)options.permission=wanted
    } else if(actual===undefined||actual>ceiling||wantedRank!==undefined&&wantedRank>ceiling) {
      const choices=(target.permissions??[]).filter(item=>{const rank=permissionRank(item.id);return rank!==undefined&&rank<=ceiling}).sort((a,b)=>permissionRank(b.id)-permissionRank(a.id))
      if(!choices.length)throw fail(409,'The destination cannot enforce the caller’s permission ceiling. Configure a narrower destination mode in Woven before dispatching work.')
      options.permission=choices[0].id
    }
    if(Object.keys(options).length)await runtime.configure({native:child.native,runtimeKind:child.conversation.runtimeKind,options})
  }
  async function deliver(caller,target,text,requestID,suffix='send') {
    const destination=getRecord(target)
    if(destination.conversation.activeRunID) {
      const capabilities=runtime.capabilities?await runtime.capabilities({native:destination.native,runtimeKind:destination.conversation.runtimeKind}):null
      if(capabilities?.canSteer===true)return baseCommand('steer',caller,requestID,suffix,{conversationID:target,runID:destination.conversation.activeRunID,text,agentSourceID:caller,...(suffix==='notification'?{coordinationNotification:true}:{})})
      const id=stableID([caller,requestID,suffix].join(':'))
      const existing=db.prepare('SELECT * FROM mcp_session_messages WHERE id=?').get(id)
      if(!existing)db.prepare('INSERT INTO mcp_session_messages VALUES(?,?,?,?,?,?,?,?)').run(id,caller,target,text,'queued',null,stamp(),suffix==='notification'?1:0)
      return {commandID:id,conversationID:target,status:'queued'}
    }
    return baseCommand('send',caller,requestID,suffix,{conversationID:target,text,agentSourceID:caller,...(suffix==='notification'?{coordinationNotification:true}:{})})
  }
  function canReadTarget(caller,target) {return policy(caller).includes('history')||readableConversationIDs(caller).has(target)}
  async function call(scope,name,input,{signal}={}) {
    signal?.throwIfAborted()
    const source=getRecord(scope.conversationID),action=name.slice('woven_sessions_'.length),requestID=input.requestID
    if(action==='receipts') {
      const before=input.before==null?Number.MAX_SAFE_INTEGER:Number(input.before),limit=Math.min(input.limit??50,200)
      if(!Number.isSafeInteger(before)||before<1)throw fail(400,'Invalid receipt cursor.')
      const rows=db.prepare('SELECT rowid AS sequence,request_id,response FROM mcp_orchestration_receipts WHERE caller=? AND response IS NOT NULL AND rowid<? ORDER BY rowid DESC LIMIT ?').all(scope.conversationID,before,limit+1),page=rows.slice(0,limit)
      return success({rows:page.map(row=>({sequence:Number(row.sequence),requestID:row.request_id,...JSON.parse(row.response)})),...(rows.length>limit?{nextBefore:String(page.at(-1).sequence)}:{})},requestID)
    }
    const previous=reserve(scope,name,input)
    if(previous?.response&&!JSON.parse(previous.response).result?.pending)return JSON.parse(previous.response)
    let result
    if(action==='create') {
      let intent=previous?.intent?JSON.parse(previous.intent):null
      if(!intent) {
        const kind=input.harness??source.conversation.runtimeKind,defaults=settings().harnessDefaults?.[kind]??{}
        const parentSettings=runtime.settings?await runtime.settings({native:source.native,runtimeKind:source.conversation.runtimeKind}):{}
        const permissionCeiling=permissionRank(parentSettings.permission)??1
        let permission=defaults.permission
        if(kind==='grok_build'){permission??='default';if((permissionRank(permission)??Infinity)>permissionCeiling)permission=permissionCeiling===0?'dontAsk':'default'}
        const enabled=[...new Set([...(defaults.tools??settings().enabledByDefault),'goals'])].filter(group=>!scope.enabledGroups||scope.enabledGroups.includes(group)||group==='goals')
        intent={id:stableID([scope.conversationID,requestID,'child'].join(':')),runtimeKind:kind,title:input.title,text:input.text,purpose:input.purpose,
          ...(input.folder==='all'?{}:input.folder||source.conversation.folderID?{folderID:input.folder??source.conversation.folderID}:{}),
          nativeWorkingDirectory:input.directory??source.native.nativeWorkingDirectory,model:input.model??defaults.model,thinking:input.thinking??defaults.thinking,permission,permissionCeiling,enabledTools:enabled,independent:input.independent===true}
        db.prepare('UPDATE mcp_orchestration_receipts SET intent=? WHERE caller=? AND request_id=?').run(JSON.stringify(intent),scope.conversationID,requestID)
      }
      if(!intent.independent) {
        const managed=db.prepare('SELECT count(*) AS count FROM mcp_session_coordination WHERE caller=?').get(scope.conversationID).count
        if(managed>=settings().maximumManagedSessions&&!db.prepare('SELECT target FROM mcp_session_coordination WHERE target=? AND caller=?').get(intent.id,scope.conversationID))throw fail(409,'The coordinator has reached its managed-session limit.')
      }
      signal?.throwIfAborted()
      if(!db.prepare('SELECT id FROM commands WHERE id=?').get(stableID([scope.conversationID,requestID,'create'].join(':')))&&runningSessions()>=settings().maximumRunningSessions)throw fail(409,'The workspace has reached its simultaneous-session limit.')
      const created=await baseCommand('createSession',scope.conversationID,requestID,'create',{conversationID:intent.id,providerID:intent.runtimeKind,runtimeKind:intent.runtimeKind,folderID:intent.folderID,initialConfiguration:intent})
      if(created.status!=='completed')throw fail(409,created.message??'The destination session could not be created.')
      const child=getRecord(intent.id)
      if(!child.conversation.activeRunID&&!db.prepare('SELECT id FROM commands WHERE id=?').get(stableID([scope.conversationID,requestID,'initial-send'].join(':'))))await narrowPermissions(source,child,intent)
      db.prepare('INSERT OR IGNORE INTO mcp_session_provenance VALUES(?,?,?,?)').run(intent.id,scope.conversationID,intent.purpose,stamp())
      if(!intent.independent)coordinate(scope.conversationID,intent.id,intent.purpose)
      signal?.throwIfAborted()
      if(!policy(scope.conversationID).includes('sessions'))throw fail(403,'Session management was disabled before dispatch.')
      const dispatched=await deliver(scope.conversationID,intent.id,intent.text,requestID,'initial-send')
      result={session:getRecord(intent.id).conversation,relationship:relationship(intent.id),receipt:dispatched}
    } else if(action==='send') {
      if(!canReadTarget(scope.conversationID,input.id)&&!policy(scope.conversationID).includes('sessions'))throw fail(403,'Session management is disabled.')
      result={receipt:await deliver(scope.conversationID,input.id,input.text,requestID),session:getRecord(input.id).conversation}
    } else if(action==='manage') {
      getRecord(input.id)
      if(!canReadTarget(scope.conversationID,input.id)) {
        const approvalID=stableID([scope.conversationID,requestID,'manage-access'].join(':'))
        let approval=db.prepare('SELECT * FROM mcp_session_access_requests WHERE id=?').get(approvalID)
        if(approval?.state==='rejected')throw fail(403,'The user declined access to this session.')
        if(approval?.state!=='approved') {
          if(!source.conversation.activeRunID)throw fail(403,'Enable Conversation history in Woven or request management from an active Woven conversation to approve access.')
          if(!approval) {
            const interactionID='woven-mcp-manage:'+approvalID
            db.prepare('INSERT INTO mcp_session_access_requests VALUES(?,?,?,?,?)').run(approvalID,scope.conversationID,input.id,interactionID,'pending')
            notifyApproval(scope.conversationID,source.conversation.activeRunID,{id:interactionID,kind:'approval',title:'Allow this coordinator to read and manage '+getRecord(input.id).conversation.title+'?',options:[{id:'allow_once',label:'Allow management'},{id:'reject',label:'Decline'}],questions:[],mcpManageAccessID:approvalID})
          }
          return saveReply(scope,requestID,success({pending:true,requestID,message:'Waiting for the user to approve session management in Woven. Retry this same requestID after approval.'},requestID))
        }
      }
      result=coordinate(scope.conversationID,input.id,input.purpose,input.noNotify!==true)
    } else if(action==='release'||action==='notifications') {
      const current=db.prepare('SELECT * FROM mcp_session_coordination WHERE target=?').get(input.id)
      if(!current||current.caller!==scope.conversationID||current.epoch!==String(input.epoch))throw fail(409,'This coordination assignment has changed. Read the current session status.')
      if(action==='release')db.prepare('DELETE FROM mcp_session_coordination WHERE target=? AND caller=? AND epoch=?').run(input.id,scope.conversationID,String(input.epoch))
      else db.prepare('UPDATE mcp_session_coordination SET notify=? WHERE target=? AND caller=? AND epoch=?').run(input.enabled?1:0,input.id,scope.conversationID,String(input.epoch))
      result=relationship(input.id)
    } else throw fail(400,'Unknown local session operation.')
    return saveReply(scope,requestID,success(result,requestID))
  }
  function respondAccess(caller,interaction,allowed) {
    const request=db.prepare('SELECT * FROM mcp_session_access_requests WHERE id=? AND caller=? AND interaction_id=?').get(interaction.mcpManageAccessID,caller,interaction.id)
    if(!request||request.state!=='pending')throw fail(409,'This management request is no longer pending.')
    db.prepare('UPDATE mcp_session_access_requests SET state=? WHERE id=?').run(allowed?'approved':'rejected',request.id)
  }
  function pump(target) {
    if(pumps.has(target))return pumps.get(target)
    const pending=(async()=> {
      if(getRecord(target).conversation.activeRunID)return
      const next=db.prepare("SELECT * FROM mcp_session_messages WHERE target=? AND status='queued' ORDER BY rowid LIMIT 1").get(target)
      if(!next)return
      const receipt=await baseCommand('send',next.caller,next.id,'queue-delivery',{conversationID:target,text:next.text,agentSourceID:next.caller,...(next.notification===1?{coordinationNotification:true}:{})})
      db.prepare('UPDATE mcp_session_messages SET status=?,receipt=? WHERE id=?').run(receipt.status,JSON.stringify(receipt),next.id)
    })().finally(()=>pumps.delete(target));pumps.set(target,pending);return pending
  }
  async function notify(target,runID,kind,details,notificationID=runID+':'+kind) {
    const coordination=db.prepare('SELECT * FROM mcp_session_coordination WHERE target=? AND notify=1').get(target)
    if(!coordination||!policy(coordination.caller).includes('sessions'))return
    const id=stableID([target,coordination.epoch,notificationID].join(':'))
    if(db.prepare('SELECT id FROM mcp_coordination_notifications WHERE id=?').get(id))return
    const message=`Woven session ${getRecord(target).conversation.title??target} (${target}) ${kind==='needs-input'?'needs user input':kind==='failed'?'stopped with an error':'finished a turn'}. ${details??''}\nRead its status or relevant history before deciding what to do next. A finished turn does not complete the assignment. Permission approvals remain with the user.`
    const receipt=await deliver(target,coordination.caller,message,id,'notification')
    if(['accepted','completed','queued'].includes(receipt.status))db.prepare('INSERT OR IGNORE INTO mcp_coordination_notifications VALUES(?)').run(id)
  }
  return {call,relationship,readableConversationIDs,respondAccess,
    settled(target,runID,error,notificationOnly=false){if(!notificationOnly)void notify(target,runID,error?'failed':'completed',error?.message).catch(()=>{});void pump(target).catch(()=>{})},
    needsInput(target,runID,interaction){void notify(target,runID,'needs-input',interaction.title,interaction.id).catch(()=>{})}}
}
