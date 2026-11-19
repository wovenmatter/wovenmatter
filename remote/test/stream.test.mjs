import test from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { createServer, request as httpRequest } from 'node:http'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { createBotConversationLibrary, createMemoryBotLibraryAdapter } from '../src/bots-library.mjs'
import { createBotsService } from '../src/bots-service.mjs'
import { createClientExecution } from '../src/client-execution.mjs'
import { createMemberVerifier, privateKeyFromSeed, rawPublicKeyFor, signMemberRequest } from '../src/member-auth.mjs'
import { authenticateMemberUpgrade, authorizeBotsUpgrade, createMemberSocketRegistry } from '../src/member-sockets.mjs'
import { createInstallerBearer } from '../src/installer-bearer.mjs'
import { createStreamClient } from '../src/stream-client.mjs'
import { decodeFrame, encodeFrame, StreamFrameError, streamCapability } from '../src/stream-protocol.mjs'
import { createOutboundQueue, createStreamServer } from '../src/stream-server.mjs'
import { WebSocket, WebSocketServer, webSocketPackageOwner } from '../src/websocket.mjs'
import { enroll } from './fixtures/execution.mjs'

// The live stream (docs/architecture/WOVEN_EVERYWHERE.md, "Streaming").

const fixturesPath = new URL('../../shared/Tests/WovenMatterSharedTests/StreamProtocolFixtures.json', import.meta.url)
const prefix = '/wovenmatter-execution/box'
const streamTarget = prefix + '/stream'
const settle = () => new Promise(resolve => setImmediate(resolve))
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)))
async function eventually(condition, message, timeout = 10_000) {
  for (const deadline = Date.now() + timeout; !condition();) {
    assert.ok(Date.now() < deadline, message)
    await new Promise(resolve => setTimeout(resolve, 5))
  }
}

// Coalescing timers on a clock the test moves.
function fakeClock() {
  let now = 0
  const timers = new Set()
  return {
    now: () => now,
    setTimeout: (callback, milliseconds) => { const timer = { at: now + Math.max(0, milliseconds), callback }; timers.add(timer); return timer },
    clearTimeout: timer => { timers.delete(timer) },
    async advance(milliseconds) {
      const end = now + milliseconds
      for (;;) {
        const due = [...timers].filter(timer => timer.at <= end).sort((a, b) => a.at - b.at)[0]
        if (!due) break
        timers.delete(due); now = due.at; due.callback(); await settle()
      }
      now = end
      await settle()
    },
  }
}

const memberEntry = (member, extra = {}) => ({ deviceID: member.deviceID, kind: member.kind, name: member.name ?? 'Studio',
  publicKey: rawPublicKeyFor(member.key).toString('base64'), endpoints: [], revoked: false, ...extra })

// The library host's change cursor as library-host.mjs reports it.
function libraryFeed(initial = null) {
  let cursor = initial
  const listeners = new Set()
  return { cursor: () => cursor, watch: listener => { listeners.add(listener); return () => listeners.delete(listener) },
    set(value) { cursor = value; for (const listener of listeners) listener(value) }, listeners }
}

