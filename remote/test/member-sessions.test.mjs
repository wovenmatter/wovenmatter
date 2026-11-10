import test from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { createClientExecution } from '../src/client-execution.mjs'
import { createLibraryHostSupervisor } from '../src/library-host.mjs'
import { createMemberVerifier } from '../src/member-auth.mjs'
import { createMemberTransport } from '../src/member-client.mjs'
import { enroll } from './fixtures/execution.mjs'

// A Linux session (or bot) drives a session it created on another Linux host
// through that host's execution API, signed, with every Mac offline
// (docs/architecture/WOVEN_EVERYWHERE.md, "Sessions across devices").

const fakeHost = resolve(import.meta.dirname, '../test-support/fake-library-host.mjs')
const loopback = value => /^http:\/\/127\.0\.0\.1:\d+\//.test(value)
const body = async request => { const chunks = []; for await (const chunk of request) chunks.push(chunk); return Buffer.concat(chunks) }
const send = (response, status, value) => { response.writeHead(status, { 'content-type': 'application/json' }); response.end(JSON.stringify(value)) }
const resultOf = reply => JSON.parse(reply.result.content[0].text)
const until = async (check, what) => { for (let i = 0; i < 300; i++) { if (await check()) return; await new Promise(r => setTimeout(r, 10)) } assert.fail(what) }

function scratch(t, prefix) {
  const directory = mkdtempSync(join('/tmp', prefix))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}
