import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { chmodSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { join, resolve } from 'node:path'
import { privateKeyFromSeed, rawPublicKeyFor, signMemberRequest } from '../src/member-auth.mjs'

const repositoryRoot = resolve(import.meta.dirname, '../..')
const fakeHost = resolve(repositoryRoot, 'remote/test-support/fake-library-host.mjs')
const token = 'sign-ins-fixture-' + 'a'.repeat(40)

// A host's own sign-ins are administered by Mac members (and the installing
// Mac's bearer on its SSH tunnel) only: never a phone's device grant, a phone
// member, a Linux or bots member, or an unsigned request.
test('only a Mac administers a Linux host\'s sign-ins', async t => {
  const directory = mkdtempSync(join('/tmp', 'wl-sign-ins-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const home = join(directory, 'home')
  const member = (kind, seed) => ({ kind, deviceID: randomUUID(), key: privateKeyFromSeed(Buffer.alloc(32, seed)) })
  const mac = member('mac', 1), phone = member('ios', 2), linux = member('linux', 3)
  const membersPath = join(directory, 'members.json')
  writeFileSync(membersPath, JSON.stringify({ revision: 1, members: [mac, phone, linux].map(item => ({
    deviceID: item.deviceID, kind: item.kind, name: item.kind, publicKey: rawPublicKeyFor(item.key).toString('base64'), endpoints: [], revoked: false })) }))
  mkdirSync(join(directory, 'data'), { mode: 0o700 }); writeFileSync(join(directory, 'data/installation.json'), JSON.stringify({ id: 'studio', port: 7337 }))
  const tools = join(directory, 'bin'); mkdirSync(tools)
  writeFileSync(join(tools, 'flock'), '#!/bin/sh\nshift 3\nexec "$@"\n'); chmodSync(join(tools, 'flock'), 0o700)
  const library = join(directory, 'wovenmatter-library')
  writeFileSync(library, `#!/bin/sh\nexec "${process.execPath}" "${fakeHost}" "$@"\n`); chmodSync(library, 0o700)
  const port = await freePort()
  const child = spawn(process.execPath, [resolve(repositoryRoot, 'remote/src/server.mjs')], { cwd: repositoryRoot, stdio: ['ignore', 'pipe', 'pipe'], env: {
    HOME: home, PATH: tools + ':' + process.env.PATH, LANG: 'C', WOVENMATTER_API_TOKEN: token, WOVENMATTER_LISTEN_HOST: '127.0.0.1', WOVENMATTER_LISTEN_PORT: String(port),
    WOVENMATTER_WORKSPACE: join(home, 'workspace'), WOVENMATTER_HARNESS_CATALOG: resolve(repositoryRoot, 'harnesses/catalog.json'),
    WOVENMATTER_STATE_DIRECTORY: join(home, 'state'), WOVENMATTER_DATA_ROOT: join(directory, 'data'), WOVENMATTER_DATA_DIRECTORY: join(directory, 'data/databases'),
    WOVENMATTER_LIBRARY_BINARY: library, WOVENMATTER_LIBRARY_SERVE: '0', FAKE_LIBRARY_MEMBERS: membersPath } })
  const exited = new Promise(resolve => child.once('exit', resolve))
  t.after(async () => { child.kill('SIGTERM'); await exited })
  let output = ''
  child.stdout.on('data', data => { output += data }); child.stderr.on('data', data => { output += data })
  const base = 'http://127.0.0.1:' + port
  const bearer = (value, path, body) => fetch(base + path, { method: body ? 'POST' : 'GET',
    headers: { authorization: 'Bearer ' + value, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })
  let audience = null
  for (let i = 0; i < 200 && !audience; i++) {
    try { audience = (await (await bearer(token, '/health')).json()).memberIdentity?.deviceID ?? null } catch {}
    if (!audience) await new Promise(r => setTimeout(r, 50))
  }
  assert.ok(audience, output)
  const signed = (who, path, body) => {
    const data = body ? Buffer.from(JSON.stringify(body)) : Buffer.alloc(0), method = body ? 'POST' : 'GET'
    return fetch(base + path, { method, body: body ? data : undefined, headers: { 'content-type': 'application/json',
      ...signMemberRequest({ deviceID: who.deviceID, privateKey: who.key, audience, method, target: path, body: data }) } })
  }
  const change = { action: 'saveKey', provider: 'openrouter', key: 'fixture-provider-secret' }

  // Unsigned, or with an unknown bearer: 401.
  assert.equal((await fetch(base + '/sign-ins')).status, 401)
  assert.equal((await fetch(base + '/sign-ins', { method: 'POST', body: JSON.stringify(change) })).status, 401)
  assert.equal((await bearer('wrong', '/sign-ins')).status, 401)
  // A phone's device grant: 403 for both.
  const grant = await (await bearer(token, '/execution/devices', { libraryID: randomUUID(), workspaceID: randomUUID(), deviceID: randomUUID(), ownerDeviceID: randomUUID(), scopes: ['execution'] })).json()
  assert.ok(grant.token, JSON.stringify(grant))
  assert.equal((await bearer(grant.token, '/sign-ins')).status, 403)
  assert.equal((await bearer(grant.token, '/sign-ins', change)).status, 403)
  // Phone and Linux (bots) members: 403 for both.
  for (const who of [phone, linux]) {
    assert.equal((await signed(who, '/sign-ins')).status, 403, who.kind)
    assert.equal((await signed(who, '/sign-ins', change)).status, 403, who.kind)
  }
  // Nothing they sent was saved; a Mac member reads and changes them.
  const listed = await signed(mac, '/sign-ins')
  assert.equal(listed.status, 200)
  assert.deepEqual((await listed.json()).accounts.openrouter, [])
  const saved = await signed(mac, '/sign-ins', change)
  assert.equal(saved.status, 200)
  assert.equal((await saved.json()).accounts.openrouter.length, 1)
  // The installing Mac's bearer on its tunnel administers the host too.
  assert.equal((await bearer(token, '/sign-ins')).status, 200)
})

function freePort() {
  return new Promise(resolve => { const probe = createServer(); probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)) }) })
}