async function fixture(t, { clock, limits, timings, refreshMilliseconds = 15_000, library = null } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'wm-stream-')), runs = []
  const provider = { id: 'default_agent', runtimeKind: 'default_agent', displayName: 'Pi Durable', routeName: 'This workspace', available: true, canStart: true,
    canResume: true, canSteer: true, canStop: true, supportsApprovals: false, supportsQuestions: false, activeInputMode: 'steer' }
  // Session settings live in the runtime, outside the record, as OpenCode's do.
  const configured = new Map(), models = [{ id: 'small', label: 'Small' }, { id: 'large', label: 'Large' }]
  const runtime = { providers: async () => [provider], create: async () => ({ sessionID: randomUUID() }),
    settings: async ({ native }) => ({ model: configured.get(native.sessionID)?.model ?? 'small', thinking: configured.get(native.sessionID)?.thinking ?? null,
      permission: null, models, thinkingLevels: [], permissions: [], availableTools: [], enabledTools: [], canConfigure: true }),
    configure: async ({ native, options }) => { configured.set(native.sessionID, { ...configured.get(native.sessionID), ...Object.fromEntries(Object.entries(options).filter(([key, value]) => key !== 'id' && value != null)) }) },
    run: async input => { const done = Promise.withResolvers(); runs.push({ ...input, done }); await done.promise },
    stop: async ({ command }) => runs.find(item => item.command.runID === command.runID)?.done.resolve(),
    respond: async () => {}, steer: async () => {}, close: async () => { for (const run of runs) run.done.resolve() } }
  const execution = createClientExecution({ directory, runtime, extraCapabilities: () => [streamCapability] })
  const { enrollment } = enroll(execution)
  const host = randomUUID(), mac = { deviceID: randomUUID(), key: privateKeyFromSeed(Buffer.alloc(32, 7)), kind: 'mac' }
  const list = { value: { revision: '1', members: [memberEntry(mac)] } }
  const verifier = createMemberVerifier({ audience: host, loadMembers: async () => list.value, refreshMilliseconds })
  const registry = createMemberSocketRegistry()
  verifier.watch(members => registry.sweep(members))
  const servedTargets = async target => [prefix + target]
  const stream = createStreamServer({ members: verifier, servedTargets, execution, registry, library, ...(clock ? { clock } : {}), limits, timings })
  const upgrades = [stream.upgrade]
  const server = createServer((_, response) => { response.writeHead(404); response.end() })
  server.on('upgrade', (request, socket, head) => { if (!upgrades.some(handler => handler(request, socket, head))) socket.destroy() })
  const port = await listen(server)
  const sockets = [], connections = new Set()
  server.on('connection', socket => { connections.add(socket); socket.on('close', () => connections.delete(socket)) })
  t.after(async () => {
    for (const socket of sockets) socket.terminate()
    for (const socket of connections) socket.destroy()
    await stream.close(); verifier.close()
    await new Promise(resolve => server.close(resolve))
    await execution.close(); rmSync(directory, { recursive: true, force: true })
  })
  const signed = (target = streamTarget, options = {}, member = mac) => signMemberRequest({ deviceID: member.deviceID, privateKey: member.key, audience: host, method: 'GET', target, ...options })
  const command = (kind, values = {}) => ({ commandID: randomUUID(), deviceID: mac.deviceID, libraryID: enrollment.libraryID, workspaceID: enrollment.workspaceID, kind, ...values })
  const device = { id: mac.deviceID }
  function connect(headers = signed(), options = {}) {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/stream`, { headers, ...options })
    sockets.push(socket)
    return frameReader(socket)
  }
  async function session() {
    const opened = await execution.command(command('createSession'), device)
    return opened.conversationID
  }
  return { execution, enrollment, runs, host, mac, list, verifier, registry, stream, server, port, upgrades, servedTargets, sockets, signed, command, device, connect, session }
}

// Collects a socket's frames; `next` takes the first unread one that matches.
function frameReader(socket) {
  const frames = [], read = new Set(), waiters = []
  socket.on('message', data => { frames.push(JSON.parse(String(data))); for (const waiter of waiters.splice(0)) waiter() })
  socket.on('error', () => {})
  const closed = new Promise(resolve => socket.on('close', (code, reason) => resolve({ code, reason: String(reason) })))
  const opened = new Promise((resolve, reject) => { socket.once('open', resolve); socket.once('unexpected-response', (_, response) => reject(new Error('refused ' + response.statusCode))) })
  async function next(predicate = () => true, timeout = 10_000) {
    const deadline = Date.now() + timeout
    for (;;) {
      const index = frames.findIndex((frame, position) => !read.has(position) && predicate(frame))
      if (index >= 0) { read.add(index); return frames[index] }
      const remaining = deadline - Date.now()
      if (remaining <= 0) throw new Error('No matching frame among ' + JSON.stringify(frames.map(frame => [frame.t, frame.kind, frame.id])))
      await new Promise(resolve => { const timer = setTimeout(resolve, remaining); waiters.push(() => { clearTimeout(timer); resolve() }) })
    }
  }
  const send = frame => socket.send(JSON.stringify(frame))
  const unread = predicate => frames.filter((frame, position) => !read.has(position) && predicate(frame))
  let requests = 0
  const request = async (method, params) => { const id = 'r' + ++requests; send({ t: 'req', id, method, params }); return next(frame => frame.t === 'res' && frame.id === id) }
  return { socket, frames, next, send, unread, closed, opened, request }
}

// A raw upgrade request: the refusal's status and JSON body, or 101.
function handshake(port, { path = '/stream', headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const request = httpRequest({ host: '127.0.0.1', port, path, headers: { connection: 'Upgrade', upgrade: 'websocket',
      'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==', 'sec-websocket-version': '13', ...headers } })
    request.on('response', response => {
      let body = ''
      response.on('data', chunk => { body += chunk })
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: body ? JSON.parse(body) : null }))
    })
    request.on('upgrade', (_, socket) => { socket.destroy(); resolve({ status: 101 }) })
    request.on('error', reject)
    request.end()
  })
}

const isItem = (kind, id) => frame => frame.t === 'item' && frame.kind === kind && (id === undefined || frame.id === id)

test('ws comes from the Built-in agent graph: one declared, locked selection', () => {
  const owner = JSON.parse(readFileSync(webSocketPackageOwner, 'utf8'))
  const lock = JSON.parse(readFileSync(new URL('package-lock.json', webSocketPackageOwner), 'utf8'))
  assert.equal(owner.name, 'wovenmatter-default-agent')
  assert.match(owner.dependencies.ws, /^>=\d+\.\d+\.\d+$/)
  const installed = JSON.parse(readFileSync(new URL('node_modules/ws/package.json', webSocketPackageOwner), 'utf8'))
  assert.equal(installed.version, lock.packages['node_modules/ws'].version)
  assert.equal(typeof WebSocketServer, 'function')
})

test('every shared stream fixture decodes and re-encodes to the same JSON', () => {
  const fixtures = JSON.parse(readFileSync(fixturesPath, 'utf8'))
  const types = new Set(), kinds = new Set()
  for (const { name, frame } of fixtures.frames) {
    const decoded = decodeFrame(JSON.stringify(frame))
    types.add(decoded.t); if (decoded.t === 'item') kinds.add(decoded.kind)
    assert.deepEqual(JSON.parse(encodeFrame(decoded)), frame, `${name} did not round-trip`)
  }
  // Every frame type and item kind the protocol defines, as the Swift suite lists them.
  assert.deepEqual([...types].sort(), ['cancel', 'end', 'hello', 'item', 'req', 'res', 'sub'])
  assert.deepEqual([...kinds].sort(), ['capabilities', 'conversations', 'journal', 'library', 'owner', 'pending', 'server.state', 'session', 'synchronized', 'transcript'])
  // The length-prefixed form is the Mac window's Unix socket; its JSON is still one frame.
  assert.deepEqual(JSON.parse(Buffer.from(fixtures.lengthPrefixed.hex, 'hex').subarray(4).toString('utf8')), fixtures.lengthPrefixed.frame)
  assert.throws(() => encodeFrame({ t: 'item', id: 's', kind: 'server.state', data: { scopes: ['x'.repeat(64)] } }, { maximumBytes: 32 }), StreamFrameError)
})

test('a frame the protocol does not define is refused, read or written', () => {
  const journal = { eventID: 'e', workspaceID: 'w', conversationID: 'c', kind: 'conversation', originSequence: 1 }
  const refused = [
    // The frames the Swift suite refuses (`aFrameThisBuildDoesNotDefineIsRefused`).
    '{"t":"futureFrame","id":"x1"}',
    '{"t":"item","id":"s1","seq":43,"kind":"futureKind","data":{"anything":true}}',
    '{"t":"item","id":"s2","kind":"transcript","data":{"transcript":{"conversationID":7},"snapshot":true}}',
    '{', '{"id":"s1","kind":"journal"}', '{"t":"item","kind":"journal","data":{}}',
    // A key its type or kind requires is missing or of another type.
    'not json', '[]', '{"t":7}', '{"t":"req"}', '{"t":"req","id":"r","method":"execution.receipt"}',
    '{"t":"sub","id":"s","stream":"workspace"}', '{"t":"sub","id":"s","stream":"workspace","params":{"after":"1"}}',
    '{"t":"sub","id":"s","stream":"conversation","params":{"conversationID":7}}',
    '{"t":"res","id":"r","error":{"code":"invalid","message":"No."}}', '{"t":"end","id":"s","error":{"code":"resync"}}',
    '{"t":"hello","deviceID":"d","libraryID":"l","workspaceID":"w","serverTime":1,"maxFrameBytes":1}',
    '{"t":"item","id":"s","kind":"constructor","data":{}}', '{"t":"item","id":"s","kind":"pending"}',
    '{"t":"item","id":"s","kind":"pending","data":{"interactions":[{"id":"i"}]}}',
    '{"t":"item","id":"s","kind":"conversations","data":{"conversations":[]}}',
    '{"t":"item","id":"s","kind":"conversations","data":{"conversations":[{"title":"No ID"}],"snapshot":true}}',
    '{"t":"item","id":"s","kind":"conversations","data":{"conversations":[],"deletedConversationIDs":[7],"snapshot":false}}',
    JSON.stringify({ t: 'item', id: 's', seq: 1, kind: 'journal', data: { entry: { ...journal, originSequence: '1' } } }),
    '{"t":"item","id":"s","kind":"transcript","data":{"transcript":{"conversationID":"c","messages":[]},"snapshot":true}}',
    '{"t":"item","id":"s","kind":"capabilities","data":{}}', '{"t":"item","id":"s","kind":"session","data":{"settings":[]}}',
    '{"t":"item","id":"s","kind":"owner","data":{}}', '{"t":"item","id":"s","kind":"library","data":{"cursor":"1"}}',
    '{"t":"item","id":"s","kind":"server.state","data":{}}',
  ]
  for (const frame of refused) {
    assert.throws(() => decodeFrame(frame), StreamFrameError, frame)
    let value
    try { value = JSON.parse(frame) } catch { continue }
    assert.throws(() => encodeFrame(value), StreamFrameError, frame)
  }
  // A key a frame does not define is not kept, and an absent optional one is not written.
  assert.deepEqual(decodeFrame('{"t":"sub","id":"s","stream":"workspace","params":{"after":null,"later":1},"extra":true}'), { t: 'sub', id: 's', stream: 'workspace', params: {} })
  assert.deepEqual(decodeFrame(JSON.stringify({ t: 'item', id: 's', seq: 1, kind: 'journal', data: { entry: journal, extra: true } })), { t: 'item', id: 's', seq: 1, kind: 'journal', data: { entry: journal } })
  assert.deepEqual(decodeFrame('{"t":"item","id":"s","kind":"synchronized"}'), { t: 'item', id: 's', kind: 'synchronized', data: {} })
})

test('the outbound queue supersedes queued entities and ends an overflowing subscription with resync', async () => {
  const sent = [], overflowed = []
  const queue = createOutboundQueue({ limits: { items: 3, bytes: 4096, inflightBytes: 1, frameBytes: 8 * 1024 * 1024 },
    send: (text, done) => sent.push({ text, done }), overflow: subscription => { overflowed.push(subscription.id); subscription.ended = true; queue.enqueue({ t: 'end', id: subscription.id, error: { code: 'resync', message: 'Subscribe again.', retryable: true } }) } })
  const a = { id: 'a', ended: false }, b = { id: 'b', ended: false }
  const replace = (_, next) => next
  // The first item is in flight and never acknowledged: the client stopped reading.
  queue.enqueue({ t: 'item', id: 'a', kind: 'pending', data: { interactions: [] } }, { subscription: a })
  assert.equal(sent.length, 1)
  for (let index = 0; index < 10; index++) queue.enqueue({ t: 'item', id: 'b', kind: 'library', data: { cursor: index } }, { subscription: b, key: 'library', merge: replace })
  assert.deepEqual(queue.size().items, 1, 'updates to one entity supersede the queued one')
  const journal = seq => ({ t: 'item', id: 'a', kind: 'journal', seq, data: { entry: { eventID: 'e' + seq, workspaceID: 'w', conversationID: 'c', kind: 'conversation', originSequence: seq } } })
  for (const seq of [1, 2, 3]) queue.enqueue(journal(seq), { subscription: a })
  assert.deepEqual(overflowed, ['a'])
  // Responses always go out.
  assert.equal(queue.enqueue({ t: 'res', id: 'r1', result: null }), true)
  // Acknowledge everything: what remains is b's latest update, a's end, and the response.
  while (sent.some(entry => !entry.acknowledged)) { const entry = sent.find(item => !item.acknowledged); entry.acknowledged = true; entry.done() }
  const frames = sent.slice(1).map(entry => JSON.parse(entry.text))
  assert.deepEqual(frames.map(frame => [frame.t, frame.id]), [['item', 'b'], ['end', 'a'], ['res', 'r1']])
  assert.equal(frames[0].data.cursor, 9)
  assert.equal(frames[1].error.code, 'resync'); assert.equal(frames[1].error.retryable, true)
  // A large first item still goes out alone.
  assert.equal(queue.enqueue({ t: 'item', id: 'b', kind: 'server.state', data: { scopes: ['x'.repeat(10_000)] } }, { subscription: b }), true)
  // A frame the protocol does not define is never queued.
  assert.equal(queue.enqueue({ t: 'item', id: 'b', kind: 'noSuchKind', data: {} }, { subscription: b }), false)
})

test('the stream upgrade refuses a query, stale clocks, bearers and browsers before upgrading', async t => {
  const f = await fixture(t)
  // The stream takes no query at all, whatever it says and however it is signed.
  let refused
  for (const query of ['?stream=workspace', '?x=1', '?']) {
    refused = await handshake(f.port, { path: '/stream' + query, headers: f.signed(prefix + '/stream' + query) })
    assert.deepEqual([refused.status, refused.body.code], [400, 'bad_request'], query)
  }
  const stale = await handshake(f.port, { headers: f.signed(streamTarget, { time: Date.now() - 400_000 }) })
  assert.deepEqual([stale.status, stale.body.code, typeof stale.body.serverTime], [401, 'member_time_stale', 'number'])
  assert.ok(Math.abs(stale.body.serverTime - Date.now()) < 60_000)
  for (const headers of [{}, { authorization: 'Bearer ' + 'i'.repeat(43) }, f.signed(streamTarget, { audience: randomUUID() }),
    f.signed(prefix + '/streams')]) {
    const result = await handshake(f.port, { headers })
    assert.deepEqual([result.status, result.body.code], [401, 'unauthorized'], JSON.stringify(Object.keys(headers)))
  }
  const stranger = { deviceID: randomUUID(), key: privateKeyFromSeed(Buffer.alloc(32, 3)), kind: 'ios' }
  assert.equal((await handshake(f.port, { headers: f.signed(streamTarget, {}, stranger) })).status, 401, 'a device that is not a member')
  assert.equal((await handshake(f.port, { headers: { ...f.signed(), origin: 'https://evil.example' } })).status, 403)
  assert.equal((await handshake(f.port, { headers: { ...f.signed(), cookie: 'session=1' } })).status, 403)
  // Every refusal repeats its code in X-Woven-Error and carries a Date, for
  // clients that cannot read a refused upgrade's body.
  const browser = await handshake(f.port, { headers: { ...f.signed(), origin: 'https://evil.example' } })
  const unsigned = await handshake(f.port, {})
  for (const [result, code] of [[refused, 'bad_request'], [stale, 'member_time_stale'], [browser, 'browser_request'], [unsigned, 'unauthorized']]) {
    assert.equal(result.headers['x-woven-error'], code)
    assert.equal(result.body.code, code)
    assert.ok(Math.abs(Date.parse(result.headers.date) - Date.now()) < 60_000, 'a Date header')
  }
  // Signed for the path the member sent, or as this server saw it.
  assert.equal((await handshake(f.port, { headers: f.signed() })).status, 101)
  assert.equal((await handshake(f.port, { headers: f.signed('/stream') })).status, 101)
  const replay = f.signed()
  assert.equal((await handshake(f.port, { headers: replay })).status, 101)
  assert.equal((await handshake(f.port, { headers: replay })).status, 401, 'an upgrade cannot be replayed')
  // Hello names this server's member device, its library and workspace.
  const client = f.connect()
  const hello = await client.next(frame => frame.t === 'hello')
  assert.deepEqual(Object.keys(hello), ['t', 'deviceID', 'libraryID', 'workspaceID', 'serverTime', 'capabilities', 'maxFrameBytes'])
  assert.deepEqual([hello.deviceID, hello.libraryID, hello.workspaceID, hello.maxFrameBytes], [f.host, f.enrollment.libraryID, f.enrollment.workspaceID, 8 * 1024 * 1024])
  assert.ok(hello.capabilities.includes('stream'))
  assert.equal(client.frames[0].t, 'hello', 'hello is the first frame')
  assert.ok(f.execution.descriptor().capabilities.includes('stream'))
  // A stopping server refuses with 503 unavailable, in the header too.
  await f.stream.close()
  const stopping = await handshake(f.port, { headers: f.signed() })
  assert.deepEqual([stopping.status, stopping.body.code, stopping.headers['x-woven-error']], [503, 'unavailable', 'unavailable'])
})

test('the workspace stream sends its snapshot, replays the journal after the cursor and follows new entries', async t => {
  const f = await fixture(t)
  const id = await f.session()
  const after = f.execution.events().cursor
  await f.execution.command(f.command('workspace', { conversationID: id, workspaceAction: { conversation: { id, action: 'rename', title: 'First' } } }), f.device)
  const written = f.execution.events(after).entries
  assert.ok(written.length > 0)

  const client = f.connect()
  await client.next(frame => frame.t === 'hello')
  client.send({ t: 'sub', id: 'w', stream: 'workspace', params: { after } })
  const snapshot = await client.next(isItem('conversations', 'w'))
  assert.equal(snapshot.data.snapshot, true)
  assert.deepEqual(snapshot.data.conversations, f.execution.conversations())
  assert.deepEqual((await client.next(isItem('pending', 'w'))).data, { interactions: [] })
  const replayed = []
  for (const entry of written) {
    const frame = await client.next(isItem('journal', 'w'))
    assert.equal(frame.seq, entry.originSequence); assert.deepEqual(frame.data.entry, entry)
    replayed.push(frame.seq)
  }
  assert.deepEqual(replayed, written.map(entry => entry.originSequence))
  await client.next(isItem('synchronized', 'w'))
  assert.ok(client.frames.findIndex(isItem('synchronized', 'w')) > client.frames.findIndex(frame => frame.seq === replayed.at(-1)), 'synchronized follows the replay')

  // New entries follow as they are written, with the summary that changed.
  await f.execution.command(f.command('workspace', { conversationID: id, workspaceAction: { conversation: { id, action: 'rename', title: 'Second' } } }), f.device)
  const live = f.execution.events(replayed.at(-1)).entries
  for (const entry of live) assert.equal((await client.next(isItem('journal', 'w'))).seq, entry.originSequence)
  const changed = await client.next(frame => isItem('conversations', 'w')(frame) && !frame.data.snapshot)
  assert.equal(changed.data.conversations[0].title, 'Second')

  // Without `after`, no journal at all.
  client.send({ t: 'sub', id: 'plain', stream: 'workspace', params: {} })
  await client.next(isItem('synchronized', 'plain'))
  assert.equal(client.frames.filter(isItem('journal', 'plain')).length, 0)
  // A stream this server does not serve, and a cursor that is no sequence.
  client.send({ t: 'sub', id: 'state', stream: 'server.state', params: {} })
  assert.equal((await client.next(frame => frame.t === 'end' && frame.id === 'state')).error.code, 'invalid')
  client.send({ t: 'sub', id: 'bad', stream: 'workspace', params: { after: -1 } })
  assert.equal((await client.next(frame => frame.t === 'end' && frame.id === 'bad')).error.code, 'invalid')
  // A pending question reaches the workspace stream.
  const opened = await f.execution.command(f.command('send', { conversationID: id, text: 'go' }), f.device)
  await eventually(() => f.runs.length === 1, 'the run started')
  f.runs[0].interaction({ id: randomUUID(), kind: 'question', title: 'Which?', options: [], questions: [] })
  const pending = await client.next(frame => isItem('pending', 'w')(frame) && frame.data.interactions.length === 1)
  assert.equal(pending.data.interactions[0].runID, opened.runID)
})

test('the conversation stream sends the transcript window, then live upserts well before the journal flush', async t => {
  const f = await fixture(t)
  const id = await f.session()
  const receipt = await f.execution.command(f.command('send', { conversationID: id, text: 'Say hello' }), f.device)
  await eventually(() => f.runs.length === 1, 'the run started')
  const client = f.connect()
  await client.next(frame => frame.t === 'hello')
  client.send({ t: 'sub', id: 'c', stream: 'conversation', params: { conversationID: id } })
  const snapshot = await client.next(isItem('transcript', 'c'))
  assert.equal(snapshot.data.snapshot, true)
  assert.deepEqual(snapshot.data.transcript, f.execution.transcript(id))
  const capabilities = await client.next(isItem('capabilities', 'c'))
  assert.equal(capabilities.data.capabilities.runtimeKind, 'default_agent')
  await client.next(isItem('synchronized', 'c'))

  const started = Date.now()
  f.runs[0].publish({ sessionUpdate: 'agent_message_chunk', content: { text: 'Hel' } })
  const upsert = await client.next(isItem('transcript', 'c'))
  const elapsed = Date.now() - started
  // Before the journal's 500 ms flush: the stream does not wait for it (checked below).
  assert.ok(elapsed < 500, `live text took ${elapsed} ms`)
  assert.equal(upsert.data.snapshot, false)
  assert.deepEqual(upsert.data.transcript.messages.map(message => [message.id, message.content]), [[receipt.runID, 'Hel']])
  assert.equal(upsert.data.transcript.activeRunID, receipt.runID)
  // The journal has not flushed this text yet: the stream did not wait for it, and wrote nothing.
  assert.ok(!f.execution.events().entries.some(entry => entry.transcript?.messages.some(message => message.content === 'Hel')))
  // Each upsert is the whole message so far.
  f.runs[0].publish({ sessionUpdate: 'agent_message_chunk', content: { text: 'lo' } })
  f.runs[0].publish({ sessionUpdate: 'tool_call', toolCallId: 'one', title: 'Read', status: 'in_progress' })
  const next = await client.next(frame => isItem('transcript', 'c')(frame) && frame.data.transcript.activities.length > 0)
  assert.equal(f.execution.transcript(id).messages.find(message => message.id === receipt.runID).content, 'Hello')
  assert.ok([...client.frames].filter(isItem('transcript', 'c')).some(frame => frame.data.transcript.messages.some(message => message.content === 'Hello')))
  // The text before the tool became its commentary; the tool follows it.
  assert.deepEqual(next.data.transcript.activities.map(activity => activity.title), ['Commentary', 'Read'])
  // The run ends: the final state, with no active run.
  f.runs[0].done.resolve()
  const finished = await client.next(frame => isItem('transcript', 'c')(frame) && !frame.data.transcript.activeRunID)
  assert.ok(finished.data.transcript.messages.some(message => message.id === receipt.runID && message.status === 'completed'))
  // The journal still records the history on its own schedule.
  await eventually(() => f.execution.events().entries.some(entry => entry.transcript?.messages.some(message => message.content === 'Hello')), 'the journal flushed')
  // An unknown conversation.
  client.send({ t: 'sub', id: 'missing', stream: 'conversation', params: { conversationID: randomUUID() } })
  assert.equal((await client.next(frame => frame.t === 'end' && frame.id === 'missing')).error.code, 'not_found')
  // Cancel ends a subscription without an end frame.
  client.send({ t: 'cancel', id: 'c' })
  // A call answered after it: the server read the cancel first (frames are handled in order).
  await client.request('execution.receipt', { commandID: randomUUID() })
  const before = client.frames.length
  await f.execution.command(f.command('workspace', { conversationID: id, workspaceAction: { conversation: { id, action: 'rename', title: 'After' } } }), f.device)
  await new Promise(resolve => setTimeout(resolve, 120))
  assert.equal(client.frames.slice(before).filter(frame => frame.id === 'c').length, 0)
})

test('the conversation stream sends the session settings on subscribe and whenever they change', async t => {
  const f = await fixture(t)
  const id = await f.session()
  const client = f.connect()
  await client.next(frame => frame.t === 'hello')
  client.send({ t: 'sub', id: 'c', stream: 'conversation', params: { conversationID: id } })
  // On subscribe, before synchronized, exactly what the `session` workspace read returns.
  const first = await client.next(isItem('session', 'c'))
  assert.deepEqual(first.data.settings, (await f.execution.readWorkspace({ session: { id } })).session._0)
  assert.deepEqual([first.data.settings.conversationID, first.data.settings.model, first.data.settings.canConfigure], [id, 'small', true])
  await client.next(isItem('synchronized', 'c'))
  assert.ok(client.frames.findIndex(isItem('session', 'c')) < client.frames.findIndex(isItem('synchronized', 'c')))

  // A model change the runtime keeps outside the record.
  await f.execution.command(f.command('workspace', { conversationID: id, workspaceAction: { configureSession: { id, model: 'large' } } }), f.device)
  assert.equal((await client.next(isItem('session', 'c'))).data.settings.model, 'large')
  // A change that leaves the settings as they were sends nothing.
  const sent = client.frames.filter(isItem('session', 'c')).length
  await f.execution.command(f.command('workspace', { conversationID: id, workspaceAction: { conversation: { id, action: 'rename', title: 'Same settings' } } }), f.device)
  await new Promise(resolve => setTimeout(resolve, 150))
  assert.equal(client.frames.filter(isItem('session', 'c')).length, sent)
  // A goal change.
  await f.execution.command(f.command('workspace', { conversationID: id, workspaceAction: { goal: { id, mutation: { set: { objective: 'Ship it' } } } } }), f.device)
  const goal = await client.next(frame => isItem('session', 'c')(frame) && frame.data.settings.goal)
  assert.equal(goal.data.settings.goal.objective, 'Ship it')
})

test('the workspace stream carries the library change cursor: on subscribe, then at most every 300 ms', async t => {
  const clock = fakeClock(), library = libraryFeed(41), f = await fixture(t, { clock, library })
  const client = f.connect()
  await client.next(frame => frame.t === 'hello')
  client.send({ t: 'sub', id: 'w', stream: 'workspace', params: {} })
  assert.deepEqual((await client.next(isItem('library', 'w'))).data, { cursor: 41 })
  await client.next(isItem('synchronized', 'w'))
  assert.ok(client.frames.findIndex(isItem('library', 'w')) < client.frames.findIndex(isItem('synchronized', 'w')), 'the cursor comes with the snapshot')
  const items = () => client.frames.filter(isItem('library', 'w')).map(frame => frame.data.cursor)
  const quiet = async () => { await new Promise(resolve => setTimeout(resolve, 30)); return items() }

  // Three changes inside one window are one item, 300 ms after the last one sent.
  library.set(42); library.set(43); library.set(44)
  await clock.advance(299)
  assert.deepEqual(await quiet(), [41], 'nothing before 300 ms')
  await clock.advance(1)
  await eventually(() => items().length === 2, 'the coalesced cursor arrived')
  assert.deepEqual(items(), [41, 44])
  // An announcement that does not move the cursor sends nothing.
  library.set(44)
  await clock.advance(300)
  assert.deepEqual(await quiet(), [41, 44])
  // Once the window has passed, the next change goes at once.
  await clock.advance(1_000)
  library.set(45)
  await clock.advance(0)
  await eventually(() => items().length === 3, 'an isolated change is sent at once')
  assert.deepEqual(items(), [41, 44, 45])

  // A host that has announced nothing yet sends no item; its first announcement does.
  const empty = libraryFeed(null), g = await fixture(t, { clock, library: empty })
  const other = g.connect()
  await other.next(frame => frame.t === 'hello')
  other.send({ t: 'sub', id: 'w', stream: 'workspace', params: {} })
  await other.next(isItem('synchronized', 'w'))
  assert.equal(other.frames.filter(isItem('library', 'w')).length, 0)
  empty.set(3)
  await clock.advance(300)
  assert.deepEqual((await other.next(isItem('library', 'w'))).data, { cursor: 3 })
  // A closed subscription stops listening.
  other.send({ t: 'cancel', id: 'w' })
  // A call answered after it: the server read the cancel first (frames are handled in order).
  await other.request('execution.receipt', { commandID: randomUUID() })
  empty.set(4)
  await clock.advance(300)
  assert.equal(other.frames.filter(isItem('library', 'w')).length, 1)
})

test('conversation changes are coalesced every 50 ms, and every 200 ms once a message exceeds 8 KB', async t => {
  const clock = fakeClock(), f = await fixture(t, { clock })
  const id = await f.session()
  const receipt = await f.execution.command(f.command('send', { conversationID: id, text: 'Write' }), f.device)
  await eventually(() => f.runs.length === 1, 'the run started')
  const client = f.connect()
  await client.next(frame => frame.t === 'hello')
  client.send({ t: 'sub', id: 'c', stream: 'conversation', params: { conversationID: id } })
  await client.next(isItem('synchronized', 'c'))
  const upserts = () => client.frames.filter(frame => isItem('transcript', 'c')(frame) && !frame.data.snapshot)
  const content = frame => frame.data.transcript.messages.find(message => message.id === receipt.runID)?.content
  const publish = text => f.runs[0].publish({ sessionUpdate: 'agent_message_chunk', content: { text } })
  const quiet = async () => { await new Promise(resolve => setTimeout(resolve, 30)); return upserts().length }

  publish('a')
  await clock.advance(49)
  assert.equal(await quiet(), 0, 'nothing before 50 ms')
  await clock.advance(1)
  await eventually(() => upserts().length === 1, 'the first change at 50 ms')
  assert.equal(content(upserts()[0]), 'a')

  // Two changes within the interval arrive as one upsert of the whole message.
  publish('b'); publish('c')
  await clock.advance(49)
  assert.equal(await quiet(), 1)
  await clock.advance(1)
  await eventually(() => upserts().length === 2, 'the coalesced change at 100 ms')
  assert.equal(content(upserts()[1]), 'abc')

  // Past 8 KB, a message changes at most every 200 ms.
  publish('x'.repeat(9_000))
  await clock.advance(199)
  assert.equal(await quiet(), 2, 'a large message waits 200 ms after the last send')
  await clock.advance(1)
  await eventually(() => upserts().length === 3, 'the large change at 300 ms')
  assert.equal(content(upserts()[2]).length, 9_003)
  publish('y')
  await clock.advance(199)
  assert.equal(await quiet(), 3)
  await clock.advance(1)
  await eventually(() => upserts().length === 4, 'the next large change at 500 ms')
  assert.ok(content(upserts()[3]).endsWith('y'))
  // An activity alongside a large message still waits for the large interval;
  // with only small entities, 50 ms again.
  f.runs[0].publish({ sessionUpdate: 'tool_call', toolCallId: 'small', title: 'Small', status: 'in_progress' })
  await clock.advance(50)
  await eventually(() => upserts().length === 5, 'small entities at 50 ms')
  assert.equal(upserts()[4].data.transcript.messages.length, 0)
  assert.equal(upserts()[4].data.transcript.activities.at(-1).title, 'Small')
})

test('execution.command and execution.receipt answer with the HTTP command receipts', async t => {
  const f = await fixture(t)
  const client = f.connect()
  await client.next(frame => frame.t === 'hello')
  const create = f.command('createSession')
  const first = await client.request('execution.command', { command: create })
  assert.equal(first.result.status, 'completed'); assert.equal(first.result.commandID, create.commandID)
  // A duplicate command ID replays the same receipt; nothing runs twice.
  const again = await client.request('execution.command', { command: create })
  assert.deepEqual(again.result, first.result)
  assert.equal(f.execution.conversations().length, 1)
  assert.deepEqual((await client.request('execution.receipt', { commandID: create.commandID })).result, first.result)
  assert.deepEqual((await client.request('execution.receipt', { commandID: create.commandID })).result, f.execution.receipt(create.commandID, f.mac.deviceID))
  assert.equal((await client.request('execution.receipt', { commandID: randomUUID() })).result, null)
  // The same refusals as the HTTP route.
  assert.equal((await client.request('execution.command', { command: { ...f.command('createSession'), deviceID: randomUUID() } })).error.code, 'invalid')
  assert.equal((await client.request('execution.command', { command: { ...create, title: 'changed' } })).error.code, 'conflict')
  assert.equal((await client.request('execution.command', {})).error.code, 'invalid')
  assert.equal((await client.request('execution.unknown', {})).error.code, 'invalid')
  const send = f.command('send', { conversationID: first.result.conversationID, text: 'hello' })
  assert.equal((await client.request('execution.command', { command: send })).result.status, 'accepted')
  assert.equal((await client.request('execution.command', { command: f.command('send', { conversationID: first.result.conversationID, text: 'again' }) })).result.status, 'rejected')
})

test('a removed member’s stream and bots relay close with 4401', async t => {
  const f = await fixture(t, { refreshMilliseconds: 50 })
  // A bots runtime stand-in behind the relay.
  const runtimeServer = createServer(), runtimeSockets = new WebSocketServer({ server: runtimeServer, path: '/ws' })
  runtimeSockets.on('connection', socket => socket.on('message', data => socket.send(data)))
  const runtimePort = await listen(runtimeServer)
  t.after(() => { for (const socket of runtimeSockets.clients) socket.terminate(); runtimeSockets.close(); runtimeServer.close() })
  const directory = mkdtempSync(join(tmpdir(), 'wm-stream-bots-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const bots = createBotsService({ configuration: { stateDirectory: directory, dataRoot: directory, botsData: join(directory, 'bots'), serviceRoot: directory, botsEnabled: true, workspaceEnabled: true },
    engine: { status: async () => ({ installed: false }), layout: { socket: join(directory, 'engine.sock') } }, previews: { recover: async () => {}, close: async () => {} },
    runtime: { start() {}, stop: async () => {}, restart: async () => {}, status: () => ({ running: true }), endpoint: () => ({ host: '127.0.0.1', port: runtimePort, token: 'runtime-token' }) },
    library: createBotConversationLibrary(createMemoryBotLibraryAdapter()), machine: { deviceID: f.host, name: 'box' }, serverPort: () => f.port, registry: f.registry, log: () => {},
    authorizeClient: async request => (await authenticateMemberUpgrade(request, { members: f.verifier, servedTargets: f.servedTargets })).member })
  f.upgrades.push(bots.upgrade)
  const phone = { deviceID: randomUUID(), key: privateKeyFromSeed(Buffer.alloc(32, 5)), kind: 'ios' }
  f.list.value = { revision: '2', members: [memberEntry(f.mac), memberEntry(phone)] }
  await f.verifier.refresh()

  const stream = f.connect()
  await stream.next(frame => frame.t === 'hello')
  const kept = f.connect(f.signed(streamTarget, {}, phone))
  await kept.next(frame => frame.t === 'hello')
  const relay = new WebSocket(`ws://127.0.0.1:${f.port}/bots/ws`, { headers: f.signed(prefix + '/bots/ws') })
  f.sockets.push(relay)
  const relayed = frameReader(relay)
  await relayed.opened
  relay.send(JSON.stringify({ t: 'echo' }))
  assert.deepEqual(await relayed.next(), { t: 'echo' })
  assert.equal(f.registry.count(), 3)

  // The Mac is removed; the periodic reload closes its sockets, not the phone's.
  f.list.value = { revision: '3', members: [memberEntry(f.mac, { revoked: true }), memberEntry(phone)] }
  assert.equal((await stream.closed).code, 4401)
  assert.equal((await relayed.closed).code, 4401)
  assert.equal(f.registry.count(), 1)
  assert.equal(kept.socket.readyState, WebSocket.OPEN)
  // A member that is no longer an allowed kind is closed too.
  f.list.value = { revision: '4', members: [{ ...memberEntry(phone), kind: 'printer' }] }
  assert.equal((await kept.closed).code, 4401)
  // And a removed member cannot reconnect.
  assert.equal((await handshake(f.port, { headers: f.signed() })).status, 401)
})

