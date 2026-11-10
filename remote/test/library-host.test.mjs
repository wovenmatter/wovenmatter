import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { createClientExecution } from '../src/client-execution.mjs'
import { createBotConversationLibrary, createLocalLibraryBotAdapter } from '../src/bots-library.mjs'
import { createHostAdministration } from '../src/host-admin.mjs'
import { createLibraryHostSupervisor, ensureLibraryToken, libraryBinaryPath } from '../src/library-host.mjs'
import { createLibraryServe } from '../src/library-serve.mjs'
import { memberHeaders, privateKeyFromSeed, rawPublicKeyFor, signMemberRequest } from '../src/member-auth.mjs'
import { enroll } from './fixtures/execution.mjs'

const repositoryRoot = resolve(import.meta.dirname, '../..')
const fakeHost = resolve(repositoryRoot, 'remote/test-support/fake-library-host.mjs')

function scratch(t, prefix) {
  // Unix socket paths are short; keep the data root shallow.
  const directory = mkdtempSync(join('/tmp', prefix))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}
function fakeBinary(directory) {
  const path = join(directory, 'wovenmatter-library')
  writeFileSync(path, `#!/bin/sh\nexec "${process.execPath}" "${fakeHost}" "$@"\n`); chmodSync(path, 0o700)
  return path
}
async function startedLibrary(t, directory, environment = {}) {
  const library = createLibraryHostSupervisor({ binary: fakeBinary(directory), dataRoot: join(directory, 'data'), statePath: join(directory, 'state/library/host.json'),
    environment: { ...process.env, ...environment }, minimumBackoff: 50, maximumBackoff: 200 })
  t.after(() => library.stop())
  library.start()
  assert.ok(await library.whenReady(10_000), 'the library host became ready')
  return library
}
const debugState = library => library.client.json('GET', '/v1/debug/state')

test('library binaries resolve per architecture inside the release', () => {
  assert.equal(libraryBinaryPath('/release', 'x64'), '/release/host/library/linux-x86_64/wovenmatter-library')
  assert.equal(libraryBinaryPath('/release', 'arm64'), '/release/host/library/linux-aarch64/wovenmatter-library')
  assert.equal(libraryBinaryPath('/release', 'ia32'), null)
})

test('the supervisor creates a private token, waits for ready, keeps its port across a crash, and stops cleanly', async t => {
  const directory = scratch(t, 'wl-sup-')
  const token = await ensureLibraryToken(join(directory, 'data/run/library-api.token'))
  assert.match(token, /^[A-Za-z0-9_-]{43}$/); assert.equal(statSync(join(directory, 'data/run/library-api.token')).mode & 0o777, 0o600)
  assert.equal(await ensureLibraryToken(join(directory, 'data/run/library-api.token')), token, 'an existing token is reused')
  const library = await startedLibrary(t, directory)
  const health = await library.client.health()
  assert.equal(health.service, 'wovenmatter-library'); assert.match(health.deviceID, /^[0-9a-f-]{36}$/)
  const first = library.endpoint()
  assert.equal(library.status().schema, 'fake-library-schema', 'the ready line carries the paired-library schema')
  assert.equal(JSON.parse(readFileSync(join(directory, 'data/run/library.json'), 'utf8')).pid, first.pid)
  process.kill(first.pid, 'SIGKILL')
  for (let i = 0; i < 200 && (!library.endpoint() || library.endpoint().pid === first.pid); i++) await new Promise(r => setTimeout(r, 25))
  assert.notEqual(library.endpoint().pid, first.pid); assert.equal(library.endpoint().port, first.port)
  assert.equal(library.status().restarts, 1)
  await library.stop()
  assert.equal(library.available(), false); assert.equal(existsSync(join(directory, 'data/run/library.json')), false)
  // A wrong bearer is refused by the host; the client never sends one while stopped.
  await assert.rejects(library.client.health(), error => error.statusCode === 503)
})

