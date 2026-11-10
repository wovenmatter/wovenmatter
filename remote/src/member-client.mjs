import { createHash } from 'node:crypto'

// Outgoing signed requests from this Linux host to other members
// (docs/architecture/WOVEN_EVERYWHERE.md, "Membership and device keys",
// "Sessions across devices"). The library host holds this machine's member key
// and signs each request over the socket (`POST /v1/members/sign`); Node never
// reads the key. Nothing is issued or cached for the destination.

const fail = (statusCode, message, code) => Object.assign(new Error(message), { statusCode, ...(code ? { code } : {}) })

/** Tailnet HTTPS only: a signed request never leaves the private network. */
export function tailnetEndpoint(value) {
  let url
  try { url = new URL(value) } catch { return false }
  return url.protocol === 'https:' && /^[a-z0-9.-]+\.ts\.net$/i.test(url.hostname) && !url.username && !url.password && !url.search && !url.hash
}

/** `<base>/<path>`: member endpoints carry no trailing slash (`…/wovenmatter`), Linux ones may. */
export function memberURL(base, path) {
  return new URL(String(base).replace(/\/+$/, '') + '/' + String(path).replace(/^\/+/, ''))
}

/** True when the request never reached the member, so another may be tried. */
export const unreached = error => error?.code === 'member_unreachable' || error?.code === 'member_refused'

export function createMemberTransport({ library, fetchImpl = globalThis.fetch, allowEndpoint = tailnetEndpoint, timeoutMilliseconds = 30_000, now = Date.now }) {
  let peers = { at: 0, states: new Map() }

  /**
   * The member a request is addressed to, from synced records only, never
   * from what the endpoint says about itself (Swift `MemberAudience.serving`):
   * a device ID from the member list, or a registry workspace, served by its
   * execution device when that is an active member (or a Mac's own ID), else
   * by the one active Linux member advertising the endpoint's host (an older
   * Linux record names its Node server's own execution device ID).
   */
  async function audienceFor(audience) {
    const id = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value) ? value.toLowerCase() : null
    if (typeof audience === 'string') return id(audience)
    if (!audience || typeof audience !== 'object' || audience.deleted || audience.kind === 'ios') return null
    const list = ((await library.members()).members ?? []).map(item => ({ ...item, deviceID: id(item.deviceID) })).filter(item => item.deviceID)
    const active = list.filter(item => !item.revoked && item.kind !== 'ios'), execution = id(audience.executionDeviceID)
    if (execution && active.some(item => item.deviceID === execution)) return execution
    if (audience.kind === 'mac' && execution && !list.some(item => item.deviceID === execution && (item.revoked || item.kind !== 'mac'))) return execution
    let host = null
    try { host = audience.kind === 'linux' && audience.endpoint ? new URL(audience.endpoint).hostname.toLowerCase() : null } catch {}
    if (!host?.endsWith('.ts.net')) return null
    const matches = active.filter(item => item.kind === 'linux' && (item.endpoints ?? []).some(endpoint => { try { return new URL(endpoint).hostname.toLowerCase() === host } catch { return false } }))
    return matches.length === 1 ? matches[0].deviceID : null
  }

  /** `audience`: the destination member's device ID or its registry workspace (`audienceFor`). */
  async function request(url, { method = 'GET', body, headers = {}, signal, timeout = timeoutMilliseconds, audience: destination } = {}) {
    const target = url instanceof URL ? url : new URL(url)
    if (!allowEndpoint(target.origin + target.pathname)) throw fail(400, 'Members are reached only over tailnet HTTPS.', 'member_endpoint_invalid')
    const audience = await audienceFor(destination)
    if (!audience) {
      throw fail(409, 'This device has not learned that member’s identity yet. Try again once the libraries have synchronized.', 'member_audience_unknown')
    }
    const payload = body === undefined || body === null ? null : Buffer.isBuffer(body) ? body : Buffer.from(typeof body === 'string' ? body : JSON.stringify(body))
    const signed = (await library.sign({ method, target: target.pathname + target.search, audience,
      bodySHA256: createHash('sha256').update(payload ?? Buffer.alloc(0)).digest('hex') })).headers ?? {}
    const outgoing = { accept: 'application/json', ...(payload ? { 'content-type': 'application/json' } : {}), ...headers }
    for (const [name, value] of Object.entries(signed)) outgoing[name.toLowerCase()] = String(value)
    const deadline = AbortSignal.timeout(timeout), combined = signal ? AbortSignal.any([signal, deadline]) : deadline
    let response
    try { response = await fetchImpl(target, { method, headers: outgoing, body: payload ?? undefined, redirect: 'error', signal: combined }) }
    catch (error) {
      if (signal?.aborted) throw fail(499, 'The request was cancelled.')
      // A timeout or a connection lost mid-reply may follow an effect; any
      // other network failure happened before the member saw the request.
      const code = error?.cause?.code ?? error?.code
      throw deadline.aborted || code === 'UND_ERR_SOCKET'
        ? fail(504, 'This member did not answer in time. Inspect its state before retrying a change.', 'member_timeout')
        : fail(503, 'This member is not reachable right now.', 'member_unreachable')
    }
    const text = await response.text()
    if (Buffer.byteLength(text) > 8 * 1024 * 1024) throw fail(413, 'The member reply is too large.')
    let value = text
    if ((response.headers.get('content-type') ?? '').includes('json') && text) { try { value = JSON.parse(text) } catch { throw fail(502, 'The member returned invalid JSON.') } }
    return { status: response.status, body: value }
  }

  async function json(url, options) {
    const reply = await request(url, options)
    if (reply.status >= 200 && reply.status < 300) return reply.body
    const message = typeof reply.body?.message === 'string' ? reply.body.message.slice(0, 512) : typeof reply.body?.error === 'string' ? reply.body.error : 'The member refused this request.'
    // A refusal before any effect (authentication, unknown route, old version)
    // lets the caller try another member; anything else is reported as is.
    throw fail(reply.status, message, [401, 403, 404, 426].includes(reply.status) ? 'member_refused' : reply.body?.code ?? 'member_http_' + reply.status)
  }

  async function peerStates() {
    if (now() - peers.at < 10_000) return peers.states
    const states = new Map()
    try { for (const peer of (await library.syncStatus()).peers ?? []) states.set(String(peer.deviceID).toLowerCase(), peer.state) } catch {}
    peers = { at: now(), states }
    return states
  }

  /** Every current Mac member with an endpoint, online ones first. */
  async function macs() {
    const list = (await library.members()).members ?? [], states = await peerStates()
    const rank = state => state === 'online' ? 0 : state === 'offline' ? 2 : 1
    return list.filter(item => item.kind === 'mac' && !item.revoked && Array.isArray(item.endpoints) && item.endpoints.some(allowEndpoint))
      .map(item => ({ deviceID: item.deviceID.toLowerCase(), name: item.name, endpoint: item.endpoints.find(allowEndpoint), state: states.get(item.deviceID.toLowerCase()) ?? 'unknown' }))
      .sort((a, b) => rank(a.state) - rank(b.state))
  }

  /** The synced execution workspace registry (every Mac and Linux workspace). */
  async function workspaces() { return ((await library.workspaces()).workspaces ?? []).filter(item => item && !item.deleted) }

  return { request, json, macs, workspaces, audienceFor }
}