test('a socket that answers no pings is closed', async t => {
  // A pong timeout well above what a busy machine delays an answered ping.
  const f = await fixture(t, { timings: { pingMilliseconds: 40, pongTimeoutMilliseconds: 1_000 } })
  const silent = f.connect(f.signed(), { autoPong: false })
  const answering = f.connect(f.signed())
  await silent.next(frame => frame.t === 'hello'); await answering.next(frame => frame.t === 'hello')
  const started = Date.now()
  assert.equal((await silent.closed).code, 1001, 'closed as going away')
  assert.ok(Date.now() - started >= 900)
  assert.equal(answering.socket.readyState, WebSocket.OPEN, 'a socket that answers pings stays open')
  // The server answers the client's pings.
  const pong = new Promise(resolve => answering.socket.once('pong', resolve))
  answering.socket.ping('x')
  assert.equal(String(await pong), 'x')
})

test('any frame from the client keeps its socket alive, not only a pong', async t => {
  const f = await fixture(t, { timings: { pingMilliseconds: 40, pongTimeoutMilliseconds: 600 } })
  const talking = f.connect(f.signed(), { autoPong: false })
  await talking.next(frame => frame.t === 'hello')
  for (const deadline = Date.now() + 1_500; Date.now() < deadline;) {
    await talking.request('execution.receipt', { commandID: randomUUID() })
    await new Promise(resolve => setTimeout(resolve, 100))
  }
  assert.equal(talking.socket.readyState, WebSocket.OPEN)
  // Its own pings count too.
  for (const deadline = Date.now() + 1_000; Date.now() < deadline;) { talking.socket.ping(); await new Promise(resolve => setTimeout(resolve, 100)) }
  assert.equal(talking.socket.readyState, WebSocket.OPEN)
  // Silence still closes it.
  assert.equal((await talking.closed).code, 1001)
})

