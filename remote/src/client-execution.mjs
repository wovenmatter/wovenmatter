import { updateReasoningDetails, flushReasoningDetails } from './reasoning-details.mjs'
import { assemblePresentationFrame, textParts } from './presentation-frames.mjs'
import { toolActivity, planActivity, subagentActivity, commentaryActivity, summary, storeActivity, storedActivity, settleActivity, activityDetails } from './activity-projection.mjs'
import { createClientExecutionPublisher } from './client-execution-publisher.mjs'
import { DatabaseSync } from 'node:sqlite'
import { mkdirSync, chmodSync } from 'node:fs'
import { realpath, stat } from 'node:fs/promises'
import { mutateGoal, settleGoal, setGoalStatus, budgetReached, goalUsageUnavailable, goalPrompt, goalGuidance } from './client-goals.mjs'
import { resolve, isAbsolute, sep } from 'node:path'
import { readWorkspaceFile } from './execution-attachments.mjs'
import { createWorkspaceMCP } from './workspace-mcp.mjs'
import { createLocalLibraryTools } from './library-tools.mjs'
import { createWorkspaceMCPOrchestration } from './workspace-mcp-orchestration.mjs'
import { queryWorkspaceMCPHistory } from './workspace-mcp-history.mjs'
import { databaseOperation } from './database-catalog.mjs'
import { createHash, randomBytes, randomUUID, timingSafeEqual, createCipheriv, createDecipheriv } from 'node:crypto'
import { ordered, sha256 as digest } from './durable-json.mjs'
import { createMemberMacDelegate } from './member-client.mjs'
import { createMemberSessions } from './member-sessions.mjs'
import { createLocalSessionSource, createRemoteSessionSource, createSessionWatch, sessionState } from './session-watch.mjs'
import { maximumWaitSeconds } from './stream-protocol.mjs'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const identifier = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
const copy = structuredClone
const date = () => new Date().toISOString()
// How many recent runs a transcript keeps the timing of.
const maximumRuns = 32
// ACP `available_commands_update` as `SessionSettings.commands`.
const sessionCommands = value => (Array.isArray(value) ? value : []).flatMap(item => typeof item?.name === 'string' && item.name
  ? [{ name: item.name.slice(0, 128), ...(typeof item.description === 'string' && item.description ? { detail: item.description.slice(0, 1024) } : {}),
    ...(typeof item.input?.hint === 'string' && item.input.hint ? { argumentHint: item.input.hint.slice(0, 256) } : {}) }] : []).slice(0, 256)
// `files` are the input's attachments, listed on its first message.
function inputMessages(command,runID,files=[]) {
  return textParts(command.text).map((content,index)=>({id:index?`${command.commandID}-part-${index}`:command.commandID,
    conversationID:command.conversationID,runID,role:'user',content,createdAt:date(),...(command.agentSourceID?{agentSourceID:command.agentSourceID,isAgentAuthored:true,senderSessionTitle:command.senderSessionTitle,senderHarness:command.senderHarness,senderKind:command.senderKind??'message'}:{}),
    ...(!index&&files.length?{attachments:files.map(({id,name,mimeType,byteCount})=>({id,name,mimeType,byteCount}))}:{})}))
}
const maximumInput = 262144
// A member's choices for a new session (`LibraryCommand.sessionOptions`).
function requestedOptions(value, toolGroups) {
  if (value == null) return {}
  if (typeof value !== 'object' || Array.isArray(value)) throw fail(400, 'Invalid session options.')
  const text = (name, limit = 512) => {
    if (value[name] == null) return undefined
    if (typeof value[name] !== 'string' || !value[name] || value[name].length > limit || value[name].includes('\0')) throw fail(400, `Invalid ${name}.`)
    return value[name]
  }
  const enabledTools = value.enabledTools == null ? undefined : value.enabledTools
  if (enabledTools !== undefined && (!Array.isArray(enabledTools) || enabledTools.some(item => !toolGroups.includes(item)))) throw fail(400, 'Invalid execution tool selection.')
  return { workingDirectory: text('workingDirectory', 4096), model: text('model'), thinking: text('thinking'), permission: text('permission'),
    ...(enabledTools ? { enabledTools: [...new Set([...enabledTools, 'goals'])] } : {}) }
}
function inputExtras(command) {
  if (command.promptContext != null && (typeof command.promptContext !== 'string' || command.promptContext.length > maximumInput)) throw fail(400, 'Invalid message context.')
  if (command.noteID != null && (typeof command.noteID !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(command.noteID))) throw fail(400, 'Invalid visible note.')
  if (command.attachments != null && (!Array.isArray(command.attachments) || command.attachments.length > 8)) throw fail(400, 'Attach up to 8 files to one message.')
}

