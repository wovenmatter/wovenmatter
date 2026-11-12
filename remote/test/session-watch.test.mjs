import test from 'node:test'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'
import { randomUUID } from 'node:crypto'
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { DatabaseSync } from 'node:sqlite'
import { createClientExecution } from '../src/client-execution.mjs'
import { createLibraryHostSupervisor } from '../src/library-host.mjs'
import { createMemberVerifier } from '../src/member-auth.mjs'
import { createMemberTransport } from '../src/member-client.mjs'
import { createMemberSocketRegistry } from '../src/member-sockets.mjs'
import { createSessionWatch, wakeUpText } from '../src/session-watch.mjs'
import { maximumWaitSeconds, maximumWakeUpsPerRun, streamCapability } from '../src/stream-protocol.mjs'
import { createStreamServer } from '../src/stream-server.mjs'
import { loadWorkspaceMCPCatalog } from '../src/workspace-mcp.mjs'
import { enroll } from './fixtures/execution.mjs'

// Agent-to-agent waiting and wake-ups (docs/architecture/WOVEN_EVERYWHERE.md,
// "Streaming", "Agent to agent"; Swift `SessionWakeUp`).

const fakeHost = resolve(import.meta.dirname, '../test-support/fake-library-host.mjs')
const wakeUpFixtures = new URL('../../shared/Tests/WovenMatterSharedTests/SessionWakeUpFixtures.json', import.meta.url)
const loopback = value => /^http:\/\/127\.0\.0\.1:\d+\//.test(value)
const body = async request => { const chunks = []; for await (const chunk of request) chunks.push(chunk); return Buffer.concat(chunks) }
const send = (response, status, value) => { response.writeHead(status, { 'content-type': 'application/json' }); response.end(JSON.stringify(value)) }
const resultOf = reply => { assert.equal(reply.result.isError, false, JSON.stringify(reply)); return JSON.parse(reply.result.content[0].text) }
const settle = () => new Promise(done => setImmediate(done))
const sleep = milliseconds => new Promise(done => setTimeout(done, milliseconds))
async function until(check, what, timeout = 5_000) {
  for (const deadline = Date.now() + timeout; !(await check());) { assert.ok(Date.now() < deadline, what); await sleep(10) }
}

