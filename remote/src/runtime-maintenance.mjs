import { spawn } from 'node:child_process'
import { readFile, writeFile, mkdir, rename, realpath } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'

const quote = value => `'${String(value).replaceAll("'", "'\\''")}'`
const failure = message => Object.assign(new Error(message), { statusCode: 409 })
export const normalizedVersion = value => String(value ?? '').match(/\d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.-]+)?/)?.[0] ?? null
export function precedes(a, b) {
  if (!a || !b || a === b) return false
  const aa = a.split(/[.-]/), bb = b.split(/[.-]/)
  for (let i = 0; i < Math.max(aa.length, bb.length); i++) {
    if (aa[i] === bb[i]) continue
    if (/^\d+$/.test(aa[i]) && /^\d+$/.test(bb[i])) return Number(aa[i]) < Number(bb[i])
    return false // Unknown prerelease ordering is not an available update claim.
  }
  return false
}
export function diagnosticCategory(error) {
  const text = String(error ?? '')
  const allowed = ['runtime_active_stop_conversations_or_server_first', 'active_conversation_check_unavailable', 'runtime_active_or_operation_in_progress', 'runtime_lock_unavailable', 'hermes_update_requires_host_terminal', 'source_digest_required', 'installer_digest_changed', 'installer_download_failed', 'installer_download_timed_out', 'runtime_preferences_save_failed', 'bundled_dependency_refresh_failed']
  if (allowed.includes(text)) return text
  if (text.startsWith('Installer exited ')) return 'installer_failed'
  if (text === 'Installer finished but required components could not be verified.') return 'installation_verification_failed'
  if (text === 'Update finished but a required component is still behind the checked version.') return 'update_verification_failed'
  return 'runtime_operation_failed'
}
const updateTarget = component => component.id === 'bundled' ? component.updateTargetVersion : component.latestVersion
export function sanitize(value, environment = {}) {
  let result = String(value ?? '').replace(/\x1b\[[0-9;]*[A-Za-z]/g, '')
  for (const [key, secret] of Object.entries(environment)) {
    if (/token|secret|password|api.?key/i.test(key) && typeof secret === 'string' && secret.length > 3) result = result.replaceAll(secret, '[redacted]')
  }
  return result.replace(/https?:\/\/\S+/gi, '[URL redacted]').replace(/(?:Bearer\s+|sk-|sk-ant-)[\w.-]+/gi, '[redacted]').replace(/((?:token|password|secret|api[_-]?key)\s*[=:]\s*)\S+/gi, '$1[redacted]').slice(-4096)
}
export function runHost(command, environment, cwd, timeout = 15000) {
  return new Promise(resolvePromise => {
    let output = '', settled = false, timedOut = false
    const child = spawn('/bin/bash', ['-c', command], { env: environment, cwd, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    const done = code => { if (settled) return; settled = true; clearTimeout(timer); resolvePromise({ code: timedOut ? -1 : code, output }) }
    const timer = setTimeout(() => { timedOut = true; try { process.kill(-child.pid, 'SIGKILL') } catch {} }, timeout)
    child.stdout.on('data', data => { output = (output + data).slice(-65536) })
    child.stderr.on('data', data => { output = (output + data).slice(-65536) })
    child.on('error', () => done(-1)); child.on('close', done)
  })
}
export async function acquireHostLock(path, environment, cwd, shared = false) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  return new Promise((resolvePromise, reject) => {
    const child = spawn('flock', [shared ? '--shared' : '--exclusive', '--nonblock', path, '/bin/sh', '-c', 'echo locked; cat >/dev/null'], { env: environment, cwd, stdio: ['pipe', 'pipe', 'ignore'] })
    let acquired = false
    const timer = setTimeout(() => { child.kill('SIGTERM'); reject(failure('runtime_lock_unavailable')) }, 5000)
    child.once('error', () => { clearTimeout(timer); reject(failure('runtime_lock_unavailable')) })
    child.once('exit', () => { clearTimeout(timer); if (!acquired) reject(failure('runtime_active_or_operation_in_progress')) })
    child.stdout.once('data', () => { acquired = true; clearTimeout(timer); resolvePromise(() => child.stdin.end()) })
  })
}
async function packageAt(path) { try { return JSON.parse(await readFile(resolve(path, 'package.json'), 'utf8')) } catch { return null } }
async function packageRoot(path, name, dependency = false) {
  let directory = path
  for (let i = 0; i < 16; i++) {
    const candidate = dependency ? resolve(directory, 'node_modules', name) : directory
    if ((await packageAt(candidate))?.name === name) return candidate
    if (dirname(directory) === directory) break
    directory = dirname(directory)
  }
  return null
}

export function createRuntimeMaintenance({ catalog, workspaceRoot, environment, verifiedInstaller, hasActiveRuntime = async () => false, execute = runHost, fetchImplementation = fetch, acquireLock = acquireHostLock }) {
  const states = new Map(), operations = new Map()
  const statePath = resolve(workspaceRoot, '.wovenmatter/runtime-preferences.json')
  let saveQueue = Promise.resolve(), checks = null
  const loaded = readFile(statePath, 'utf8').then(text => {
    const saved = JSON.parse(text)
    for (const h of catalog.values()) states.set(h.id, { enabled: saved[h.id]?.enabled === true, visible: saved[h.id]?.visible !== false, failureCount: Number(saved[h.id]?.failureCount) || 0 })
  }).catch(() => {})
  async function state(id) { await loaded; if (!states.has(id)) states.set(id, { enabled: false, visible: true, failureCount: 0 }); return states.get(id) }
  function persist() {
    saveQueue = saveQueue.catch(() => {}).then(async () => {
      await mkdir(dirname(statePath), { recursive: true, mode: 0o700 })
      const data = Object.fromEntries([...states].map(([id, s]) => [id, { enabled: s.enabled, visible: s.visible, failureCount: s.failureCount }]))
      await writeFile(statePath + '.tmp', JSON.stringify(data), { mode: 0o600 }); await rename(statePath + '.tmp', statePath)
    }); return saveQueue
  }
  const run = (command, timeout) => execute(command, environment(), workspaceRoot, timeout)
  async function component(id, name, command, required = true) {
    const found = await run(`command -v ${quote(command)}`)
    const path = found.code === 0 ? found.output.trim().split('\n')[0] : null
    const result = path ? await run(`${quote(path)} --version`) : null
    const version = result?.code === 0 ? normalizedVersion(result.output) : null
    return { id, displayName: name, path, installedVersion: version, latestVersion: null, required, installed: Boolean(path && version) }
  }
  async function latest(packageName, tag = 'latest') {
    try {
      const response = await fetchImplementation(`https://registry.npmjs.org/${encodeURIComponent(packageName)}/${encodeURIComponent(tag)}`, { signal: AbortSignal.timeout(10000) })
      if (!response.ok) return null
      return normalizedVersion((await response.json()).version)
    } catch { return null }
  }
  async function inventory(h, checkLatest = false) {
    const s = await state(h.id), previous = s.components ?? []
    const main = await component('runtime', h.command, h.command)
    if (h.minimumAdapterVersion && precedes(main.installedVersion, h.minimumAdapterVersion)) main.installed = false
    if (h.id === 'opencode' && main.installedVersion !== h.install.package.split('@').at(-1)) main.installed = false
    const components = [main]
    let adapterRoot = null, dependencyName = null, dependencyRange = null
    if (h.transportCheckCommand && !h.adapterPackage && h.id !== 'opencode') {
      const probe = main.installed ? await run(h.id === 'openclaw' ? 'openclaw gateway --help' : h.transportCheckCommand) : null
      components.push({ id: 'transport', displayName: h.id === 'openclaw' ? 'Gateway command' : h.transport + ' transport', path: main.path, installedVersion: main.installedVersion, latestVersion: null, required: true, installed: probe?.code === 0 })
    }
    if (h.adapterPackage) {
      components.push(await component('signin', h.cliCommand + ' (sign-in CLI)', h.cliCommand))
      const dependency = h.id === 'codex' ? '@openai/codex' : '@anthropic-ai/claude-agent-sdk'
      let root = null
      try { root = await packageRoot(dirname(await realpath(main.path)), h.adapterPackage) } catch {}
      adapterRoot = root; dependencyName = dependency
      dependencyRange = root ? (await packageAt(root))?.dependencies?.[dependency] : null
      const dep = root ? await packageRoot(root, dependency, true) : null
      const object = dep ? await packageAt(dep) : null
      let engine = dep ? resolve(dep, h.id === 'codex' ? 'bin/codex.js' : 'cli.js') : null
      if (dep && h.id === 'claude_code') {
        const native = `@anthropic-ai/claude-agent-sdk-${process.platform}-${process.arch}`
        if (object?.optionalDependencies?.[native]) { const nativeRoot = await packageRoot(dep, native, true); engine = nativeRoot ? resolve(nativeRoot, 'claude') : null }
      }
      const result = engine ? await run(`${quote(engine)} --version`) : null
      components.push({ id: 'bundled', displayName: 'Bundled ' + dependency, path: engine, installedVersion: normalizedVersion(object?.version), latestVersion: null, required: true, installed: Boolean(object?.version && result?.code === 0 && normalizedVersion(result.output)) })
      if (h.id === 'claude_code') components.push({ id: 'engine', displayName: 'Bundled Claude Code', path: engine, installedVersion: normalizedVersion(result?.output), latestVersion: null, required: true, installed: result?.code === 0 && Boolean(normalizedVersion(result.output)) })
      const key = h.id === 'codex' ? 'CODEX_PATH' : 'CLAUDE_CODE_EXECUTABLE'
      if (environment()[key]) components.push(await component('override', key + ' override', environment()[key]))
    }
    if (checkLatest) {
      if (h.id === 'hermes') {
        const result = main.installed ? await run(`${quote(main.path)} update --check`, 30000) : null
        const available = /Update available:|Update available \(behind /.test(result?.output ?? '')
        const current = (result?.output ?? '').includes('Already up to date.')
        s.hermesNotice = result?.code === 0 && available !== current
          ? available ? 'Hermes reports an update available. Review its update plan in Terminal on this host.' : 'Hermes reports this checkout is up to date.'
          : 'Hermes update information is unavailable.'
      }
      const packageName = h.adapterPackage ?? ({ pi: '@earendil-works/pi-coding-agent', openclaw: 'openclaw', opencode: '@opencode/cli' })[h.id]
      if (packageName) main.latestVersion = await latest(packageName, h.id === 'opencode' ? h.install.package.split('@').at(-1) : 'latest')
      else if (['grok_build', 'cursor'].includes(h.id)) {
        try {
          const response = await fetchImplementation(h.id === 'cursor' ? 'https://cursor.com/install' : 'https://x.ai/cli/stable', { signal: AbortSignal.timeout(10000) })
          if (response.ok) { const text = await response.text(); main.latestVersion = h.id === 'cursor' ? text.match(/https:\/\/downloads\.cursor\.com\/lab\/([0-9]{4}\.[0-9]{2}\.[0-9]{2}-[a-z0-9]+)\//)?.[1] ?? null : normalizedVersion(text) }
        } catch {}
      }
      if (h.adapterPackage) {
        components[1].latestVersion = await latest(h.id === 'codex' ? '@openai/codex' : '@anthropic-ai/claude-code')
        const bundled = components.find(c => c.id === 'bundled')
        bundled.latestVersion = await latest(dependencyName)
        bundled.updateTargetVersion = null
        // npm performs the semver selection using the adapter's declared dependency
        // range. Never override a pinned/ranged adapter dependency with @latest.
        if (adapterRoot && typeof dependencyRange === 'string' && /^[0-9v^~<>=|*xX. +\-]+$/.test(dependencyRange)) {
          const result = await run(`npm view ${quote(dependencyName + '@' + dependencyRange)} version --json --registry=https://registry.npmjs.org`, 15000)
          try { const versions = JSON.parse(result.output); if (result.code === 0) bundled.updateTargetVersion = normalizedVersion(Array.isArray(versions) ? versions.at(-1) : versions) } catch {}
        }
      }
    } else for (const c of components) { const cached = previous.find(p => p.id === c.id); c.latestVersion = cached?.latestVersion ?? null; if (c.id === 'bundled') c.updateTargetVersion = cached?.updateTargetVersion ?? null }
    s.components = components
    const storedOperation = operations.get(h.id) ?? null
    const operation = storedOperation && !storedOperation.finishedAt ? { ...storedOperation, status: 'running' } : storedOperation
    const installed = components.every(c => !c.required || c.installed)
    let notice = h.id === 'hermes' ? 'Hermes updates remain manual: review hermes update --plan on this host; its updater may restart other profiles.' : h.id === 'opencode' ? `OpenCode v2 compatibility is pinned to ${h.install.package.split('@').at(-1)}.` : h.adapterPackage ? 'Chat uses the adapter and bundled engine shown here; sign-in CLI updates do not update that engine.' : null
    if (h.id === 'hermes' && s.hermesNotice) notice += ' ' + s.hermesNotice
    const bundled = components.find(c => c.id === 'bundled')
    if (bundled?.latestVersion && bundled.latestVersion !== bundled.updateTargetVersion) notice += ' The newest bundled dependency may exceed the adapter’s declared compatibility; only compatible dependency updates are offered.'
    if (checkLatest && h.id !== 'hermes' && (main.latestVersion === null || (bundled && (!bundled.latestVersion || !bundled.updateTargetVersion)))) notice = [notice, 'Latest version information is unavailable.'].filter(Boolean).join(' ')
    s.notice = checkLatest ? notice : notice ?? s.notice ?? null
    return { id: h.id, displayName: h.displayName, enabled: s.enabled, visible: s.visible, installed, components, operation, failureCount: s.failureCount, diagnosticPrompt: s.failureCount >= 2 ? `Diagnose ${h.displayName} on this remote workspace host (${process.platform}/${process.arch}). Do not modify other hosts.\n${components.map(c => `${c.displayName}: installed=${c.installedVersion ?? 'unknown'} latest=${c.latestVersion ?? 'unknown'} verified=${c.installed}`).join('\n')}\nFailure: ${diagnosticCategory(operation?.error)}` : null, notice: s.notice, updateAvailable: h.id !== 'hermes' && components.some(c => precedes(c.installedVersion, updateTarget(c))) }
  }
  async function busy(h) {
    if (await hasActiveRuntime(h.id)) return true
    // Conversations run over SSH outside this service. Check the host process list,
    // without returning command lines (which can contain credentials) to the client.
    const result = await run('ps -eo pid=,args=')
    if (result.code !== 0) throw failure('active_conversation_check_unavailable')
    const names = [h.command, h.cliCommand]
    return result.output.split('\n').some(line => !/ps -eo|\/bin\/bash -c/.test(line) && names.some(name => line.split(/\s+/).some(arg => arg === name || arg.endsWith('/' + name) || arg.endsWith('/' + name + '.js'))))
  }
  async function start(h, action, body) {
    if (body.confirmed !== true) throw failure('confirmation_required')
    const s = await state(h.id)
    if (operations.get(h.id) && !operations.get(h.id).finishedAt) return operations.get(h.id)
    // Reserve synchronously before download/probe awaits to prevent duplicate operations.
    const op = { id: randomUUID(), harnessID: h.id, action, status: 'running', output: '', error: null, startedAt: new Date().toISOString(), finishedAt: null }
    operations.set(h.id, op)
    void (async () => {
      let unlock
      try {
        unlock = await acquireLock(resolve(environment().HOME, '.wovenmatter/runtime-operation.lock'), environment(), workspaceRoot)
        if (action === 'update' && h.id === 'hermes') throw failure('hermes_update_requires_host_terminal')
        if (await busy(h)) throw failure('runtime_active_stop_conversations_or_server_first')
        let command
        const pkg = h.id === 'opencode' ? h.install.package : h.id === 'pi' ? '@earendil-works/pi-coding-agent@latest' : null
        const adapter = h.adapterPackage ? ` && npm install --global --prefix "$HOME/.local" ${quote(h.adapterPackage + '@latest')}` : ''
        if (pkg) command = `npm install --global --prefix "$HOME/.local" ${quote(pkg)}${adapter}`
        else {
          if (typeof body.sourceSHA256 !== 'string') throw failure('source_digest_required')
          const installer = await verifiedInstaller(h, body.sourceSHA256)
          command = `${quote(h.install.interpreter)} ${quote(installer.path)} ${(h.install.arguments ?? []).map(quote).join(' ')}${adapter}`
        }
        if (await busy(h)) throw failure('runtime_active_stop_conversations_or_server_first')
        const before = await inventory(h)
        const result = await run(command, 300000)
        op.output = sanitize(result.output, environment())
        if (result.code !== 0) throw failure(`Installer exited ${result.code}. ${op.output}`)
        if (h.adapterPackage) {
          // Re-resolve after adapter installation: npm may have changed its package
          // root or dependency constraint. npm update respects that new declaration.
          const installedAdapter = await component('runtime', h.command, h.command)
          let root = null
          try { root = await packageRoot(dirname(await realpath(installedAdapter.path)), h.adapterPackage) } catch {}
          const dependency = h.id === 'codex' ? '@openai/codex' : '@anthropic-ai/claude-agent-sdk'
          if (root && (await packageAt(root))?.dependencies?.[dependency]) {
            const refreshed = await run(`npm update --prefix ${quote(root)} --omit=dev --no-save --package-lock=false --registry=https://registry.npmjs.org ${quote(dependency)}`, 300000)
            if (refreshed.code !== 0) throw failure('bundled_dependency_refresh_failed')
          }
        }
        const after = await inventory(h)
        if (!after.installed) throw failure('Installer finished but required components could not be verified.')
        if (action === 'update' && before.components.some(c => precedes(c.installedVersion, updateTarget(c)) && precedes(after.components.find(a => a.id === c.id)?.installedVersion, updateTarget(c)))) throw failure('Update finished but a required component is still behind the checked version.')
        op.status = 'succeeded'; s.failureCount = 0
      } catch (error) { op.status = 'failed'; op.error = sanitize(error.message, environment()); s.failureCount += 1 }
      await persist().catch(() => { op.status = 'failed'; op.error = 'runtime_preferences_save_failed' })
      unlock?.(); op.finishedAt = new Date().toISOString()
    })()
    return op
  }
  return {
    inventory,
    async recordFailure(h, action, error) {
      const s = await state(h.id)
      if (operations.get(h.id) && !operations.get(h.id).finishedAt) return
      s.failureCount += 1
      const now = new Date().toISOString()
      operations.set(h.id, { id: randomUUID(), harnessID: h.id, action, status: 'failed', output: '', error: sanitize(error.message, environment()), startedAt: now, finishedAt: now })
      await persist()
    },
    async isEnabled(id) { return (await state(id)).enabled },
    isBusy(id) { return Boolean(operations.get(id) && !operations.get(id).finishedAt) },
    operation: id => { const op = [...operations.values()].find(op => op.id === id); return op && !op.finishedAt ? { ...op, status: 'running' } : op },
    start,
    async list() { return { runtimes: await Promise.all([...catalog.values()].map(h => inventory(h))) } },
    async check() {
      if (!checks) checks = (async () => ({ runtimes: await Promise.all([...catalog.values()].map(async h => inventory(h, (await state(h.id)).enabled))) }))().finally(() => { checks = null })
      return checks
    },
    async preferences(h, body) {
      const s = await state(h.id)
      if (body.enabled === true && !(await inventory(h)).installed) throw failure('runtime_requirements_not_verified')
      if (typeof body.enabled === 'boolean') s.enabled = body.enabled
      if (typeof body.visible === 'boolean') s.visible = body.visible
      await persist(); return inventory(h)
    },
  }
}
