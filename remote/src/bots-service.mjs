import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { mkdir, open, readFile, rename } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { connect } from 'node:net'
import { hostname } from 'node:os'
import { dirname, join } from 'node:path'
import { createBotEngine, machineIdentity } from './bots-engine.mjs'
import { createBotConversationLibrary, createJournalBotLibraryAdapter, createLocalLibraryBotAdapter } from './bots-library.mjs'
import { createBotPreviews } from './bots-previews.mjs'
import { botsPackageRoot, createBotsRuntime } from './bots-runtime.mjs'

const GB = 1024 ** 3
const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
const digest = value => createHash('sha256').update(String(value)).digest()
// Client headers the runtime's WebSocket handshake may see. Credentials are
// never forwarded: the proxy authenticates to the runtime with its own token.
const forwardedSocketHeaders = ['sec-websocket-key', 'sec-websocket-version', 'sec-websocket-protocol', 'sec-websocket-extensions', 'user-agent']

/**
 * The default agent's Claude binary in this release, which the bots runtime runs
 * (`claude.executable`) instead of shipping a second copy: the glibc package, or
 * the musl one where that is what npm installed.
 */
export function defaultAgentClaude(serviceRoot, { platform = process.platform, arch = process.arch, exists = existsSync } = {}) {
  // A host release ships default-agent/ beside src/; a checkout has it beside remote/.
  for (const root of [join(serviceRoot, 'default-agent'), join(serviceRoot, '..', 'default-agent')]) {
    for (const name of [`claude-agent-sdk-${platform}-${arch}`, `claude-agent-sdk-${platform}-${arch}-musl`]) {
      const binary = join(root, 'node_modules/@anthropic-ai', name, 'claude')
      if (exists(binary)) return binary
    }
  }
  return null
}

async function readJSONFile(path, fallback) { try { return JSON.parse(await readFile(path, 'utf8')) } catch { return fallback } }
async function writePrivateJSON(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = path + '.' + randomBytes(4).toString('hex'), handle = await open(temporary, 'wx', 0o600)
  try { await handle.writeFile(JSON.stringify(value) + '\n') } finally { await handle.close() }
  await rename(temporary, path)
}

/**
 * The Woven server's side of bots on a Linux machine: it supervises the
 * runtime, serves the runtime host API on /v1/bots-host/* with its own bearer,
 * reports resources, and proxies /v1/bots/ws for Woven apps.
 */
