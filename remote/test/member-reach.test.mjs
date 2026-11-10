import test from 'node:test'
import assert from 'node:assert/strict'
import { randomUUID } from 'node:crypto'
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { createClientExecution } from '../src/client-execution.mjs'
import { createHostAdministration } from '../src/host-admin.mjs'
import { createLibraryHostSupervisor } from '../src/library-host.mjs'
import { createMemberVerifier } from '../src/member-auth.mjs'
import { createMemberMacDelegate, createMemberTransport, tailnetEndpoint } from '../src/member-client.mjs'
import { enroll } from './fixtures/execution.mjs'

// Everything reaches everything (docs/architecture/WOVEN_EVERYWHERE.md,
// "Sessions across devices"): a Linux host signs its own requests to other
// members through its library host, with no Mac grant and every Mac offline.

const fakeHost = resolve(import.meta.dirname, '../test-support/fake-library-host.mjs')
const loopback = value => /^http:\/\/127\.0\.0\.1:\d+\//.test(value)

function scratch(t, prefix) {
  const directory = mkdtempSync(join('/tmp', prefix))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}
async function library(t, directory, environment = {}) {
  const binary = join(directory, 'wovenmatter-library')
  writeFileSync(binary, `#!/bin/sh\nexec "${process.execPath}" "${fakeHost}" "$@"\n`); chmodSync(binary, 0o700)
  const host = createLibraryHostSupervisor({ binary, dataRoot: join(directory, 'data'), statePath: join(directory, 'host.json'), environment: { ...process.env, ...environment }, minimumBackoff: 50 })
  t.after(() => host.stop())
  host.start()
  assert.ok(await host.whenReady(10_000))
  return host
}
function listen(t, handler) {
  return new Promise(done => {
    const server = createServer(async (request, response) => {
      try { await handler(request, response) } catch (error) { response.writeHead(error.statusCode ?? 500, { 'content-type': 'application/json' }); response.end(JSON.stringify({ error: error.message })) }
    })
    t.after(() => new Promise(closed => { server.closeAllConnections(); server.close(closed) }))
    server.listen(0, '127.0.0.1', () => done(server.address().port))
  })
}
const body = async request => { const chunks = []; for await (const chunk of request) chunks.push(chunk); return Buffer.concat(chunks) }
const send = (response, status, value) => { response.writeHead(status, { 'content-type': 'application/json' }); response.end(JSON.stringify(value)) }
function service(t, extra = {}) {
  const directory = mkdtempSync(join(tmpdir(), 'woven-member-reach-')), runs = []
  const runtime = { providers: async () => [{ id: 'default_agent', runtimeKind: 'default_agent', available: true, canStart: true }, { id: 'codex', runtimeKind: 'codex', available: true, canStart: true }],
    create: async () => ({ sessionID: randomUUID() }), run: async input => { runs.push(input) }, close: async () => {} }
  const value = createClientExecution({ directory, runtime, managedDataRoot: join(directory, 'databases'), publisherKey: 'k'.repeat(40),
    publisherFetch: async () => { throw new Error('No Mac is reachable.') }, publisherIntervalMilliseconds: 0, ...extra })
  t.after(async () => { await value.close(); rmSync(directory, { recursive: true, force: true }) })
  return { service: value, runs, ...enroll(value) }
}
async function session(f) {
  const opened = await f.service.command({ commandID: randomUUID(), deviceID: f.principal.id, kind: 'createSession' }, f.principal)
  const scope = f.service.mcp.resolvePrincipal('Bearer ' + f.service.mcp.sessionConnection(opened.conversationID).bearerToken)
  return { id: opened.conversationID, call: (name, input = {}) => f.service.mcp.handle(scope, { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call', params: { name, arguments: input } }) }
}
const resultOf = reply => JSON.parse(reply.result.content[0].text)
function closedPort() {
  return new Promise(done => { const probe = createServer(); probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => done(port)) }) })
}

test('only tailnet HTTPS endpoints are signed for', () => {
  assert.equal(tailnetEndpoint('https://studio.tail1234.ts.net:8443/wovenmatter'), true)
  for (const value of ['http://studio.tail1234.ts.net/', 'https://example.com/', 'https://user:pw@studio.tail1234.ts.net/', 'not a url']) assert.equal(tailnetEndpoint(value), false, value)
})

