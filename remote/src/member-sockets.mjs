import { hasMemberSignature } from './member-auth.mjs'

// Member-signed WebSocket upgrades (docs/architecture/WOVEN_EVERYWHERE.md,
// "Streaming", "Endpoint and authentication"): the signed `GET` is the whole
// credential, and every open socket is kept by its member's device ID so a
// removal closes it.

export const memberRemovedCloseCode = 4401
// What `/v1/execution/*` accepts: every kind of member.
export const executionMemberKinds = Object.freeze(['mac', 'ios', 'linux'])

/**
 * Checks one upgrade request. Only a member signature over the request target
 * (with the Serve prefix restored, `servedTargets`) opens a socket: a bearer,
 * installer token or device grant is refused. Returns `{member}` or
 * `{status, body}` for a JSON refusal.
 */
export async function authenticateMemberUpgrade(request, { members, servedTargets = async () => [], kinds = executionMemberKinds, now = Date.now }) {
  if (!members || !hasMemberSignature(request.headers)) return { status: 401, body: { code: 'unauthorized', message: 'Sign this request as a member device.' } }
  let member
  try {
    member = await members.verify({ method: request.method, target: request.url, alternateTargets: await servedTargets(request.url), headers: request.headers, body: Buffer.alloc(0) })
  } catch (error) {
    // The device clock is wrong: the app says so instead of "unauthorized".
    if (error.code === 'member_time_stale') return { status: 401, body: { code: 'member_time_stale', message: error.message, serverTime: now() } }
    if (error.statusCode === 503) return { status: 503, body: { code: 'unavailable', message: error.message } }
    return { status: 401, body: { code: 'unauthorized', message: 'This device is not a member here.' } }
  }
  if (!kinds.includes(member.kind)) return { status: 401, body: { code: 'unauthorized', message: 'This member cannot open this socket.' } }
  return { member }
}

const reasons = { 400: 'Bad Request', 401: 'Unauthorized', 403: 'Forbidden', 404: 'Not Found', 426: 'Upgrade Required', 502: 'Bad Gateway', 503: 'Service Unavailable' }

/**
 * Ends an upgrade request with a JSON HTTP error. The code is repeated in
 * `X-Woven-Error`, and `Date` is always sent: a client whose WebSocket API
 * cannot read a refused upgrade's body still learns why, and its clock skew.
 */
export function refuseUpgrade(socket, status, body = {}, headers = {}) {
  const payload = JSON.stringify(body)
  const code = typeof body.code === 'string' && /^[a-z_]+$/.test(body.code) ? body.code : null
  const lines = [`HTTP/1.1 ${status} ${reasons[status] ?? 'Error'}`, 'Connection: close', 'Content-Type: application/json', 'Cache-Control: no-store',
    `Date: ${new Date().toUTCString()}`, ...(code ? [`X-Woven-Error: ${code}`] : []),
    `Content-Length: ${Buffer.byteLength(payload)}`, ...Object.entries(headers).map(([name, value]) => `${name}: ${value}`)]
  if (socket.writable) socket.end(lines.join('\r\n') + '\r\n\r\n' + payload)
  else socket.destroy()
}

/**
 * Who may open this host's bots relay: a signed member, or the installer
 * bearer on the installing Mac's SSH tunnel (a bots-only host that is not in
 * the registry is reached only that way). The bearer never works through
 * Tailscale Serve (`installerBearer.authorizes`), and an installer socket is
 * not a member socket, so the member registry never closes it.
 */
export async function authorizeBotsUpgrade(request, { members, servedTargets, installerBearer = null }) {
  const member = members ? (await authenticateMemberUpgrade(request, { members, servedTargets })).member : null
  if (member) return member
  return installerBearer?.authorizes(request) ? { installer: true } : null
}

/**
 * Open member sockets by device ID. `sweep(members)` closes every socket whose
 * member is gone, revoked, or no longer an allowed kind, with `4401`.
 */
export function createMemberSocketRegistry() {
  const sockets = new Map()
  function add(member, { kinds = executionMemberKinds, close }) {
    const entry = { kinds, close }
    const set = sockets.get(member.deviceID) ?? new Set()
    set.add(entry); sockets.set(member.deviceID, set)
    return () => {
      set.delete(entry)
      if (!set.size && sockets.get(member.deviceID) === set) sockets.delete(member.deviceID)
    }
  }
  function sweep(members) {
    const current = new Map(members.map(item => [item.deviceID, item]))
    let closed = 0
    for (const [deviceID, set] of sockets) {
      const member = current.get(deviceID)
      for (const entry of [...set]) {
        if (member && !member.revoked && entry.kinds.includes(member.kind)) continue
        set.delete(entry); closed++
        try { entry.close(memberRemovedCloseCode, 'This member was removed.') } catch {}
      }
      if (!set.size) sockets.delete(deviceID)
    }
    return closed
  }
  const count = () => [...sockets.values()].reduce((total, set) => total + set.size, 0)
  return { add, sweep, count }
}
