import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { EventEmitter, once } from 'node:events'
import { PassThrough, Writable } from 'node:stream'
import { createHash, randomBytes } from 'node:crypto'
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { createServer as createNetServer } from 'node:net'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { authenticationInput, authenticationDeadline, downloadInstallerSource, probeHarnessTransport } from '../src/server.mjs'












const repositoryRoot = resolve(import.meta.dirname, '../..')
const catalogPath = resolve(repositoryRoot, 'harnesses/catalog.json')

test('installer download rejects non-HTTPS sources and redirect destinations', async () => {
  let requests = 0
  const fetchImplementation = async () => {
    requests += 1
    return installerResponse([], {
      status: 302,
      url: 'https://downloads.example.test/install',
      headers: { location: 'http://downloads.example.test/insecure.sh' },
    }).response
  }

  await assert.rejects(
    downloadInstallerSource('http://downloads.example.test/install', {
      fetchImplementation,
    }),
    { message: 'installer_https_required' }
  )
  assert.equal(requests, 0)

  await assert.rejects(
    downloadInstallerSource('https://downloads.example.test/install', {
      fetchImplementation,
    }),
    { message: 'installer_https_required' }
  )
  assert.equal(requests, 1, 'an insecure redirect must be rejected before it is fetched')

  const insecureFinal = installerResponse([Buffer.from('unsafe')], {
    url: 'http://downloads.example.test/final.sh',
  })
  await assert.rejects(
    downloadInstallerSource('https://downloads.example.test/install', {
      fetchImplementation: async () => insecureFinal.response,
    }),
    { message: 'installer_https_required' }
  )
  assert.equal(insecureFinal.wasCancelled(), true)
})

test('installer download cancels a stream as soon as it exceeds the byte limit', async () => {
  const oversized = installerResponse([
    Buffer.alloc(4, 'a'),
    Buffer.alloc(4, 'b'),
    Buffer.alloc(4, 'c'),
  ], { url: 'https://downloads.example.test/install.sh' })

  await assert.rejects(
    downloadInstallerSource('https://downloads.example.test/install.sh', {
      maximumBytes: 5,
      fetchImplementation: async () => oversized.response,
    }),
    { message: 'invalid_installer_size' }
  )
  assert.equal(oversized.pulls(), 2)
  assert.equal(oversized.wasCancelled(), true)

  const declaredOversized = installerResponse([Buffer.alloc(1)], {
    url: 'https://downloads.example.test/declared.sh',
    headers: { 'content-length': '6' },
  })
  await assert.rejects(
    downloadInstallerSource('https://downloads.example.test/declared.sh', {
      maximumBytes: 5,
      fetchImplementation: async () => declaredOversized.response,
    }),
    { message: 'invalid_installer_size' }
  )
  assert.equal(declaredOversized.pulls(), 0)
  assert.equal(declaredOversized.wasCancelled(), true)
})

test('installer download aborts a stalled request at its deadline', async () => {
  let signal
  await assert.rejects(
    downloadInstallerSource('https://downloads.example.test/stalled.sh', {
      timeoutMilliseconds: 10,
      fetchImplementation: async (_url, options) => {
        signal = options.signal
        return new Promise(() => {})
      },
    }),
    { message: 'installer_download_timed_out' }
  )
  assert.equal(signal.aborted, true)
})

for (const outcome of ['exit', 'cancel', 'timeout']) {
  test(`authorization input rechecks ${outcome} after the request body arrives`, async () => {
    let writes = 0
    const input = new Writable({ write(_chunk, _encoding, callback) { writes++; callback() } })
    const session = { child: { stdin: input }, method: { acceptsInput: true }, state: 'waiting_for_user' }
    const submit = authenticationInput(session)
    let finishBody
    const pending = submit(() => new Promise(resolve => { finishBody = resolve }))
    if (outcome === 'exit') { session.child = null; session.state = 'failed' }
    if (outcome === 'cancel') session.cancelRequested = true
    if (outcome === 'timeout') { session.timedOut = true; session.error = 'Sign-in timed out.' }
    finishBody({ code: 'fixture-code' })
    await assert.rejects(pending, { statusCode: 409, message: 'authentication_session_not_active' })
    assert.equal(writes, 0)
    input.destroy()
  })
}

