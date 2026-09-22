import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { EventEmitter } from 'node:events'
import { PassThrough, Writable } from 'node:stream'
import { createHash, randomBytes } from 'node:crypto'
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { connect, createServer as createNetServer } from 'node:net'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { authenticationInput, authenticationDeadline, downloadInstallerSource, probeHarnessTransport } from '../src/server.mjs'

const repositoryRoot = resolve(import.meta.dirname, '../..')
const catalogPath = resolve(repositoryRoot, 'harnesses/catalog.json')

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

for (const outcome of ['success', 'signal', 'error', 'timeout-then-success']) {
  test(`authentication deadline clears after ${outcome}`, context => {
    context.mock.timers.enable({ apis: ['setTimeout'] })
    const child = new EventEmitter()
    child.exitCode = null
    child.signalCode = null
    const signals = []
    child.kill = signal => signals.push(signal)
    const session = { child, timedOut: false, error: null }
    authenticationDeadline(session)
    if (outcome === 'timeout-then-success') context.mock.timers.tick(30 * 60_000)
    if (outcome === 'signal') child.signalCode = 'SIGTERM'
    else if (outcome !== 'error') child.exitCode = 0
    child.emit(outcome === 'error' ? 'error' : 'exit')
    context.mock.timers.tick(31 * 60_000)
    assert.deepEqual(signals, outcome === 'timeout-then-success' ? ['SIGTERM'] : [])
    assert.equal(session.timedOut, outcome === 'timeout-then-success')
  })
}

test('service authentication exposes the reviewed harness catalog', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-service-')
  const service = await startService({
    workspace: fixture,
    home: fixture,
    catalog: catalogPath,
    token: 'service-token',
  })
  context.after(() => service.child.kill('SIGTERM'))

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
    'codex', 'claude_code', 'grok_build', 'hermes',
    'cursor', 'opencode', 'pi', 'openclaw',
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

test('authorization input rejects additional lines and accepts a single trimmed credential', async context => {
  const fixture = await temporaryFixture(context, 'wovenmatter-input-')
  const inputPath = resolve(fixture, 'input')
  const catalog = JSON.parse(await readFile(catalogPath, 'utf8'))
  const harness = catalog.harnesses[0]
  harness.authentication.statusCommands = [`test -f '${inputPath}'`]
  harness.authentication.methods = [{ id: 'fixture', displayName: 'Fixture', acceptsInput: true,
    command: `IFS= read -r code; printf '%s' "$code" > '${inputPath}'` }]
  const path = resolve(fixture, 'catalog.json')
  await writeFile(path, JSON.stringify({ schemaVersion: 4, harnesses: [harness] }))
  const service = await startService({ workspace: fixture, home: fixture, catalog: path, token: 'input-token' })
  context.after(() => service.child.kill('SIGTERM'))
  const headers = { authorization: 'Bearer input-token', 'content-type': 'application/json' }
  const started = await fetch(`${service.url}/v1/harnesses/${harness.id}/sign-in`, {
    method: 'POST', headers, body: JSON.stringify({ methodID: 'fixture' }),
  })
  assert.equal(started.status, 201)
  const sessionURL = `${service.url}/v1/authentication-sessions/${(await started.json()).id}`
  for (const code of ['first\nsecond', 'first\rsecond', '  ', 'x'.repeat(4097), 123]) {
    const response = await fetch(`${sessionURL}/authorization-code`, {
      method: 'POST', headers, body: JSON.stringify({ code }),
    })
    assert.equal(response.status, 400)
    assert.equal((await response.json()).error, 'invalid_authorization_code')
  }
  const accepted = await fetch(`${sessionURL}/authorization-code`, {
    method: 'POST', headers, body: JSON.stringify({ code: '  safe-code\n' }),
  })
  assert.equal(accepted.status, 202)
  assert.equal((await waitFor(sessionURL, headers, value => value.state !== 'waiting_for_user')).state, 'succeeded')
  assert.equal(await readFile(inputPath, 'utf8'), 'safe-code')
})

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
  context.after(() => service.child.kill('SIGTERM'))
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
  const pi = resolve(bin, 'working-pi')
  await writeFile(pi, fakePiRPCExecutable())
  await chmod(pi, 0o700)

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
      { ...harness('pi', 'Working Pi RPC', 'working-pi'), transport: 'rpc' },
    ],
  }))

  const service = await startService({
    workspace,
    home,
    catalog: testCatalog,
    token: 'transport-token',
  })
  context.after(() => service.child.kill('SIGTERM'))
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
  assert.equal(statuses[2].state, 'ready')
  assert.equal(statuses[2].transportStatus, 'ready')
})

