import test from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { canonicalTarget, createMemberVerifier, memberHeaders, memberSigningMessage, privateKeyFromSeed, rawPublicKeyFor, signMemberRequest } from '../src/member-auth.mjs'

// The vectors the Swift membership code checks too; find them wherever the
// shared tests keep them.
const testsRoot = resolve(import.meta.dirname, '../../shared/Tests')
const vectorsPath = readdirSync(testsRoot, { recursive: true }).map(String).find(path => path.endsWith('MemberSignatureVectors.json'))
const vectors = JSON.parse(readFileSync(resolve(testsRoot, vectorsPath), 'utf8'))
const key = privateKeyFromSeed(Buffer.from(vectors.privateKeySeedHex, 'hex'))
const member = { deviceID: vectors.deviceID, kind: 'mac', name: 'Vector Mac', publicKey: vectors.publicKeyBase64, endpoints: [], revoked: false }
const headersFor = item => ({ [memberHeaders.device]: vectors.deviceID, [memberHeaders.audience]: vectors.audience, [memberHeaders.time]: String(item.time), [memberHeaders.nonce]: item.nonce, [memberHeaders.signature]: item.signature })
const verifierAt = (time, members = [member], audience = vectors.audience) => createMemberVerifier({ loadMembers: async () => ({ revision: 1, members }), audience, now: () => time })
const requestFor = item => ({ method: item.method, target: item.target, headers: headersFor(item), body: Buffer.from(item.body, 'utf8') })

test('Node derives the vector key and reproduces every signature byte for byte', () => {
  assert.ok(vectorsPath, 'MemberSignatureVectors.json is under shared/Tests')
  assert.equal(rawPublicKeyFor(key).toString('base64'), vectors.publicKeyBase64)
  for (const item of vectors.cases) {
    assert.equal(memberSigningMessage({ audience: vectors.audience, method: item.method, target: item.target, time: String(item.time), nonce: item.nonce, bodySHA256: item.bodySHA256 }), item.message)
    // Node's Ed25519 is deterministic (RFC 8032), so it matches exactly.
    const signed = signMemberRequest({ deviceID: vectors.deviceID, privateKey: key, audience: vectors.audience, method: item.method, target: item.target, body: Buffer.from(item.body, 'utf8'), time: item.time, nonce: item.nonce })
    assert.deepEqual(signed, Object.fromEntries(Object.entries(item.headers).map(([name, value]) => [name.toLowerCase(), value])), item.name)
  }
})

test('every vector verifies and every reject is refused', async () => {
  for (const item of vectors.cases) {
    const verified = await verifierAt(item.time).verify(requestFor(item))
    assert.equal(verified.deviceID, vectors.deviceID); assert.equal(verified.kind, 'mac')
  }
  for (const reject of vectors.rejects) {
    const base = vectors.cases.find(item => item.name === reject.case)
    const changed = { ...base, ...Object.fromEntries(Object.entries(reject).filter(([name]) => !['name', 'case'].includes(name))) }
    const audience = changed.audience ?? vectors.audience
    // Presented to the member it names (the audience-changed reject is the
    // second member): the signature must not verify there.
    await assert.rejects(verifierAt(base.time, [member], audience).verify({ ...requestFor(changed),
      headers: { ...headersFor(base), [memberHeaders.audience]: audience, [memberHeaders.time]: String(changed.time), [memberHeaders.nonce]: changed.nonce } }),
      error => error.statusCode === 401 && error.code === 'member_signature_mismatch', reject.name)
  }
})

test('a wrong key, a stale or future time and a replayed nonce are refused', async () => {
  const item = vectors.cases[0]
  const other = privateKeyFromSeed(Buffer.alloc(32, 5))
  const forged = signMemberRequest({ deviceID: vectors.deviceID, privateKey: other, audience: vectors.audience, method: item.method, target: item.target, body: Buffer.from(item.body), time: item.time, nonce: item.nonce })
  await assert.rejects(verifierAt(item.time).verify({ ...requestFor(item), headers: forged }), error => error.code === 'member_signature_mismatch')
  await assert.rejects(verifierAt(item.time + vectors.windowMilliseconds + 1).verify(requestFor(item)), error => error.code === 'member_time_stale')
  await assert.rejects(verifierAt(item.time - vectors.windowMilliseconds - 1).verify(requestFor(item)), error => error.code === 'member_time_stale')
  assert.ok(await verifierAt(item.time + vectors.windowMilliseconds).verify(requestFor(item)), 'the window is inclusive')
  const verifier = verifierAt(item.time)
  await verifier.verify(requestFor(item))
  await assert.rejects(verifier.verify(requestFor(item)), error => error.code === 'member_nonce_replayed')
})

