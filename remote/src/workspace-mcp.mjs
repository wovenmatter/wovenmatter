import { createHash, randomBytes, randomUUID, createCipheriv, createDecipheriv } from 'node:crypto'
import { readFileSync } from 'node:fs'

const fail = (statusCode, message) => Object.assign(new Error(message), {statusCode})
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
const hash = value => createHash('sha256').update(value).digest('hex')
const groups = new Set(['notes','history','sessions','goals','timers','usage','calendar','library','executor','browser','computer'])
const groupFor = name => name === 'woven_context' || name.startsWith('woven_databases_') ? 'notes' : name.split('_')[1]
const errorReply = (id, code, message) => ({jsonrpc:'2.0',id:id??null,error:{code,message}})
const result = value => value.result?.content ? {content:value.result.content,structuredContent:{success:value.success,requestID:value.requestID},isError:value.success===false}
  : {content:[{type:'text',text:JSON.stringify(value.result ?? null)}],structuredContent:value,isError:value.success===false}

export function loadWorkspaceMCPCatalog() {
  return JSON.parse(readFileSync(new URL('./woven-mcp-tools.json', import.meta.url), 'utf8'))
}

// The public endpoint never accepts a conversation id as caller authority. A
// session connection or separately created outside-client credential owns it.
export function createWorkspaceMCP({db,identity,secret,endpointURL,policy,localTools,localCall,fetchImpl=globalThis.fetch,catalog=loadWorkspaceMCPCatalog(),now=Date.now,beforeLibraryCall=async()=>{},shouldDelegate=()=>false,scopedHistoryAccess=()=>false}) {
  db.exec(`CREATE TABLE IF NOT EXISTS mcp_external_clients (id TEXT PRIMARY KEY, digest TEXT NOT NULL UNIQUE, body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS mcp_library_connection (id INTEGER PRIMARY KEY CHECK(id=1), envelope TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS mcp_preferences (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL);`)
  const key = typeof secret === 'string' && secret.length >= 16 ? createHash('sha256').update('wovenmatter-workspace-mcp-library-v1\0'+secret).digest() : null
  const sessions = new Map(), controllers = new Set(), taskPolicies=new Map(),inFlight=new Map()
  let stopped = false
  const definition = new Map(catalog.map(tool=>[tool.name,tool]))
  const local = new Set(localTools)
  const own = () => identity()
  const defaultSettings={enabledByDefault:['notes','history','sessions','goals','timers','usage','calendar','library','browser'],maximumManagedSessions:4,maximumRunningSessions:16,harnessDefaults:{}}
  function settings(){return JSON.parse(db.prepare('SELECT body FROM mcp_preferences WHERE id=1').get()?.body??JSON.stringify(defaultSettings))}
  function configureSettings(value) {
    const enabled=value?.enabledByDefault
    if(!Array.isArray(enabled)||enabled.some(group=>!groups.has(group)||group==='databases')||!Number.isSafeInteger(value.maximumManagedSessions)||value.maximumManagedSessions<1||value.maximumManagedSessions>16||!Number.isSafeInteger(value.maximumRunningSessions)||value.maximumRunningSessions<1||value.maximumRunningSessions>48)throw fail(400,'Invalid Woven MCP tool defaults or session limits.')
    const defaults=value.harnessDefaults??{}
    if(!defaults||typeof defaults!=='object'||Array.isArray(defaults))throw fail(400,'Invalid destination harness defaults.')
    for(const [kind,selection] of Object.entries(defaults)) {
      if(!['default_agent','codex','claude_code','grok_build','opencode'].includes(kind)||!selection||typeof selection!=='object'||Array.isArray(selection))throw fail(400,'Invalid destination harness default.')
      for(const name of ['model','thinking','permission'])if(selection[name]!=null&&(typeof selection[name]!=='string'||selection[name].length>4096))throw fail(400,'Invalid saved harness selection.')
      if(selection.tools!=null&&(!Array.isArray(selection.tools)||selection.tools.some(group=>!groups.has(group)||group==='databases')))throw fail(400,'Invalid saved harness tool defaults.')
      if(selection.usesProductPermissionDefault!=null&&typeof selection.usesProductPermissionDefault!=='boolean')throw fail(400,'Invalid saved harness permission default.')
    }
    const normalized={enabledByDefault:[...new Set([...enabled,'goals'])],maximumManagedSessions:value.maximumManagedSessions,maximumRunningSessions:value.maximumRunningSessions,harnessDefaults:defaults}
    db.prepare('INSERT INTO mcp_preferences VALUES(1,?) ON CONFLICT(id) DO UPDATE SET body=excluded.body').run(JSON.stringify(normalized))
    return settings()
  }
  function libraryGrant() {
    if (!key) return null
    const row = db.prepare('SELECT envelope FROM mcp_library_connection WHERE id=1').get()
    if (!row) return null
    try {
      const saved=JSON.parse(row.envelope),workspace=own(), decipher=createDecipheriv('aes-256-gcm',key,Buffer.from(saved.iv,'base64'))
      decipher.setAAD(Buffer.from(JSON.stringify([workspace.libraryID,workspace.id,workspace.executionDeviceID])))
      decipher.setAuthTag(Buffer.from(saved.tag,'base64'))
      return JSON.parse(Buffer.concat([decipher.update(Buffer.from(saved.ciphertext,'base64')),decipher.final()]).toString('utf8'))
    } catch { return null }
  }
  function libraryStatus() {
    const value=libraryGrant()
    return {configured:!!value,...(value?{grantID:value.grantID,libraryID:value.libraryID,workspaceID:value.workspaceID,executionDeviceID:value.executionDeviceID}:{})}
  }
  function configureLibrary(value) {
    const workspace=own();let endpoint
    try {endpoint=new URL(value.endpointURL)} catch {throw fail(400,'Invalid library MCP endpoint.')}
    if(!key||!uuid(value.grantID)||value.libraryID!==workspace.libraryID||value.workspaceID!==workspace.id||value.executionDeviceID!==workspace.executionDeviceID
      ||typeof value.bearerToken!=='string'||value.bearerToken.length<32||value.bearerToken.length>256
      ||endpoint.protocol!=='https:'||!endpoint.hostname.endsWith('.ts.net')||endpoint.username||endpoint.password||endpoint.search||endpoint.hash||!endpoint.pathname.endsWith('/mcp/workspace')) {
      throw fail(400,'The MCP library grant must match this workspace and its private central endpoint.')
    }
    if(value.toolSettings)configureSettings(value.toolSettings)
    const iv=randomBytes(12),cipher=createCipheriv('aes-256-gcm',key,iv)
    cipher.setAAD(Buffer.from(JSON.stringify([workspace.libraryID,workspace.id,workspace.executionDeviceID])))
    const encrypted=Buffer.concat([cipher.update(JSON.stringify(value),'utf8'),cipher.final()])
    db.prepare('INSERT INTO mcp_library_connection VALUES(1,?) ON CONFLICT(id) DO UPDATE SET envelope=excluded.envelope')
      .run(JSON.stringify({iv:iv.toString('base64'),ciphertext:encrypted.toString('base64'),tag:cipher.getAuthTag().toString('base64')}))
    return libraryStatus()
  }
  function clearLibrary() {db.prepare('DELETE FROM mcp_library_connection').run();return libraryStatus()}
  function endpoint() {const value=typeof endpointURL==='function'?endpointURL():endpointURL;if(!value)throw fail(503,'The Woven MCP listener is not ready.');return value}
  function sessionConnection(conversationID) {
    if(!uuid(conversationID)||stopped)throw fail(409,'Invalid Woven MCP session.')
    let scope=sessions.get(conversationID)
    if(!scope){scope={id:randomUUID(),conversationID,bearerToken:randomBytes(32).toString('base64url'),lastAliveAt:now()};sessions.set(conversationID,scope)}
    scope.lastAliveAt=now()
    return {endpointURL:endpoint(),bearerToken:scope.bearerToken,sessionID:conversationID}
  }
  function resolvePrincipal(authorization) {
    if(stopped||typeof authorization!=='string'||!authorization.startsWith('Bearer '))return null
    const digest=hash(authorization.slice(7))
    for(const scope of sessions.values())if(hash(scope.bearerToken)===digest&&now()-scope.lastAliveAt<=24*3600000){scope.lastAliveAt=now();return scope}
    const row=db.prepare('SELECT body FROM mcp_external_clients WHERE digest=?').get(digest)
    return row?JSON.parse(row.body):null
  }
  function provisionClient(body) {
    if(!uuid(body.conversationID)||typeof body.label!=='string'||!body.label.trim()||body.label.length>256)throw fail(400,'Choose an existing conversation and client label.')
    policy(body.conversationID)
    const enabledGroups=body.enabledGroups??['notes','history','sessions','goals','usage','calendar','library']
    if(!Array.isArray(enabledGroups)||enabledGroups.some(group=>!groups.has(group)))throw fail(400,'Invalid MCP client capabilities.')
    const bearerToken=randomBytes(32).toString('base64url'),scope={id:randomUUID(),conversationID:body.conversationID,label:body.label.trim(),readOnly:body.readOnly!==false,enabledGroups:[...new Set(enabledGroups)],createdAt:new Date(now()).toISOString()}
    db.prepare('INSERT INTO mcp_external_clients VALUES(?,?,?)').run(scope.id,hash(bearerToken),JSON.stringify(scope))
    const externalEndpoint=own().endpoint?own().endpoint.replace(/\/$/,'')+'/mcp':endpoint()
    return {...scope,connection:{endpointURL:externalEndpoint,bearerToken,sessionID:scope.conversationID}}
  }
  function clients(){return db.prepare('SELECT body FROM mcp_external_clients ORDER BY id').all().map(row=>JSON.parse(row.body))}
  function revokeClient(id){db.prepare('DELETE FROM mcp_external_clients WHERE id=?').run(id);return {revoked:true}}
  function activeGroups(scope) {
    const current=new Set(taskPolicies.get(scope.conversationID)??policy(scope.conversationID))
    return scope.enabledGroups?new Set(scope.enabledGroups.filter(group=>current.has(group))):current
  }
  function inventory(scope) {
    return catalog.filter(tool=>{
      const group=groupFor(tool.name)
      const granted=!scope.enabledGroups||scope.enabledGroups.includes(group)
      const taskSupported=!scope.taskProof||!['goals','timers'].includes(group)&&(!tool.name.startsWith('woven_sessions_')||['woven_sessions_list','woven_sessions_status','woven_sessions_folders','woven_sessions_harnesses'].includes(tool.name))
      return granted&&taskSupported&&(!scope.readOnly||tool.annotations?.readOnlyHint===true)
    })
  }
  function available(scope) {
    const current=activeGroups(scope),hasLibrary=!!libraryGrant()
    return inventory(scope).filter(tool=>{
      const group=groupFor(tool.name)
      const cleanup=['woven_browser_cancel','woven_computer_cancel'].includes(tool.name)
      const scopedHistory=!scope.taskProof&&group==='history'&&scopedHistoryAccess(scope)
      const localTask=tool.name.startsWith('woven_databases_')||tool.name==='woven_context'||group==='browser'&&local.has(tool.name)
      const transport=scope.taskProof?(localTask||hasLibrary):(local.has(tool.name)||hasLibrary)
      return (current.has(group)||cleanup||scopedHistory)&&transport
    })
  }
  async function prepareTask({run,eventRevision,nativeSessionID}) {
    if(!uuid(run?.sessionID)||!uuid(run?.id)||!Number.isSafeInteger(eventRevision))throw fail(400,'Invalid scheduled MCP caller.')
    const connection=sessionConnection(run.sessionID),scope=sessions.get(run.sessionID)
    scope.taskProof={run,eventRevision,...(nativeSessionID?{nativeSessionID}:{})}
    taskPolicies.set(run.sessionID,run.task?.configuration?.tools?.enabled??['notes'])
    const grant=libraryGrant()
    if(grant) {
      try {await prepareTaskCaller(scope,grant)} catch(error) {
        // Host-local data tools retain their saved schedule permissions while
        // the library is offline; delegated operations still fail explicitly.
        if(error.statusCode&&error.statusCode<500)throw error
      }
    }
    return {...connection,captureID:run.id}
  }
  async function prepareTaskCaller(scope,grant,signal) {
    const response=await fetchImpl(grant.endpointURL+'/prepare',{method:'POST',redirect:'error',signal:signal??AbortSignal.timeout(15000),
      headers:{authorization:'Bearer '+grant.bearerToken,'content-type':'application/json','x-woven-protocol':'3','x-woven-workspace':grant.libraryID},body:JSON.stringify(scope.taskProof)})
    if(!response.ok)throw fail(response.status,'The saved schedule no longer authorizes this MCP caller.')
    const value=await response.json()
    if(!Array.isArray(value.enabledGroups)||value.enabledGroups.some(group=>!groups.has(group)))throw fail(502,'Invalid schedule tool policy.')
    taskPolicies.set(scope.conversationID,value.enabledGroups)
  }
  async function libraryCall(scope,message,signal) {
    const grant=libraryGrant()
    if(!grant)throw fail(503,'The central library MCP connection has not been provisioned for this workspace.')
    const controller=new AbortController();controllers.add(controller)
    const timer=setTimeout(()=>controller.abort(),115000);timer.unref()
    const headers={authorization:'Bearer '+grant.bearerToken,'content-type':'application/json',accept:'application/json, text/event-stream','mcp-protocol-version':'2025-06-18',
      'x-woven-protocol':'3','x-woven-workspace':grant.libraryID,'x-woven-conversation-id':scope.conversationID,'x-woven-enabled-groups':[...activeGroups(scope)].join(',')}
    try {
      if(scope.taskProof)await prepareTaskCaller(scope,grant,signal)
      else await beforeLibraryCall()
      const response=await fetchImpl(grant.endpointURL,{method:'POST',headers,redirect:'error',body:JSON.stringify(message),signal:signal?AbortSignal.any([controller.signal,signal]):controller.signal})
      if(!response.ok)throw fail(response.status,'The central library did not authorize this Woven MCP request. Refresh the workspace connection before retrying.')
      const text=await response.text()
      if(Buffer.byteLength(text)>4*1024*1024)throw fail(413,'The library MCP response is too large. Request a smaller page.')
      return response.status===202?null:JSON.parse(text)
    } catch(error) {
      if(error.statusCode)throw error
      throw fail(503,'The central library is unavailable. Local workspace tools remain available; inspect prior effects before retrying mutations.')
    } finally {clearTimeout(timer);controllers.delete(controller)}
  }
  async function handle(scope,message,{signal}={}) {
    if(!scope)throw fail(401,'A valid Woven MCP credential is required.')
    if(!message||typeof message!=='object'||Array.isArray(message)||message.jsonrpc!=='2.0'||typeof message.method!=='string'||message.id!==undefined&&message.id!==null&&typeof message.id!=='string'&&!(typeof message.id==='number'&&Number.isFinite(message.id)))return errorReply(message?.id,-32600,'Invalid JSON-RPC request.')
    const id=message.id
    if(id===undefined){
      if(message.method==='notifications/cancelled'&&message.params?.requestId!==undefined)inFlight.get(scope.id+':'+JSON.stringify(message.params.requestId))?.abort()
      return null
    }
    if(message.params!==undefined&&(!message.params||typeof message.params!=='object'||Array.isArray(message.params)))return errorReply(id,-32602,'Parameters must be an object.')
    if(message.method==='initialize'&&(!message.params?.protocolVersion||!message.params?.capabilities||!message.params?.clientInfo))return errorReply(id,-32602,'Initialization requires protocolVersion, capabilities and clientInfo.')
    if(message.method==='initialize')return {jsonrpc:'2.0',id,result:{protocolVersion:['2025-11-25','2025-06-18','2025-03-26'].includes(message.params?.protocolVersion)?message.params.protocolVersion:'2025-11-25',capabilities:{tools:{listChanged:false}},serverInfo:{name:'Woven MCP',version:'1.0.0'},instructions:'Use named Woven tools within this credential’s conversation and current permissions. Library operations require the central library; local execution tools remain available while it is offline. Never replay an uncertain external effect.'}}
    if(message.method==='ping')return {jsonrpc:'2.0',id,result:{}}
    let requestKey,requestController,operationRequestID
    try {
      if(message.method==='tools/list'&&message.params?.cursor!==undefined)return errorReply(id,-32602,'This catalog has no pagination cursor.')
      if(message.method==='tools/list') {
        activeGroups(scope) // Validate the live caller without narrowing its cached schema inventory.
        return {jsonrpc:'2.0',id,result:{tools:inventory(scope)}}
      }
      if(message.method!=='tools/call')return errorReply(id,-32601,'Method not found.')
      const name=message.params?.name,input=message.params?.arguments??{},tool=definition.get(name)
      if(!tool||!available(scope).some(item=>item.name===name))return errorReply(id,-32602,'This Woven tool is unavailable or disabled for this caller.')
      try {validateInput(tool.inputSchema,input);if(input.requestID!==undefined&&!uuid(input.requestID))throw fail(400,'requestID must be a UUID.')} catch(error) {return errorReply(id,-32602,error.message)}
      operationRequestID=input.requestID?.toLowerCase()??randomUUID()
      requestKey=scope.id+':'+JSON.stringify(id)
      if(inFlight.size>=32||[...inFlight.keys()].filter(key=>key.startsWith(scope.id+':')).length>=8)return errorReply(id,-32000,'The Woven MCP service is busy. Retry with the same requestID after an active call finishes.')
      if(inFlight.has(requestKey))return errorReply(id,-32600,'This JSON-RPC request ID is already active for this caller.')
      requestController=new AbortController();inFlight.set(requestKey,requestController)
      const invocationSignal=signal?AbortSignal.any([signal,requestController.signal]):requestController.signal
      if(!local.has(name)||shouldDelegate(scope,name,input)||scope.taskProof&&!name.startsWith('woven_databases_')&&name!=='woven_context'&&groupFor(name)!=='browser')return await libraryCall(scope,{...message,params:{...message.params,arguments:{...input,requestID:operationRequestID}}},invocationSignal)
      const value=await localCall(scope,name,{...input,requestID:operationRequestID},{signal:invocationSignal})
      const reply=result(value)
      if(Buffer.byteLength(JSON.stringify(reply))>1048576)throw fail(413,'The response exceeds 1 MiB. Request a smaller page or character window.')
      return {jsonrpc:'2.0',id,result:reply}
    } catch(error) {
      return {jsonrpc:'2.0',id,result:{isError:true,content:[{type:'text',text:error.message??'The Woven MCP request failed.'}],structuredContent:{success:false,...(operationRequestID?{requestID:operationRequestID}:{}),error:error.message??'The Woven MCP request failed.',code:error.statusCode===403?'capability_denied':error.statusCode===503?'unavailable':'operation_failed'}}}
    } finally {if(requestKey&&inFlight.get(requestKey)===requestController)inFlight.delete(requestKey)}
  }
  return {settings,configureSettings,sessionConnection,prepareTask,resolvePrincipal,handle,libraryStatus,configureLibrary,clearLibrary,provisionClient,clients,revokeClient,
    revokeSession:conversationID=>sessions.delete(conversationID),close(){stopped=true;sessions.clear();taskPolicies.clear();for(const controller of inFlight.values())controller.abort();inFlight.clear();for(const controller of controllers)controller.abort();controllers.clear()}}
}