test('Pi authentication locates its owning package from a nested npm bin target', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-pi-auth-')
  const home = resolve(fixture, 'home')
  const bin = resolve(home, '.local/bin')
  const packageRoot = resolve(home, '.local/lib/node_modules/@earendil-works/pi-coding-agent')
  const cli = resolve(packageRoot, 'dist/bundle/cli.js')
  const providerModule = resolve(
    packageRoot,
    'node_modules/@earendil-works/pi-ai/dist/providers/all.js'
  )
  const storageModule = resolve(packageRoot, 'dist/core/auth-storage.js')
  const resultPath = resolve(fixture, 'credential.json')
  await mkdir(bin, { recursive: true })
  await mkdir(resolve(packageRoot, 'dist/bundle'), { recursive: true })
  await mkdir(resolve(packageRoot, 'dist/core'), { recursive: true })
  await mkdir(resolve(packageRoot, 'node_modules/@earendil-works/pi-ai/dist/providers'), {
    recursive: true,
  })
  await writeFile(resolve(packageRoot, 'package.json'), JSON.stringify({
    name: '@earendil-works/pi-coding-agent',
    type: 'module',
    bin: { pi: 'dist/bundle/cli.js' },
  }))
  await writeFile(cli, '#!/bin/sh\nexit 0\n')
  await chmod(cli, 0o700)
  await symlink(cli, resolve(bin, 'pi'))
  await writeFile(providerModule, `
    export function builtinProviders() {
      return [{ id: 'openai', name: 'OpenAI', auth: { apiKey: {} } }]
    }
  `)
  await writeFile(storageModule, `
    import { writeFile } from 'node:fs/promises'
    export class AuthStorage {
      static create() { return new AuthStorage() }
      async modify(provider, update) {
        const credential = await update(undefined)
        await writeFile(process.env.WOVENMATTER_PI_AUTH_TEST_RESULT, JSON.stringify({
          provider,
          credential,
        }))
      }
    }
  `)

  const result = await runProcess(
    process.execPath,
    [resolve(repositoryRoot, 'remote/src/pi-auth.mjs'), 'api-key', 'openai'],
    {
      cwd: repositoryRoot,
      env: {
        ...await fixtureEnvironment(home),
        WOVENMATTER_PI_AUTH_TEST_RESULT: resultPath,
      },
      input: 'fixture-key\n',
    }
  )
  assert.equal(result.code, 0, result.stderr)
  assert.match(result.stdout, /API key stored/)
  assert.deepEqual(JSON.parse(await readFile(resultPath, 'utf8')), {
    provider: 'openai',
    credential: { type: 'api_key', key: 'fixture-key' },
  })
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
  const pi = catalog.harnesses.find((value) => value.id === 'pi')
  const testCatalog = resolve(fixture, 'catalog.json')
  await writeFile(testCatalog, JSON.stringify({
    schemaVersion: 4,
    harnesses: [{
      ...pi,
      adapterPackage: '@example/pi-rpc-adapter',
      minimumAdapterVersion: '1.2.3',
      command: 'pi-rpc-adapter',
      transportCheckCommand: null,
    }],
  }))

  const service = await startService({
    workspace,
    home,
    catalog: testCatalog,
    token: 'install-token',
  })
  context.after(() => service.child.kill('SIGTERM'))
  const headers = {
    authorization: 'Bearer install-token',
    'content-type': 'application/json',
  }
  const response = await fetch(`${service.url}/v1/harnesses/pi/install`, {
    method: 'POST',
    headers,
    body: JSON.stringify({ confirmed: true }),
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
  assert.match(argumentsValue, /@earendil-works\/pi-coding-agent/)
  assert.match(argumentsValue, /@example\/pi-rpc-adapter@latest/)
})

test('Gateway upgrades refuse unrelated listeners and never forward the API token', async (context) => {
  let upstreamRequest = ''
  const upstream = createNetServer((socket) => {
    socket.on('data', (data) => {
      upstreamRequest += data.toString('utf8')
      if (upstreamRequest.includes('\r\n\r\n')) {
        socket.write(
          'HTTP/1.1 101 Switching Protocols\r\n'
          + 'Connection: Upgrade\r\nUpgrade: websocket\r\n\r\n'
        )
      }
    })
  })
  await listen(upstream)
  context.after(() => upstream.close())
  const fixture = await temporaryFixture(context, 'wovenmatter-gateway-')
  await mkdir(resolve(fixture, '.wovenmatter'), { recursive: true })
  await writeFile(resolve(fixture, '.wovenmatter/runtime-preferences.json'), JSON.stringify({openclaw:{enabled:true}}))
  const service = await startService({
    workspace: fixture,
    home: fixture,
    catalog: catalogPath,
    token: 'gateway-token',
    gatewayPort: upstream.address().port,
  })
  context.after(() => service.child.kill('SIGTERM'))

  const socket = connect({ host: '127.0.0.1', port: service.port })
  context.after(() => socket.destroy())
  socket.write(
    'GET /v1/openclaw/gateway/socket HTTP/1.1\r\n'
    + `Host: 127.0.0.1:${service.port}\r\n`
    + 'Connection: Upgrade\r\nUpgrade: websocket\r\n'
    + 'Sec-WebSocket-Version: 13\r\n'
    + 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    + 'Authorization: Bearer gateway-token\r\n\r\n'
  )
  assert.match(await socketText(socket), /^HTTP\/1\.1 503 Service Unavailable/)
  assert.doesNotMatch(upstreamRequest, /authorization:|gateway-token/i)
  const start = await fetch(`${service.url}/v1/openclaw/gateway/start`, { method: 'POST', headers: { authorization: 'Bearer gateway-token' } })
  assert.equal(start.status, 409)
  assert.equal((await start.json()).error, 'openclaw_gateway_port_in_use')
})

test('Gateway start reports running only after its listener accepts connections', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-gateway-ready-')
  await mkdir(resolve(fixture, '.wovenmatter'), { recursive: true })
  await writeFile(resolve(fixture, '.wovenmatter/runtime-preferences.json'), JSON.stringify({openclaw:{enabled:true}}))
  const home = resolve(fixture, 'home')
  const bin = resolve(home, '.local/bin')
  const gatewayPort = await unusedPort()
  await mkdir(bin, { recursive: true })
  const openclaw = resolve(bin, 'openclaw')
  await writeFile(openclaw, `#!/usr/bin/env node
if (process.argv[2] === 'config') { console.log('{}'); process.exit(0) }
const { createServer } = require('node:net')
const port = Number(process.argv[process.argv.indexOf('--port') + 1])
const server = createServer((socket) => {
  let request = ''
  socket.on('data', data => {
    request += data.toString()
    if (!request.includes('\\r\\n\\r\\n')) return
    socket.end('HTTP/1.1 101 Switching Protocols\\r\\nConnection: Upgrade\\r\\nUpgrade: websocket\\r\\nX-Request: '
      + Buffer.from(request).toString('base64') + '\\r\\n\\r\\n')
  })
})
setTimeout(() => server.listen(port, '127.0.0.1'), 200)
process.on('SIGTERM', () => server.close(() => process.exit(0)))
`)
  await chmod(openclaw, 0o700)

  const service = await startService({
    workspace: fixture,
    home,
    catalog: catalogPath,
    token: 'gateway-ready-token',
    gatewayPort,
  })
  context.after(() => service.child.kill('SIGTERM'))
  const response = await fetch(`${service.url}/v1/openclaw/gateway/start`, {
    method: 'POST',
    headers: { authorization: 'Bearer gateway-ready-token' },
  })
  assert.equal(response.status, 202)
  const status = await response.json()
  context.after(() => {
    try { process.kill(status.pid, 'SIGTERM') } catch {}
  })
  assert.equal(status.state, 'running')
  assert.equal(await canConnect(gatewayPort), true)
  const socket = connect({ host: '127.0.0.1', port: service.port })
  context.after(() => socket.destroy())
  socket.write('GET /v1/openclaw/gateway/socket HTTP/1.1\r\n'
    + `Host: 127.0.0.1:${service.port}\r\n`
    + 'Connection: Upgrade\r\nUpgrade: websocket\r\n'
    + 'Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n'
    + 'Sec-WebSocket-Protocol: fixture\r\n'
    + 'Authorization: Bearer gateway-ready-token\r\nCookie: secret=cookie\r\n'
    + 'Origin: https://untrusted.example\r\nX-Forwarded-For: 127.0.0.1\r\n\r\n')
  const handshake = await socketText(socket)
  assert.match(handshake, /^HTTP\/1\.1 101/)
  const forwarded = Buffer.from(handshake.match(/X-Request: ([^\r]+)/)[1], 'base64').toString()
  assert.match(forwarded, /^GET \/ HTTP\/1\.1/)
  assert.match(forwarded, new RegExp(`Host: 127.0.0.1:${gatewayPort}`))
  assert.match(forwarded, /sec-websocket-key: dGhlIHNhbXBsZSBub25jZQ==/i)
  assert.match(forwarded, /sec-websocket-version: 13/i)
  assert.match(forwarded, /sec-websocket-protocol: fixture/i)
  assert.doesNotMatch(forwarded, /authorization:|gateway-ready-token|cookie:|origin:|x-forwarded-for:/i)

  assert.equal(JSON.parse(await readFile(resolve(fixture, '.wovenmatter/openclaw-desired.json'))).running, true)
  service.child.kill('SIGTERM')
  await new Promise(done => service.child.once('exit', done))
  const restarted = await startService({ workspace: fixture, home, catalog: catalogPath,
    token: 'gateway-ready-token', gatewayPort })
  context.after(() => restarted.child.kill('SIGTERM'))
  const headers = { authorization: 'Bearer gateway-ready-token' }
  const recovered = await waitFor(`${restarted.url}/v1/openclaw/gateway`, headers, value => value.state === 'running')
  assert.notEqual(recovered.pid, status.pid)
  const stopped = await fetch(`${restarted.url}/v1/workspace-instances/openclaw/stop`, { method: 'POST', headers })
  assert.equal(stopped.status, 200)
  assert.equal(JSON.parse(await readFile(resolve(fixture, '.wovenmatter/openclaw-desired.json'))).running, false)
})

