import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { createHash } from 'node:crypto'
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { connect, createServer as createNetServer } from 'node:net'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { downloadInstallerSource } from '../src/server.mjs'

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
  const headers = { authorization: 'Bearer service-token' }
  const health = await fetch(`${service.url}/v1/health`, { headers })
  assert.equal((await health.json()).status, 'ready')
  const response = await fetch(`${service.url}/v1/harnesses`, { headers })
  const harnesses = (await response.json()).harnesses
  assert.deepEqual(harnesses.map((value) => value.id), [
    'codex', 'claude_code', 'grok_build', 'hermes',
    'cursor', 'opencode', 'pi', 'openclaw',
  ])
  assert.ok(harnesses.every((value) =>
    Array.isArray(value.setupMethods) && value.setupMethods.length > 0
  ))
  assert.deepEqual(
    Object.keys(harnesses[0].setupMethods[0]).sort(),
    ['displayName', 'id']
  )
  assert.ok(harnesses.every((value) =>
    !['adapterInstalled', 'cliInstalled', 'installCommand', 'installSource', 'operation']
      .some((field) => Object.hasOwn(value, field))
  ))
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
    (value) => value.harnesses[0].state === 'ready'
  )
  assert.equal(harnessDocument.harnesses[0].authenticationStatus, 'configured')
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
  const statuses = (await response.json()).harnesses
  assert.equal(statuses[0].state, 'ready')
  assert.equal(statuses[0].transportStatus, 'ready')
  assert.equal(statuses[0].transportError, null)
  assert.equal(statuses[1].state, 'transport_unavailable')
  assert.equal(statuses[1].transportStatus, 'unavailable')
  assert.match(statuses[1].transportError, /exited before readiness/)
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
        ...process.env,
        HOME: home,
        PATH: `${bin}:${process.env.PATH}`,
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

test('installation includes the declared transport adapter', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-install-')
  const home = resolve(fixture, 'home')
  const workspace = resolve(fixture, 'workspace')
  const bin = resolve(home, '.local/bin')
  const npmArguments = resolve(fixture, 'npm-arguments')
  await mkdir(bin, { recursive: true })
  await mkdir(workspace, { recursive: true })
  const npm = resolve(bin, 'npm')
  await writeFile(npm, `#!/bin/sh\nprintf '%s\\n' "$@" > '${npmArguments}'\n`)
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
  assert.equal(operation.status, 'succeeded')
  const argumentsValue = await readFile(npmArguments, 'utf8')
  assert.match(argumentsValue, /@earendil-works\/pi-coding-agent/)
  assert.match(argumentsValue, /@example\/pi-rpc-adapter@1\.2\.3/)
})

test('Gateway upgrades are authenticated and never forward the API token', async (context) => {
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
  assert.match(await socketText(socket), /^HTTP\/1\.1 101 Switching Protocols/)
  assert.doesNotMatch(upstreamRequest, /authorization:|gateway-token/i)
})

test('Gateway start reports running only after its listener accepts connections', async (context) => {
  const fixture = await temporaryFixture(context, 'wovenmatter-gateway-ready-')
  const home = resolve(fixture, 'home')
  const bin = resolve(home, '.local/bin')
  const gatewayPort = await unusedPort()
  await mkdir(bin, { recursive: true })
  const openclaw = resolve(bin, 'openclaw')
  await writeFile(openclaw, `#!/usr/bin/env node
const { createServer } = require('node:net')
const port = Number(process.argv[process.argv.indexOf('--port') + 1])
const server = createServer((socket) => socket.destroy())
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
})

async function temporaryFixture(context, prefix) {
  const directory = await mkdtemp(resolve(tmpdir(), prefix))
  context.after(() => rm(directory, { recursive: true, force: true }))
  return directory
}

async function startService({ workspace, home, catalog, token, gatewayPort }) {
  const port = await unusedPort()
  const child = spawn(process.execPath, [resolve(repositoryRoot, 'remote/src/server.mjs')], {
    cwd: repositoryRoot,
    env: {
      ...process.env,
      HOME: home,
      WOVENMATTER_API_TOKEN: token,
      WOVENMATTER_LISTEN_PORT: String(port),
      WOVENMATTER_WORKSPACE: workspace,
      WOVENMATTER_HARNESS_CATALOG: catalog,
      ...(gatewayPort ? { WOVENMATTER_GATEWAY_PORT: String(gatewayPort) } : {}),
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