// Linux L creates a session on Linux M through M's own execution API. Every
// Mac is offline; L's request is signed by L's library host and M verifies it
// against the member list, as the Node server does.
test('a Linux host creates a session on another Linux host with every Mac offline', async t => {
  const directory = scratch(t, 'wm-ll-')
  const m = service(t), membersFile = join(directory, 'members.json'), workspacesFile = join(directory, 'workspaces.json')
  const lHost = await library(t, directory, { FAKE_LIBRARY_MEMBERS: membersFile, FAKE_LIBRARY_WORKSPACES: workspacesFile })
  const lIdentity = await lHost.client.identity()
  const offlineMac = { deviceID: randomUUID(), kind: 'mac', name: 'Studio Mac', publicKey: Buffer.alloc(32, 1).toString('base64'), endpoints: ['https://studio.invalid.ts.net:8443/wovenmatter'], revoked: false }
  // M's member entry, as L's library knows it once synced.
  const mDeviceID = randomUUID()
  const mMember = { deviceID: mDeviceID, kind: 'linux', name: 'Workstation M', publicKey: Buffer.alloc(32, 4).toString('base64'), endpoints: [], revoked: false }
  writeFileSync(membersFile, JSON.stringify({ revision: '1', members: [{ ...lIdentity, endpoints: [], revoked: false }, offlineMac, mMember] }))
  // M's server: signed members get execution scopes; the Serve prefix is restored for the check.
  const verifier = createMemberVerifier({ loadMembers: async () => ({ revision: '1', members: [{ ...lIdentity, revoked: false }] }), audience: mDeviceID })
  t.after(() => verifier.close())
  const seen = []
  const port = await listen(t, async (request, response) => {
    const raw = await body(request), path = request.url.replace(/^\/wovenmatter-execution\/m/, '')
    const member = await verifier.verify({ method: request.method, target: path, alternateTargets: ['/wovenmatter-execution/m' + path], headers: request.headers, body: raw })
    seen.push({ path, device: member.deviceID })
    const device = { id: member.deviceID, scopes: ['execution', 'inference'] }
    if (path === '/v1/execution/providers') return send(response, 200, await m.service.providers())
    if (path === '/v1/execution/commands' && request.method === 'POST') return send(response, 200, await m.service.command(JSON.parse(raw), device))
    send(response, 404, { error: 'not_found' })
  })
  const mWorkspace = { id: m.enrollment.workspaceID, libraryID: m.enrollment.libraryID, ownerDeviceID: offlineMac.deviceID, executionDeviceID: mDeviceID, kind: 'linux', name: 'Workstation M',
    endpoint: `http://127.0.0.1:${port}/wovenmatter-execution/m/`, capabilities: [], journalDeviceIDs: [], revision: 1, deleted: false }
  writeFileSync(workspacesFile, JSON.stringify([mWorkspace, { ...mWorkspace, id: randomUUID(), kind: 'ios', name: 'iPhone', endpoint: null }]))
  const l = service(t, { library: { client: lHost.client, available: lHost.available },
    members: { transport: createMemberTransport({ library: lHost.client, allowEndpoint: loopback }), deviceID: () => lIdentity.deviceID, hasMac: () => false } })
  const caller = await session(l)

  const input = { workspace: mWorkspace.id, title: 'Index the logs', text: 'Summarize /var/log', purpose: 'triage', harness: 'codex', requestID: randomUUID() }
  const created = await caller.call('woven_sessions_create', input)
  assert.equal(created.result.isError, false, JSON.stringify(created))
  const { session: child, independent, receipt } = resultOf(created)
  assert.equal(independent, true); assert.equal(child.workspace, mWorkspace.id); assert.equal(child.harness, 'codex')
  assert.ok(['accepted', 'completed'].includes(receipt.status), JSON.stringify(receipt))
  const remote = m.service.conversations().find(item => item.id === child.id)
  assert.equal(remote.title, 'Index the logs'); assert.equal(remote.runtimeKind, 'codex')
  assert.ok(seen.every(entry => entry.device === lIdentity.deviceID), 'every request was signed by L')
  // A retry with the same request ID replays receipts instead of creating again.
  assert.equal(resultOf(await caller.call('woven_sessions_create', input)).session.id, child.id)
  assert.equal(m.service.conversations().filter(item => item.id === child.id).length, 1)
  assert.equal(m.runs.length, 1, 'the first instruction was delivered once')
  // A workspace may also be named by its name; `local` and the iPhone are never destinations.
  assert.equal(resultOf(await caller.call('woven_sessions_create', { ...input, workspace: 'Workstation M', requestID: randomUUID() })).session.workspace, mWorkspace.id)
  const local = await caller.call('woven_sessions_create', { ...input, workspace: 'local', requestID: randomUUID() })
  assert.equal(local.result.isError, true); assert.match(local.result.content[0].text, new RegExp(l.enrollment.workspaceID))
  const phone = await caller.call('woven_sessions_create', { ...input, workspace: 'iPhone', requestID: randomUUID() })
  assert.equal(phone.result.isError, true); assert.match(phone.result.content[0].text, /iPhone runs only its own Quick Chats/)
  // This workspace by ID still creates a coordinated session here.
  const here = await caller.call('woven_sessions_create', { ...input, workspace: l.enrollment.workspaceID, requestID: randomUUID() })
  assert.equal(here.result.isError, false, JSON.stringify(here)); assert.equal(resultOf(here).relationship.coordinatorID, caller.id)

  // The harness list names every workspace by ID: this one, then M.
  const harnesses = resultOf(await caller.call('woven_sessions_harnesses'))
  assert.deepEqual([...new Set(harnesses.rows.map(row => row.workspace))], [l.enrollment.workspaceID, mWorkspace.id])
  assert.ok(harnesses.rows.some(row => row.workspace === mWorkspace.id && row.harness === 'codex' && row.ready && row.workspaceName === 'Workstation M'))
  assert.ok(!harnesses.rows.some(row => row.workspaceKind === 'ios'))
})