test('a stream name that is an Object prototype key is not a stream', async t => {
  const f = await fixture(t)
  const client = f.connect()
  await client.next(frame => frame.t === 'hello')
  for (const stream of ['constructor', '__proto__', 'toString', 'hasOwnProperty']) {
    client.send({ t: 'sub', id: stream, stream, params: {} })
    const end = await client.next(frame => frame.t === 'end' && frame.id === stream)
    assert.equal(end.error.code, 'invalid', stream)
  }
  // The connection still serves real streams.
  client.send({ t: 'sub', id: 'w', stream: 'workspace', params: {} })
  await client.next(isItem('synchronized', 'w'))
})

test('a transcript snapshot or entity too large for one frame ends the subscription with unavailable', async t => {
  const f = await fixture(t, { limits: { frameBytes: 4 * 1024 } })
  const id = await f.session()
  await f.execution.command(f.command('send', { conversationID: id, text: 'go' }), f.device)
  await eventually(() => f.runs.length === 1, 'the run started')
  const client = f.connect()
  await client.next(frame => frame.t === 'hello')
  client.send({ t: 'sub', id: 'live', stream: 'conversation', params: { conversationID: id } })
  await client.next(isItem('synchronized', 'live'))
  // An entity over the frame limit: the subscription ends; it is not dropped quietly.
  f.runs[0].publish({ sessionUpdate: 'agent_message_chunk', content: { text: 'x'.repeat(40 * 1024) } })
  const ended = await client.next(frame => frame.t === 'end' && frame.id === 'live')
  assert.equal(ended.error.code, 'unavailable'); assert.equal(ended.error.retryable, false)
  // A snapshot that does not fit even one message ends before `synchronized`.
  client.send({ t: 'sub', id: 'snapshot', stream: 'conversation', params: { conversationID: id } })
  const refused = await client.next(frame => frame.t === 'end' && frame.id === 'snapshot')
  assert.equal(refused.error.code, 'unavailable'); assert.equal(refused.error.retryable, false)
  assert.equal(client.unread(frame => frame.id === 'snapshot').length, 0)
  assert.ok(!client.frames.some(frame => frame.id === 'snapshot' && frame.t === 'item'))
})

