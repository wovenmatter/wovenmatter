import { createServer } from 'node:http'
import { timingSafeEqual, randomUUID, createHash } from 'node:crypto'
import { readFile, writeFile, mkdir } from 'node:fs/promises'
import { spawn } from 'node:child_process'
import { connect } from 'node:net'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const modulePath = fileURLToPath(import.meta.url)
const runningAsService = resolve(process.argv[1] ?? '') === modulePath
const serviceRoot = resolve(dirname(modulePath), '..')
const catalogPath = process.env.WOVENMATTER_HARNESS_CATALOG
  ?? resolve(serviceRoot, 'harnesses/catalog.json')
const workspaceRoot = process.env.WOVENMATTER_WORKSPACE
  ?? resolve(process.env.HOME, '.woven-matter')
const listenHost = process.env.WOVENMATTER_LISTEN_HOST ?? '127.0.0.1'
const listenPort = parsePositiveInteger(process.env.WOVENMATTER_LISTEN_PORT, 7337)
const apiToken = runningAsService
  ? requiredEnvironment('WOVENMATTER_API_TOKEN')
  : process.env.WOVENMATTER_API_TOKEN ?? ''
const gatewayPort = parsePositiveInteger(process.env.WOVENMATTER_GATEWAY_PORT, 18789)

const catalogDocument = runningAsService
  ? JSON.parse(await readFile(catalogPath, 'utf8'))
  : { schemaVersion: 4, harnesses: [] }
if (catalogDocument.schemaVersion !== 4 || !Array.isArray(catalogDocument.harnesses)) {
  throw new Error('Unsupported harness catalog')
}
const catalog = new Map(catalogDocument.harnesses.map((entry) => [entry.id, entry]))
const operations = new Map()
const authenticationSessions = new Map()
const maximumRetainedTerminalRecords = 64
const maximumInstallerBytes = 5_242_880
const installerDownloadTimeoutMilliseconds = 30_000
const maximumInstallerRedirects = 5
let gateway = { process: null, desired: false, restarts: 0, lastError: null }

