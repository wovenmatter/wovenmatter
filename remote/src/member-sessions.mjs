import { createHash } from 'node:crypto'
import { memberURL, unreached } from './member-client.mjs'

// Sessions on other workspaces (docs/architecture/WOVEN_EVERYWHERE.md,
// "Sessions across devices"). A Linux host's agents create sessions on any
// Mac or Linux workspace in the synced registry by calling that workspace's
// execution API directly with a signed member request, so it works with every
// other Mac offline. Workspaces are named by ID (or an unambiguous name);
// `local` is not a destination, and the iPhone never is.

const fail = (statusCode, message, code) => Object.assign(new Error(message), { statusCode, ...(code ? { code } : {}) })
const stableID = value => {
  const h = createHash('sha256').update('woven-member-session-v1\0' + value).digest('hex')
  return `${h.slice(0, 8)}-${h.slice(8, 12)}-5${h.slice(13, 16)}-a${h.slice(17, 20)}-${h.slice(20, 32)}`
}
const label = workspace => `${workspace.name} (${workspace.id}, ${workspace.kind === 'mac' ? 'Mac' : 'Linux'})`

export function createMemberSessions({ transport, identity, deviceID, localProviders, probeTimeout = 5000 }) {
  const headers = workspace => ({ 'x-woven-protocol': '3', 'x-woven-library': workspace.libraryID, 'x-woven-workspace': workspace.id, 'x-woven-device': deviceID() })
  const targets = async () => (await transport.workspaces()).filter(item => item.kind !== 'ios' && item.id !== identity().id)

  async function choices() {
    try { return [identity(), ...await targets()].map(label).join('; ') } catch { return label(identity()) }
  }

  /** `null` for this workspace; otherwise the destination's registry entry. */
  async function destination(raw) {
    if (raw == null) return null
    const value = String(raw).trim(), own = identity()
    if (!value) throw fail(400, 'Name the destination workspace by ID.')
    if (value.toLowerCase() === own.id.toLowerCase()) return null
    if (['local', 'current'].includes(value.toLowerCase())) throw fail(400, `"${value}" is not a workspace name. Name the destination by ID: ${await choices()}.`)
    const all = (await transport.workspaces()).filter(item => item.id !== own.id)
    const byID = all.find(item => item.id.toLowerCase() === value.toLowerCase())
    const named = byID ? [byID] : all.filter(item => String(item.name).toLowerCase() === value.toLowerCase())
    if (!byID && String(own.name ?? '').toLowerCase() === value.toLowerCase() && !named.length) return null
    if (named.length > 1) throw fail(400, `More than one workspace is named "${value}". Name it by ID: ${named.map(label).join('; ')}.`)
    const workspace = named[0]
    if (!workspace) throw fail(404, `No workspace "${value}" is known here. Name one by ID: ${await choices()}.`)
    if (workspace.kind === 'ios') throw fail(400, 'An iPhone runs only its own Quick Chats; choose a Mac or Linux workspace.')
    if (!workspace.endpoint) throw fail(409, `${workspace.name} has not shared its address with this library yet.`)
    return workspace
  }

  async function command(workspace, body, signal) {
    const receipt = await transport.json(memberURL(workspace.endpoint, 'v1/execution/commands'), { method: 'POST', headers: headers(workspace), signal, audience: workspace,
      body: { ...body, deviceID: deviceID(), libraryID: workspace.libraryID, workspaceID: workspace.id } })
    if (receipt?.commandID !== body.commandID) throw fail(502, 'The workspace returned another command’s receipt.')
    return receipt
  }

  /**
   * Creates the session on `workspace` with that workspace's saved defaults,
   * renames it, and sends the first instruction. Command IDs derive from the
   * caller and request ID, so a retry replays the destination's receipts.
   */
  async function create({ callerID, requestID, workspace, runtimeKind, input, signal }) {
    const base = [callerID, requestID, workspace.id].join(':'), conversationID = stableID(base + ':conversation')
    const providers = await transport.json(memberURL(workspace.endpoint, 'v1/execution/providers'), { headers: headers(workspace), signal, audience: workspace })
    const kind = input.harness ?? runtimeKind
    const provider = Array.isArray(providers) ? providers.find(item => item.runtimeKind === kind && item.available !== false && item.canStart !== false) : null
    if (!provider) throw fail(409, `${kind} is not ready on ${workspace.name}. Call woven_sessions_harnesses to see what it offers.`)
    const folder = input.folder && !['all', 'ungrouped'].includes(input.folder) ? { folderID: input.folder } : {}
    const created = await command(workspace, { commandID: stableID(base + ':create'), kind: 'createSession', conversationID, providerID: provider.id, runtimeKind: kind, ...folder }, signal)
    if (!['accepted', 'completed'].includes(created.status)) throw fail(409, created.message ?? `${workspace.name} could not create the session.`)
    // A failed rename leaves a working session; the first message still goes.
    await command(workspace, { commandID: stableID(base + ':title'), kind: 'workspace', conversationID,
      workspaceAction: { conversation: { id: conversationID, action: 'rename', title: String(input.title).slice(0, 256) } } }, signal).catch(() => null)
    const sent = await command(workspace, { commandID: stableID(base + ':send'), kind: 'send', conversationID, text: input.text }, signal)
    return { session: { id: conversationID, title: input.title, harness: kind, workspace: workspace.id, workspaceName: workspace.name, workspaceKind: workspace.kind },
      independent: true, receipt: sent,
      note: 'This session runs on another workspace and is not coordinated by the caller. Read its progress with woven_history_conversation once it syncs.' }
  }

  /** Harnesses on this workspace, then every other Mac and Linux workspace that answers. */
  async function harnesses(input = {}) {
    const own = identity(), rows = []
    for (const provider of await localProviders()) rows.push({ ...provider, harness: provider.runtimeKind, workspace: own.id, workspaceName: own.name, workspaceKind: own.kind ?? 'linux', online: true })
    let others = []
    try { others = await targets() } catch {}
    const replies = await Promise.all(others.filter(item => item.endpoint).map(async workspace => {
      try {
        const list = await transport.json(memberURL(workspace.endpoint, 'v1/execution/providers'), { headers: headers(workspace), timeout: probeTimeout, audience: workspace })
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

  return { destination, create, harnesses }
}
