import test from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { mkdtempSync, rmSync, readFileSync, statSync, writeFileSync, mkdirSync, existsSync, watch } from 'node:fs'
import { createServer, request as httpRequest } from 'node:http'
import { connect } from 'node:net'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createClientExecution } from '../src/client-execution.mjs'
import { botPrincipal } from '../src/workspace-mcp.mjs'
import { createBotConversationLibrary, createMemoryBotLibraryAdapter, createJournalBotLibraryAdapter } from '../src/bots-library.mjs'
import { createBotPreviews } from '../src/bots-previews.mjs'
import { createBotsRuntime } from '../src/bots-runtime.mjs'
import { botEngineLayout, createBotEngine, machineIdentity } from '../src/bots-engine.mjs'
import { createBotsService } from '../src/bots-service.mjs'

const temporary = t => { const directory = mkdtempSync(join(tmpdir(), 'woven-bots-')); t.after(() => rmSync(directory, { recursive: true, force: true })); return directory }
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)))

async function execution(t, fetchImpl) {
  const directory = temporary(t)
  const runtime = { providers: async () => [], create: async () => ({ sessionID: randomUUID() }), close: async () => {} }
  const service = createClientExecution({ directory, runtime, managedDataRoot: join(directory, 'databases'), publisherKey: 'k'.repeat(40), publisherFetch: fetchImpl, publisherIntervalMilliseconds: 0,
    mcpEndpointURL: () => 'http://127.0.0.1:7337/mcp' })
  t.after(() => service.close())
  return service
}

test('bot MCP keys rotate, attribute library calls to the bot, honor botMCP groups and pause-all, and revoke', async t => {
  const requests = []
  const service = await execution(t, async (url, options) => { requests.push({ url, options }); return { ok: true, status: 200, text: async () => JSON.stringify({ jsonrpc: '2.0', id: 'x', result: { content: [] } }) } })
  const { enroll } = await import('./fixtures/execution.mjs'); enroll(service)
  const mcp = service.mcp, deviceID = randomUUID(), botID = randomUUID()
  assert.throws(() => mcp.issueBotKey({ botID: 'nope', botName: 'x', deviceID }), /bot UUID/)
  const first = mcp.issueBotKey({ botID, botName: 'Research\nbot', deviceID })
  assert.equal(first.principal, botPrincipal(deviceID, botID))
  assert.equal(first.principal, `woven:bot:${deviceID}:${botID}`)
  const second = mcp.issueBotKey({ botID, botName: 'Research bot', deviceID })
  assert.equal(mcp.resolvePrincipal('Bearer ' + first.bearerToken), null, 'issuing again rotates the key')
  const scope = mcp.resolvePrincipal('Bearer ' + second.bearerToken)
  assert.equal(scope.kind, 'bot'); assert.equal(scope.botID, botID)
  assert.deepEqual(mcp.botKeys().map(key => key.botID), [botID])
  assert.ok(!JSON.stringify(mcp.botKeys()).includes(second.bearerToken))

  const list = async () => (await mcp.handle(scope, { jsonrpc: '2.0', id: 'l', method: 'tools/list' })).result.tools.map(tool => tool.name)
  const names = await list()
  assert.ok(names.includes('woven_notes_read'))
  assert.ok(!names.some(name => name.startsWith('woven_computer_') || name.startsWith('woven_executor_')), 'Computer Use and Executor start off')
  assert.ok(!names.includes('woven_sessions_send') && !names.includes('woven_goals_set'), 'conversation-bound local tools are not offered to bots')
  // Without the library connection there is nowhere to send a bot's call.
  assert.equal((await mcp.handle(scope, { jsonrpc: '2.0', id: 'n', method: 'tools/call', params: { name: 'woven_notes_read', arguments: { noteID: randomUUID() } } })).error.code, -32602)
  const own = service.descriptor()
  mcp.configureLibrary({ grantID: randomUUID(), libraryID: own.libraryID, workspaceID: own.id, executionDeviceID: own.executionDeviceID, endpointURL: 'https://central.example.ts.net/wovenmatter/mcp/workspace', bearerToken: 't'.repeat(43) })
  const called = await mcp.handle(scope, { jsonrpc: '2.0', id: 'n', method: 'tools/call', params: { name: 'woven_notes_read', arguments: { noteID: randomUUID() } } })
  assert.ok(called.result, JSON.stringify(called))
  const headers = requests.at(-1).options.headers
  assert.equal(headers['x-woven-caller'], second.principal)
  assert.equal(headers['x-woven-bot-id'], botID)
  assert.equal(decodeURIComponent(headers['x-woven-bot-name']), 'Research bot')
  assert.equal(headers['x-woven-conversation-id'], undefined)

  mcp.configureBots({ groups: ['calendar'] })
  assert.ok(!(await list()).includes('woven_notes_read'))
  assert.ok((await list()).some(name => name.startsWith('woven_calendar_')))
  mcp.configureBots({ isEnabled: false })
  assert.deepEqual(await list(), [], 'pause-all removes every tool from every bot')
  assert.equal(mcp.settings().botMCP.isEnabled, false)
  // The Mac's synced settings carry the same toggles.
  const synced = mcp.configureSettings({ ...mcp.settings(), botMCP: { isEnabled: true, groups: ['notes'] } })
  assert.deepEqual(synced.botMCP, { isEnabled: true, groups: ['notes'] })
  assert.ok((await list()).includes('woven_notes_read'))
  mcp.revokeBotKey(botID)
  assert.equal(mcp.resolvePrincipal('Bearer ' + second.bearerToken), null)
})

