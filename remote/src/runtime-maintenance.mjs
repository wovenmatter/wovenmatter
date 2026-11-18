import { createRequire } from 'node:module'
import { existsSync, constants as fsConstants } from 'node:fs'
import { spawn } from 'node:child_process'
import { readFile, writeFile, mkdir, rename, realpath, access } from 'node:fs/promises'
import { dirname, resolve, sep } from 'node:path'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { supportsOpenCodeVersion, openCodeCommands } from './opencode-compatibility.mjs'
import { loadRuntimeConfiguration, runtimeNPMInvocation, shellQuote as quote, defaultAgentModule, acpAdapterPrefix, nativeCLILocation } from './config.mjs'

const { latestSupportedPackage } = await import(defaultAgentModule('src/package-versions.mjs'))
const failure = message => Object.assign(new Error(message), { statusCode: 409 })

// Each harness is the person's own native CLI, installed by its vendor's official
// installer and updated by the vendor's own command, so a terminal on this host
// uses the same CLI, logins, skills and sessions as Woven. Codex and Claude Code
// reach Woven through ACP adapters kept in Woven's folder; Grok speaks ACP
// itself; OpenCode is v2 only and runs as OpenCode's shared background service.
export const nativeHarnesses = Object.freeze({
  codex: { installer: { source: 'https://chatgpt.com/codex/install.sh', interpreter: 'sh', arguments: [] }, update: ['update'] },
  claude_code: { installer: { source: 'https://claude.ai/install.sh', interpreter: 'bash', arguments: ['latest'] }, update: ['update'] },
  grok_build: { installer: { source: 'https://x.ai/cli/install.sh', interpreter: 'bash', arguments: [] }, update: ['update'] },
  opencode: { installer: { source: 'https://opencode.ai/v2/install', interpreter: 'bash', arguments: [] }, update: ['upgrade'] },
})

/** The vendor's official installer: the catalog's when it names one, else the known one. */
export function nativeInstaller(harness) {
  const install = harness.install
  if (install?.kind === 'official-script' && typeof install.source === 'string' && ['sh', 'bash'].includes(install.interpreter)) {
    return { source: install.source, interpreter: install.interpreter, arguments: install.arguments ?? [] }
  }
  const known = nativeHarnesses[harness.id]?.installer
  if (!known) throw failure('native_installer_unavailable')
  return known
}