test('Stopping a gateway during crash backoff cancels its pending restart', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-gateway-stop-')
  await mkdir(resolve(fixture, '.wovenmatter'), { recursive: true })
  await writeFile(resolve(fixture, '.wovenmatter/runtime-preferences.json'), JSON.stringify({ openclaw: { enabled: true } }))
  const home = resolve(fixture, 'home')
  const bin = resolve(home, '.local/bin')
  const launches = resolve(fixture, 'launches')
  await mkdir(bin, { recursive: true })
  await writeFile(resolve(bin, 'openclaw'), `#!/usr/bin/env node
if (process.argv[2] === 'config') { console.log('{}'); process.exit(0) }
require('node:fs').appendFileSync(${JSON.stringify(launches)}, 'started\\n')
const server = require('node:net').createServer(socket => socket.destroy())
server.listen(Number(process.argv[process.argv.indexOf('--port') + 1]), '127.0.0.1')
process.on('SIGTERM', () => server.close(() => process.exit(0)))
`)
  await chmod(resolve(bin, 'openclaw'), 0o700)
  const service = await startService({ workspace: fixture, home, catalog: catalogPath, token: 'stop-token' })
  const headers = { authorization: 'Bearer stop-token' }
  context.after(async () => {
    const status = await fetch(`${service.url}/v1/openclaw/gateway`, { headers }).then(response => response.json())
    if (status.pid) { try { process.kill(status.pid, 'SIGTERM') } catch {} }
    service.child.kill('SIGTERM')
  })
  const response = await fetch(`${service.url}/v1/openclaw/gateway/start`, { method: 'POST', headers })
  assert.equal(response.status, 202)
  const started = await response.json()
  process.kill(started.pid, 'SIGKILL')
  await waitFor(`${service.url}/v1/openclaw/gateway`, headers, value => value.state === 'reconnecting')
  const stopped = await fetch(`${service.url}/v1/workspace-instances/openclaw/stop`, { method: 'POST', headers })
  assert.equal(stopped.status, 200)
  assert.equal((await stopped.json()).state, 'stopped')
  await new Promise(done => setTimeout(done, 1250))
  const current = await fetch(`${service.url}/v1/openclaw/gateway`, { headers }).then(response => response.json())
  assert.equal(current.state, 'stopped')
  assert.equal(await readFile(launches, 'utf8'), 'started\n')
})

