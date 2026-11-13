import test from 'node:test'
import assert from 'node:assert/strict'
import { createHash, randomUUID } from 'node:crypto'
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { createBotsService } from '../src/bots-service.mjs'
import { createBotConversationLibrary, createMemoryBotLibraryAdapter } from '../src/bots-library.mjs'
import { createClientExecution } from '../src/client-execution.mjs'
import { createLibraryHostSupervisor } from '../src/library-host.mjs'
import { createLibraryTimers } from '../src/library-timers.mjs'
import { enroll } from './fixtures/execution.mjs'

// Timers fire on the Linux machine whose library holds them, with every Mac
// offline (docs/architecture/WOVEN_EVERYWHERE.md, "Timers on a library host").

const fakeHost = resolve(import.meta.dirname, '../test-support/fake-library-host.mjs')

function scratch(t, prefix) {
  const directory = mkdtempSync(join('/tmp', prefix))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}
async function startedLibrary(t, directory) {
  const binary = join(directory, 'wovenmatter-library')
  writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${fakeHost}" "$@"\n`); chmodSync(binary, 0o700)
  const library = createLibraryHostSupervisor({ binary, dataRoot: join(directory, 'data'), statePath: join(directory, 'state/library/host.json'), minimumBackoff: 50 })
  t.after(() => library.stop())
  library.start()
  assert.ok(await library.whenReady(10_000))
  return library
}
async function workspace(t, library, { onTimersChanged } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'woven-timers-')), runs = []
  const runtime = { providers: async () => [{ id: 'default_agent', runtimeKind: 'default_agent', available: true }], create: async () => ({ sessionID: randomUUID() }),
    run: async ({ command }) => { runs.push(command) }, close: async () => {} }
  const service = createClientExecution({ directory, runtime, managedDataRoot: join(directory, 'databases'),
    publisherIntervalMilliseconds: 0, library: { client: library.client, available: library.available }, onTimersChanged })
  t.after(async () => { await service.close(); rmSync(directory, { recursive: true, force: true }) })
  const { principal: device } = enroll(service)
  const opened = await service.command({ commandID: randomUUID(), deviceID: device.id, kind: 'createSession' }, device)
  return { service, runs, id: opened.conversationID }
}
const call = (service, scope, name, input) => service.mcp.handle(scope, { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call', params: { name, arguments: input } })
const state = library => library.client.json('GET', '/v1/debug/state')
const until = async (check, what) => { for (let i = 0; i < 200; i++) { if (await check()) return; await new Promise(r => setTimeout(r, 10)) } assert.fail(what) }

test('a Linux session’s timer fires here and is delivered to the session with every Mac offline', async t => {
  const library = await startedLibrary(t, scratch(t, 'wt-session-'))
  let kicks = 0
  const { service, runs, id } = await workspace(t, library, { onTimersChanged: () => kicks++ })
  const scope = service.mcp.resolvePrincipal('Bearer ' + service.mcp.sessionConnection(id).bearerToken)
  const timers = createLibraryTimers({ library, deliverSession: (...args) => service.deliverTimer(...args) })
  const created = await call(service, scope, 'woven_timers_create', { at: new Date(Date.now() - 1000).toISOString(), text: 'Check the build', requestID: randomUUID() })
  assert.equal(created.result.isError, false, JSON.stringify(created))
  assert.equal(kicks, 1, 'a new timer wakes the dispatcher')
  await timers.runOnce()
  await until(() => runs.length === 1, 'the session ran the timer’s instruction')
  assert.equal(runs[0].text.startsWith('Check the build'), true)
  assert.equal(runs[0].conversationID, id)
  const { timers: saved, settlements } = await state(library)
  assert.deepEqual(settlements.map(item => item.outcome), ['accepted'])
  assert.equal(saved[0].paused, true, 'a one-shot timer ends once delivered')
  // Settled occurrences never repeat, and the delivery ID names the command.
  await timers.runOnce()
  assert.equal(runs.length, 1)
  assert.ok(['accepted', 'completed'].includes((await service.deliverTimer(id, 'Check the build', settlements[0].deliveryID)).status), 'a retried occurrence replays its receipt')
  assert.equal(runs.length, 1)
})

test('a timer for a session another workspace runs is cancelled here instead of retried forever', async t => {
  const library = await startedLibrary(t, scratch(t, 'wt-other-'))
  const { service, id } = await workspace(t, library)
  const scope = service.mcp.resolvePrincipal('Bearer ' + service.mcp.sessionConnection(id).bearerToken)
  const elsewhere = randomUUID()
  await call(service, scope, 'woven_timers_create', { at: new Date(Date.now() - 1000).toISOString(), text: 'x', session: elsewhere, requestID: randomUUID() })
  const timers = createLibraryTimers({ library, deliverSession: (...args) => service.deliverTimer(...args) })
  await timers.runOnce()
  const { settlements } = await state(library)
  assert.deepEqual(settlements.map(item => item.outcome), ['cancelled'])
})

// A minimal WebSocket endpoint standing in for the bots runtime's /ws.
function fakeRuntime(t, token) {
  const frames = [], headers = []
  const server = createServer()
  server.on('upgrade', (request, socket) => {
    headers.push(request.headers)
    if (request.headers.authorization !== 'Bearer ' + token) { socket.end('HTTP/1.1 401 Unauthorized\r\n\r\n'); return }
    const accept = createHash('sha1').update(request.headers['sec-websocket-key'] + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').digest('base64')
    socket.write(`HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ${accept}\r\n\r\n`)
    let buffer = Buffer.alloc(0)
    socket.on('data', chunk => {
      buffer = Buffer.concat([buffer, chunk])
      while (buffer.length >= 2) {
        const opcode = buffer[0] & 0x0f
        let length = buffer[1] & 0x7f, offset = 2
        if (length === 126) { length = buffer.readUInt16BE(2); offset = 4 }
        if (buffer.length < offset + 4 + length) return
        const mask = buffer.subarray(offset, offset + 4), payload = Buffer.from(buffer.subarray(offset + 4, offset + 4 + length)).map((byte, index) => byte ^ mask[index % 4])
        buffer = buffer.subarray(offset + 4 + length)
        if (opcode === 8) { socket.end(); return }
        if (opcode !== 1) continue
        const message = JSON.parse(Buffer.from(payload).toString('utf8')); frames.push(message)
        const reply = Buffer.from(JSON.stringify({ type: 'result', id: message.id, data: { conversationId: 'main', submissionId: 's1' } }))
        socket.write(Buffer.concat([Buffer.from(reply.length < 126 ? [0x81, reply.length] : [0x81, 126, reply.length >> 8, reply.length & 0xff]), reply]))
      }
    })
    socket.on('error', () => {})
  })
  t.after(() => server.close())
  return new Promise(resolve => server.listen(0, '127.0.0.1', () => resolve({ port: server.address().port, frames, headers })))
}

test('a bot schedules its own timer and is woken by it with every Mac offline', async t => {
  const directory = scratch(t, 'wt-bot-')
  const library = await startedLibrary(t, directory)
  const { service } = await workspace(t, library)
  const machine = (await library.client.identity()).deviceID, botID = randomUUID(), token = 'r'.repeat(43)
  const runtime = await fakeRuntime(t, token)
  const bots = createBotsService({ configuration: { stateDirectory: directory, dataRoot: directory, serviceRoot: directory, botsEnabled: true, workspaceEnabled: true, botsInstance: 'wmtest' },
    mcp: service.mcp, engine: { status: async () => ({ installed: false }) }, previews: { recover: async () => {}, close: async () => {} },
    runtime: { start() {}, stop: async () => {}, endpoint: () => ({ host: '127.0.0.1', port: runtime.port, token }), status: () => ({ running: true }) },
    library: createBotConversationLibrary(createMemoryBotLibraryAdapter()), machine: { deviceID: machine, name: 'box' }, serverPort: () => 1, authorizeClient: () => false, log: () => {} })
  // The bot's own Woven MCP key, as the runtime gets it from the host API.
  const key = service.mcp.issueBotKey({ botID, botName: 'Reporter', deviceID: machine })
  const scope = service.mcp.resolvePrincipal('Bearer ' + key.bearerToken)
  const listed = await service.mcp.handle(scope, { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })
  assert.ok(listed.result.tools.some(tool => tool.name === 'woven_timers_create'), 'bots get timers without a Mac')
  const created = await call(service, scope, 'woven_timers_create', { at: new Date(Date.now() - 1000).toISOString(), every: 3600, text: 'Post the morning report', requestID: randomUUID() })
  assert.equal(created.result.isError, false, JSON.stringify(created))
  const own = await call(service, scope, 'woven_timers_list', {})
  assert.equal(JSON.parse(own.result.content[0].text).rows.length, 1, 'the bot reads its own schedule (idle checks use it)')
  const timers = createLibraryTimers({ library, deliverSession: (...args) => service.deliverTimer(...args), deliverBot: delivery => bots.deliver(delivery) })
  await timers.runOnce()
  assert.equal(runtime.frames.length, 1)
  const [frame] = runtime.frames
  assert.equal(frame.type, 'message.send'); assert.equal(frame.botId, botID); assert.equal(frame.text, 'Post the morning report')
  const { timers: saved, settlements } = await state(library)
  assert.equal(frame.deliveryId, settlements[0].deliveryID, 'the runtime accepts each occurrence once by its delivery ID')
  assert.deepEqual(settlements.map(item => item.outcome), ['accepted'])
  assert.ok(saved[0].at > Date.now() + 3000_000 && !saved[0].paused, 'a repeating timer moves to its next time')
  assert.equal(runtime.headers[0].origin, undefined, 'the runtime sees no browser origin')
})

test('a delivery that fails is retried later and the dispatcher sleeps until the next timer', async t => {
  const occurrences = [{ timerID: randomUUID(), deliveryID: randomUUID(), target: randomUUID(), kind: 'session', text: 'x' }], settled = []
  const library = { available: () => true, client: { timersDue: async () => ({ occurrences: occurrences.splice(0), nextFireAt: new Date(Date.now() + 5000).toISOString() }), settleTimer: async body => { settled.push(body) } } }
  const timers = createLibraryTimers({ library, deliverSession: async () => { throw Object.assign(new Error('busy'), { statusCode: 503 }) }, deliverBot: null })
  t.after(() => timers.close())
  await timers.runOnce()
  assert.deepEqual(settled.map(item => item.outcome), ['retry'])
  const bot = createLibraryTimers({ library: { available: () => true, client: { timersDue: async () => ({ occurrences: [{ timerID: randomUUID(), deliveryID: randomUUID(), target: 'woven:bot:a:b', kind: 'bot', botID: randomUUID(), text: 'x' }] }), settleTimer: async body => { settled.push(body) } } }, deliverSession: async () => {} })
  t.after(() => bot.close())
  await bot.runOnce()
  assert.equal(settled.at(-1).outcome, 'retry', 'with bots off a bot occurrence waits')
})