// Timers and usage are Mac-only tools: any reachable Mac member serves them,
// signed with the Linux host's key; no single-Mac grant is needed.
test('Mac-only tools go to any reachable Mac member with a signed request', async t => {
  const directory = scratch(t, 'wm-mac-')
  const membersFile = join(directory, 'members.json'), syncFile = join(directory, 'sync.json')
  const lHost = await library(t, directory, { FAKE_LIBRARY_MEMBERS: membersFile, FAKE_LIBRARY_SYNC: syncFile })
  const lIdentity = await lHost.client.identity()
  // Both Macs share this test server's verifier, so it accepts either audience.
  const verifiers = new Map()
  const verifierFor = audience => verifiers.get(audience) ?? verifiers.set(audience, createMemberVerifier({ loadMembers: async () => ({ revision: '1', members: [{ ...lIdentity, revoked: false }] }), audience })).get(audience)
  t.after(() => { for (const value of verifiers.values()) value.close() })
  const calls = []
  const port = await listen(t, async (request, response) => {
    const raw = await body(request)
    const member = await verifierFor(request.headers['x-woven-member-audience']).verify({ method: request.method, target: request.url, headers: request.headers, body: raw })
    calls.push({ path: request.url, device: member.deviceID, headers: request.headers, message: JSON.parse(raw) })
    if (request.url === '/wovenmatter/mcp/workspace') {
      const message = JSON.parse(raw)
      return send(response, 200, { jsonrpc: '2.0', id: message.id, result: { content: [{ type: 'text', text: JSON.stringify({ rows: [] }) }], structuredContent: { success: true }, isError: false } })
    }
    send(response, 404, { error: 'not_found' })
  })
  // The Mac reported online is unreachable, so the next Mac answers.
  const offline = { deviceID: randomUUID(), kind: 'mac', name: 'Laptop', publicKey: Buffer.alloc(32, 2).toString('base64'), endpoints: [`http://127.0.0.1:${await closedPort()}/wovenmatter`], revoked: false }
  const online = { deviceID: randomUUID(), kind: 'mac', name: 'Studio', publicKey: Buffer.alloc(32, 3).toString('base64'), endpoints: [`http://127.0.0.1:${port}/wovenmatter`], revoked: false }
  writeFileSync(membersFile, JSON.stringify({ revision: '1', members: [offline, online] }))
  writeFileSync(syncFile, JSON.stringify({ peers: [{ deviceID: offline.deviceID, state: 'online' }, { deviceID: online.deviceID, state: 'offline' }] }))
  const l = service(t, { library: { client: lHost.client, available: lHost.available },
    members: { transport: createMemberTransport({ library: lHost.client, allowEndpoint: loopback }), deviceID: () => lIdentity.deviceID, hasMac: () => true } })
  assert.equal(l.service.mcp.libraryStatus().configured, false, 'no Mac grant exists')
  const caller = await session(l)
  const usage = await caller.call('woven_usage_read')
  assert.equal(usage.result.isError, false, JSON.stringify(usage))
  const [call] = calls
  assert.equal(call.device, lIdentity.deviceID)
  assert.equal(call.headers['x-woven-workspace-id'], l.enrollment.workspaceID)
  assert.equal(call.headers['x-woven-conversation-id'], caller.id)
  assert.equal(call.headers.authorization, undefined, 'no bearer is sent')
  assert.equal(call.message.params.name, 'woven_usage_read')
  // Session folders are library rows and timers fire here: both come from this host's own library.
  const folders = await caller.call('woven_sessions_folders')
  assert.equal(folders.result.isError, false, JSON.stringify(folders))
  assert.equal((await caller.call('woven_timers_list')).result.isError, false)
  assert.equal(calls.length, 1)
})

