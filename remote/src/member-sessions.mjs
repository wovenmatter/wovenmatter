import { createHash } from 'node:crypto'
import { memberURL, unreached } from './member-client.mjs'

// Sessions on other workspaces (docs/architecture/WOVEN_EVERYWHERE.md,
// "Sessions across devices"). A Linux host's agents and bots create and manage
// sessions on any Mac or Linux workspace in the synced registry by calling that
// workspace's execution API directly with a signed member request, so it works
// with every other Mac offline. Workspaces are named by ID (or an unambiguous
// name); `local` is not a destination, and the iPhone never is.
//
// Every session a caller creates here is remembered (`member_sessions`), so
// later calls name it by ID alone. A bot has no conversation of its own, so it
// reaches this workspace through the same execution commands (`local`).

const fail = (statusCode, message, code) => Object.assign(new Error(message), { statusCode, ...(code ? { code } : {}) })
const stableID = value => {
  const h = createHash('sha256').update('woven-member-session-v1\0' + value).digest('hex')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`
}
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
const label = workspace => `${workspace.name} (${workspace.id}, ${workspace.kind === 'mac' ? 'Mac' : 'Linux'})`
const clip = (value, size) => typeof value === 'string' && value.length > size ? value.slice(0, size) + '…' : value
const own = Symbol('this workspace')

/**
 * `local` ({providers, conversations, transcript, interactions, capabilities,
 * command}) is this workspace's own execution API, used for bots, which have
 * no conversation to coordinate from. `db` keeps the sessions each caller created.
 */
export function createMemberSessions({ transport, identity, deviceID, localProviders, db = null, local = null, probeTimeout = 5000, workspaceRole = () => true }) {
  db?.exec('CREATE TABLE IF NOT EXISTS member_sessions (id TEXT PRIMARY KEY, caller TEXT NOT NULL, workspace TEXT NOT NULL, created_at TEXT NOT NULL)')
  const headers = workspace => ({ 'x-woven-protocol': '3', 'x-woven-library': workspace.libraryID, 'x-woven-workspace': workspace.id, 'x-woven-device': deviceID() })
  // A bots-only host has no workspace of its own, and a workspace host has
  // none until its Mac enrolls it (`identity` throws until then); its bots
  // still reach every other workspace.
  const enrolled = () => { try { return identity() } catch { return null } }
  const targets = async () => { const self = enrolled(); return (await transport.workspaces()).filter(item => item.kind !== 'ios' && item.id !== self?.id) }

  async function choices() {
    const self = enrolled()
    try { return [...(self ? [self] : []), ...await targets()].map(label).join('; ') || 'none is known here' } catch { return self ? label(self) : 'none is known here' }
  }

  /** `null` for this workspace; otherwise the destination's registry entry. */
  async function destination(raw) {
    if (raw == null) return null
    const value = String(raw).trim(), self = enrolled()
    if (!value) throw fail(400, 'Name the destination workspace by ID.')
    if (self && value.toLowerCase() === self.id.toLowerCase()) return null
    if (['local', 'current'].includes(value.toLowerCase())) throw fail(400, `"${value}" is not a workspace name. Name the destination by ID: ${await choices()}.`)
    const all = (await transport.workspaces()).filter(item => item.id !== self?.id)
    const byID = all.find(item => item.id.toLowerCase() === value.toLowerCase())
    const named = byID ? [byID] : all.filter(item => String(item.name).toLowerCase() === value.toLowerCase())
    if (self && !byID && String(self.name ?? '').toLowerCase() === value.toLowerCase() && !named.length) return null
    if (named.length > 1) throw fail(400, `More than one workspace is named "${value}". Name it by ID: ${named.map(label).join('; ')}.`)
    const workspace = named[0]
    if (!workspace) throw fail(404, `No workspace "${value}" is known here. Name one by ID: ${await choices()}.`)
    if (workspace.kind === 'ios') throw fail(400, 'An iPhone runs only its own Quick Chats; choose a Mac or Linux workspace.')
    if (!workspace.endpoint) throw fail(409, `${workspace.name} has not shared its address with this library yet.`)
    return workspace
  }

  // One execution API: another member's over signed HTTPS, or this workspace's own.
  function api(workspace) {
    if (workspace === own) {
      if (!local) throw fail(503, 'This workspace cannot run sessions for this caller.')
      const self = enrolled()
      if (!self) throw fail(409, workspaceRole()
        ? 'This machine\'s workspace is not enrolled yet: the Mac that manages it enrolls it as soon as it reaches this machine. Until then, name another workspace by ID; woven_sessions_harnesses lists them.'
        : 'This machine runs only bots and has no workspace of its own. Name another workspace by ID; woven_sessions_harnesses lists them.')
      return { ...local, workspace: { ...self, kind: self.kind ?? 'linux' },
        command: body => local.command({ ...body, deviceID: self.executionDeviceID, libraryID: self.libraryID, workspaceID: self.id }) }
    }
    const get = (path, signal, timeout) => transport.json(memberURL(workspace.endpoint, path), { headers: headers(workspace), signal, audience: workspace, ...(timeout ? { timeout } : {}) })
    return {
      workspace,
      providers: (signal, timeout) => get('v1/execution/providers', signal, timeout),
      conversations: signal => get('v1/execution/conversations', signal),
      transcript: (id, before, signal) => get(`v1/execution/conversations/${id}/transcript` + (before ? '?before=' + encodeURIComponent(before) : ''), signal),
      interactions: signal => get('v1/execution/interactions', signal),
      capabilities: (id, signal) => get(`v1/execution/conversations/${id}/capabilities`, signal),
      command: (body, signal) => transport.json(memberURL(workspace.endpoint, 'v1/execution/commands'), { method: 'POST', headers: headers(workspace), signal, audience: workspace,
        body: { ...body, deviceID: deviceID(), libraryID: workspace.libraryID, workspaceID: workspace.id } }),
    }
  }

  async function command(client, body, signal) {
    const receipt = await client.command(body, signal)
    if (receipt?.commandID !== body.commandID) throw fail(502, 'The workspace returned another command’s receipt.')
    return receipt
  }
  const describe = (client, conversation) => ({ id: conversation.id, title: conversation.title ?? null, harness: conversation.runtimeKind ?? null,
    workspace: client.workspace.id, workspaceName: client.workspace.name, workspaceKind: client.workspace.kind,
    state: conversation.activeRunID ? 'running' : 'idle', ...(conversation.activeRunID ? { runID: conversation.activeRunID } : {}),
    ...(conversation.updatedAt ? { updatedAt: conversation.updatedAt } : {}), ...(conversation.preview ? { preview: clip(conversation.preview, 512) } : {}) })

  /**
   * Creates the session on `workspace` with that workspace's saved defaults,
   * renames it, and sends the first instruction. Command IDs derive from the
   * caller and request ID, so a retry replays the destination's receipts.
   * `workspace` null is this workspace (bots only).
   */
  async function create({ callerID, requestID, workspace, runtimeKind, input, signal }) {
    const client = api(workspace ?? own)
    const base = [callerID, requestID, client.workspace.id].join(':'), conversationID = stableID(base + ':conversation')
    const providers = await client.providers(signal)
    const kind = input.harness ?? runtimeKind
    const provider = Array.isArray(providers) ? providers.find(item => item.runtimeKind === kind && item.available !== false && item.canStart !== false) : null
    if (!provider) throw fail(409, `${kind} is not ready on ${client.workspace.name}. Call woven_sessions_harnesses to see what it offers.`)
    const folder = input.folder && !['all', 'ungrouped'].includes(input.folder) ? { folderID: input.folder } : {}
    const title = typeof input.title === 'string' && input.title.trim() ? { title: input.title.trim().slice(0, 256) } : {}
    const created = await command(client, { commandID: stableID(base + ':create'), kind: 'createSession', conversationID, providerID: provider.id, runtimeKind: kind, ...title, ...folder }, signal)
    if (!['accepted', 'completed'].includes(created.status)) throw fail(409, created.message ?? `${client.workspace.name} could not create the session.`)
    db?.prepare('INSERT OR IGNORE INTO member_sessions VALUES (?,?,?,?)').run(conversationID, callerID, client.workspace.id, new Date().toISOString())
    // A failed rename leaves a working session; the first message still goes.
    await command(client, { commandID: stableID(base + ':title'), kind: 'workspace', conversationID,
      workspaceAction: { conversation: { id: conversationID, action: 'rename', title: String(input.title).slice(0, 256) } } }, signal).catch(() => null)
    const sent = await command(client, { commandID: stableID(base + ':send'), kind: 'send', conversationID, text: input.text }, signal)
    return { session: { id: conversationID, title: input.title, harness: kind, workspace: client.workspace.id, workspaceName: client.workspace.name, workspaceKind: client.workspace.kind },
      independent: true, receipt: sent,
      note: 'Manage it with woven_sessions_status (state, pending questions and recent transcript), woven_sessions_send, woven_sessions_stop and woven_sessions_respond; it is not coordinated, so poll its status.' }
  }

  /**
   * Which workspace runs session `id` for this caller: the one `workspaceRaw`
   * names, or the one this caller created it on. `null` when it is neither a
   * member session nor named, so the caller's own workspace handles it.
   */
  async function resolve(callerID, id, workspaceRaw, { bot = false } = {}) {
    if (workspaceRaw != null) {
      const named = await destination(workspaceRaw)
      return named ? api(named) : bot ? api(own) : null
    }
    const row = uuid(id) ? db?.prepare('SELECT workspace FROM member_sessions WHERE id=?').get(String(id).toLowerCase()) : null
    if (!row) return bot ? api(own) : null
    if (row.workspace === enrolled()?.id) return bot ? api(own) : null
    const workspace = (await transport.workspaces()).find(item => item.id === row.workspace)
    if (!workspace?.endpoint) throw fail(409, 'The workspace that runs this session is no longer known here.')
    return api(workspace)
  }
  const created = (callerID, id) => !!db?.prepare('SELECT 1 FROM member_sessions WHERE id=? AND caller=?').get(String(id).toLowerCase(), callerID)

  async function conversation(client, id, signal) {
    if (!uuid(id)) throw fail(400, 'Name the session by its ID.')
    const list = await client.conversations(signal)
    const found = (Array.isArray(list) ? list : []).find(item => item?.id?.toLowerCase() === id.toLowerCase())
    if (!found) throw fail(404, `No session ${id} runs on ${client.workspace.name}.`)
    return found
  }
  function readable(callerID, id, canReadAll) {
    if (!canReadAll && !created(callerID, id)) throw fail(403, 'Read only the sessions you created, or enable Conversation history.')
  }

  /** State, pending questions and approvals, and a window of recent transcript. */
  async function status({ client, callerID, id, before, canReadAll, signal }) {
    readable(callerID, id, canReadAll)
    const found = await conversation(client, id, signal)
    const [transcript, pending] = await Promise.all([client.transcript(found.id, before, signal), Promise.resolve().then(() => client.interactions(signal)).catch(() => [])])
    const messages = (transcript?.messages ?? []).slice(-20).map(message => ({ id: message.id, role: message.role, ...(message.runID ? { runID: message.runID } : {}),
      ...(message.status ? { status: message.status } : {}), createdAt: message.createdAt, content: clip(String(message.content ?? ''), 4000) }))
    const questions = (Array.isArray(pending) ? pending : []).filter(item => item?.conversationID?.toLowerCase() === found.id.toLowerCase())
      .map(item => ({ id: item.id, kind: item.kind, title: item.title, ...(item.detail ? { detail: clip(item.detail, 2000) } : {}), runID: item.runID,
        options: item.options ?? [], questions: item.questions ?? [] }))
    const session = describe(client, found)
    if (questions.length) session.state = 'needsInput'
    return { session, pending: questions, transcript: { messages, ...(transcript?.olderCursor ? { before: transcript.olderCursor } : {}) },
      ...(questions.some(item => item.kind === 'approval') ? { note: 'Permission approvals belong to the user unless this workspace’s user granted full access; answer questions with woven_sessions_respond.' } : {}) }
  }

  /** Sends to an idle session, or steers a running one when its harness can. */
  async function send({ client, callerID, requestID, id, text, signal }) {
    const found = await conversation(client, id, signal), base = [callerID, requestID, client.workspace.id, found.id].join(':')
    if (found.activeRunID) {
      const capabilities = await Promise.resolve().then(() => client.capabilities(found.id, signal)).catch(() => null)
      if (capabilities?.canSteer !== true) throw fail(409, `${found.title ?? 'The session'} is running and its harness cannot take a message mid-turn. Check woven_sessions_status and send when it is idle.`)
      return { session: describe(client, found), receipt: await command(client, { commandID: stableID(base + ':steer'), kind: 'steer', conversationID: found.id, runID: found.activeRunID, text }, signal) }
    }
    return { session: describe(client, found), receipt: await command(client, { commandID: stableID(base + ':send'), kind: 'send', conversationID: found.id, text }, signal) }
  }

  async function stop({ client, callerID, requestID, id, signal }) {
    const found = await conversation(client, id, signal)
    if (!found.activeRunID) return { session: describe(client, found), stopped: false, message: 'The session is not running.' }
    const receipt = await command(client, { commandID: stableID([callerID, requestID, client.workspace.id, found.id, 'stop'].join(':')), kind: 'stop', conversationID: found.id, runID: found.activeRunID }, signal)
    return { session: describe(client, found), stopped: ['accepted', 'completed'].includes(receipt.status), receipt }
  }

  /** Answers one pending question (or approval) of the session's current run. */
  async function respond({ client, callerID, requestID, id, interaction, optionID, answers, cancelled, signal }) {
    const found = await conversation(client, id, signal)
    const pending = (await client.interactions(signal)).find(item => item?.id === interaction && item.conversationID?.toLowerCase() === found.id.toLowerCase())
    if (!pending) throw fail(409, 'That question is no longer pending. Read woven_sessions_status again.')
    const response = { optionID: optionID ?? null, answers: answers ?? {}, cancelled: cancelled === true }
    if (!response.cancelled && pending.kind === 'approval' && !(pending.options ?? []).some(option => option.id === optionID)) throw fail(400, 'Choose one of the offered options.')
    const receipt = await command(client, { commandID: stableID([callerID, requestID, client.workspace.id, found.id, 'respond'].join(':')), kind: 'respond',
      conversationID: found.id, runID: pending.runID, interactionID: pending.id, response }, signal)
    return { session: describe(client, found), receipt }
  }

  /**
   * Sessions on one workspace (`workspace`), or every session this caller
   * created on other workspaces, each with its live state.
   */
  async function list({ callerID, workspace: raw, canReadAll, signal, limit = 100 }) {
    if (raw != null) {
      const named = await destination(raw), client = api(named ?? own)
      const rows = (await client.conversations(signal)).filter(item => canReadAll || created(callerID, item.id))
      return { rows: rows.slice(0, limit).map(item => describe(client, item)), hasMore: rows.length > limit }
    }
    const mine = db?.prepare('SELECT id, workspace FROM member_sessions WHERE caller=? ORDER BY created_at DESC').all(callerID) ?? []
    const byWorkspace = new Map()
    for (const row of mine) byWorkspace.set(row.workspace, [...byWorkspace.get(row.workspace) ?? [], row.id])
    const registry = await transport.workspaces().catch(() => [])
    const rows = []
    for (const [workspaceID, ids] of byWorkspace) {
      const entry = workspaceID === enrolled()?.id ? own : registry.find(item => item.id === workspaceID)
      if (!entry || (entry !== own && !entry.endpoint) || (entry === own && !local)) { rows.push(...ids.map(id => ({ id, workspace: workspaceID, online: false }))); continue }
      const client = api(entry)
      try {
        const live = new Map((await client.conversations(signal)).map(item => [item.id, item]))
        rows.push(...ids.map(id => live.has(id) ? describe(client, live.get(id)) : { id, workspace: workspaceID, workspaceName: client.workspace.name, state: 'missing' }))
      } catch (error) {
        rows.push(...ids.map(id => ({ id, workspace: workspaceID, workspaceName: client.workspace.name, online: false, error: unreached(error) ? 'unreachable' : error.message })))
      }
    }
    return { rows: rows.slice(0, limit), hasMore: rows.length > limit }
  }

  /** Harnesses on this workspace, then every other Mac and Linux workspace that answers. */
  async function harnesses(input = {}) {
    const self = enrolled(), rows = []
    if (self) for (const provider of await localProviders()) rows.push({ ...provider, harness: provider.runtimeKind, workspace: self.id, workspaceName: self.name, workspaceKind: self.kind ?? 'linux', online: true })
    let others = []
    try { others = await targets() } catch {}
    const replies = await Promise.all(others.filter(item => item.endpoint).map(async workspace => {
      try {
        const list = await api(workspace).providers(undefined, probeTimeout)
        return (Array.isArray(list) ? list : []).map(provider => ({ id: provider.id, harness: provider.runtimeKind, runtimeKind: provider.runtimeKind, name: provider.name,
          ready: provider.available !== false && provider.canStart !== false, workspace: workspace.id, workspaceName: workspace.name, workspaceKind: workspace.kind, online: true }))
      } catch (error) {
        return [{ workspace: workspace.id, workspaceName: workspace.name, workspaceKind: workspace.kind, online: false, error: unreached(error) ? 'unreachable' : error.message }]
      }
    }))
    rows.push(...replies.flat())
    const offset = input.offset ?? 0, limit = input.limit ?? 100, page = rows.slice(offset, offset + limit)
    return { rows: page.map((row, index) => ({ ...row, sequence: offset + index + 1 })), hasMore: offset + page.length < rows.length, nextOffset: offset + page.length }
  }

  return { destination, create, resolve, status, send, stop, respond, list, harnesses, here: () => api(own) }
}
