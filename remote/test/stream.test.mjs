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
import { authenticateMemberUpgrade, createMemberSocketRegistry } from '../src/member-sockets.mjs'
import { createStreamClient } from '../src/stream-client.mjs'
import { decodeFrame, encodeFrame, StreamFrameError, streamCapability } from '../src/stream-protocol.mjs'
import { createOutboundQueue, createStreamServer } from '../src/stream-server.mjs'
import { WebSocket, WebSocketServer, webSocketPackageOwner } from '../src/websocket.mjs'
import { enroll } from './fixtures/execution.mjs'

// The live stream (docs/architecture/WOVEN_EVERYWHERE.md, "Streaming").

const fixturesPath = new URL('../../shared/Tests/WovenMatterSharedTests/StreamProtocolFixtures.json', import.meta.url)
const prefix = '/wovenmatter-execution/box'
const streamTarget = prefix + '/v1/stream?protocol=1'
const settle = () => new Promise(resolve => setImmediate(resolve))
const listen = server => new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve(server.address().port)))
async function eventually(condition, message, timeout = 5_000) {
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

async function fixture(t, { clock, limits, timings, refreshMilliseconds = 15_000 } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'wm-stream-')), runs = []
  const provider = { id: 'default_agent', runtimeKind: 'default_agent', displayName: 'Pi Durable', routeName: 'This workspace', available: true, canStart: true,
    canResume: true, canSteer: true, canStop: true, supportsApprovals: false, supportsQuestions: false, activeInputMode: 'steer' }
  const runtime = { providers: async () => [provider], create: async () => ({ sessionID: randomUUID() }),
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
  const stream = createStreamServer({ members: verifier, servedTargets, execution, registry, ...(clock ? { clock } : {}), limits, timings })
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
    const socket = new WebSocket(`ws://127.0.0.1:${port}/v1/stream?protocol=1`, { headers, ...options })
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
  async function next(predicate = () => true, timeout = 5_000) {
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
function handshake(port, { path = '/v1/stream?protocol=1', headers = {} } = {}) {
  return new Promise((resolve, reject) => {
    const request = httpRequest({ host: '127.0.0.1', port, path, headers: { connection: 'Upgrade', upgrade: 'websocket',
      'sec-websocket-key': 'dGhlIHNhbXBsZSBub25jZQ==', 'sec-websocket-version': '13', ...headers } })
    request.on('response', response => {
      let body = ''
      response.on('data', chunk => { body += chunk })
      response.on('end', () => resolve({ status: response.statusCode, body: body ? JSON.parse(body) : null }))
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
  assert.equal(fixtures.protocol, 1)
  const types = new Set(), kinds = new Set()
  for (const { name, frame } of fixtures.frames) {
    const decoded = decodeFrame(JSON.stringify(frame))
    assert.notEqual(decoded.t, 'unknown', name)
    types.add(decoded.t); if (decoded.t === 'item') kinds.add(decoded.kind)
    assert.deepEqual(JSON.parse(encodeFrame(decoded)), frame, `${name} did not round-trip`)
  }
  assert.deepEqual([...types].sort(), ['cancel', 'end', 'hello', 'item', 'req', 'res', 'sub'])
  for (const kind of ['conversations', 'pending', 'journal', 'transcript', 'capabilities', 'synchronized', 'server.state']) assert.ok(kinds.has(kind), kind)
  for (const frame of fixtures.unknownFrames) {
    assert.deepEqual(decodeFrame(JSON.stringify(frame)), { t: 'unknown', type: 'futureFrame' })
    assert.throws(() => encodeFrame(frame), StreamFrameError)
  }
  const unknownKind = decodeFrame(JSON.stringify(fixtures.frames.find(item => item.name === 'item-unknown-kind').frame))
  assert.equal(unknownKind.seq, 43); assert.equal(unknownKind.kind, 'futureKind')
  // The length-prefixed form is the Mac window's Unix socket; its JSON is still one frame.
  assert.deepEqual(JSON.parse(Buffer.from(fixtures.lengthPrefixed.hex, 'hex').subarray(4).toString('utf8')), fixtures.lengthPrefixed.frame)
  assert.throws(() => decodeFrame('not json'), StreamFrameError)
  assert.throws(() => decodeFrame('{"t":"req"}'), StreamFrameError)
  assert.throws(() => encodeFrame({ t: 'item', id: 's', kind: 'x', data: 'x'.repeat(64) }, { maximumBytes: 32 }), StreamFrameError)
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
  for (let index = 0; index < 10; index++) queue.enqueue({ t: 'item', id: 'b', kind: 'pending', data: { interactions: [], version: index } }, { subscription: b, key: 'pending', merge: replace })
  assert.deepEqual(queue.size().items, 1, 'updates to one entity supersede the queued one')
  queue.enqueue({ t: 'item', id: 'a', kind: 'journal', seq: 1, data: { entry: {} } }, { subscription: a })
  queue.enqueue({ t: 'item', id: 'a', kind: 'journal', seq: 2, data: { entry: {} } }, { subscription: a })
  queue.enqueue({ t: 'item', id: 'a', kind: 'journal', seq: 3, data: { entry: {} } }, { subscription: a })
  assert.deepEqual(overflowed, ['a'])
  // Responses always go out.
  assert.equal(queue.enqueue({ t: 'res', id: 'r1', result: null }), true)
  // Acknowledge everything: what remains is b's latest update, a's end, and the response.
  while (sent.some(entry => !entry.acknowledged)) { const entry = sent.find(item => !item.acknowledged); entry.acknowledged = true; entry.done() }
  const frames = sent.slice(1).map(entry => JSON.parse(entry.text))
  assert.deepEqual(frames.map(frame => [frame.t, frame.id]), [['item', 'b'], ['end', 'a'], ['res', 'r1']])
  assert.equal(frames[0].data.version, 9)
  assert.equal(frames[1].error.code, 'resync'); assert.equal(frames[1].error.retryable, true)
  // A large first item still goes out alone.
  assert.equal(queue.enqueue({ t: 'item', id: 'b', kind: 'pending', data: { big: 'x'.repeat(10_000) } }, { subscription: b }), true)
})

test('the stream upgrade refuses bad protocols, stale clocks, bearers and browsers before upgrading', async t => {
  const f = await fixture(t)
  const refused = await handshake(f.port, { path: '/v1/stream', headers: f.signed(prefix + '/v1/stream') })
  assert.deepEqual([refused.status, refused.body.code, refused.body.supported], [426, 'protocol_unsupported', [1]])
  assert.equal((await handshake(f.port, { path: '/v1/stream?protocol=2', headers: f.signed(prefix + '/v1/stream?protocol=2') })).status, 426)
  const stale = await handshake(f.port, { headers: f.signed(streamTarget, { time: Date.now() - 400_000 }) })
  assert.deepEqual([stale.status, stale.body.code, typeof stale.body.serverTime], [401, 'member_time_stale', 'number'])
  assert.ok(Math.abs(stale.body.serverTime - Date.now()) < 60_000)
  for (const headers of [{}, { authorization: 'Bearer ' + 'i'.repeat(43) }, f.signed(streamTarget, { audience: randomUUID() }),
    f.signed(prefix + '/v1/stream?protocol=1&x=1')]) {
    const result = await handshake(f.port, { headers })
    assert.deepEqual([result.status, result.body.code], [401, 'unauthorized'], JSON.stringify(Object.keys(headers)))
  }
  const stranger = { deviceID: randomUUID(), key: privateKeyFromSeed(Buffer.alloc(32, 3)), kind: 'ios' }
  assert.equal((await handshake(f.port, { headers: f.signed(streamTarget, {}, stranger) })).status, 401, 'a device that is not a member')
  assert.equal((await handshake(f.port, { headers: { ...f.signed(), origin: 'https://evil.example' } })).status, 403)
  assert.equal((await handshake(f.port, { headers: { ...f.signed(), cookie: 'session=1' } })).status, 403)
  // Signed for the path the member sent, or as this server saw it.
  assert.equal((await handshake(f.port, { headers: f.signed() })).status, 101)
  assert.equal((await handshake(f.port, { headers: f.signed('/v1/stream?protocol=1') })).status, 101)
  const replay = f.signed()
  assert.equal((await handshake(f.port, { headers: replay })).status, 101)
  assert.equal((await handshake(f.port, { headers: replay })).status, 401, 'an upgrade cannot be replayed')
  // Hello names this server's member device, its library and workspace.
  const client = f.connect()
  const hello = await client.next(frame => frame.t === 'hello')
  assert.deepEqual([hello.deviceID, hello.libraryID, hello.workspaceID, hello.protocol, hello.maxFrameBytes], [f.host, f.enrollment.libraryID, f.enrollment.workspaceID, 1, 8 * 1024 * 1024])
  assert.ok(hello.capabilities.includes('stream.v1'))
  assert.equal(client.frames[0].t, 'hello', 'hello is the first frame')
  assert.ok(f.execution.descriptor().capabilities.includes('stream.v1'))
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
  // Unknown frames and streams.
  client.send({ t: 'futureFrame', id: 'x' })
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
  assert.ok(elapsed < 300, `live text took ${elapsed} ms`)
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
  assert.equal(next.data.transcript.activities[0].title, 'Read')
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
  await settle()
  const before = client.frames.length
  await f.execution.command(f.command('workspace', { conversationID: id, workspaceAction: { conversation: { id, action: 'rename', title: 'After' } } }), f.device)
  await new Promise(resolve => setTimeout(resolve, 120))
  assert.equal(client.frames.slice(before).filter(frame => frame.id === 'c').length, 0)
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
  assert.equal(upserts()[4].data.transcript.activities[0].title, 'Small')
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
  const relay = new WebSocket(`ws://127.0.0.1:${f.port}/v1/bots/ws`, { headers: f.signed(prefix + '/v1/bots/ws') })
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
  const f = await fixture(t, { timings: { pingMilliseconds: 40, pongTimeoutMilliseconds: 250 } })
  const silent = f.connect(f.signed(), { autoPong: false })
  const answering = f.connect(f.signed())
  await silent.next(frame => frame.t === 'hello'); await answering.next(frame => frame.t === 'hello')
  const started = Date.now()
  await silent.closed
  assert.ok(Date.now() - started >= 150)
  assert.equal(answering.socket.readyState, WebSocket.OPEN, 'a socket that answers pings stays open')
  // The server answers the client's pings.
  const pong = new Promise(resolve => answering.socket.once('pong', resolve))
  answering.socket.ping('x')
  assert.equal(String(await pong), 'x')
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
  const end = await client.next(frame => frame.t === 'end' && frame.id === 'c', 10_000)
  assert.deepEqual(end.error, { code: 'resync', message: 'This subscription fell behind. Subscribe again.', retryable: true })
  // Subscribing again starts from a snapshot.
  client.send({ t: 'sub', id: 'c2', stream: 'conversation', params: { conversationID: id } })
  assert.equal((await client.next(isItem('transcript', 'c2'), 10_000)).data.snapshot, true)
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
  await eventually(() => client.state() === 'open' && items.filter(frame => frame.kind === 'synchronized').length === 2, 'resubscribed after reconnecting', 10_000)
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