test('bots use this host’s library as app-wide callers and never get Mac-only tools', async t => {
  const directory = scratch(t, 'wm-bot-'), logPath = join(directory, 'requests.jsonl')
  const lHost = await library(t, directory, { FAKE_LIBRARY_LOG: logPath })
  const l = service(t, { library: { client: lHost.client, available: lHost.available },
    members: { transport: createMemberTransport({ library: lHost.client, allowEndpoint: loopback }), deviceID: () => randomUUID(), hasMac: () => true } })
  const machine = randomUUID(), botID = randomUUID()
  const key = l.service.mcp.issueBotKey({ botID, botName: 'Ops Bot', deviceID: machine })
  const scope = l.service.mcp.resolvePrincipal('Bearer ' + key.bearerToken)
  const call = (name, input = {}) => l.service.mcp.handle(scope, { jsonrpc: '2.0', id: randomUUID(), method: 'tools/call', params: { name, arguments: input } })
  const note = await call('woven_notes_create', { title: 'From a bot' })
  assert.equal(note.result.isError, false, JSON.stringify(note))
  const { readFileSync } = await import('node:fs')
  const request = readFileSync(logPath, 'utf8').trim().split('\n').map(line => JSON.parse(line)).find(entry => entry.path === '/v1/mcp')
  assert.equal(request.headers['x-woven-caller'], `woven:bot:${machine}:${botID}`)
  assert.equal(request.headers['x-woven-bot-id'], botID)
  assert.equal(decodeURIComponent(request.headers['x-woven-bot-name']), 'Ops Bot')
  assert.equal(request.headers['x-woven-conversation-id'], undefined)
  assert.equal((await call('woven_usage_read')).error?.code, -32602, 'a Mac’s /mcp/workspace binds conversations, so bots never get Mac-only tools')
  // A bot's timers are its schedule, kept and fired by this host's library.
  assert.equal((await call('woven_timers_list')).result?.isError, false)
})

// The installer's bearer adopts the first Mac; after that only a signed Mac
// member may hand this host member records, which reach the library unchanged,
// even once every Mac was removed: a host adopted once stays adopted.
test('member adoption takes the installer bearer only until the host was adopted', async t => {
  let adopted = false
  const forwarded = []
  const admin = createHostAdministration({ serviceRoot: '/nonexistent', dataRoot: '/nonexistent', stateDirectory: scratch(t, 'wm-adopt-'),
    adoptMembers: async raw => { forwarded.push(raw); adopted = true; return { revision: '2', members: [], adopted: true } }, adopted: async () => adopted })
  const payload = Buffer.from('{"anchor":{"deviceID":"x"},"entries":[],  "revocations":[]}')
  async function adopt(context) {
    const reply = {}
    const request = { method: 'POST', wovenBody: payload }
    await admin.handle(request, null, new URL('http://localhost/v1/host/members/adopt'), { json: (_, status, value) => Object.assign(reply, { status, value }),
      readJSON: async () => ({}), readBody: async () => payload, administrator: true, ...context })
    return reply.status
  }
  assert.equal(await adopt({ member: { kind: 'ios' } }), 403)
  assert.equal(await adopt({ installer: true }), 200, 'the first adoption')
  assert.ok(forwarded[0].equals(payload), 'the body is forwarded byte for byte')
  assert.equal(await adopt({ installer: true }), 403, 'later adoptions need a signed Mac')
  assert.equal(await adopt({ member: { kind: 'linux' } }), 403)
  assert.equal(await adopt({ member: { kind: 'mac' } }), 200)
  // With every Mac removed the host has no Mac member, yet stays adopted.
  assert.equal(await adopt({ installer: true }), 403, 'the bearer never re-adopts')
})