test('Stopping a gateway fences a start suspended while acquiring its host lock', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-gateway-pending-')
  await mkdir(resolve(fixture, '.wovenmatter'), { recursive: true })
  await writeFile(resolve(fixture, '.wovenmatter/runtime-preferences.json'), JSON.stringify({ openclaw: { enabled: true } }))
  const home = resolve(fixture, 'home')
  const service = await startService({ workspace: fixture, home, catalog: catalogPath, token: 'pending-token' })
  context.after(() => service.child.kill('SIGTERM'))
  const waiting = resolve(fixture, 'waiting'), release = resolve(fixture, 'release')
  await writeFile(resolve(home, '.fixture-bin/flock'), `#!/usr/bin/env node
const fs = require('node:fs')
fs.writeFileSync(${JSON.stringify(waiting)}, '')
const timer = setInterval(() => {
  if (!fs.existsSync(${JSON.stringify(release)})) return
  clearInterval(timer)
  const child = require('node:child_process').spawn(process.argv[5], process.argv.slice(6), { stdio: 'inherit' })
  child.on('exit', code => process.exit(code ?? 1))
}, 10)
`)
  const headers = { authorization: 'Bearer pending-token' }
  const pending = fetch(`${service.url}/v1/openclaw/gateway/start`, { method: 'POST', headers })
  for (let attempts = 0; ; attempts++) {
    try { await readFile(waiting); break } catch { assert.ok(attempts < 100, 'start should reach host lock') }
    await new Promise(done => setTimeout(done, 10))
  }
  const stopped = await fetch(`${service.url}/v1/workspace-instances/openclaw/stop`, { method: 'POST', headers })
  assert.equal(stopped.status, 200)
  await writeFile(release, '')
  const result = await pending
  assert.equal(result.status, 409)
  assert.equal((await result.json()).error, 'openclaw_gateway_start_cancelled')
  const current = await fetch(`${service.url}/v1/openclaw/gateway`, { headers }).then(response => response.json())
  assert.equal(current.state, 'stopped')
  assert.equal(current.pid, null)
})

