import { spawn } from 'node:child_process'
import { createHash, randomBytes } from 'node:crypto'
import { createWriteStream } from 'node:fs'
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import { pipeline } from 'node:stream/promises'

const fail = (statusCode, message) => Object.assign(new Error(message), { statusCode })
const maximumBundleBytes = 512 * 1024 * 1024

// Runs one lifecycle command and returns its JSON reply, or its JSON error.
export function runHostScript(script, args, { environment = process.env, timeout = 180_000, spawnImpl = spawn } = {}) {
  return new Promise((resolve, reject) => {
    const env = { ...environment }; delete env.WOVENMATTER_API_TOKEN
    const child = spawnImpl('/bin/bash', [script, ...args], { env, stdio: ['ignore', 'pipe', 'pipe'] })
    let output = '', errors = ''
    const timer = setTimeout(() => child.kill('SIGKILL'), timeout); timer.unref?.()
    child.stdout.on('data', data => { output = (output + data).slice(-4 * 1024 * 1024) })
    child.stderr.on('data', data => { errors = (errors + data).slice(-65536) })
    child.once('error', () => { clearTimeout(timer); reject(fail(500, 'host_script_unavailable')) })
    child.once('exit', code => {
      clearTimeout(timer)
      const last = text => { try { return JSON.parse(text.trim().split('\n').filter(Boolean).at(-1)) } catch { return null } }
      if (code === 0) { const value = last(output); return value ? resolve(value) : reject(fail(502, 'host_script_invalid_reply')) }
      const error = last(errors)
      reject(Object.assign(fail(code === 64 ? 400 : code === 66 ? 404 : code === 73 || code === 75 ? 409 : 502, typeof error?.error === 'string' ? error.error : 'host_command_failed'),
        { detail: typeof error?.detail === 'string' ? error.detail.slice(0, 512) : null }))
    })
  })
}

/**
 * Remote host administration for Mac members (docs: "Membership and device
 * keys"): the same lifecycle commands a Mac runs over Tailscale SSH, through
 * this server instead. Restart and update run in their own transient systemd
 * user unit, because they stop this server. Only first install needs SSH.
 */