test('a missing binary is reported and retried instead of crashing the server', async t => {
  const directory = scratch(t, 'wl-miss-'), logs = []
  const library = createLibraryHostSupervisor({ binary: join(directory, 'missing'), dataRoot: join(directory, 'data'), statePath: join(directory, 'host.json'), log: line => logs.push(line), minimumBackoff: 20 })
  t.after(() => library.stop())
  library.start()
  assert.equal(await library.whenReady(200), null)
  assert.match(library.status().lastError, /no library host/)
})

test('a host that exits while the server is shutting down is not restarted', async t => {
  const directory = scratch(t, 'wl-quiet-'), logs = []
  const library = createLibraryHostSupervisor({ binary: fakeBinary(directory), dataRoot: join(directory, 'data'), statePath: join(directory, 'state/library/host.json'),
    log: line => logs.push(line), minimumBackoff: 20, maximumBackoff: 50 })
  t.after(() => library.stop())
  library.start()
  const ready = await library.whenReady(10_000)
  assert.ok(ready)
  library.quiesce()
  assert.equal(library.available(), true, 'a quiesced host keeps serving the shutdown')
  // systemd signals the whole service, so the host can exit before stop().
  process.kill(ready.pid, 'SIGTERM')
  for (let i = 0; i < 200 && library.status().running; i++) await new Promise(r => setTimeout(r, 25))
  await new Promise(r => setTimeout(r, 150))
  assert.equal(library.status().running, false); assert.equal(library.status().restarts, 0)
  assert.deepEqual(logs.filter(line => /restarting/.test(line)), [])
  await library.stop()
})