// A runtime whose turns run until the test ends them, and that asks a
// question when told to.
function workspace(t, { enrolled = true, ...extra } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'woven-session-watch-')), runs = [], live = new Map()
  const runtime = {
    providers: async () => [{ id: 'default_agent', runtimeKind: 'default_agent', available: true, canStart: true }],
    capabilities: async () => ({ canSteer: false }),
    create: async () => ({ sessionID: randomUUID() }),
    run: ({ command, interaction }) => new Promise(done => {
      runs.push(command); live.set(command.runID, done)
      if (command.text.startsWith('Ask first')) interaction({ id: 'question-' + runs.length, kind: 'question', title: 'Which log?', options: [], questions: [{ id: 'log', prompt: 'Which log?', options: ['syslog', 'auth'] }] })
    }),
    respond: async () => {},
    stop: async ({ command }) => { live.get(command.runID)?.(); live.delete(command.runID) },
    close: async () => { for (const done of live.values()) done() },
  }
  const service = createClientExecution({ directory, runtime, managedDataRoot: join(directory, 'databases'), publisherKey: 'k'.repeat(40),
    publisherFetch: async () => { throw new Error('No Mac is reachable.') }, publisherIntervalMilliseconds: 0, extraCapabilities: () => [streamCapability],
    sessionWatchOptions: { retryMilliseconds: 100, lingerMilliseconds: 50, log: () => {}, stream: { timings: { initial: 20, maximum: 200 } } }, ...extra })
  t.after(async () => { await service.close(); rmSync(directory, { recursive: true, force: true }) })
  const finish = runID => { live.get(runID)?.(); live.delete(runID) }
  return { service, runs, live, finish, ...(enrolled ? enroll(service) : {}) }
}
async function conversation(f) {
  const opened = await f.service.command({ commandID: randomUUID(), deviceID: f.principal.id, kind: 'createSession' }, f.principal)
  const scope = f.service.mcp.resolvePrincipal('Bearer ' + f.service.mcp.sessionConnection(opened.conversationID).bearerToken)
  return { id: opened.conversationID, scope, call: (name, input = {}) => f.service.mcp.handle(scope, { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call', params: { name, arguments: input } }) }
}
const sendTo = (f, id, text) => f.service.command({ commandID: randomUUID(), deviceID: f.principal.id, kind: 'send', conversationID: id, text }, f.principal)

async function library(t, directory, environment) {
  const binary = join(directory, 'wovenmatter-library')
  writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${fakeHost}" "$@"\n`); chmodSync(binary, 0o700)
  const host = createLibraryHostSupervisor({ binary, dataRoot: join(directory, 'data'), statePath: join(directory, 'host.json'), environment: { ...process.env, ...environment }, minimumBackoff: 50 })
  t.after(() => host.stop())
  host.start()
  assert.ok(await host.whenReady(10_000))
  return host
}

// Linux L and Linux M, with every Mac offline. M serves its execution API and
// its live stream, verifying L's member signature, as the Node server does.
async function hosts(t, prefix) {
  const directory = mkdtempSync(join('/tmp', prefix))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const m = workspace(t), membersFile = join(directory, 'members.json'), workspacesFile = join(directory, 'workspaces.json')
  const lHost = await library(t, directory, { FAKE_LIBRARY_MEMBERS: membersFile, FAKE_LIBRARY_WORKSPACES: workspacesFile })
  const lIdentity = await lHost.client.identity()
  const offlineMac = { deviceID: randomUUID(), kind: 'mac', name: 'Studio Mac', publicKey: Buffer.alloc(32, 1).toString('base64'), endpoints: ['https://studio.invalid.ts.net:8443/wovenmatter'], revoked: false }
  const mDeviceID = randomUUID()
  writeFileSync(membersFile, JSON.stringify({ revision: '1', members: [{ ...lIdentity, endpoints: [], revoked: false }, offlineMac,
    { deviceID: mDeviceID, kind: 'linux', name: 'Workstation M', publicKey: Buffer.alloc(32, 4).toString('base64'), endpoints: [], revoked: false }] }))
  const verifier = createMemberVerifier({ loadMembers: async () => ({ revision: '1', members: [{ ...lIdentity, revoked: false }] }), audience: mDeviceID })
  t.after(() => verifier.close())
  const mounted = '/wovenmatter-execution/m', reads = []
  const stream = createStreamServer({ members: verifier, servedTargets: async target => [mounted + target], execution: m.service, registry: createMemberSocketRegistry() })
  t.after(() => stream.close())
  const server = createServer(async (request, response) => {
    try {
      const raw = await body(request), url = new URL(request.url.replace(/^\/wovenmatter-execution\/m/, ''), 'http://m'), path = url.pathname
      const member = await verifier.verify({ method: request.method, target: url.pathname + url.search, alternateTargets: [mounted + url.pathname + url.search], headers: request.headers, body: raw })
      reads.push(request.method + ' ' + path)
      const device = { id: member.deviceID, scopes: ['execution'] }
      if (path === '/v1/execution/providers') return send(response, 200, await m.service.providers())
      if (path === '/v1/execution/conversations') return send(response, 200, m.service.conversations())
      if (path === '/v1/execution/interactions') return send(response, 200, m.service.interactions())
      const transcript = path.match(/^\/v1\/execution\/conversations\/([0-9a-f-]+)\/transcript$/)
      if (transcript) return send(response, 200, m.service.transcript(transcript[1], url.searchParams.get('before')))
      const capabilities = path.match(/^\/v1\/execution\/conversations\/([0-9a-f-]+)\/capabilities$/)
      if (capabilities) return send(response, 200, await m.service.capabilities(capabilities[1]))
      if (path === '/v1/execution/commands' && request.method === 'POST') return send(response, 200, await m.service.command(JSON.parse(raw), device))
      send(response, 404, { error: 'not_found' })
    } catch (error) { send(response, error.statusCode ?? 500, { message: error.message }) }
  })
  // Tailscale Serve strips the mount before the request reaches the server.
  server.on('upgrade', (request, socket, head) => {
    request.url = request.url.replace(/^\/wovenmatter-execution\/m/, '')
    if (!stream.upgrade(request, socket, head)) socket.destroy()
  })
  t.after(() => new Promise(closed => { server.closeAllConnections(); server.close(closed) }))
  const port = await new Promise(done => server.listen(0, '127.0.0.1', () => done(server.address().port)))
  const mWorkspace = { id: m.enrollment.workspaceID, libraryID: m.enrollment.libraryID, ownerDeviceID: offlineMac.deviceID, executionDeviceID: mDeviceID, kind: 'linux', name: 'Workstation M',
    endpoint: `http://127.0.0.1:${port}${mounted}/`, capabilities: [streamCapability], journalDeviceIDs: [], revision: 1, deleted: false }
  writeFileSync(workspacesFile, JSON.stringify([mWorkspace]))
  const botDeliveries = []
  const l = workspace(t, { library: { client: lHost.client, available: lHost.available },
    members: { transport: createMemberTransport({ library: lHost.client, allowEndpoint: loopback }), deviceID: () => lIdentity.deviceID, hasMac: () => false },
    deliverBot: async delivery => { botDeliveries.push(delivery); return { conversationId: 1, submissionId: botDeliveries.length } } })
  return { l, m, mWorkspace, lIdentity, stream, reads, botDeliveries }
}

test('wake-up text matches the shared fixtures', () => {
  for (const fixture of JSON.parse(readFileSync(wakeUpFixtures, 'utf8'))) assert.equal(wakeUpText(fixture), fixture.text, fixture.text)
})

test('the bundled catalog serves woven_sessions_wait as the Swift catalog exports it', t => {
  const catalog = loadWorkspaceMCPCatalog(), tool = catalog.find(item => item.name === 'woven_sessions_wait')
  assert.ok(tool, 'woven_sessions_wait is in remote/src/woven-mcp-tools.json')
  assert.deepEqual(tool.inputSchema.required, ['id', 'timeoutSeconds', 'until'])
  assert.deepEqual(tool.inputSchema.properties.until.enum, ['idle', 'needsInput', 'either'])
  assert.equal(tool.inputSchema.properties.timeoutSeconds.maximum, maximumWaitSeconds)
  assert.equal(tool.annotations.readOnlyHint, true)
  assert.match(tool.description, /Prefer this to repeated woven_sessions_status calls/)
  // The export itself: WOVENMATTER_CATALOG_EXPORT names a built WovenMCPCatalogExport.
  const exporter = process.env.WOVENMATTER_CATALOG_EXPORT
  if (!exporter) { t.diagnostic('Set WOVENMATTER_CATALOG_EXPORT to compare with a fresh Swift export (WovenMCPTests compares them in Swift).'); return }
  assert.deepEqual(JSON.parse(execFileSync(exporter, { encoding: 'utf8' })), catalog)
})

test('a wait on this workspace resolves on idle, needsInput and either, and times out', async t => {
  const f = workspace(t)
  const caller = await conversation(f), child = await conversation(f)
  const tools = (await f.service.mcp.handle(caller.scope, { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })).result.tools.map(tool => tool.name)
  assert.ok(tools.includes('woven_sessions_wait'))

  // Already idle: at once.
  const idle = resultOf(await caller.call('woven_sessions_wait', { id: child.id, until: 'idle', timeoutSeconds: 5 }))
  assert.equal(idle.state, 'idle'); assert.equal(idle.timedOut, false)
  assert.equal(idle.rows[0].id, child.id, 'the woven_sessions_status body')

  // Running: the timeout answers with timedOut.
  await sendTo(f, child.id, 'Work for a while')
  const started = Date.now()
  const late = resultOf(await caller.call('woven_sessions_wait', { id: child.id, until: 'idle', timeoutSeconds: 1 }))
  assert.equal(late.state, 'running'); assert.equal(late.timedOut, true)
  assert.ok(Date.now() - started >= 950, 'it waited for the timeout')

  // The turn ends while the call waits.
  const waiting = caller.call('woven_sessions_wait', { id: child.id, until: 'idle', timeoutSeconds: 10 })
  await sleep(50)
  f.finish(f.runs.at(-1).runID)
  const finished = resultOf(await waiting)
  assert.equal(finished.state, 'idle'); assert.equal(finished.timedOut, false)

  // A question: needsInput, and either.
  const asking = caller.call('woven_sessions_wait', { id: child.id, until: 'needsInput', timeoutSeconds: 10 })
  await sleep(50)
  await sendTo(f, child.id, 'Ask first, then work')
  const asked = resultOf(await asking)
  assert.equal(asked.state, 'needsInput'); assert.equal(asked.timedOut, false)
  const either = resultOf(await caller.call('woven_sessions_wait', { id: child.id, until: 'either', timeoutSeconds: 10 }))
  assert.equal(either.state, 'needsInput'); assert.equal(either.timedOut, false)
  f.finish(f.runs.at(-1).runID)
  await until(() => !f.service.summary(child.id).conversation.activeRunID, 'the question run ended')
  await sendTo(f, child.id, 'One more turn')
  const any = caller.call('woven_sessions_wait', { id: child.id, until: 'either', timeoutSeconds: 10 })
  await sleep(50)
  f.finish(f.runs.at(-1).runID)
  assert.equal(resultOf(await any).state, 'idle')

  // Bounded by the catalog.
  const refused = await caller.call('woven_sessions_wait', { id: child.id, until: 'idle', timeoutSeconds: maximumWaitSeconds + 1 })
  assert.ok(refused.error, JSON.stringify(refused))
})

test('a wait on another workspace resolves through the destination\'s stream without polling', async t => {
  const { l, m, mWorkspace, stream, reads } = await hosts(t, 'wm-wait-')
  const caller = await conversation(l)
  const child = resultOf(await caller.call('woven_sessions_create', { workspace: mWorkspace.id, title: 'Index the logs', text: 'Ask first, then summarize', purpose: 'triage', requestID: randomUUID() })).session
  const asked = resultOf(await caller.call('woven_sessions_wait', { id: child.id, until: 'needsInput', timeoutSeconds: 10 }))
  assert.equal(asked.state, 'needsInput'); assert.equal(asked.session.workspace, mWorkspace.id); assert.equal(asked.pending[0].title, 'Which log?')
  resultOf(await caller.call('woven_sessions_respond', { id: child.id, interaction: asked.pending[0].id, answers: { log: ['auth'] }, requestID: randomUUID() }))
  await until(() => stream.connections() === 1, 'L holds one stream to M')

  // While it waits, M is only read once more: when the stream says the turn ended.
  const before = reads.filter(entry => entry === 'GET /v1/execution/conversations').length
  const waiting = caller.call('woven_sessions_wait', { id: child.id, until: 'idle', timeoutSeconds: 20 })
  await sleep(1_200)
  assert.equal(reads.filter(entry => entry === 'GET /v1/execution/conversations').length, before + 1, 'one read when the wait began, no polling')
  m.finish(m.runs.at(-1).runID)
  const finished = resultOf(await waiting)
  assert.equal(finished.state, 'idle'); assert.equal(finished.timedOut, false)
  assert.equal(finished.session.id, child.id)
  assert.equal(reads.filter(entry => entry === 'GET /v1/execution/conversations').length, before + 2)
  assert.equal(stream.connections(), 1, 'still one stream')
})

test('a scheduled task waits on this server, never on a Mac', async t => {
  const f = workspace(t)
  const owner = await conversation(f), child = await conversation(f)
  const run = { id: randomUUID(), sessionID: owner.id, eventID: randomUUID(), task: { configuration: { tools: { enabled: ['sessions'] } } } }
  const connection = await f.service.prepareTaskMCP({ run, eventRevision: 1 })
  const scope = f.service.mcp.resolvePrincipal('Bearer ' + connection.bearerToken)
  const tools = (await f.service.mcp.handle(scope, { jsonrpc: '2.0', id: 1, method: 'tools/list' })).result.tools.map(tool => tool.name)
  assert.ok(tools.includes('woven_sessions_wait'))
  await sendTo(f, child.id, 'Work for a while')
  const waiting = f.service.mcp.handle(scope, { jsonrpc: '2.0', id: 2, method: 'tools/call', params: { name: 'woven_sessions_wait', arguments: { id: child.id, until: 'idle', timeoutSeconds: 10 } } })
  await sleep(50)
  f.finish(f.runs.at(-1).runID)
  const waited = resultOf(await waiting)
  assert.equal(waited.state, 'idle'); assert.equal(waited.timedOut, false)
})

test('a finished session wakes its idle caller, and waits while the caller runs', async t => {
  const { l, m, mWorkspace } = await hosts(t, 'wm-wake-')
  const caller = await conversation(l)
  const child = resultOf(await caller.call('woven_sessions_create', { workspace: mWorkspace.id, title: 'Index the logs', text: 'Summarize', purpose: 'triage', requestID: randomUUID() })).session
  await until(() => m.runs.length === 1, 'M runs the session')

  // The caller is busy with a turn of its own when the session finishes.
  await sendTo(l, caller.id, 'Keep busy')
  await until(() => l.runs.length === 1, 'the caller runs')
  m.finish(m.runs[0].runID)
  await until(() => l.service.summary(caller.id) && !m.service.summary(child.id).conversation.activeRunID, 'the session finished')
  await sleep(300)
  assert.equal(l.runs.length, 1, 'a running caller is not woken')

  // Its turn ends: the wake-up starts the next one.
  l.finish(l.runs[0].runID)
  await until(() => l.runs.length === 2, 'the idle caller was woken')
  const wake = l.runs[1]
  assert.equal(wake.conversationID, caller.id)
  assert.equal(wake.text.split('\n\n')[0].trim().startsWith(`Your session "Index the logs" (${child.id}) on Workstation M finished.`), true, wake.text)
  const message = l.service.record(caller.id).transcript.messages.find(item => item.role === 'user' && item.runID === wake.runID)
  assert.equal(message.agentSourceID, child.id); assert.equal(message.senderKind, 'notification')

  // A question wakes it too, once it is idle again.
  l.finish(wake.runID)
  await until(() => !l.service.summary(caller.id).conversation.activeRunID, 'the woken turn ended')
  resultOf(await caller.call('woven_sessions_send', { id: child.id, text: 'Ask first, then the rest', requestID: randomUUID() }))
  await until(() => l.runs.length === 3, 'woken by the question')
  assert.match(l.runs[2].text, /is waiting for your answer: Which log\? Read it with woven_sessions_status and answer with woven_sessions_respond\./)

  // Reading the state first means no wake-up for it.
  l.finish(l.runs[2].runID)
  await until(() => !l.service.summary(caller.id).conversation.activeRunID, 'that turn ended')
  await sendTo(l, caller.id, 'Busy again')
  await until(() => l.runs.length === 4, 'the caller runs')
  m.finish(m.runs.at(-1).runID)
  await until(() => !m.service.summary(child.id).conversation.activeRunID, 'the session finished again')
  await sleep(200)
  assert.equal(resultOf(await caller.call('woven_sessions_status', { id: child.id })).session.state, 'idle')
  l.finish(l.runs[3].runID)
  await sleep(400)
  assert.equal(l.runs.length, 4, 'the caller saw it finish, so it is not woken')
})

test('a bot is woken through the bots runtime', async t => {
  const { l, m, mWorkspace, lIdentity, botDeliveries } = await hosts(t, 'wm-wakebot-')
  const botID = randomUUID()
  const key = l.service.mcp.issueBotKey({ botID, botName: 'Ops', deviceID: lIdentity.deviceID })
  const scope = l.service.mcp.resolvePrincipal('Bearer ' + key.bearerToken)
  const call = (name, input = {}) => l.service.mcp.handle(scope, { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call', params: { name, arguments: input } })
  const tools = (await l.service.mcp.handle(scope, { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })).result.tools.map(tool => tool.name)
  assert.ok(tools.includes('woven_sessions_wait'), 'bots wait too')
  const child = resultOf(await call('woven_sessions_create', { workspace: mWorkspace.id, title: 'Remote job', text: 'Work remotely', purpose: 'p', requestID: randomUUID() })).session
  await until(() => m.runs.length === 1, 'M runs it')
  const waited = call('woven_sessions_wait', { id: child.id, until: 'idle', timeoutSeconds: 10 })
  await sleep(100)
  m.finish(m.runs[0].runID)
  assert.equal(resultOf(await waited).state, 'idle')
  await sleep(300)
  assert.equal(botDeliveries.length, 0, 'the wait already told the bot')

  resultOf(await call('woven_sessions_send', { id: child.id, text: 'Again', requestID: randomUUID() }))
  await until(() => m.runs.length === 2, 'M runs it again')
  m.finish(m.runs[1].runID)
  await until(() => botDeliveries.length === 1, 'the bot was woken')
  assert.equal(botDeliveries[0].botID, botID)
  assert.match(botDeliveries[0].text, /^Your session "Remote job" \(.+\) on Workstation M finished\./)
})

// The coordinator alone, with a source the test drives.
function coordinator(t, { db = new DatabaseSync(':memory:'), runs } = {}) {
  const sources = [], delivered = [], bots = []
  const callers = runs ?? new Map()
  const watch = createSessionWatch({ db, retryMilliseconds: 50, lingerMilliseconds: 10_000,
    sourceFor: async () => {
      const listeners = new Set()
      const source = { listen: fn => { listeners.add(fn); return () => listeners.delete(fn) }, track: () => () => {}, sync() {}, retry() {}, ready: () => true, close() {},
        emit: (id, state, extra = {}) => { for (const fn of listeners) fn(id, { state, conversation: { id, ...(extra.title ? { title: extra.title } : {}), ...(state === 'running' ? { activeRunID: extra.runID ?? 'remote-run' } : {}) }, pending: extra.pending ?? [] }) } }
      sources.push(source)
      return source
    },
    caller: id => id.startsWith('woven:bot:') ? { kind: 'bot', botID: id.split(':').at(-1) } : callers.get(id) ?? null,
    deliverToConversation: async input => {
      const state = callers.get(input.callerID)
      if (!state.idle) return { status: 'rejected', message: 'This conversation is already running.' }
      const runID = 'wake-' + (delivered.length + 1)
      delivered.push(input); state.idle = false; state.latestRunID = runID
      return { status: 'accepted', commandID: input.commandID, runID }
    },
    deliverToBot: async input => { bots.push(input) } })
  t.after(() => watch.close())
  const remember = (id, callerID) => db.prepare('INSERT INTO member_sessions VALUES (?,?,?,?)').run(id, callerID, 'w1', new Date().toISOString())
  return { db, watch, sources, delivered, bots, callers, remember }
}
const workspaceW1 = { id: 'w1', name: 'Workstation W' }

test('at most ten wake-ups per calling run, and a run started another way counts again', async t => {
  const { watch, sources, delivered, callers, remember } = coordinator(t)
  const callerID = randomUUID(), sessionID = randomUUID()
  callers.set(callerID, { kind: 'conversation', idle: true, latestRunID: 'user-run' })
  remember(sessionID, callerID)
  for (let round = 1; round <= maximumWakeUpsPerRun + 2; round++) {
    // The (woken) caller gives the session more work, then its turn ends.
    watch.observe({ callerID, workspace: workspaceW1, id: sessionID, state: 'running', runID: 'remote-' + round })
    await until(() => sources.length === 1, 'a source for w1')
    callers.get(callerID).idle = true
    sources[0].emit(sessionID, 'idle')
    await sleep(30)
  }
  assert.equal(delivered.length, maximumWakeUpsPerRun)
  assert.ok(!delivered[maximumWakeUpsPerRun - 2].text.includes('last wake-up'))
  assert.match(delivered[maximumWakeUpsPerRun - 1].text, /This is your last wake-up/)
  assert.equal(new Set(delivered.map(item => item.commandID)).size, delivered.length, 'one command per wake-up')
  assert.deepEqual(watch.pending(callerID), [], 'the eleventh was dropped')

  // The user starts the caller again: a new count.
  callers.get(callerID).latestRunID = 'user-run-2'
  watch.observe({ callerID, workspace: workspaceW1, id: sessionID, state: 'running', runID: 'remote-x' })
  sources[0].emit(sessionID, 'idle')
  await until(() => delivered.length === maximumWakeUpsPerRun + 1, 'woken again after a run the user started')
})

test('wake-ups wait for an idle caller, give way to newer states, and survive a restart', async t => {
  const directory = mkdtempSync(join(tmpdir(), 'woven-session-watch-db-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const db = new DatabaseSync(join(directory, 'execution.sqlite'))
  t.after(() => db.close())
  const callers = new Map(), callerID = randomUUID(), sessionID = randomUUID(), other = randomUUID()
  callers.set(callerID, { kind: 'conversation', idle: false, latestRunID: 'user-run' })
  const first = coordinator(t, { db, runs: callers })
  first.remember(sessionID, callerID); first.remember(other, callerID)
  first.watch.observe({ callerID, workspace: workspaceW1, id: sessionID, title: 'Index', state: 'running', runID: 'r1' })
  first.watch.observe({ callerID, workspace: workspaceW1, id: other, title: 'Other', state: 'running', runID: 'r2' })
  await until(() => first.sources.length === 1, 'a source for w1')

  // A question while the caller runs: held. The session runs on: dropped.
  first.sources[0].emit(sessionID, 'needsInput', { pending: [{ id: 'q1', title: 'Which log?' }] })
  await sleep(50)
  assert.equal(first.delivered.length, 0, 'a running caller is not woken')
  assert.equal(first.watch.pending(callerID).length, 1)
  first.sources[0].emit(sessionID, 'running', { runID: 'r1' })
  await settle()
  assert.equal(first.watch.pending(callerID).length, 0, 'superseded by running again')

  // Finished while the caller runs; then the newer state of another wins nothing over it.
  first.sources[0].emit(sessionID, 'idle')
  await settle()
  assert.equal(first.watch.pending(callerID)[0].kind, 'finished')
  // A sessions the caller did not create is never watched.
  first.watch.observe({ callerID: randomUUID(), workspace: workspaceW1, id: other, state: 'running' })
  assert.equal(first.watch.watched().find(row => row.id === other).caller, callerID)

  // Restart: a new coordinator on the same database delivers what was pending
  // and compares the stream's snapshot with what it stored.
  first.watch.close()
  const second = coordinator(t, { db, runs: callers })
  callers.get(callerID).idle = true
  second.watch.start()
  await until(() => second.delivered.length === 1, 'the pending wake-up survived the restart')
  assert.match(second.delivered[0].text, /^Your session "Index" .* finished\./)
  callers.get(callerID).idle = true
  await until(() => second.sources.length === 1, 'watching again after the restart')
  second.sources[0].emit(other, 'idle')
  await until(() => second.delivered.length === 2, 'a session that finished meanwhile wakes its caller')
  assert.match(second.delivered[1].text, /"Other"/)
  assert.deepEqual(second.watch.watched(), [], 'nothing is watched once both finished')
})

test('a bot\'s wake-ups count again when it creates a session', async t => {
  const { watch, sources, bots, remember } = coordinator(t)
  const callerID = `woven:bot:${randomUUID()}:${randomUUID()}`, sessionID = randomUUID()
  remember(sessionID, callerID)
  for (let round = 0; round < maximumWakeUpsPerRun + 1; round++) {
    watch.observe({ callerID, workspace: workspaceW1, id: sessionID, state: 'running', runID: 'r' + round })
    await until(() => sources.length === 1, 'a source')
    sources[0].emit(sessionID, 'idle')
    await sleep(20)
  }
  assert.equal(bots.length, maximumWakeUpsPerRun)
  assert.match(bots.at(-1).text, /last wake-up/)
  watch.observe({ callerID, workspace: workspaceW1, id: sessionID, state: 'running', runID: 'new', created: true })
  sources[0].emit(sessionID, 'idle')
  await until(() => bots.length === maximumWakeUpsPerRun + 1, 'a created session starts a new count')
})