test('inbound frames are limited to 1 MiB and must be JSON text', async t => {
  const f = await fixture(t)
  const large = f.connect()
  await large.next(frame => frame.t === 'hello')
  large.send({ t: 'req', id: 'r', method: 'execution.receipt', params: { padding: 'x'.repeat(1024 * 1024) } })
  assert.equal((await large.closed).code, 1009)
  const binary = f.connect()
  await binary.next(frame => frame.t === 'hello')
  binary.socket.send(Buffer.from('{}'), { binary: true })
  assert.equal((await binary.closed).code, 4400)
  const garbage = f.connect()
  await garbage.next(frame => frame.t === 'hello')
  garbage.socket.send('not json')
  assert.equal((await garbage.closed).code, 4400)
  // So is a frame type or an item kind the protocol does not define, and a frame without a key it requires.
  for (const frame of [{ t: 'noSuchFrame', id: 'x' }, { t: 'item', id: 's', kind: 'noSuchKind', data: {} }, { t: 'sub', id: 's', stream: 'workspace' },
    { t: 'req', id: 'r', method: 'execution.receipt' }]) {
    const client = f.connect()
    await client.next(item => item.t === 'hello')
    client.send(frame)
    // What follows a violation is not read.
    client.send({ t: 'req', id: 'after', method: 'execution.command', params: { command: f.command('createSession') } })
    assert.equal((await client.closed).code, 4400, JSON.stringify(frame))
    assert.ok(!client.frames.some(item => item.t === 'res'))
  }
  assert.deepEqual(f.execution.conversations(), [])
  // A frame a server sends is not a client's: nothing answers it, and the socket stays open.
  const echo = f.connect()
  await echo.next(frame => frame.t === 'hello')
  echo.send({ t: 'end', id: 's' }); echo.send({ t: 'res', id: 'r', result: null })
  assert.equal((await echo.request('execution.receipt', { commandID: randomUUID() })).result, null)
  assert.equal(echo.frames.length, 2)
})

