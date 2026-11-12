import { execFile } from 'node:child_process'
import { randomBytes } from 'node:crypto'
import { mkdir, open, readFile, rename } from 'node:fs/promises'
import { dirname } from 'node:path'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const uuid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)
const validPort = value => Number.isSafeInteger(value) && value >= 1 && value <= 65535

export function tailscaleCommand(args, { binary = 'tailscale', timeout = 20000 } = {}) {
  return new Promise((resolve, reject) => execFile(binary, args, { timeout, maxBuffer: 4 * 1024 * 1024 }, (error, stdout) => {
    if (error) reject(fail(502, 'tailscale_command_failed')); else resolve(stdout)
  }))
}

/**
 * Previews are tailnet-only Tailscale Serve routes on this host's name, one
 * HTTPS port per preview. Each points at the runtime's loopback activity proxy
 * for that container port (the runtime counts activity for idle). Funnel is
 * never used. Only routes recorded in `statePath` are ever changed or removed.
 */
export function createBotPreviews({ statePath, tailscale = tailscaleCommand, httpsPorts = [17000, 17999] } = {}) {
  const previews = new Map()
  let queue = Promise.resolve()
  const serialized = operation => { const next = queue.then(operation); queue = next.catch(() => {}); return next }

  async function serveStatus() {
    const value = JSON.parse(await tailscale(['serve', 'status', '--json']) || 'null')
    return value && typeof value === 'object' ? value : {}
  }
  async function dnsName() {
    const state = JSON.parse(await tailscale(['status', '--json']))
    const name = String(state?.Self?.DNSName ?? '').replace(/\.$/, '').toLowerCase()
    if (state?.BackendState !== 'Running' || !/^[a-z0-9.-]+\.ts\.net$/.test(name)) throw fail(503, 'tailscale_not_running')
    return name
  }
  const target = record => 'http://127.0.0.1:' + record.port
  const owns = (config, record) => {
    const endpoint = `${record.dns}:${record.httpsPort}`
    return config.TCP?.[String(record.httpsPort)]?.HTTPS === true && config.Web?.[endpoint]?.Handlers?.['/']?.Proxy === target(record) && !config.AllowFunnel?.[endpoint]
  }
  async function save() {
    await mkdir(dirname(statePath), { recursive: true, mode: 0o700 })
    const temporary = statePath + '.' + randomBytes(4).toString('hex')
    const handle = await open(temporary, 'wx', 0o600)
    try { await handle.writeFile(JSON.stringify([...previews.values()])) } finally { await handle.close() }
    await rename(temporary, statePath)
  }
  async function removeRoute(record) {
    // Leave a route alone if anything else changed it since Woven made it.
    if (!owns(await serveStatus(), record)) return false
    await tailscale(['serve', '--https=' + record.httpsPort, 'off'])
    return true
  }

  // Routes from a previous server process may point at a runtime proxy that no
  // longer exists; the runtime publishes again after it restarts.
  async function recover() {
    let saved = []
    try { saved = JSON.parse(await readFile(statePath, 'utf8')) } catch {}
    for (const record of Array.isArray(saved) ? saved : []) await removeRoute(record).catch(() => {})
    await save().catch(() => {})
  }

  function publish({ botID, port, containerPort }) {
    return serialized(async () => {
      if (!uuid(botID) || !validPort(port) || port < 1024 || (containerPort != null && !validPort(containerPort))) throw fail(400, 'A bot UUID and the runtime’s loopback proxy port are required.')
      const key = botID.toLowerCase() + ':' + port
      const existing = previews.get(key)
      if (existing) return view(existing)
      const dns = await dnsName(), config = await serveStatus()
      const used = new Set([...Object.keys(config.TCP ?? {}).map(Number), ...[...previews.values()].map(value => value.httpsPort)])
      let httpsPort = null
      for (let candidate = httpsPorts[0]; candidate <= httpsPorts[1]; candidate++) if (!used.has(candidate)) { httpsPort = candidate; break }
      if (!httpsPort) throw fail(503, 'no_preview_port_available')
      const record = { botID: botID.toLowerCase(), port, containerPort: containerPort ?? null, httpsPort, dns, createdAt: new Date().toISOString() }
      try {
        await tailscale(['serve', '--bg', '--https=' + httpsPort, target(record)])
        if (!owns(await serveStatus(), record)) throw fail(502, 'preview_route_unverified')
      } catch (error) {
        await removeRoute(record).catch(() => {}); throw error
      }
      previews.set(key, record); await save()
      return view(record)
    })
  }

  function unpublish({ botID, port }) {
    return serialized(async () => {
      const key = String(botID).toLowerCase() + ':' + port, record = previews.get(key)
      if (!record) return { removed: false }
      await removeRoute(record)
      previews.delete(key); await save()
      return { removed: true }
    })
  }

  const view = record => ({ url: `https://${record.dns}:${record.httpsPort}/`, botID: record.botID, port: record.port, containerPort: record.containerPort, httpsPort: record.httpsPort, createdAt: record.createdAt })

  // Shutdown removes every route: without this server, nothing renews them.
  async function close() {
    await serialized(async () => {
      for (const record of previews.values()) await removeRoute(record).catch(() => {})
      previews.clear(); await save().catch(() => {})
    })
  }

  return { recover, publish, unpublish, list: () => [...previews.values()].map(view), close }
}
