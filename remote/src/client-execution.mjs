import { createClientExecutionPublisher } from './client-execution-publisher.mjs'
import { DatabaseSync } from 'node:sqlite'
import { mkdirSync, chmodSync } from 'node:fs'
import { mutateGoal, settleGoal, setGoalStatus, budgetReached, goalUsageUnavailable, goalPrompt, goalGuidance } from './client-goals.mjs'
import { resolve } from 'node:path'
import { createWorkspaceMCP } from './workspace-mcp.mjs'
import { createWorkspaceMCPOrchestration } from './workspace-mcp-orchestration.mjs'
import { queryWorkspaceMCPHistory } from './workspace-mcp-history.mjs'
import { databaseOperation } from './database-catalog.mjs'
import { createHash, randomBytes, randomUUID, timingSafeEqual, createCipheriv, createDecipheriv } from 'node:crypto'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const identifier = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
const digest = value => createHash('sha256').update(value).digest('hex')
const ordered = value => Array.isArray(value) ? value.map(ordered) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value
const copy = structuredClone
const date = () => new Date().toISOString()
function textParts(value) {
  const parts=[]
  for(let start=0;start<value.length;) {
    let end=Math.min(start+16384,value.length)
    const last=value.charCodeAt(end-1),next=value.charCodeAt(end)
    if(last>=0xd800&&last<=0xdbff&&next>=0xdc00&&next<=0xdfff)end--
    parts.push(value.slice(start,end));start=end
  }
  return parts.length?parts:['']
}
function inputMessages(command,runID) {
  return textParts(command.text).map((content,index)=>({id:index?`${command.commandID}-part-${index}`:command.commandID,
    conversationID:command.conversationID,runID,role:'user',content,createdAt:date(),...(command.agentSourceID?{agentSourceID:command.agentSourceID,isAgentAuthored:true,senderSessionTitle:command.senderSessionTitle,senderHarness:command.senderHarness,senderKind:command.senderKind??'message'}:{})}))
}