async function executionFixture(t, library, { fetchImpl } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'woven-linux-library-'))
  const runtime = { providers: async () => [{ id: 'default_agent', runtimeKind: 'default_agent', available: true }], create: async () => ({ sessionID: randomUUID() }), close: async () => {} }
  const service = createClientExecution({ directory, runtime, managedDataRoot: join(directory, 'databases'), publisherKey: 'k'.repeat(40), publisherFetch: fetchImpl ?? (async () => { throw new Error('No Mac is reachable.') }),
    publisherIntervalMilliseconds: 0, library: { client: library.client, available: library.available } })
  t.after(async () => { await service.close(); rmSync(directory, { recursive: true, force: true }) })
  const { principal: device, enrollment } = enroll(service)
  const command = (kind, values = {}) => service.command({ commandID: randomUUID(), deviceID: device.id, kind, ...values }, device)
  const opened = await command('createSession'), id = opened.conversationID
  const scope = service.mcp.resolvePrincipal('Bearer ' + service.mcp.sessionConnection(id).bearerToken)
  const call = (name, input = {}) => service.mcp.handle(scope, { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call', params: { name, arguments: input } })
  return { service, id, command, call, enrollment }
}
const resultOf = reply => JSON.parse(reply.result.content[0].text)

test('a Linux session reads and edits notes in its own library with no Mac grant and no Mac reachable', async t => {
  const directory = scratch(t, 'wl-mcp-'), logPath = join(directory, 'requests.jsonl')
  const library = await startedLibrary(t, directory, { FAKE_LIBRARY_LOG: logPath })
  const f = await executionFixture(t, library)
  assert.equal(f.service.mcp.libraryStatus().configured, false, 'no single-Mac library grant exists')
  const created = await f.call('woven_notes_create', { title: 'Linux note' })
  assert.equal(created.result.isError, false, JSON.stringify(created))
  const { noteID } = resultOf(created)
  assert.equal((await f.call('woven_notes_append', { noteID, text: 'written offline' })).result.isError, false)
  assert.equal(resultOf(await f.call('woven_notes_read', { noteID })).text, 'written offline')
  assert.equal(resultOf(await f.call('woven_notes_list')).notes.length, 1)
  assert.equal((await f.call('woven_calendar_list')).result.isError, false)
  const state = await debugState(library)
  assert.equal(state.notes[0].author, f.id, 'edits are attributed to the session')
  assert.equal(state.callers[f.id].runtimeKind, 'default_agent')
  const calls = readFileSync(logPath, 'utf8').trim().split('\n').map(line => JSON.parse(line)).filter(entry => entry.path === '/v1/mcp')
  for (const call of calls) {
    assert.equal(call.headers['x-woven-conversation-id'], f.id)
    assert.ok(call.headers['x-woven-enabled-groups'].split(',').every(group => ['notes', 'history', 'calendar', 'library', 'timers', 'sessions'].includes(group)), call.headers['x-woven-enabled-groups'])
  }
  // Groups the library host does not serve need a reachable Mac member; timers are served here.
  assert.equal((await f.call('woven_usage_read')).error.code, -32602)
  assert.equal((await f.call('woven_timers_list')).result.isError, false)
  // Turning notes off for the session takes effect at once.
  await f.command('workspace', { conversationID: f.id, workspaceAction: { sessionTools: { id: f.id, enabled: ['calendar'] } } })
  assert.equal((await f.call('woven_notes_list')).error.code, -32602)
})

test('history goes to the library when it runs and falls back to the local journal when it is down', async t => {
  const directory = scratch(t, 'wl-hist-')
  const library = await startedLibrary(t, directory)
  const f = await executionFixture(t, library)
  const fromLibrary = await f.call('woven_history_search', { search: 'x' })
  assert.equal(fromLibrary.result.isError, false); assert.ok(Array.isArray(resultOf(fromLibrary).entries))
  await library.stop()
  const local = await f.call('woven_history_conversations')
  assert.equal(local.result.isError, false, 'the Node journal answers while the library is down')
  const notes = await f.call('woven_notes_list')
  assert.equal(notes.result.isError, true); assert.equal(notes.result.structuredContent.code, 'unavailable')
})

test('session history is published into the local library instead of a Mac', async t => {
  const directory = scratch(t, 'wl-pub-')
  const library = await startedLibrary(t, directory)
  const fetched = []
  const f = await executionFixture(t, library, { fetchImpl: async url => { fetched.push(url); throw new Error('unreachable') } })
  await f.service.synchronizePublisher()
  const status = f.service.publisherStatus()
  assert.equal(status.target, 'local'); assert.equal(status.configured, true)
  const { journal } = await debugState(library)
  assert.ok(journal.length > 0); assert.ok(journal.every(entry => entry.workspaceID === f.enrollment.workspaceID))
  assert.equal(status.acknowledgedOriginSequence, Math.max(...journal.map(entry => entry.originSequence)))
  assert.equal(fetched.length, 0, 'no Mac publisher endpoint is contacted')
  // Nothing is sent twice.
  const before = journal.length
  await f.service.synchronizePublisher()
  assert.equal((await debugState(library)).journal.length, before)
})

test('bot conversation batches wait in the outbox while the library is down and drain in order', async t => {
  const directory = scratch(t, 'wl-bots-'), outbox = join(directory, 'outbox')
  const library = await startedLibrary(t, directory)
  const adapter = createLocalLibraryBotAdapter({ client: library.client, available: library.available, directory: outbox })
  const bots = createBotConversationLibrary(adapter), botID = randomUUID()
  const batch = n => ({ bot: { id: botID, name: 'Scout' }, conversations: [{ conversationId: 1, kind: 'main' }], entries: [{ id: n, conversationId: 1, role: 'user', text: 'entry ' + n, createdAt: n }] })
  await library.stop()
  await bots.writeBotEntries(botID, batch(1)); await bots.writeBotEntries(botID, batch(2))
  assert.equal(readFileSync(join(outbox, botID + '.jsonl'), 'utf8').trim().split('\n').length, 2)
  library.start(); await library.whenReady(10_000)
  assert.equal(await adapter.drain(), 2)
  assert.equal(existsSync(join(outbox, botID + '.jsonl')), false)
  await bots.writeBotEntries(botID, batch(3))
  assert.deepEqual((await debugState(library)).botEntries.map(item => item.entries[0].id), [1, 2, 3])
})

test('a library host without the bot entries route keeps batches in the outbox', async t => {
  const directory = scratch(t, 'wl-bots404-'), outbox = join(directory, 'outbox')
  const library = await startedLibrary(t, directory, { FAKE_LIBRARY_BOTS: '0' })
  const bots = createBotConversationLibrary(createLocalLibraryBotAdapter({ client: library.client, available: library.available, directory: outbox })), botID = randomUUID()
  await bots.writeBotEntries(botID, { bot: { id: botID, name: 'Scout' }, conversations: [{ conversationId: 1, kind: 'main' }], entries: [] })
  assert.equal(readdirSync(outbox).length, 1)
})

test('the library route is published under /wovenmatter on the first free Mac port, updated in place, and never on Funnel', async t => {
  const directory = scratch(t, 'wl-serve-')
  let config = { TCP: { 8443: { HTTPS: true } }, Web: { 'host.example.ts.net:8443': { Handlers: { '/wovenmatter-execution/w': { Proxy: 'http://127.0.0.1:7337' } } } } }
  const commands = []
  const tailscale = async args => {
    commands.push(args)
    if (args[0] === 'status') return JSON.stringify({ BackendState: 'Running', Self: { DNSName: 'host.example.ts.net.' } })
    if (args[1] === 'status') return JSON.stringify(config)
    const port = args.find(arg => arg.startsWith('--https=')).slice(8), endpoint = 'host.example.ts.net:' + port
    if (args.at(-1) === 'off') { delete config.Web[endpoint].Handlers['/wovenmatter']; return '' }
    config.TCP[port] = { HTTPS: true }; config.Web[endpoint] ??= { Handlers: {} }; config.Web[endpoint].Handlers['/wovenmatter'] = { Proxy: args.at(-1) }
    return ''
  }
  const serve = createLibraryServe({ statePath: join(directory, 'serve.json'), tailscale })
  assert.deepEqual(await serve.publish(41000), { endpoint: 'https://host.example.ts.net:10000/wovenmatter', httpsPort: 10000, target: 'http://127.0.0.1:41000' })
  assert.ok(commands.some(args => args.join(' ') === 'serve --bg --https=10000 --set-path=/wovenmatter http://127.0.0.1:41000'))
  const count = commands.length
  await serve.publish(41000)
  assert.equal(commands.filter(args => args[0] === 'serve' && args[1] === '--bg').length, commands.slice(0, count).filter(args => args[0] === 'serve' && args[1] === '--bg').length, 'an intact route is left alone')
  assert.equal((await serve.publish(41001)).httpsPort, 10000, 'a new loopback port reuses the recorded HTTPS port')
  assert.equal(config.Web['host.example.ts.net:10000'].Handlers['/wovenmatter'].Proxy, 'http://127.0.0.1:41001')
  assert.equal(config.Web['host.example.ts.net:8443'].Handlers['/wovenmatter-execution/w'].Proxy, 'http://127.0.0.1:7337', 'other routes are untouched')
  assert.ok(!commands.some(args => args.includes('funnel')))
  // A port that became public is no longer ours: publish elsewhere, leave it alone.
  config.AllowFunnel = { 'host.example.ts.net:10000': true }
  assert.equal((await serve.publish(41002)).httpsPort, 8444)
  assert.equal(config.Web['host.example.ts.net:10000'].Handlers['/wovenmatter'].Proxy, 'http://127.0.0.1:41001')
  config.AllowFunnel = { 'host.example.ts.net:8445': true }; config.TCP[8444] = { HTTPS: false }
  delete config.Web['host.example.ts.net:8444']
  await assert.rejects(createLibraryServe({ statePath: join(directory, 'other.json'), tailscale, candidates: [8445] }).publish(41003), /funnel/)
  delete config.AllowFunnel; config.TCP[8444] = { HTTPS: true }
  config.Web['host.example.ts.net:8444'] = { Handlers: { '/wovenmatter': { Proxy: 'http://127.0.0.1:41002' } } }
  assert.deepEqual(await serve.remove(), { removed: true })
  assert.equal(config.Web['host.example.ts.net:8444'].Handlers['/wovenmatter'], undefined)
  assert.equal(config.Web['host.example.ts.net:10000'].Handlers['/wovenmatter'].Proxy, 'http://127.0.0.1:41001', 'only the recorded route is removed')
})

test('host administration runs lifecycle commands for administrators and detaches restart and update', async t => {
  const directory = scratch(t, 'wl-admin-'), ran = [], detached = []
  writeFileSync(join(directory, 'installation.json'), JSON.stringify({ id: 'studio', port: 7337, accessMode: 'user', roles: { workspace: true, bots: true } }))
  const admin = createHostAdministration({ serviceRoot: directory, dataRoot: directory, stateDirectory: join(directory, 'run'), script: '/release/host/remote-host.sh',
    run: async (script, args) => { ran.push([script, ...args]); return { ok: true, command: args[0] } }, detach: async (name, command, options) => { detached.push({ name, command, options }); return 'unit' },
    extractScript: async () => { throw new Error('no script') }, extra: async () => ({ memberIdentity: { deviceID: 'x' } }) })
  const replies = []
  const json = (response, status, value) => replies.push({ status, value })
  const request = (method, path, body) => Object.assign(Readable.from(body ? [Buffer.from(body)] : []), { method, headers: {} })
  const { Readable } = await import('node:stream')
  const handle = (method, path, { administrator = true, body } = {}) => admin.handle(request(method, path, body), {}, new URL(path, 'http://localhost'), { json, readJSON: async () => JSON.parse(body ?? '{}'), administrator })
  await handle('GET', '/v1/host/status', { administrator: false })
  assert.deepEqual(replies.pop(), { status: 403, value: { error: 'administrator_required' } })
  await handle('GET', '/v1/host/status')
  assert.deepEqual(replies.pop().value, { ok: true, command: 'status', memberIdentity: { deviceID: 'x' } })
  await handle('GET', '/v1/host/logs?lines=50')
  assert.deepEqual(ran.at(-1), ['/release/host/remote-host.sh', 'logs', 'studio', '50'])
  await handle('POST', '/v1/host/bots-configure', { body: JSON.stringify({ poolBytes: 8 * 1024 ** 3, diskBytes: null }) })
  assert.deepEqual(ran.at(-1), ['/release/host/remote-host.sh', 'bots-configure', 'studio', String(8 * 1024 ** 3), 'none'])
  await handle('POST', '/v1/host/restart')
  assert.equal(replies.pop().status, 202); assert.deepEqual(detached.at(-1).command, ['/bin/bash', '/release/host/remote-host.sh', 'restart', 'studio'])
  await handle('POST', '/v1/host/update?fingerprint=' + 'a'.repeat(64), { body: 'bundle bytes' })
  assert.equal(replies.pop().status, 202)
  const update = detached.at(-1).command
  assert.deepEqual(update.slice(3, 9), ['wovenmatter-update', '/release/host/remote-host.sh', 'studio', '7337', 'user', 'a'.repeat(64)])
  assert.equal(update[9], 'workspace,bots')
  assert.equal(readFileSync(update[10], 'utf8'), '\nbundle bytes', 'an empty credential line keeps the installed token')
  assert.equal((await admin.lastUpdate()).state, 'running')
  writeFileSync(join(directory, 'run/host-update/update.code'), '0\n'); writeFileSync(join(directory, 'run/host-update/update.out'), '{"state":"running"}\n')
  assert.deepEqual((await admin.lastUpdate()).result, { state: 'running' })
})

// The service with a library host: signed member requests, roles and rejections.
test('the server accepts signed member requests and rejects wrong keys, replays, stale times and unknown devices', async t => {
  const directory = scratch(t, 'wl-svc-'), home = join(directory, 'home')
  const macSeed = Buffer.alloc(32, 1), phoneSeed = Buffer.alloc(32, 2), strangerSeed = Buffer.alloc(32, 3)
  const mac = { deviceID: randomUUID(), key: privateKeyFromSeed(macSeed) }, phone = { deviceID: randomUUID(), key: privateKeyFromSeed(phoneSeed) }
  const membersPath = join(directory, 'members.json')
  const writeMembers = (revision, extra = []) => writeFileSync(membersPath, JSON.stringify({ revision, members: [
    { deviceID: mac.deviceID, kind: 'mac', name: 'Studio Mac', publicKey: rawPublicKeyFor(mac.key).toString('base64'), endpoints: [], revoked: false },
    { deviceID: phone.deviceID, kind: 'ios', name: 'Phone', publicKey: rawPublicKeyFor(phone.key).toString('base64'), endpoints: [], revoked: false }, ...extra] }))
  writeMembers(1)
  mkdirSync(join(directory, 'data'), { mode: 0o700 }); writeFileSync(join(directory, 'data/installation.json'), JSON.stringify({ id: 'studio', port: 7337 }))
  const token = 'member-fixture-' + 'a'.repeat(40), port = await freePort()
  // The host lock uses flock(1), which macOS lacks; the service tests use the same shim.
  const tools = join(directory, 'bin'); mkdirSync(tools)
  writeFileSync(join(tools, 'flock'), '#!/bin/sh\nshift 3\nexec "$@"\n'); chmodSync(join(tools, 'flock'), 0o700)
  const child = spawn(process.execPath, [resolve(repositoryRoot, 'remote/src/server.mjs')], { cwd: repositoryRoot, stdio: ['ignore', 'pipe', 'pipe'], env: {
    HOME: home, PATH: tools + ':' + process.env.PATH, LANG: 'C', WOVENMATTER_API_TOKEN: token, WOVENMATTER_LISTEN_HOST: '127.0.0.1', WOVENMATTER_LISTEN_PORT: String(port),
    WOVENMATTER_WORKSPACE: join(home, 'workspace'), WOVENMATTER_HARNESS_CATALOG: resolve(repositoryRoot, 'harnesses/catalog.json'),
    WOVENMATTER_STATE_DIRECTORY: join(home, 'state'), WOVENMATTER_DATA_ROOT: join(directory, 'data'), WOVENMATTER_DATA_DIRECTORY: join(directory, 'data/databases'),
    WOVENMATTER_LIBRARY_BINARY: fakeBinary(directory), WOVENMATTER_LIBRARY_SERVE: '0', FAKE_LIBRARY_MEMBERS: membersPath } })
  const exited = new Promise(resolve => child.once('exit', resolve))
  t.after(async () => { child.kill('SIGTERM'); await exited })
  let output = ''
  child.stdout.on('data', data => { output += data }); child.stderr.on('data', data => { output += data })
  const base = 'http://127.0.0.1:' + port
  let audience = null
  const signed = (who, method, path, body, options = {}) => {
    const headers = signMemberRequest({ deviceID: who.deviceID, privateKey: who.key, audience, method, target: path, body: body ? Buffer.from(body) : Buffer.alloc(0), ...options })
    return fetch(base + path, { method, headers: { ...headers, ...(body ? { 'content-type': 'application/json' } : {}) }, ...(body ? { body } : {}) })
  }
  let identity
  for (const deadline = Date.now() + 20_000; Date.now() < deadline;) {
    // identity.json is written beside the health report; wait for both.
    try { identity = await (await fetch(base + '/v1/health', { headers: { authorization: 'Bearer ' + token } })).json(); if (identity.memberIdentity && existsSync(join(home, 'state/library/identity.json'))) break } catch {}
    await new Promise(r => setTimeout(r, 50))
  }
  assert.ok(identity?.memberIdentity, output)
  assert.equal(identity.memberIdentity.kind, 'linux'); assert.match(identity.memberIdentity.publicKey, /^[A-Za-z0-9+/]+=*$/)
  assert.equal(JSON.parse(readFileSync(join(home, 'state/library/identity.json'), 'utf8')).deviceID, identity.memberIdentity.deviceID)
  assert.equal(identity.library.ready, true)
  // Requests are addressed to this host's own member device ID.
  audience = identity.memberIdentity.deviceID

  // A Mac member administers the host; a phone member does not.
  assert.equal((await signed(mac, 'GET', '/v1/health')).status, 200)
  assert.equal((await signed(phone, 'GET', '/v1/health')).status, 403)
  // Any member may use execution routes: this workspace is not enrolled yet.
  assert.equal((await signed(phone, 'GET', '/v1/execution')).status, 409)
  // A signed JSON body is checked byte for byte and still parsed by the route.
  const provision = JSON.stringify({ libraryID: randomUUID(), workspaceID: randomUUID(), deviceID: randomUUID(), ownerDeviceID: mac.deviceID, scopes: ['execution'] })
  const enrolled = await signed(mac, 'POST', '/v1/execution/devices', provision)
  assert.equal(enrolled.status, 201)
  // The workspace's execution device is this host's member device ID, so
  // members address it from the registry alone.
  assert.equal((await enrolled.json()).workspace.executionDeviceID, audience)
  assert.equal((await signed(phone, 'GET', '/v1/execution')).status, 200)

  const stranger = { deviceID: phone.deviceID, key: privateKeyFromSeed(strangerSeed) }
  const refused = async (response, code) => { assert.equal(response.status, 401); assert.equal((await response.json()).error, code) }
  await refused(await signed(stranger, 'GET', '/v1/execution'), 'member_signature_mismatch')
  await refused(await signed({ deviceID: randomUUID(), key: mac.key }, 'GET', '/v1/execution'), 'member_unknown')
  await refused(await signed(phone, 'GET', '/v1/execution', null, { time: Date.now() - 301_000 }), 'member_time_stale')
  const nonce = Buffer.alloc(16, 9).toString('base64url')
  assert.equal((await signed(phone, 'GET', '/v1/execution', null, { nonce })).status, 200)
  await refused(await signed(phone, 'GET', '/v1/execution', null, { nonce }), 'member_nonce_replayed')
  // A body that differs from the signed one is refused.
  const headers = signMemberRequest({ deviceID: mac.deviceID, privateKey: mac.key, audience, method: 'POST', target: '/v1/execution/devices', body: Buffer.from(provision) })
  await refused(await fetch(base + '/v1/execution/devices', { method: 'POST', headers: { ...headers, 'content-type': 'application/json' }, body: provision.replace('execution', 'inference') }), 'member_signature_mismatch')
  // A Mac signs the execution endpoint's full path, which Serve strips.
  assert.equal((await signed(phone, 'GET', '/v1/execution', null, { target: '/wovenmatter-execution/studio/v1/execution' })).status, 200)
  await refused(await signed(phone, 'GET', '/v1/execution', null, { target: '/wovenmatter-execution/other/v1/execution' }), 'member_signature_mismatch')
  // A request addressed to another member (captured on its way there) is
  // refused here even though its nonce is new to this host.
  await refused(await signed(phone, 'GET', '/v1/execution', null, { audience: randomUUID() }), 'member_audience_mismatch')
  // (Revocation is applied on the next member list refresh; member-auth.test.mjs covers it.)
  // The installer's bearer still works during the transition.
  assert.equal((await fetch(base + '/v1/health', { headers: { authorization: 'Bearer ' + token } })).status, 200)
  assert.equal(memberHeaders.signature, 'x-woven-member-signature')
  // Stopping the server stops the library host it supervises.
  const libraryPid = identity.library.pid
  child.kill('SIGTERM'); await exited
  let alive = true
  // The library host gets SIGTERM as the server exits; allow a loaded machine
  // time to deliver it rather than a fixed 2.5 s.
  for (const deadline = Date.now() + 15_000; alive && Date.now() < deadline;) {
    try { process.kill(libraryPid, 0); await new Promise(r => setTimeout(r, 25)) } catch { alive = false }
  }
  assert.equal(alive, false, 'the library host exited with the server')
})

function freePort() {
  return new Promise(resolve => { const probe = createServer(); probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)) }) })
}