test('native sign-in reports a real handoff and verifies provider state', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-sign-in-')
  const home = resolve(fixture, 'home')
  const workspace = resolve(fixture, 'workspace')
  const bin = resolve(home, '.local/bin')
  const authenticated = resolve(fixture, 'authenticated')
  await mkdir(bin, { recursive: true })
  await mkdir(workspace, { recursive: true })
  const codexCLI = resolve(bin, 'codex')
  await writeFile(codexCLI, '#!/bin/sh\nexit 0\n')
  await chmod(codexCLI, 0o700)
  const codexACP = resolve(bin, 'codex-acp')
  await writeFile(codexACP, fakeACPExecutable())
  await chmod(codexACP, 0o700)

  const catalog = JSON.parse(await readFile(catalogPath, 'utf8'))
  const codex = catalog.harnesses.find((value) => value.id === 'codex')
  const testCatalog = resolve(fixture, 'catalog.json')
  await writeFile(testCatalog, JSON.stringify({
    schemaVersion: 4,
    harnesses: [{
      ...codex,
      authentication: {
        ...codex.authentication,
        statusCommands: [`test -f '${authenticated}'`],
        discoveries: [{
          displayName: 'Codex account',
          statusCommand: `test -f '${authenticated}'`,
        }],
        methods: [{
          ...codex.authentication.methods[0],
          acceptsInput: true,
          command: `printf 'Open https://example.test/device\\nDevice code ABCD-EFGH\\n'; touch '${authenticated}'`,
        }],
      },
    }],
  }))

  const service = await startService({
    workspace,
    home,
    catalog: testCatalog,
    token: 'sign-in-token',
  })
  context.after(() => stopService(service.child))
  const headers = {
    authorization: 'Bearer sign-in-token',
    'content-type': 'application/json',
  }
  const started = await fetch(`${service.url}/v1/harnesses/codex/sign-in`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ methodID: 'chatgpt' }),
  })
  assert.equal(started.status, 201)
  const session = await waitFor(
    `${service.url}/v1/authentication-sessions/${(await started.json()).id}`,
    headers,
    (value) => value.state !== 'waiting_for_user'
  )
  assert.equal(session.state, 'succeeded')
  assert.equal(session.verificationURL, 'https://example.test/device')
  assert.equal(session.userCode, 'ABCD-EFGH')
  const harnessDocument = await waitFor(
    `${service.url}/v1/harnesses`,
    headers,
    (value) => value.harnesses.find(h => h.id === 'codex').state === 'ready'
  )
  assert.equal(harnessDocument.harnesses.find(h => h.id === 'codex').authenticationStatus, 'configured')
  const terminalAuthorizationCode = await fetch(
    `${service.url}/v1/authentication-sessions/${session.id}/authorization-code`,
    { method: 'POST', headers, body: JSON.stringify({ code: 'too-late' }) }
  )
  assert.equal(terminalAuthorizationCode.status, 409)
  assert.equal(
    (await terminalAuthorizationCode.json()).error,
    'authentication_session_not_active'
  )
  const terminalCancellation = await fetch(
    `${service.url}/v1/authentication-sessions/${session.id}`,
    { method: 'DELETE', headers }
  )
  assert.equal(terminalCancellation.status, 409)
  assert.equal((await terminalCancellation.json()).error, 'authentication_session_not_active')
})

test('harness readiness requires a real bounded transport handshake', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-transport-ready-')
  const home = resolve(fixture, 'home')
  const workspace = resolve(fixture, 'workspace')
  const bin = resolve(home, '.local/bin')
  const authenticated = resolve(fixture, 'authenticated')
  await mkdir(bin, { recursive: true })
  await mkdir(workspace, { recursive: true })
  await writeFile(authenticated, 'ready')

  const working = resolve(bin, 'working-acp')
  await writeFile(working, fakeACPExecutable())
  await chmod(working, 0o700)
  const broken = resolve(bin, 'broken-acp')
  await writeFile(broken, '#!/bin/sh\nexit 0\n')
  await chmod(broken, 0o700)

  const harness = (id, displayName, command) => ({
    id,
    displayName,
    transport: 'acp',
    command,
    arguments: [],
    cliCommand: command,
    install: { kind: 'npm-global', source: 'https://example.test', command: 'true' },
    authentication: {
      statusCommands: [`test -f '${authenticated}'`],
      discoveries: [],
      methods: [{ id: 'test', displayName: 'Test', command: 'true' }],
    },
    capabilities: ['conversations'],
  })
  const testCatalog = resolve(fixture, 'catalog.json')
  await writeFile(testCatalog, JSON.stringify({
    schemaVersion: 4,
    harnesses: [
      harness('codex', 'Working ACP', 'working-acp'),
      harness('claude_code', 'Broken ACP', 'broken-acp'),
    ],
  }))

  const service = await startService({
    workspace,
    home,
    catalog: testCatalog,
    token: 'transport-token',
  })
  context.after(() => stopService(service.child))
  const response = await fetch(`${service.url}/v1/harnesses`, {
    headers: { authorization: 'Bearer transport-token' },
  })
  assert.equal(response.status, 200)
  const statuses = (await response.json()).harnesses.filter(h => h.id !== 'default_agent')
  assert.equal(statuses[0].state, 'ready')
  assert.equal(statuses[0].transportStatus, 'ready')
  assert.equal(statuses[0].transportError, null)
  assert.equal(statuses[1].state, 'transport_unavailable')
  assert.equal(statuses[1].transportStatus, 'unavailable')
  assert.match(statuses[1].transportError, /before readiness/)
})

async function temporaryFixture(context, prefix) {
  const directory = await mkdtemp(resolve(tmpdir(), prefix))
  context.after(() => rm(directory, { recursive: true, force: true }))
  return directory
}