/** The vendor's own update subcommand: the catalog's `update.arguments` when present. */
export function nativeUpdateArguments(harness) {
  const fromCatalog = harness.update?.arguments
  if (Array.isArray(fromCatalog) && fromCatalog.length && fromCatalog.every(value => typeof value === 'string')) return fromCatalog
  const known = nativeHarnesses[harness.id]?.update
  if (!known) throw failure('native_update_unavailable')
  return known
}

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
// The only values an operation's `error` holds: fixed ids the apps map to their own
// words. What a command printed stays in the operation's sanitized `output`.
export const operationFailureCodes = Object.freeze([
  'update_failed', 'installer_failed', 'update_timed_out', 'install_timed_out',
  'update_verification_failed', 'installation_verification_failed',
  'runtime_active_stop_conversations_or_server_first', 'runtime_active_or_operation_in_progress', 'runtime_lock_unavailable',
  'installer_download_failed', 'installer_download_timed_out', 'invalid_installer_size', 'installer_https_required',
  'runtime_preferences_save_failed', 'system_install_update_forbidden',
  'opencode_v1_replacement_confirmation_required', 'opencode_service_restart_failed',
  'native_installer_unavailable', 'native_update_unavailable',
  'adapter_version_below_minimum', 'latest_engine_version_unavailable', 'latest_protocol_sdk_version_unavailable',
  'runtime_operation_failed',
])
export function diagnosticCategory(error) {
  const text = String(error ?? '')
  if (operationFailureCodes.includes(text)) return text
  // Records saved by older hosts held free text.
  if (text.startsWith('Installer exited ')) return 'installer_failed'
  if (text.startsWith('Update exited ')) return 'update_failed'
  if (text === 'Installer finished but required components could not be verified.') return 'installation_verification_failed'
  if (text === 'Update finished but a required component is still behind the checked version.') return 'update_verification_failed'
  return 'runtime_operation_failed'
}
export function sanitize(value, environment = {}) {
  let result = String(value ?? '').replace(/\x1b\[[0-9;]*[A-Za-z]/g, '')
  for (const [key, secret] of Object.entries(environment)) {
    if (/token|secret|password|api.?key/i.test(key) && typeof secret === 'string' && secret.length > 3) result = result.replaceAll(secret, '[redacted]')
  }
  return result.replace(/https?:\/\/\S+/gi, '[URL redacted]').replace(/(?:Bearer\s+|sk-|sk-ant-)[\w.-]+/gi, '[redacted]').replace(/((?:token|password|secret|api[_-]?key)\s*[=:]\s*)\S+/gi, '$1[redacted]').slice(-4096)
}
// Settles when the command exits, not when its pipes close: an installer or updater may
// leave a daemon holding them open, which must not keep the operation or its lock forever.
export function runHost(command, environment, cwd, timeout = 15000) {
  return new Promise(resolvePromise => {
    let output = '', settled = false, timedOut = false, grace = null
    const child = spawn('/bin/bash', ['-c', command], { env: environment, cwd, detached: true, stdio: ['ignore', 'pipe', 'pipe'] })
    const done = code => {
      if (settled) return
      settled = true; clearTimeout(timer); clearTimeout(grace)
      child.stdout.destroy(); child.stderr.destroy()
      resolvePromise({ code: timedOut ? -1 : code, output, timedOut })
    }
    const timer = setTimeout(() => { timedOut = true; try { process.kill(-child.pid, 'SIGKILL') } catch {} done(-1) }, timeout)
    child.stdout.on('data', data => { output = (output + data).slice(-65536) })
    child.stderr.on('data', data => { output = (output + data).slice(-65536) })
    child.on('error', () => done(-1))
    child.on('close', done)
    child.on('exit', code => { grace = setTimeout(() => done(code), 1000) })
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
/** One harness's maintenance lock. Different harnesses install and update side by side. */
export const harnessLockPath = (configuration, harnessID) => resolve(configuration.stateDirectory, `runtime-operation-${harnessID}.lock`)

async function packageAt(path) { try { return JSON.parse(await readFile(resolve(path, 'package.json'), 'utf8')) } catch { return null } }
async function packageRoot(path, name) {
  let directory = path
  for (let i = 0; i < 16; i++) {
    if ((await packageAt(directory))?.name === name) return directory
    if (dirname(directory) === directory) break
    directory = dirname(directory)
  }
  return null
}

export const claudeCodeNativeChannel = 'https://downloads.claude.ai/claude-code-releases/latest'
// The channels each vendor's official installer and update command read, which can trail npm.
const json = text => { try { return JSON.parse(text) } catch { return null } }
export const nativeChannels = {
  claude_code: { url: claudeCodeNativeChannel, read: text => normalizedVersion(text) },
  grok_build: { url: 'https://x.ai/cli/stable', read: text => normalizedVersion(text) },
  codex: { url: 'https://releases.openai.com/codex/channels/latest', read: text => { const tag = json(text)?.tag_name; return typeof tag === 'string' && tag.startsWith('rust-v') ? normalizedVersion(tag.slice(6)) : null } },
  opencode: { url: 'https://opencode.ai/update/api/latest/cli/npm', read: text => { const version = json(text)?.version; return typeof version === 'string' ? normalizedVersion(version) : null } },
}

// How long the vendor's own update and the official installer may run in the background.
const updateTimeout = 600_000
const installTimeout = 600_000

export function createRuntimeMaintenance({ catalog, workspaceRoot, environment, officialInstaller, hasActiveRuntime = async () => false, restartOpenCodeService = async () => {}, execute = runHost, fetchImplementation = fetch, acquireLock = acquireHostLock, configuration = loadRuntimeConfiguration(environment()) }) {
  const states = new Map(), operations = new Map()
  const statePath = resolve(workspaceRoot, '.wovenmatter/runtime-preferences.json')
  const adapterPrefix = acpAdapterPrefix(configuration)
  let saveQueue = Promise.resolve(), checks = null
  const loaded = readFile(statePath, 'utf8').then(text => {
    const saved = JSON.parse(text)
    for (const h of catalog.values()) states.set(h.id, { failureCount: Number(saved[h.id]?.failureCount) || 0 })
  }).catch(() => {})
  async function state(id) { await loaded; if (!states.has(id)) states.set(id, { failureCount: 0 }); return states.get(id) }
  function persist() {
    saveQueue = saveQueue.catch(() => {}).then(async () => {
      await mkdir(dirname(statePath), { recursive: true, mode: 0o700 })
      const data = Object.fromEntries([...states].map(([id, s]) => [id, { failureCount: s.failureCount }]))
      await writeFile(statePath + '.tmp', JSON.stringify(data), { mode: 0o600 }); await rename(statePath + '.tmp', statePath)
    }); return saveQueue
  }
  const run = (command, timeout) => execute(command, {
    ...environment(), npm_config_cache: resolve(workspaceRoot, '.wovenmatter/npm-cache'),
  }, workspaceRoot, timeout)
  const inside = (path, root) => path === root || path.startsWith(root + sep)
  // A CLI in the person's home is theirs to update with its vendor's command; one
  // elsewhere (a distribution package under /usr) belongs to the system. One in the
  // home that resolves into a node_modules tree is an older npm install (older Woven
  // hosts installed OpenCode that way): its vendor's updater would go back through
  // npm, so it is replaced with the official installer instead.
  async function componentSource(path, adapter = false) {
    if (!path) return 'missing'
    const target = await realpath(path).catch(() => path)
    if (adapter) return inside(target, configuration.home) || inside(path, configuration.home) ? 'managed' : 'system'
    if (!inside(path, configuration.home) && !inside(target, configuration.home)) return 'system'
    return [path, target].some(value => value.split(sep).includes('node_modules')) ? 'npm' : 'native'
  }
  async function commandPath(command) {
    // Where the official installer puts the CLI wins over an older copy earlier on PATH.
    const official = nativeCLILocation(command, configuration)
    if (official && await access(official, fsConstants.X_OK).then(() => true, () => false)) return official
    const found = await run(`command -v ${quote(command)}`)
    return found.code === 0 ? found.output.trim().split('\n')[0] : null
  }
  async function component(id, name, command, { adapter = false } = {}) {
    const path = await commandPath(command)
    const result = path ? await run(`${quote(path)} --version`) : null
    const version = result?.code === 0 ? normalizedVersion(result.output) : null
    return { id, displayName: name, path, source: await componentSource(path, adapter), installedVersion: version, latestVersion: null, required: true, installed: Boolean(path && version) }
  }
  async function latest(packageName) {
    try {
      return await latestSupportedPackage(packageName, { major: packageName === '@opencode/cli' ? 2 : undefined, fetchImplementation })
    } catch { return null }
  }
  // Release information only: the vendor's own updater does the updating.
  // Grok and Claude publish their native channel; `grok update` and `claude update` follow
  // it, and it can trail npm.
  async function latestCLI(h) {
    const channel = nativeChannels[h.id]
    if (!channel) return null
    try {
      const response = await fetchImplementation(channel.url, { signal: AbortSignal.timeout(10000) })
      if (!response.ok) return null
      const version = channel.read(await response.text())
      return version && (h.id !== 'opencode' || supportsOpenCodeVersion(version)) ? version : null
    } catch { return null }
  }
  /** OpenCode v2, under `opencode` or its `opencode2` alias, and any v1 `opencode` found. */
  async function openCode(h) {
    let v1 = null
    for (const command of [h.command, ...openCodeCommands.filter(value => value !== h.command)]) {
      const found = await component('runtime', 'OpenCode', command)
      if (supportsOpenCodeVersion(found.installedVersion)) return { main: found, v1 }
      if (found.path && found.installedVersion && !v1) v1 = { path: found.path, version: found.installedVersion }
    }
    return { main: { id: 'runtime', displayName: 'OpenCode', path: null, source: 'missing', installedVersion: null, latestVersion: null, required: true, installed: false }, v1 }
  }
  async function inventory(h, checkLatest = false) {
    const s = await state(h.id), previous = s.components ?? []
    let cli, adapter = null, openCodeV1 = null
    if (h.id === 'opencode') {
      const found = await openCode(h)
      cli = found.main; openCodeV1 = found.v1
    } else {
      cli = await component(h.adapterPackage ? 'cli' : 'runtime', h.cliCommand ?? h.command, h.cliCommand ?? h.command)
    }
    const components = [cli]
    if (h.adapterPackage) {
      adapter = await component('runtime', h.command, h.command, { adapter: true })
      adapter.displayName = h.command + ' (ACP connection)'
      // Woven installs the adapter; its own package version is the one that matters.
      let root = null
      try { root = adapter.path ? await packageRoot(dirname(await realpath(adapter.path)), h.adapterPackage) : null } catch {}
      const packaged = root ? normalizedVersion((await packageAt(root))?.version) : null
      if (packaged) adapter.installedVersion = packaged
      if (h.minimumAdapterVersion && precedes(adapter.installedVersion, h.minimumAdapterVersion)) adapter.installed = false
      components.push(adapter)
      // The ACP protocol SDK is selected by Woven at install. Claude ACP's Claude Agent SDK is
      // the adapter's own transport to the native CLI: it moves only with an adapter release.
      for (const [id, name, minimum] of [['protocol-sdk', '@agentclientprotocol/sdk', h.minimumProtocolSDKVersion]]) {
        if (!minimum) continue
        let installed = null
        try {
          const manifest = resolve(root, 'package.json')
          const paths = createRequire(manifest).resolve.paths(name)
          for (const path of paths) {
            const info = await packageAt(resolve(path, name))
            if (info) { installed = normalizedVersion(info.version); break }
          }
        } catch {}
        components.push({ id, displayName: name, path: adapter.path, source: adapter.source,
          installedVersion: installed, latestVersion: null, package: name, required: true,
          installed: installed !== null && !precedes(installed, minimum) })
      }
    } else if (h.transportCheckCommand && cli.installed) {
      const probe = await run(h.transportCheckCommand)
      components.push({ id: 'transport', displayName: h.transport + ' transport', path: cli.path, source: cli.source, installedVersion: cli.installedVersion, latestVersion: null, required: true, installed: probe?.code === 0 })
    }
    if (checkLatest) {
      cli.latestVersion = await latestCLI(h)
      if (adapter) adapter.latestVersion = await latest(h.adapterPackage)
      for (const c of components) if (c.package) c.latestVersion = await latest(c.package)
      s.versionCheckAvailable = components.filter(c => c.id !== 'transport').every(c => c.latestVersion !== null)
    } else for (const c of components) c.latestVersion = previous.find(p => p.id === c.id)?.latestVersion ?? null
    for (const c of components) c.updateAvailable = c.source === 'npm' || (c.id !== 'transport' && c.source !== 'system' && c.source !== 'missing' && precedes(c.installedVersion, c.latestVersion))
    s.components = components
    const storedOperation = operations.get(h.id) ?? null
    const operation = storedOperation && !storedOperation.finishedAt ? { ...storedOperation, status: 'running' } : storedOperation
    const installed = components.every(c => !c.required || c.installed)
    s.installed = installed
    let notice = h.id === 'opencode'
      ? (openCodeV1 && !cli.installed ? `OpenCode ${openCodeV1.version} (v1) is installed. Woven supports OpenCode v2; installing it replaces the v1 opencode command.` : null)
      : h.adapterPackage ? `Chats use this host's ${h.cliCommand} through its ACP connection.` : null
    if (cli.source === 'npm') notice = [notice, `${cli.displayName} was installed with npm. Updating replaces it with the official installer's copy.`].filter(Boolean).join(' ')
    if (checkLatest && components.some(c => c.id !== 'transport' && c.latestVersion === null)) notice = [notice, 'Latest version information is unavailable.'].filter(Boolean).join(' ')
    s.notice = notice
    return { id: h.id, displayName: h.displayName, source: cli.source, path: cli.path, installed, components, operation,
      ...(h.id === 'opencode' ? { openCodeV1 } : {}),
      failureCount: s.failureCount,
      diagnosticPrompt: s.failureCount >= 2 ? `Diagnose ${h.displayName} on this remote workspace host (${process.platform}/${process.arch}). Do not modify other hosts.\n${components.map(c => `${c.displayName}: installed=${c.installedVersion ?? 'unknown'} latest=${c.latestVersion ?? 'unknown'} verified=${c.installed}`).join('\n')}\nFailure: ${diagnosticCategory(operation?.error)}` : null,
      notice: s.notice, versionCheckAvailable: s.versionCheckAvailable ?? null, updateAvailable: components.some(c => c.updateAvailable) }
  }
  async function adapterInstallCommand(h) {
    const version = await latest(h.adapterPackage)
    if (!version || precedes(version, h.minimumAdapterVersion)) throw failure('adapter_version_below_minimum')
    // Preserve the adapter manifest, selecting only its ACP protocol SDK independently.
    // It is checked over ACP against the native CLI it
    // drives (CODEX_PATH / CLAUDE_CODE_EXECUTABLE, config.mjs); the CLI copy npm bundles
    // inside its package is never selected or used. A CLI installed in this same action
    // lands at the official location.
    const cli = (await commandPath(h.cliCommand)) ?? nativeCLILocation(h.cliCommand, configuration)
    const installedScript = resolve(configuration.serviceRoot, 'harnesses/install-adapter.mjs')
    const script = existsSync(installedScript) ? installedScript : fileURLToPath(new URL('../../harnesses/install-adapter.mjs', import.meta.url))
    const selection = { prefix: adapterPrefix, adapter: h.adapterPackage, adapterVersion: version, npm: runtimeNPMInvocation(configuration), ...(cli ? { cli } : {}) }
    if (h.minimumProtocolSDKVersion) {
      const sdk = await latest('@agentclientprotocol/sdk')
      if (!sdk || precedes(sdk, h.minimumProtocolSDKVersion)) throw failure('latest_protocol_sdk_version_unavailable')
      selection.protocolSDKVersion = sdk
    }
    return `${quote(process.execPath)} ${quote(script)} ${quote(JSON.stringify(selection))}`
  }
  /** The steps an action runs, each a background shell command with its own time limit. */
  async function plan(h, action, body, before) {
    const steps = []
    const cli = before.components.find(c => c.id === (h.adapterPackage ? 'cli' : 'runtime'))
    const adapter = h.adapterPackage ? before.components.find(c => c.id === 'runtime') : null
    const officialInstall = async () => {
      const installer = nativeInstaller(h)
      const file = await officialInstaller(h, installer.source)
      return { kind: 'install', command: `${quote(installer.interpreter)} ${quote(file)} ${installer.arguments.map(quote).join(' ')}`.trim(), timeout: installTimeout }
    }
    if (action === 'install') {
      if (!cli.installed) {
        if (h.id === 'opencode' && before.openCodeV1 && body.replaceOpenCodeV1 !== true) throw failure('opencode_v1_replacement_confirmation_required')
        steps.push(await officialInstall())
      } else if (cli.source === 'npm') steps.push(await officialInstall())
      if (adapter && adapter.source !== 'system' && (!adapter.installed || before.components.some(c => c.package && !c.installed))) steps.push({ kind: 'install', command: await adapterInstallCommand(h), timeout: installTimeout })
      return steps
    }
    // Update: the vendor's own command for the CLI, wherever its installer put it,
    // and a fresh adapter when a newer one is published. An npm copy gets the
    // official installer instead; the npm copy itself is left as it was.
    if (cli.installed && cli.source === 'npm') steps.push(await officialInstall())
    else if (cli.installed && cli.source === 'native' && (cli.updateAvailable || !cli.latestVersion)) {
      steps.push({ kind: 'update', command: [cli.path, ...nativeUpdateArguments(h)].map(quote).join(' '), timeout: updateTimeout })
    }
    if (adapter && adapter.source !== 'system' && (adapter.updateAvailable || before.components.some(c => c.package && (c.updateAvailable || !c.installed)))) steps.push({ kind: 'update', command: await adapterInstallCommand(h), timeout: installTimeout })
    if (!steps.length && cli.source === 'system') throw failure('system_install_update_forbidden')
    return steps
  }
  async function start(h, action, body) {
    if (body.confirmed !== true) throw failure('confirmation_required')
    const s = await state(h.id)
    if (operations.get(h.id) && !operations.get(h.id).finishedAt) return operations.get(h.id)
    // Reserve synchronously before awaits to prevent duplicate operations.
    const op = { id: randomUUID(), harnessID: h.id, action, status: 'running', output: '', error: null, startedAt: new Date().toISOString(), finishedAt: null }
    operations.set(h.id, op)
    void (async () => {
      let unlock
      try {
        unlock = await acquireLock(harnessLockPath(configuration, h.id), environment(), workspaceRoot)
        if (await hasActiveRuntime(h.id)) throw failure('runtime_active_stop_conversations_or_server_first')
        const before = await inventory(h)
        const steps = await plan(h, action, body, before)
        for (const step of steps) {
          const result = await run(step.command, step.timeout)
          op.output = sanitize([op.output, result.output].filter(Boolean).join('\n'), environment())
          if (result.timedOut) throw failure(step.kind === 'update' ? 'update_timed_out' : 'install_timed_out')
          if (result.code !== 0) throw failure(step.kind === 'update' ? 'update_failed' : 'installer_failed')
        }
        const after = await inventory(h)
        const afterCLI = after.components.find(c => c.id === (h.adapterPackage ? 'cli' : 'runtime'))
        if (!after.installed || (steps.some(step => step.kind === 'install') && afterCLI?.source === 'npm')) throw failure('installation_verification_failed')
        if (action === 'update') {
          // The updater's exit status isn't proof: each part that was behind must now be current.
          const behind = before.components.filter(c => c.updateAvailable)
          if (behind.some(c => precedes(after.components.find(a => a.id === c.id)?.installedVersion, c.latestVersion))) {
            throw failure('update_verification_failed')
          }
        }
        // The shared service keeps running the CLI it started with until it restarts.
        if (h.id === 'opencode' && steps.length && before.installed) {
          try { await restartOpenCodeService() } catch { throw failure('opencode_service_restart_failed') }
        }
        op.status = 'succeeded'; s.failureCount = 0
      } catch (error) { op.status = 'failed'; op.error = diagnosticCategory(error.message); s.failureCount += 1 }
      await persist().catch(() => { op.status = 'failed'; op.error = 'runtime_preferences_save_failed' })
      unlock?.(); op.finishedAt = new Date().toISOString()
    })()
    return op
  }
  return {
    inventory,
    async location(command) {
      await loaded
      const path = await commandPath(command)
      return { path, source: await componentSource(path) }
    },
    /** What an install would run, for apps that still show it before installing. */
    installPreview(h) {
      const installer = nativeInstaller(h)
      return { harnessID: h.id, source: installer.source, sha256: null, bytes: null, packageSpec: null,
        command: `curl -fsSL ${installer.source} | ${installer.interpreter}${installer.arguments.length ? ' -s -- ' + installer.arguments.join(' ') : ''}`,
        verification: 'official-installer' }
    },
    async recordFailure(h, action, error) {
      const s = await state(h.id)
      if (operations.get(h.id) && !operations.get(h.id).finishedAt) return
      s.failureCount += 1
      const now = new Date().toISOString()
      operations.set(h.id, { id: randomUUID(), harnessID: h.id, action, status: 'failed', output: '', error: diagnosticCategory(error.message), startedAt: now, finishedAt: now })
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
