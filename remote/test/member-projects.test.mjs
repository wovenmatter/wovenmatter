import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, realpathSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { join, resolve } from 'node:path'
import { privateKeyFromSeed, rawPublicKeyFor, signMemberRequest } from '../src/member-auth.mjs'

const repositoryRoot = resolve(import.meta.dirname, '../..')
const fakeHost = resolve(repositoryRoot, 'remote/test-support/fake-library-host.mjs')
const token = 'projects-fixture-' + 'a'.repeat(40)

// A new folder on this host is a blank directory in its managed workspace
// root. Any Mac member creates it with its signature alone, whichever Mac set
// the host up (docs/architecture/WOVEN_EVERYWHERE.md, "Folder owners"); a phone
// or Linux member cannot, and a taken name is named instead of failing as 500.
test('a Mac member creates a project directory with its signature; other members cannot', async t => {
  const directory = mkdtempSync(join('/tmp', 'wl-projects-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const home = join(directory, 'home'), workspace = join(home, 'workspace')
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
    WOVENMATTER_WORKSPACE: workspace, WOVENMATTER_HARNESS_CATALOG: resolve(repositoryRoot, 'harnesses/catalog.json'),
    WOVENMATTER_STATE_DIRECTORY: join(home, 'state'), WOVENMATTER_DATA_ROOT: join(directory, 'data'), WOVENMATTER_DATA_DIRECTORY: join(directory, 'data/databases'),
    WOVENMATTER_LIBRARY_BINARY: library, WOVENMATTER_LIBRARY_SERVE: '0', FAKE_LIBRARY_MEMBERS: membersPath } })
  const exited = new Promise(resolve => child.once('exit', resolve))
  t.after(async () => { child.kill('SIGTERM'); await exited })
  let output = ''
  child.stdout.on('data', data => { output += data }); child.stderr.on('data', data => { output += data })
  const base = 'http://127.0.0.1:' + port
  let audience = null
  for (let i = 0; i < 200 && !audience; i++) {
    try { audience = (await (await fetch(base + '/v1/health', { headers: { authorization: 'Bearer ' + token } })).json()).memberIdentity?.deviceID ?? null } catch {}
    if (!audience) await new Promise(r => setTimeout(r, 50))
  }
  assert.ok(audience, output)
  // As a Mac reaches it through Tailscale Serve, which strips the workspace's
  // `/wovenmatter-execution/<id>` prefix: the signature covers the path as sent.
  const create = (who, name) => {
    const data = Buffer.from(JSON.stringify({ name, reuseExisting: false }))
    return fetch(base + '/v1/projects', { method: 'POST', body: data, headers: { 'content-type': 'application/json',
      ...signMemberRequest({ deviceID: who.deviceID, privateKey: who.key, audience, method: 'POST', target: '/v1/projects', body: data }) } })
  }

  assert.equal((await fetch(base + '/v1/projects', { method: 'POST', body: JSON.stringify({ name: 'Unsigned' }) })).status, 401)
  for (const who of [phone, linux]) assert.equal((await create(who, 'Refused ' + who.kind)).status, 403, who.kind)
  assert.equal(existsSync(join(workspace, 'Refused ios')) || existsSync(join(workspace, 'Refused linux')) || existsSync(join(workspace, 'Unsigned')), false)

  const created = await create(mac, 'Field notes')
  assert.equal(created.status, 201, output)
  const path = (await created.json()).path
  assert.equal(path, join(realpathSync(workspace), 'Field notes'))
  assert.ok(statSync(path).isDirectory())

  // The same name again is refused by name, with nothing changed.
  const taken = await create(mac, 'Field notes')
  assert.equal(taken.status, 409)
  assert.deepEqual(await taken.json(), { error: 'A directory with that name already exists in this workspace.' })
  const invalid = await create(mac, 'scratch')
  assert.equal(invalid.status, 400)
  assert.match((await invalid.json()).error, /Scratch is reserved/)
})

function freePort() {
  return new Promise(resolve => { const probe = createServer(); probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)) }) })
}