export function createHostAdministration({ serviceRoot, dataRoot, stateDirectory, script = process.env.WOVENMATTER_HOST_SCRIPT || join(serviceRoot, 'host/remote-host.sh'),
  run = runHostScript, detach = detachedUnit, extractScript = extractBundleScript, extra = async () => ({}),
  adoptMembers = null, hasMacMember = async () => true }) {
  const updates = join(stateDirectory, 'host-update')
  async function installation() {
    try {
      const value = JSON.parse(await readFile(join(dataRoot, 'installation.json'), 'utf8'))
      if (typeof value.id === 'string' && Number.isSafeInteger(value.port)) return value
    } catch {}
    throw fail(409, 'host_not_installed')
  }
  const sizeArgument = value => value === null ? 'none' : Number.isSafeInteger(value) && value > 0 ? String(value) : null

  async function lastUpdate() {
    let saved = null
    try { saved = JSON.parse(await readFile(join(updates, 'update.json'), 'utf8')) } catch { return { state: 'none' } }
    const read = async name => { try { return await readFile(join(updates, name), 'utf8') } catch { return null } }
    const code = await read('update.code')
    if (code === null) return { ...saved, state: 'running' }
    const parse = value => { try { return JSON.parse(String(value).trim().split('\n').filter(Boolean).at(-1)) } catch { return null } }
    return Number(code) === 0 ? { ...saved, state: 'succeeded', result: parse(await read('update.out')) }
      : { ...saved, state: 'failed', error: parse(await read('update.err')) ?? { error: 'host_update_failed' } }
  }

  // The uploaded bundle belongs to the detached update once it starts (which
  // removes it when done); on every earlier failure it is removed here.
  async function startUpdate(request, url, bodyFile) {
    let stream = bodyFile, recorded = false
    try {
      const fingerprint = url.searchParams.get('fingerprint') ?? ''
      if (!/^[a-f0-9]{64}$/.test(fingerprint)) throw fail(400, 'A SHA-256 deployment fingerprint is required.')
      const roles = url.searchParams.get('roles')
      if (roles !== null && !/^(workspace|bots)(,(workspace|bots))?$/.test(roles)) throw fail(400, 'Choose the workspace, bots, or both.')
      const current = await installation()
      if ((await lastUpdate()).state === 'running') throw fail(409, 'host_update_running')
      await mkdir(updates, { recursive: true, mode: 0o700 })
      for (const name of ['update.out', 'update.err', 'update.code', 'remote-host.sh']) await rm(join(updates, name), { force: true })
      // The bundle carries its own lifecycle script; it verifies the bundle.
      stream ??= await receiveBundle(request, join(updates, 'bundle-' + randomBytes(6).toString('hex') + '.stream'))
      const updateScript = await extractScript(stream.path, join(updates, 'remote-host.sh')).catch(() => script)
      const roleText = roles ?? Object.entries(current.roles ?? { workspace: true }).filter(([, on]) => on).map(([name]) => name).join(',')
      await writeFile(join(updates, 'update.json'), JSON.stringify({ fingerprint, roles: roleText, startedAt: new Date().toISOString() }) + '\n', { mode: 0o600 })
      recorded = true
      // An empty credential line keeps the installed API token.
      await detach('update', ['/bin/bash', '-c', 'bash "$1" update "$2" "$3" "$4" "$5" "$6" <"$7" >"$8/update.out" 2>"$8/update.err"; echo $? >"$8/update.code"; rm -f "$7"',
        'wovenmatter-update', updateScript, current.id, String(current.port), current.accessMode, fingerprint, roleText, stream.path, updates])
      stream.owned = true
      return { started: true, fingerprint }
    } finally {
      if (stream && !stream.owned) await rm(stream.path, { force: true }).catch(() => {})
      // An update that never started must not read as running.
      if (recorded && !stream?.owned) await rm(join(updates, 'update.json'), { force: true }).catch(() => {})
    }
  }

  async function handle(request, response, url, { json, readJSON, readBody, administrator, bodyFile, member = null, installer = false }) {
    if (!url.pathname.startsWith('/v1/host/')) return false
    const path = url.pathname, method = request.method
    // Adopting members: the installer's bearer only while no Mac is a member
    // yet (the first adoption, when this host cannot verify any Mac); a signed
    // Mac member after that. The body reaches the library host unchanged.
    if (path === '/v1/host/members/adopt') {
      if (method !== 'POST') { json(response, 405, { error: 'method_not_allowed' }); return true }
      if (!adoptMembers) { json(response, 503, { error: 'library_unavailable' }); return true }
      if (member?.kind !== 'mac' && !(installer && !await hasMacMember())) { json(response, 403, { error: 'mac_member_required' }); return true }
      const body = request.wovenBody ?? await readBody(request, 1_048_576)
      if (body.length > 1_048_576) throw fail(413, 'request_too_large')
      json(response, 200, await adoptMembers(body)); return true
    }
    if (!administrator) { json(response, 403, { error: 'administrator_required' }); return true }
    if (path === '/v1/host/status' && method === 'GET') {
      const current = await installation()
      json(response, 200, { ...await run(script, ['status', current.id]), ...await extra() }); return true
    }
    if (path === '/v1/host/logs' && method === 'GET') {
      const lines = url.searchParams.get('lines') ?? '100'
      if (!/^\d{1,4}$/.test(lines) || Number(lines) < 1 || Number(lines) > 1000) throw fail(400, 'Choose between 1 and 1000 log lines.')
      json(response, 200, await run(script, ['logs', (await installation()).id, lines])); return true
    }
    if (path === '/v1/host/restart' && method === 'POST') {
      const current = await installation()
      await detach('restart', ['/bin/bash', script, 'restart', current.id], { delaySeconds: 1 })
      json(response, 202, { restarting: true }); return true
    }
    if (path === '/v1/host/bots-configure' && method === 'POST') {
      const body = await readJSON(request, 4096), pool = sizeArgument(body.poolBytes), disk = sizeArgument(body.diskBytes)
      if (!pool || !disk) throw fail(400, 'Choose a positive RAM pool and disk cap in bytes, or null for no cap.')
      json(response, 200, await run(script, ['bots-configure', (await installation()).id, pool, disk])); return true
    }
    if (path === '/v1/host/update' && method === 'GET') { json(response, 200, await lastUpdate()); return true }
    if (path === '/v1/host/update' && method === 'POST') { json(response, 202, await startUpdate(request, url, bodyFile)); return true }
    json(response, 404, { error: 'not_found' }); return true
  }

  // A signed upload is received while its signature is checked.
  async function receive(request) {
    await mkdir(updates, { recursive: true, mode: 0o700 })
    return receiveBundle(request, join(updates, 'bundle-' + randomBytes(6).toString('hex') + '.stream'))
  }

  return { handle, receive, lastUpdate }
}

/** Streams a request body to `path`, prefixed by the empty credential line, hashing the body. */
export async function receiveBundle(request, path, limit = maximumBundleBytes) {
  const hash = createHash('sha256'), output = createWriteStream(path, { mode: 0o600 })
  output.write('\n')
  let bytes = 0
  try {
    await pipeline(request, async function* (source) {
      for await (const chunk of source) {
        bytes += chunk.length
        if (bytes > limit) throw fail(413, 'The host bundle exceeds its size limit.')
        hash.update(chunk); yield chunk
      }
    }, output)
  } catch (error) { await rm(path, { force: true }); throw error.statusCode ? error : fail(400, 'The host bundle upload failed.') }
  return { path, sha256: hash.digest('hex'), bytes }
}

// The bundle's own host/remote-host.sh; the stream file starts with one line.
function extractBundleScript(streamPath, destination) {
  return new Promise((resolve, reject) => {
    const child = spawn('/bin/bash', ['-c', 'tail -c +2 "$1" | tar -xzOf - host/remote-host.sh >"$2"', 'extract', streamPath, destination], { stdio: 'ignore' })
    child.once('error', reject)
    child.once('exit', code => code === 0 ? resolve(destination) : reject(fail(400, 'bundle_script_missing')))
  })
}

// A transient user unit survives this service's own restart.
function detachedUnit(name, command, { delaySeconds = 0 } = {}) {
  return new Promise((resolve, reject) => {
    const unit = `wovenmatter-host-${name}-${randomBytes(4).toString('hex')}`
    const child = spawn('systemd-run', ['--user', '--collect', '--quiet', '--unit=' + unit, ...(delaySeconds ? ['--on-active=' + delaySeconds] : []), ...command], { stdio: 'ignore' })
    child.once('error', () => reject(fail(500, 'systemd_run_unavailable')))
    child.once('exit', code => code === 0 ? resolve(unit) : reject(fail(500, 'systemd_run_failed')))
  })
}
