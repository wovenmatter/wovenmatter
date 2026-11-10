import { createHash, createPrivateKey, createPublicKey, randomBytes, sign as signData, verify as verifySignature } from 'node:crypto'

// Signed requests between members (docs/architecture/WOVEN_EVERYWHERE.md,
// "Membership and device keys"). Nothing is issued or cached for a caller: a
// request is accepted when its device is a current member, its time is within
// the window, its nonce is new, and the Ed25519 signature verifies.
export const memberHeaders = Object.freeze({
  device: 'x-woven-member-device', audience: 'x-woven-member-audience', time: 'x-woven-member-time',
  nonce: 'x-woven-member-nonce', signature: 'x-woven-member-signature',
})
export const memberSignatureDomain = 'woven-member-v2'
export const memberSignatureWindowMilliseconds = 300_000
const fail = (statusCode, message, code) => Object.assign(new Error(message), { statusCode, code })
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
// Strict unpadded base64url: only the canonical encoding of its bytes.
const base64url = value => typeof value === 'string' && /^[A-Za-z0-9_-]+$/.test(value) && Buffer.from(value, 'base64url').toString('base64url') === value

export const bodyDigest = body => createHash('sha256').update(body ?? Buffer.alloc(0)).digest('hex')

/**
 * The signed path omits a leading `/wovenmatter` mount, which Tailscale Serve
 * strips before a Linux host sees the request while a Mac receives it intact
 * (Swift `MemberRequestSignature.canonicalTarget`).
 */
export function canonicalTarget(target) {
  if (target === '/wovenmatter') return '/'
  if (target.startsWith('/wovenmatter/')) return target.slice('/wovenmatter'.length)
  if (target.startsWith('/wovenmatter?')) return '/' + target.slice('/wovenmatter'.length)
  return target
}

/**
 * The exact UTF-8 string both sides sign. `target` is the path with query;
 * `audience` is the destination member's device ID, so a request captured on
 * the way to one member cannot be replayed to another within the window.
 */
export function memberSigningMessage({ audience, method, target, time, nonce, bodySHA256 }) {
  return `${memberSignatureDomain}\n${audience}\n${String(method).toUpperCase()}\n${canonicalTarget(target)}\n${time}\n${nonce}\n${bodySHA256}`
}

/** Accepts standard or URL-safe base64, padded or not; returns the raw 32-byte key. */
export function rawPublicKey(value) {
  if (typeof value !== 'string' || !/^[A-Za-z0-9+/_-]+={0,2}$/.test(value)) return null
  const bytes = Buffer.from(value.replaceAll('-', '+').replaceAll('_', '/'), 'base64')
  return bytes.length === 32 ? bytes : null
}

export function publicKeyObject(raw) {
  return createPublicKey({ key: { kty: 'OKP', crv: 'Ed25519', x: Buffer.from(raw).toString('base64url') }, format: 'jwk' })
}

// A 32-byte Ed25519 seed (CryptoKit's `rawRepresentation`) as a Node key.
export function privateKeyFromSeed(seed) {
  const bytes = Buffer.from(seed)
  if (bytes.length !== 32) throw new TypeError('An Ed25519 seed is 32 bytes.')
  return createPrivateKey({ key: Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), bytes]), format: 'der', type: 'pkcs8' })
}

export function rawPublicKeyFor(privateKey) {
  return Buffer.from(createPublicKey(privateKey).export({ format: 'jwk' }).x, 'base64url')
}

/** Headers for one signed request to the member `audience`; used by tests. Production Node signs through its library host. */
export function signMemberRequest({ deviceID, privateKey, audience, method, target, body, time = Date.now(), nonce = randomBytes(16).toString('base64url') }) {
  if (!uuid(audience) || audience !== audience.toLowerCase()) throw new TypeError('A signed member request names its destination member (lowercase device ID).')
  const message = memberSigningMessage({ audience, method, target, time: String(time), nonce, bodySHA256: bodyDigest(body) })
  return {
    [memberHeaders.device]: deviceID, [memberHeaders.audience]: audience, [memberHeaders.time]: String(time), [memberHeaders.nonce]: nonce,
    [memberHeaders.signature]: signData(null, Buffer.from(message, 'utf8'), privateKey).toString('base64url'),
  }
}

export const hasMemberSignature = headers => Object.values(memberHeaders).some(name => headers[name] !== undefined)

/**
 * `loadMembers()` returns the library host's `GET /v1/members` reply:
 * `{revision, members: [{deviceID, kind, name, publicKey, endpoints, revoked}]}`.
 * The list is cached by revision, refreshed every `refreshMilliseconds`, and
 * reloaded early (at most once per `missRefreshMilliseconds`) when an unknown
 * device signs, so a newly added member works as soon as it has synced.
 */