test('a slow reader’s subscription ends with resync instead of growing without bound', async t => {
  const clock = fakeClock()
  const f = await fixture(t, { clock, limits: { items: 8, bytes: 96 * 1024, inflightBytes: 64 * 1024 } })
  const id = await f.session()
  await f.execution.command(f.command('send', { conversationID: id, text: 'go' }), f.device)
  await eventually(() => f.runs.length === 1, 'the run started')
  const client = f.connect()
  await client.next(frame => frame.t === 'hello')
  client.send({ t: 'sub', id: 'c', stream: 'conversation', params: { conversationID: id } })
  await client.next(isItem('synchronized', 'c'))
  // The client stops reading: kernel buffers fill, then the queue. Each change
  // adds ten new 16 KB message parts, so one queued upsert keeps growing.
  client.socket.pause()
  for (let index = 0; index < 64; index++) {
    f.runs[0].publish({ sessionUpdate: 'agent_message_chunk', content: { text: String(index % 10).repeat(160_000) } })
    await clock.advance(200)
  }
  client.socket.resume()
  const end = await client.next(frame => frame.t === 'end' && frame.id === 'c', 30_000)
  assert.deepEqual(end.error, { code: 'resync', message: 'This subscription fell behind. Subscribe again.', retryable: true })
  // Subscribing again starts from a snapshot.
  client.send({ t: 'sub', id: 'c2', stream: 'conversation', params: { conversationID: id } })
  assert.equal((await client.next(isItem('transcript', 'c2'), 30_000)).data.snapshot, true)
})