// The canonical catalog uses flat named inputs. Validate its public schema at
// the transport boundary before any local or delegated operation is admitted.
export function validateInput(schema,input) {
  if(!input||typeof input!=='object'||Array.isArray(input))throw fail(400,'Tool arguments must be an object.')
  const properties=schema.properties??{}
  for(const name of schema.required??[])if(input[name]===undefined)throw fail(400,'Missing tool argument: '+name)
  for(const [name,value] of Object.entries(input)) {
    const field=properties[name]
    if(!field)throw fail(400,'Unknown tool argument: '+name)
    const type=field.type
    if(type==='integer'&&!Number.isSafeInteger(value)||type==='number'&&(!Number.isFinite(value)||typeof value!=='number')||type==='string'&&typeof value!=='string'||type==='boolean'&&typeof value!=='boolean'||type==='array'&&!Array.isArray(value)||type==='object'&&(!value||typeof value!=='object'||Array.isArray(value)))throw fail(400,'Invalid tool argument: '+name)
    if(field.enum&&!field.enum.includes(value)||field.minimum!=null&&value<field.minimum||field.maximum!=null&&value>field.maximum)throw fail(400,'Tool argument is outside its supported range: '+name)
    if(field.format==='uuid'&&!uuid(value))throw fail(400,'Tool request ID must be a UUID.')
  }
}