export function createMemberVerifier({ loadMembers, audience, now = Date.now, windowMilliseconds = memberSignatureWindowMilliseconds,
  refreshMilliseconds = 15_000, missRefreshMilliseconds = 2_000, maximumNonces = 200_000 } = {}) {
  let current = { revision: null, members: new Map() }, loadedAt = 0, missAt = 0, loading = null, ownDeviceID = null
  const nonces = new Map()
  // This machine's own member device ID: a request signed for any other
  // member is refused, whatever its signature. `audience` is the ID or a
  // function that resolves it (the library host's identity), cached once known.
  async function own() {
    if (ownDeviceID) return ownDeviceID
    const value = typeof audience === 'function' ? await audience() : audience
    if (!uuid(value)) throw fail(503, 'This host does not know its own member identity yet.', 'members_unavailable')
    return (ownDeviceID = value.toLowerCase())
  }

  function index(value) {
    if (!value || typeof value !== 'object' || !Array.isArray(value.members)) throw fail(503, 'The member list is unavailable.', 'members_unavailable')
    if (value.revision != null && value.revision === current.revision) return current
    const members = new Map()
    for (const item of value.members) {
      if (!item || typeof item !== 'object' || !uuid(item.deviceID) || !['mac', 'linux', 'ios'].includes(item.kind)) continue
      const raw = rawPublicKey(item.publicKey)
      if (!raw) continue
      let key
      try { key = publicKeyObject(raw) } catch { continue }
      members.set(item.deviceID.toLowerCase(), { deviceID: item.deviceID.toLowerCase(), kind: item.kind, name: typeof item.name === 'string' ? item.name.slice(0, 256) : '',
        endpoints: Array.isArray(item.endpoints) ? item.endpoints : [], revoked: item.revoked === true, key })
    }
    return { revision: value.revision ?? null, members }
  }

  async function refresh() {
    loading ??= (async () => {
      try { current = index(await loadMembers()); loadedAt = now() } finally { loading = null }
      return current
    })()
    return loading
  }

  async function member(deviceID) {
    if (now() - loadedAt >= refreshMilliseconds) await refresh().catch(() => {})
    let found = current.members.get(deviceID)
    if (!found && now() - missAt >= missRefreshMilliseconds) {
      missAt = now()
      await refresh().catch(() => {})
      found = current.members.get(deviceID)
    }
    return found
  }

  function remember(key, time) {
    const clock = now()
    if (nonces.size >= maximumNonces) for (const [saved, expires] of nonces) if (expires < clock) nonces.delete(saved)
    if (nonces.size >= maximumNonces) throw fail(503, 'Too many signed requests are in flight. Retry shortly.', 'member_busy')
    nonces.set(key, time + windowMilliseconds)
  }

  /**
   * Verifies one request. `target` is the request target as this server
   * received it (path and query); `alternateTargets` are the same request as
   * the caller may have sent it before a Serve prefix was stripped. `body` is
   * the raw body bytes or a reader. Returns the member, or throws a 401 whose
   * `code` names the reason.
   */
  async function verify({ method, target, alternateTargets = [], headers, body }) {
    const device = headers[memberHeaders.device], time = headers[memberHeaders.time], addressed = headers[memberHeaders.audience]
    const nonce = headers[memberHeaders.nonce], signature = headers[memberHeaders.signature]
    if (![device, addressed, time, nonce, signature].every(value => typeof value === 'string')) throw fail(401, 'Every member signature header is required.', 'member_headers_missing')
    // Device IDs are lowercase on the wire, as the Swift signer sends them.
    if (!uuid(device) || device !== device.toLowerCase()) throw fail(401, 'The member device ID is invalid.', 'member_device_invalid')
    if (!uuid(addressed) || addressed !== addressed.toLowerCase()) throw fail(401, 'The member audience is invalid.', 'member_audience_invalid')
    if (addressed !== await own()) throw fail(401, 'This signed request was meant for another device.', 'member_audience_mismatch')
    if (!/^\d{1,16}$/.test(time)) throw fail(401, 'The member request time is invalid.', 'member_time_invalid')
    if (!base64url(nonce) || Buffer.from(nonce, 'base64url').length !== 16 || nonce.length !== 22) throw fail(401, 'The member nonce must be 16 bytes of unpadded base64url.', 'member_nonce_invalid')
    if (!base64url(signature) || Buffer.from(signature, 'base64url').length !== 64) throw fail(401, 'The member signature is invalid.', 'member_signature_invalid')
    const milliseconds = Number(time)
    if (Math.abs(now() - milliseconds) > windowMilliseconds) throw fail(401, 'The member request time is outside the accepted window.', 'member_time_stale')
    const found = await member(device.toLowerCase())
    if (!found) throw fail(401, 'This device is not a member.', 'member_unknown')
    if (found.revoked) throw fail(401, 'This member was removed.', 'member_revoked')
    // A body reader runs only after the cheap checks, so strangers cannot make
    // this server buffer large uploads; it may return `{sha256}` for a file.
    const bytes = typeof body === 'function' ? await body() : body
    const bodySHA256 = typeof bytes?.sha256 === 'string' ? bytes.sha256 : bodyDigest(bytes), raw = Buffer.from(signature, 'base64url')
    const verified = [target, ...alternateTargets].some(candidate =>
      verifySignature(null, Buffer.from(memberSigningMessage({ audience: addressed, method, target: candidate, time, nonce, bodySHA256 }), 'utf8'), found.key, raw))
    if (!verified) throw fail(401, 'The member signature does not verify.', 'member_signature_mismatch')
    // Only a verified request consumes its nonce, so a forged copy cannot block it.
    const key = found.deviceID + ':' + nonce
    const seen = nonces.get(key)
    if (seen !== undefined && seen >= now()) throw fail(401, 'This member request was already used.', 'member_nonce_replayed')
    remember(key, milliseconds)
    return { deviceID: found.deviceID, kind: found.kind, name: found.name, endpoints: found.endpoints }
  }

  const periodic = setInterval(() => {
    const clock = now()
    for (const [key, expires] of nonces) if (expires < clock) nonces.delete(key)
  }, 60_000)
  periodic.unref?.()

  return { verify, refresh, audience: own, revision: () => current.revision, members: () => [...current.members.values()].map(({ key, ...rest }) => rest), close: () => clearInterval(periodic) }
}