test('the stream client reconnects with a fresh signature, resumes its journal and waits after 4401', async t => {
  const f = await fixture(t, { refreshMilliseconds: 50 })
  const id = await f.session()
  const signatures = []
  const events = []
  const client = createStreamClient({ endpoint: `http://127.0.0.1:${f.port}`,
    sign: async url => { const headers = f.signed(url.pathname + url.search); signatures.push(headers['x-woven-member-nonce']); return headers },
    timings: { initial: 20, maximum: 100 }, onEvent: event => { events.push(event); if (process.env.STREAM_DEBUG) console.error("event", event.type, event.code ?? event.status ?? "", Date.now() % 100000) } })
  t.after(() => client.close())
  const items = []
  client.connect()
  client.subscribe('workspace', { after: 0 }, { onItem: frame => items.push(frame) })
  await eventually(() => items.some(frame => frame.kind === 'synchronized'), 'the first subscription synchronized')
  const replayed = items.filter(frame => frame.kind === 'journal').map(frame => frame.seq)
  assert.deepEqual(replayed, f.execution.events().entries.map(entry => entry.originSequence))
  assert.equal((await client.request('execution.receipt', { commandID: randomUUID() })), null)

  // The server stops (1001), refusing new upgrades until a new one starts on
  // the same port: the client signs every attempt again and resumes after its
  // last journal item.
  const cursor = replayed.at(-1)
  await f.stream.close()
  await eventually(() => events.some(event => event.type === 'closed' && event.code === 1001), 'the client saw the server stop')
  await eventually(() => events.some(event => event.type === 'refused' && event.status === 503), 'an attempt was refused while stopped')
  const restarted = createStreamServer({ members: f.verifier, servedTargets: f.servedTargets, execution: f.execution, registry: f.registry })
  f.upgrades.splice(0, 1, restarted.upgrade)
  t.after(() => restarted.close())
  await f.execution.command(f.command('workspace', { conversationID: id, workspaceAction: { conversation: { id, action: 'rename', title: 'Later' } } }), f.device)
  await eventually(() => client.state() === 'open' && items.filter(frame => frame.kind === 'synchronized').length === 2, 'resubscribed after reconnecting', 30_000)
  assert.ok(new Set(signatures).size === signatures.length && signatures.length >= 2, 'every attempt is signed afresh')
  const resumed = items.filter(frame => frame.kind === 'journal').map(frame => frame.seq).slice(replayed.length)
  assert.deepEqual(resumed, f.execution.events(cursor).entries.map(entry => entry.originSequence), 'resumed after the last journal item')

  // Removed: 4401, and no attempts until told.
  f.list.value = { revision: '9', members: [] }
  await eventually(() => client.state() === 'removed', 'the client stopped after 4401')
  const attempts = signatures.length
  await new Promise(resolve => setTimeout(resolve, 250))
  assert.equal(signatures.length, attempts)
  f.list.value = { revision: '10', members: [memberEntry(f.mac)] }
  await f.verifier.refresh()
  client.retry()
  await eventually(() => client.state() === 'open', 'connected again once told')
})

test('a socket added after the sweep that removed its member is closed with 4401', async () => {
  const registry = createMemberSocketRegistry()
  const kept = { deviceID: randomUUID(), kind: 'ios' }, removed = { deviceID: randomUUID(), kind: 'mac' }
  const closes = { early: [], late: [], kept: [] }
  registry.add(removed, { close: code => closes.early.push(code) })
  registry.sweep([{ ...kept, revoked: false }, { ...removed, revoked: true }])
  assert.deepEqual(closes.early, [4401])
  // Authenticated before that sweep, added after it: closed once its caller has set it up.
  registry.add(removed, { close: code => closes.late.push(code) })
  registry.add(kept, { close: code => closes.kept.push(code) })
  assert.deepEqual(closes.late, [], 'not while it is being added')
  await new Promise(resolve => queueMicrotask(resolve))
  assert.deepEqual(closes.late, [4401])
  assert.deepEqual(closes.kept, [])
  assert.equal(registry.count(), 1)
})

test('the stream client uses a server only when its hello names the expected workspace and library', async t => {
  const f = await fixture(t)
  const connect = expected => {
    const events = [], items = [], signatures = []
    const client = createStreamClient({ endpoint: `http://127.0.0.1:${f.port}`, expected,
      sign: async url => { signatures.push(url); return f.signed(url.pathname + url.search) }, timings: { initial: 20, maximum: 100 }, onEvent: event => events.push(event) })
    t.after(() => client.close())
    client.subscribe('workspace', {}, { onItem: frame => items.push(frame) })
    client.connect()
    return { client, events, items, signatures }
  }
  const right = connect({ workspaceID: f.enrollment.workspaceID.toUpperCase(), libraryID: f.enrollment.libraryID })
  await eventually(() => right.items.some(frame => frame.kind === 'synchronized'), 'the expected workspace streams')
  for (const expected of [{ workspaceID: randomUUID(), libraryID: f.enrollment.libraryID }, { workspaceID: f.enrollment.workspaceID, libraryID: randomUUID() }]) {
    const wrong = connect(expected)
    await eventually(() => wrong.client.state() === 'mismatched', 'another workspace is not used')
    assert.deepEqual(wrong.events.find(event => event.type === 'mismatch').hello, { workspaceID: f.enrollment.workspaceID, libraryID: f.enrollment.libraryID })
    assert.equal(wrong.items.length, 0, 'nothing it sent was used')
    // No reconnecting to it until told.
    const attempts = wrong.signatures.length
    await new Promise(resolve => setTimeout(resolve, 200))
    assert.equal(wrong.signatures.length, attempts)
    wrong.client.retry()
    await eventually(() => wrong.signatures.length === attempts + 1 && wrong.client.state() === 'mismatched', 'retry checks again')
  }
})

