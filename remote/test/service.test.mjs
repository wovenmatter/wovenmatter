import test from 'node:test'
import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { chmod, mkdir, mkdtemp, readFile, rm, symlink, writeFile } from 'node:fs/promises'
import { connect, createServer as createNetServer } from 'node:net'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'

const repositoryRoot = resolve(import.meta.dirname, '../..')
const catalogPath = resolve(repositoryRoot, 'harnesses/catalog.json')

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
  for (const command of ['codex', 'codex-acp']) {
    const executable = resolve(bin, command)
    await writeFile(executable, '#!/bin/sh\nexit 0\n')
    await chmod(executable, 0o700)
  }

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