test('bot conversation batches validate and upsert by id, and the journal keeps every batch durably', async t => {
  const memory = createMemoryBotLibraryAdapter(), library = createBotConversationLibrary(memory), botID = randomUUID()
  const batch = (entries, extra = {}) => ({ bot: { id: botID, name: 'Helper' }, conversations: [{ conversationId: 'main', kind: 'main' }, { conversationId: 't1', kind: 'thread', parentConversationId: 'main', title: 'Plan' }], entries, ...extra })
  await assert.rejects(library.writeBotEntries('bot', batch([])), /bot UUID/)
  await assert.rejects(library.writeBotEntries(botID, { ...batch([]), bot: { id: randomUUID(), name: 'x' } }), /name its bot/)
  await assert.rejects(library.writeBotEntries(botID, batch([{ id: 'a', conversationId: 'missing', role: 'user', text: 'hi' }])), /listed conversation/)
  await assert.rejects(library.writeBotEntries(botID, batch(Array.from({ length: 201 }, (_, i) => ({ id: 'e' + i, conversationId: 'main', role: 'user', text: '' }))) ), /at most 200/)
  assert.deepEqual(await library.writeBotEntries(botID, batch([{ id: 'a', conversationId: 'main', role: 'user', text: 'hi', createdAt: 1 }])), { conversations: 2, entries: 1 })
  // Metadata-only batches and resends are valid; an entry id upserts.
  assert.deepEqual(await library.writeBotEntries(botID.toUpperCase(), batch([])), { conversations: 2, entries: 0 })
  await library.writeBotEntries(botID, batch([{ id: 'a', conversationId: 'main', role: 'user', text: 'hi', createdAt: 1 }, { id: 'b', conversationId: 't1', role: 'assistant', text: 'ok' }]))
  assert.deepEqual(memory.entries(botID).map(entry => entry.id), ['a', 'b'])
  assert.equal(memory.bot(botID).conversations.get('t1').title, 'Plan')

  const directory = temporary(t)
  const journal = createBotConversationLibrary(createJournalBotLibraryAdapter(directory))
  await journal.writeBotEntries(botID, batch([{ id: 'a', conversationId: 'main', role: 'user', text: 'hi' }]))
  await journal.writeBotEntries(botID, batch([]))
  const lines = readFileSync(join(directory, botID + '.jsonl'), 'utf8').trim().split('\n').map(line => JSON.parse(line))
  assert.deepEqual(lines.map(line => line.entries.length), [1, 0])
  assert.equal(lines[0].bot.name, 'Helper')
  assert.equal(statSync(join(directory, botID + '.jsonl')).mode & 0o777, 0o600)
})