test('the stream client closes a server that breaks the protocol with 4400', async t => {
  const server = createServer(), sockets = new WebSocketServer({ server }), port = await listen(server)
  const scripts = [], closes = []
  sockets.on('connection', socket => { socket.on('close', code => closes.push(code)); scripts.shift()(socket) })
  t.after(async () => { for (const socket of sockets.clients) socket.terminate(); await new Promise(resolve => server.close(resolve)) })
  const hello = { t: 'hello', deviceID: 'd', libraryID: 'l', workspaceID: 'w', serverTime: 1, capabilities: [], maxFrameBytes: 8 * 1024 * 1024 }
  const text = frame => JSON.stringify(frame), pending = { t: 'item', id: 's1', kind: 'pending', data: { interactions: [] } }
  function connect() {
    const items = [], ends = []
    // A long backoff: each case is one connection.
    const client = createStreamClient({ endpoint: `http://127.0.0.1:${port}`, sign: async () => ({}), timings: { initial: 60_000, maximum: 60_000 } })
    t.after(() => client.close())
    client.subscribe('workspace', {}, { onItem: frame => items.push(frame), onEnd: error => ends.push(error) })
    client.connect()
    return { client, items, ends }
  }
  const violations = {
    'a frame before hello': socket => { socket.send(text(pending)); socket.send(text(hello)) },
    'a frame type the protocol does not define': socket => { socket.send(text(hello)); socket.send(text({ t: 'noSuchFrame', id: 's1' })); socket.send(text(pending)) },
    'an item kind the protocol does not define': socket => { socket.send(text(hello)); socket.send(text({ t: 'item', id: 's1', seq: 43, kind: 'noSuchKind', data: {} })) },
    'an item its kind cannot read': socket => { socket.send(text(hello)); socket.send(text({ t: 'item', id: 's1', kind: 'pending', data: { interactions: [{ id: 'i' }] } })) },
    'a binary frame': socket => { socket.send(text(hello)); socket.send(Buffer.from(text(pending)), { binary: true }) },
    'invalid JSON': socket => { socket.send(text(hello)); socket.send('{') },
  }
  for (const [name, script] of Object.entries(violations)) {
    scripts.push(script)
    const seen = closes.length, { client, items, ends } = connect()
    await eventually(() => closes.length === seen + 1, name)
    assert.equal(closes.at(-1), 4400, name)
    await eventually(() => client.state() === 'waiting', name + ': it reconnects after its backoff')
    assert.deepEqual([items, ends], [[], []], name)
    client.close()
  }
  // After its hello a server greets no more, and a client's own frame types are not answered.
  scripts.push(socket => { socket.send(text(hello)); socket.send(text({ ...hello, workspaceID: 'other' })); socket.send(text({ t: 'cancel', id: 's1' })); socket.send(text(pending)) })
  const open = connect()
  await eventually(() => open.items.length === 1, 'the item after them is delivered')
  assert.equal(open.client.state(), 'open'); assert.equal(open.client.hello().workspaceID, 'w')
})

test('the bots relay dials no runtime for a bad handshake, and a bearer rotation closes installer relays', async t => {
  const f = await fixture(t)
  const runtimeServer = createServer(), runtimeSockets = new WebSocketServer({ server: runtimeServer, path: '/ws' })
  let dialled = 0
  runtimeSockets.on('connection', socket => { dialled++; socket.on('message', data => socket.send(data)) })
  const runtimePort = await listen(runtimeServer)
  t.after(() => { for (const socket of runtimeSockets.clients) socket.terminate(); runtimeSockets.close(); runtimeServer.close() })
  const directory = mkdtempSync(join(tmpdir(), 'wm-stream-installer-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  const token = 'installer-' + 'a'.repeat(40), next = 'installer-' + 'b'.repeat(40)
  const installerBearer = createInstallerBearer({ token, rotate: async () => next })
  const bots = createBotsService({ configuration: { stateDirectory: directory, dataRoot: directory, botsData: join(directory, 'bots'), serviceRoot: directory, botsEnabled: true, workspaceEnabled: true },
    engine: { status: async () => ({ installed: false }), layout: { socket: join(directory, 'engine.sock') } }, previews: { recover: async () => {}, close: async () => {} },
    runtime: { start() {}, stop: async () => {}, restart: async () => {}, status: () => ({ running: true }), endpoint: () => ({ host: '127.0.0.1', port: runtimePort, token: 'runtime-token' }) },
    library: createBotConversationLibrary(createMemoryBotLibraryAdapter()), machine: { deviceID: f.host, name: 'box' }, serverPort: () => f.port, registry: f.registry, log: () => {},
    installerBearer, authorizeClient: request => authorizeBotsUpgrade(request, { members: f.verifier, servedTargets: f.servedTargets, installerBearer }) })
  t.after(() => bots.close())
  f.upgrades.push(bots.upgrade)

  // A signed request whose WebSocket handshake cannot be completed: refused before any upstream exists.
  for (const headers of [{ 'sec-websocket-key': 'short' }, { 'sec-websocket-version': '12' }]) {
    const refused = await handshake(f.port, { path: '/bots/ws', headers: { ...f.signed(prefix + '/bots/ws'), ...headers } })
    assert.equal(refused.status, 400)
  }
  assert.equal(dialled, 0)

  const open = headers => { const socket = new WebSocket(`ws://127.0.0.1:${f.port}/bots/ws`, { headers }); f.sockets.push(socket); return frameReader(socket) }
  const installer = open({ authorization: 'Bearer ' + token }), member = open(f.signed(prefix + '/bots/ws'))
  await installer.opened; await member.opened
  installer.send({ t: 'echo' })
  assert.deepEqual(await installer.next(), { t: 'echo' })
  await eventually(() => dialled === 2, 'both relays reach the runtime')
  assert.equal(await installerBearer.rotate(), next)
  assert.equal((await installer.closed).code, 4401)
  assert.equal(member.socket.readyState, WebSocket.OPEN, 'a member relay is not the installer\'s')
  // The old bearer opens nothing; the new one does.
  assert.equal((await handshake(f.port, { path: '/bots/ws', headers: { authorization: 'Bearer ' + token } })).status, 401)
  const renewed = open({ authorization: 'Bearer ' + next })
  await renewed.opened
  await eventually(() => runtimeSockets.clients.size === 2, 'the closed relay left no runtime socket behind')
})

test('a subscription a store error ends is retryable, and a refusal is not', async () => {
  const { subscriptionErrorFor } = await import('../src/stream-protocol.mjs')
  assert.equal(subscriptionErrorFor(new Error('database is locked')).retryable, true)
  assert.equal(subscriptionErrorFor(Object.assign(new Error('busy'), { statusCode: 500 })).retryable, true)
  assert.deepEqual(subscriptionErrorFor(Object.assign(new Error('gone'), { statusCode: 404 })), { code: 'not_found', message: 'gone', retryable: false })
  assert.equal(subscriptionErrorFor(Object.assign(new Error('no'), { statusCode: 403 })).retryable, false)
  const explicit = { code: 'unavailable', message: 'Too large.', retryable: false }
  assert.equal(subscriptionErrorFor(Object.assign(new Error('x'), { stream: explicit })), explicit)
})