const server = createServer(async (request, response) => {
  try {
    if (!authorized(request)) return json(response, 401, { error: 'unauthorized' })
    const url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`)

    if (request.method === 'GET' && url.pathname === '/v1/health') {
      return json(response, 200, {
        status: 'ready',
        version: '0.1.0',
        workspaceRoot,
        harnessCount: catalog.size,
        gateway: gatewayStatus(),
      })
    }

    if (request.method === 'GET' && url.pathname === '/v1/harnesses') {
      const statuses = await Promise.all([...catalog.values()].map(harnessStatus))
      return json(response, 200, { harnesses: statuses })
    }

    const installPreview = url.pathname.match(/^\/v1\/harnesses\/([^/]+)\/install-preview$/)
    if (request.method === 'GET' && installPreview) {
      const harness = requireHarness(installPreview[1])
      return json(response, 200, await installerPreview(harness))
    }

    const harnessAction = url.pathname.match(/^\/v1\/harnesses\/([^/]+)\/(install|update|recheck)$/)
    if (request.method === 'POST' && harnessAction) {
      const harness = requireHarness(harnessAction[1])
      const body = await readJSON(request)
      const action = harnessAction[2]
      if ((action === 'install' || action === 'update') && body.confirmed !== true) {
        return json(response, 409, { error: 'confirmation_required' })
      }
      if (action === 'recheck') return json(response, 200, await harnessStatus(harness))
      let installerPath = null
      if ((action === 'install' || action === 'update')
        && harness.install.kind === 'official-script') {
        if (typeof body.sourceSHA256 !== 'string') {
          return json(response, 409, { error: 'source_digest_required' })
        }
        installerPath = (await verifiedInstaller(
          harness,
          body.sourceSHA256
        )).path
      }
      const operation = startHarnessOperation(harness, action, installerPath)
      return json(response, 202, operationView(operation))
    }

    const operationMatch = url.pathname.match(/^\/v1\/operations\/([^/]+)$/)
    if (request.method === 'GET' && operationMatch) {
      const operation = operations.get(normalizeIdentifier(operationMatch[1]))
      if (!operation) return json(response, 404, { error: 'operation_not_found' })
      return json(response, 200, operationView(operation))
    }

    const signInMatch = url.pathname.match(/^\/v1\/harnesses\/([^/]+)\/sign-in$/)
    if (request.method === 'POST' && signInMatch) {
      const harness = requireHarness(signInMatch[1])
      const body = await readJSON(request)
      const method = requireAuthenticationMethod(harness, body.methodID)
      const session = startAuthenticationSession(harness, method)
      return json(response, 201, authenticationSessionView(session))
    }

    const authorizationCodeMatch = url.pathname.match(
      /^\/v1\/authentication-sessions\/([^/]+)\/authorization-code$/
    )
    if (request.method === 'POST' && authorizationCodeMatch) {
      const session = requireAuthenticationSession(authorizationCodeMatch[1])
      if (session.method.acceptsInput !== true) {
        return json(response, 409, { error: 'authorization_code_not_supported' })
      }
      if (session.state !== 'waiting_for_user'
        || session.child?.stdin?.writable !== true
        || session.child.stdin.destroyed) {
        return json(response, 409, { error: 'authentication_session_not_active' })
      }
      const body = await readJSON(request)
      if (typeof body.code !== 'string'
        || body.code.trim().length === 0
        || Buffer.byteLength(body.code) > 4_096) {
        return json(response, 400, { error: 'invalid_authorization_code' })
      }
      session.child.stdin.write(`${body.code.trim()}\n`)
      return json(response, 202, { accepted: true })
    }

    const authenticationSessionMatch = url.pathname.match(
      /^\/v1\/authentication-sessions\/([^/]+)$/
    )
    if (request.method === 'GET' && authenticationSessionMatch) {
      return json(
        response,
        200,
        authenticationSessionView(
          requireAuthenticationSession(authenticationSessionMatch[1])
        )
      )
    }
    if (request.method === 'DELETE' && authenticationSessionMatch) {
      const session = requireAuthenticationSession(authenticationSessionMatch[1])
      if (session.state !== 'waiting_for_user' || !session.child) {
        return json(response, 409, { error: 'authentication_session_not_active' })
      }
      session.cancelRequested = true
      session.child.kill('SIGTERM')
      return json(response, 202, { stopping: true })
    }

    if (request.method === 'GET' && url.pathname === '/v1/openclaw/gateway') {
      return json(response, 200, gatewayStatus())
    }
    if (request.method === 'POST' && url.pathname === '/v1/openclaw/gateway/start') {
      gateway.desired = true
      await startGateway()
      return json(response, 202, gatewayStatus())
    }
    if (request.method === 'POST' && url.pathname === '/v1/openclaw/gateway/restart') {
      gateway.desired = true
      gateway.restarts = 0
      gateway.process?.kill('SIGTERM')
      if (!gateway.process) await startGateway()
      return json(response, 202, gatewayStatus())
    }
    return json(response, 404, { error: 'not_found' })
  } catch (error) {
    const status = error.statusCode ?? 500
    return json(response, status, { error: error.message ?? 'internal_error' })
  }
})

server.on('upgrade', (request, socket, head) => {
  if (!authorized(request) || request.url !== '/v1/openclaw/gateway/socket') {
    socket.write('HTTP/1.1 401 Unauthorized\r\nConnection: close\r\n\r\n')
    return socket.destroy()
  }
  const upstream = connect({ host: '127.0.0.1', port: gatewayPort }, () => {
    const headers = Object.entries(request.headers)
      .filter(([name]) => !['authorization', 'host'].includes(name.toLowerCase()))
      .map(([name, value]) => `${name}: ${Array.isArray(value) ? value.join(', ') : value}`)
      .join('\r\n')
    upstream.write(`GET / HTTP/1.1\r\nHost: 127.0.0.1:${gatewayPort}\r\n${headers}\r\n\r\n`)
    if (head.length) upstream.write(head)
    socket.pipe(upstream).pipe(socket)
  })
  upstream.on('error', () => socket.destroy())
})

if (runningAsService) {
  server.listen(listenPort, listenHost, () => {
    process.stdout.write(`Woven Matter remote service listening on ${listenHost}:${listenPort}\n`)
  })
}

function authorized(request) {
  const value = request.headers.authorization ?? ''
  if (!value.startsWith('Bearer ')) return false
  const presented = Buffer.from(value.slice(7))
  const expected = Buffer.from(apiToken)
  return presented.length === expected.length && timingSafeEqual(presented, expected)
}

async function harnessStatus(harness) {
  const cliInstalled = await commandExists(harness.cliCommand)
  const adapterInstalled = harness.adapterPackage
    ? await commandExists(harness.command)
    : typeof harness.transportCheckCommand === 'string'
      ? await commandSucceeded(harness.transportCheckCommand, 10_000)
      : await commandExists(harness.command)
  const [authenticationConfigured, detectedProviders] = cliInstalled && adapterInstalled
    ? await Promise.all([
      harnessAuthenticationConfigured(harness),
      discoverAuthenticationProviders(harness),
    ])
    : [false, []]
  let state = 'ready'
  if (!cliInstalled) state = 'cli_missing'
  else if (!adapterInstalled) state = 'adapter_missing'
  else if (!authenticationConfigured) {
    state = 'authentication_required'
  }
  return {
    id: harness.id,
    displayName: harness.displayName,
    transport: harness.transport,
    capabilities: harness.capabilities,
    state,
    authenticationStatus: state === 'authentication_required'
      ? 'required'
      : state === 'ready' ? 'configured' : 'unknown',
    setupMethods: (harness.authentication.methods ?? []).map((method) => ({
      id: method.id,
      displayName: method.displayName,
    })),
    detectedProviders,
  }
}

async function discoverAuthenticationProviders(harness) {
  const discoveries = harness.authentication.discoveries ?? []
  const results = await Promise.all(discoveries.map(async (discovery) => ({
    discovery,
    configured: await commandSucceeded(discovery.statusCommand, 10_000),
  })))
  return results
    .filter((value) => value.configured)
    .map((value) => value.discovery.displayName)
}

function startHarnessOperation(harness, action, installerPath = null) {
  const active = [...operations.values()].find((value) => value.harnessID === harness.id && value.status === 'running')
  if (active) return active
  const command = operationCommand(harness, action, installerPath)
  const operation = {
    id: randomUUID(), harnessID: harness.id, action, status: 'running',
    output: '', error: null, startedAt: new Date().toISOString(), finishedAt: null,
  }
  operations.set(normalizeIdentifier(operation.id), operation)
  const child = spawn('/bin/bash', ['-c', command], {
    cwd: workspaceRoot,
    env: harnessEnvironment(),
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  capture(child.stdout, operation)
  capture(child.stderr, operation)
  child.on('error', (error) => { operation.error = error.message })
  child.on('close', async (code) => {
    operation.status = code === 0 ? 'succeeded' : 'failed'
    operation.error = code === 0 ? null : operation.error ?? `command exited ${code}`
    operation.finishedAt = new Date().toISOString()
    pruneTerminalRecords(operations, (value) => value.status !== 'running')
  })
  return operation
}

function operationCommand(harness, action, installerPath) {
  if (action === 'install' || action === 'update') {
    const adapterPackage = harness.minimumAdapterVersion
      ? `${harness.adapterPackage}@${harness.minimumAdapterVersion}`
      : harness.adapterPackage
    if (harness.install.kind === 'npm-global') {
      const packages = [harness.install.package, adapterPackage]
        .filter((value) => typeof value === 'string')
        .map(shellQuote)
        .join(' ')
      return `npm install --global --prefix "$HOME/.local" ${packages}`
    }
    if (!installerPath) throw httpError(409, 'verified_installer_required')
    const adapter = harness.adapterPackage
      ? ` && npm install --global --prefix "$HOME/.local" ${shellQuote(adapterPackage)}`
      : ''
    const interpreter = shellQuote(harness.install.interpreter)
    const argumentsValue = (harness.install.arguments ?? []).map(shellQuote).join(' ')
    return `${interpreter} ${shellQuote(installerPath)} ${argumentsValue}${adapter}`
  }
  throw httpError(400, 'unsupported_action')
}

function startAuthenticationSession(harness, method) {
  const active = [...authenticationSessions.values()].find((value) =>
    value.harness.id === harness.id
      && value.method.id === method.id
      && value.state === 'waiting_for_user'
  )
  if (active) return active
  const id = randomUUID()
  const launch = authenticationProcessLaunch(method)
  const child = spawn(launch.command, launch.arguments, {
    cwd: workspaceRoot,
    env: harnessEnvironment(),
    stdio: ['pipe', 'pipe', 'pipe'],
  })
  const session = {
    id,
    harness,
    method,
    child,
    state: 'waiting_for_user',
    output: '',
    error: null,
    cancelRequested: false,
  }
  authenticationSessions.set(normalizeIdentifier(id), session)
  captureAuthenticationOutput(child.stdout, session)
  captureAuthenticationOutput(child.stderr, session)
  child.on('error', (error) => {
    session.error = error.message
    session.state = 'failed'
  })
  child.on('close', async (code) => {
    if (session.cancelRequested) {
      session.state = 'cancelled'
    } else if (code !== 0) {
      session.state = 'failed'
    } else if (await harnessAuthenticationConfigured(harness)) {
      session.state = 'succeeded'
    } else {
      session.state = 'failed'
      session.error = 'Sign-in finished, but the harness could not verify a usable account.'
    }
    if (code !== 0 && !session.error) {
      session.error = authenticationFailureDetail(code)
    }
    session.child = null
    pruneTerminalRecords(
      authenticationSessions,
      (value) => value.state !== 'waiting_for_user'
    )
  })
  return session
}

function authenticationProcessLaunch(method) {
  const command = process.platform !== 'darwin' && method.inputSecret === true
    ? `stty -echo; ${method.command}`
    : method.command
  return process.platform === 'darwin'
    ? { command: '/bin/bash', arguments: ['-c', command] }
    : { command: '/usr/bin/script', arguments: ['-qefc', command, '/dev/null'] }
}

async function startGateway() {
  if (gateway.process) return
  if (!await commandExists('openclaw')) throw httpError(409, 'openclaw_not_installed')
  const child = spawn('openclaw', ['gateway', 'run', '--bind', 'loopback', '--port', String(gatewayPort)], {
    cwd: workspaceRoot,
    env: harnessEnvironment(),
    stdio: ['ignore', 'pipe', 'pipe'],
  })
  gateway.process = child
  gateway.lastError = null
  child.stdout.on('data', (data) => process.stdout.write(`[gateway] ${data}`))
  child.stderr.on('data', (data) => {
    gateway.lastError = String(data).trim().slice(-2000)
    process.stderr.write(`[gateway] ${data}`)
  })
  child.on('close', () => {
    gateway.process = null
    if (gateway.desired && gateway.restarts < 3) {
      gateway.restarts += 1
      setTimeout(() => startGateway().catch((error) => { gateway.lastError = error.message }), 1000 * gateway.restarts)
    }
  })
}

function gatewayStatus() {
  return {
    desired: gateway.desired,
    state: gateway.process ? 'running' : gateway.desired ? 'reconnecting' : 'stopped',
    pid: gateway.process?.pid ?? null,
    restarts: gateway.restarts,
    lastError: gateway.lastError,
    socketPath: '/v1/openclaw/gateway/socket',
  }
}

function authenticationSessionView(session) {
  const artifacts = authenticationArtifacts(session.output)
  const configuredVerificationURL = session.method.verificationURL
  return {
    id: session.id,
    harnessID: session.harness.id,
    methodID: session.method.id,
    methodName: session.method.displayName,
    state: session.state,
    verificationURL: artifacts.verificationURL ?? configuredVerificationURL ?? null,
    userCode: artifacts.userCode,
    message: authenticationMessage(session.harness, session.method, artifacts),
    error: session.error,
    acceptsAuthorizationCode: session.method.acceptsInput === true,
    credentialInputLabel: session.method.inputLabel
      ?? (session.method.acceptsInput === true ? 'Authorization code' : null),
    credentialInputSecret: session.method.inputSecret === true,
    notice: session.method.notice ?? null,
  }
}

function operationView(operation) {
  return { ...operation, output: operation.output.slice(-16_384) }
}

function capture(stream, operation) {
  stream.on('data', (data) => { operation.output = (operation.output + data).slice(-65_536) })
}

function captureAuthenticationOutput(stream, session) {
  stream.on('data', (data) => {
    session.output = (session.output + data.toString('utf8')).slice(-65_536)
  })
}

function pruneTerminalRecords(records, isTerminal) {
  let terminalCount = [...records.values()].filter(isTerminal).length
  if (terminalCount <= maximumRetainedTerminalRecords) return
  for (const [id, value] of records) {
    if (!isTerminal(value)) continue
    records.delete(id)
    terminalCount -= 1
    if (terminalCount <= maximumRetainedTerminalRecords) return
  }
}

function authenticationArtifacts(output) {
  const text = sanitizedAuthenticationOutput(output)
  const urlMatches = text.match(/https?:\/\/[^\s<>"']+/gu) ?? []
  const verificationURLs = urlMatches
    .map((value) => value.replace(/[),.;]+$/u, ''))
    .filter((value) => {
      try {
        const url = new URL(value)
        return url.protocol === 'https:'
      } catch {
        return false
      }
    })
  const verificationURL = verificationURLs[0] ?? null
  const URLUserCode = verificationURLs
    .map((value) => new URL(value).searchParams.get('user_code'))
    .find((value) => typeof value === 'string' && value.length > 0) ?? null
  const codeMatch = text.match(
    /(?:one[- ]time|device|authorization|confirm\s+this)?\s*code(?:\s+in\s+your\s+browser)?(?:\s+is)?\s*[:\-]?\s*([A-Z0-9]{4,}(?:-[A-Z0-9]{3,})*)/iu
  )
  const labeledUserCode = normalizedAuthenticationCode(codeMatch?.[1])
  const promptedUserCode = authenticationPromptedCode(text)
  return {
    verificationURL,
    userCode: URLUserCode ?? promptedUserCode ?? labeledUserCode,
  }
}

function authenticationPromptedCode(text) {
  const lines = text.split(/\r?\n/u)
  for (let index = 0; index < lines.length; index += 1) {
    if (!/\b(?:(?:one[- ]time|device|authorization|confirmation)\s+)?code\b/iu.test(lines[index])) {
      continue
    }
    for (let offset = 1; offset <= 3 && index + offset < lines.length; offset += 1) {
      const candidate = normalizedAuthenticationCode(lines[index + offset])
      if (candidate) return candidate
    }
  }
  return null
}

function normalizedAuthenticationCode(value) {
  const candidate = typeof value === 'string' ? value.trim() : ''
  if (!/^[A-Z0-9]{4,}(?:-[A-Z0-9]{3,})*$/u.test(candidate)) return null
  if (new Set([
    'AUTHORIZATION', 'CONFIRMATION', 'CONTINUE', 'BROWSER', 'DEVICE', 'LOGIN', 'OPENAI', 'CHATGPT',
  ]).has(candidate)) return null
  return candidate
}

function authenticationMessage(harness, method, artifacts) {
  if (method.kind === 'api-key') {
    return `Enter the credential securely to finish ${method.displayName.toLowerCase()}.`
  }
  if (artifacts.verificationURL && artifacts.userCode) {
    return `Open the secure ${harness.displayName} sign-in page and enter the one-time code.`
  }
  if (artifacts.verificationURL) {
    return `Complete ${harness.displayName} sign-in in your browser.`
  }
  return `Preparing the secure ${harness.displayName} sign-in handoff…`
}

function authenticationFailureDetail(code) {
  return `Sign-in did not complete (exit status ${code ?? -1}). Try again or verify the provider is reachable.`
}

function sanitizedAuthenticationOutput(output) {
  return String(output)
    .replace(/\u001b\[[0-?]*[ -/]*[@-~]/gu, '')
    .replace(/[^\n\t\x20-\x7E]/gu, '')
}

async function commandExists(command) {
  if (!command) return false
  return new Promise((resolvePromise) => {
    const child = spawn('/bin/bash', ['-c', `command -v ${shellQuote(command)}`], { env: harnessEnvironment(), stdio: 'ignore' })
    child.on('error', () => resolvePromise(false))
    child.on('close', (code) => resolvePromise(code === 0))
  })
}

async function harnessAuthenticationConfigured(harness) {
  const commands = harness.authentication.statusCommands ?? []
  if (commands.length === 0) return false
  const results = await Promise.all(commands.map((command) =>
    commandSucceeded(command, 10_000)
  ))
  return results.some(Boolean)
}

function commandSucceeded(command, timeoutMilliseconds) {
  return new Promise((resolvePromise) => {
    const child = spawn('/bin/bash', ['-c', command], {
      cwd: workspaceRoot,
      env: harnessEnvironment(),
      stdio: 'ignore',
    })
    let settled = false
    const finish = (value) => {
      if (settled) return
      settled = true
      clearTimeout(timeout)
      resolvePromise(value)
    }
    const timeout = setTimeout(() => {
      child.kill('SIGTERM')
      finish(false)
    }, timeoutMilliseconds)
    child.on('error', () => finish(false))
    child.on('close', (code) => finish(code === 0))
  })
}

async function installerPreview(harness) {
  if (harness.install.kind === 'npm-global') {
    return {
      harnessID: harness.id,
      source: harness.install.source,
      sha256: null,
      bytes: null,
      command: harness.install.command,
      verification: 'npm-registry-integrity',
    }
  }
  const installer = await downloadInstaller(harness)
  return {
    harnessID: harness.id,
    source: harness.install.source,
    sha256: installer.sha256,
    bytes: installer.data.length,
    command: harness.install.command,
    verification: 'sha256-redownload',
  }
}

async function verifiedInstaller(harness, expectedSHA256) {
  const installer = await downloadInstaller(harness)
  if (installer.sha256 !== expectedSHA256.toLowerCase()) {
    throw httpError(409, 'installer_digest_changed')
  }
  const directory = resolve(workspaceRoot, '.wovenmatter/installers')
  await mkdir(directory, { recursive: true })
  const path = resolve(directory, `${harness.id}-${installer.sha256}.sh`)
  await writeFile(path, installer.data, { mode: 0o700 })
  return { ...installer, path }
}

async function downloadInstaller(harness) {
  return downloadInstallerSource(harness.install.source)
}

export async function downloadInstallerSource(source, options = {}) {
  const fetchImplementation = options.fetchImplementation ?? globalThis.fetch
  const maximumBytes = options.maximumBytes ?? maximumInstallerBytes
  const timeoutMilliseconds = options.timeoutMilliseconds
    ?? installerDownloadTimeoutMilliseconds
  if (typeof fetchImplementation !== 'function') throw new TypeError('fetchImplementation')
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) {
    throw new TypeError('maximumBytes')
  }
  if (!Number.isSafeInteger(timeoutMilliseconds) || timeoutMilliseconds <= 0) {
    throw new TypeError('timeoutMilliseconds')
  }

  const initialURL = requireHTTPSInstallerURL(source)
  const controller = new AbortController()
  const timeoutError = httpError(502, 'installer_download_timed_out')
  const timeout = setTimeout(() => controller.abort(timeoutError), timeoutMilliseconds)
  try {
    const response = await fetchInstallerResponse(
      initialURL,
      fetchImplementation,
      controller.signal
    )
    if (!response.ok) {
      cancelResponseBody(response, httpError(502, 'installer_download_failed'))
      throw httpError(502, 'installer_download_failed')
    }
    const declaredBytes = response.headers?.get?.('content-length')
    if (declaredBytes !== null && declaredBytes !== undefined) {
      const parsedBytes = Number(declaredBytes)
      if (!Number.isSafeInteger(parsedBytes)
        || parsedBytes <= 0
        || parsedBytes > maximumBytes) {
        cancelResponseBody(response, httpError(502, 'invalid_installer_size'))
        throw httpError(502, 'invalid_installer_size')
      }
    }
    const data = await readBoundedResponseBody(response, maximumBytes, controller.signal)
    if (data.length === 0) throw httpError(502, 'invalid_installer_size')
    return {
      data,
      sha256: createHash('sha256').update(data).digest('hex'),
    }
  } catch (error) {
    if (controller.signal.aborted) throw controller.signal.reason ?? timeoutError
    if (error?.statusCode) throw error
    throw httpError(502, 'installer_download_failed')
  } finally {
    clearTimeout(timeout)
  }
}

async function fetchInstallerResponse(initialURL, fetchImplementation, signal) {
  let currentURL = initialURL
  for (let redirects = 0; redirects <= maximumInstallerRedirects; redirects += 1) {
    const response = await awaitWithAbort(
      Promise.resolve().then(() => fetchImplementation(currentURL, {
        redirect: 'manual',
        signal,
      })),
      signal
    )
    let responseURL = currentURL
    try {
      if (response.url) responseURL = requireHTTPSInstallerURL(response.url)
    } catch (error) {
      cancelResponseBody(response, error)
      throw error
    }
    if (![301, 302, 303, 307, 308].includes(response.status)) return response

    const location = response.headers?.get?.('location')
    cancelResponseBody(response, httpError(502, 'installer_redirected'))
    if (!location || redirects === maximumInstallerRedirects) {
      throw httpError(502, 'installer_download_failed')
    }
    currentURL = requireHTTPSInstallerURL(new URL(location, responseURL))
  }
  throw httpError(502, 'installer_download_failed')
}

async function readBoundedResponseBody(response, maximumBytes, signal) {
  if (!response.body || typeof response.body.getReader !== 'function') {
    throw httpError(502, 'installer_download_failed')
  }
  const reader = response.body.getReader()
  const chunks = []
  let bytes = 0
  let cancelled = false
  try {
    while (true) {
      const { done, value } = await awaitWithAbort(reader.read(), signal)
      if (done) break
      const chunk = Buffer.from(value)
      bytes += chunk.length
      if (bytes > maximumBytes) {
        cancelled = true
        void reader.cancel(httpError(502, 'invalid_installer_size')).catch(() => {})
        throw httpError(502, 'invalid_installer_size')
      }
      chunks.push(chunk)
    }
  } finally {
    if (signal.aborted && !cancelled) {
      void reader.cancel(signal.reason).catch(() => {})
    }
    reader.releaseLock()
  }
  return Buffer.concat(chunks, bytes)
}

function requireHTTPSInstallerURL(source) {
  let url
  try {
    url = source instanceof URL ? source : new URL(source)
  } catch {
    throw httpError(502, 'installer_https_required')
  }
  if (url.protocol !== 'https:') throw httpError(502, 'installer_https_required')
  return url
}

function cancelResponseBody(response, reason) {
  if (!response.body || typeof response.body.cancel !== 'function') return
  void response.body.cancel(reason).catch(() => {})
}

function awaitWithAbort(promise, signal) {
  if (signal.aborted) return Promise.reject(signal.reason)
  return new Promise((resolvePromise, reject) => {
    const aborted = () => reject(signal.reason)
    signal.addEventListener('abort', aborted, { once: true })
    promise.then(
      (value) => {
        signal.removeEventListener('abort', aborted)
        resolvePromise(value)
      },
      (error) => {
        signal.removeEventListener('abort', aborted)
        reject(error)
      }
    )
  })
}

function harnessEnvironment() {
  return {
    ...process.env,
    HOME: process.env.HOME,
    PATH: `${resolve(process.env.HOME, '.local/bin')}:${resolve(process.env.HOME, '.npm-global/bin')}:${process.env.PATH}`,
    WOVENMATTER_WORKSPACE: workspaceRoot,
    WOVENMATTER_GATEWAY_PORT: String(gatewayPort),
    OPENCLAW_GATEWAY_TOKEN: apiToken,
  }
}

async function readJSON(request) {
  const chunks = []
  let bytes = 0
  for await (const chunk of request) {
    bytes += chunk.length
    if (bytes > 1_048_576) throw httpError(413, 'request_too_large')
    chunks.push(chunk)
  }
  if (chunks.length === 0) return {}
  try { return JSON.parse(Buffer.concat(chunks).toString('utf8')) }
  catch { throw httpError(400, 'invalid_json') }
}

function requireHarness(id) {
  const harness = catalog.get(id)
  if (!harness) throw httpError(404, 'harness_not_found')
  return harness
}

function requireAuthenticationMethod(harness, id) {
  if (typeof id !== 'string' || !id) throw httpError(400, 'authentication_method_required')
  const method = (harness.authentication.methods ?? []).find((value) => value.id === id)
  if (!method || typeof method.command !== 'string') {
    throw httpError(404, 'authentication_method_not_found')
  }
  return method
}

function requireAuthenticationSession(id) {
  const session = authenticationSessions.get(normalizeIdentifier(id))
  if (!session) throw httpError(404, 'authentication_session_not_found')
  return session
}

function normalizeIdentifier(id) {
  return String(id).toLowerCase()
}

function json(response, statusCode, value) {
  const body = JSON.stringify(value)
  response.writeHead(statusCode, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body), 'cache-control': 'no-store' })
  response.end(body)
}

function requiredEnvironment(name) {
  const value = process.env[name]
  if (!value) throw new Error(`${name} is required`)
  return value
}

function parsePositiveInteger(value, fallback) {
  const parsed = Number.parseInt(value ?? '', 10)
  return Number.isInteger(parsed) && parsed > 0 && parsed <= 65535 ? parsed : fallback
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`
}

function httpError(statusCode, message) {
  const error = new Error(message)
  error.statusCode = statusCode
  return error
}