function fakeTailscale(initial = {}) {
  const state = { config: structuredClone(initial), calls: [] }
  const dns = 'host.example.ts.net'
  const run = async args => {
    state.calls.push(args)
    if (args[0] === 'status') return JSON.stringify({ BackendState: 'Running', Self: { DNSName: dns + '.' } })
    if (args[0] === 'serve' && args[1] === 'status') return JSON.stringify(Object.keys(state.config).length ? state.config : null)
    if (args[0] === 'serve' && args[1] === '--bg') {
      assert.ok(!args.includes('funnel'))
      const port = args[2].slice('--https='.length), target = args[3]
      state.config.TCP = { ...state.config.TCP, [port]: { HTTPS: true } }
      state.config.Web = { ...state.config.Web, [`${dns}:${port}`]: { Handlers: { '/': { Proxy: target } } } }
      return ''
    }
    if (args[0] === 'serve' && args[2] === 'off') {
      const port = args[1].slice('--https='.length)
      delete state.config.TCP[port]; delete state.config.Web[`${dns}:${port}`]
      return ''
    }
    throw new Error('unexpected tailscale call ' + args.join(' '))
  }
  return { state, run, dns }
}

test('previews publish the runtime proxy as tailnet-only Serve routes on free ports and remove only their own routes', async t => {
  const directory = temporary(t)
  const foreign = { TCP: { '17000': { HTTPS: true } }, Web: { 'host.example.ts.net:17000': { Handlers: { '/': { Proxy: 'http://127.0.0.1:4317' } } } } }
  const tailscale = fakeTailscale(foreign)
  const previews = createBotPreviews({ statePath: join(directory, 'previews.json'), tailscale: tailscale.run })
  const botID = randomUUID()
  await assert.rejects(previews.publish({ botID, port: 80 }), /loopback proxy port/)
  const published = await previews.publish({ botID, port: 41000, containerPort: 3000 })
  assert.equal(published.httpsPort, 17001, 'a port another route uses is skipped')
  assert.equal(published.url, 'https://host.example.ts.net:17001/')
  assert.equal(tailscale.state.config.Web['host.example.ts.net:17001'].Handlers['/'].Proxy, 'http://127.0.0.1:41000')
  assert.deepEqual(await previews.publish({ botID, port: 41000, containerPort: 3000 }), published, 'publishing again is idempotent')
  assert.equal(previews.list()[0].containerPort, 3000)
  assert.ok(!tailscale.state.calls.some(args => args.includes('funnel')))
  assert.deepEqual(await previews.unpublish({ botID, port: 41000 }), { removed: true })
  assert.equal(tailscale.state.config.Web['host.example.ts.net:17000'].Handlers['/'].Proxy, 'http://127.0.0.1:4317', 'unrelated sharing is preserved')
  assert.equal(tailscale.state.config.TCP['17001'], undefined)

  // A route left by a previous process is removed on recovery, a changed one is not.
  const again = await previews.publish({ botID, port: 41000 })
  const other = await previews.publish({ botID, port: 41001 })
  tailscale.state.config.Web[`host.example.ts.net:${other.httpsPort}`].Handlers['/'].Proxy = 'http://127.0.0.1:1'
  await createBotPreviews({ statePath: join(directory, 'previews.json'), tailscale: tailscale.run }).recover()
  assert.equal(tailscale.state.config.TCP[String(again.httpsPort)], undefined, 'a stale Woven route is removed')
  assert.ok(tailscale.state.config.TCP[String(other.httpsPort)], 'a route someone changed is left alone')
})