test('the /wovenmatter mount is not part of the signed path, and a stripped Serve prefix can be supplied', async () => {
  assert.equal(canonicalTarget('/wovenmatter/v1/peers/sync?x=1'), '/v1/peers/sync?x=1')
  assert.equal(canonicalTarget('/wovenmatter'), '/'); assert.equal(canonicalTarget('/wovenmatter?x'), '/?x')
  assert.equal(canonicalTarget('/wovenmatter-execution/studio/v1/execution'), '/wovenmatter-execution/studio/v1/execution')
  const item = vectors.cases[0]
  assert.ok(await verifierAt(item.time).verify({ ...requestFor(item), target: '/wovenmatter' + item.target }))
  // A Mac signs the execution endpoint's full path; Serve strips it before Node.
  const time = item.time, nonce = 'QEFCQ0RFRkdISUpLTE1OTw'
  const headers = signMemberRequest({ deviceID: vectors.deviceID, privateKey: key, audience: vectors.audience, method: 'GET', target: '/wovenmatter-execution/studio/v1/execution', time, nonce })
  await assert.rejects(verifierAt(time).verify({ method: 'GET', target: '/v1/execution', headers, body: Buffer.alloc(0) }), error => error.code === 'member_signature_mismatch')
  assert.ok(await verifierAt(time).verify({ method: 'GET', target: '/v1/execution', alternateTargets: ['/wovenmatter-execution/studio/v1/execution'], headers, body: Buffer.alloc(0) }))
})

test('revoked and unknown members are refused, and a newly synced member is picked up', async () => {
  const item = vectors.cases[1]
  await assert.rejects(verifierAt(item.time, [{ ...member, revoked: true }]).verify(requestFor(item)), error => error.code === 'member_revoked')
  await assert.rejects(verifierAt(item.time, []).verify(requestFor(item)), error => error.code === 'member_unknown')
  let members = [], loads = 0
  const verifier = createMemberVerifier({ loadMembers: async () => { loads++; return { revision: members.length, members } }, audience: vectors.audience, now: () => item.time, missRefreshMilliseconds: 0 })
  await assert.rejects(verifier.verify(requestFor(item)), error => error.code === 'member_unknown')
  members = [member]
  assert.equal((await verifier.verify(requestFor(item))).deviceID, vectors.deviceID)
  assert.ok(loads >= 2)
  // A key that is not a raw 32-byte Ed25519 key is ignored, not trusted.
  await assert.rejects(verifierAt(item.time, [{ ...member, publicKey: 'AAAA' }]).verify(requestFor(item)), error => error.code === 'member_unknown')
})

test('malformed headers are refused before any member lookup or body read', async () => {
  let loads = 0, reads = 0
  const verifier = createMemberVerifier({ loadMembers: async () => { loads++; return { revision: 1, members: [member] } }, audience: vectors.audience, now: () => vectors.cases[0].time })
  const item = vectors.cases[0], base = headersFor(item)
  for (const [header, value, code] of [[memberHeaders.nonce, 'short', 'member_nonce_invalid'], [memberHeaders.nonce, item.nonce + '=', 'member_nonce_invalid'],
    [memberHeaders.time, '12.5', 'member_time_invalid'], [memberHeaders.device, 'not-a-uuid', 'member_device_invalid'], [memberHeaders.device, vectors.deviceID.toUpperCase(), 'member_device_invalid'],
    [memberHeaders.signature, 'AAAA', 'member_signature_invalid'], [memberHeaders.signature, undefined, 'member_headers_missing'],
    [memberHeaders.audience, undefined, 'member_headers_missing'], [memberHeaders.audience, 'nobody', 'member_audience_invalid'],
    [memberHeaders.audience, vectors.audience.toUpperCase(), 'member_audience_invalid']]) {
    await assert.rejects(verifier.verify({ method: 'POST', target: item.target, headers: { ...base, [header]: value }, body: async () => { reads++; return Buffer.alloc(0) } }), error => error.code === code)
  }
  assert.equal(loads, 0); assert.equal(reads, 0)
})

test('a request signed for one member is refused by every other member, even unused there', async () => {
  // Two members each keep their own nonce cache: only the audience stops a
  // captured request from being replayed to the second one inside the window.
  const item = vectors.cases[0], second = 'c0ffee00-1234-4abc-8def-0123456789ab'
  const first = verifierAt(item.time), other = verifierAt(item.time, [member], second)
  assert.ok(await first.verify(requestFor(item)))
  await assert.rejects(other.verify(requestFor(item)), error => error.statusCode === 401 && error.code === 'member_audience_mismatch')
  // Relabelling the audience header to the second member breaks the signature.
  await assert.rejects(other.verify({ ...requestFor(item), headers: { ...headersFor(item), [memberHeaders.audience]: second } }),
    error => error.code === 'member_signature_mismatch')
  // A fresh signature addressed to the second member is accepted there only.
  const addressed = signMemberRequest({ deviceID: vectors.deviceID, privateKey: key, audience: second, method: item.method, target: item.target,
    body: Buffer.from(item.body), time: item.time, nonce: 'UFFSU1RVVldYWVpbXF1eXw' })
  assert.ok(await other.verify({ ...requestFor(item), headers: addressed }))
  await assert.rejects(verifierAt(item.time).verify({ ...requestFor(item), headers: addressed }), error => error.code === 'member_audience_mismatch')
})

test('a verifier that does not know its own identity refuses signed requests', async () => {
  const item = vectors.cases[0]
  await assert.rejects(verifierAt(item.time, [member], async () => null).verify(requestFor(item)), error => error.statusCode === 503)
  let asked = 0
  const verifier = verifierAt(item.time, [member], async () => { asked++; return vectors.audience })
  assert.ok(await verifier.verify(requestFor(item)))
  assert.equal(await verifier.audience(), vectors.audience); assert.equal(asked, 1)
})