export function createBotsService({ configuration, mcp, defaultAgent, serverPort, library, libraryHost, engine, runtime, previews,
  authorizeClient, machine, memberIdentity, release, engineWatchMilliseconds = 5000, webSocket = globalThis.WebSocket, log = message => process.stderr.write(message + '\n') }) {
  const stateDirectory = join(configuration.stateDirectory, 'bots')
  const settingsPath = join(stateDirectory, 'settings.json')
  const dataDirectory = configuration.botsData ?? join(configuration.dataRoot, 'bots')
  const hostToken = randomBytes(32).toString('base64url'), hostDigest = digest(hostToken)
  const packageRoot = botsPackageRoot(configuration.serviceRoot)
  const claudeExecutable = configuration.claudeExecutable ?? defaultAgentClaude(configuration.serviceRoot)
  engine ??= createBotEngine({ instance: configuration.botsInstance })
  // With this machine's library host, batches go into its library copy; the
  // outbox keeps them while it is down and is drained when it is ready.
  const outbox = join(dataDirectory, 'library-outbox')
  const libraryAdapter = libraryHost ? createLocalLibraryBotAdapter({ client: libraryHost.client, available: libraryHost.available, directory: outbox, log }) : createJournalBotLibraryAdapter(outbox)
  library ??= createBotConversationLibrary(libraryAdapter)
  previews ??= createBotPreviews({ statePath: join(stateDirectory, 'previews.json') })
  let identity = machine ?? null, started = false, engineWatch = null
  const settings = () => readJSONFile(settingsPath, { botMemoryBytes: 4 * GB })

  // The machine's member identity (the library host's) names its bots; the
  // saved device-id file is the fallback while there is no library host.
  async function machineInfo() {
    if (!identity) {
      const member = await Promise.resolve().then(() => memberIdentity?.()).catch(() => null)
      identity = member?.deviceID ? { deviceID: member.deviceID, name: member.name || hostname() } : await machineIdentity({ dataRoot: configuration.dataRoot, hostname: hostname() })
    }
    return identity
  }
  async function runtimeConfiguration() {
    return {
      dataDir: dataDirectory,
      engine: { socket: engine.layout.socket, kind: 'linux-dockerd' },
      // An untagged name: the runtime tags it with its image content hash.
      image: { tag: process.env.WOVENMATTER_BOTS_IMAGE || 'wovenmatter-bots' },
      limits: { botMemoryBytes: (await settings()).botMemoryBytes ?? null },
      host: { url: `http://127.0.0.1:${serverPort()}/`, token: hostToken },
      machine: await machineInfo(),
      ...(claudeExecutable ? { claude: { executable: claudeExecutable } } : {}),
    }
  }
  runtime ??= packageRoot ? createBotsRuntime({ packageRoot, configPath: join(stateDirectory, 'runtime.json'), configuration: runtimeConfiguration, log }) : null

  async function start() {
    if (started || !configuration.botsEnabled) return
    started = true
    await mkdir(dataDirectory, { recursive: true, mode: 0o700 })
    await previews.recover().catch(error => log('Bot preview recovery failed: ' + error.message))
    if (!runtime) { log('Bots are enabled, but this release has no bots runtime.'); return }
    // The runtime waits for the engine itself; a crash loop backs off to 30 s.
    // Install finishes the engine after this server starts, so watch for it.
    if ((await engine.status()).installed) { runtime.start(); return }
    log('Bots are enabled; waiting for the bot engine.')
    engineWatch = setInterval(async () => {
      if (!(await engine.status().catch(() => ({}))).installed) return
      clearInterval(engineWatch); engineWatch = null; runtime.start()
    }, engineWatchMilliseconds)
    engineWatch.unref?.()
  }
  async function close() {
    clearInterval(engineWatch)
    await runtime?.stop()
    await previews.close().catch(() => {})
  }

  function hostAuthorized(request) {
    const value = request.headers.authorization ?? ''
    return value.startsWith('Bearer ') && timingSafeEqual(digest(value.slice(7)), hostDigest)
  }

  // Runtime host API: only the supervised runtime holds this bearer.
  async function handleHost(request, response, url, { readJSON, json }) {
    if (!url.pathname.startsWith('/v1/bots-host/')) return false
    if (!hostAuthorized(request)) { json(response, 401, { error: 'unauthorized' }); return true }
    if (!configuration.botsEnabled) { json(response, 409, { error: 'bots_disabled' }); return true }
    const path = url.pathname, method = request.method
    if (path === '/v1/bots-host/mcp-keys' && method === 'POST') {
      const body = await readJSON(request, 16384)
      if (!mcp) throw fail(503, 'woven_mcp_unavailable')
      let key
      try { key = mcp.issueBotKey({ botID: body.botID, botName: body.botName, deviceID: (await machineInfo()).deviceID }) }
      catch (error) { if (error.code !== 'revoked') throw error; json(response, 403, { error: 'revoked', message: error.message }); return true }
      json(response, 201, { endpoint: key.endpointURL, token: key.bearerToken, principal: key.principal }); return true
    }
    const revoke = path.match(/^\/v1\/bots-host\/mcp-keys\/([0-9a-fA-F-]{36})$/)
    // The runtime deleted the bot; a user's revoke is the client route below. Its
    // library conversations are marked deleted too, as on a Mac, so the transcript
    // stops syncing as a live conversation.
    if (revoke && method === 'DELETE') {
      const result = mcp.revokeBotKey(revoke[1])
      await library.deleteBot(revoke[1])
      json(response, 200, result); return true
    }
    if (path === '/v1/bots-host/previews' && method === 'POST') {
      const body = await readJSON(request, 16384)
      json(response, 201, await previews.publish({ botID: body.botID, port: body.port, containerPort: body.containerPort })); return true
    }
    if (path === '/v1/bots-host/previews' && method === 'GET') { json(response, 200, { previews: previews.list() }); return true }
    const preview = path.match(/^\/v1\/bots-host\/previews\/([0-9a-fA-F-]{36})\/(\d{1,5})$/)
    if (preview && method === 'DELETE') { json(response, 200, await previews.unpublish({ botID: preview[1], port: Number(preview[2]) })); return true }
    if (path === '/v1/bots-host/inference-credentials' && method === 'POST') {
      const body = await readJSON(request, 16384)
      json(response, 200, await defaultAgent.botCredentials({ provider: body.provider })); return true
    }
    const entries = path.match(/^\/v1\/bots-host\/conversations\/([0-9a-fA-F-]{36})\/entries$/)
    if (entries && method === 'POST') {
      const body = await readJSON(request, 8 * 1024 * 1024 + 65536)
      json(response, 200, await library.writeBotEntries(entries[1], body)); return true
    }
    json(response, 404, { error: 'not_found' }); return true
  }

  function releaseVersions() {
    const value = release?.() ?? { version: configuration.releaseVersion ?? null, fingerprint: configuration.serviceFingerprint ?? null, librarySchema: null }
    return { app: value.version ?? null, fingerprint: value.fingerprint ?? null, librarySchema: value.librarySchema ?? null }
  }
  const runtimeVersion = packageRoot ? readJSONFile(join(packageRoot, 'package.json'), {}).then(value => typeof value.version === 'string' ? value.version : null) : Promise.resolve(null)
  const size = value => Number.isSafeInteger(value) && value >= 0 ? value : null

  // The shape every Woven server that hosts bots answers (docs/architecture/
  // WOVEN_EVERYWHERE.md, "Woven server routes for bots"), plus this server's
  // own engine, runtime and settings detail.
  async function status() {
    const [engineStatus, saved, identity] = await Promise.all([engine.status(), settings(), machineInfo()])
    const report = engineStatus.installed ? await engine.resources({ botMemoryBytes: saved.botMemoryBytes ?? null }).catch(() => null) : null
    const running = runtime?.status() ?? null
    let state = 'off', message
    if (!configuration.botsEnabled) state = 'off'
    else if (!runtime) { state = 'failed'; message = 'This release does not include the bots runtime. Update this host.' }
    else if (!engineStatus.installed) { state = 'starting'; message = 'Waiting for the bot engine.' }
    else if (running?.running && engineStatus.ready) state = 'ready'
    else { state = 'starting'; if (!engineStatus.ready) message = 'Waiting for the bot engine to answer.' }
    const memoryBytes = size(report?.memory?.totalBytes), diskTotalBytes = size(report?.disk?.totalBytes), diskFreeBytes = size(report?.disk?.freeBytes)
    return {
      machine: { ...identity, kind: 'linux' }, enabled: !!configuration.botsEnabled, state, ...(message ? { message } : {}),
      // `app` is the Woven Matter version that shipped this host release; apps compare the
      // fingerprint (exact) and the library schema to tell an out-of-date host.
      versions: { ...releaseVersions(), runtime: await runtimeVersion, protocol: 1 },
      resources: engineStatus.installed ? { poolBytes: engineStatus.poolBytes ?? null, perBotBytes: saved.botMemoryBytes ?? null, diskBytes: engineStatus.diskBytes ?? null } : null,
      capacity: memoryBytes !== null && diskTotalBytes !== null && diskFreeBytes !== null
        ? { memoryBytes, diskTotalBytes, diskFreeBytes, diskUsedByBotsBytes: size(report.disk.usedBytes) } : null,
      // Pause-all is the bots' Woven MCP switch on this server.
      paused: mcp ? mcp.settings().botMCP?.isEnabled === false : false,
      workspaceEnabled: configuration.workspaceEnabled, runtimeAvailable: !!runtime,
      engine: engineStatus, runtime: running, settings: saved }
  }

  // App-facing routes. Reads accept device grants; changes need administration.
  async function handleClient(request, response, url, { readJSON, json, administrator, device }) {
    if (!url.pathname.startsWith('/v1/bots/')) return false
    const path = url.pathname, method = request.method
    if (!administrator && !device) { json(response, 401, { error: 'unauthorized' }); return true }
    if (path === '/v1/bots/status' && method === 'GET') { json(response, 200, await status()); return true }
    if (path === '/v1/bots/resources' && method === 'GET') { json(response, 200, await engine.resources(await settings())); return true }
    if (!administrator) { json(response, 403, { error: 'administrator_required' }); return true }
    if (path === '/v1/bots/resources' && method === 'POST') {
      // `{resources: {poolBytes, perBotBytes, diskBytes}}`: null is no cap; a
      // missing field stays as it is.
      const requested = (await readJSON(request, 4096))?.resources
      if (!requested || typeof requested !== 'object' || Array.isArray(requested)) throw fail(400, 'Send {resources: {poolBytes, perBotBytes, diskBytes}}.')
      const body = { poolBytes: requested.poolBytes, diskBytes: requested.diskBytes, botMemoryBytes: requested.perBotBytes }
      const current = await engine.status(), saved = await settings()
      const pool = body.poolBytes === undefined ? current.poolBytes ?? null : body.poolBytes
      const disk = body.diskBytes === undefined ? current.diskBytes ?? null : body.diskBytes
      // Lowering the pool below the per-bot limit lowers that limit with it.
      const botMemoryBytes = body.botMemoryBytes !== undefined ? body.botMemoryBytes
        : pool !== null && (saved.botMemoryBytes === null || saved.botMemoryBytes > pool) ? pool : saved.botMemoryBytes
      if (pool !== null && (!Number.isSafeInteger(pool) || pool < GB)) throw fail(400, 'The RAM pool must be at least 1 GB, or null for no cap.')
      if (botMemoryBytes !== null && (!Number.isSafeInteger(botMemoryBytes) || botMemoryBytes < 256 * 1024 ** 2 || (pool !== null && botMemoryBytes > pool))) throw fail(400, 'Per-bot RAM must fit in the pool, or be null for no cap.')
      if (pool !== current.poolBytes || disk !== current.diskBytes) await engine.configure({ poolBytes: pool, diskBytes: disk })
      if (botMemoryBytes !== saved.botMemoryBytes) {
        await writePrivateJSON(settingsPath, { ...saved, botMemoryBytes })
        // The runtime reads limits from its config at start; bots keep running.
        if (runtime && configuration.botsEnabled) await runtime.restart()
      }
      json(response, 200, await status()); return true
    }
    if (path === '/v1/bots/mcp' && method === 'GET') { json(response, 200, { settings: mcp.settings().botMCP, keys: mcp.botKeys(), revoked: mcp.revokedBots?.() ?? [] }); return true }
    if (path === '/v1/bots/mcp' && method === 'POST') {
      const body = await readJSON(request, 4096)
      json(response, 200, mcp.configureBots({ ...(typeof body.isEnabled === 'boolean' ? { isEnabled: body.isEnabled } : {}), ...(body.groups ? { groups: body.groups } : {}) })); return true
    }
    // The user's revoke sticks until reinstated, as on a Mac.
    const key = path.match(/^\/v1\/bots\/mcp\/keys\/([0-9a-fA-F-]{36})$/)
    if (key && method === 'DELETE') { json(response, 200, mcp.revokeBotKey(key[1], { sticky: true })); return true }
    const reinstate = path.match(/^\/v1\/bots\/mcp\/keys\/([0-9a-fA-F-]{36})\/reinstate$/)
    if (reinstate && method === 'POST') { json(response, 200, mcp.reinstateBot(reinstate[1])); return true }
    json(response, 404, { error: 'not_found' }); return true
  }

  // Woven apps reach this machine's bots here. `authorizeClient` (possibly
  // async) accepts a signed member request or, during transition, a bearer.
  function upgrade(request, socket, head) {
    const url = new URL(request.url, 'http://localhost')
    if (url.pathname !== '/v1/bots/ws') return false
    const refuse = (status, text) => { socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`) }
    if (request.headers.origin) { refuse(403, 'Forbidden'); return true }
    socket.pause()
    Promise.resolve().then(() => authorizeClient(request)).catch(() => false).then(allowed => {
      if (!allowed) refuse(401, 'Unauthorized'); else proxySocket(request, socket, head, url, refuse)
    })
    return true
  }
  function proxySocket(request, socket, head, url, refuse) {
    const target = configuration.botsEnabled ? runtime?.endpoint() : null
    if (!target) { refuse(503, 'Service Unavailable'); return true }
    if ((request.headers.upgrade ?? '').toLowerCase() !== 'websocket') { refuse(400, 'Bad Request'); return true }
    const upstream = connect(target.port, target.host, () => {
      const lines = [`GET /ws${url.search} HTTP/1.1`, `Host: ${target.host}:${target.port}`, 'Upgrade: websocket', 'Connection: Upgrade', `Authorization: Bearer ${target.token}`]
      for (const name of forwardedSocketHeaders) if (typeof request.headers[name] === 'string') lines.push(`${name}: ${request.headers[name].replace(/[\r\n]/g, '')}`)
      upstream.write(lines.join('\r\n') + '\r\n\r\n')
      if (head?.length) upstream.write(head)
      upstream.pipe(socket); socket.pipe(upstream); socket.resume()
    })
    const close = () => { upstream.destroy(); socket.destroy() }
    upstream.on('error', () => { if (!socket.writableEnded && upstream.bytesRead === 0) refuse(502, 'Bad Gateway'); close() })
    // HTTP server sockets allow half-open connections; end either side fully.
    for (const event of ['error', 'end', 'close']) socket.on(event, close)
    upstream.on('end', close); upstream.on('close', close)
  }

  // A due timer reaches its bot as `message.send` with the occurrence's delivery
  // ID, which the runtime accepts once (docs: "Timers on a library host").
  function deliver({ botID, text, deliveryID }, { timeout = 30_000 } = {}) {
    const target = configuration.botsEnabled ? runtime?.endpoint() : null
    if (!target) return Promise.reject(fail(503, 'The bots runtime is not running.'))
    if (!uuid(botID) || typeof text !== 'string' || !text || typeof deliveryID !== 'string') return Promise.reject(fail(400, 'Invalid bot delivery.'))
    return new Promise((resolve, reject) => {
      const id = 'woven-delivery-' + deliveryID
      let settled = false, socket
      const done = (error, value) => {
        if (settled) return
        settled = true; clearTimeout(timer)
        try { socket?.close() } catch {}
        if (error) reject(error); else resolve(value)
      }
      const timer = setTimeout(() => done(fail(504, 'The bots runtime did not answer in time.')), timeout); timer.unref?.()
      try { socket = new webSocket(`ws://${target.host}:${target.port}/ws`, { headers: { authorization: 'Bearer ' + target.token } }) }
      catch (error) { done(fail(503, 'The bots runtime is unreachable: ' + error.message)); return }
      socket.onopen = () => socket.send(JSON.stringify({ id, type: 'message.send', botId: botID.toLowerCase(), text: text.slice(0, 100_000), deliveryId: deliveryID }))
      socket.onmessage = event => {
        let message; try { message = JSON.parse(String(event.data)) } catch { return }
        if (message?.id !== id) return
        if (message.type === 'result') done(null, message.data)
        else if (message.type === 'error') done(fail(502, typeof message.message === 'string' ? message.message.slice(0, 512) : 'The bots runtime refused the message.'))
      }
      socket.onerror = () => done(fail(503, 'The bots runtime is unreachable.'))
      socket.onclose = () => done(fail(503, 'The bots runtime closed the connection.'))
    })
  }

  return { start, close, status, handleHost, deliver, handleClient, upgrade, runtimeConfiguration, hostToken: () => hostToken,
    drainLibrary: () => libraryAdapter.drain?.() ?? Promise.resolve(0) }
}
