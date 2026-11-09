import test from 'node:test'
import assert from 'node:assert/strict'
import { readdirSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'
import { createMemberVerifier, memberHeaders, privateKeyFromSeed, rawPublicKeyFor, signMemberRequest } from '../src/member-auth.mjs'

// Swift checks the same file; find it wherever the shared tests keep it.
const testsRoot = resolve(import.meta.dirname, '../../shared/Tests')
const vectorsPath = readdirSync(testsRoot, { recursive: true }).map(String).find(path => path.endsWith('MemberSignatureVectors.json'))
const vectors = JSON.parse(readFileSync(resolve(testsRoot, vectorsPath), 'utf8'))
const headersFor = item => ({ [memberHeaders.device]: vectors.member.deviceID, [memberHeaders.time]: item.time, [memberHeaders.nonce]: item.nonce, [memberHeaders.signature]: item.signature })
const verifierAt = (time, members = [vectors.member]) => createMemberVerifier({ loadMembers: async () => ({ revision: 1, members }), now: () => time })

test('the shared vectors file has a key pair Node derives the same way', () => {
  assert.ok(vectorsPath, 'MemberSignatureVectors.json is under shared/Tests')
  const key = privateKeyFromSeed(Buffer.from(vectors.member.privateKeySeed, 'base64'))
  assert.equal(rawPublicKeyFor(key).toString('base64'), vectors.member.publicKey)
  for (const item of vectors.accepted) {
    assert.equal(item.message, `woven-member-v1\n${item.method}\n${item.target}\n${item.time}\n${item.nonce}\n${item.bodySHA256}`)
    // Node's Ed25519 is deterministic, so it reproduces each vector exactly.
    const signed = signMemberRequest({ deviceID: vectors.member.deviceID, privateKey: key, method: item.method, target: item.target, body: Buffer.from(item.body, 'utf8'), time: item.time, nonce: item.nonce })
    assert.equal(signed[memberHeaders.signature], item.signature, item.name)
  }
})

test('every accepted vector verifies and every rejected vector fails for its stated reason', async () => {
  const now = Number(vectors.verifyAt)
  for (const item of vectors.accepted) {
    const member = await verifierAt(now).verify({ method: item.method, target: item.target, headers: headersFor(item), body: Buffer.from(item.body, 'utf8') })
    assert.equal(member.deviceID, vectors.member.deviceID); assert.equal(member.kind, 'mac')
  }
  for (const item of vectors.rejected) {
    await assert.rejects(verifierAt(now).verify({ method: item.method, target: item.target, headers: headersFor(item), body: Buffer.from(item.body, 'utf8') }),
      error => error.statusCode === 401 && error.code === item.reason, item.name)
  }
  const verifier = verifierAt(now), replayed = vectors.accepted.find(item => item.name === vectors.replay.of)
  const request = { method: replayed.method, target: replayed.target, headers: headersFor(replayed), body: Buffer.from(replayed.body, 'utf8') }
  await verifier.verify(request)
  await assert.rejects(verifier.verify(request), error => error.code === vectors.replay.reason)
})

test('revoked and unknown members are refused, and a newly synced member is picked up', async () => {
  const now = Number(vectors.verifyAt), item = vectors.accepted[0]
  const request = { method: item.method, target: item.target, headers: headersFor(item), body: Buffer.alloc(0) }
  await assert.rejects(verifierAt(now, [{ ...vectors.member, revoked: true }]).verify(request), error => error.code === 'member_revoked')
  await assert.rejects(verifierAt(now, []).verify(request), error => error.code === 'member_unknown')
  let members = [], loads = 0
  const verifier = createMemberVerifier({ loadMembers: async () => { loads++; return { revision: members.length, members } }, now: () => now, missRefreshMilliseconds: 0 })
  await assert.rejects(verifier.verify(request), error => error.code === 'member_unknown')
  members = [vectors.member]
  assert.equal((await verifier.verify(request)).deviceID, vectors.member.deviceID)
  assert.ok(loads >= 2)
  // Members whose keys are not raw 32-byte Ed25519 keys are ignored, not trusted.
  await assert.rejects(verifierAt(now, [{ ...vectors.member, publicKey: 'AAAA' }]).verify(request), error => error.code === 'member_unknown')
})

test('malformed headers are refused before any key lookup', async () => {
  let loads = 0
  const verifier = createMemberVerifier({ loadMembers: async () => { loads++; return { revision: 1, members: [vectors.member] } }, now: () => Number(vectors.verifyAt) })
  const item = vectors.accepted[0], base = headersFor(item)
  for (const [header, value, code] of [[memberHeaders.nonce, 'short', 'member_nonce_invalid'], [memberHeaders.time, '12.5', 'member_time_invalid'],
    [memberHeaders.device, 'not-a-uuid', 'member_device_invalid'], [memberHeaders.signature, 'AAAA', 'member_signature_invalid'], [memberHeaders.signature, undefined, 'member_headers_missing']]) {
    await assert.rejects(verifier.verify({ method: 'GET', target: item.target, headers: { ...base, [header]: value }, body: Buffer.alloc(0) }), error => error.code === code)
  }
  assert.equal(loads, 0)
})