// This store is owned by the workspace service (the existing host lock fences
// competing owners). Neither a phone nor an SSH attachment owns these runs.
export function createClientExecution({ directory, runtime, kind = 'linux', name = 'Workspace', publisherKey, publisherFetch, publisherIntervalMilliseconds, goalIntervalMilliseconds = 1000, mcpEndpointURL = 'http://127.0.0.1:7337/mcp', managedDataRoot = resolve(directory, '../databases'), mcpCatalog,externalRunningSessions=()=>0,workspaceBrowser }) {
  mkdirSync(directory, { recursive: true, mode: 0o700 })
  const path = resolve(directory, 'execution.sqlite')
  const db = new DatabaseSync(path)
  chmodSync(path, 0o600)
  db.exec(`PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
    CREATE TABLE IF NOT EXISTS identity (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS devices (id TEXT PRIMARY KEY, digest TEXT NOT NULL, body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS commands (id TEXT PRIMARY KEY, device TEXT NOT NULL, fingerprint TEXT NOT NULL, body TEXT NOT NULL, receipt TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS conversations (id TEXT PRIMARY KEY, body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, body TEXT NOT NULL);
    CREATE TABLE IF NOT EXISTS runs (id TEXT PRIMARY KEY, commandID TEXT NOT NULL);`)
  let identity = JSON.parse(db.prepare('SELECT body FROM identity WHERE id=1').get()?.body ?? 'null')
  const jobs = new Map(), queues = new Map(), dirty = new Map()
  let flushTimer
  let closed = false, unlockMaterial
  let goalsTickRunning = false
  const transaction = action => {
    db.exec('BEGIN IMMEDIATE')
    try { const value = action(); db.exec('COMMIT'); return value }
    catch (error) { db.exec('ROLLBACK'); throw error }
  }
  function assertIdentity() { if (!identity) throw fail(409, 'This workspace has not been enrolled in a central library.') }
  function event(kind, conversationID, payload, runID) {
    const record = { eventID: randomUUID(), recordedAt:date(), workspaceID: identity.id, conversationID, kind, ...(runID ? {runID} : {}), ...payload }
    const result = db.prepare('INSERT INTO events(body) VALUES (?)').run('{}')
    record.originSequence = Number(result.lastInsertRowid)
    db.prepare('UPDATE events SET body=? WHERE sequence=?').run(JSON.stringify(record), record.originSequence)
  }
  function save(record) {
    db.prepare('INSERT OR REPLACE INTO conversations(id,body) VALUES (?,?)').run(record.conversation.id, JSON.stringify(record))
  }
  function publish(record, changed) {
    save(record)
    event('conversation', record.conversation.id, { conversation: record.conversation }, record.conversation.activeRunID)
    const messages = changed ? record.transcript.messages.filter(item => changed.messages.has(item.id)) : record.transcript.messages
    const activities = changed ? record.transcript.activities.filter(item => changed.activities.has(item.id)) : record.transcript.activities
    // A journal transcript is an upsert batch, never a replacement of history.
    // Bound entries independently of total conversation length.
    for (let offset = 0; offset < Math.max(messages.length, activities.length, 1); offset += 4) {
      event('transcript', record.conversation.id, { transcript: { conversationID: record.conversation.id,
        messages: messages.slice(offset, offset + 4), activities: activities.slice(offset, offset + 4),
        ...(record.transcript.activeRunID ? {activeRunID: record.transcript.activeRunID} : {}) } }, record.conversation.activeRunID)
    }
  }
  function flush(id) {
    const changes = dirty.get(id)
    if (!changes) return
    transaction(() => publish(getRecord(id), changes)); dirty.delete(id)
  }
  function markDirty(record, messages = [], activities = []) {
    save(record)
    const changes = dirty.get(record.conversation.id) ?? {messages: new Set(), activities: new Set()}
    messages.forEach(id => changes.messages.add(id)); activities.forEach(id => changes.activities.add(id))
    dirty.set(record.conversation.id, changes)
    if (!flushTimer) { flushTimer = setTimeout(() => { flushTimer = undefined; for (const id of dirty.keys()) flush(id) }, 500); flushTimer.unref() }
  }
  function receipt(command, status, fields = {}) {
    const value = { commandID: command.commandID, deviceID: command.deviceID, libraryID: identity.libraryID, workspaceID: identity.id, status,
      ...(command.conversationID ? { conversationID: command.conversationID } : {}), ...(command.runID ? { runID: command.runID } : {}), ...fields }
    db.prepare('UPDATE commands SET receipt=? WHERE id=?').run(JSON.stringify(value), command.commandID)
    if (value.conversationID) event('receipt', value.conversationID, { receipt: value }, value.runID)
    return value
  }
  // A process loss is not permission to re-run an accepted external effect.
  // The native agent retains its own checkpoints; a user may explicitly resume.
  transaction(() => {
    if (!identity) return
    for (const row of db.prepare('SELECT body,receipt FROM commands').all()) {
      const current = JSON.parse(row.receipt)
      if (current.status === 'accepted') receipt(JSON.parse(row.body), 'outcomeUnknown', { ...current, status: 'outcomeUnknown', message: 'The workspace restarted. Check the saved conversation before sending again.' })
    }
    for (const row of db.prepare('SELECT body FROM conversations').all()) {
      const record = JSON.parse(row.body)
      if(record.goal?.status==='active'){setGoalStatus(record.goal,'paused');record.goal.evidence='The execution owner restarted. Resume explicitly.';delete record.goal.pendingDeliveryID;save(record)}
      if (record.conversation.activeRunID) {
        for(const activity of record.transcript.activities)if(activity.status==='running')activity.status='interrupted'
        delete record.conversation.activeRunID; delete record.transcript.activeRunID; record.pending = record.pending.filter(item=>item.mcpManageAccessID)
        for (const message of record.transcript.messages) if (message.status === 'running') message.status = 'interrupted'
        publish(record)
      }
    }
  })
  function descriptor() { assertIdentity(); return copy(identity) }
  function provision(body) {
    if (!identifier(body.libraryID) || !identifier(body.workspaceID) || !identifier(body.deviceID) || !identifier(body.ownerDeviceID)
      || !Array.isArray(body.scopes) || !body.scopes.length || body.scopes.some(scope => !['execution','inference'].includes(scope))) throw fail(400, 'Invalid device enrollment.')
    if (identity && (identity.id !== body.workspaceID || identity.libraryID !== body.libraryID)) throw fail(409, 'This workspace already belongs to a different library.')
    const token = randomBytes(32).toString('base64url')
    let unlockEnvelope
    if (unlockMaterial) {
      const iv = randomBytes(12), key = createHash('sha256').update('wovenmatter-client-unlock-v1\0'+token).digest()
      const cipher = createCipheriv('aes-256-gcm',key,iv)
      cipher.setAAD(Buffer.from(JSON.stringify([body.libraryID,body.workspaceID,body.deviceID,[...new Set(body.scopes)].sort()])))
      const ciphertext = Buffer.concat([cipher.update(JSON.stringify(unlockMaterial),'utf8'),cipher.final()])
      unlockEnvelope = {iv:iv.toString('base64'),ciphertext:ciphertext.toString('base64'),tag:cipher.getAuthTag().toString('base64')}
    }
    let nextIdentity
    transaction(() => {
      nextIdentity = identity ? copy(identity) : { id: body.workspaceID, libraryID: body.libraryID, ownerDeviceID: body.ownerDeviceID, executionDeviceID: randomUUID(),
        kind, name: typeof body.workspaceName === 'string' ? body.workspaceName.slice(0,256) : name,
        capabilities: ['execution','historyReplay','idempotentCommands','inference'], journalDeviceIDs: [], revision: 1, deleted: false }
      if (body.endpoint) {
        const endpoint = new URL(body.endpoint)
        if (endpoint.protocol !== 'https:' || !endpoint.hostname.endsWith('.ts.net') || endpoint.username || endpoint.password || endpoint.search || endpoint.hash) throw fail(400, 'Use a private Tailscale HTTPS endpoint.')
        nextIdentity.endpoint = endpoint.href.replace(/\/$/, '')
      }
      const device = { id: body.deviceID, name: String(body.name ?? 'Client').slice(0,256), scopes: [...new Set(body.scopes)], createdAt: date(), ...(unlockEnvelope ? {unlockEnvelope} : {}) }
      db.prepare('INSERT OR REPLACE INTO devices VALUES (?,?,?)').run(device.id, digest(token), JSON.stringify(device))
      // Observing devices may control/read this workspace but never publish its origin history.
      nextIdentity.journalDeviceIDs = []
      nextIdentity.revision++
      db.prepare('INSERT OR REPLACE INTO identity VALUES (1,?)').run(JSON.stringify(nextIdentity))
    })
    identity = nextIdentity
    return { workspace: descriptor(), token, deviceID: body.deviceID }
  }
  function principal(authorization, scope) {
    if (typeof authorization !== 'string' || !authorization.startsWith('Bearer ')) return null
    const supplied = Buffer.from(digest(authorization.slice(7)), 'hex')
    for (const row of db.prepare('SELECT digest,body FROM devices').all()) {
      const device = JSON.parse(row.body)
      if (timingSafeEqual(supplied, Buffer.from(row.digest, 'hex')) && device.scopes.includes(scope)) return device
    }
    return null
  }
  function rememberUnlockMaterial(value) {
    if (typeof value?.workspace !== 'string' || typeof value?.unlockKey !== 'string' || !value.unlockKey) throw fail(400,'Invalid workspace unlock material.')
    unlockMaterial = {workspace:value.workspace,unlockKey:value.unlockKey}
  }
  function clientUnlockMaterial(authorization) {
    const device = principal(authorization,'inference') ?? principal(authorization,'execution')
    if (!device?.unlockEnvelope) return null
    try {
      const {iv,tag,ciphertext} = device.unlockEnvelope
      const key = createHash('sha256').update('wovenmatter-client-unlock-v1\0'+authorization.slice(7)).digest()
      const decipher = createDecipheriv('aes-256-gcm',key,Buffer.from(iv,'base64'))
      decipher.setAAD(Buffer.from(JSON.stringify([identity.libraryID,identity.id,device.id,[...device.scopes].sort()]))); decipher.setAuthTag(Buffer.from(tag,'base64'))
      const value = JSON.parse(Buffer.concat([decipher.update(Buffer.from(ciphertext,'base64')),decipher.final()]).toString('utf8'))
      rememberUnlockMaterial(value); return value
    } catch { throw fail(403,'This device must be reauthorized by the central Mac before using stored model accounts.') }
  }
  function revoke(id) {
    transaction(() => {
      db.prepare('DELETE FROM devices WHERE id=?').run(id)
      if (identity?.journalDeviceIDs.includes(id)) {
        const next=copy(identity); next.journalDeviceIDs=next.journalDeviceIDs.filter(value=>value!==id); next.revision++
        db.prepare('UPDATE identity SET body=? WHERE id=1').run(JSON.stringify(next));identity=next
      }
    })
  }
  function getRecord(id) {
    if (!identifier(id)) throw fail(400, 'Invalid conversation identifier.')
    const row = db.prepare('SELECT body FROM conversations WHERE id=?').get(id)
    if (!row) throw fail(404, 'Conversation not found in this workspace.')
    return JSON.parse(row.body)
  }
  async function adopt(body) {
    assertIdentity()
    if(body.workspaceID!==identity.id || !identifier(body.conversation?.id)||body.conversation.activeRunID
      || typeof body.nativeSessionID!=='string'||!body.nativeSessionID||typeof body.runtimeKind!=='string'
      || (body.knownRunIDs!=null&&(!Array.isArray(body.knownRunIDs)||body.knownRunIDs.some(id=>!identifier(id))))) throw fail(400,'Invalid native conversation adoption.')
    return serialize('native:'+body.runtimeKind+':'+body.nativeSessionID,()=>serialize(body.conversation.id,async()=>{
      const existing=db.prepare('SELECT body FROM conversations WHERE id=?').get(body.conversation.id)
      if(existing) {
        const record=JSON.parse(existing.body)
        if(record.native.sessionID!==body.nativeSessionID||record.conversation.runtimeKind!==body.runtimeKind)throw fail(409,'This conversation already belongs to a different native session.')
        return record.conversation
      }
      if(db.prepare("SELECT id FROM conversations WHERE json_extract(body,'$.conversation.runtimeKind')=? AND json_extract(body,'$.native.sessionID')=?").get(body.runtimeKind,body.nativeSessionID))throw fail(409,'This native session already belongs to another conversation.')
      for(const runID of body.knownRunIDs??[])if(db.prepare('SELECT id FROM runs WHERE id=?').get(runID))throw fail(409,'A run already belongs to another conversation.')
      const native=await runtime.adopt({native:{sessionID:body.nativeSessionID,channelID:body.conversation.id,workspaceID:identity.id,nativeWorkingDirectory:body.nativeWorkingDirectory},runtimeKind:body.runtimeKind})
      const record={native,pending:[],conversation:{...copy(body.conversation),runtimeKind:body.runtimeKind,workspaceID:identity.id,routeID:identity.id},
        transcript:{conversationID:body.conversation.id,messages:[],activities:[]}}
      if(body.goal) {
        if(body.goal.sessionID!==body.conversation.id)throw fail(400,'Goal identity does not match.')
        record.goal=copy(body.goal);if(record.goal.status==='active')setGoalStatus(record.goal,'paused');delete record.goal.pendingDeliveryID
        record.goalBaseCompletedTurns=record.goal.completedTurns;record.goalBaseTokensUsed=record.goal.tokensUsed;record.goalRuns={}
      }
      transaction(()=>{
        for(const runID of new Set(body.knownRunIDs??[]))db.prepare('INSERT INTO runs VALUES (?,?)').run(runID,'adopted')
        publish(record)
      })
      return copy(record.conversation)
    }))
  }
  function getReceipt(id, deviceID) {
    const row = db.prepare('SELECT device,receipt FROM commands WHERE id=?').get(id)
    if (!row || row.device !== deviceID) throw fail(404, 'Command receipt not found.')
    return JSON.parse(row.receipt)
  }
  const serialize = (id, action) => {
    const task = (queues.get(id) ?? Promise.resolve()).then(action)
    const tail = task.catch(() => {})
    queues.set(id, tail); void tail.finally(() => { if (queues.get(id) === tail) queues.delete(id) })
    return task
  }
  async function command(body, device, {internal=false}={}) {
    assertIdentity()
    if (closed) throw fail(503, 'The workspace is stopping.')
    if(!internal&&['agentSourceID','coordinationNotification','initialConfiguration','senderSessionTitle','senderHarness','senderKind'].some(key=>Object.hasOwn(body,key)))throw fail(400,'Agent provenance and frozen creation intent belong to the execution owner.')
    if (!identifier(body.commandID) || !identifier(body.deviceID) || body.deviceID !== device.id
      || (body.libraryID && body.libraryID !== identity.libraryID) || (body.workspaceID && body.workspaceID !== identity.id)
      || !['createSession','send','steer','stop','respond','workspace'].includes(body.kind)) throw fail(400, 'Invalid workspace command.')
    const fingerprint = digest(JSON.stringify(ordered(body)))
    const previous = db.prepare('SELECT fingerprint,device,receipt FROM commands WHERE id=?').get(body.commandID)
    if (previous) {
      if (previous.device !== device.id || previous.fingerprint !== fingerprint) throw fail(409, 'Command identifier already belongs to another request.')
      return JSON.parse(previous.receipt)
    }
    const command = copy(body)
    command.conversationID ??= command.kind === 'createSession' ? randomUUID() : command.workspaceAction?.goal?.id ?? command.workspaceAction?.sessionTools?.id ?? command.workspaceAction?.configureSession?.id ?? command.workspaceAction?.conversation?.id
    if (!identifier(command.conversationID)) throw fail(400, 'A conversation is required.')
    const initial = { commandID: command.commandID, deviceID: device.id, conversationID: command.conversationID,
      libraryID: identity.libraryID, workspaceID: identity.id, status: 'accepted' }
    db.prepare('INSERT INTO commands VALUES (?,?,?,?,?)').run(command.commandID, device.id, fingerprint, JSON.stringify(command), JSON.stringify(initial))
    return serialize(command.conversationID, async () => {
      try { return await perform(command) }
      catch (error) { return transaction(() => receipt(command, error.outcomeUnknown ? 'outcomeUnknown' : 'rejected', {message: error.message ?? 'The workspace command failed.'})) }
    })
  }
  async function perform(command) {
    if(closed)throw fail(503,'The workspace is stopping.')
    if (command.kind === 'createSession') {
      if (db.prepare('SELECT id FROM conversations WHERE id=?').get(command.conversationID)) throw fail(409, 'Conversation already exists.')
      const providers = await runtime.providers()
      const route = command.providerID ?? command.routeID ?? command.runtimeKind ?? 'default_agent'
      const provider = providers.find(item => item.id === route)
      if (!provider?.available || provider.canStart === false || (command.runtimeKind && command.runtimeKind !== provider.runtimeKind)) throw fail(409, 'The selected agent route is unavailable or does not match its runtime.')
      const selected = provider.runtimeKind
      const defaults=mcp.settings().harnessDefaults?.[selected]??{},initial=command.initialConfiguration??{}
      const enabledTools=initial.enabledTools??[...new Set([...(defaults.tools??mcp.settings().enabledByDefault),'goals'])]
      // The authenticated tool session exists before a native MCP client
      // discovers its catalog. No prompt has been submitted at this point.
      save({native:{},pending:[],enabledTools,conversation:{id:command.conversationID,runtimeKind:selected,workspaceID:identity.id,routeID:identity.id,...(command.folderID?{folderID:command.folderID}:{})},transcript:{conversationID:command.conversationID,messages:[],activities:[]}})
      let native
      try {native = await runtime.create({ runtimeKind: selected, conversationID: command.conversationID, providerID: provider.id, workspaceID: identity.id, mcpConnection: mcp.sessionConnection(command.conversationID),nativeWorkingDirectory:initial.nativeWorkingDirectory,permission:initial.permission??defaults.permission })}
      catch(error){db.prepare('DELETE FROM conversations WHERE id=?').run(command.conversationID);mcp.revokeSession(command.conversationID);throw error}
      const record = { native, pending: [], enabledTools, conversation: { id: command.conversationID, title:initial.title??'New conversation', preview: '', runtimeKind: selected,
        providerID: provider.id, routeID: identity.id, workspaceID: identity.id, ...(command.folderID ? {folderID: command.folderID} : {}), updatedAt: date() },
        transcript: { conversationID: command.conversationID, messages: [], activities: [] } }
      return transaction(() => { publish(record); return receipt(command, 'completed') })
    }
    const record = getRecord(command.conversationID)
    if(record.native.needsAdopt) {
      const native=await runtime.adopt({native:record.native,runtimeKind:record.conversation.runtimeKind})
      record.native={...native};delete record.native.needsAdopt;save(record)
    }
    // Translate app-owned goal requests before send or steer reaches a native parser.
    if (['send','steer'].includes(command.kind) && typeof command.text === 'string') {
      const slash=command.text.trim().match(/^\/goal(?:\s+(.*))?$/is)
      if(slash) {
        const objective=slash[1]?.trim()??''
        const controls={
          '':'Establish a Woven Matter goal from our current conversation using the goal tools, then work toward it. If the intended objective is unclear, ask me to clarify before setting the goal.',
          show:'Read the current Woven Matter goal using the goal tools and report its status.',
          pause:'Pause the current Woven Matter goal using the goal tools.',
          resume:'Resume the current Woven Matter goal using the goal tools and continue working toward it.',
          clear:'Delete the current Woven Matter goal using the goal tools.'
        }
        command.text=Object.hasOwn(controls,objective.toLowerCase())?controls[objective.toLowerCase()]:`Set a Woven Matter goal using the goal tools, then work toward this objective:\n${objective}`
      }
    }
    if (command.kind === 'workspace') {
      if(command.workspaceAction?.goal) {
        const action=command.workspaceAction.goal
        if(action.id!==command.conversationID)throw fail(400,'Session identity does not match.')
        if(!['default_agent','codex','claude_code','grok_build','opencode'].includes(record.conversation.runtimeKind))throw fail(400,'Goals are unavailable for this runtime.')
        // Validate a concrete edit before cancelling any current work.
        const draft=copy(record);mutateGoal(draft,action.mutation,record.conversation.activeRunID)
        if(action.mutation.set||(action.mutation.resume&&record.goal?.status!=='active'))record.goalCommandBaseline=Number(db.prepare('SELECT coalesce(max(rowid),0) AS sequence FROM commands').get().sequence)
        const stops=['pause','clear','edit'].some(key=>action.mutation[key])
        if(stops&&record.conversation.activeRunID) {
          // Persist the goal fence before native cancellation.
          record.goal=draft.goal;record.goalRuns=draft.goalRuns;record.goalBaseCompletedTurns=draft.goalBaseCompletedTurns;record.goalBaseTokensUsed=draft.goalBaseTokensUsed;save(record)
          const runID=record.conversation.activeRunID,job=jobs.get(runID)
          if(job)job.stopped=true
          await runtime.stop({native:record.native,runtimeKind:record.conversation.runtimeKind,command:{...command,runID}})
          await job?.completion
        } else { record.goal=draft.goal;record.goalRuns=draft.goalRuns;record.goalBaseCompletedTurns=draft.goalBaseCompletedTurns;record.goalBaseTokensUsed=draft.goalBaseTokensUsed;save(record) }
        return transaction(()=>receipt(command,'completed'))
      }
      if (record.conversation.activeRunID) throw fail(409,'Wait for this run to finish before changing its settings.')
      if(command.workspaceAction?.sessionTools) {
        const options=command.workspaceAction.sessionTools
        if(options.id!==command.conversationID||!Array.isArray(options.enabled)||options.enabled.some(value=>!allToolGroups.includes(value)))throw fail(400,'Invalid execution tool selection.')
        record.enabledTools=[...new Set([...options.enabled,'goals'])]
      } else if (command.workspaceAction?.configureSession) {
        const options = command.workspaceAction.configureSession
        if (options.id !== command.conversationID) throw fail(400,'Session identity does not match.')
        await runtime.configure({native:record.native,runtimeKind:record.conversation.runtimeKind,options})
      } else if (command.workspaceAction?.conversation) {
        const action = command.workspaceAction.conversation
        if (action.id !== command.conversationID) throw fail(400,'Session identity does not match.')
        if (action.action === 'rename' && typeof action.title === 'string' && action.title.trim()) record.conversation.title = action.title.slice(0,256)
        else if (action.action === 'pin') record.conversation.isPinned = true
        else if (action.action === 'unpin') record.conversation.isPinned = false
        else if (action.action === 'move') record.conversation.folderID = action.folderID ?? null
        else throw fail(400,'This conversation action is unavailable on the execution workspace.')
      } else throw fail(400,'This action belongs to the central library, not an execution workspace.')
      return transaction(() => {publish(record);return receipt(command,'completed')})
    }
    if(command.kind==='respond') {
      const approval=record.pending.find(item=>item.id===command.interactionID&&item.mcpManageAccessID&&item.runID===command.runID)
      if(approval) {
        if(!command.response||!command.response.cancelled&&!approval.options.some(option=>option.id===command.response.optionID))throw fail(400,'Choose an offered response.')
        orchestration.respondAccess(command.conversationID,approval,!command.response.cancelled&&command.response.optionID==='allow_once')
        record.pending=record.pending.filter(item=>item.id!==approval.id)
        return transaction(()=>{save(record);return receipt(command,'completed')})
      }
    }
    if (['steer','stop','respond'].includes(command.kind) && (!command.runID || command.runID !== record.conversation.activeRunID)) throw fail(409, 'This command belongs to an older run.')
    if (command.kind === 'send') {
      if (record.conversation.activeRunID) throw fail(409, 'This conversation is already running.')
      const running=db.prepare("SELECT count(*) AS count FROM conversations WHERE json_extract(body,'$.conversation.activeRunID') IS NOT NULL").get().count
      if(running+externalRunningSessions()>=mcp.settings().maximumRunningSessions)throw fail(409,'The workspace has reached its simultaneous-session limit.')
      if (typeof command.text !== 'string' || !command.text.trim() || command.text.length > 262144) throw fail(400, 'A message is required.')
      if(command.goalID&&(record.goal?.id!==command.goalID||record.goal?.status!=='active'||record.goal?.pendingDeliveryID!==command.commandID))throw fail(409,'The goal continuation was cancelled.')
      const runID = command.runID ?? randomUUID()
      if (!identifier(runID)) throw fail(400, 'Invalid run identifier.')
      if (db.prepare('SELECT id FROM runs WHERE id=?').get(runID)) throw fail(409, 'This run identifier has already been used.')
      command.runID = runID
      record.conversation.activeRunID = runID; record.transcript.activeRunID = runID
      record.conversation.title = record.transcript.messages.length ? record.conversation.title : command.text.slice(0,100)
      record.conversation.preview = command.text.slice(0,256); record.conversation.updatedAt = date()
      const visible=command.goalID?'Continuing toward the goal.':command.text
      record.transcript.messages.push(...inputMessages({...command,text:visible},runID))
      if(record.goal?.status==='active') { (record.goalRuns??={})[runID]={settled:false};delete record.goal.pendingDeliveryID }
      command.text+=goalGuidance
      record.transcript.messages.push({id: runID, conversationID: command.conversationID, runID, role: 'assistant', content: '', status: 'running', createdAt: date()})
      const result = transaction(() => {
        db.prepare('INSERT INTO runs VALUES (?,?)').run(runID, command.commandID)
        db.prepare('UPDATE commands SET body=? WHERE id=?').run(JSON.stringify(command), command.commandID)
        publish(record); return receipt(command, 'accepted')
      })
      const job = { command, runtimeKind:record.conversation.runtimeKind, stopped: false }
      jobs.set(runID, job)
      job.completion = Promise.resolve().then(async () => {
        if(job.stopped)throw fail(409,'The run stopped before native dispatch.')
        command.mcpConnection={...mcp.sessionConnection(command.conversationID),captureID:command.commandID}
        return runtime.run({ native: record.native, runtimeKind: record.conversation.runtimeKind,
        command, publish: update => applyUpdate(command.conversationID, runID, update),
        interaction: value => setInteraction(command.conversationID, runID, value) }) })
        .then(() => finish(command, undefined), error => finish(command, error))
        .finally(() => jobs.delete(runID))
      return result
    }
    if (command.kind === 'respond') {
      const interaction = record.pending.find(item => item.id === command.interactionID && item.runID === command.runID)
      if (!interaction) throw fail(409, 'This interaction is no longer pending.')
      if (!command.response || (interaction.kind === 'approval' && !command.response.cancelled && !interaction.options.some(option => option.id === command.response.optionID))) throw fail(400, 'Choose an available response.')
      await runtime.respond({ native: record.native, runtimeKind: record.conversation.runtimeKind, command, interaction })
      const latest = getRecord(command.conversationID)
      latest.pending = latest.pending.filter(item => item.id !== interaction.id)
      return transaction(() => { save(latest); return receipt(command, 'completed') })
    }
    if (command.kind === 'stop') {
      if(record.goal?.status==='active'){setGoalStatus(record.goal,'paused');delete record.goal.pendingDeliveryID;save(record)}
      const job=jobs.get(command.runID)
      if(job)job.stopped=true
      try { await runtime.stop({ native: record.native, runtimeKind: record.conversation.runtimeKind, command }) }
      catch(error){if(job)job.stopped=false;throw error}
      return transaction(() => receipt(command, 'completed'))
    }
    if (typeof command.text !== 'string' || !command.text.trim() || command.text.length > 262144) throw fail(400, 'A message is required.')
    command.mcpConnection={...mcp.sessionConnection(command.conversationID),captureID:command.commandID}
    await runtime.steer({ native: record.native, runtimeKind: record.conversation.runtimeKind, command })
    // Read again: streaming updates may have arrived while the steer was sent.
    const latest = getRecord(command.conversationID)
    latest.transcript.messages.push(...inputMessages(command,command.runID))
    return transaction(() => { publish(latest); return receipt(command, 'completed') })
  }
  function setInteraction(conversationID, runID, interaction) {
    const record = getRecord(conversationID)
    if (record.conversation.activeRunID !== runID) return
    const value = { ...interaction, conversationID, runID }
    record.pending = [...record.pending.filter(item => item.id !== value.id), value]
    save(record)
    orchestration.needsInput(conversationID,runID,interaction)
  }
  function applyUpdate(conversationID, runID, update) {
    if (closed) return
    const record = getRecord(conversationID)
    if (record.conversation.activeRunID !== runID) return
    if (update.sessionUpdate !== 'woven_execution_binding') {
      const bytes = Buffer.from(JSON.stringify(update)), sha256 = createHash('sha256').update(bytes).digest('hex'), recordID = randomUUID()
      const partCount = Math.max(1, Math.ceil(bytes.length / 131072))
      transaction(() => {
        for (let partIndex = 0; partIndex < partCount; partIndex++) event('nativeRecord', conversationID,
          {nativeRecord:{recordID,format:'woven-native-update-v1',partIndex,partCount,byteCount:bytes.length,sha256,
            data:bytes.subarray(partIndex*131072,(partIndex+1)*131072).toString('base64')}},runID)
      })
    }
    if(update.sessionUpdate==='usage_update'||update.sessionUpdate==='woven_usage') {
      const tokens=update.usage?.totalTokens??update.totalTokens
      if(Number.isSafeInteger(tokens)&&tokens>=0){record.runUsage??={};record.runUsage[runID]=Math.max(record.runUsage[runID]??0,tokens);save(record)}
      return
    }
    const message = record.transcript.messages.find(item => item.id === runID)
    const changedMessages = [], changedActivities = []
    if (update.sessionUpdate === 'woven_execution_binding') { record.native = copy(update.native); save(record); return }
    if (update.sessionUpdate === 'agent_message_chunk') {
      const pieces = record.transcript.messages.filter(item => item.runID === runID && item.role === 'assistant')
      const previous = pieces.map(item => item.content).join('')
      const content = update._meta?.wovenAssistantSnapshot === true ? update.content?.text ?? '' : previous + (update.content?.text ?? '')
      const contents=textParts(content)
      for (let index = 0; index < Math.max(contents.length,pieces.length); index++) {
        const id = index ? `${runID}-part-${index}` : runID
        let piece = pieces[index]
        if (!piece) { piece = {...message, id}; record.transcript.messages.push(piece) }
        const text = contents[index] ?? ''
        if (piece.content !== text) { piece.content = text; changedMessages.push(id) }
      }
      record.conversation.preview = content.slice(-256)
    } else if (update.sessionUpdate === 'agent_thought_chunk') {
      const id=runID+':'+String(update._meta?.wovenThoughtID??'thinking')
      let activity=record.transcript.activities.find(item=>item.id===id)
      if(!activity){activity={id,runID,title:'Thinking',status:'running',detail:''};record.transcript.activities.push(activity)}
      const value=update.content?.text??''
      activity.detail=textParts(update._meta?.wovenThoughtSnapshot?value:(activity.detail??'')+value)[0]
      changedActivities.push(id)
    } else if (['tool_call','tool_call_update'].includes(update.sessionUpdate)) {
      const id = runID+':'+String(update.toolCallId ?? randomUUID())
      let activity = record.transcript.activities.find(item => item.id === id)
      if (!activity) { activity = {id,runID,title:textParts(update.title ?? 'Tool')[0],status:'running'}; record.transcript.activities.push(activity) }
      activity.status = update.status === 'completed' ? 'completed' : update.status === 'failed' ? 'failed' : 'running'
      if (update.title) activity.title = textParts(update.title)[0]
      const detail = update.content?.map(item => item.content?.text ?? item.text ?? '').filter(Boolean).join('\n')
      if (detail) activity.detail = textParts(detail)[0]
      changedActivities.push(id)
    } else return
    record.conversation.updatedAt = date()
    markDirty(record, changedMessages, changedActivities)
  }
  function finish(command, error) {
    if (closed) return
    const record = getRecord(command.conversationID)
    if (record.conversation.activeRunID !== command.runID) return
    const message = record.transcript.messages.find(item => item.id === command.runID)
    const stopped=jobs.get(command.runID)?.stopped===true
    if(stopped)error=undefined
    for (const item of record.transcript.messages) if (item.runID === command.runID && item.role === 'assistant') item.status = stopped ? 'cancelled' : error ? 'failed' : 'completed'
    if (error && !message.content) message.content = 'The workspace run stopped before completion. Review its saved history before retrying.'
    for(const activity of record.transcript.activities)if(activity.runID===command.runID&&activity.status==='running')activity.status=stopped?'cancelled':error?'failed':'completed'
    delete record.conversation.activeRunID; delete record.transcript.activeRunID; record.pending = record.pending.filter(item=>item.mcpManageAccessID)
    dirty.delete(command.conversationID)
    settleGoal(record,command.runID,!error&&!stopped,record.runUsage?.[command.runID])
    transaction(() => { publish(record); receipt(command, error ? 'outcomeUnknown' : 'completed', error ? {message: message.content} : {}) })
    orchestration.settled(command.conversationID,command.runID,error,command.coordinationNotification===true)
  }
  async function tickGoals() {
    if(closed||!identity||goalsTickRunning)return
    goalsTickRunning=true
    try {
      for(const row of db.prepare('SELECT id FROM conversations').all()) {
        if(closed)return
        await serialize(row.id,async()=> {
          const record=getRecord(row.id),goal=record.goal
          if(!goal||goal.status!=='active'||record.conversation.activeRunID||record.pending?.length||goal.pendingDeliveryID)return
          if(goal.tokenBudget!=null&&goalUsageUnavailable(record)){setGoalStatus(goal,'blocked');goal.evidence='Token usage is unavailable; remove the token budget before resuming.';save(record);return}
          if(budgetReached(goal)){setGoalStatus(goal,'budget_limited');save(record);return}
          if(db.prepare("SELECT id FROM commands WHERE json_extract(body,'$.conversationID')=? AND json_extract(receipt,'$.status')='accepted'").get(row.id))return
          const uncertain=db.prepare("SELECT id FROM commands WHERE json_extract(body,'$.conversationID')=? AND json_extract(receipt,'$.status')='outcomeUnknown' AND rowid>?").get(row.id,record.goalCommandBaseline??0)
          if(uncertain){setGoalStatus(goal,'blocked');goal.evidence='An earlier command needs reconciliation before continuing.';save(record);return}
          const settings=await runtime.settings({native:record.native,runtimeKind:record.conversation.runtimeKind})
          if(closed)return
          if(['plan','plan_mode'].includes(settings.permission))return
          // Runtime settings may await while a human command enters the durable queue.
          if(db.prepare("SELECT id FROM commands WHERE json_extract(body,'$.conversationID')=? AND json_extract(receipt,'$.status')='accepted'").get(row.id))return
          if(Object.keys(record.goalRuns??{}).length&&goal.progressRevision<=goal.pendingProgressRevision)return
          const commandID=randomUUID()
          goal.pendingDeliveryID=commandID;goal.pendingProgressRevision=goal.progressRevision;save(record)
          const command={commandID,deviceID:identity.executionDeviceID,conversationID:row.id,kind:'send',text:goalPrompt(goal),goalID:goal.id}
          const initial={commandID,deviceID:command.deviceID,conversationID:row.id,status:'accepted'}
          db.prepare('INSERT INTO commands VALUES (?,?,?,?,?)').run(commandID,command.deviceID,digest(JSON.stringify(ordered(command))),JSON.stringify(command),JSON.stringify(initial))
          try { await perform(command) }
          catch(error){const latest=getRecord(row.id);if(latest.goal?.id===goal.id&&latest.goal.status==='active'){setGoalStatus(latest.goal,'blocked');latest.goal.evidence=String(error.message).slice(0,1024);delete latest.goal.pendingDeliveryID;save(latest)}receipt(command,'rejected',{message:error.message})}
        })
      }
    } finally {goalsTickRunning=false}
  }
  const goalTimer=setInterval(()=>{void tickGoals().catch(()=>{})},goalIntervalMilliseconds);goalTimer.unref()
  function events(after = 0) {
    assertIdentity(); const cursor = Number(after)
    if (!Number.isSafeInteger(cursor) || cursor < 0) throw fail(400, 'Invalid history cursor.')
    const rows = db.prepare('SELECT sequence,body FROM events WHERE sequence>? ORDER BY sequence LIMIT 201').all(cursor)
    const page = []; let bytes = 0
    for (const row of rows.slice(0,200)) {
      if (page.length && bytes + Buffer.byteLength(row.body) > 4*1024*1024) break
      page.push(row); bytes += Buffer.byteLength(row.body)
    }
    return { libraryID: identity.libraryID, cursor: page.at(-1)?.sequence ?? cursor, entries: page.map(row => JSON.parse(row.body)), hasMore: rows.length > page.length }
  }
  function importRetainedEvents(entries) {
    assertIdentity()
    if (!Array.isArray(entries) || entries.length > 200 || Buffer.byteLength(JSON.stringify(entries)) > 8*1024*1024) throw fail(400,'Import retained history in bounded batches.')
    transaction(() => {
      for (const input of entries) {
        if (!identifier(input.eventID) || !identifier(input.conversationID) || (input.workspaceID != null && input.workspaceID !== identity.id)
          || input.originSequence != null || !['conversation','transcript','nativeRecord','receipt','deletedConversation','restoredConversation'].includes(input.kind)
          || (input.runID != null && !identifier(input.runID)) || Buffer.byteLength(JSON.stringify(input)) > 1024*1024-1024) throw fail(400,'Invalid retained owner history.')
        const entry = {...copy(input),workspaceID:identity.id}
        const old = db.prepare("SELECT body FROM events WHERE json_extract(body,'$.eventID')=?").get(entry.eventID)
        if (old) { const prior=JSON.parse(old.body);delete prior.originSequence;if(JSON.stringify(ordered(prior))!==JSON.stringify(ordered(entry)))throw fail(409,'Retained event identity was reused.');continue }
        const inserted=db.prepare('INSERT INTO events(body) VALUES (?)').run('{}');entry.originSequence=Number(inserted.lastInsertRowid)
        db.prepare('UPDATE events SET body=? WHERE sequence=?').run(JSON.stringify(entry),entry.originSequence)
        if(entry.kind==='conversation' && entry.retainedExecution) {
          const proof=entry.retainedExecution, previous=db.prepare('SELECT body FROM conversations WHERE id=?').get(entry.conversationID)
          if(previous) {
            const record=JSON.parse(previous.body)
            if(record.native.sessionID!==proof.nativeSessionID || record.conversation.runtimeKind!==proof.runtimeKind)throw fail(409,'Retained history cannot replace an existing native execution identity.')
          }
          if(!previous)save({conversation:{...entry.conversation,workspaceID:identity.id,routeID:identity.id},pending:[],
            native:{sessionID:proof.nativeSessionID,channelID:entry.conversationID,workspaceID:identity.id,needsAdopt:true},
            transcript:{conversationID:entry.conversationID,messages:[],activities:[]}})
        }
        if(entry.kind==='transcript') {
          const previous=db.prepare('SELECT body FROM conversations WHERE id=?').get(entry.conversationID)
          if(previous){const record=JSON.parse(previous.body)
            for(const field of ['messages','activities','runs'])for(const item of entry.transcript?.[field]??[]) {
              record.transcript[field]??=[];const index=record.transcript[field].findIndex(old=>old.id===item.id)
              if(index<0)record.transcript[field].push(item);else record.transcript[field][index]=item
            }
            save(record)
          }
          for(const run of entry.transcript?.runs??[])if(['completed','failed','cancelled','interrupted'].includes(run.status))db.prepare('INSERT OR IGNORE INTO runs(id,commandID) VALUES (?,?)').run(run.id,'retained')
        }
      }
    })
  }
  const publisher = createClientExecutionPublisher({db,identity:descriptor,secret:publisherKey,events,
    flush:()=>{for(const id of dirty.keys())flush(id)},fetchImpl:publisherFetch,intervalMilliseconds:publisherIntervalMilliseconds})
  const allToolGroups=['notes','history','sessions','goals','timers','usage','calendar','library','browser','computer','executor']
  const toolLabels={notes:'Notes',history:'Conversation history',sessions:'Session management',timers:'Timers',usage:'Usage data',calendar:'Calendar',library:'Library',browser:'Browser Use',computer:'Computer Use',executor:'Executor'}
  const localMCPTools=['woven_sessions_create','woven_sessions_send','woven_sessions_manage','woven_sessions_release','woven_sessions_notifications','woven_sessions_receipts','woven_context','woven_goals_get','woven_goals_set','woven_goals_pause','woven_goals_resume','woven_goals_clear','woven_goals_complete','woven_goals_block','woven_goals_checkpoint',
    'woven_sessions_list','woven_sessions_status','woven_sessions_harnesses','woven_history_search','woven_history_conversations','woven_history_conversation','woven_history_message','woven_history_runs','woven_history_trace','woven_history_events','woven_history_event',
    'woven_databases_list','woven_databases_create','woven_databases_query','woven_databases_execute',...(workspaceBrowser?['woven_browser','woven_browser_cancel']:[])]
  db.exec('CREATE TABLE IF NOT EXISTS mcp_tool_receipts (caller TEXT NOT NULL, request_id TEXT NOT NULL, fingerprint TEXT NOT NULL, response TEXT, PRIMARY KEY(caller,request_id))')
  const mcp=createWorkspaceMCP({db,identity:descriptor,secret:publisherKey,endpointURL:mcpEndpointURL,
    policy:id=>getRecord(id).enabledTools??mcp.settings().enabledByDefault,localTools:localMCPTools,localCall:performMCP,fetchImpl:publisherFetch,beforeLibraryCall:()=>publisher.syncNow(),
    shouldDelegate:(scope,name,input)=>name==='woven_sessions_create'&&input.workspace!=null&&![identity.id,'current'].includes(input.workspace),
    scopedHistoryAccess:scope=>orchestration.readableConversationIDs(scope.conversationID).size>0,
    ...(mcpCatalog?{catalog:mcpCatalog}:{})})
  const orchestration=createWorkspaceMCPOrchestration({db,identity:descriptor,getRecord,command:(body,device)=>command(body,device,{internal:true}),runtime,settings:()=>mcp.settings(),runningSessions:()=>Number(db.prepare("SELECT count(*) AS count FROM conversations WHERE json_extract(body,'$.conversation.activeRunID') IS NOT NULL").get().count)+externalRunningSessions(),policy:id=>getRecord(id).enabledTools??mcp.settings().enabledByDefault,notifyApproval:setInteraction})
  async function performMCP(scope,name,input,{signal}={}) {
    const caller=name==='woven_context'||name.startsWith('woven_databases_')||name.startsWith('woven_browser')?null:getRecord(scope.conversationID),requestID=input.requestID
    let value
    if(name==='woven_context')value=null // Device-originated inputs have no borrowed Mac asset capture.
    else if(name==='woven_browser')value=await workspaceBrowser.executeMCP(scope,input,{signal})
    else if(name==='woven_browser_cancel')value=await workspaceBrowser.cancelMCP(scope,input.id)
    else if(name.startsWith('woven_sessions_')&&!['woven_sessions_list','woven_sessions_status','woven_sessions_harnesses'].includes(name))return orchestration.call(scope,name,input,{signal})
    else if(name.startsWith('woven_goals_')) {
      const action=name.slice('woven_goals_'.length)
      if(action==='get')value=caller.goal??null
      else value=await serialize(scope.conversationID,()=> {
        const record=getRecord(scope.conversationID),payload={...input};delete payload.requestID
        const mutation={[action]:payload},fingerprint=JSON.stringify(ordered(mutation)),previous=record.goalReceipts?.[requestID]
        if(previous){if(previous.fingerprint!==fingerprint)throw fail(409,'This request ID belongs to another goal change.');return previous.result}
        const wasActive=record.goal?.status==='active'
        mutateGoal(record,mutation,record.conversation.activeRunID)
        if(action==='set'||action==='resume'&&!wasActive)record.goalCommandBaseline=Number(db.prepare('SELECT coalesce(max(rowid),0) AS sequence FROM commands').get().sequence)
        const result=record.goal??null;(record.goalReceipts??={})[requestID]={fingerprint,result:copy(result)}
        save(record);return result
      })
    } else if(name.startsWith('woven_databases_')) {
      const action=name.slice('woven_databases_'.length),request={action,name:input.title,databaseID:input.databaseID,sql:input.query}
      const fingerprint=digest(JSON.stringify(ordered(request)))
      if(['create','execute'].includes(action)) {
        const previous=db.prepare('SELECT fingerprint,response FROM mcp_tool_receipts WHERE caller=? AND request_id=?').get(scope.conversationID,requestID)
        if(previous){if(previous.fingerprint!==fingerprint)throw fail(409,'This request ID belongs to another database change.');if(!previous.response)throw fail(409,'The prior database effect is uncertain. Query current data before starting a new request.');return JSON.parse(previous.response)}
        db.prepare('INSERT INTO mcp_tool_receipts VALUES(?,?,?,NULL)').run(scope.conversationID,requestID,fingerprint)
      }
      value=await databaseOperation(managedDataRoot,request)
      if(['create','execute'].includes(action)) {
        const response={success:true,result:value,requestID}
        db.prepare('UPDATE mcp_tool_receipts SET response=? WHERE caller=? AND request_id=?').run(JSON.stringify(response),scope.conversationID,requestID)
      }
    } else {
      const records=db.prepare('SELECT rowid AS sequence,body FROM conversations ORDER BY rowid').all().map(row=>({...JSON.parse(row.body),_sequence:Number(row.sequence)}))
      const journal=db.prepare('SELECT sequence,body FROM events ORDER BY sequence').all().map(row=>({...JSON.parse(row.body),originSequence:Number(row.sequence)}))
      const readableConversationIDs=(caller.enabledTools??mcp.settings().enabledByDefault).includes('history')?undefined:
        orchestration.readableConversationIDs?.(scope.conversationID)??new Set([scope.conversationID])
      value=queryWorkspaceMCPHistory(name,input,{records,events:journal,callerID:scope.conversationID,workspace:descriptor(),
        providers:name==='woven_sessions_harnesses'?await runtime.providers():[],relationship:id=>orchestration.relationship(id),readableConversationIDs})
    }
    return {success:true,result:value,requestID}
  }
  return { runningSessionCount:()=>Number(db.prepare("SELECT count(*) AS count FROM conversations WHERE json_extract(body,'$.conversation.activeRunID') IS NOT NULL").get().count), descriptor, provision, principal, revoke, adopt, importRetainedEvents, mcp, prepareTaskMCP:mcp.prepareTask,
    configurePublisher:publisher.configure, publisherStatus:publisher.status, synchronizePublisher:publisher.syncNow, saveArtifact:publisher.saveArtifact,
    resolveRetainedAssociation:publisher.resolveRetainedAssociation, hasRun:runID=>!!db.prepare('SELECT id FROM runs WHERE id=?').get(runID),
    hasActiveRuntime:kind => [...jobs.values()].some(job=>job.runtimeKind===kind),
    async cancelActive(){await runtime.cancelActive?.();await Promise.allSettled([...jobs.values()].map(job=>job.completion))},
    rememberUnlockMaterial, unlockMaterial: clientUnlockMaterial, command, receipt: getReceipt, events,
    conversations: () => db.prepare('SELECT body FROM conversations').all().map(row => JSON.parse(row.body).conversation),
    transcript: (id, before) => {
      const value = getRecord(id).transcript
      let end = {messages:value.messages.length,activities:value.activities.length}
      if (before != null) {
        try {
          if (typeof before !== 'string' || before.length > 2048) throw Error()
          end = /^\d+$/.test(before) ? {...end,messages:Number(before)} : JSON.parse(Buffer.from(before,'base64url').toString('utf8'))
        } catch { throw fail(400, 'Invalid transcript cursor.') }
      }
      if (!end || !Number.isSafeInteger(end.messages) || end.messages < 0 || end.messages > value.messages.length
        || !Number.isSafeInteger(end.activities) || end.activities < 0 || end.activities > value.activities.length) throw fail(400, 'Invalid transcript cursor.')
      const start = {messages:Math.max(0,end.messages-40),activities:Math.max(0,end.activities-40)}
      return {...value,messages:value.messages.slice(start.messages,end.messages),activities:value.activities.slice(start.activities,end.activities),
        ...(start.messages || start.activities ? {olderCursor:Buffer.from(JSON.stringify(start)).toString('base64url')} : {})}
    },
    interactions: () => db.prepare('SELECT body FROM conversations').all().flatMap(row => JSON.parse(row.body).pending),
    providers: () => runtime.providers(),
    async capabilities(id) { const record = getRecord(id); return runtime.capabilities ? runtime.capabilities({native:record.native,runtimeKind:record.conversation.runtimeKind}) : (await runtime.providers()).find(provider => provider.runtimeKind === record.conversation.runtimeKind) },
    async readWorkspace(request) {
      if (request?.session) {
        const record = getRecord(request.session.id)
        const settings = await runtime.settings({native:record.native,runtimeKind:record.conversation.runtimeKind})
        return {session:{_0:{...settings,availableTools:allToolGroups.filter(id=>id!=='goals').map(id=>({id,label:toolLabels[id]})),enabledTools:record.enabledTools??mcp.settings().enabledByDefault,conversationID:record.conversation.id,canConfigure:settings.canConfigure && !record.conversation.activeRunID,...(record.goal?{goal:record.goal}:{})}}}
      }
      if (request?.exportConversation) {
        const {id,format}=request.exportConversation, record=getRecord(id)
        if (!['markdown','text','txt','md'].includes(format)) throw fail(400,'This workspace exports conversations as text or Markdown.')
        const content=record.transcript.messages.map(message=>`## ${message.role}\n\n${message.content}`).join('\n\n')
        return {file:{_0:{name:'conversation.md',mimeType:'text/markdown',data:Buffer.from(content).toString('base64')}}}
      }
      throw fail(400,'This content belongs to the central library and is unavailable through execution transport.')
    },
    tickGoals,
    async close() { closed=true;clearInterval(goalTimer);mcp.close();await publisher.close(); clearTimeout(flushTimer); for (const id of dirty.keys()) flush(id); unlockMaterial = undefined; await runtime.close?.(); await Promise.allSettled([...jobs.values()].map(job => job.completion)); await Promise.allSettled([...queues.values()]); db.close() },
  }
}
