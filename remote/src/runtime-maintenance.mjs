import { existsSync } from 'node:fs'
const bundledVersions = new URL('../default-agent/src/package-versions.mjs', import.meta.url)
const { latestSupportedPackage } = await import(existsSync(bundledVersions) ? bundledVersions.href : new URL('../../default-agent/src/package-versions.mjs', import.meta.url).href)
import { spawn } from 'node:child_process'
import { readFile, writeFile, mkdir, rename, realpath, lstat, readlink } from 'node:fs/promises'
import { dirname, resolve } from 'node:path'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { supportsOpenCodeVersion, openCodeCommands } from './opencode-compatibility.mjs'
import { loadRuntimeConfiguration, runtimeNPMCommand } from './config.mjs'
import { withInstallerGuard } from './installer-guard.mjs'

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
export function validatedPackageSpec(harness, supplied) {
  const selector = harness.install.package
  const separator = typeof selector === 'string' ? selector.lastIndexOf('@') : -1
  if (separator <= 0) throw failure('reviewed_package_spec_required')
  const name = selector.slice(0, separator)
  const spec = supplied
  if (typeof spec !== 'string' || !spec.startsWith(name + '@')) throw failure('invalid_package_spec')
  const version = spec.slice(name.length + 1)
  if (!/^\d+\.\d+\.\d+(?:-[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?(?:\+[0-9A-Za-z]+(?:[.-][0-9A-Za-z]+)*)?$/.test(version)) throw failure('invalid_package_spec')
  if (harness.id === 'opencode' && !supportsOpenCodeVersion(version)) throw failure('opencode_version_incompatible')
  return spec
}
export function diagnosticCategory(error) {
  const text = String(error ?? '')
  const allowed = ['runtime_active_stop_conversations_or_server_first', 'active_conversation_check_unavailable', 'runtime_active_or_operation_in_progress', 'runtime_lock_unavailable', 'source_digest_required', 'installer_digest_changed', 'installer_download_failed', 'installer_download_timed_out', 'runtime_preferences_save_failed', 'bundled_dependency_refresh_failed', 'system_install_update_forbidden', 'installer_modified_shell_config', 'installer_modified_harness_config']
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

export function createRuntimeMaintenance({ catalog, workspaceRoot, environment, verifiedInstaller, hasActiveRuntime = async () => false, execute = runHost, fetchImplementation = fetch, acquireLock = acquireHostLock, configuration = loadRuntimeConfiguration(environment()) }) {
  const states = new Map(), operations = new Map()
  const npm = runtimeNPMCommand(configuration)
  const statePath = resolve(workspaceRoot, '.wovenmatter/runtime-preferences.json')
  let saveQueue = Promise.resolve(), checks = null
  const loaded = readFile(statePath, 'utf8').then(text => {
    const saved = JSON.parse(text)
    for (const h of catalog.values()) {
      states.set(h.id, { failureCount: Number(saved[h.id]?.failureCount) || 0, managedComponents: saved[h.id]?.managedComponents ?? {} })
    }
  }).catch(() => {})
  async function state(id) { await loaded; if (!states.has(id)) states.set(id, { failureCount: 0 }); return states.get(id) }
  function persist() {
    saveQueue = saveQueue.catch(() => {}).then(async () => {
      await mkdir(dirname(statePath), { recursive: true, mode: 0o700 })
      const data = Object.fromEntries([...states].map(([id, s]) => [id, { failureCount: s.failureCount,
        ...(s.managedComponents && Object.keys(s.managedComponents).length ? { managedComponents: s.managedComponents } : {}) }]))
      await writeFile(statePath + '.tmp', JSON.stringify(data), { mode: 0o600 }); await rename(statePath + '.tmp', statePath)
    }); return saveQueue
  }
  // Older images copied a root-owned $HOME/.npm into named home volumes.
  // Keep all installer subprocesses on a cache owned by this workspace user.
  const run = (command, timeout) => execute(command, {
    ...environment(), npm_config_cache: resolve(workspaceRoot, '.wovenmatter/npm-cache'),
  }, workspaceRoot, timeout)
  async function componentSource(path) {
    if (!path) return 'missing'
    if (configuration.runtimeKind !== 'host') return 'managed'
    const target = await realpath(path).catch(() => path)
    for (const value of states.values()) for (const owned of Object.values(value.managedComponents ?? {})) {
      if (owned.path === path && owned.target === target) return 'managed'
    }
    return 'system'
  }
  async function commandPath(command) {
    const found = await run(`command -v ${quote(command)}`)
    return found.code === 0 ? found.output.trim().split('\n')[0] : null
  }
  async function component(id, name, command, required = true) {
    const path = await commandPath(command)
    const result = path ? await run(`${quote(path)} --version`) : null
    const version = result?.code === 0 ? normalizedVersion(result.output) : null
    return { id, displayName: name, path, source: await componentSource(path), installedVersion: version, latestVersion: null, required, installed: Boolean(path && version) }
  }
  async function latest(packageName) {
    try {
      return await latestSupportedPackage(packageName, {
        major: packageName === '@opencode/cli' ? 2 : undefined,
        fetchImplementation,
      })
    } catch { return null }
  }
  async function inventory(h, checkLatest = false) {
    const s = await state(h.id), previous = s.components ?? []
    let main = await component('runtime', h.command, h.command)
    if (h.id === 'opencode' && !supportsOpenCodeVersion(main.installedVersion)) {
      for (const command of openCodeCommands.filter(value => value !== h.command)) {
        const alias = await component('runtime', command, command)
        if (supportsOpenCodeVersion(alias.installedVersion)) { main = alias; break }
      }
    }
    if (h.minimumAdapterVersion && precedes(main.installedVersion, h.minimumAdapterVersion)) main.installed = false
    if (h.id === 'opencode' && !supportsOpenCodeVersion(main.installedVersion)) main.installed = false
    const components = [main]
    let adapterRoot = null, dependencyName = null, dependencyRange = null
    if (h.transportCheckCommand && !h.adapterPackage && h.id !== 'opencode') {
      const probe = main.installed ? await run(h.transportCheckCommand) : null
      components.push({ id: 'transport', displayName: h.transport + ' transport', path: main.path, source: main.source, installedVersion: main.installedVersion, latestVersion: null, required: true, installed: probe?.code === 0 })
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
      components.push({ id: 'bundled', displayName: 'Bundled ' + dependency, path: engine, source: main.source, installedVersion: normalizedVersion(object?.version), latestVersion: null, required: true, installed: Boolean(object?.version && result?.code === 0 && normalizedVersion(result.output)) })
      if (h.id === 'claude_code') components.push({ id: 'engine', displayName: 'Bundled Claude Code', path: engine, source: main.source, installedVersion: normalizedVersion(result?.output), latestVersion: null, required: true, installed: result?.code === 0 && Boolean(normalizedVersion(result.output)) })
      const key = h.id === 'codex' ? 'CODEX_PATH' : 'CLAUDE_CODE_EXECUTABLE'
      if (environment()[key]) components.push(await component('override', key + ' override', environment()[key]))
    }
    if (checkLatest) {
      const packageName = h.adapterPackage ?? ({ opencode: '@opencode/cli' })[h.id]
      if (packageName) main.latestVersion = await latest(packageName)
      else if (h.id === 'grok_build') {
        try {
          const response = await fetchImplementation('https://x.ai/cli/stable', { signal: AbortSignal.timeout(10000) })
          if (response.ok) { const text = await response.text(); main.latestVersion = normalizedVersion(text) }
        } catch {}
      }
      if (h.adapterPackage) {
        components[1].latestVersion = await latest(h.id === 'codex' ? '@openai/codex' : '@anthropic-ai/claude-code')
        const bundled = components.find(c => c.id === 'bundled')
        bundled.latestVersion = await latest(dependencyName)
        bundled.updateTargetVersion = h.minimumEngineVersion ? bundled.latestVersion : null
        // npm performs the semver selection using the adapter's declared dependency
        // range. Never override a pinned/ranged adapter dependency with @latest.
        if (!h.minimumEngineVersion && adapterRoot && typeof dependencyRange === 'string' && /^[0-9v^~<>=|*xX. +\-]+$/.test(dependencyRange)) {
          const result = await run(`${npm} view ${quote(dependencyName + '@' + dependencyRange)} version --json --registry=https://registry.npmjs.org`, 15000)
          try { const versions = JSON.parse(result.output); if (result.code === 0) bundled.updateTargetVersion = normalizedVersion(Array.isArray(versions) ? versions.at(-1) : versions) } catch {}
        }
      }
    } else for (const c of components) { const cached = previous.find(p => p.id === c.id); c.latestVersion = cached?.latestVersion ?? null; if (c.id === 'bundled') c.updateTargetVersion = cached?.updateTargetVersion ?? null }
    if (checkLatest) s.versionCheckAvailable = components.filter(c => ['runtime', 'signin', 'bundled'].includes(c.id)).every(c => c.latestVersion !== null && (c.id !== 'bundled' || c.updateTargetVersion !== null))
    for (const c of components) c.updateAvailable = c.source !== 'system' && precedes(c.installedVersion, updateTarget(c))
    s.components = components
    const storedOperation = operations.get(h.id) ?? null
    const operation = storedOperation && !storedOperation.finishedAt ? { ...storedOperation, status: 'running' } : storedOperation
    const installed = components.every(c => !c.required || c.installed)
    s.installed = installed
    let notice = h.id === 'opencode' ? 'OpenCode v2 releases can be updated independently.' : h.adapterPackage ? 'Chat uses the adapter and bundled engine shown here; sign-in CLI updates do not update that engine.' : null
    const bundled = components.find(c => c.id === 'bundled')
    if (!h.minimumEngineVersion && bundled?.latestVersion && bundled.latestVersion !== bundled.updateTargetVersion) notice += ' The newest bundled dependency may exceed the adapter’s declared compatibility; only compatible dependency updates are offered.'
    if (checkLatest && (main.latestVersion === null || (bundled && (!bundled.latestVersion || !bundled.updateTargetVersion)))) notice = [notice, 'Latest version information is unavailable.'].filter(Boolean).join(' ')
    s.notice = checkLatest ? notice : notice ?? s.notice ?? null
    return { id: h.id, displayName: h.displayName, source: main.source, path: main.path, enabled: installed, visible: true, installed, components, operation, failureCount: s.failureCount, diagnosticPrompt: s.failureCount >= 2 ? `Diagnose ${h.displayName} on this remote workspace host (${process.platform}/${process.arch}). Do not modify other hosts.\n${components.map(c => `${c.displayName}: installed=${c.installedVersion ?? 'unknown'} latest=${c.latestVersion ?? 'unknown'} verified=${c.installed}`).join('\n')}\nFailure: ${diagnosticCategory(operation?.error)}` : null, notice: s.notice, versionCheckAvailable: s.versionCheckAvailable ?? null, updateAvailable: components.some(c => c.updateAvailable) }
  }
  async function busy(h, maintainedNames) {
    if (await hasActiveRuntime(h.id)) return true
    const names = maintainedNames ?? (h.id === 'opencode' ? openCodeCommands : [h.command, h.cliCommand])
    if (!names.length) return false
    // Conversations run over SSH outside this service. Check the host process list,
    // without returning command lines (which can contain credentials) to the client.
    const result = await run('ps -eo pid=,args=')
    if (result.code !== 0) throw failure('active_conversation_check_unavailable')
    return result.output.split('\n').some(line => !/ps -eo|\/bin\/bash -c/.test(line) && names.some(name => line.split(/\s+/).some(arg => arg === name || arg.endsWith('/' + name) || arg.endsWith('/' + name + '.js'))))
  }
  function hostTargets(h, action, before) {
    const main = before.components.find(c => c.id === 'runtime')
    const cli = before.components.find(c => c.id === 'signin') ?? main
    return { main, cli, needsCLI: !cli.path || (action === 'update' && cli.source === 'managed'),
      needsAdapter: Boolean(h.adapterPackage && (!main.installed || (action === 'update' && main.source === 'managed'))) }
  }
  async function hostMaintainedProcesses(h, action, before) {
    const { cli, needsCLI, needsAdapter } = hostTargets(h, action, before)
    const names = []
    if (needsCLI) names.push(...(h.id === 'opencode' ? openCodeCommands : [h.cliCommand ?? h.command]))
    if (needsAdapter) names.push(h.command)
    const components = before.components.filter(c => (needsCLI && c.id === cli.id) || (needsAdapter && ['runtime', 'bundled', 'engine'].includes(c.id)))
    for (const component of components) if (component.path) {
      names.push(component.path, await realpath(component.path).catch(() => component.path))
      const link = await readlink(component.path).catch(() => null)
      if (link) names.push(resolve(dirname(component.path), link))
    }
    return [...new Set(names.filter(Boolean))]
  }
  async function adapterPackageSpec(h, supplied) {
    const version = supplied?.startsWith(h.adapterPackage + '@') ? supplied.slice(h.adapterPackage.length + 1) : supplied ? null : await latest(h.adapterPackage)
    if (!version || !/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/.test(version)) throw failure('invalid_adapter_package_spec')
    if (precedes(version, h.minimumAdapterVersion)) throw failure('adapter_version_below_minimum')
    return h.adapterPackage + '@' + version
  }
  async function adapterInstallCommand(h, spec) {
    if (!h.minimumEngineVersion) return `${npm} install --global --prefix "$HOME/.local" ${quote(spec)}`
    const dependency = h.id === 'codex' ? '@openai/codex' : '@anthropic-ai/claude-agent-sdk'
    const engineVersion = await latest(dependency)
    if (!engineVersion || precedes(engineVersion, h.minimumEngineVersion)) throw failure('latest_engine_version_unavailable')
    const installedScript = resolve(configuration.serviceRoot, 'harnesses/install-adapter.mjs')
    const script = existsSync(installedScript) ? installedScript : fileURLToPath(new URL('../../harnesses/install-adapter.mjs', import.meta.url))
    const selection = { prefix: resolve(configuration.home, '.local'), adapter: h.adapterPackage,
      adapterVersion: spec.slice(h.adapterPackage.length + 1), engineVersion,
      npm: configuration.runtimeKind === 'host'
        ? [process.execPath, resolve(configuration.serviceRoot, 'tooling/lib/node_modules/npm/bin/npm-cli.js')] : ['npm'] }
    return `${quote(process.execPath)} ${quote(script)} ${quote(JSON.stringify(selection))}`
  }
  async function protectInstallDestination(command, component) {
    if (component?.source === 'managed') return
    const target = resolve(configuration.home, '.local/bin', command)
    try { await lstat(target) } catch (error) { if (error.code === 'ENOENT') return; throw error }
    throw failure('unmanaged_install_destination')
  }
  async function hostInstallation(h, action, body, before) {
    const commands = [], installedCommands = []
    const { main, cli, needsCLI, needsAdapter } = hostTargets(h, action, before)
    if (needsCLI) {
      await protectInstallDestination(h.cliCommand ?? h.command, cli)
      if (h.install?.kind === 'npm-global') {
        const pkg = validatedPackageSpec(h, body.packageSpec ?? (await npmPreview(h)).packageSpec)
        commands.push(`${npm} install --global --prefix "$HOME/.local" ${quote(pkg)}`)
      } else {
        if (typeof body.sourceSHA256 !== 'string') throw failure('source_digest_required')
        const installer = await verifiedInstaller(h, body.sourceSHA256)
        commands.push(`${quote(h.install.interpreter)} ${quote(installer.path)} ${(h.install.arguments ?? []).map(quote).join(' ')}`)
      }
      installedCommands.push(['signin', h.cliCommand ?? h.command])
      if (!h.adapterPackage) installedCommands.push(['runtime', h.command])
    }
    if (needsAdapter) {
      await protectInstallDestination(h.command, main)
      const spec = await adapterPackageSpec(h, body.adapterPackageSpec ?? (body.packageSpec?.startsWith(h.adapterPackage + '@') ? body.packageSpec : undefined))
      commands.push(await adapterInstallCommand(h, spec))
      installedCommands.push(['runtime', h.command])
    }
    if (!commands.length && action === 'update') throw failure('system_install_update_forbidden')
    return { command: commands.join(' && '), installedCommands }
  }
  async function refreshAdapterDependency(h) {
    if (h.minimumEngineVersion) return // The immutable consumer graph already verified both releases.
    // System adapter directories and their bundled engines are never mutated.
    const path = await commandPath(h.command)
    if (configuration.runtimeKind === 'host' && await componentSource(path) !== 'managed') return
    let root = null
    try { root = await packageRoot(dirname(await realpath(path)), h.adapterPackage) } catch {}
    const dependency = h.id === 'codex' ? '@openai/codex' : '@anthropic-ai/claude-agent-sdk'
    if (root && (await packageAt(root))?.dependencies?.[dependency]) {
      const refreshed = await run(`${npm} update --prefix ${quote(root)} --omit=dev --no-save --package-lock=false --registry=https://registry.npmjs.org ${quote(dependency)}`, 300000)
      if (refreshed.code !== 0) throw failure('bundled_dependency_refresh_failed')
    }
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
        unlock = await acquireLock(resolve(configuration.stateDirectory, 'runtime-operation.lock'), environment(), workspaceRoot)
        if (await busy(h, configuration.runtimeKind === 'host' ? [] : undefined)) throw failure('runtime_active_stop_conversations_or_server_first')
        const before = await inventory(h)
        const maintainedNames = configuration.runtimeKind === 'host' ? await hostMaintainedProcesses(h, action, before) : undefined
        if (configuration.runtimeKind === 'host' && await busy(h, maintainedNames)) throw failure('runtime_active_stop_conversations_or_server_first')
        let command, installedCommands = []
        if (configuration.runtimeKind === 'host') {
          ({ command, installedCommands } = await hostInstallation(h, action, body, before))
        } else {
          const pkg = h.install?.kind === 'npm-global' ? validatedPackageSpec(h, body.packageSpec ?? (await npmPreview(h)).packageSpec) : null
          const adapter = h.adapterPackage ? ' && ' + (h.minimumEngineVersion
            ? await adapterInstallCommand(h, await adapterPackageSpec(h))
            : `${npm} install --global --prefix "$HOME/.local" ${quote(h.adapterPackage + '@latest')}`) : ''
          if (pkg) command = `${npm} install --global --prefix "$HOME/.local" ${quote(pkg)}${adapter}`
          else {
            if (typeof body.sourceSHA256 !== 'string') throw failure('source_digest_required')
            const installer = await verifiedInstaller(h, body.sourceSHA256)
            command = `${quote(h.install.interpreter)} ${quote(installer.path)} ${(h.install.arguments ?? []).map(quote).join(' ')}${adapter}`
          }
        }
        if (await busy(h, maintainedNames)) throw failure('runtime_active_stop_conversations_or_server_first')
        const installation = async () => {
          if (command) {
            const result = await run(command, 300000)
            op.output = sanitize(result.output, environment())
            if (result.code !== 0) throw failure(`Installer exited ${result.code}. ${op.output}`)
          }
          // Record only explicit Woven installations. Existing ~/.local and mise
          // installations remain system-owned, even when sharing our PATH.
          for (const [id, name] of installedCommands) {
            const path = await commandPath(name)
            if (path) {
              s.managedComponents ??= {}
              s.managedComponents[id] = { path, target: await realpath(path).catch(() => path) }
            }
          }
          if (h.adapterPackage && (configuration.runtimeKind !== 'host' || installedCommands.some(([id]) => id === 'runtime'))) await refreshAdapterDependency(h)
        }
        if (configuration.runtimeKind === 'host') await withInstallerGuard(configuration.home, installation)
        else await installation()
        const after = await inventory(h)
        if (!after.installed) throw failure('Installer finished but required components could not be verified.')
        if (action === 'update' && before.components.some(c => c.source !== 'system' && precedes(c.installedVersion, updateTarget(c)) && precedes(after.components.find(a => a.id === c.id)?.installedVersion, updateTarget(c)))) throw failure('Update finished but a required component is still behind the checked version.')
        op.status = 'succeeded'; s.failureCount = 0
      } catch (error) { op.status = 'failed'; op.error = sanitize(error.message, environment()); s.failureCount += 1 }
      await persist().catch(() => { op.status = 'failed'; op.error = 'runtime_preferences_save_failed' })
      unlock?.(); op.finishedAt = new Date().toISOString()
    })()
    return op
  }
  async function npmPreview(h) {
    let packageSpec = h.install.package
    if (h.install?.kind === 'npm-global') {
      const name = packageSpec.slice(0, packageSpec.lastIndexOf('@'))
      const version = await latest(name)
      if (!version) throw failure('latest_package_version_unavailable')
      packageSpec = name + '@' + version
    }
    packageSpec = validatedPackageSpec(h, packageSpec)
    return { harnessID: h.id, source: h.install.source, sha256: null, bytes: null,
      packageSpec, command: `${npm} install --global --prefix "$HOME/.local" ${quote(packageSpec)}`,
      verification: 'npm-registry-integrity' }
  }
  return {
    inventory,
    npmPreview,
    async location(command) {
      await loaded
      const path = await commandPath(command)
      return { path, source: await componentSource(path) }
    },
    async hostAdapterPreview(h) {
      if (configuration.runtimeKind !== 'host' || !h.adapterPackage) return null
      const row = await inventory(h)
      const cli = row.components.find(c => c.id === 'signin')
      if (!cli?.path) return null
      const spec = await adapterPackageSpec(h)
      return { harnessID: h.id, source: 'https://registry.npmjs.org/' + h.adapterPackage,
        sha256: null, bytes: null, packageSpec: spec,
        command: await adapterInstallCommand(h, spec), verification: 'npm-registry-integrity' }
    },
    async recordFailure(h, action, error) {
      const s = await state(h.id)
      if (operations.get(h.id) && !operations.get(h.id).finishedAt) return
      s.failureCount += 1
      const now = new Date().toISOString()
      operations.set(h.id, { id: randomUUID(), harnessID: h.id, action, status: 'failed', output: '', error: sanitize(error.message, environment()), startedAt: now, finishedAt: now })
      await persist()
    },
    async isInstalled(id) {
      const harness = catalog.get(id)
      if (!harness) return false
      const current = await state(id)
      // Hot execution paths use the last verified inventory; refresh/install
      // updates it without spawning version probes for every API request.
      return current.installed ?? (await inventory(harness)).installed
    },
    isBusy(id) { return Boolean(operations.get(id) && !operations.get(id).finishedAt) },
    operation: id => { const op = [...operations.values()].find(op => op.id === String(id).toLowerCase()); return op && !op.finishedAt ? { ...op, status: 'running' } : op },
    start,
    async list() { return { runtimes: await Promise.all([...catalog.values()].map(h => inventory(h))) } },
    async check() {
      if (!checks) checks = (async () => ({ runtimes: await Promise.all([...catalog.values()].map(async h => {
        const current = await inventory(h)
        return current.installed ? inventory(h, true) : current
      })) }))().finally(() => { checks = null })
      return checks
    },
  }
}