// This store is owned by the workspace service (the existing host lock fences
// competing owners). Neither a phone nor an SSH attachment owns these runs.
// `workspaceRoot` is where sessions run (default: two levels above
// `directory`). `attachments` (execution-attachments.mjs) holds uploaded
// message files; `titleGenerator(text)` names a chat from its first message
// (title-generation.mjs); `performanceLog(line)` receives command timings.
export function createClientExecution({ directory, runtime, kind = 'linux', name = 'Workspace', publisherKey, publisherFetch, publisherIntervalMilliseconds, goalIntervalMilliseconds = 1000, mcpEndpointURL = 'http://127.0.0.1:7337/mcp', managedDataRoot = resolve(directory, '../databases'), externalRunningSessions=()=>0,workspaceBrowser, library = null, members = null, onTimersChanged = () => {}, workspaceRole = () => true, extraCapabilities = () => [], deliverBot = null, sessionWatchOptions = {},
  workspaceRoot = resolve(directory, '../..'), attachments = null, titleGenerator = null, performanceLog = null }) {
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
  // Live streams (stream-server.mjs) watch changes in process, as they happen:
  // `record` when a conversation is saved, `journal` once an entry is
  // committed, `deleted` when a conversation is removed, `session` after its
  // settings were changed. Durable journaling is
  // unchanged; watchers read the stored state.
  const watchers = new Set()
  let committedJournal = null
  function notify(change) { for (const watcher of watchers) { try { watcher(change) } catch {} } }
  const transaction = action => {
    db.exec('BEGIN IMMEDIATE')
    committedJournal = []
    try {
      const value = action(); db.exec('COMMIT')
      const written = committedJournal; committedJournal = null
      for (const sequence of written) notify({ kind: 'journal', sequence })
      return value
    }
    catch (error) { committedJournal = null; db.exec('ROLLBACK'); throw error }
  }
  // An entry written outside a transaction is committed already.
  function journalWritten(sequence) { if (committedJournal) committedJournal.push(sequence); else notify({ kind: 'journal', sequence }) }
  function assertIdentity() { if (!identity) throw fail(409, 'This workspace has not been enrolled in a central library.') }
  function event(kind, conversationID, payload, runID) {
    const record = { eventID: randomUUID(), recordedAt:date(), workspaceID: identity.id, conversationID, kind, ...(runID ? {runID} : {}), ...payload }
    const result = db.prepare('INSERT INTO events(body) VALUES (?)').run('{}')
    record.originSequence = Number(result.lastInsertRowid)
    db.prepare('UPDATE events SET body=? WHERE sequence=?').run(JSON.stringify(record), record.originSequence)
    journalWritten(record.originSequence)
  }
  // `transcript` names what changed in the transcript: `null` nothing (other
  // fields of the record), `{messages, activities}` those IDs, `'all'` unknown.
  function save(record, transcript = null) {
    db.prepare('INSERT OR REPLACE INTO conversations(id,body) VALUES (?,?)').run(record.conversation.id, JSON.stringify(record))
    notify({ kind: 'record', conversationID: record.conversation.id, transcript })
  }
  function publish(record, changed, force = !changed) {
    let pendingDetails=false
    for(const activity of record.transcript.activities) {
      if(changed && !changed.activities.has(activity.id))continue
      if(!activity.projectionJSON || JSON.parse(activity.projectionJSON).kind!=='thought')continue
      const parts=flushReasoningDetails(directory,activity,{force})
      if(parts===null)pendingDetails=true
      for(const nativeRecord of parts??[])event('nativeRecord',record.conversation.id,{nativeRecord},activity.runID)
    }
    save(record, changed ? { messages: [...changed.messages], activities: [...changed.activities] } : 'all')
    event('conversation', record.conversation.id, { conversation: record.conversation }, record.conversation.activeRunID)
    const messages = changed ? record.transcript.messages.filter(item => changed.messages.has(item.id)) : record.transcript.messages
    const activities = changed ? record.transcript.activities.filter(item => changed.activities.has(item.id)) : record.transcript.activities
    // A journal transcript is an upsert batch, never a replacement of history.
    // Bound entries independently of total conversation length.
    for (let offset = 0; offset < Math.max(messages.length, activities.length, 1); offset += 4) {
      event('transcript', record.conversation.id, { transcript: { conversationID: record.conversation.id,
        messages: messages.slice(offset, offset + 4), activities: activities.slice(offset, offset + 4),
        ...(offset === 0 && record.transcript.runs?.length ? {runs: record.transcript.runs.slice(-1)} : {}),
        ...(record.transcript.activeRunID ? {activeRunID: record.transcript.activeRunID} : {}) } }, record.conversation.activeRunID)
    }
    return pendingDetails
  }
  function flush(id, force = false) {
    const changes = dirty.get(id)
    if (!changes) return
    const pending=transaction(() => publish(getRecord(id), changes, force))
    if(!pending)dirty.delete(id)
    else scheduleFlush()
  }
  function scheduleFlush() {
    if (!flushTimer) { flushTimer = setTimeout(() => { flushTimer = undefined; for (const id of dirty.keys()) flush(id) }, 500); flushTimer.unref() }
  }
  function markDirty(record, messages = [], activities = []) {
    save(record, { messages, activities })
    const changes = dirty.get(record.conversation.id) ?? {messages: new Set(), activities: new Set()}
    messages.forEach(id => changes.messages.add(id)); activities.forEach(id => changes.activities.add(id))
    dirty.set(record.conversation.id, changes)
    scheduleFlush()
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
        delete record.presentationFrames
        for(const activity of record.transcript.activities)if(activity.status==='running')activity.status='interrupted'
        for(const run of record.transcript.runs??[])if(run.status==='running'){run.status='interrupted';run.completedAt=date()}
        delete record.conversation.activeRunID; delete record.transcript.activeRunID; record.pending = record.pending.filter(item=>item.mcpManageAccessID)
        for (const message of record.transcript.messages) if (message.status === 'running') message.status = 'interrupted'
        publish(record)
      }
    }
  })
  function descriptor() {
    assertIdentity()
    const value = copy(identity)
    value.capabilities = [...new Set([...(value.capabilities ?? []), ...extraCapabilities()])]
    return value
  }
  // A new workspace's execution device is this host's member device ID (its
  // library host's identity), so other members address it from the registry
  // alone; without a library host it gets its own random ID.
  function provision(body, { executionDeviceID = null } = {}) {
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
      nextIdentity = identity ? copy(identity) : { id: body.workspaceID, libraryID: body.libraryID, ownerDeviceID: body.ownerDeviceID, executionDeviceID: identifier(executionDeviceID) ? executionDeviceID : randomUUID(),
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
  // The history the adopting Mac already shows (`transcript`: its messages
  // and activities before adoption), so this owner's transcript starts with
  // it. An unfinished entry is kept as interrupted.
  function adoptedTranscript(value, conversationID) {
    if (value == null) return { messages: [], activities: [] }
    const messages = value.messages ?? [], activities = value.activities ?? []
    if (typeof value !== 'object' || !Array.isArray(messages) || !Array.isArray(activities) || messages.length > 10000 || activities.length > 10000) throw fail(400, 'Invalid adopted history.')
    const settled = status => ['running', 'pending', 'queued'].includes(status) ? 'interrupted' : status
    const ids = new Set()
    const entity = (item, valid) => {
      if (!item || typeof item !== 'object' || typeof item.id !== 'string' || !item.id || item.id.length > 256 || ids.has(item.id) || !valid(item)) throw fail(400, 'Invalid adopted history.')
      ids.add(item.id)
      return { ...copy(item), conversationID, ...(item.status != null ? { status: settled(item.status) } : {}) }
    }
    return { messages: messages.map(item => entity(item, value => ['user', 'assistant', 'system'].includes(value.role) && typeof value.content === 'string')),
      activities: activities.map(item => entity(item, value => typeof value.title === 'string')).map(({ conversationID: _, ...item }) => item) }
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
      const seeded=adoptedTranscript(body.transcript,body.conversation.id)
      const native=await runtime.adopt({native:{sessionID:body.nativeSessionID,channelID:body.conversation.id,workspaceID:identity.id,nativeWorkingDirectory:body.nativeWorkingDirectory},runtimeKind:body.runtimeKind})
      const record={native,pending:[],conversation:{...copy(body.conversation),runtimeKind:body.runtimeKind,workspaceID:identity.id,routeID:identity.id},
        // A title the Mac already shows stays; its "New … chat" placeholder does not.
        ...(typeof body.conversation.title==='string'&&body.conversation.title.trim()&&!/^New .+ chat$/.test(body.conversation.title)?{titled:true}:{}),transcript:{conversationID:body.conversation.id,...seeded}}
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
  // A library folder's binding to a directory on this host, from this
  // machine's library copy (`woven_sessions_folders`): {workspaceID,
  // rootPath}, {workspaceID: null} for an unbound folder, or null when the
  // library cannot say (not running, or the folder has not synced here yet).
  async function folderBinding(folderID, conversationID) {
    if (!libraryTools?.available()) return null
    let after = 0
    try {
      for (let page = 0; page < 50; page++) {
        const reply = await libraryTools.call({ conversationID, groups: ['sessions'], message: { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call',
          params: { name: 'woven_sessions_folders', arguments: { requestID: randomUUID(), after, limit: 200 } } } })
        const value = reply?.result?.structuredContent?.result ?? JSON.parse(reply?.result?.content?.[0]?.text ?? 'null')
        if (reply?.result?.isError || !Array.isArray(value?.rows)) return null
        const row = value.rows.find(item => String(item.id).toLowerCase() === folderID.toLowerCase())
        if (row) {
          const workspaceID = row.execution_workspace_id ?? row.executionWorkspaceID ?? null, rootPath = row.root_path ?? row.rootPath ?? null
          return workspaceID && rootPath ? { workspaceID: String(workspaceID).toLowerCase(), rootPath: String(rootPath) } : { workspaceID: null }
        }
        if (!value.hasMore || !Number.isSafeInteger(value.nextCursor) || value.nextCursor <= after) return null
        after = value.nextCursor
      }
    } catch { return null }
    return null
  }
  async function existingDirectory(path) {
    if (typeof path !== 'string' || !isAbsolute(path) || path.includes('\0') || Buffer.byteLength(path) > 4096) throw fail(400, 'The working directory must be an absolute path.')
    try { const actual = await realpath(path); if ((await stat(actual)).isDirectory()) return actual } catch {}
    throw fail(409, 'The working directory does not exist on this workspace.')
  }
  // Where a member's new session runs, as the Mac chose for a session it
  // created over SSH (`folderWorkingDirectory`): a folder bound to this
  // workspace runs in its root, and an explicit directory must match it; a
  // folder bound to another workspace is refused. Without a binding the
  // session gets its own scratch folder, unless the caller names a directory:
  // a Mac any directory on this host, other members one inside its workspace.
  async function creationDirectory(command, options, trusted) {
    const explicit = options.workingDirectory
    const binding = command.folderID ? await folderBinding(command.folderID, command.conversationID) : null
    if (binding?.workspaceID) {
      if (binding.workspaceID !== 'remote:' + identity.id.toLowerCase()) throw fail(409, "Select a folder owned by this workspace, or All Workspaces.")
      const root = await existingDirectory(binding.rootPath)
      if (explicit && await existingDirectory(explicit) !== root) throw fail(409, "The folder's root directory is fixed.")
      return root
    }
    if (!explicit) return undefined
    const directory = await existingDirectory(explicit)
    const base = await realpath(workspaceRoot).catch(() => resolve(workspaceRoot))
    if (!trusted && directory !== base && !directory.startsWith(base + sep)) throw fail(403, 'Choose a directory inside this workspace.')
    return directory
  }
  async function applySelections(native, runtimeKind, wanted) {
    if (!wanted.model && !wanted.thinking) return
    try {
      const offered = await runtime.settings({ native, runtimeKind })
      const options = {}
      if (wanted.model && wanted.model !== offered.model && offered.models.some(item => item.id === wanted.model)) options.model = wanted.model
      if (wanted.thinking && wanted.thinking !== offered.thinking && offered.thinkingLevels.some(item => item.id === wanted.thinking)) options.thinking = wanted.thinking
      if (Object.keys(options).length) await runtime.configure({ native, runtimeKind, options })
    } catch {}
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
    // A Mac member (or this host's installer) may choose any working
    // directory, as it administers this host; other members stay inside it.
    const trusted = internal || device.administrator === true || device.memberKind === 'mac'
    const started = performance.now()
    return serialize(command.conversationID, async () => {
      try { return await perform(command, {trusted}) }
      catch (error) { return transaction(() => receipt(command, error.outcomeUnknown ? 'outcomeUnknown' : 'rejected', {message: error.message ?? 'The workspace command failed.',
        ...(typeof error.code === 'string' && /^[a-z_]{1,64}$/.test(error.code) ? {code: error.code} : {})})) }
      finally { performanceLog?.(`execution command kind=${command.kind} ms=${Math.round(performance.now() - started)}`) }
    })
  }
  async function perform(command, {trusted = true} = {}) {
    if(closed)throw fail(503,'The workspace is stopping.')
    if (command.kind === 'createSession') {
      if (db.prepare('SELECT id FROM conversations WHERE id=?').get(command.conversationID)) throw fail(409, 'Conversation already exists.')
      const options = requestedOptions(command.sessionOptions, allToolGroups)
      const providers = await runtime.providers()
      const route = command.providerID ?? command.routeID ?? command.runtimeKind ?? 'default_agent'
      const provider = providers.find(item => item.id === route)
      if (provider?.locked) throw Object.assign(fail(423, provider.unavailableReason ?? 'Pi Durable is locked.'), { code: 'default_agent_locked' })
      if (!provider?.available || provider.canStart === false || (command.runtimeKind && command.runtimeKind !== provider.runtimeKind)) throw fail(409, 'The selected agent route is unavailable or does not match its runtime.')
      const selected = provider.runtimeKind
      // The frozen intent of a session an agent creates here
      // (workspace-mcp-orchestration.mjs) is internal; members name their
      // choices in `sessionOptions`, validated above and below.
      const defaults=mcp.settings().harnessDefaults?.[selected]??{},initial=command.initialConfiguration??{}
      const enabledTools=initial.enabledTools??options.enabledTools??[...new Set([...(defaults.tools??mcp.settings().enabledByDefault),'goals'])]
      // The authenticated tool session exists before a native MCP client
      // discovers its catalog. No prompt has been submitted at this point.
      save({native:{},pending:[],enabledTools,conversation:{id:command.conversationID,runtimeKind:selected,workspaceID:identity.id,routeID:identity.id,...(command.folderID?{folderID:command.folderID}:{})},transcript:{conversationID:command.conversationID,messages:[],activities:[]}})
      let native
      try {
        const nativeWorkingDirectory=initial.nativeWorkingDirectory??await creationDirectory(command,options,trusted)
        native = await runtime.create({ runtimeKind: selected, conversationID: command.conversationID, providerID: provider.id, workspaceID: identity.id, mcpConnection: mcp.sessionConnection(command.conversationID),nativeWorkingDirectory,permission:initial.permission??options.permission??defaults.permission })
      }
      catch(error){db.prepare('DELETE FROM conversations WHERE id=?').run(command.conversationID);notify({kind:'deleted',conversationID:command.conversationID});mcp.revokeSession(command.conversationID);throw error}
      // The requested model and thinking level, else the destination's saved
      // ones, applied as the Mac applied them to a session it created over
      // SSH: one the harness does not offer, or a failure, keeps the native value.
      if(!command.initialConfiguration)await applySelections(native,selected,{model:options.model??defaults.model,thinking:options.thinking??defaults.thinking})
      // A title named at creation (a member's createSession, or the frozen intent) stays past the first message.
      const named=[command.title,initial.title].find(value=>typeof value==='string'&&value.trim())?.trim().slice(0,256)
      const record = { native, pending: [], enabledTools, ...(named?{titled:true}:{}), conversation: { id: command.conversationID, title:named??'New conversation', preview: '', runtimeKind: selected,
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
        if (action.action === 'rename' && typeof action.title === 'string' && action.title.trim()) { record.conversation.title = action.title.slice(0,256); record.titled = true }
        else if (action.action === 'pin') record.conversation.isPinned = true
        else if (action.action === 'unpin') record.conversation.isPinned = false
        else if (action.action === 'move') record.conversation.folderID = action.folderID ?? null
        else throw fail(400,'This conversation action is unavailable on the execution workspace.')
      } else throw fail(400,'This action belongs to the central library, not an execution workspace.')
      const configured=transaction(() => {publish(record);return receipt(command,'completed')})
      // A runtime may keep its settings outside the record (OpenCode): live streams read them again.
      notify({kind:'session',conversationID:command.conversationID})
      return configured
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
      inputExtras(command)
      if (typeof command.text !== 'string' || (!command.text.trim() && !command.attachments?.length) || command.text.length > maximumInput) throw fail(400, 'A message is required.')
      if(command.goalID&&(record.goal?.id!==command.goalID||record.goal?.status!=='active'||record.goal?.pendingDeliveryID!==command.commandID))throw fail(409,'The goal continuation was cancelled.')
      const files = await messageFiles(command)
      const runID = command.runID ?? randomUUID()
      if (!identifier(runID)) throw fail(400, 'Invalid run identifier.')
      if (db.prepare('SELECT id FROM runs WHERE id=?').get(runID)) throw fail(409, 'This run identifier has already been used.')
      command.runID = runID
      record.conversation.activeRunID = runID; record.transcript.activeRunID = runID
      // A title set before the first message (an agent naming the session it creates) stays.
      const untitled = !record.titled && !record.titleGenerated && (!record.transcript.messages.length || record.conversation.title === record.titleFallback)
      if (!record.transcript.messages.length && !record.titled) record.conversation.title = record.titleFallback = (command.text.trim() ? command.text : files[0]?.name ?? 'Attachment').slice(0,100)
      record.conversation.preview = command.text.slice(0,256); record.conversation.updatedAt = date()
      const visible=command.goalID?'Continuing toward the goal.':command.text
      record.transcript.messages.push(...inputMessages({...command,text:visible},runID,files))
      captureInput(record, command, runID)
      if(record.goal?.status==='active') { (record.goalRuns??={})[runID]={settled:false};delete record.goal.pendingDeliveryID }
      if(untitled&&!command.goalID&&!command.agentSourceID&&command.text.trim())scheduleTitle(command.conversationID,command.text)
      command.text=deliveryText(command)+goalGuidance
      record.transcript.messages.push({id: runID, conversationID: command.conversationID, runID, role: 'assistant', content: '', status: 'running', createdAt: date()})
      // The latest runs' timing, for the elapsed work header (`LibraryTranscriptRun`).
      record.transcript.runs = [...(record.transcript.runs ?? []), {id: runID, status: 'running', startedAt: date(), userMessageID: command.commandID, assistantMessageID: runID}].slice(-maximumRuns)
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
        command, files, publish: update => applyUpdate(command.conversationID, runID, update),
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
    inputExtras(command)
    if (typeof command.text !== 'string' || (!command.text.trim() && !command.attachments?.length) || command.text.length > maximumInput) throw fail(400, 'A message is required.')
    const files = await messageFiles(command)
    command.mcpConnection={...mcp.sessionConnection(command.conversationID),captureID:command.commandID}
    const visible = command.text
    await runtime.steer({ native: record.native, runtimeKind: record.conversation.runtimeKind, command: {...command, text: deliveryText(command)}, files })
    // Read again: streaming updates may have arrived while the steer was sent.
    const latest = getRecord(command.conversationID)
    latest.transcript.messages.push(...inputMessages({...command,text:visible},command.runID,files))
    captureInput(latest, command, command.runID)
    return transaction(() => { publish(latest); return receipt(command, 'completed') })
  }
  // The uploaded files a send or steer names, verified again now.
  async function messageFiles(command) {
    if (!command.attachments?.length) return []
    if (!attachments) throw Object.assign(fail(409, 'This workspace does not accept message attachments.'), { code: 'attachment_unavailable' })
    return attachments.resolve(command.attachments)
  }
  // What the harness receives: the message, then the sending device's
  // context (its visible notes and pages, references), as the Mac's
  // `AgentMessageInput.transportText` joined them. The transcript keeps the
  // message alone.
  function deliveryText(command) {
    const context = typeof command.promptContext === 'string' ? command.promptContext.trim() : ''
    return context ? (command.text.trim() ? command.text + '\n\n' : '') + context : command.text
  }
  // Each input's capture for `woven_context`: the note the sending device
  // showed, kept only while the session has Notes, and nothing for an
  // agent's, a goal's or a timer's input (the Mac's
  // `captureInputContext`). The latest 64 are kept.
  function captureInput(record, command, runID) {
    const notes = (record.enabledTools ?? mcp.settings().enabledByDefault).includes('notes')
    // A timer's input carries no note, so it captures none either.
    const device = !command.agentSourceID && !command.goalID
    const captures = (record.inputContexts ?? []).filter(item => item.id !== command.commandID)
    captures.push({ id: command.commandID, runID, noteID: notes && device ? command.noteID ?? null : null })
    record.inputContexts = captures.slice(-64)
  }
  // The capture `contextID` names (the harness's `_meta.wovenContextID`),
  // else the latest of the running turn, else the latest input.
  function inputContext(conversationID, contextID) {
    const record = getRecord(conversationID), captures = record.inputContexts ?? []
    const capture = contextID ? captures.find(item => item.id === contextID)
      : captures.filter(item => !record.conversation.activeRunID || item.runID === record.conversation.activeRunID).at(-1)
    if (contextID && !capture) throw fail(404, 'The native harness has not supplied a context binding for this message.')
    return capture?.noteID ?? null
  }
  // A chat named by its first message gets a generated title, once, unless
  // it is renamed first. A failure keeps the first-message title and the
  // next message tries again, as on the Mac.
  const titling = new Set()
  function scheduleTitle(conversationID, text) {
    if (!titleGenerator || titling.has(conversationID)) return
    titling.add(conversationID)
    void Promise.resolve().then(() => titleGenerator(text)).then(title => {
      if (!title || closed) return
      return serialize(conversationID, () => {
        const latest = getRecord(conversationID)
        if (latest.titled || latest.titleGenerated || latest.conversation.title !== latest.titleFallback) return
        latest.conversation.title = String(title).slice(0, 256); latest.titleGenerated = true
        transaction(() => publish(latest))
      })
    }).catch(() => {}).finally(() => titling.delete(conversationID))
  }
  function setInteraction(conversationID, runID, interaction) {
    const record = getRecord(conversationID)
    if (record.conversation.activeRunID !== runID) return
    const value = { ...interaction, conversationID, runID }
    record.pending = [...record.pending.filter(item => item.id !== value.id), value]
    save(record)
    orchestration.needsInput(conversationID,runID,interaction)
  }
  // A new activity in the run: the assistant text written since the last
  // one becomes commentary before it, so text and work interleave as they
  // happened. Every activity takes the next position in the conversation.
  function addActivity(record, runID, row, changedActivities) {
    freezeCommentary(record, runID, changedActivities)
    row.sequence = nextActivityPosition(record); row.createdAt = date()
    record.transcript.activities.push(row)
    return row
  }
  function nextActivityPosition(record) {
    record.activityPosition = (record.activityPosition ?? record.transcript.activities.length) + 1
    return record.activityPosition
  }
  function freezeCommentary(record, runID, changedActivities) {
    const content = record.transcript.messages.filter(item => item.runID === runID && item.role === 'assistant'
      && (item.id === runID || item.id.startsWith(runID + '-part-'))).map(item => item.content).join('')
    const frozen = (record.commentary ??= {})[runID] ?? 0
    const segment = content.slice(frozen)
    if (!segment.trim() || content.length < frozen) return
    record.commentary[runID] = content.length
    const id = runID + ':assistant:' + record.transcript.activities.filter(item => item.runID === runID && item.id.startsWith(runID + ':assistant:')).length
    const row = {id, runID, title: 'Commentary', status: 'completed', sequence: nextActivityPosition(record), createdAt: date()}
    row.projectionJSON = JSON.stringify(summary({...commentaryActivity(id, runID, segment), position: row.sequence}))
    record.transcript.activities.push(row)
    changedActivities.push(id)
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
    if(update.sessionUpdate==='available_commands_update') {
      record.availableCommands=sessionCommands(update.availableCommands);save(record)
      notify({kind:'session',conversationID});return
    }
    if(update.sessionUpdate==='usage_update'||update.sessionUpdate==='woven_usage') {
      const tokens=update.usage?.totalTokens??update.totalTokens
      if(Number.isSafeInteger(tokens)&&tokens>=0){record.runUsage??={};record.runUsage[runID]=Math.max(record.runUsage[runID]??0,tokens);save(record)}
      return
    }
    record.presentationFrames ??= {}
    update=assemblePresentationFrame(update,record.presentationFrames)
    if(!update){save(record);return}
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
      if(!activity)activity=addActivity(record,runID,{id,runID,title:'Thinking',status:'running',detail:''},changedActivities)
      const parts=updateReasoningDetails(directory,activity,update,randomUUID())
      transaction(() => { for(const nativeRecord of parts)event('nativeRecord',conversationID,{nativeRecord},runID) })
      changedActivities.push(id)
    } else if (['tool_call','tool_call_update'].includes(update.sessionUpdate)) {
      const id = runID+':'+String(update.toolCallId ?? randomUUID())
      let activity = record.transcript.activities.find(item => item.id === id)
      if (!activity) activity = addActivity(record, runID, {id,runID,title:textParts(update.title ?? 'Tool')[0],status:'running'}, changedActivities)
      activity.status = update.status === 'completed' ? 'completed' : update.status === 'failed' ? 'failed' : 'running'
      if (update.title) activity.title = textParts(update.title)[0]
      const detail = Array.isArray(update.content) ? update.content.map(item => item?.content?.text ?? item?.text ?? '').filter(Boolean).join('\n') : ''
      if (detail) activity.detail = textParts(detail)[0]
      const previous = storedActivity(directory, id) ?? (activity.projectionJSON ? JSON.parse(activity.projectionJSON) : undefined)
      storeActivity(directory, activity, {...toolActivity(update, previous, id), position: activity.sequence})
      if (activity.status !== 'running') {
        const parts = settleActivity(directory, activity)
        transaction(() => { for (const nativeRecord of parts) event('nativeRecord', conversationID, {nativeRecord}, runID) })
      }
      changedActivities.push(id)
    } else if (update.sessionUpdate === 'plan' || update.sessionUpdate === 'woven_subagents') {
      const plan = update.sessionUpdate === 'plan', id = runID + (plan ? ':plan' : ':subagents')
      let activity = record.transcript.activities.find(item => item.id === id)
      if (!activity) activity = addActivity(record, runID, {id, runID, title: plan ? 'Plan' : 'Subagents', status: 'running'}, changedActivities)
      const full = {...(plan ? planActivity(update, id) : subagentActivity(update, id)), position: activity.sequence}
      activity.status = full.status === 'completed' ? 'completed' : 'running'
      activity.detail = plan ? full.planEntries.map(entry => entry.content).join('\n').slice(0, 16384) : full.detail
      storeActivity(directory, activity, full)
      changedActivities.push(id)
    } else return
    record.conversation.updatedAt = date()
    markDirty(record, changedMessages, changedActivities)
  }
  function finish(command, error) {
    if (closed) return
    const record = getRecord(command.conversationID)
    if (record.conversation.activeRunID !== command.runID) return
    delete record.presentationFrames
    const message = record.transcript.messages.find(item => item.id === command.runID)
    const stopped=jobs.get(command.runID)?.stopped===true
    if(stopped)error=undefined
    for (const item of record.transcript.messages) if (item.runID === command.runID && item.role === 'assistant') item.status = stopped ? 'cancelled' : error ? 'failed' : 'completed'
    if (error && !message.content) message.content = 'The workspace run stopped before completion. Review its saved history before retrying.'
    for(const activity of record.transcript.activities)if(activity.runID===command.runID&&activity.status==='running')activity.status=stopped?'cancelled':error?'failed':'completed'
    const run=record.transcript.runs?.find(item=>item.id===command.runID)
    if(run){run.status=stopped?'cancelled':error?'failed':'completed';run.completedAt=date()}
    // Every settled activity's full projection reaches history as a record.
    const details=record.transcript.activities.filter(item=>item.runID===command.runID).flatMap(item=>settleActivity(directory,item))
    if(record.commentary)delete record.commentary[command.runID]
    delete record.conversation.activeRunID; delete record.transcript.activeRunID; record.pending = record.pending.filter(item=>item.mcpManageAccessID)
    dirty.delete(command.conversationID)
    settleGoal(record,command.runID,!error&&!stopped,record.runUsage?.[command.runID])
    transaction(() => { for(const nativeRecord of details)event('nativeRecord',command.conversationID,{nativeRecord},command.runID); publish(record); receipt(command, error ? 'outcomeUnknown' : 'completed', error ? {message: message.content} : {}) })
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
        journalWritten(entry.originSequence)
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
            save(record,'all')
          }
          for(const run of entry.transcript?.runs??[])if(['completed','failed','cancelled','interrupted'].includes(run.status))db.prepare('INSERT OR IGNORE INTO runs(id,commandID) VALUES (?,?)').run(run.id,'retained')
        }
      }
    })
  }
  // `library` is this machine's library host ({client, available}); see library-host.mjs.
  const publisher = createClientExecutionPublisher({db,identity:descriptor,secret:publisherKey,events,
    flush:()=>{for(const id of dirty.keys())flush(id)},fetchImpl:publisherFetch,intervalMilliseconds:publisherIntervalMilliseconds,
    localLibrary:library?{available:library.available,post:(path,body,headers,options)=>library.client.publisher(path,body,headers,options)}:null})
  const libraryTools=library?createLocalLibraryTools({client:library.client,available:library.available,
    callerInfo:id=>{const {conversation}=getRecord(id);return {...(conversation.title?{title:String(conversation.title).slice(0,512)}:{}),runtimeKind:conversation.runtimeKind}}}):null
  const allToolGroups=['notes','history','sessions','goals','timers','usage','calendar','library','browser','computer','executor','html']
  const toolLabels={notes:'Notes',history:'Conversation history',sessions:'Session management',timers:'Timers',usage:'Usage data',calendar:'Calendar',library:'Library',browser:'Browser Use',computer:'Computer Use',executor:'Executor'}
  const localMCPTools=['woven_sessions_create','woven_sessions_send','woven_sessions_stop','woven_sessions_respond','woven_sessions_manage','woven_sessions_release','woven_sessions_notifications','woven_sessions_receipts','woven_context','woven_goals_get','woven_goals_set','woven_goals_pause','woven_goals_resume','woven_goals_clear','woven_goals_complete','woven_goals_block','woven_goals_checkpoint',
    'woven_sessions_list','woven_sessions_status','woven_sessions_wait','woven_sessions_harnesses','woven_history_search','woven_history_conversations','woven_history_conversation','woven_history_message','woven_history_runs','woven_history_trace','woven_history_events','woven_history_event',
    'woven_databases_list','woven_databases_create','woven_databases_query','woven_databases_execute',...(workspaceBrowser?['woven_browser_use','woven_browser_use_cancel']:[])]
  db.exec('CREATE TABLE IF NOT EXISTS mcp_tool_receipts (caller TEXT NOT NULL, request_id TEXT NOT NULL, fingerprint TEXT NOT NULL, response TEXT, PRIMARY KEY(caller,request_id))')
  // `members` ({transport, deviceID, hasMac}) reaches other members with this
  // host's signed requests: sessions on any workspace, and the Mac-only tools.
  const memberDelegate=members?createMemberMacDelegate({transport:members.transport,workspaceID:()=>descriptor().id,hasMac:members.hasMac}):null
  // Bots have no conversation here: they reach this workspace through its own
  // execution API, as another member would (`local`).
  // Waits and wake-ups (session-watch.mjs): one stream per destination
  // server, signed with this host's member identity, and this workspace's own
  // changes in process.
  const enrolledID=()=>{try{return descriptor().id}catch{return null}}
  const latestRun=record=>record.conversation.activeRunID??record.transcript.messages.findLast(message=>message.runID)?.runID??null
  const sessionWatch=createSessionWatch({db,log:message=>process.stderr.write(message+'\n'),...sessionWatchOptions,
    async sourceFor(workspaceID,{interesting}) {
      if(workspaceID===enrolledID())return createLocalSessionSource({summary:id=>service.summary(id),watch:listener=>{watchers.add(listener);return()=>watchers.delete(listener)},interesting})
      if(!members)return null
      const workspace=(await members.transport.workspaces()).find(item=>item.id===workspaceID)
      if(!workspace?.endpoint||workspace.kind==='ios')return null
      return createRemoteSessionSource({endpoint:workspace.endpoint,sign:url=>members.transport.signedHeaders(url,{audience:workspace}),interesting,
        log:message=>process.stderr.write(message+'\n'),...(sessionWatchOptions.stream??{})})
    },
    caller(callerID) {
      const bot=String(callerID).match(/^woven:bot:[^:]+:([0-9a-f-]{36})$/)
      if(bot)return {kind:'bot',botID:bot[1]}
      // Called on every change of a caller with a pending wake-up: read the
      // whole record only once it is idle.
      const summary=service.summary(callerID)
      if(!summary)return null
      if(summary.conversation.activeRunID)return {kind:'conversation',idle:false}
      return {kind:'conversation',idle:true,latestRunID:latestRun(getRecord(callerID))}
    },
    // Like a coordination notification: the session it is about is its
    // source, and the turn it starts does not notify this caller's coordinator.
    deliverToConversation({callerID,commandID,text,sessionID,title,harness}) {
      const self=descriptor()
      return command({commandID,deviceID:self.executionDeviceID,kind:'send',conversationID:callerID,text,agentSourceID:sessionID,
        ...(title?{senderSessionTitle:String(title).slice(0,256)}:{}),...(harness?{senderHarness:harness}:{}),senderKind:'notification',coordinationNotification:true},
        {id:self.executionDeviceID},{internal:true})
    },
    deliverToBot:deliverBot})
  watchers.add(change=>{if(change.kind==='record'||change.kind==='deleted')sessionWatch.callerChanged(change.conversationID)})
  const memberSessions=members?createMemberSessions({transport:members.transport,identity:descriptor,deviceID:members.deviceID,db,workspaceRole,observe:sessionWatch.observe,
    local:{providers:()=>runtime.providers(),conversations:()=>service.conversations(),transcript:(id,before)=>service.transcript(id,before),
      interactions:()=>service.interactions(),capabilities:id=>service.capabilities(id),command:body=>command(body,{id:body.deviceID},{internal:true})},
    localProviders:async()=>(await runtime.providers()).filter(provider=>provider.available!==false)}):null
  // Bots manage sessions on this and every other workspace with these tools.
  const botSessionTools=memberSessions?['woven_sessions_create','woven_sessions_send','woven_sessions_status','woven_sessions_wait','woven_sessions_list','woven_sessions_stop','woven_sessions_respond','woven_sessions_harnesses']:[]
  const mcp=createWorkspaceMCP({db,identity:descriptor,secret:publisherKey,endpointURL:mcpEndpointURL,
    policy:id=>getRecord(id).enabledTools??mcp.settings().enabledByDefault,localTools:localMCPTools,localCall:performMCP,fetchImpl:publisherFetch,beforeLibraryCall:()=>publisher.syncNow(),
    scopedHistoryAccess:scope=>orchestration.readableConversationIDs(scope.conversationID).size>0,localLibrary:libraryTools,memberDelegate,onTimersChanged,botTools:botSessionTools})
  // Workspaces are named by ID; `local` is not one. Without a library host
  // this workspace can only create sessions on itself.
  async function sessionDestination(raw) {
    if(memberSessions)return memberSessions.destination(raw)
    if(raw==null||String(raw).toLowerCase()===descriptor().id.toLowerCase())return null
    if(['local','current'].includes(String(raw).toLowerCase()))throw fail(400,`"${raw}" is not a workspace name. Name the destination by ID: ${descriptor().id}.`)
    throw fail(503,'This workspace reaches other workspaces through its library host, which is not running.')
  }
  const orchestration=createWorkspaceMCPOrchestration({db,identity:descriptor,getRecord,command:(body,device)=>command(body,device,{internal:true}),runtime,settings:()=>mcp.settings(),runningSessions:()=>Number(db.prepare("SELECT count(*) AS count FROM conversations WHERE json_extract(body,'$.conversation.activeRunID') IS NOT NULL").get().count)+externalRunningSessions(),policy:id=>getRecord(id).enabledTools??mcp.settings().enabledByDefault,notifyApproval:setInteraction})
  // One operation on a session another workspace runs (or, for stop and
  // respond, one this caller coordinates here), through that workspace's
  // execution API.
  function memberOperation(client,callerID,name,input,canReadAll,signal) {
    const common={client,callerID,requestID:input.requestID,id:input.id,signal}
    if(name==='woven_sessions_status')return memberSessions.status({...common,before:input.before,canReadAll})
    if(name==='woven_sessions_send')return memberSessions.send({...common,text:input.text})
    if(name==='woven_sessions_stop')return memberSessions.stop(common)
    return memberSessions.respond({...common,interaction:input.interaction,optionID:input.optionID,answers:input.answers,cancelled:input.cancelled})
  }
  const managed=['woven_sessions_status','woven_sessions_send','woven_sessions_stop','woven_sessions_respond']
  // `woven_sessions_wait`: the same reads as woven_sessions_status, again
  // whenever a change reaches `until`, and at the timeout.
  async function sessionWait(scope,input,signal) {
    const bot=scope?.kind==='bot',callerID=bot?scope.principal:scope.conversationID,id=String(input.id).toLowerCase()
    const timeoutMilliseconds=Math.min(input.timeoutSeconds,maximumWaitSeconds)*1000
    const client=memberSessions?await memberSessions.resolve(callerID,id,input.workspace,{bot}):null
    if(client) {
      const canReadAll=bot?mcp.settings().botMCP.groups.includes('history'):(getRecord(callerID).enabledTools??mcp.settings().enabledByDefault).includes('history')
      return sessionWatch.wait({callerID,workspaceID:client.workspace.id,id,until:input.until,timeoutMilliseconds,signal,
        read:async()=>{const body=await memberSessions.status({client,callerID,id,canReadAll,signal});return {body,state:body.session.state}}})
    }
    if(bot)throw fail(503,'Bots reach sessions through this machine\'s library host, which is not running.')
    const status={id,requestID:input.requestID,...(input.workspace!=null?{workspace:input.workspace}:{})}
    return sessionWatch.wait({callerID,workspaceID:descriptor().id,id,until:input.until,timeoutMilliseconds,signal,
      read:async()=>{const reply=await performMCP(scope,'woven_sessions_status',status,{signal});const summary=service.summary(id);return {body:reply.result,state:summary?sessionState(summary):'idle'}}})
  }
  async function botSessionCall(scope,name,input,signal) {
    const callerID=scope.principal,canReadAll=mcp.settings().botMCP.groups.includes('history')
    if(name==='woven_sessions_wait')return sessionWait(scope,input,signal)
    if(name==='woven_sessions_harnesses')return memberSessions.harnesses(input)
    if(name==='woven_sessions_create')return memberSessions.create({callerID,requestID:input.requestID,workspace:await memberSessions.destination(input.workspace),runtimeKind:'default_agent',input,signal})
    if(name==='woven_sessions_list')return memberSessions.list({callerID,workspace:input.workspace,canReadAll,signal,limit:input.limit})
    if(!managed.includes(name))throw fail(400,'This session tool is not available to bots.')
    return memberOperation(await memberSessions.resolve(callerID,input.id,input.workspace,{bot:true}),callerID,name,input,canReadAll,signal)
  }
  async function performMCP(scope,name,input,{signal,contextID}={}) {
    if(scope?.kind==='bot')return {success:true,result:await botSessionCall(scope,name,input,signal),requestID:input.requestID}
    if(name==='woven_sessions_wait')return {success:true,result:await sessionWait(scope,input,signal),requestID:input.requestID}
    let client
    if(memberSessions&&managed.includes(name)&&(client=await memberSessions.resolve(scope.conversationID,input.id,input.workspace))) {
      const canReadAll=(getRecord(scope.conversationID).enabledTools??mcp.settings().enabledByDefault).includes('history')
      return {success:true,result:await memberOperation(client,scope.conversationID,name,input,canReadAll,signal),requestID:input.requestID}
    }
    if(name==='woven_sessions_list'&&memberSessions&&input.workspace!=null&&await memberSessions.destination(input.workspace)) {
      const canReadAll=(getRecord(scope.conversationID).enabledTools??mcp.settings().enabledByDefault).includes('history')
      return {success:true,result:await memberSessions.list({callerID:scope.conversationID,workspace:input.workspace,canReadAll,signal,limit:input.limit}),requestID:input.requestID}
    }
    if(name==='woven_sessions_stop'||name==='woven_sessions_respond') {
      // Here, only a session this caller created or coordinates.
      const relation=orchestration.relationship(input.id)
      if(relation.createdBy!==scope.conversationID&&relation.coordinatorID!==scope.conversationID)throw fail(403,'Stop or answer only the sessions you created or coordinate.')
      if(!memberSessions)throw fail(503,'This workspace reaches its sessions through its library host, which is not running.')
      return {success:true,result:await memberOperation(memberSessions.here(),scope.conversationID,name,input,true,signal),requestID:input.requestID}
    }
    const caller=name==='woven_context'||name.startsWith('woven_databases_')||name.startsWith('woven_browser_use')?null:getRecord(scope.conversationID),requestID=input.requestID
    let value,destination
    // A scheduled task's caller has no conversation here, so no capture.
    if(name==='woven_context')value=!scope.taskProof&&identifier(scope.conversationID)&&db.prepare('SELECT id FROM conversations WHERE id=?').get(scope.conversationID)?inputContext(scope.conversationID,contextID):null
    else if(name==='woven_browser_use')value=await workspaceBrowser.executeMCP(scope,input,{signal})
    else if(name==='woven_browser_use_cancel')value=await workspaceBrowser.cancelMCP(scope,input.id)
    else if(name==='woven_sessions_harnesses'&&memberSessions)value=await memberSessions.harnesses(input)
    else if(name==='woven_sessions_create'&&(destination=await sessionDestination(input.workspace))) {
      value=await memberSessions.create({callerID:scope.conversationID,requestID,workspace:destination,runtimeKind:caller.conversation.runtimeKind,input,signal})
    }
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
  const service = { runningSessionCount:()=>Number(db.prepare("SELECT count(*) AS count FROM conversations WHERE json_extract(body,'$.conversation.activeRunID') IS NOT NULL").get().count), descriptor, provision, principal, revoke, adopt, importRetainedEvents, mcp, prepareTaskMCP:mcp.prepareTask,
    configurePublisher:publisher.configure, publisherStatus:publisher.status, synchronizePublisher:publisher.syncNow, kickPublisher:publisher.kick, saveArtifact:publisher.saveArtifact,
    resolveRetainedAssociation:publisher.resolveRetainedAssociation, hasRun:runID=>!!db.prepare('SELECT id FROM runs WHERE id=?').get(runID),
    hasActiveRuntime:kind => [...jobs.values()].some(job=>job.runtimeKind===kind),
    async cancelActive(){await runtime.cancelActive?.();await Promise.allSettled([...jobs.values()].map(job=>job.completion))},
    rememberUnlockMaterial, unlockMaterial: clientUnlockMaterial, command, receipt: getReceipt, events,
    conversations: () => db.prepare('SELECT body FROM conversations').all().map(row => JSON.parse(row.body).conversation),
    // The latest `limit` messages and activities before `before`.
    transcript: (id, before, {limit = 40} = {}) => {
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
      const start = {messages:Math.max(0,end.messages-limit),activities:Math.max(0,end.activities-limit)}
      return {...value,messages:value.messages.slice(start.messages,end.messages),activities:value.activities.slice(start.activities,end.activities),
        ...(start.messages || start.activities ? {olderCursor:Buffer.from(JSON.stringify(start)).toString('base64url')} : {})}
    },
    // One activity's complete projection, read when its disclosure opens.
    activityDetails: (id, activityID) => {
      const row = getRecord(id).transcript.activities.find(item => item.id === activityID)
      if (!row) throw fail(404, 'This activity is not in the conversation.')
      const projectionJSON = activityDetails(directory, row)
      const { detailsRecordID, ...value } = row
      return { ...value, ...(projectionJSON ? { projectionJSON } : {}) }
    },
    interactions: () => db.prepare('SELECT body FROM conversations').all().flatMap(row => JSON.parse(row.body).pending),
    // For live streams: one conversation's summary and pending interactions
    // without parsing its transcript, and the stored record itself.
    summary: id => {
      const row = identifier(id) ? db.prepare("SELECT json_extract(body,'$.conversation') AS conversation, json_extract(body,'$.pending') AS pending FROM conversations WHERE id=?").get(id) : null
      return row ? {conversation:JSON.parse(row.conversation),pending:JSON.parse(row.pending ?? '[]')} : null
    },
    record: id => getRecord(id),
    watch(listener) { watchers.add(listener); return () => watchers.delete(listener) },
    providers: () => runtime.providers(),
    async capabilities(id) { const record = getRecord(id); return runtime.capabilities ? runtime.capabilities({native:record.native,runtimeKind:record.conversation.runtimeKind}) : (await runtime.providers()).find(provider => provider.runtimeKind === record.conversation.runtimeKind) },
    async readWorkspace(request) {
      if (request?.session) {
        const record = getRecord(request.session.id)
        const settings = await runtime.settings({native:record.native,runtimeKind:record.conversation.runtimeKind})
        const commands=record.availableCommands??settings.commands
        return {session:{_0:{...settings,...(commands?{commands}:{}),availableTools:allToolGroups.filter(id=>!['goals','html'].includes(id)).map(id=>({id,label:toolLabels[id]})),enabledTools:record.enabledTools??mcp.settings().enabledByDefault,conversationID:record.conversation.id,canConfigure:settings.canConfigure && !record.conversation.activeRunID,...(record.goal?{goal:record.goal}:{})}}}
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
    ownsConversation: id => identifier(id) && !!db.prepare('SELECT id FROM conversations WHERE id=?').get(id),
    // A message attachment a member uploads before it sends (execution-attachments.mjs).
    async uploadAttachment(value) {
      assertIdentity()
      if (!attachments) throw fail(503, 'This workspace does not accept message attachments.')
      const { path, ...stored } = await attachments.store(value)
      return stored
    },
    // An uploaded attachment's bytes (`GET v1/execution/attachments/<sha256>`).
    async readAttachment(value) {
      assertIdentity()
      if (!attachments) throw fail(404, 'This workspace holds no message attachments.')
      const { path, ...file } = await attachments.read(value)
      return file
    },
    // A harness's options before a session exists (`SessionSettings`, with
    // no conversation): native choices plus this workspace's tool groups and
    // its saved tool default for that harness.
    async sessionOptions(providerID, { workingDirectory, model } = {}) {
      assertIdentity()
      const provider = (await runtime.providers()).find(item => item.id === providerID || item.runtimeKind === providerID)
      if (!provider) throw fail(404, 'This agent is not on this workspace.')
      if (provider.locked) throw Object.assign(fail(423, provider.unavailableReason ?? 'Pi Durable is locked.'), { code: 'default_agent_locked' })
      if (provider.available === false) throw fail(409, provider.unavailableReason ?? 'This agent is not ready on this workspace.')
      if (!runtime.sessionOptions) throw fail(501, 'This workspace cannot list options without a session.')
      const directory = workingDirectory ? await existingDirectory(workingDirectory) : undefined
      const settings = await runtime.sessionOptions({ runtimeKind: provider.runtimeKind, workingDirectory: directory, model })
      const defaults = mcp.settings().harnessDefaults?.[provider.runtimeKind] ?? {}
      return { ...settings, conversationID: '', availableTools: allToolGroups.filter(id => !['goals', 'html'].includes(id)).map(id => ({ id, label: toolLabels[id] })),
        enabledTools: defaults.tools ?? mcp.settings().enabledByDefault, canConfigure: true }
    },
    // A file an agent wrote, for Library retention: inside the session's
    // working directory (or this workspace), /tmp or /mnt/data.
    async readLibraryFile({ conversationID, path }) {
      assertIdentity()
      const root = conversationID != null ? getRecord(conversationID).native?.nativeWorkingDirectory ?? workspaceRoot : workspaceRoot
      const file = await readWorkspaceFile({ path, root })
      return { name: file.name, mimeType: file.mimeType, byteCount: file.byteCount, sha256: file.sha256, data: file.data.toString('base64') }
    },
    // A timer occurrence from this machine's library (library-timers.mjs). The
    // delivery ID names the command, so a retry replays its receipt.
    async deliverTimer(sessionID, text, deliveryID) {
      if (!identifier(sessionID) || !db.prepare('SELECT id FROM conversations WHERE id=?').get(sessionID)) throw Object.assign(fail(404, 'This session does not run on this workspace.'), { code: 'not_here' })
      const value = await orchestration.deliverTimer(sessionID, text, deliveryID)
      // A receipt is final for its command ID: a refused occurrence is not retried.
      if (!['accepted', 'completed', 'queued'].includes(value.status)) throw Object.assign(fail(409, value.message ?? 'The session did not accept the timer.'), { code: 'not_here' })
      return value
    },
    // The member list changed: a stream refused with 4401 may try again.
    retryStreams:()=>sessionWatch.retry(),
    async close() { closed=true;sessionWatch.close();clearInterval(goalTimer);mcp.close();await publisher.close(); clearTimeout(flushTimer); for (const id of dirty.keys()) flush(id,true); unlockMaterial = undefined; await runtime.close?.(); await Promise.allSettled([...jobs.values()].map(job => job.completion)); await Promise.allSettled([...queues.values()]); db.close() },
  }
  // What was watched or pending before a restart (its interrupted runs are idle now).
  setImmediate(()=>{if(!closed)sessionWatch.start()})
  return service
}
