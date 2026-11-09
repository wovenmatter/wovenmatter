import { randomUUID } from 'node:crypto'
import { open, readFile, rename, statfs, stat, unlink, writeFile } from 'node:fs/promises'
import { request as httpRequest } from 'node:http'
import { totalmem } from 'node:os'
import { join } from 'node:path'

const GB = 1024 ** 3
const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })

// Paths of the root-owned engine that remote/host/bots-engine.py installs.
// The server only reads them, except the group-writable settings request.
export function botEngineLayout(instance = 'wovenmatter', root = '/') {
  if (!/^[a-z][a-z0-9]{1,15}$/.test(instance)) throw new Error('invalid_bots_instance')
  const varRoot = join(root, 'var/lib', instance + '-bots')
  return {
    instance,
    config: join(root, 'etc', instance + '-bots', 'instance.json'),
    var: varRoot, data: join(varRoot, 'docker'), image: join(varRoot, 'disk.img'),
    request: join(varRoot, 'requests/settings.json'), state: join(varRoot, 'state/state.json'),
    socket: join(root, 'run', instance, 'docker.sock'),
    sliceMemory: join(root, 'sys/fs/cgroup', instance + '.slice', instance + '-bots.slice', 'memory.current'),
  }
}

async function readJSON(path) {
  try { return JSON.parse(await readFile(path, 'utf8')) } catch { return null }
}

async function filesystem(path) {
  for (let current = path; ; current = join(current, '..')) {
    try {
      const value = await statfs(current)
      return { totalBytes: value.blocks * value.bsize, freeBytes: value.bavail * value.bsize, usedBytes: (value.blocks - value.bfree) * value.bsize }
    } catch (error) { if (current === '/' || error.code !== 'ENOENT') return null }
  }
}

// Docker Engine API over its Unix socket; the runtime uses the same socket.
export function dockerAPI(socketPath, path, { method = 'GET', timeout = 5000, body } = {}) {
  return new Promise((resolve, reject) => {
    const request = httpRequest({ socketPath, path, method, timeout, headers: body ? { 'content-type': 'application/json' } : {} }, response => {
      const chunks = []
      let size = 0
      response.on('data', chunk => { size += chunk.length; if (size > 8 * 1024 * 1024) request.destroy(fail(502, 'docker_response_too_large')); else chunks.push(chunk) })
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8')
        if (response.statusCode >= 400) return reject(fail(502, 'docker_request_failed'))
        try { resolve(text && response.headers['content-type']?.includes('json') ? JSON.parse(text) : text) } catch { reject(fail(502, 'docker_invalid_response')) }
      })
    })
    request.on('timeout', () => request.destroy(fail(504, 'docker_timeout')))
    request.on('error', reject)
    if (body) request.write(JSON.stringify(body))
    request.end()
  })
}

