import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { join, resolve } from 'node:path'
import { Readable } from 'node:stream'
import { createInstallerBearer, proxiedRequest } from '../src/installer-bearer.mjs'
import { createHostAdministration } from '../src/host-admin.mjs'
import { privateKeyFromSeed, rawPublicKeyFor, signMemberRequest } from '../src/member-auth.mjs'

const repositoryRoot = resolve(import.meta.dirname, '../..')
const fakeHost = resolve(repositoryRoot, 'remote/test-support/fake-library-host.mjs')
const token = 'installer-fixture-' + 'a'.repeat(40)

function scratch(t, prefix) {
  const directory = mkdtempSync(join('/tmp', prefix))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}
const request = headers => ({ headers })

test('the installer bearer works only without the headers Tailscale Serve adds', async () => {
  let next = 'rotated-' + 'b'.repeat(40)
  const bearer = createInstallerBearer({ token, rotate: async () => next })
  assert.equal(bearer.authorizes(request({ authorization: 'Bearer ' + token })), true)
  assert.equal(bearer.authorizes(request({ authorization: 'Bearer wrong' })), false)
  assert.equal(bearer.authorizes(request({})), false)
  for (const name of ['x-forwarded-for', 'x-forwarded-host', 'x-forwarded-proto', 'tailscale-user-login', 'tailscale-headers-info', 'forwarded']) {
    assert.equal(proxiedRequest(request({ [name]: 'x' })), true, name)
    assert.equal(bearer.authorizes(request({ authorization: 'Bearer ' + token, [name]: 'x' })), false, name)
  }
  assert.equal(await bearer.rotate(), next)
  assert.equal(bearer.authorizes(request({ authorization: 'Bearer ' + token })), false, 'the old bearer stops at once')
  assert.equal(bearer.authorizes(request({ authorization: 'Bearer ' + next })), true)
  next = 'short'
  await assert.rejects(bearer.rotate(), /installer_rotation_failed/)
  assert.equal(bearer.matches(request({ authorization: 'Bearer rotated-' + 'b'.repeat(40) })), true, 'a failed rotation keeps the current bearer')
})

test('a host update upload is removed unless the update took it', async t => {
  const directory = scratch(t, 'wl-upload-')
  writeFileSync(join(directory, 'installation.json'), JSON.stringify({ id: 'studio', port: 7337, accessMode: 'user', roles: { workspace: true } }))
  let detachFails = false
  const admin = createHostAdministration({ serviceRoot: directory, dataRoot: directory, stateDirectory: join(directory, 'run'), script: '/release/host/remote-host.sh',
    run: async () => ({}), detach: async () => { if (detachFails) throw Object.assign(new Error('systemd_run_failed'), { statusCode: 500 }); return 'unit' },
    extractScript: async () => { throw new Error('no script') } })
  const updates = join(directory, 'run/host-update')
  const replies = [], json = (response, status, value) => replies.push({ status, value })
  const upload = async () => admin.receive(Object.assign(Readable.from([Buffer.from('bundle bytes')]), { headers: {} }))
  const handle = (path, bodyFile, administrator = true) => admin.handle(Object.assign(Readable.from([]), { method: 'POST', headers: {} }), {}, new URL(path, 'http://localhost'),
    { json, readJSON: async () => ({}), readBody: async () => Buffer.alloc(0), administrator, bodyFile })
  const streams = () => existsSync(updates) ? readdirSync(updates).filter(name => name.endsWith('.stream')) : []

  // A bad fingerprint, a missing installation and a failed start all remove it.
  let file = await upload()
  await assert.rejects(handle('/v1/host/update?fingerprint=bad', file), /fingerprint/)
  assert.deepEqual(streams(), [])
  file = await upload(); detachFails = true
  await assert.rejects(handle('/v1/host/update?fingerprint=' + 'a'.repeat(64), file), /systemd_run_failed/)
  assert.deepEqual(streams(), [])
  assert.equal((await admin.lastUpdate()).state, 'none', 'an update that never started is not reported as running')
  // A started update owns it (its unit removes it when done)…
  file = await upload(); detachFails = false
  await handle('/v1/host/update?fingerprint=' + 'a'.repeat(64), file)
  assert.equal(replies.pop().status, 202); assert.equal(file.owned, true); assert.deepEqual(streams(), [file.path.split('/').at(-1)])
  // …and a second one while it runs is refused and removed.
  const second = await upload()
  await assert.rejects(handle('/v1/host/update?fingerprint=' + 'a'.repeat(64), second), /host_update_running/)
  assert.deepEqual(streams(), [file.path.split('/').at(-1)])
})

