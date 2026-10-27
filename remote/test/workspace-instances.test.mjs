import { test } from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'
import { createServer } from 'node:http'
import { Readable, Writable } from 'node:stream'
import { createWorkspaceInstances } from '../src/workspace-instances.mjs'

const fixtureVersion = '2.0.22'
const info = { url: 'http://127.0.0.1:43210', pid: 1234, password: 'host-secret', version: fixtureVersion }
function fixture(overrides = {}) {
  return createWorkspaceInstances({
    workspaceRoot: '/remote/project', environment: () => ({ PATH: '/host/bin', HOME: '/host/home' }), acquireLock: async () => () => {},
    readFile: async () => JSON.stringify(info), signal: () => {}, installMCP: () => {},
    fetch: async (_url, options) => {
      assert.equal(_url.pathname, '/api/info')
      assert.equal(options.headers.authorization, 'Basic ' + Buffer.from('opencode:host-secret').toString('base64'))
      assert.equal(options.redirect, 'error')
      return { ok: true, json: async () => ({ healthy: true, pid: info.pid, version: fixtureVersion }) }
    }, ...overrides,
  })
}

test('reject non-loopback, credentials in URL, malformed PID and incompatible services before any mutation', async () => {
  for (const patch of [{ url: 'http://example.com' }, { url: 'http://user:secret@127.0.0.1' }, { pid: -1 }]) {
    const instances = fixture({ readFile: async () => JSON.stringify({ ...info, ...patch }) })
    assert.equal((await instances.status('opencode')).state, 'unavailable')
    await assert.rejects(instances.action('opencode', 'stop'), /registration_invalid/)
  }
  const incompatible = fixture({ fetch: async () => ({ ok: true, json: async () => ({ healthy: true, pid: info.pid, version: '1.0.0' }) }) })
  await assert.rejects(incompatible.action('opencode', 'stop'), /version_incompatible/)
})

test('startup is serialized, version checked, loopback bound and workspace state isolated', async () => {
  let registered = false, release, ownedChild, unlocks = 0
  const gate = new Promise((done) => { release = done })
  const instances = fixture({
    readFile: async () => { if (!registered) throw Object.assign(new Error(), { code: 'ENOENT' }); return JSON.stringify(info) },
    execFile: async (command, args) => { assert.equal(command, 'opencode'); assert.deepEqual(args, ['--version']); await gate; return { stdout: fixtureVersion } },
    mkdir: async () => {},
    acquireLock: async (path, _environment, _cwd, shared) => {
      assert.equal(path, '/host/home/.wovenmatter/runtime-operation.lock'); assert.equal(shared, true)
      return () => { unlocks++ }
    },
    spawn: (command, args, options) => {
      assert.equal(command, 'opencode')
      assert.deepEqual(args, ['serve', '--service', '--hostname', '127.0.0.1'])
      assert.equal(options.env.XDG_STATE_HOME, '/remote/project/.woven-matter/opencode-state')
      assert.equal(options.cwd, '/remote/project')
      registered = true
      ownedChild = Object.assign(new EventEmitter(), { exitCode: null })
      return ownedChild
    },
  })
  const first = instances.action('opencode', 'start')
  await assert.rejects(instances.action('opencode', 'start'), /operation_in_progress/)
  release(); await first
  const publicStatus = await instances.status('opencode')
  assert.equal(JSON.stringify(publicStatus).includes(info.password), false)
  assert.equal(JSON.stringify(publicStatus).includes(Buffer.from('opencode:' + info.password).toString('base64')), false)
  assert.equal(unlocks, 0, 'server must hold lock after startup completes')
  ownedChild.exitCode = 0; ownedChild.emit('close', 0)
  assert.equal(unlocks, 1)
})


test('streaming proxy uses host Basic auth, strips client bearer and cookies, preserves SSE', async () => {
  let recorded
  const upstream = createServer((request, response) => {
    recorded = { url: request.url, headers: request.headers }
    response.writeHead(200, { 'content-type': 'text/event-stream', 'set-cookie': 'secret=x' })
    response.write('data: {"part":1}\n\n'); response.end('data: {"part":2}\n\n')
  })
  await new Promise((done) => upstream.listen(0, '127.0.0.1', done))
  try {
    const instances = fixture({ readFile: async () => JSON.stringify({ ...info, url: `http://127.0.0.1:${upstream.address().port}` }) })
    const request = Readable.from([])
    request.method = 'GET'; request.headers = { authorization: 'Bearer client-secret', cookie: 'private', accept: 'text/event-stream' }
    const chunks = [], headers = {}
    const response = new Writable({ write(chunk, _encoding, done) { chunks.push(chunk); done() } })
    response.setHeader = (key, value) => { headers[key] = value }
    await instances.handle(request, response, new URL('http://host/v1/workspace-instances/opencode/api/event?cursor=17'))
    assert.equal(recorded.url, '/api/event?cursor=17')
    assert.equal(recorded.headers.authorization, 'Basic ' + Buffer.from('opencode:host-secret').toString('base64'))
    assert.equal(recorded.headers.cookie, undefined)
    assert.equal(headers['set-cookie'], undefined)
    assert.match(Buffer.concat(chunks).toString(), /"part":2/)
    const fileRequest = Readable.from([])
    fileRequest.method = 'GET'; fileRequest.headers = {}
    const fileResponse = new Writable({ write(_chunk, _encoding, done) { done() } })
    fileResponse.setHeader = () => {}
    await instances.handle(fileRequest, fileResponse, new URL('http://host/v1/workspace-instances/opencode/api/fs/read/%2Fremote%2Ffile%2Etxt'))
    assert.equal(recorded.url, '/api/fs/read/%2Fremote%2Ffile%2Etxt')
  } finally { await new Promise((done) => upstream.close(done)) }
})