async function library(t, directory, environment) {
  const binary = join(directory, 'wovenmatter-library')
  writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${fakeHost}" "$@"\n`); chmodSync(binary, 0o700)
  const host = createLibraryHostSupervisor({ binary, dataRoot: join(directory, 'data'), statePath: join(directory, 'host.json'), environment: { ...process.env, ...environment }, minimumBackoff: 50 })
  t.after(() => host.stop())
  host.start()
  assert.ok(await host.whenReady(10_000))
  return host
}
// A runtime whose turns stay running until stopped, and that can ask a question.
function workspace(t, { enrolled = true, ...extra } = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'woven-member-sessions-')), runs = [], responses = [], stops = []
  const live = new Map()
  const runtime = {
    providers: async () => [{ id: 'default_agent', runtimeKind: 'default_agent', available: true, canStart: true }, { id: 'claude_code', runtimeKind: 'claude_code', available: true, canStart: true }],
    capabilities: async () => ({ canSteer: false }),
    create: async () => ({ sessionID: randomUUID() }),
    run: ({ command, interaction }) => new Promise(done => {
      runs.push(command); live.set(command.runID, done)
      if (command.text.startsWith('Ask first')) interaction({ id: 'question-1', kind: 'question', title: 'Which log?', options: [], questions: [{ id: 'log', prompt: 'Which log?', options: ['syslog', 'auth'] }] })
    }),
    respond: async ({ command }) => { responses.push(command.response) },
    stop: async ({ command }) => { stops.push(command.runID); live.get(command.runID)?.(); live.delete(command.runID) },
    close: async () => { for (const done of live.values()) done() },
  }
  const service = createClientExecution({ directory, runtime, managedDataRoot: join(directory, 'databases'), publisherKey: 'k'.repeat(40),
    publisherFetch: async () => { throw new Error('No Mac is reachable.') }, publisherIntervalMilliseconds: 0, ...extra })
  t.after(async () => { await service.close(); rmSync(directory, { recursive: true, force: true }) })
  return { service, runs, responses, stops, ...(enrolled ? enroll(service) : {}) }
}
async function session(f) {
  const opened = await f.service.command({ commandID: randomUUID(), deviceID: f.principal.id, kind: 'createSession' }, f.principal)
  const scope = f.service.mcp.resolvePrincipal('Bearer ' + f.service.mcp.sessionConnection(opened.conversationID).bearerToken)
  return { id: opened.conversationID, call: (name, input = {}) => f.service.mcp.handle(scope, { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call', params: { name, arguments: input } }) }
}

// Linux L and Linux M; the only Mac member is offline. M's server verifies L's
// signature and serves its execution API, as the Node server does.
async function hosts(t, prefix, { botsOnly = false } = {}) {
  const directory = scratch(t, prefix)
  const m = workspace(t), membersFile = join(directory, 'members.json'), workspacesFile = join(directory, 'workspaces.json')
  const lHost = await library(t, directory, { FAKE_LIBRARY_MEMBERS: membersFile, FAKE_LIBRARY_WORKSPACES: workspacesFile })
  const lIdentity = await lHost.client.identity()
  const offlineMac = { deviceID: randomUUID(), kind: 'mac', name: 'Studio Mac', publicKey: Buffer.alloc(32, 1).toString('base64'), endpoints: ['https://studio.invalid.ts.net:8443/wovenmatter'], revoked: false }
  const mDeviceID = randomUUID()
  const mMember = { deviceID: mDeviceID, kind: 'linux', name: 'Workstation M', publicKey: Buffer.alloc(32, 4).toString('base64'), endpoints: [], revoked: false }
  writeFileSync(membersFile, JSON.stringify({ revision: '1', members: [{ ...lIdentity, endpoints: [], revoked: false }, offlineMac, mMember] }))
  const verifier = createMemberVerifier({ loadMembers: async () => ({ revision: '1', members: [{ ...lIdentity, revoked: false }] }), audience: mDeviceID })
  t.after(() => verifier.close())
  const seen = []
  const server = createServer(async (request, response) => {
    try {
      const raw = await body(request), url = new URL(request.url.replace(/^\/wovenmatter-execution\/m/, ''), 'http://m'), path = url.pathname
      const member = await verifier.verify({ method: request.method, target: url.pathname + url.search, alternateTargets: ['/wovenmatter-execution/m' + url.pathname + url.search], headers: request.headers, body: raw })
      seen.push({ path, device: member.deviceID })
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
  t.after(() => new Promise(closed => { server.closeAllConnections(); server.close(closed) }))
  const port = await new Promise(done => server.listen(0, '127.0.0.1', () => done(server.address().port)))
  const mWorkspace = { id: m.enrollment.workspaceID, libraryID: m.enrollment.libraryID, ownerDeviceID: offlineMac.deviceID, executionDeviceID: mDeviceID, kind: 'linux', name: 'Workstation M',
    endpoint: `http://127.0.0.1:${port}/wovenmatter-execution/m/`, capabilities: [], journalDeviceIDs: [], revision: 1, deleted: false }
  writeFileSync(workspacesFile, JSON.stringify([mWorkspace]))
  const l = workspace(t, { enrolled: !botsOnly, library: { client: lHost.client, available: lHost.available },
    members: { transport: createMemberTransport({ library: lHost.client, allowEndpoint: loopback }), deviceID: () => lIdentity.deviceID, hasMac: () => false } })
  return { l, m, mWorkspace, lIdentity, seen }
}

test('a Linux session sends to, reads, answers and stops a session it created on another Linux host with every Mac offline', async t => {
  const { l, m, mWorkspace, lIdentity, seen } = await hosts(t, 'wm-manage-')
  const caller = await session(l)
  const created = await caller.call('woven_sessions_create', { workspace: mWorkspace.id, title: 'Index the logs', text: 'Ask first, then summarize', purpose: 'triage', requestID: randomUUID() })
  assert.equal(created.result.isError, false, JSON.stringify(created))
  const child = resultOf(created).session
  await until(() => m.service.interactions().length === 1, 'the remote turn asked its question')

  // Status needs only the session ID: the caller remembers where it runs.
  const status = resultOf(await caller.call('woven_sessions_status', { id: child.id }))
  assert.equal(status.session.workspace, mWorkspace.id); assert.equal(status.session.state, 'needsInput')
  assert.equal(status.pending[0].id, 'question-1'); assert.equal(status.pending[0].title, 'Which log?')
  assert.ok(status.transcript.messages.some(message => message.role === 'user' && message.content.includes('Ask first')))

  const answered = await caller.call('woven_sessions_respond', { id: child.id, interaction: 'question-1', answers: { log: ['auth'] }, requestID: randomUUID() })
  assert.equal(answered.result.isError, false, JSON.stringify(answered))
  assert.deepEqual(m.responses, [{ optionID: null, answers: { log: ['auth'] }, cancelled: false }])

  // A running turn whose harness cannot steer is not interrupted by a message.
  const busy = await caller.call('woven_sessions_send', { id: child.id, text: 'Also check dmesg', requestID: randomUUID() })
  assert.equal(busy.result.isError, true); assert.match(busy.result.content[0].text, /running/)

  const stopped = resultOf(await caller.call('woven_sessions_stop', { id: child.id, requestID: randomUUID() }))
  assert.equal(stopped.stopped, true); assert.equal(m.stops.length, 1)
  await until(() => !m.service.conversations().find(item => item.id === child.id).activeRunID, 'the remote run ended')

  const requestID = randomUUID()
  const sent = resultOf(await caller.call('woven_sessions_send', { id: child.id, text: 'Now check dmesg', requestID }))
  assert.ok(['accepted', 'completed'].includes(sent.receipt.status), JSON.stringify(sent))
  await until(() => m.runs.length === 2, 'the second message ran')
  assert.equal(m.runs[1].text.startsWith('Now check dmesg'), true)
  // A retried send replays its receipt.
  await caller.call('woven_sessions_send', { id: child.id, text: 'Now check dmesg', requestID })
  assert.equal(m.runs.length, 2)

  const listed = resultOf(await caller.call('woven_sessions_list', { workspace: mWorkspace.id }))
  assert.deepEqual(listed.rows.map(row => row.id), [child.id], 'only sessions the caller created, without history access to the workspace')
  assert.ok(seen.every(entry => entry.device === lIdentity.deviceID), 'every request was signed by L')

  // Another session on L may not read it without Conversation history.
  const stranger = await session(l)
  await l.service.command({ commandID: randomUUID(), deviceID: l.principal.id, kind: 'workspace', conversationID: stranger.id, workspaceAction: { sessionTools: { id: stranger.id, enabled: ['sessions'] } } }, l.principal)
  const refused = await stranger.call('woven_sessions_status', { id: child.id, workspace: mWorkspace.id })
  assert.equal(refused.result.isError, true); assert.match(refused.result.content[0].text, /sessions you created/)
})

test('a bot launches and manages sessions on another Linux host and on its own', async t => {
  const { l, m, mWorkspace, lIdentity } = await hosts(t, 'wm-botmanage-')
  const key = l.service.mcp.issueBotKey({ botID: randomUUID(), botName: 'Ops', deviceID: lIdentity.deviceID })
  const scope = l.service.mcp.resolvePrincipal('Bearer ' + key.bearerToken)
  const call = (name, input = {}) => l.service.mcp.handle(scope, { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call', params: { name, arguments: input } })
  const tools = (await l.service.mcp.handle(scope, { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })).result.tools.map(tool => tool.name)
  for (const name of ['woven_sessions_create', 'woven_sessions_send', 'woven_sessions_status', 'woven_sessions_stop', 'woven_sessions_respond', 'woven_sessions_list']) assert.ok(tools.includes(name), name)
  assert.ok(!tools.includes('woven_sessions_manage'), 'coordination binds a conversation')

  const remote = await call('woven_sessions_create', { workspace: mWorkspace.id, title: 'Remote job', text: 'Work remotely', purpose: 'p', harness: 'claude_code', requestID: randomUUID() })
  assert.equal(remote.result.isError, false, JSON.stringify(remote))
  const remoteID = resultOf(remote).session.id
  assert.equal(m.service.conversations().find(item => item.id === remoteID).runtimeKind, 'claude_code')
  const remoteStatus = resultOf(await call('woven_sessions_status', { id: remoteID }))
  assert.equal(remoteStatus.session.state, 'running')
  assert.equal(resultOf(await call('woven_sessions_stop', { id: remoteID, requestID: randomUUID() })).stopped, true)

  // With no workspace a bot's session runs on its own machine's workspace.
  const own = await call('woven_sessions_create', { title: 'Local job', text: 'Work here', purpose: 'p', requestID: randomUUID() })
  assert.equal(own.result.isError, false, JSON.stringify(own))
  const ownID = resultOf(own).session.id
  assert.equal(resultOf(own).session.workspace, l.enrollment.workspaceID)
  await until(() => l.runs.length === 1, 'the local session ran')
  assert.equal(resultOf(await call('woven_sessions_status', { id: ownID })).session.state, 'running')
  assert.equal(resultOf(await call('woven_sessions_stop', { id: ownID, requestID: randomUUID() })).stopped, true)
  const mine = resultOf(await call('woven_sessions_list'))
  assert.deepEqual(new Set(mine.rows.map(row => row.id)), new Set([remoteID, ownID]))
})

test('a bot on a bots-only host lists and launches harnesses on other workspaces', async t => {
  const { l, m, mWorkspace, lIdentity } = await hosts(t, 'wm-botsonly-', { botsOnly: true })
  const key = l.service.mcp.issueBotKey({ botID: randomUUID(), botName: 'Ops', deviceID: lIdentity.deviceID })
  const scope = l.service.mcp.resolvePrincipal('Bearer ' + key.bearerToken)
  const call = (name, input = {}) => l.service.mcp.handle(scope, { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call', params: { name, arguments: input } })
  const tools = (await l.service.mcp.handle(scope, { jsonrpc: '2.0', id: 1, method: 'tools/list', params: {} })).result.tools.map(tool => tool.name)
  assert.ok(tools.includes('woven_sessions_harnesses'))
  const listed = await call('woven_sessions_harnesses')
  assert.equal(listed.result.isError, false, JSON.stringify(listed))
  // No rows for this machine, which has no workspace; the other workspace's harnesses.
  const rows = resultOf(listed).rows
  assert.ok(rows.length > 0 && rows.every(row => row.workspace === mWorkspace.id && row.online), JSON.stringify(rows))
  const remote = await call('woven_sessions_create', { workspace: mWorkspace.id, title: 'Remote job', text: 'Work remotely', purpose: 'p', requestID: randomUUID() })
  assert.equal(remote.result.isError, false, JSON.stringify(remote))
  assert.ok(m.service.conversations().some(item => item.id === resultOf(remote).session.id))
  // A session "here" is refused with a reason, not an enrollment error.
  const here = await call('woven_sessions_create', { title: 'Local job', text: 'Work here', purpose: 'p', requestID: randomUUID() })
  assert.equal(here.result.isError, true)
  assert.match(JSON.stringify(here), /runs only bots/)
})