export function createBotEngine({ instance = 'wovenmatter', root = '/', memoryTotal = totalmem, docker = dockerAPI, now = Date.now, sleep = ms => new Promise(r => setTimeout(r, ms)) } = {}) {
  const layout = botEngineLayout(instance, root)

  async function status() {
    const config = await readJSON(layout.config)
    if (!config || typeof config !== 'object') return { installed: false, instance, socket: layout.socket, ready: false }
    const state = await readJSON(layout.state) ?? {}
    let ready = false
    try { ready = (await docker(layout.socket, '/_ping', { timeout: 2000 })) === 'OK' } catch {}
    return { installed: true, instance, ready, socket: layout.socket, owner: config.user, dockerVersion: config.dockerVersion ?? null,
      poolBytes: config.poolBytes ?? null, diskBytes: config.diskBytes ?? null, subnet: config.subnet, bridge: config.bridge,
      appliedRevision: state.appliedRevision ?? null, requestError: state.requestError ?? null, notes: Array.isArray(state.notes) ? state.notes : [] }
  }

  async function diskUsage(engine) {
    if (engine.diskBytes != null) {
      const mounted = await filesystem(layout.data)
      const host = await filesystem(layout.var)
      // A capped engine is a mounted image, so its filesystem reports usage.
      if (mounted && host && mounted.totalBytes !== host.totalBytes) return mounted.usedBytes
    }
    if (!engine.ready) return null
    try {
      const value = await docker(layout.socket, '/system/df', { timeout: 15000 })
      const containers = (value.Containers ?? []).reduce((sum, item) => sum + (item.SizeRw ?? 0), 0)
      const volumes = (value.Volumes ?? []).reduce((sum, item) => sum + Math.max(0, item.UsageData?.Size ?? 0), 0)
      return (value.LayersSize ?? 0) + containers + volumes + (value.BuildCache ?? []).reduce((sum, item) => sum + (item.Size ?? 0), 0)
    } catch { return null }
  }

  // What the Bots page shows: device totals, the caps, and current usage.
  async function resources({ botMemoryBytes = null } = {}) {
    const engine = await status()
    const host = await filesystem(layout.var)
    const totalMemory = memoryTotal()
    let memoryUsed = null
    try { memoryUsed = Number.parseInt(await readFile(layout.sliceMemory, 'utf8'), 10) } catch {}
    const imageBytes = await stat(layout.image).then(value => value.size, () => null)
    const used = engine.installed ? await diskUsage(engine) : null
    const warnings = []
    if (engine.poolBytes == null || totalMemory - engine.poolBytes < 4 * GB) warnings.push({ id: 'pool_leaves_little_memory', message: 'The RAM pool leaves this device less than 4 GB.' })
    if (host && engine.diskBytes != null && engine.diskBytes - (used ?? 0) > host.freeBytes) warnings.push({ id: 'disk_cap_exceeds_free_space', message: 'The disk cap is larger than the free space on this disk.' })
    return {
      engine: { installed: engine.installed, ready: engine.ready, dockerVersion: engine.dockerVersion ?? null },
      memory: { totalBytes: totalMemory, poolBytes: engine.poolBytes ?? null, botBytes: botMemoryBytes, usedBytes: Number.isFinite(memoryUsed) ? memoryUsed : null },
      disk: { path: layout.var, totalBytes: host?.totalBytes ?? null, freeBytes: host?.freeBytes ?? null, capBytes: engine.diskBytes ?? null, imageBytes, usedBytes: used },
      warnings, appliedRevision: engine.appliedRevision ?? null, requestError: engine.requestError ?? null, notes: engine.notes ?? [],
    }
  }

  // The root-owned path unit applies this request; the server never needs sudo.
  async function configure({ poolBytes, diskBytes }, { waitMilliseconds = 120000 } = {}) {
    const valid = value => value === null || (Number.isSafeInteger(value) && value > 0)
    if (!valid(poolBytes) || !valid(diskBytes)) throw fail(400, 'Choose a positive size in bytes, or null for no cap.')
    const engine = await status()
    if (!engine.installed) throw fail(409, 'bots_engine_not_installed')
    const revision = randomUUID(), temporary = layout.request + '.' + revision
    const handle = await open(temporary, 'wx', 0o640)
    try { await handle.writeFile(JSON.stringify({ revision, poolBytes, diskBytes })); await handle.sync() } finally { await handle.close() }
    try { await rename(temporary, layout.request) } catch (error) { await unlink(temporary).catch(() => {}); throw error }
    const deadline = now() + waitMilliseconds
    while (now() < deadline) {
      const state = await readJSON(layout.state)
      if (state?.appliedRevision === revision) {
        if (state.requestError) throw fail(409, state.requestError)
        return { revision, pending: false, ...await resources() }
      }
      await sleep(250)
    }
    return { revision, pending: true, ...await resources() }
  }

  return { layout, status, resources, configure }
}

// Linux hosts written before membership keys use this stable machine ID. The
// membership workstream's identity file takes precedence when it exists.
export async function machineIdentity({ dataRoot, environment = process.env, hostname }) {
  const valid = value => typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value.trim())
  if (valid(environment.WOVENMATTER_DEVICE_ID)) return { deviceID: environment.WOVENMATTER_DEVICE_ID.trim().toLowerCase(), name: hostname }
  const path = join(dataRoot, 'identity/device-id')
  try {
    const saved = (await readFile(path, 'utf8')).trim()
    if (valid(saved)) return { deviceID: saved.toLowerCase(), name: hostname }
  } catch {}
  const { mkdir } = await import('node:fs/promises')
  await mkdir(join(dataRoot, 'identity'), { recursive: true, mode: 0o700 })
  const deviceID = randomUUID()
  try { await writeFile(path, deviceID + '\n', { mode: 0o600, flag: 'wx' }) } catch (error) {
    if (error.code !== 'EEXIST') throw error
    return machineIdentity({ dataRoot, environment: {}, hostname })
  }
  return { deviceID, name: hostname }
}
