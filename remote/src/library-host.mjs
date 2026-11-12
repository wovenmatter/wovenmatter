import { spawn } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { existsSync } from 'node:fs'
import { lstat, mkdir, open, readFile, rename } from 'node:fs/promises'
import { request as httpRequest } from 'node:http'
import { createServer as createNetServer } from 'node:net'
import { dirname, join } from 'node:path'
import { createInterface } from 'node:readline'
import { freeLoopbackPort } from './bots-runtime.mjs'

const fail = (statusCode, message, code) => Object.assign(new Error(message), { statusCode, ...(code ? { code } : {}) })
const architectures = { x64: 'x86_64', arm64: 'aarch64' }

/** `<release>/host/library/linux-<arch>/wovenmatter-library`, as host bundles ship it. */
export function libraryBinaryPath(serviceRoot, arch = process.arch) {
  const name = architectures[arch]
  return name ? join(serviceRoot, 'host/library', 'linux-' + name, 'wovenmatter-library') : null
}

/** Where everything lives for one data root (docs: "Library host", data layout). */
export function libraryHostLayout(dataRoot) {
  const run = join(dataRoot, 'run')
  return { dataRoot, run, socket: join(run, 'library.sock'), tokenFile: join(run, 'library-api.token'), readyFile: join(run, 'library.json') }
}

// The local API bearer: 0600, owned by this user, 43–256 base64url characters.
// The server writes it before the first start; the host reuses it.
export async function ensureLibraryToken(path) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  try {
    const handle = await open(path, 'wx', 0o600)
    try { await handle.writeFile(randomBytes(32).toString('base64url') + '\n') } finally { await handle.close() }
  } catch (error) { if (error.code !== 'EEXIST') throw error }
  const info = await lstat(path)
  if (!info.isFile() || (process.getuid && info.uid !== process.getuid()) || (info.mode & 0o077)) throw fail(500, 'The library API token file is unsafe.')
  const value = (await readFile(path, 'utf8')).trim()
  if (!/^[A-Za-z0-9_-]{43,256}$/.test(value)) throw fail(500, 'The library API token file is invalid.')
  return value
}

/**
 * HTTP/1.1 over the library host's Unix socket, one request per connection,
 * always with the bearer. Replies are bounded; JSON replies are parsed.
 */
export function createLibraryClient({ socket, token, timeoutMilliseconds = 120_000, maximumBytes = 8 * 1024 * 1024 }) {
  function request(method, path, { body, headers = {}, signal, timeout = timeoutMilliseconds } = {}) {
    const payload = body === undefined ? null : Buffer.isBuffer(body) ? body : Buffer.from(JSON.stringify(body))
    const bearer = typeof token === 'function' ? token() : token
    if (!bearer) return Promise.reject(fail(503, 'The local library is not running.', 'library_unavailable'))
    return new Promise((resolve, reject) => {
      const outgoing = httpRequest({ socketPath: typeof socket === 'function' ? socket() : socket, path, method, agent: false, timeout, signal,
        headers: { host: 'localhost', connection: 'close', authorization: 'Bearer ' + bearer, accept: 'application/json',
          ...(payload ? { 'content-type': 'application/json', 'content-length': payload.length } : {}), ...headers } }, response => {
        const chunks = []; let size = 0
        response.on('data', chunk => { size += chunk.length; if (size > maximumBytes) outgoing.destroy(fail(413, 'The library reply is too large.')); else chunks.push(chunk) })
        response.on('end', () => {
          const data = Buffer.concat(chunks), type = response.headers['content-type'] ?? ''
          let value = data
          if (type.includes('json') && data.length) { try { value = JSON.parse(data.toString('utf8')) } catch { return reject(fail(502, 'The library returned invalid JSON.')) } }
          resolve({ status: response.statusCode, headers: response.headers, body: value })
        })
        response.on('error', reject)
      })
      outgoing.on('timeout', () => outgoing.destroy(fail(504, 'The local library did not answer in time.', 'library_timeout')))
      outgoing.on('error', error => reject(error.statusCode ? error : signal?.aborted ? fail(499, 'The request was cancelled.') : fail(503, 'The local library is unavailable.', 'library_unavailable')))
      outgoing.end(payload ?? undefined)
    })
  }
  async function json(method, path, options) {
    const reply = await request(method, path, options)
    if (reply.status < 200 || reply.status >= 300) {
      const message = typeof reply.body?.message === 'string' ? reply.body.message.slice(0, 512) : 'The local library refused this request.'
      throw fail(reply.status === 401 ? 503 : reply.status, message, reply.body?.code ?? 'library_http_' + reply.status)
    }
    return reply.body
  }
  return {
    request, json,
    health: () => json('GET', '/v1/health', { timeout: 5000 }),
    identity: () => json('GET', '/v1/identity', { timeout: 5000 }),
    members: () => json('GET', '/v1/members', { timeout: 10_000 }),
    // The adding Mac's signed records, forwarded byte for byte.
    adoptMembers: body => json('POST', '/v1/members/adopt', { body: Buffer.from(body), timeout: 30_000 }),
    updateSelf: body => json('POST', '/v1/members/self', { body, timeout: 10_000 }),
    // Signs one outgoing request with this machine's member key, which stays in the host.
    // `audience` is the destination member's device ID (it is signed too).
    sign: ({ method, target, bodySHA256, audience }) => json('POST', '/v1/members/sign', { body: { method, target, bodySHA256, audience }, timeout: 5000 }),
    workspaces: () => json('GET', '/v1/workspaces', { timeout: 10_000 }),
    syncStatus: () => json('GET', '/v1/sync/status', { timeout: 10_000 }),
    registerCaller: body => json('POST', '/v1/callers', { body, timeout: 30_000 }),
    mcp: (message, headers, options = {}) => request('POST', '/v1/mcp', { body: message, headers, ...options }),
    publisher: (path, body, headers = {}, options = {}) => json('POST', '/v1/publisher/' + path, { body, headers, timeout: 30_000, ...options }),
    timersDue: () => json('POST', '/v1/timers/due', { body: {}, timeout: 30_000 }),
    settleTimer: body => json('POST', '/v1/timers/settle', { body, timeout: 15_000 }),
    botEntries: (botID, batch) => json('POST', '/v1/bots/' + encodeURIComponent(botID) + '/entries', { body: batch, timeout: 30_000 }),
    // Marks a deleted bot's conversations deleted in this library copy (entries stay).
    deleteBotConversations: botID => json('DELETE', '/v1/bots/' + encodeURIComponent(botID) + '/conversations', { timeout: 30_000 }),
  }
}

