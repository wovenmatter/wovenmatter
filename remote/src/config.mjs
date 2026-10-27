import { homedir } from 'node:os'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

// This is shared by the HTTP service, maintenance and host launch helpers. Keep
// container defaults stable: persisted volumes and older clients depend on them.
export function loadRuntimeConfiguration(environment = process.env, options = {}) {
  const home = environment.HOME ?? homedir()
  const serviceRoot = options.serviceRoot ?? resolve(dirname(fileURLToPath(import.meta.url)), '..')
  const runtimeKind = environment.WOVENMATTER_RUNTIME_KIND ?? 'container'
  const accessMode = environment.WOVENMATTER_ACCESS_MODE ?? 'user'
  if (!['container', 'host'].includes(runtimeKind)) throw new Error('invalid_runtime_kind')
  if (!['fullRoot', 'user'].includes(accessMode)) throw new Error('invalid_access_mode')
  const listenHost = environment.WOVENMATTER_LISTEN_HOST ?? '127.0.0.1'
  if (runtimeKind === 'host' && !['127.0.0.1', '::1'].includes(listenHost)) throw new Error('host_listener_must_be_loopback')
  const port = Number.parseInt(environment.WOVENMATTER_LISTEN_PORT ?? '', 10)
  const managedDataRoot = environment.WOVENMATTER_DATA_DIRECTORY ?? resolve(home, '.local/share/wovenmatter/databases')
  return Object.freeze({
    home, serviceRoot, runtimeKind, accessMode, listenHost,
    listenPort: Number.isInteger(port) && port > 0 && port <= 65535 ? port : 7337,
    apiToken: environment.WOVENMATTER_API_TOKEN ?? '',
    catalogPath: environment.WOVENMATTER_HARNESS_CATALOG ?? resolve(serviceRoot, 'harnesses/catalog.json'),
    workspaceRoot: environment.WOVENMATTER_WORKSPACE ?? resolve(home, '.woven-matter'),
    managedDataRoot,
    dataRoot: environment.WOVENMATTER_DATA_ROOT ?? resolve(managedDataRoot, '..'),
    stateDirectory: environment.WOVENMATTER_STATE_DIRECTORY ?? resolve(home, '.wovenmatter'),
    browserProfilesRoot: environment.WOVENMATTER_BROWSER_PROFILES ?? resolve(home, '.local/share/wovenmatter/browser-profiles'),
    legacyBrowserProfile: resolve(home, '.local/share/wovenmatter/browser'),
    harnessPath: environment.WOVENMATTER_HARNESS_PATH ?? '',
    serviceFingerprint: environment.WOVENMATTER_SERVICE_FINGERPRINT ?? null,
  })
}

export function runtimeHarnessEnvironment(environment = process.env, configuration = loadRuntimeConfiguration(environment)) {
  const paths = [resolve(configuration.home, '.local/bin'), resolve(configuration.home, '.npm-global/bin')]
  if (configuration.harnessPath) paths.push(configuration.harnessPath)
  paths.push(environment.PATH ?? '')
  return { ...environment, HOME: configuration.home, PATH: paths.join(':'), WOVENMATTER_WORKSPACE: configuration.workspaceRoot }
}

export function runtimeNPMCommand(configuration = runtimeConfiguration, nodeExecutable = process.execPath) {
  if (configuration.runtimeKind !== 'host') return 'npm'
  const quote = value => `'${String(value).replaceAll("'", "'\\''")}'`
  // This is the release's patched npm, not Node's stock bundled npm or a user
  // shim. Explicit Node also prevents npm's /usr/bin/env shebang selecting an
  // unrelated runtime earlier in the user's harness PATH.
  return [nodeExecutable, resolve(configuration.serviceRoot, 'tooling/lib/node_modules/npm/bin/npm-cli.js')].map(quote).join(' ')
}

export function workspacePermission(runtimeKind, requested, configuration = runtimeConfiguration) {
  if (configuration.runtimeKind !== 'host' || configuration.accessMode !== 'fullRoot') return requested
  return { codex: 'agent-full-access', claude_code: 'bypassPermissions', grok_build: 'bypassPermissions', default_agent: 'full', opencode: 'allow' }[runtimeKind] ?? requested
}

export function workspaceExecutionConfiguration(value, configuration = runtimeConfiguration) {
  const permission = workspacePermission(value.runtimeKind, value.permission, configuration)
  return configuration.runtimeKind === 'host' && configuration.accessMode === 'fullRoot'
    ? { ...value, permission, usesProductPermissionDefault: false } : value
}

export const runtimeConfiguration = loadRuntimeConfiguration()