// A Linux host's registry row names its Node server's own execution device ID; the
// audience is the member serving that endpoint's host, from synced records only.
test('the audience of a workspace comes from the member list and registry, never the endpoint', async () => {
  const id = n => `0000000${n}-0000-4000-8000-00000000000${n}`
  let members = [{ deviceID: id(1), kind: 'mac', endpoints: ['https://studio.tail1.ts.net:8443/wovenmatter'], revoked: false },
    { deviceID: id(2), kind: 'linux', endpoints: ['https://box.tail1.ts.net:8443/wovenmatter/'], revoked: false }]
  const transport = createMemberTransport({ library: { members: async () => ({ members }) } })
  const box = { id: 'w', kind: 'linux', executionDeviceID: id(3), endpoint: 'https://box.tail1.ts.net/wovenmatter-execution/w' }
  assert.equal(await transport.audienceFor(box), id(2))
  assert.equal(await transport.audienceFor({ ...box, endpoint: 'https://other.tail1.ts.net/wovenmatter-execution/w' }), null)
  assert.equal(await transport.audienceFor({ id: 'm', kind: 'mac', executionDeviceID: id(1), endpoint: 'https://studio.tail1.ts.net:8443/wovenmatter' }), id(1))
  assert.equal(await transport.audienceFor({ id: 'm', kind: 'mac', executionDeviceID: id(5), endpoint: 'https://mini.tail1.ts.net:8443/wovenmatter' }), id(5), 'a Mac workspace names its member ID')
  assert.equal(await transport.audienceFor({ ...box, kind: 'ios' }), null)
  members = [...members, { deviceID: id(4), kind: 'linux', endpoints: ['https://box.tail1.ts.net/wovenmatter/'], revoked: false }]
  assert.equal(await transport.audienceFor(box), null, 'two members claiming one host serve nothing')
  members = [{ ...members[0], revoked: true }]
  assert.equal(await transport.audienceFor({ id: 'm', kind: 'mac', executionDeviceID: id(1) }), null, 'a removed Mac is not addressed')
  await assert.rejects(transport.request('https://box.tail1.ts.net/wovenmatter-execution/w/v1/execution', { audience: box }), error => error.code === 'member_audience_unknown')
})

// A scheduled task's prepare record is not synced, so its calls must reach a
// Mac that holds it, whichever Mac answers first.
test('a scheduled task’s Mac-only calls go to a Mac that prepared it', async () => {
  const studio = { deviceID: randomUUID(), name: 'Studio', endpoint: 'https://studio.tail.ts.net/wovenmatter' }
  const laptop = { deviceID: randomUUID(), name: 'Laptop', endpoint: 'https://laptop.tail.ts.net/wovenmatter' }
  const prepared = new Set(), calls = [], down = new Set()
  let order = [studio, laptop]
  const transport = {
    macs: async () => order,
    request: async (url, { audience, headers }) => {
      const mac = audience === studio.deviceID ? 'Studio' : 'Laptop', path = url.pathname.replace('/wovenmatter/', '')
      const record = audience + ':' + headers['x-woven-conversation-id']
      calls.push(`${mac} ${path}`)
      if (down.has(audience)) throw Object.assign(new Error('offline'), { code: 'member_unreachable' })
      if (path === 'mcp/workspace/prepare') { prepared.add(record); return { status: 200, body: { enabledGroups: ['usage'] } } }
      // A Mac without the record refuses before any effect, as the real one does.
      return prepared.has(record) ? { status: 200, body: { jsonrpc: '2.0', id: 1, result: {} } } : { status: 403, body: { message: 'wrong_owner' } }
    },
  }
  const delegate = createMemberMacDelegate({ transport, workspaceID: () => randomUUID() })
  const task = { conversationID: randomUUID(), taskProof: { run: { id: randomUUID() }, eventRevision: 1 } }
  const message = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'woven_usage_read', arguments: {} } }

  assert.deepEqual(await delegate.prepare(task), { enabledGroups: ['usage'] })
  // The Macs' order changed since (another came online): the call still goes to the Mac that prepared it.
  order = [laptop, studio]; calls.length = 0
  assert.ok(await delegate.call(task, message))
  assert.deepEqual(calls, ['Studio mcp/workspace'])
  // That Mac went offline: the next is prepared before it is asked.
  down.add(studio.deviceID); calls.length = 0
  assert.ok(await delegate.call(task, message))
  assert.deepEqual(calls, ['Studio mcp/workspace', 'Laptop mcp/workspace/prepare', 'Laptop mcp/workspace'])
  // Conversation calls are unchanged: the first Mac that answers serves them.
  down.clear(); calls.length = 0
  await assert.rejects(delegate.call({ conversationID: randomUUID() }, message), error => error.statusCode === 503)
  assert.deepEqual(calls, ['Laptop mcp/workspace', 'Studio mcp/workspace'])
})
