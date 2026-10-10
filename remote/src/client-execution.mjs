import { DatabaseSync } from 'node:sqlite'
import { mkdirSync, chmodSync } from 'node:fs'
import { resolve } from 'node:path'
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
    conversationID:command.conversationID,runID,role:'user',content,createdAt:date()}))
}

// This store is owned by the workspace service (the existing host lock fences
// competing owners). Neither a phone nor an SSH attachment owns these runs.
export function createClientExecution({ directory, runtime, kind = 'linux', name = 'Workspace' }) {
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
  const transaction = action => {
    db.exec('BEGIN IMMEDIATE')
    try { const value = action(); db.exec('COMMIT'); return value }
    catch (error) { db.exec('ROLLBACK'); throw error }
  }
  function assertIdentity() { if (!identity) throw fail(409, 'This workspace has not been enrolled in a central library.') }
  function event(kind, conversationID, payload, runID) {
    const record = { eventID: randomUUID(), workspaceID: identity.id, conversationID, kind, ...(runID ? {runID} : {}), ...payload }
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
      if (record.conversation.activeRunID) {
        for(const activity of record.transcript.activities)if(activity.runID===command.runID&&activity.status==='running')activity.status=stopped?'cancelled':error?'failed':'completed'
    delete record.conversation.activeRunID; delete record.transcript.activeRunID; record.pending = []
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
      if (!nextIdentity.journalDeviceIDs.includes(device.id)) nextIdentity.journalDeviceIDs.push(device.id)
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
      const native=await runtime.adopt({native:{sessionID:body.nativeSessionID,channelID:body.conversation.id,workspaceID:identity.id},runtimeKind:body.runtimeKind})
      const record={native,pending:[],conversation:{...copy(body.conversation),runtimeKind:body.runtimeKind,workspaceID:identity.id,routeID:identity.id},
        transcript:{conversationID:body.conversation.id,messages:[],activities:[]}}
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
  async function command(body, device) {
    assertIdentity()
    if (closed) throw fail(503, 'The workspace is stopping.')
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
    command.conversationID ??= command.kind === 'createSession' ? randomUUID() : command.workspaceAction?.configureSession?.id ?? command.workspaceAction?.conversation?.id
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
    if (command.kind === 'createSession') {
      if (db.prepare('SELECT id FROM conversations WHERE id=?').get(command.conversationID)) throw fail(409, 'Conversation already exists.')
      const selected = command.runtimeKind ?? 'default_agent'
      const native = await runtime.create({ runtimeKind: selected, conversationID: command.conversationID, providerID: command.providerID, workspaceID: identity.id })
      const record = { native, pending: [], conversation: { id: command.conversationID, title: 'New conversation', preview: '', runtimeKind: selected,
        ...(command.providerID ? {providerID: command.providerID} : {}), routeID: identity.id, workspaceID: identity.id, updatedAt: date() },
        transcript: { conversationID: command.conversationID, messages: [], activities: [] } }
      return transaction(() => { publish(record); return receipt(command, 'completed') })
    }
    const record = getRecord(command.conversationID)
    if (command.kind === 'workspace') {
      if (record.conversation.activeRunID) throw fail(409,'Wait for this run to finish before changing its settings.')
      if (command.workspaceAction?.configureSession) {
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
    if (['steer','stop','respond'].includes(command.kind) && (!command.runID || command.runID !== record.conversation.activeRunID)) throw fail(409, 'This command belongs to an older run.')
    if (command.kind === 'send') {
      if (record.conversation.activeRunID) throw fail(409, 'This conversation is already running.')
      if (typeof command.text !== 'string' || !command.text.trim() || command.text.length > 262144) throw fail(400, 'A message is required.')
      const runID = command.runID ?? randomUUID()
      if (!identifier(runID)) throw fail(400, 'Invalid run identifier.')
      if (db.prepare('SELECT id FROM runs WHERE id=?').get(runID)) throw fail(409, 'This run identifier has already been used.')
      command.runID = runID
      record.conversation.activeRunID = runID; record.transcript.activeRunID = runID
      record.conversation.title = record.transcript.messages.length ? record.conversation.title : command.text.slice(0,100)
      record.conversation.preview = command.text.slice(0,256); record.conversation.updatedAt = date()
      record.transcript.messages.push(...inputMessages(command,runID))
      record.transcript.messages.push({id: runID, conversationID: command.conversationID, runID, role: 'assistant', content: '', status: 'running', createdAt: date()})
      const result = transaction(() => {
        db.prepare('INSERT INTO runs VALUES (?,?)').run(runID, command.commandID)
        db.prepare('UPDATE commands SET body=? WHERE id=?').run(JSON.stringify(command), command.commandID)
        publish(record); return receipt(command, 'accepted')
      })
      const job = { command, runtimeKind:record.conversation.runtimeKind, stopped: false }
      jobs.set(runID, job)
      job.completion = Promise.resolve().then(() => runtime.run({ native: record.native, runtimeKind: record.conversation.runtimeKind,
        command, publish: update => applyUpdate(command.conversationID, runID, update),
        interaction: value => setInteraction(command.conversationID, runID, value) }))
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
      const job=jobs.get(command.runID)
      if(job)job.stopped=true
      try { await runtime.stop({ native: record.native, runtimeKind: record.conversation.runtimeKind, command }) }
      catch(error){if(job)job.stopped=false;throw error}
      return transaction(() => receipt(command, 'completed'))
    }
    if (typeof command.text !== 'string' || !command.text.trim() || command.text.length > 262144) throw fail(400, 'A message is required.')
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
      const id=String(update._meta?.wovenThoughtID??runID+':thinking')
      let activity=record.transcript.activities.find(item=>item.id===id)
      if(!activity){activity={id,runID,title:'Thinking',status:'running',detail:''};record.transcript.activities.push(activity)}
      const value=update.content?.text??''
      activity.detail=textParts(update._meta?.wovenThoughtSnapshot?value:(activity.detail??'')+value)[0]
      changedActivities.push(id)
    } else if (['tool_call','tool_call_update'].includes(update.sessionUpdate)) {
      const id = String(update.toolCallId ?? randomUUID())
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
    delete record.conversation.activeRunID; delete record.transcript.activeRunID; record.pending = []
    dirty.delete(command.conversationID)
    transaction(() => { publish(record); receipt(command, error ? 'outcomeUnknown' : 'completed', error ? {message: message.content} : {}) })
  }
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
  return { descriptor, provision, principal, revoke, adopt,
    hasActiveRuntime:kind => [...jobs.values()].some(job=>job.runtimeKind===kind),
    async cancelActive(){await runtime.cancelActive?.();await Promise.allSettled([...jobs.values()].map(job=>job.completion))},
    rememberUnlockMaterial, unlockMaterial: clientUnlockMaterial, command, receipt: getReceipt, events,
    conversations: () => db.prepare('SELECT body FROM conversations').all().map(row => JSON.parse(row.body).conversation),
    transcript: (id, before) => {
      const value = getRecord(id).transcript
      const offset = before == null ? value.messages.length : Number(before)
      if (!Number.isSafeInteger(offset) || offset < 0 || offset > value.messages.length) throw fail(400, 'Invalid transcript cursor.')
      const start = Math.max(0, offset - 40)
      return {...value,messages:value.messages.slice(start,offset),activities:value.activities.slice(-40),...(start ? {olderCursor:String(start)} : {})}
    },
    interactions: () => db.prepare('SELECT body FROM conversations').all().flatMap(row => JSON.parse(row.body).pending),
    providers: () => runtime.providers(),
    async capabilities(id) { const record = getRecord(id); return runtime.capabilities ? runtime.capabilities({native:record.native,runtimeKind:record.conversation.runtimeKind}) : (await runtime.providers()).find(provider => provider.runtimeKind === record.conversation.runtimeKind) },
    async readWorkspace(request) {
      if (request?.session) {
        const record = getRecord(request.session.id)
        const settings = await runtime.settings({native:record.native,runtimeKind:record.conversation.runtimeKind})
        return {session:{_0:{...settings,conversationID:record.conversation.id,canConfigure:settings.canConfigure && !record.conversation.activeRunID}}}
      }
      if (request?.exportConversation) {
        const {id,format}=request.exportConversation, record=getRecord(id)
        if (!['markdown','text','txt','md'].includes(format)) throw fail(400,'This workspace exports conversations as text or Markdown.')
        const content=record.transcript.messages.map(message=>`## ${message.role}\n\n${message.content}`).join('\n\n')
        return {file:{_0:{name:'conversation.md',mimeType:'text/markdown',data:Buffer.from(content).toString('base64')}}}
      }
      throw fail(400,'This content belongs to the central library and is unavailable through execution transport.')
    },
    async close() { clearTimeout(flushTimer); for (const id of dirty.keys()) flush(id); closed = true; unlockMaterial = undefined; await runtime.close?.(); await Promise.allSettled([...jobs.values()].map(job => job.completion)); db.close() },
  }
}