async function readReadyFile(path) {
  try { const value = JSON.parse(await readFile(path, 'utf8')); return value?.event === 'ready' ? value : null } catch { return null }
}
async function writePrivateJSON(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = path + '.' + randomBytes(4).toString('hex'), handle = await open(temporary, 'wx', 0o600)
  try { await handle.writeFile(JSON.stringify(value) + '\n') } finally { await handle.close() }
  await rename(temporary, path)
}

/**
 * Supervises `wovenmatter-library` (docs: "Library host"). It creates the
 * token, keeps one loopback port across restarts (so the Tailscale Serve route
 * stays valid), waits for the ready line or `run/library.json`, restarts a
 * crash with backoff up to 30 s and stops it on SIGTERM. `onReady(ready)` runs
 * after every successful start.
 */
export function createLibraryHostSupervisor({ binary, dataRoot, harnessCatalog, statePath, spawnImpl = spawn, portImpl = freeLoopbackPort,
  environment = process.env, log = () => {}, onReady = () => {}, minimumBackoff = 1000, maximumBackoff = 30_000, healthyAfter = 60_000, readyTimeout = 60_000 }) {
  const layout = libraryHostLayout(dataRoot)
  let child = null, stopping = true, timer = null, backoff = minimumBackoff, startedAt = 0, restarts = 0, lastExit = null, lastError = null
  let ready = null, token = null, generation = 0, waiters = []
  const client = createLibraryClient({ socket: () => ready?.socket ?? layout.socket, token: () => (ready ? token : null) })

  async function chosenPort() {
    let saved = null
    try { saved = JSON.parse(await readFile(statePath, 'utf8')).port } catch {}
    // Keep the recorded port when it is still free; a new one updates Serve.
    if (Number.isSafeInteger(saved) && saved > 1024 && saved < 65536 && await portFree(saved)) return saved
    const port = await portImpl()
    await writePrivateJSON(statePath, { port })
    return port
  }

  function settleWaiters() { const list = waiters; waiters = []; for (const resolve of list) resolve(ready) }

  function schedule() {
    if (stopping) return
    timer = setTimeout(launch, backoff); timer.unref?.()
    backoff = Math.min(maximumBackoff, backoff * 2)
  }

  async function launch() {
    timer = null
    if (stopping) return
    const current = ++generation
    try {
      if (!binary || !existsSync(binary)) throw fail(503, 'This release has no library host for this machine.')
      token = await ensureLibraryToken(layout.tokenFile)
      const port = await chosenPort()
      if (stopping || current !== generation) return
      const args = ['--data-root', dataRoot, '--port', String(port), '--socket', layout.socket, '--token-file', layout.tokenFile, ...(harnessCatalog ? ['--harness-catalog', harnessCatalog] : [])]
      const env = { ...environment }
      for (const name of Object.keys(env)) if (name.startsWith('WOVENMATTER_') && /TOKEN|SECRET/.test(name)) delete env[name]
      const process_ = spawnImpl(binary, args, { cwd: dataRoot, env, stdio: ['ignore', 'pipe', 'pipe'] })
      child = process_; startedAt = Date.now()
      let announced = false
      const announce = async value => {
        if (announced || current !== generation || !value || value.event !== 'ready') return
        announced = true; ready = { ...value, startedAt: new Date(startedAt).toISOString() }; lastError = null
        settleWaiters()
        try { await onReady(ready) } catch (error) { log('Library host ready hook failed: ' + error.message) }
      }
      createInterface({ input: process_.stdout }).on('line', line => {
        let value; try { value = JSON.parse(line) } catch { return }
        void announce(value)
      })
      process_.stderr?.on('data', data => log('wovenmatter-library: ' + String(data).trim().slice(0, 2000)))
      // The ready file covers a ready line lost to a stdout race.
      const deadline = Date.now() + readyTimeout
      const poll = setInterval(async () => {
        if (announced || current !== generation || child !== process_) return clearInterval(poll)
        const value = await readReadyFile(layout.readyFile)
        if (value && value.pid === process_.pid) { clearInterval(poll); void announce(value); return }
        if (Date.now() > deadline) { clearInterval(poll); lastError = 'The library host did not become ready.'; log(lastError); process_.kill('SIGTERM') }
      }, 250)
      poll.unref?.()
      process_.once('error', error => { lastError = error.message })
      process_.once('exit', (code, signal) => {
        clearInterval(poll)
        lastExit = { code, signal, at: new Date().toISOString() }
        if (child === process_) { child = null; ready = null }
        if (stopping || current !== generation) return
        if (Date.now() - startedAt >= healthyAfter) backoff = minimumBackoff
        restarts++
        log(`Library host exited (${signal ?? code}); restarting in ${backoff} ms`)
        schedule()
      })
    } catch (error) {
      lastError = error.message
      log('Library host could not start: ' + error.message)
      schedule()
    }
  }

  function start() { if (!stopping) return; stopping = false; if (!child && !timer) void launch() }

  async function stop({ timeout = 10_000 } = {}) {
    stopping = true; generation++
    clearTimeout(timer); timer = null
    const running = child
    ready = null; settleWaiters()
    if (!running) return
    await new Promise(resolve => {
      const kill = setTimeout(() => running.kill('SIGKILL'), timeout); kill.unref?.()
      running.once('exit', () => { clearTimeout(kill); resolve() })
      running.kill('SIGTERM')
    })
    if (child === running) child = null
  }

  /** Resolves with the ready record, or null when stopped or not ready in time. */
  function whenReady(timeout = readyTimeout) {
    if (ready) return Promise.resolve(ready)
    if (stopping) return Promise.resolve(null)
    return new Promise(resolve => {
      const timer_ = setTimeout(() => { waiters = waiters.filter(item => item !== done); resolve(null) }, timeout); timer_.unref?.()
      const done = value => { clearTimeout(timer_); resolve(value) }
      waiters.push(done)
    })
  }

  // The server is shutting down: a running host keeps serving until stop(), but
  // an exit is final. systemd signals the host with the server, so its exit
  // must not be restarted while the server is still closing other services.
  function quiesce() { stopping = true; generation++; clearTimeout(timer); timer = null }

  // Synchronous last resort for process exit: the host never outlives this server.
  function terminate() { stopping = true; generation++; clearTimeout(timer); child?.kill('SIGTERM') }

  return {
    layout, client, start, stop, quiesce, terminate, whenReady,
    available: () => !!ready,
    endpoint: () => ready ? { port: ready.port, socket: ready.socket, pid: ready.pid } : null,
    status: () => ({ running: !!child, ready: !!ready, pid: child?.pid ?? null, port: ready?.port ?? null, version: ready?.version ?? null,
      // The paired-library schema hash, once the library host includes it in its ready line.
      schema: typeof ready?.schema === 'string' ? ready.schema : null,
      restarts, lastExit, lastError, startedAt: ready?.startedAt ?? null, binary }),
  }
}

function portFree(port) {
  return new Promise(resolve => {
    const probe = createNetServer()
    probe.once('error', () => resolve(false))
    probe.listen(port, '127.0.0.1', () => probe.close(() => resolve(true)))
  })
}