test('the runtime supervisor writes a private config with a fresh token, restarts after a crash, and stops', async t => {
  const directory = temporary(t), children = []
  const spawnImpl = (command, args, options) => {
    const child = new EventEmitter(); child.pid = 1000 + children.length; child.args = args; child.options = options
    child.kill = signal => { setImmediate(() => child.emit('exit', null, signal)) }
    children.push(child); return child
  }
  let port = 40000
  const runtime = createBotsRuntime({ packageRoot: '/release/bots', configPath: join(directory, 'run/bots/runtime.json'), spawnImpl, portImpl: async () => ++port,
    environment: { WOVENMATTER_API_TOKEN: 'secret', PATH: '/usr/bin' }, minimumBackoff: 10, configuration: async () => ({ dataDir: '/data/bots', engine: { socket: '/run/wovenmatter/docker.sock', kind: 'linux-dockerd' } }) })
  runtime.start()
  await new Promise(resolve => setTimeout(resolve, 30))
  assert.equal(children.length, 1)
  assert.deepEqual(children[0].args, ['/release/bots/src/cli.ts', 'serve', '--config', join(directory, 'run/bots/runtime.json')])
  assert.equal(children[0].options.env.WOVENMATTER_API_TOKEN, undefined)
  const config = JSON.parse(readFileSync(join(directory, 'run/bots/runtime.json'), 'utf8'))
  assert.deepEqual(config.listen, { host: '127.0.0.1', port: 40001 })
  assert.equal(config.engine.kind, 'linux-dockerd')
  assert.ok(config.runtimeToken.length >= 40)
  assert.equal(statSync(join(directory, 'run/bots/runtime.json')).mode & 0o777, 0o600)
  assert.deepEqual(runtime.endpoint(), { host: '127.0.0.1', port: 40001, token: config.runtimeToken })
  children[0].emit('exit', 1, null)
  await new Promise(resolve => setTimeout(resolve, 60))
  assert.equal(children.length, 2, 'a crash restarts the runtime')
  const restarted = JSON.parse(readFileSync(join(directory, 'run/bots/runtime.json'), 'utf8'))
  assert.notEqual(restarted.runtimeToken, config.runtimeToken)
  assert.equal(runtime.status().restarts, 1)
  await runtime.stop()
  assert.equal(runtime.endpoint(), null)
  await new Promise(resolve => setTimeout(resolve, 40))
  assert.equal(children.length, 2, 'a stopped runtime is not restarted')
})

function engineFixture(t, { pool = 8 * 1024 ** 3, disk = null } = {}) {
  const root = temporary(t), layout = botEngineLayout('wmtest', root)
  mkdirSync(join(root, 'etc/wmtest-bots'), { recursive: true }); mkdirSync(join(layout.var, 'requests'), { recursive: true }); mkdirSync(join(layout.var, 'state'), { recursive: true })
  writeFileSync(layout.config, JSON.stringify({ user: 'bots', poolBytes: pool, diskBytes: disk, subnet: ['10', '237', '0', '0'].join('.') + '/16', bridge: 'br-wmtest', dockerVersion: '29.9.3' }))
  return { root, layout }
}

test('engine status and resources come from the root-owned records, and settings requests wait for the applier', async t => {
  const { root, layout } = engineFixture(t)
  const engine = createBotEngine({ instance: 'wmtest', root, memoryTotal: () => 10 * 1024 ** 3, docker: async () => 'OK', sleep: ms => new Promise(r => setTimeout(r, Math.min(ms, 20))) })
  const status = await engine.status()
  assert.equal(status.installed, true); assert.equal(status.ready, true); assert.equal(status.socket, join(root, 'run/wmtest/docker.sock'))
  const resources = await engine.resources({ botMemoryBytes: 4 * 1024 ** 3 })
  assert.equal(resources.memory.totalBytes, 10 * 1024 ** 3)
  assert.equal(resources.memory.poolBytes, 8 * 1024 ** 3)
  assert.ok(resources.disk.totalBytes > 0 && resources.disk.freeBytes > 0)
  assert.ok(resources.warnings.some(warning => warning.id === 'pool_leaves_little_memory'))
  await assert.rejects(engine.configure({ poolBytes: -1, diskBytes: null }), /positive size/)
  // Stand-in for the root path unit: apply whatever request appears.
  const watcher = watch(join(layout.var, 'requests'), () => {
    try {
      const request = JSON.parse(readFileSync(layout.request, 'utf8'))
      writeFileSync(layout.state, JSON.stringify({ appliedRevision: request.revision, requestError: null }))
    } catch {}
  })
  t.after(() => watcher.close())
  const applied = await engine.configure({ poolBytes: 4 * 1024 ** 3, diskBytes: 20 * 1024 ** 3 }, { waitMilliseconds: 3000 })
  assert.equal(applied.pending, false)
  const request = JSON.parse(readFileSync(layout.request, 'utf8'))
  assert.deepEqual(Object.keys(request).sort(), ['diskBytes', 'poolBytes', 'revision'])
  assert.equal(request.poolBytes, 4 * 1024 ** 3)
  const missing = createBotEngine({ instance: 'wmtest', root: temporary(t), docker: async () => 'OK' })
  assert.equal((await missing.status()).installed, false)
  await assert.rejects(missing.configure({ poolBytes: null, diskBytes: null }), /not_installed/)
})

