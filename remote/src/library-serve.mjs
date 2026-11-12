import { randomBytes } from 'node:crypto'
import { mkdir, open, readFile, rename } from 'node:fs/promises'
import { dirname } from 'node:path'
import { tailscaleCommand } from './bots-previews.mjs'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })

/**
 * Publishes the library host's loopback routes on the tailnet with Tailscale
 * Serve under `/wovenmatter`, the path layout a Mac uses, so peers and phones
 * reach this machine's library at `https://<name>:<port>/wovenmatter`. The
 * HTTPS port follows the Mac's choice order. Funnel is never used, and only the
 * route recorded in `statePath` is ever replaced or removed.
 */
export function createLibraryServe({ statePath, tailscale = tailscaleCommand, candidates = [8443, 10000, 8444, 8445], path = '/wovenmatter' }) {
  let queue = Promise.resolve()
  const serialized = operation => { const next = queue.then(operation); queue = next.catch(() => {}); return next }
  const handlerAt = (config, endpoint) => {
    const handlers = config.Web?.[endpoint]?.Handlers ?? {}
    return handlers[path] ?? handlers[path + '/'] ?? null
  }
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
  async function recorded() { try { return JSON.parse(await readFile(statePath, 'utf8')) } catch { return null } }
  async function save(value) {
    await mkdir(dirname(statePath), { recursive: true, mode: 0o700 })
    const temporary = statePath + '.' + randomBytes(4).toString('hex'), handle = await open(temporary, 'wx', 0o600)
    try { await handle.writeFile(JSON.stringify(value) + '\n') } finally { await handle.close() }
    await rename(temporary, statePath)
  }
  const owns = (config, record) => {
    const endpoint = `${record.dns}:${record.httpsPort}`
    return config.TCP?.[String(record.httpsPort)]?.HTTPS === true && !config.AllowFunnel?.[endpoint] && handlerAt(config, endpoint)?.Proxy === record.target
  }
  const view = record => ({ endpoint: `https://${record.dns}:${record.httpsPort}${path}`, httpsPort: record.httpsPort, target: record.target })

  function publish(loopbackPort) {
    return serialized(async () => {
      const target = 'http://127.0.0.1:' + loopbackPort, dns = await dnsName(), config = await serveStatus(), saved = await recorded()
      if (saved && saved.dns === dns && owns(config, { ...saved, target })) return view({ ...saved, target })
      let httpsPort = null
      // Our earlier route (an older loopback port) is updated in place.
      if (saved && saved.dns === dns && owns(config, saved)) httpsPort = saved.httpsPort
      else {
        const used = new Set(Object.keys(config.TCP ?? {}).map(Number))
        httpsPort = candidates.find(port => !used.has(port)) ?? null
      }
      if (!httpsPort) throw fail(503, 'no_library_https_port')
      if (config.AllowFunnel?.[`${dns}:${httpsPort}`]) throw fail(409, 'library_route_funnel_conflict')
      const record = { dns, httpsPort, target, path, publishedAt: new Date().toISOString() }
      await tailscale(['serve', '--bg', '--https=' + httpsPort, '--set-path=' + path, target])
      if (!owns(await serveStatus(), record)) throw fail(502, 'library_route_unverified')
      await save(record)
      return view(record)
    })
  }

  /** Removes the recorded route if it still points where Woven left it. */
  function remove() {
    return serialized(async () => {
      const saved = await recorded()
      if (!saved) return { removed: false }
      let removed = false
      if (owns(await serveStatus(), saved)) { await tailscale(['serve', '--https=' + saved.httpsPort, '--set-path=' + path, 'off']); removed = true }
      await save(null)
      return { removed }
    })
  }

  return { publish, remove, recorded: async () => { const value = await recorded(); return value ? view(value) : null } }
}