async function temporaryFixture(context, prefix) {
  const directory = await mkdtemp(resolve(tmpdir(), prefix))
  context.after(() => rm(directory, { recursive: true, force: true }))
  return directory
}

test('database routes require authentication and ignore client-supplied workspace roots', async context => {
  const root = await temporaryFixture(context, 'wovenmatter-database-api-')
  const home = resolve(root, 'home')
  await mkdir(home)
  await mkdir(resolve(root, 'Databases'))
  const service = await startService({ workspace: root, home, catalog: catalogPath, token: 'database-token' })
  context.after(() => service.child.kill('SIGTERM'))
  const request = (path, method = 'GET', body, token = 'database-token') => fetch(service.url + path, {
    method, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  })
  assert.equal((await request('/v1/databases', 'GET', undefined, 'wrong')).status, 401)
  assert.equal((await request('/v1/databases', 'POST', { databaseID: 'Denied', preference: 'none' }, 'wrong')).status, 401)
  const created = await request('/v1/databases', 'POST', { databaseID: 'Sales', preference: 'json', root: '/tmp/ignored', action: 'list' })
  assert.equal(created.status, 200)
  assert.equal((await created.json()).id, 'Sales')
  await writeFile(resolve(root, 'Databases/Sales/data.json'), '[1,2,3]')
  const read = await request('/v1/databases/data', 'POST', { databaseID: 'Sales', relativePath: 'data.json' })
  assert.equal(Buffer.from((await read.json()).jsonBase64, 'base64').toString(), '[1,2,3]')
  assert.equal((await request('/v1/databases/preference', 'PATCH', { databaseID: 'Sales', preference: 'sqlite' })).status, 200)
  const listed = await (await request('/v1/databases')).json()
  assert.deepEqual(listed.databases, [{ id: 'Sales', name: 'Sales', preference: 'sqlite' }])
  assert.equal((await request('/v1/databases/data', 'POST', { databaseID: '../Sales', relativePath: 'data.json' })).status, 400)
})