test('machine identity is stable and honors an explicit device ID', async t => {
  const dataRoot = temporary(t)
  const first = await machineIdentity({ dataRoot, environment: {}, hostname: 'box' })
  assert.match(first.deviceID, /^[0-9a-f-]{36}$/)
  assert.deepEqual(await machineIdentity({ dataRoot, environment: {}, hostname: 'box' }), first)
  assert.equal(statSync(join(dataRoot, 'identity/device-id')).mode & 0o777, 0o600)
  const explicit = randomUUID().toUpperCase()
  assert.equal((await machineIdentity({ dataRoot, environment: { WOVENMATTER_DEVICE_ID: explicit }, hostname: 'box' })).deviceID, explicit.toLowerCase())
})

async function serviceFixture(t, overrides = {}) {
  const directory = temporary(t)
  const { root } = engineFixture(t)
  const engine = createBotEngine({ instance: 'wmtest', root, docker: async () => 'OK' })
  const keys = new Map(), credentialsCalls = []
  const mcp = {
    issueBotKey: ({ botID, botName, deviceID }) => { keys.set(botID, botName); return { endpointURL: 'http://127.0.0.1:1/mcp', bearerToken: 'bot-token', principal: botPrincipal(deviceID, botID) } },
    revokeBotKey: botID => ({ revoked: keys.delete(botID) }),
    settings: () => ({ botMCP: { isEnabled: true, groups: ['notes'] } }), botKeys: () => [...keys.keys()], configureBots: value => ({ settings: value }),
  }
  const memory = createMemoryBotLibraryAdapter()
  const publishCalls = []
  const previews = { recover: async () => {}, close: async () => {}, list: () => [], publish: async value => { publishCalls.push(value); return { url: 'https://host.example.ts.net:17000/' } }, unpublish: async () => ({ removed: true }) }
  const machine = { deviceID: randomUUID(), name: 'box' }
  const runtimeStub = overrides.runtime ?? { start() {}, stop: async () => {}, restart: async () => {}, endpoint: () => null, status: () => ({ running: false }) }
  let port
  const service = createBotsService({ configuration: { stateDirectory: directory, dataRoot: directory, botsData: join(directory, 'bots'), serviceRoot: directory, botsEnabled: true, workspaceEnabled: false, botsInstance: 'wmtest' },
    mcp, defaultAgent: { botCredentials: async value => { credentialsCalls.push(value); return { provider: value.provider, credential: { type: 'api_key', key: 'k' } } } },
    serverPort: () => port, library: createBotConversationLibrary(memory), engine, runtime: runtimeStub, previews, machine,
    authorizeClient: request => request.headers.authorization === 'Bearer device', log: () => {} })
  const json = (response, status, value) => { response.writeHead(status, { 'content-type': 'application/json' }); response.end(JSON.stringify(value)) }
  const readJSON = async request => { let text = ''; for await (const chunk of request) text += chunk; return text ? JSON.parse(text) : {} }
  const server = createServer(async (request, response) => {
    const url = new URL(request.url, 'http://localhost')
    try {
      if (await service.handleHost(request, response, url, { readJSON, json })) return
      const administrator = request.headers.authorization === 'Bearer admin', device = request.headers.authorization === 'Bearer device' ? { id: 'd' } : null
      if (await service.handleClient(request, response, url, { readJSON, json, administrator, device })) return
      json(response, 404, { error: 'not_found' })
    } catch (error) { json(response, error.statusCode ?? 500, { error: error.message }) }
  })
  server.on('upgrade', (request, socket, head) => { if (!service.upgrade(request, socket, head)) socket.destroy() })
  port = await listen(server); t.after(() => server.close())
  const call = async (path, { method = 'GET', token = service.hostToken(), body } = {}) => {
    const response = await fetch(`http://127.0.0.1:${port}${path}`, { method, headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' }, body: body ? JSON.stringify(body) : undefined })
    return { status: response.status, body: await response.json() }
  }
  return { service, call, port, memory, keys, credentialsCalls, publishCalls, machine }
}

test('the runtime host API requires its own bearer and serves keys, previews, credentials and entries', async t => {
  const f = await serviceFixture(t), botID = randomUUID()
  assert.equal((await f.call('/v1/bots-host/mcp-keys', { method: 'POST', token: 'admin', body: { botID, botName: 'x' } })).status, 401)
  const key = await f.call('/v1/bots-host/mcp-keys', { method: 'POST', body: { botID, botName: 'Helper' } })
  assert.equal(key.status, 201)
  assert.deepEqual(key.body, { endpoint: 'http://127.0.0.1:1/mcp', token: 'bot-token', principal: `woven:bot:${f.machine.deviceID}:${botID}` })
  assert.equal((await f.call('/v1/bots-host/mcp-keys/' + botID, { method: 'DELETE' })).body.revoked, true)
  const preview = await f.call('/v1/bots-host/previews', { method: 'POST', body: { botID, port: 41000 } })
  assert.equal(preview.body.url, 'https://host.example.ts.net:17000/'); assert.deepEqual(f.publishCalls, [{ botID, port: 41000, containerPort: undefined }])
  assert.equal((await f.call(`/v1/bots-host/previews/${botID}/41000`, { method: 'DELETE' })).body.removed, true)
  const credentials = await f.call('/v1/bots-host/inference-credentials', { method: 'POST', body: { provider: 'anthropic' } })
  assert.equal(credentials.body.credential.type, 'api_key'); assert.deepEqual(f.credentialsCalls, [{ provider: 'anthropic' }])
  const entries = await f.call(`/v1/bots-host/conversations/${botID}/entries`, { method: 'POST', body: { bot: { id: botID, name: 'Helper' }, conversations: [{ conversationId: 'main', kind: 'main' }], entries: [{ id: 'e1', conversationId: 'main', role: 'assistant', text: 'hi' }] } })
  assert.deepEqual(entries.body, { conversations: 1, entries: 1 })
  assert.deepEqual(f.memory.entries(botID).map(entry => entry.id), ['e1'])
})

test('client routes read with device grants, change only as administrator, and report resources', async t => {
  const f = await serviceFixture(t)
  assert.equal((await f.call('/v1/bots/status', { token: 'nobody' })).status, 401)
  const status = await f.call('/v1/bots/status', { token: 'device' })
  assert.equal(status.body.enabled, true); assert.equal(status.body.workspaceEnabled, false); assert.equal(status.body.engine.installed, true)
  const resources = await f.call('/v1/bots/resources', { token: 'device' })
  assert.equal(resources.body.memory.botBytes, 4 * 1024 ** 3)
  assert.equal((await f.call('/v1/bots/resources', { token: 'device', method: 'POST', body: { botMemoryBytes: 1024 ** 3 } })).status, 403)
  assert.equal((await f.call('/v1/bots/resources', { token: 'admin', method: 'POST', body: { botMemoryBytes: 64 * 1024 ** 3 } })).status, 400, 'per-bot RAM must fit the pool')
  const changed = await f.call('/v1/bots/resources', { token: 'admin', method: 'POST', body: { botMemoryBytes: 2 * 1024 ** 3 } })
  assert.equal(changed.body.memory.botBytes, 2 * 1024 ** 3)
  assert.equal((await f.call('/v1/bots/status', { token: 'device' })).body.settings.botMemoryBytes, 2 * 1024 ** 3)
})

test('the runtime starts once the engine finishes installing, and lowering the pool lowers per-bot RAM', async t => {
  let installed = false, starts = 0
  const runtime = { start() { starts++ }, stop: async () => {}, restart: async () => {}, endpoint: () => null, status: () => ({ running: starts > 0 }) }
  const directory = temporary(t)
  const engine = { layout: { socket: '/run/x/docker.sock' }, status: async () => ({ installed, poolBytes: 8 * 1024 ** 3, diskBytes: null }),
    configure: async value => ({ memory: { poolBytes: value.poolBytes }, disk: {} }), resources: async () => ({ memory: {}, disk: {} }) }
  const service = createBotsService({ configuration: { stateDirectory: directory, dataRoot: directory, serviceRoot: directory, botsEnabled: true, workspaceEnabled: true, botsInstance: 'wmtest' },
    engine, runtime, previews: { recover: async () => {}, close: async () => {} }, library: createBotConversationLibrary(createMemoryBotLibraryAdapter()),
    machine: { deviceID: randomUUID(), name: 'box' }, serverPort: () => 1, authorizeClient: () => false, engineWatchMilliseconds: 10, log: () => {} })
  t.after(() => service.close())
  await service.start()
  assert.equal(starts, 0)
  installed = true
  await new Promise(resolve => setTimeout(resolve, 60))
  assert.equal(starts, 1)
  const json = (response, status, value) => { response.statusCode = status; response.value = value }
  const response = {}
  await service.handleClient({ method: 'POST', headers: {} }, response, new URL('http://x/v1/bots/resources'), { readJSON: async () => ({ poolBytes: 2 * 1024 ** 3 }), json, administrator: true, device: null })
  assert.equal(response.statusCode, 200)
  assert.equal(response.value.memory.botBytes, 2 * 1024 ** 3)
})

test('the bots socket requires client authorization and reaches the runtime with the runtime token only', async t => {
  const seen = []
  const runtimeServer = createServer()
  runtimeServer.on('upgrade', (request, socket) => {
    seen.push({ url: request.url, authorization: request.headers.authorization, cookie: request.headers.cookie })
    socket.write('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n')
    socket.on('data', data => socket.write(data))
  })
  const runtimePort = await listen(runtimeServer); t.after(() => runtimeServer.close())
  const runtime = { start() {}, stop: async () => {}, restart: async () => {}, status: () => ({ running: true }), endpoint: () => ({ host: '127.0.0.1', port: runtimePort, token: 'runtime-token' }) }
  const f = await serviceFixture(t, { runtime })
  const handshake = (authorization, extra = '') => new Promise(resolve => {
    const socket = connect(f.port, '127.0.0.1'); let text = ''
    socket.on('data', data => { text += data; if (text.includes('\r\n\r\n')) { if (text.includes('101')) socket.write('echo'); if (!text.includes('101') || text.includes('echo')) { socket.destroy(); resolve(text) } } })
    socket.on('close', () => resolve(text))
    socket.write(`GET /v1/bots/ws?client=mac HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nAuthorization: ${authorization}\r\nCookie: secret\r\n${extra}\r\n`)
  })
  assert.match(await handshake('Bearer nobody'), /401/)
  assert.match(await handshake('Bearer device', 'Origin: https://evil.example\r\n'), /403/)
  assert.match(await handshake('Bearer device'), /101[\s\S]*echo/)
  assert.deepEqual(seen, [{ url: '/ws?client=mac', authorization: 'Bearer runtime-token', cookie: undefined }])
})
