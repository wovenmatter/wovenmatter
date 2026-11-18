import { readFile } from 'node:fs/promises'
import { harnessResource } from './harness-resources.mjs'
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import { request as httpRequest } from 'node:http'
import { resolve } from 'node:path'
import { acquireHostLock, harnessLockPath } from './runtime-maintenance.mjs'
import { supportsOpenCodeVersion, normalizeOpenCodeVersion, openCodeCommands } from './opencode-compatibility.mjs'
import { loadRuntimeConfiguration } from './config.mjs'

const { installOpenCode } = await import(harnessResource('mcp/install.mjs'))
const prefix = '/v1/workspace-instances/opencode'
const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const executeFile = promisify(execFile)
const delay = (ms) => new Promise((done) => setTimeout(done, ms))

// OpenCode v2 runs one shared background service per user, which every OpenCode
// client on the host uses: `opencode` in a terminal, the desktop app, and Woven.
// Woven starts, restarts and stops that same service with `opencode service`, and
// finds it through OpenCode's own registration. Credentials stay on the host.
export function createWorkspaceInstances(options) {
  const { workspaceRoot } = options
  const environment = options.environment ?? (() => process.env)
  const fetchRequest = options.fetch ?? fetch
  const read = options.readFile ?? readFile
  const run = options.execFile ?? executeFile
  const signal = options.signal ?? ((pid, value) => process.kill(pid, value))
  const registrationPath = () => {
    const env = environment()
    return resolve(env.XDG_STATE_HOME || resolve(env.HOME ?? '', '.local/state'), 'opencode', 'service.json')
  }
  const isEnabled = options.isEnabled ?? (async () => true)
  const installMCP = options.installMCP ?? installOpenCode
  let mcpInstalled = false
  function prepareMCP() { if (!mcpInstalled) { installMCP(environment()); mcpInstalled = true } }
  let operation = null
  let lastError = null

  function alive(pid) {
    try { signal(pid, 0); return true } catch (error) { return error.code !== 'ESRCH' }
  }
  async function registration() {
    let bytes
    try { bytes = await read(registrationPath()) } catch (error) {
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
  async function health(info, forStop = false) {
    const requestOptions = {
      headers: { authorization: info.authorization }, redirect: 'error', signal: AbortSignal.timeout(5000),
    }
    let response = await fetchRequest(new URL('/api/info', info.url), requestOptions)
    const legacyBeta = forStop && response.status === 404
    if (legacyBeta) response = await fetchRequest(new URL('/api/health', info.url), requestOptions)
    if (!response.ok) throw fail(503, 'opencode_health_unavailable')
    const result = await response.json()
    const validBeta = legacyBeta && result.healthy === true && /^0\.0\.0-beta-\d+$/.test(result.version)
    if ((!supportsOpenCodeVersion(result.version) && !validBeta) || (info.version && info.version !== result.version)) {
      throw fail(409, 'opencode_version_incompatible')
    }
    if (result.pid !== info.pid) throw fail(503, 'opencode_identity_changed')
    return result
  }
  async function status(kind) {
    if (kind !== 'opencode') throw fail(404, 'workspace_instance_not_found')
    const base = { kind: 'opencode', state: operation ? 'starting' : 'stopped', pid: null,
      version: null, endpointPath: `${prefix}/api`, lastError }
    try {
      const info = await registration()
      if (!info || !alive(info.pid)) return base
      base.pid = info.pid
      const current = await health(info)
      return { ...base, state: 'running', version: current.version, lastError: null }
    } catch (error) { return { ...base, state: 'unavailable', lastError: publicError(error) } }
  }
  /** The OpenCode v2 command: `opencode`, or its `opencode2` alias when `opencode` is v1. */
  async function command() {
    let found = false
    for (const candidate of openCodeCommands) {
      try {
        const result = await run(candidate, ['--version'], { env: environment(), timeout: 10000, maxBuffer: 4096 })
        found = true
        if (supportsOpenCodeVersion(normalizeOpenCodeVersion(result.stdout))) return candidate
      } catch { /* An absent primary command may have the alias installed. */ }
    }
    throw fail(found ? 409 : 503, found ? 'opencode_version_incompatible' : 'opencode_executable_unavailable')
  }
  async function service(verb) {
    const executable = await command()
    try { await run(executable, ['service', verb], { cwd: workspaceRoot, env: environment(), timeout: 60000, maxBuffer: 65536 }) }
    catch { throw fail(503, `opencode_${verb}_failed`) }
  }
  async function waitUntilHealthy() {
    for (let attempt = 0; attempt < 120; attempt++) {
      try { const info = await registration(); if (info && alive(info.pid)) { await health(info); return } } catch { /* startup registration may be incomplete */ }
      await delay(250)
    }
    // Startup may still be migrating data. Never kill an uncertain service.
    throw fail(503, 'opencode_start_pending_refresh_before_retry')
  }
  async function start() {
    if (!await isEnabled('opencode')) throw fail(409, 'runtime_not_installed')
    prepareMCP()
    const existing = await registration()
    if (existing && alive(existing.pid)) { await health(existing); return }
    const hostEnvironment = environment()
    if (!hostEnvironment.HOME) throw fail(503, 'opencode_host_home_unavailable')
    // Hold OpenCode's maintenance lock only while starting, so an install can't swap the binary underneath.
    const unlock = await (options.acquireLock ?? acquireHostLock)(harnessLockPath(loadRuntimeConfiguration(hostEnvironment), 'opencode'), hostEnvironment, workspaceRoot, true)
    try {
      await service('start')
      await waitUntilHealthy()
    } finally { unlock() }
  }
  async function stop() {
    const info = await registration()
    if (!info || !alive(info.pid)) return
    // Only an authenticated v2 service is stopped, never an unknown process.
    await health(info, true)
    await service('stop')
    for (let attempt = 0; attempt < 80; attempt++) {
      if (!alive(info.pid)) return
      await delay(125)
    }
    throw fail(503, 'opencode_stop_pending')
  }
  /** After an upgrade: restart the shared service onto the new release, if it's running. */
  async function restartIfRunning() {
    const info = await registration().catch(() => null)
    if (!info || !alive(info.pid)) return
    await service('restart')
    await waitUntilHealthy()
  }
  async function action(kind, verb) {
    if (kind !== 'opencode') throw fail(404, 'workspace_instance_not_found')
    if (operation) throw fail(409, 'workspace_instance_operation_in_progress')
    // Set the lock before any asynchronous registration, enablement or health checks.
    operation = { kind, verb }
    try {
      await (verb === 'start' ? start() : stop())
      lastError = null
    } catch (error) { lastError = publicError(error); throw fail(error.statusCode ?? 503, lastError) }
    finally { operation = null }
    return status(kind)
  }
  async function proxy(request, response, url) {
    if (!await isEnabled('opencode')) throw fail(409, 'runtime_not_installed')
    const path = url.pathname.slice(prefix.length)
    if (!path.startsWith('/api/') || path.includes('\\')) throw fail(400, 'invalid_opencode_path')
    const info = await registration()
    if (!info || !alive(info.pid)) throw fail(503, 'opencode_not_running')
    // Authenticated health verifies the registration's service identity before mutations.
    await health(info)
    prepareMCP()
    const target = new URL(info.url)
    target.pathname = path
    if (!target.pathname.startsWith('/api/')) throw fail(400, 'invalid_opencode_path')
    target.search = url.search
    await new Promise((done, reject) => {
      const headers = { authorization: info.authorization }
      for (const name of ['accept', 'content-type', 'last-event-id']) {
        if (request.headers[name]) headers[name] = request.headers[name]
      }
      const upstream = httpRequest(target, { method: request.method, headers }, (incoming) => {
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
      // A signed member's body was read to verify its signature.
      if (request.wovenBody) upstream.end(request.wovenBody)
      else request.pipe(upstream)
    })
  }
  async function handle(request, response, url) {
    if (url.pathname.startsWith(`${prefix}/api/`)) { await proxy(request, response, url); return true }
    const match = url.pathname.match(/^\/v1\/workspace-instances\/(opencode)(?:\/(start|stop))?$/)
    if (!match) return false
    const [, kind, verb] = match
    if ((!verb && request.method !== 'GET') || (verb && request.method !== 'POST')) throw fail(405, 'method_not_allowed')
    const value = verb ? await action(kind, verb) : await status(kind)
    response.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' })
    response.end(JSON.stringify(value))
    return true
  }
  // A running service doesn't block an upgrade: OpenCode's own `upgrade` swaps the
  // binary and the service is restarted onto it. Only a start or stop in flight does.
  async function hasActiveRuntime(id) {
    return id === 'opencode' && operation?.kind === 'opencode'
  }
  return { handle, hasActiveRuntime, status, action, restartIfRunning, registrationPath }
}

function publicError(error) {
  // Only our fixed identifiers are safe to expose. Never child stderr, auth, or URLs.
  return /^(opencode|workspace_instance|runtime_not_installed)[a-z_]*$/.test(error.message ?? '')
    ? error.message : 'workspace_instance_operation_failed'
}