test('Built-in credential routes require authentication, unlock explicitly, and keep files encrypted', async context => {
  const root = await temporaryFixture(context, 'wovenmatter-credentials-api-');
  const home = resolve(root, 'home'); await mkdir(home);
  const service = await startService({ workspace: root, home, catalog: catalogPath, token: 'credential-test-token' });
  context.after(() => service.child.kill('SIGTERM'));
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

async function startService({ workspace, home, catalog, token, gatewayPort }) {
  const port = await unusedPort()
  const environment = await fixtureEnvironment(home)
  const child = spawn(process.execPath, [resolve(repositoryRoot, 'remote/src/server.mjs')], {
    cwd: repositoryRoot,
    env: {
      ...environment,
      WOVENMATTER_API_TOKEN: token,
      WOVENMATTER_LISTEN_HOST: '127.0.0.1',
      WOVENMATTER_LISTEN_PORT: String(port),
      WOVENMATTER_WORKSPACE: workspace,
      WOVENMATTER_HARNESS_CATALOG: catalog,
      WOVENMATTER_GATEWAY_PORT: String(gatewayPort ?? await unusedPort()),
    },
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  await new Promise((resolvePromise, reject) => {
    const timeout = setTimeout(() => reject(new Error('service did not start')), 5_000)
    child.once('exit', (code) => reject(new Error(`service exited ${code}`)))
    child.stdout.on('data', (data) => {
      if (!String(data).includes('listening')) return
      clearTimeout(timeout)
      resolvePromise()
    })
  })
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

function runProcess(command, argumentsValue, { cwd, env, input }) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, argumentsValue, { cwd, env, stdio: ['pipe', 'pipe', 'pipe'] })
    let stdout = ''
    let stderr = ''
    child.stdout.on('data', (data) => { stdout += data.toString('utf8') })
    child.stderr.on('data', (data) => { stderr += data.toString('utf8') })
    child.once('error', reject)
    child.once('close', (code) => resolvePromise({ code, stdout, stderr }))
    child.stdin.end(input)
  })
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

function canConnect(port) {
  return new Promise((resolvePromise) => {
    const socket = connect({ host: '127.0.0.1', port })
    const finish = (ready) => {
      socket.removeAllListeners()
      socket.destroy()
      resolvePromise(ready)
    }
    socket.setTimeout(1_000, () => finish(false))
    socket.once('connect', () => finish(true))
    socket.once('error', () => finish(false))
  })
}

function socketText(socket) {
  return new Promise((resolvePromise, reject) => {
    let value = ''
    const timeout = setTimeout(() => reject(new Error('socket response timed out')), 5_000)
    socket.on('error', reject)
    socket.on('data', (data) => {
      value += data.toString('utf8')
      if (!value.includes('\r\n\r\n')) return
      clearTimeout(timeout)
      resolvePromise(value)
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

function fakePiRPCExecutable() {
  return `#!/usr/bin/env node
let input = ''
process.stdin.on('data', (data) => { input += data.toString('utf8') })
process.stdin.on('end', () => {
  const request = JSON.parse(input.trim())
  process.stdout.write(JSON.stringify({
    type: 'response',
    id: request.id,
    success: true,
    data: { sessionId: 'fixture' },
  }) + '\\n')
})
`
}
