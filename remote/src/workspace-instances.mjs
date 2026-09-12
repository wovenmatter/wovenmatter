import { readFile, mkdir } from 'node:fs/promises'
import { spawn, execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { request as httpRequest } from 'node:http'
import { resolve } from 'node:path'
import { acquireHostLock } from './runtime-maintenance.mjs'

export const supportedOpenCodeVersion = '0.0.0-beta-19278'
const prefix = '/v1/workspace-instances/opencode'
const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const executeFile = promisify(execFile)
const delay = (ms) => new Promise((done) => setTimeout(done, ms))

// Each service is already bound to exactly one configured remote workspace.
// The registration and credentials stay on that host, never in API responses.
export function createWorkspaceInstances(options) {
  const { workspaceRoot, gateway } = options
  const environment = options.environment ?? (() => process.env)
  const launch = options.spawn ?? spawn
  const fetchRequest = options.fetch ?? fetch
  const read = options.readFile ?? readFile
  const signal = options.signal ?? ((pid, value) => process.kill(pid, value))
  const sleep = options.sleep ?? delay
  const stateHome = resolve(workspaceRoot, '.woven-matter', 'opencode-state')
  const registrationPath = resolve(stateHome, 'opencode', 'service.json')
  const isEnabled = options.isEnabled ?? (async () => true)
  let operation = null
  let launched = null
  let lastError = null

  function alive(pid) {
    try { signal(pid, 0); return true } catch (error) { return error.code !== 'ESRCH' }
  }
  async function registration() {
    let bytes
    try { bytes = await read(registrationPath) } catch (error) {
      if (error.code === 'ENOENT') return null
      throw fail(503, 'opencode_registration_unavailable')
    }
    try {
      if (Buffer.byteLength(bytes) > 65536) throw new Error()
      const info = JSON.parse(String(bytes))
      const url = new URL(info.url)
      // Do not resolve arbitrary hostname destinations or follow redirects.
      if (url.protocol !== 'http:' || !['127.0.0.1', '[::1]', 'localhost'].includes(url.hostname)
        || url.username || url.password || url.search || url.hash || url.pathname !== '/'
        || !Number.isInteger(info.pid) || info.pid <= 0 || info.pid > 2147483647
        || typeof info.password !== 'string' || !info.password.length) throw new Error()
      return { url, pid: info.pid, version: info.version,
        authorization: `Basic ${Buffer.from(`opencode:${info.password}`).toString('base64')}` }
    } catch { throw fail(503, 'opencode_registration_invalid') }
  }
  async function health(info) {
    const response = await fetchRequest(new URL('/api/health', info.url), {
      headers: { authorization: info.authorization }, redirect: 'error', signal: AbortSignal.timeout(5000),
    })
    if (!response.ok) throw fail(503, 'opencode_health_unavailable')
    const result = await response.json()
    if (result.version !== supportedOpenCodeVersion || (info.version && info.version !== result.version)) {
      throw fail(409, 'opencode_version_incompatible')
    }
    if (result.healthy !== true || result.pid !== info.pid) throw fail(503, 'opencode_identity_changed')
    return result
  }
  async function status(kind) {
    if (kind === 'openclaw') {
      const current = gateway.status()
      return { kind, state: current.state, pid: current.pid ?? null, version: null,
        endpointPath: '/v1/openclaw/gateway/socket',
        // The legacy gateway captures stderr which can contain credentials.
        lastError: current.lastError ? 'Gateway reported an error. Inspect the gateway logs on this workspace host.' : null }
    }
    const base = { kind: 'opencode', state: operation ? 'starting' : 'stopped', pid: null,
      version: null, endpointPath: `${prefix}/api`, lastError }
    try {
      const info = await registration()
      if (!info || !alive(info.pid)) return base
      base.pid = info.pid
      await health(info)
      return { ...base, state: 'running', version: supportedOpenCodeVersion, lastError: null }
    } catch (error) { return { ...base, state: 'unavailable', lastError: publicError(error) } }
  }
  async function start() {
    if (!await isEnabled('opencode')) throw fail(409, 'runtime_disabled')
    const existing = await registration()
    if (existing && alive(existing.pid)) { await health(existing); return }
    if (launched && launched.exitCode === null) throw fail(409, 'opencode_start_pending_refresh_before_retry')
    const hostEnvironment = environment()
    if (!hostEnvironment.HOME) throw fail(503, 'opencode_host_home_unavailable')
    const releaseLock = await (options.acquireLock ?? acquireHostLock)(resolve(hostEnvironment.HOME, '.wovenmatter/runtime-operation.lock'), hostEnvironment, workspaceRoot, true)
    let ownedChild = null
    let released = false
    const unlock = () => { if (!released) { released = true; releaseLock() } }
    try {
      let version
      try {
        const result = await (options.execFile ?? executeFile)('opencode2', ['--version'], { env: environment(), timeout: 10000, maxBuffer: 4096 })
        version = result.stdout.trim().replace(/^opencode2 v/, '')
      } catch { throw fail(503, 'opencode_executable_unavailable') }
      if (version !== supportedOpenCodeVersion) throw fail(409, 'opencode_version_incompatible')
      await (options.mkdir ?? mkdir)(stateHome, { recursive: true, mode: 0o700 })
      const child = launch('opencode2', ['serve', '--service', '--hostname', '127.0.0.1'], {
        cwd: workspaceRoot, env: { ...environment(), XDG_STATE_HOME: stateHome }, stdio: 'ignore',
      })
      launched = child
      ownedChild = child
      child.once('close', unlock)
      child.once('error', unlock)
      let spawnFailed = false
      child.once('error', () => { spawnFailed = true })
      for (let attempt = 0; attempt < 120; attempt++) {
        if (spawnFailed || (child.exitCode !== null && child.exitCode !== 0)) throw fail(503, 'opencode_start_failed')
        try { const info = await registration(); if (info) { await health(info); return } } catch { /* startup registration may be incomplete */ }
        await sleep(250)
      }
      // Startup may still be migrating host data. Never kill an uncertain service.
      throw fail(503, 'opencode_start_pending_refresh_before_retry')
    } finally {
      if (!ownedChild || ownedChild.exitCode !== null) unlock()
    }
  }
  async function stop() {
    const info = await registration()
    if (!info) {
      if (launched && launched.exitCode === null) throw fail(409, 'opencode_start_pending_refresh_before_retry')
      return
    }
    if (!alive(info.pid)) return
    await health(info)
    const current = await registration()
    if (!current || current.pid !== info.pid || current.authorization !== info.authorization
      || String(current.url) !== String(info.url)) throw fail(409, 'opencode_identity_changed')
    try { signal(info.pid, 'SIGTERM') } catch (error) { if (error.code !== 'ESRCH') throw fail(503, 'opencode_stop_failed') }
    for (let attempt = 0; attempt < 80; attempt++) {
      if (!alive(info.pid)) { launched = null; return }
      await sleep(125)
    }
    throw fail(503, 'opencode_stop_pending')
  }
  async function action(kind, verb) {
    if (operation) throw fail(409, 'workspace_instance_operation_in_progress')
    // Set the lock before any asynchronous registration, enablement or health checks.
    operation = { kind, verb }
    try {
      if (kind === 'openclaw') {
        if (verb === 'start' && !await isEnabled('openclaw')) throw fail(409, 'runtime_disabled')
        await gateway[verb]()
      } else await (verb === 'start' ? start() : stop())
      lastError = null
    } catch (error) { lastError = publicError(error); throw fail(error.statusCode ?? 503, lastError) }
    finally { operation = null }
    return status(kind)
  }
  async function proxy(request, response, url) {
    if (!await isEnabled('opencode')) throw fail(409, 'runtime_disabled')
    const path = url.pathname.slice(prefix.length)
    if (!path.startsWith('/api/') || path.includes('\\')) throw fail(400, 'invalid_opencode_path')
    const info = await registration()
    if (!info || !alive(info.pid)) throw fail(503, 'opencode_not_running')
    // Authenticated health verifies the registration's service identity before mutations.
    await health(info)
    const target = new URL(info.url)
    target.pathname = path
    if (!target.pathname.startsWith('/api/')) throw fail(400, 'invalid_opencode_path')
    target.search = url.search
    await new Promise((done, reject) => {
      const headers = { authorization: info.authorization }
      for (const name of ['accept', 'content-type', 'last-event-id']) {
        if (request.headers[name]) headers[name] = request.headers[name]
      }
      const upstream = (options.httpRequest ?? httpRequest)(target, { method: request.method, headers }, (incoming) => {
        // No credentials/cookies/redirects from the host service escape this proxy.
        if (incoming.statusCode >= 300 && incoming.statusCode < 400) {
          incoming.resume(); reject(fail(502, 'opencode_redirect_refused')); return
        }
        response.statusCode = incoming.statusCode ?? 502
        for (const name of ['content-type', 'cache-control']) {
          if (incoming.headers[name]) response.setHeader(name, incoming.headers[name])
        }
        incoming.on('error', () => { response.destroy(); done() })
        incoming.on('end', done)
        incoming.pipe(response)
      })
      upstream.on('error', () => {
        if (response.headersSent) { response.destroy(); done() }
        else reject(fail(502, 'opencode_proxy_unavailable'))
      })
      // SSE can remain silent while idle; cancellation still closes the upstream.
      response.once('close', () => { upstream.destroy(); done() })
      request.once('aborted', () => upstream.destroy())
      request.pipe(upstream)
    })
  }
  async function handle(request, response, url) {
    if (url.pathname.startsWith(`${prefix}/api/`)) { await proxy(request, response, url); return true }
    const match = url.pathname.match(/^\/v1\/workspace-instances\/(opencode|openclaw)(?:\/(start|stop))?$/)
    if (!match) return false
    const [, kind, verb] = match
    if ((!verb && request.method !== 'GET') || (verb && request.method !== 'POST')) throw fail(405, 'method_not_allowed')
    const value = verb ? await action(kind, verb) : await status(kind)
    response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
    response.end(JSON.stringify(value))
    return true
  }
  async function hasActiveRuntime(id) {
    if (id === 'openclaw') return Boolean(gateway.status().pid) || operation?.kind === 'openclaw'
    if (id !== 'opencode') return false
    if (operation?.kind === 'opencode' || (launched && launched.exitCode === null)) return true
    try { const info = await registration(); return Boolean(info && alive(info.pid)) }
    catch { return true } // uncertain identity must block upgrades
  }
  return { handle, hasActiveRuntime, status, action, registrationPath }
}

function publicError(error) {
  // Only our fixed identifiers are safe to expose. Never child stderr, auth, or URLs.
  return /^(opencode|workspace_instance|runtime_disabled)[a-z_]*$/.test(error.message ?? '')
    ? error.message : 'workspace_instance_operation_failed'
}
