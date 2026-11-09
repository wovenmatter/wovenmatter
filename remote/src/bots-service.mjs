import { createHash, randomBytes, timingSafeEqual } from 'node:crypto'
import { mkdir, open, readFile, rename } from 'node:fs/promises'
import { connect } from 'node:net'
import { hostname } from 'node:os'
import { dirname, join } from 'node:path'
import { createBotEngine, machineIdentity } from './bots-engine.mjs'
import { createBotConversationLibrary, createJournalBotLibraryAdapter } from './bots-library.mjs'
import { createBotPreviews } from './bots-previews.mjs'
import { botsPackageRoot, createBotsRuntime } from './bots-runtime.mjs'

const GB = 1024 ** 3
const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
const digest = value => createHash('sha256').update(String(value)).digest()
// Client headers the runtime's WebSocket handshake may see. Credentials are
// never forwarded: the proxy authenticates to the runtime with its own token.
const forwardedSocketHeaders = ['sec-websocket-key', 'sec-websocket-version', 'sec-websocket-protocol', 'sec-websocket-extensions', 'user-agent']

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
export function createBotsService({ configuration, mcp, defaultAgent, serverPort, library, engine, runtime, previews,
  authorizeClient, machine, engineWatchMilliseconds = 5000, log = message => process.stderr.write(message + '\n') }) {
  const stateDirectory = join(configuration.stateDirectory, 'bots')
  const settingsPath = join(stateDirectory, 'settings.json')
  const dataDirectory = configuration.botsData ?? join(configuration.dataRoot, 'bots')
  const hostToken = randomBytes(32).toString('base64url'), hostDigest = digest(hostToken)
  const packageRoot = botsPackageRoot(configuration.serviceRoot)
  engine ??= createBotEngine({ instance: configuration.botsInstance })
  library ??= createBotConversationLibrary(createJournalBotLibraryAdapter(join(dataDirectory, 'library-outbox')))
  previews ??= createBotPreviews({ statePath: join(stateDirectory, 'previews.json') })
  let identity = machine ?? null, started = false, engineWatch = null
  const settings = () => readJSONFile(settingsPath, { botMemoryBytes: 4 * GB })

  async function machineInfo() {
    identity ??= await machineIdentity({ dataRoot: configuration.dataRoot, hostname: hostname() })
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
      const key = mcp.issueBotKey({ botID: body.botID, botName: body.botName, deviceID: (await machineInfo()).deviceID })
      json(response, 201, { endpoint: key.endpointURL, token: key.bearerToken, principal: key.principal }); return true
    }
    const revoke = path.match(/^\/v1\/bots-host\/mcp-keys\/([0-9a-fA-F-]{36})$/)
    if (revoke && method === 'DELETE') { json(response, 200, mcp.revokeBotKey(revoke[1])); return true }
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

  async function status() {
    return { enabled: configuration.botsEnabled, workspaceEnabled: configuration.workspaceEnabled, runtimeAvailable: !!runtime,
      engine: await engine.status(), runtime: runtime?.status() ?? null, machine: await machineInfo(), settings: await settings() }
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
      const body = await readJSON(request, 4096), current = await engine.status(), saved = await settings()
      const pool = body.poolBytes === undefined ? current.poolBytes ?? null : body.poolBytes
      const disk = body.diskBytes === undefined ? current.diskBytes ?? null : body.diskBytes
      // Lowering the pool below the per-bot limit lowers that limit with it.
      const botMemoryBytes = body.botMemoryBytes !== undefined ? body.botMemoryBytes
        : pool !== null && (saved.botMemoryBytes === null || saved.botMemoryBytes > pool) ? pool : saved.botMemoryBytes
      if (pool !== null && (!Number.isSafeInteger(pool) || pool < GB)) throw fail(400, 'The RAM pool must be at least 1 GB, or null for no cap.')
      if (botMemoryBytes !== null && (!Number.isSafeInteger(botMemoryBytes) || botMemoryBytes < 256 * 1024 ** 2 || (pool !== null && botMemoryBytes > pool))) throw fail(400, 'Per-bot RAM must fit in the pool, or be null for no cap.')
      const result = (pool !== current.poolBytes || disk !== current.diskBytes) ? await engine.configure({ poolBytes: pool, diskBytes: disk }) : await engine.resources({ botMemoryBytes })
      if (botMemoryBytes !== saved.botMemoryBytes) {
        await writePrivateJSON(settingsPath, { ...saved, botMemoryBytes })
        // The runtime reads limits from its config at start; bots keep running.
        if (runtime && configuration.botsEnabled) await runtime.restart()
      }
      json(response, 200, { ...result, memory: { ...result.memory, botBytes: botMemoryBytes } }); return true
    }
    if (path === '/v1/bots/mcp' && method === 'GET') { json(response, 200, { settings: mcp.settings().botMCP, keys: mcp.botKeys() }); return true }
    if (path === '/v1/bots/mcp' && method === 'POST') {
      const body = await readJSON(request, 4096)
      json(response, 200, mcp.configureBots({ ...(typeof body.isEnabled === 'boolean' ? { isEnabled: body.isEnabled } : {}), ...(body.groups ? { groups: body.groups } : {}) })); return true
    }
    const key = path.match(/^\/v1\/bots\/mcp\/keys\/([0-9a-fA-F-]{36})$/)
    if (key && method === 'DELETE') { json(response, 200, mcp.revokeBotKey(key[1])); return true }
    json(response, 404, { error: 'not_found' }); return true
  }

  // Woven apps reach this machine's bots here. `authorizeClient` is the single
  // place member authentication will replace the device grant check.
  function upgrade(request, socket, head) {
    const url = new URL(request.url, 'http://localhost')
    if (url.pathname !== '/v1/bots/ws') return false
    const refuse = (status, text) => { socket.end(`HTTP/1.1 ${status} ${text}\r\nConnection: close\r\nContent-Length: 0\r\n\r\n`) }
    if (request.headers.origin) { refuse(403, 'Forbidden'); return true }
    if (!authorizeClient(request)) { refuse(401, 'Unauthorized'); return true }
    const target = configuration.botsEnabled ? runtime?.endpoint() : null
    if (!target) { refuse(503, 'Service Unavailable'); return true }
    if ((request.headers.upgrade ?? '').toLowerCase() !== 'websocket') { refuse(400, 'Bad Request'); return true }
    const upstream = connect(target.port, target.host, () => {
      const lines = [`GET /ws${url.search} HTTP/1.1`, `Host: ${target.host}:${target.port}`, 'Upgrade: websocket', 'Connection: Upgrade', `Authorization: Bearer ${target.token}`]
      for (const name of forwardedSocketHeaders) if (typeof request.headers[name] === 'string') lines.push(`${name}: ${request.headers[name].replace(/[\r\n]/g, '')}`)
      upstream.write(lines.join('\r\n') + '\r\n\r\n')
      if (head?.length) upstream.write(head)
      upstream.pipe(socket); socket.pipe(upstream)
    })
    const close = () => { upstream.destroy(); socket.destroy() }
    upstream.on('error', () => { if (!socket.writableEnded && upstream.bytesRead === 0) refuse(502, 'Bad Gateway'); close() })
    // HTTP server sockets allow half-open connections; end either side fully.
    for (const event of ['error', 'end', 'close']) socket.on(event, close)
    upstream.on('end', close); upstream.on('close', close)
    return true
  }

  return { start, close, status, handleHost, handleClient, upgrade, hostToken: () => hostToken }
}