/**
 * Library-delegated Woven MCP tools the library host does not serve (timers,
 * usage, scheduled-task policy) go to any Mac member, signed with this host's
 * member key instead of one Mac's grant. The Mac accepts the Linux member for
 * conversations of the workspace it executes (`X-Woven-Workspace-ID`).
 */
export function createMemberMacDelegate({ transport, workspaceID, hasMac = () => true, log = () => {} }) {
  async function post(path, scope, body, { groups = [], signal, timeout = 115_000 } = {}) {
    const headers = { accept: 'application/json, text/event-stream', 'mcp-protocol-version': '2025-06-18', 'x-woven-protocol': '3',
      'x-woven-workspace-id': workspaceID(), 'x-woven-enabled-groups': [...groups].join(','), 'x-woven-conversation-id': scope.conversationID }
    let last = null
    for (const mac of await transport.macs()) {
      try {
        const reply = await transport.request(memberURL(mac.endpoint, path), { method: 'POST', body, headers, signal, timeout, audience: mac.deviceID })
        if (reply.status === 202) return null
        if (reply.status >= 200 && reply.status < 300) return reply.body
        // Only a refusal before any effect moves on to another Mac.
        const before = [401, 403, 404, 426, 503].includes(reply.status)
        last = fail(reply.status, typeof reply.body?.message === 'string' ? reply.body.message.slice(0, 512) : 'The Mac refused this Woven MCP request.', before ? 'member_refused' : undefined)
        if (!before) throw last
      } catch (error) {
        if (!unreached(error)) throw error
        last = error; log(`Mac ${mac.name || mac.deviceID} is unreachable for Woven MCP: ${error.message}`)
      }
    }
    throw last?.statusCode && last.statusCode < 500 && !unreached(last) ? last
      : fail(503, 'No Mac is reachable for this tool right now. Notes, calendar, history and this workspace’s own tools keep working; inspect prior effects before retrying a change.')
  }
  return {
    available: () => !!hasMac(),
    call: (scope, message, options) => post('mcp/workspace', scope, message, options),
    prepare: (scope, options) => post('mcp/workspace/prepare', scope, scope.taskProof, { ...options, timeout: 15_000 }),
  }
}