test('database routes require authentication and keep managed data outside project roots', async context => {
  const root = await temporaryFixture(context, 'wovenmatter-database-api-')
  const home = resolve(root, 'home')
  await mkdir(home)
  const service = await startService({ workspace: root, home, catalog: catalogPath, token: 'database-token' })
  context.after(() => stopService(service.child))
  const request = (path, method = 'GET', body, token = 'database-token') => fetch(service.url + path, {
    method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  assert.equal((await request('/v1/databases', 'GET', undefined, 'wrong')).status, 401)
  assert.equal((await request('/v1/databases', 'POST', { name: 'Denied' }, 'wrong')).status, 401)
  const created = await request('/v1/databases', 'POST', { name: 'Sales', root: '/tmp/ignored', action: 'list' })
  assert.equal(created.status, 200)
  const row = await created.json()
  assert.match(row.id, /^[0-9a-f-]{36}$/)
  assert.equal(row.name, 'Sales')
  assert.equal(row.preference, 'sqlite')
  assert.equal(row.url, new URL('file://' + resolve(home, '.local/share/wovenmatter/databases', row.id + '.sqlite')).href)
  const committed = await request('/v1/databases/execute', 'POST', {
    databaseID: row.id, sql: 'CREATE TABLE sales(value); INSERT INTO sales VALUES(42)', root: '/tmp/ignored' })
  assert.equal(committed.status, 200)
  assert.equal((await committed.json()).revision, 2)
  const read = await request('/v1/databases/data', 'POST', { databaseID: row.id, sqliteQuery: 'SELECT value FROM sales' })
  assert.deepEqual((await read.json()).query.rows, [['42']])
  const snapshotResponse = await request('/v1/databases/snapshot', 'POST', { databaseID: row.id })
  const snapshot = await snapshotResponse.json()
  const copiedResponse = await request('/v1/databases/copy', 'POST', { name: 'Sales copy', snapshot })
  assert.equal(copiedResponse.status, 200)
  const copy = await copiedResponse.json()
  assert.notEqual(copy.id, row.id)
  const listed = await (await request('/v1/databases')).json()
  assert.deepEqual(listed.databases.map(value => value.name), ['Sales', 'Sales copy'])
  const largeWrite = await request('/v1/databases/execute', 'POST', {
    databaseID: row.id, sql: 'CREATE TABLE payload(value); INSERT INTO payload VALUES(zeroblob(900000))' })
  assert.equal(largeWrite.status, 200)
  const largeSnapshot = await (await request('/v1/databases/snapshot', 'POST', { databaseID: row.id })).json()
  assert.ok(Buffer.byteLength(JSON.stringify(largeSnapshot)) > 1_048_576)
  const largeCopy = await request('/v1/databases/copy', 'POST', { name: 'Large copy', snapshot: largeSnapshot })
  assert.equal(largeCopy.status, 200)
  const copiedID = (await largeCopy.json()).id
  assert.deepEqual((await (await request('/v1/databases/query', 'POST', {
    databaseID: copiedID, sql: 'SELECT length(value) AS bytes FROM payload' })).json()).query.rows, [['900000']])
  assert.equal((await request('/v1/databases/execute', 'POST', { databaseID: '../Sales', sql: 'DELETE FROM sales' })).status, 400)
  assert.equal((await request('/v1/databases/data', 'POST', { databaseID: row.id, sqliteQuery: 'DELETE FROM sales' })).status, 400)
})

test('Built-in credential routes require authentication, unlock explicitly, and keep files encrypted', async context => {
  const root = await temporaryFixture(context, 'wovenmatter-credentials-api-');
  const home = resolve(root, 'home'); await mkdir(home);
  const service = await startService({ workspace: root, home, catalog: catalogPath, token: 'credential-test-token' });
  context.after(() => stopService(service.child));
  const request = (path, body, token = 'credential-test-token') => fetch(service.url + path, {
    method: body ? 'POST' : 'GET', headers: { Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  });
  assert.equal((await request('/v1/default-agent/status', undefined, 'wrong')).status, 401);
  assert.equal((await (await request('/v1/default-agent/status')).json()).locked, true);
  assert.equal((await request('/v1/default-agent/rpc', { method: 'initialize' })).status, 423);
  const unlockKey = randomBytes(32).toString('base64');
  const body = { workspace: 'fixture-workspace', unlockKey, revision: 'fixture-revision', config: {},
    credentials: { openrouter: { type: 'api_key', key: 'fixture-provider-secret' } } };
  const receipt = await (await request('/v1/default-agent/configuration', body)).json();
  assert.equal(receipt.revision, 'fixture-revision');
  const status = await (await request('/v1/default-agent/status')).json();
  assert.equal(status.locked, false);
  assert.equal(status.providers.find(p => p.id === 'openrouter').state, 'credentials_present');
  assert.ok(!JSON.stringify(status).includes('fixture-provider-secret'));
  const disk = await readFile(resolve(root, '.wovenmatter/default-agent/credentials.enc.json'), 'utf8');
  assert.ok(!disk.includes('fixture-provider-secret') && !disk.includes(unlockKey));
});

test('task gateway routes are authenticated, default enabled, and persist explicit disable', async context => {
  const root = await temporaryFixture(context, 'wovenmatter-task-gateway-api-')
  const home = resolve(root, 'home'); await mkdir(home)
  const service = await startService({workspace:root,home,catalog:catalogPath,token:'task-test-token'})
  context.after(() => stopService(service.child))
  const request = (path, method='GET', body, token='task-test-token') => fetch(service.url+path, {
    method,headers:{Authorization:'Bearer '+token,'Content-Type':'application/json'},
    body:body===undefined?undefined:JSON.stringify(body),
  })
  assert.equal((await request('/v1/task-gateway','GET',undefined,'wrong')).status,401)
  assert.equal((await (await request('/v1/task-gateway')).json()).enabled,true)
  const published = await request('/v1/task-gateway/schedules','PUT',{publicationID:'fixture-publication',knownRuns:[],schedules:[{
    id:'fixture-event',title:'Future task',startsAt:'2099-01-01T14:00:00Z',nextFireAt:'2099-01-01T14:00:00Z',timeZoneID:'UTC',revision:1,excludedOccurrences:[],
    task:{prompt:'fixture only',sessionMode:'new',configuration:{runtimeKind:'codex',title:'Future task',tools:{enabled:[]}}},
  }]})
  assert.equal(published.status,200);assert.equal((await published.json()).scheduleCount,1)
  assert.equal((await (await request('/v1/task-gateway/schedules')).json()).schedules[0].id,'fixture-event')
  assert.deepEqual(await (await request('/v1/task-gateway/results?after=0')).json(),{entries:[],cursor:'0'})
  assert.equal((await request('/v1/task-gateway/results?after=-1')).status,400)
  assert.equal((await request('/v1/task-gateway','PATCH',{enabled:'no'})).status,400)
  const disabled=await (await request('/v1/task-gateway','PATCH',{enabled:false})).json()
  assert.equal(disabled.enabled,false);assert.equal(disabled.activeRuns,0)
  assert.equal(JSON.parse(await readFile(resolve(root,'.wovenmatter/task-gateway/state.json'),'utf8')).enabled,false)
  assert.notEqual((await request('/v1/durable-acp/attach','POST',{channelID:'no-start',harnessID:'codex'})).status,200)
})

async function stopService(child) {
  if (child.exitCode !== null || child.signalCode !== null || !child.pid) return
  const closed = new Promise(resolvePromise => child.once('close', resolvePromise))
  const escalation = setTimeout(() => child.kill('SIGKILL'), 1_000)
  try {
    child.kill('SIGTERM')
    await closed
  } finally {
    clearTimeout(escalation)
  }
}

async function startService({ workspace, home, catalog, token,
  spawnImplementation = spawn, startupTimeoutMilliseconds = 5_000 }) {
  const port = await unusedPort()
  const environment = await fixtureEnvironment(home)
  const child = spawnImplementation(process.execPath, [resolve(repositoryRoot, 'remote/src/server.mjs')], {
    cwd: repositoryRoot,
    env: {
      ...environment,
      WOVENMATTER_API_TOKEN: token,
      WOVENMATTER_LISTEN_HOST: '127.0.0.1',
      WOVENMATTER_LISTEN_PORT: String(port),
      WOVENMATTER_WORKSPACE: workspace,
      WOVENMATTER_HARNESS_CATALOG: catalog,
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  try {
    await new Promise((resolvePromise, reject) => {
      let output = ''
      const timeout = setTimeout(() => finish(new Error('service did not start')), startupTimeoutMilliseconds)
      const exited = (code, signal) => finish(new Error(`service exited ${signal ?? code}`))
      const failed = error => finish(error)
      const received = data => {
        output = (output + data.toString()).slice(-4096)
        if (output.includes('listening')) finish()
      }
      const finish = error => {
        clearTimeout(timeout)
        child.off('exit', exited)
        child.off('error', failed)
        child.stdout.off('data', received)
        if (error) reject(error)
        else resolvePromise()
      }
      child.once('exit', exited)
      child.once('error', failed)
      child.stdout.on('data', received)
      if (child.exitCode !== null || child.signalCode !== null) exited(child.exitCode, child.signalCode)
    })
  } catch (error) {
    await stopService(child)
    throw error
  }
  return { child, port, url: `http://127.0.0.1:${port}` }
}

async function fixtureEnvironment(home) {
  const tools = resolve(home, '.fixture-bin')
  const temporary = resolve(home, '.fixture-tmp')
  await mkdir(tools, { recursive: true })
  await mkdir(temporary, { recursive: true })
  const link = async (source, destination) => {
    try { await symlink(source, destination) } catch (error) { if (error.code !== 'EEXIST') throw error }
  }
  await link(process.execPath, resolve(tools, 'node'))
  await link('/usr/bin/touch', resolve(tools, 'touch'))
  await link('/bin/cat', resolve(tools, 'cat'))
  await writeFile(resolve(tools, 'flock'), '#!/bin/sh\nshift 3\nexec "$@"\n')
  await chmod(resolve(tools, 'flock'), 0o700)
  await link('/usr/bin/grep', resolve(tools, 'grep'))
  return {
    HOME: home,
    PATH: `${resolve(home, '.local/bin')}:${tools}`,
    TMPDIR: temporary,
    LANG: 'C',
  }
}

async function waitFor(url, headers, predicate) {
  const deadline = Date.now() + 5_000
  let value
  while (Date.now() < deadline) {
    const response = await fetch(url, { headers })
    assert.equal(response.status, 200)
    value = await response.json()
    if (predicate(value)) return value
    await new Promise((resolvePromise) => setTimeout(resolvePromise, 25))
  }
  throw new Error(`operation did not finish: ${JSON.stringify(value)}`)
}

async function unusedPort() {
  const server = createNetServer()
  await listen(server)
  const port = server.address().port
  await new Promise((resolvePromise, reject) =>
    server.close((error) => error ? reject(error) : resolvePromise())
  )
  return port
}

function listen(server) {
  return new Promise((resolvePromise, reject) => {
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => {
      server.off('error', reject)
      resolvePromise()
    })
  })
}

function installerResponse(chunks, { status = 200, url = '', headers = {} } = {}) {
  let chunkIndex = 0
  let pullCount = 0
  let cancelled = false
  const body = new ReadableStream({
    pull(controller) {
      pullCount += 1
      if (chunkIndex < chunks.length) {
        controller.enqueue(new Uint8Array(chunks[chunkIndex]))
        chunkIndex += 1
      } else {
        controller.close()
      }
    },
    cancel() {
      cancelled = true
    },
  }, { highWaterMark: 0 })
  return {
    response: {
      body,
      headers: new Headers(headers),
      ok: status >= 200 && status < 300,
      status,
      url,
    },
    pulls: () => pullCount,
    wasCancelled: () => cancelled,
  }
}

function fakeACPExecutable() {
  return `#!/usr/bin/env node
let input = ''
process.stdin.on('data', (data) => { input += data.toString('utf8') })
process.stdin.on('end', () => {
  const request = JSON.parse(input.trim())
  process.stdout.write(JSON.stringify({
    jsonrpc: '2.0',
    id: request.id,
    result: { protocolVersion: 2, agentInfo: { name: 'fixture' } },
  }) + '\\n')
})
`
}
test('direct client grants expose only execution routes and enforce revocation', async context => {
  const fixture=await temporaryFixture(context,'wovenmatter-direct-client-')
  const catalog=resolve(fixture,'catalog.json')
  await writeFile(catalog,JSON.stringify({schemaVersion:4,harnesses:[]}))
  const service=await startService({workspace:fixture,home:fixture,catalog,token:'fixture-admin-token'})
  context.after(() => stopService(service.child))
  const id=()=>globalThis.crypto.randomUUID()
  const body={libraryID:id(),workspaceID:id(),ownerDeviceID:id(),deviceID:id(),scopes:['execution']}
  const enrolled=await fetch(service.url+'/v1/execution/devices',{method:'POST',headers:{authorization:'Bearer fixture-admin-token','content-type':'application/json'},body:JSON.stringify(body)})
  assert.equal(enrolled.status,201)
  const grant=await enrolled.json(),headers={authorization:'Bearer '+grant.token,'content-type':'application/json'}
  const descriptor=await fetch(service.url+'/v1/execution',{headers})
  assert.equal(descriptor.status,200)
  assert.equal((await descriptor.json()).id,body.workspaceID)
  assert.equal((await fetch(service.url+'/v1/execution/events?after=0',{headers})).status,200)
  assert.equal((await fetch(service.url+'/v1/inference/catalog',{headers})).status,401)
  assert.equal((await fetch(service.url+'/v1/default-agent/status',{headers})).status,403)
  assert.equal((await fetch(service.url+'/v1/execution/devices',{method:'POST',headers,body:JSON.stringify(body)})).status,403)
  const foreign=await fetch(service.url+'/v1/execution/commands',{method:'POST',headers,body:JSON.stringify({commandID:id(),deviceID:id(),kind:'createSession'})})
  assert.equal(foreign.status,400)
  const revoked=await fetch(service.url+'/v1/execution/devices/'+body.deviceID,{method:'DELETE',headers:{authorization:'Bearer fixture-admin-token'}})
  assert.equal(revoked.status,200)
  assert.equal((await fetch(service.url+'/v1/execution',{headers})).status,401)
})

test('installer download follows only HTTPS redirects and hashes streamed bytes', async () => {
  const calls = []
  const redirect = installerResponse([], {
    status: 302,
    url: 'https://downloads.example.test/install',
    headers: { location: '/releases/current.sh' },
  })
  const payload = [Buffer.from('#!/bin/sh\n'), Buffer.from('exit 0\n')]
  const destination = installerResponse(payload, {
    url: 'https://downloads.example.test/releases/current.sh',
  })
  const result = await downloadInstallerSource(
    'https://downloads.example.test/install',
    {
      maximumBytes: 64,
      fetchImplementation: async (url, options) => {
        calls.push({ url: String(url), redirect: options.redirect })
        return calls.length === 1 ? redirect.response : destination.response
      },
    }
  )

  const expected = Buffer.concat(payload)
  assert.deepEqual(result.data, expected)
  assert.equal(
    result.sha256,
    createHash('sha256').update(expected).digest('hex')
  )
  assert.deepEqual(calls, [
    { url: 'https://downloads.example.test/install', redirect: 'manual' },
    { url: 'https://downloads.example.test/releases/current.sh', redirect: 'manual' },
  ])
})

test('authentication deadline escalates only a live process and preserves timeout outcome', context => {
  context.mock.timers.enable({ apis: ['setTimeout'] })
  const child = new EventEmitter()
  child.exitCode = null
  child.signalCode = null
  const signals = []
  child.kill = signal => signals.push(signal)
  const session = { child, timedOut: false, error: null }
  authenticationDeadline(session)
  context.mock.timers.tick(30 * 60_000 - 1)
  assert.deepEqual(signals, [])
  context.mock.timers.tick(1)
  assert.equal(session.timedOut, true)
  assert.equal(session.error, 'Sign-in timed out.')
  assert.deepEqual(signals, ['SIGTERM'])
  context.mock.timers.tick(5_000)
  assert.deepEqual(signals, ['SIGTERM', 'SIGKILL'])
})

test('HTTP fixture startup failure reaps a SIGTERM-ignoring child and cleanup accepts its signal exit', { timeout: 10000 }, async context => {
  const root = await temporaryFixture(context, 'wovenmatter-service-cleanup-')
  const child = spawn(process.execPath, ['-e',
    "process.on('SIGTERM', () => {}); console.log('ready'); setInterval(() => {}, 1000)"], {
    env: {}, stdio: ['ignore', 'pipe', 'pipe'],
  })
  context.after(() => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL') })
  await once(child.stdout, 'data')
  await assert.rejects(startService({
    workspace: root, home: root, catalog: catalogPath, token: 'synthetic-token',
    spawnImplementation: () => child, startupTimeoutMilliseconds: 25,
  }), /service did not start/)
  assert.equal(child.exitCode, null)
  assert.equal(child.signalCode, 'SIGKILL')
  await stopService(child)
})

test('HTTP execution survives a lost acknowledgement without replay and preserves history after device revocation', { timeout: 20000 }, async context => {
  const root = await temporaryFixture(context, 'wovenmatter-http-execution-')
  const bin = resolve(root, '.local/bin')
  await mkdir(bin, { recursive: true })
  const marker = resolve(root, 'prompts.jsonl')
  const executable = resolve(bin, 'fixture-acp.mjs')
  const output = 'Exact Unicode output: café 🌱\nsecond line'
  await writeFile(executable, `#!/usr/bin/env node
import { appendFileSync } from 'node:fs';
import { createInterface } from 'node:readline';
if (process.argv.includes('--version')) { console.log('1.0.0'); process.exit(0); }
const send = value => process.stdout.write(JSON.stringify(value) + '\\n');
createInterface({ input: process.stdin }).on('line', line => {
  const request = JSON.parse(line);
  if (request.method === 'initialize') send({jsonrpc:'2.0',id:request.id,result:{protocolVersion:1}});
  else if (request.method === 'session/new' || request.method === 'session/load') send({jsonrpc:'2.0',id:request.id,result:{sessionId:'http_fixture'}});
  else if (request.method === 'session/prompt') {
    appendFileSync(${JSON.stringify(marker)}, JSON.stringify(request.params.prompt) + '\\n');
    send({jsonrpc:'2.0',method:'session/update',params:{sessionId:'http_fixture',update:{sessionUpdate:'agent_message_chunk',content:{type:'text',text:${JSON.stringify(output)}}}}});
    send({jsonrpc:'2.0',id:request.id,result:{stopReason:'end_turn'}});
  }
});
`)
  await chmod(executable, 0o700)
  const catalog = resolve(root, 'catalog.json')
  await writeFile(catalog, JSON.stringify({ schemaVersion: 4, harnesses: [{
    id: 'codex', displayName: 'Synthetic ACP', transport: 'acp', command: 'fixture-acp.mjs', arguments: [], cliCommand: 'fixture-acp.mjs',
    install: { kind: 'npm-global', source: 'https://example.test', command: 'true' },
    authentication: { statusCommands: ['true'], discoveries: [], methods: [] }, capabilities: ['conversations'],
  }] }))
  const service = await startService({ workspace: root, home: root, catalog, token: 'synthetic-admin' })
  context.after(() => stopService(service.child))
  const admin = { authorization: 'Bearer synthetic-admin', 'content-type': 'application/json' }
  const id = () => globalThis.crypto.randomUUID()
  const device = { libraryID: id(), workspaceID: id(), ownerDeviceID: id(), deviceID: id(), scopes: ['execution'] }
  const request = (path, method, body, headers = admin) => fetch(service.url + path, { method, headers, ...(body ? { body: JSON.stringify(body) } : {}) })
  const enrolled = await request('/v1/execution/devices', 'POST', device)
  assert.equal(enrolled.status, 201)
  const grant = await enrolled.json()
  const headers = { ...admin, authorization: 'Bearer ' + grant.token }
  const create = await request('/v1/execution/commands', 'POST', { commandID: id(), deviceID: device.deviceID, kind: 'createSession', runtimeKind: 'codex' }, headers)
  assert.equal(create.status, 200)
  const opened = await create.json()
  assert.equal(opened.status, 'completed', JSON.stringify({ receipt: opened, harnesses: opened.status !== 'completed' ? await (await request('/v1/harnesses', 'GET')).json() : undefined }))
  const input = { commandID: id(), deviceID: device.deviceID, kind: 'send', conversationID: opened.conversationID, text: 'Hello 🌱' }
  // Intentionally discard the acknowledgement; retry the identical command ID.
  await (await request('/v1/execution/commands', 'POST', input, headers)).arrayBuffer()
  const retry = await request('/v1/execution/commands', 'POST', input, headers)
  assert.equal(retry.status, 200)
  await waitFor(service.url + '/v1/execution/commands/' + input.commandID, headers, receipt => receipt.status === 'completed')
  const historyPath = '/v1/execution/conversations/' + opened.conversationID + '/transcript'
  const historyResponse = await request(historyPath, 'GET', null, headers)
  assert.equal(historyResponse.status, 200)
  const history = await historyResponse.json()
  assert.deepEqual(history.messages.map(message => [message.role, message.content]), [['user', input.text], ['assistant', output]])
  assert.equal((await readFile(marker, 'utf8')).trim().split('\n').length, 1)
  assert.equal((await request('/v1/execution/devices/' + device.deviceID, 'DELETE')).status, 200)
  assert.equal((await request('/v1/execution/commands', 'POST', { ...input, commandID: id() }, headers)).status, 401)
  const retained = await request(historyPath, 'GET')
  assert.equal(retained.status, 200)
  assert.deepEqual(await retained.json(), history)
  assert.equal((await readFile(marker, 'utf8')).trim().split('\n').length, 1)
})

test('service authentication exposes the reviewed harness catalog', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-service-')
  const service = await startService({
    workspace: fixture,
    home: fixture,
    catalog: catalogPath,
    token: 'service-token',
  })
  context.after(() => stopService(service.child))

  assert.equal((await fetch(`${service.url}/v1/health`)).status, 401)
  for (const wrong of ['Bearer service-toke', 'Bearer service-token-longer', 'Bearer Service-Token', 'Basic service-token']) {
    assert.equal((await fetch(`${service.url}/v1/health`, { headers: { authorization: wrong } })).status, 401)
  }
  const headers = { authorization: 'Bearer service-token' }
  const health = await fetch(`${service.url}/v1/health`, { headers })
  assert.equal((await health.json()).status, 'ready')
  const response = await fetch(`${service.url}/v1/harnesses`, { headers })
  const harnesses = (await response.json()).harnesses
  assert.deepEqual(harnesses.map((value) => value.id), [
    'default_agent',
    'codex', 'claude_code', 'grok_build', 'opencode',
  ])
  assert.ok(harnesses.every((value) =>
    Array.isArray(value.setupMethods) && (['opencode', 'default_agent'].includes(value.id) || value.setupMethods.length > 0)
  ))
  const openCode = harnesses.find((value) => value.id === 'opencode')
  assert.equal(openCode.transport, 'opencode-v2')
  assert.equal(openCode.state, 'cli_missing')
  assert.deepEqual(openCode.setupMethods, [])
  assert.match(openCode.transportError, /this workspace’s OpenCode v2 server/)
  assert.deepEqual(
    Object.keys(harnesses.find(value => value.id === 'codex').setupMethods[0]).sort(),
    ['displayName', 'id']
  )
  assert.ok(harnesses.every((value) =>
    !['adapterInstalled', 'cliInstalled', 'installCommand', 'installSource', 'operation']
      .some((field) => Object.hasOwn(value, field))
  ))
})

test('authorization input contains asynchronous pipe failures and observes later stream errors', async () => {
  const failure = Object.assign(new Error('write EPIPE'), { code: 'EPIPE' })
  const input = new Writable({ write(_chunk, _encoding, callback) { callback(failure) } })
  const session = { child: { stdin: input }, method: { acceptsInput: true }, state: 'waiting_for_user' }
  const submit = authenticationInput(session)
  await assert.rejects(submit(async () => ({ code: 'fixture-code' })), { statusCode: 409, message: 'authentication_session_not_active' })
  // Writable emits its error after the write callback. Neither event may crash
  // the service, and the actual failure remains recorded for session settlement.
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(session.inputError, failure)
  assert.equal(session.error, 'Sign-in input is unavailable.')
  input.emit('error', failure)
  await assert.rejects(submit(async () => ({ code: 'again' })), { statusCode: 409 })
  input.destroy()
})

test('authorization input rejects extra lines, blank or oversized values before writing one trimmed code', async () => {
  const writes = []
  const input = new Writable({ write(chunk, _encoding, callback) { writes.push(chunk.toString()); callback() } })
  const session = { child: { stdin: input }, method: { acceptsInput: true }, state: 'waiting_for_user' }
  const submit = authenticationInput(session)
  try {
    for (const code of ['first\nsecond', 'first\rsecond', '  ', 'x'.repeat(4097), 123]) {
      await assert.rejects(submit(async () => ({ code })), { statusCode: 400, message: 'invalid_authorization_code' })
    }
    assert.deepEqual(writes, [])
    await submit(async () => ({ code: '  fixture-code\n' }))
    assert.deepEqual(writes, ['fixture-code\n'])
  } finally {
    input.destroy()
  }
})

test('authorization input reports acceptance only after the write completes', async () => {
  let finishWrite, written, accepted = false
  const input = new Writable({ write(chunk, _encoding, callback) { written = chunk.toString(); finishWrite = callback } })
  const session = { child: { stdin: input }, method: { acceptsInput: true }, state: 'waiting_for_user' }
  const submit = authenticationInput(session)
  const pending = submit(async () => ({ code: '  fixture-code\n' })).then(() => { accepted = true })
  await new Promise(resolve => setImmediate(resolve))
  assert.equal(written, 'fixture-code\n')
  assert.equal(accepted, false)
  finishWrite()
  await pending
  assert.equal(accepted, true)
  input.destroy()
})

test('readiness returns unavailable when the initialize pipe closes before its write', async () => {
  const child = new EventEmitter()
  child.exitCode = null
  child.killed = false
  child.kill = () => { child.killed = true }
  child.stdout = new PassThrough()
  child.stderr = new PassThrough()
  child.stdin = new Writable({
    write(_chunk, _encoding, callback) {
      callback(Object.assign(new Error('write EPIPE'), { code: 'EPIPE' }))
    },
  })
  const result = await probeHarnessTransport({ id: 'fixture', command: 'fixture' }, 1_000, () => {
    queueMicrotask(() => child.emit('spawn'))
    return child
  })
  assert.deepEqual(result, { ready: false, error: 'The transport input failed before readiness.' })
  assert.equal(child.killed, true)
  assert.equal(child.stdin.destroyed, true)
  // Late process events must not replace the already settled failure.
  child.emit('close', 0)
})

test('installation uses latest adapter and fails unless actual components verify', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-install-')
  const home = resolve(fixture, 'home')
  const workspace = resolve(fixture, 'workspace')
  const bin = resolve(home, '.local/bin')
  const npmArguments = resolve(fixture, 'npm-arguments')
  await mkdir(bin, { recursive: true })
  await mkdir(workspace, { recursive: true })
  await writeFile(resolve(bin, 'flock'), '#!/bin/sh\nshift 3\nexec "$@"\n')
  await chmod(resolve(bin, 'flock'), 0o700)
  await writeFile(resolve(bin, 'ps'), '#!/bin/sh\nexit 0\n')
  await chmod(resolve(bin, 'ps'), 0o700)
  const npm = resolve(bin, 'npm')
  await writeFile(npm, `#!/bin/sh\nprintf '%s\\n' "$@" >> '${npmArguments}'\n`)
  await chmod(npm, 0o700)

  const catalog = JSON.parse(await readFile(catalogPath, 'utf8'))
  const opencode = catalog.harnesses.find((value) => value.id === 'opencode')
  const testCatalog = resolve(fixture, 'catalog.json')
  await writeFile(testCatalog, JSON.stringify({
    schemaVersion: 4,
    harnesses: [{
      ...opencode,
      adapterPackage: '@example/opencode-adapter',
      minimumAdapterVersion: '1.2.3',
      command: 'opencode-adapter',
      transportCheckCommand: null,
    }],
  }))

  const service = await startService({
    workspace,
    home,
    catalog: testCatalog,
    token: 'install-token',
  })
  context.after(() => stopService(service.child))
  const headers = {
    authorization: 'Bearer install-token',
    'content-type': 'application/json',
  }
  const response = await fetch(`${service.url}/v1/harnesses/opencode/install`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ confirmed: true, packageSpec: "@opencode/cli@2.1.0" }),
  })
  assert.equal(response.status, 202)
  const operation = await waitFor(
    `${service.url}/v1/operations/${(await response.json()).id}`,
    headers,
    (value) => value.status !== 'running'
  )
  assert.equal(operation.status, 'failed')
  assert.match(operation.error, /could not be verified/)
  const argumentsValue = await readFile(npmArguments, 'utf8')
  assert.match(argumentsValue, /@opencode\/cli/)
  assert.match(argumentsValue, /@example\/opencode-adapter@latest/)
})