// The server itself: a Mac member, a phone member, the installer's bearer
// directly and the same bearer arriving through Serve.
test('the server refuses the installer bearer through Serve and any Mac rotates it', async t => {
  const directory = scratch(t, 'wl-inst-'), home = join(directory, 'home')
  const mac = { deviceID: randomUUID(), key: privateKeyFromSeed(Buffer.alloc(32, 1)) }, phone = { deviceID: randomUUID(), key: privateKeyFromSeed(Buffer.alloc(32, 2)) }
  const membersPath = join(directory, 'members.json')
  writeFileSync(membersPath, JSON.stringify({ revision: 1, members: [
    { deviceID: mac.deviceID, kind: 'mac', name: 'Studio Mac', publicKey: rawPublicKeyFor(mac.key).toString('base64'), endpoints: [], revoked: false },
    { deviceID: phone.deviceID, kind: 'ios', name: 'Phone', publicKey: rawPublicKeyFor(phone.key).toString('base64'), endpoints: [], revoked: false }] }))
  mkdirSync(join(directory, 'data'), { mode: 0o700 }); writeFileSync(join(directory, 'data/installation.json'), JSON.stringify({ id: 'studio', port: 7337 }))
  const tools = join(directory, 'bin'); mkdirSync(tools)
  writeFileSync(join(tools, 'flock'), '#!/bin/sh\nshift 3\nexec "$@"\n'); chmodSync(join(tools, 'flock'), 0o700)
  const library = join(directory, 'wovenmatter-library')
  writeFileSync(library, `#!/bin/sh\nexec "${process.execPath}" "${fakeHost}" "$@"\n`); chmodSync(library, 0o700)
  // Stands in for remote-host.sh rotate-token: hands out the next bearer.
  const rotations = join(directory, 'rotations'), script = join(directory, 'remote-host.sh')
  writeFileSync(script, `echo "$@" >>"${rotations}"\nn=$(wc -l <"${rotations}" | tr -d ' ')\nprintf '{"rotated":true,"token":"rotated-%s-${'c'.repeat(40)}"}\\n' "$n"\n`)
  const port = await freePort()
  const child = spawn(process.execPath, [resolve(repositoryRoot, 'remote/src/server.mjs')], { cwd: repositoryRoot, stdio: ['ignore', 'pipe', 'pipe'], env: {
    HOME: home, PATH: tools + ':' + process.env.PATH, LANG: 'C', WOVENMATTER_API_TOKEN: token, WOVENMATTER_LISTEN_HOST: '127.0.0.1', WOVENMATTER_LISTEN_PORT: String(port),
    WOVENMATTER_RUNTIME_KIND: 'host', WOVENMATTER_WORKSPACE: join(home, 'workspace'), WOVENMATTER_HARNESS_CATALOG: resolve(repositoryRoot, 'harnesses/catalog.json'),
    WOVENMATTER_STATE_DIRECTORY: join(home, 'state'), WOVENMATTER_DATA_ROOT: join(directory, 'data'), WOVENMATTER_DATA_DIRECTORY: join(directory, 'data/databases'),
    WOVENMATTER_LIBRARY_BINARY: library, WOVENMATTER_LIBRARY_SERVE: '0', FAKE_LIBRARY_MEMBERS: membersPath, WOVENMATTER_HOST_SCRIPT: script } })
  const exited = new Promise(resolve => child.once('exit', resolve))
  t.after(async () => { child.kill('SIGTERM'); await exited })
  let output = ''
  child.stdout.on('data', data => { output += data }); child.stderr.on('data', data => { output += data })
  const base = 'http://127.0.0.1:' + port
  const bearer = (value, path = '/v1/health', headers = {}, method = 'GET') => fetch(base + path, { method, headers: { authorization: 'Bearer ' + value, ...headers } })
  let audience = null
  for (let i = 0; i < 200 && !audience; i++) {
    try { audience = (await (await bearer(token)).json()).memberIdentity?.deviceID ?? null } catch {}
    if (!audience) await new Promise(r => setTimeout(r, 50))
  }
  assert.ok(audience, output)
  const signed = (who, method, path) => fetch(base + path, { method, headers: signMemberRequest({ deviceID: who.deviceID, privateKey: who.key, audience, method, target: path, body: Buffer.alloc(0) }) })

  // Through Serve the bearer is refused, wherever the request goes.
  for (const headers of [{ 'x-forwarded-for': 'fd7a:115c:a1e0::9', 'x-forwarded-host': 'host.tail.ts.net' }, { 'tailscale-user-login': 'someone@example.com' }]) {
    assert.equal((await bearer(token, '/v1/health', headers)).status, 401)
    assert.equal((await bearer(token, '/v1/host/installer-bearer', headers, 'POST')).status, 401)
  }
  assert.equal((await bearer(token)).status, 200, 'the SSH tunnel path keeps working')
  // A phone member cannot rotate it; a Mac member can, and learns nothing.
  assert.equal((await signed(phone, 'POST', '/v1/host/installer-bearer')).status, 403)
  const rotated = await signed(mac, 'POST', '/v1/host/installer-bearer')
  assert.equal(rotated.status, 200); assert.deepEqual(await rotated.json(), { rotated: true })
  assert.equal(readFileSync(rotations, 'utf8'), 'rotate-token studio\n')
  assert.equal((await bearer(token)).status, 401, 'the replaced bearer stops working')
  const first = 'rotated-1-' + 'c'.repeat(40)
  assert.equal((await bearer(first)).status, 200)
  // The installer rotating its own bearer over its tunnel receives the new one.
  const own = await (await bearer(first, '/v1/host/installer-bearer', {}, 'POST')).json()
  assert.deepEqual(own, { rotated: true, bearer: 'rotated-2-' + 'c'.repeat(40) })
  assert.equal((await bearer(first)).status, 401); assert.equal((await bearer(own.bearer)).status, 200)
  // Signed Mac requests never depended on it.
  assert.equal((await signed(mac, 'GET', '/v1/health')).status, 200)

  // Host administration exists on native Linux hosts only: a phone's signed
  // upload is refused before any of it is written.
  if (process.platform === 'linux') {
    const body = Buffer.alloc(1024 * 1024, 7), path = '/v1/host/update?fingerprint=' + 'a'.repeat(64)
    const headers = signMemberRequest({ deviceID: phone.deviceID, privateKey: phone.key, audience, method: 'POST', target: path, body })
    const refused = await fetch(base + path, { method: 'POST', headers: { ...headers, 'content-type': 'application/octet-stream' }, body })
    assert.equal(refused.status, 403)
    const updates = join(home, 'state/host-update')
    assert.deepEqual(existsSync(updates) ? readdirSync(updates).filter(name => name.endsWith('.stream')) : [], [])
  }
})

function freePort() {
  return new Promise(resolve => { const probe = createServer(); probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)) }) })
}
