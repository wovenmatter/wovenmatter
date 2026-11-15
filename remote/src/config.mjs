import { existsSync } from 'node:fs'
import { homedir } from 'node:os'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

export const shellQuote = value => `'${String(value).replaceAll("'", "'\\''")}'`

// Installed hosts bundle default-agent beside this service; a checkout keeps it one level up.
export function defaultAgentModule(name) {
  const bundled = new URL('../default-agent/' + name, import.meta.url)
  return existsSync(bundled) ? bundled.href : new URL('../../default-agent/' + name, import.meta.url).href
}

// This is shared by the HTTP service, maintenance and host launch helpers. The
// service runs only on native hosts (remote-host.sh installs it as a systemd
// user unit).
export function loadRuntimeConfiguration(environment = process.env) {
  const home = environment.HOME ?? homedir()
  const serviceRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
  const accessMode = environment.WOVENMATTER_ACCESS_MODE ?? 'user'
  if (!['fullRoot', 'user'].includes(accessMode)) throw new Error('invalid_access_mode')
  const listenHost = environment.WOVENMATTER_LISTEN_HOST ?? '127.0.0.1'
  if (!['127.0.0.1', '::1'].includes(listenHost)) throw new Error('host_listener_must_be_loopback')
  const port = Number.parseInt(environment.WOVENMATTER_LISTEN_PORT ?? '', 10)
  const managedDataRoot = environment.WOVENMATTER_DATA_DIRECTORY ?? resolve(home, '.local/share/wovenmatter/databases')
  return Object.freeze({
    home, serviceRoot, accessMode, listenHost,
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
    // The Woven Matter version that shipped this host release (remote-host.sh reads it
    // from the bundle manifest); empty or missing for releases that predate it.
    releaseVersion: environment.WOVENMATTER_RELEASE_VERSION || null,
    // One server per machine: a Linux host may run bots with the workspace off.
    workspaceEnabled: environment.WOVENMATTER_WORKSPACE_ENABLED !== '0',
    botsEnabled: environment.WOVENMATTER_BOTS_ENABLED === '1',
    botsInstance: environment.WOVENMATTER_BOTS_INSTANCE ?? 'wovenmatter',
    botsData: environment.WOVENMATTER_BOTS_DATA ?? null,
  })
}

// Sessions often start from another device with nobody at this one, so a
// credential prompt must fail at once instead of hanging the session. The
// session-tools sudo runs the real sudo with -n (passwordless Full root still
// works); askpass refuses git/ssh prompts with a message. Keep this overlay in
// sync with remote/host/bin/wm-exec and the Mac's WovenSessionEnvironment.
export function sessionToolsDirectory(configuration = runtimeConfiguration) {
  return resolve(configuration.serviceRoot, 'host/session-tools')
}

export function nonInteractiveSessionEnvironment(environment = process.env, configuration = runtimeConfiguration) {
  const tools = sessionToolsDirectory(configuration)
  const askpass = resolve(tools, 'askpass')
  const paths = (environment.PATH ?? '').split(':').filter(path => path && path !== tools)
  return { ...environment, PATH: [tools, ...paths].join(':'),
    GIT_TERMINAL_PROMPT: '0', GCM_INTERACTIVE: 'never', GIT_ASKPASS: askpass,
    SSH_ASKPASS: askpass, SSH_ASKPASS_REQUIRE: 'force', SUDO_ASKPASS: askpass,
    DEBIAN_FRONTEND: 'noninteractive' }
}

export function runtimeHarnessEnvironment(environment = process.env, configuration = loadRuntimeConfiguration(environment)) {
  const paths = [resolve(configuration.home, '.local/bin'), resolve(configuration.home, '.npm-global/bin')]
  if (configuration.harnessPath) paths.push(configuration.harnessPath)
  paths.push(environment.PATH ?? '')
  return nonInteractiveSessionEnvironment({ ...environment, HOME: configuration.home, PATH: paths.join(':'), WOVENMATTER_WORKSPACE: configuration.workspaceRoot }, configuration)
}

// This is the release's patched npm, not Node's stock bundled npm or a user
// shim. Explicit Node also prevents npm's /usr/bin/env shebang selecting an
// unrelated runtime earlier in the user's harness PATH.
export function runtimeNPMInvocation(configuration = runtimeConfiguration, nodeExecutable = process.execPath) {
  return [nodeExecutable, resolve(configuration.serviceRoot, 'tooling/lib/node_modules/npm/bin/npm-cli.js')]
}

export function runtimeNPMCommand(configuration = runtimeConfiguration, nodeExecutable = process.execPath) {
  return runtimeNPMInvocation(configuration, nodeExecutable).map(shellQuote).join(' ')
}

// Each harness's native Full access mode. New sessions start here unless the
// user saved a different default; Full root workspaces always use it.
export const fullAccessPermissions = Object.freeze({ codex: 'agent-full-access', claude_code: 'bypassPermissions', grok_build: 'bypassPermissions', default_agent: 'full', opencode: 'allow' })

// Each harness's native auto mode, where it has one.
export const autoPermissions = Object.freeze({ codex: 'agent', claude_code: 'auto', grok_build: 'auto' })

// The only permission modes Woven Matter offers, in presentation order: Full
// access, then the harness's auto mode (`AgentRuntimeKind.supportedPermissions`).
// Ask for approval and every other native mode are not offered.
export function supportedPermissions(runtimeKind) {
  return [fullAccessPermissions[runtimeKind], autoPermissions[runtimeKind]].filter(Boolean)
}

// A saved or requested mode Woven no longer offers becomes Full access.
export function supportedPermission(runtimeKind, permission) {
  return permission == null || supportedPermissions(runtimeKind).includes(permission) ? permission : fullAccessPermissions[runtimeKind]
}

// The Mac's names and descriptions for native permission modes
// (`LocalACPSessionPermissions.nativeMetadata`); a mode it does not rename
// keeps its native name and description.
const permissionPresentation = Object.freeze({
  claude_code: { auto: ['Auto', "Claude's model classifier decides which actions may run automatically."] },
})
// Codex's agent preset is Approve for me only when the adapter also offers
// workspace-write or marks it as auto review. Older adapters used agent for
// workspace access, which Woven does not offer.
function codexAgentReviews(choices) {
  return choices.some(choice => choice.id === 'workspace-write' || choice.kind === 'auto_review')
}
function permissionMetadata(runtimeKind, item) {
  if (runtimeKind === 'codex' && item.id === 'agent') {
    return { ...item, label: 'Approve for me', description: 'Only ask for actions detected as potentially unsafe.' }
  }
  const [label, description] = permissionPresentation[runtimeKind]?.[item.id] ?? []
  const value = { ...item, ...(label ? { label } : {}) }
  if (description) value.description = description
  return value
}

// Present only the supported native modes the harness advertises: Full access
// (always labeled "Full access") first, then its auto mode. A choice may carry
// the native `description`; `kind` (the adapter's `_meta.kind`) is dropped.
export function presentPermissionChoices(runtimeKind, choices) {
  const supported = supportedPermissions(runtimeKind)
  const reviews = runtimeKind !== 'codex' || codexAgentReviews(choices)
  return choices.filter(item => supported.includes(item.id) && (reviews || item.id !== 'agent'))
    .sort((a, b) => supported.indexOf(a.id) - supported.indexOf(b.id))
    .map(item => {
      const value = permissionMetadata(runtimeKind, item)
      delete value.kind
      if (!value.description) delete value.description
      return item.id === fullAccessPermissions[runtimeKind] ? { ...value, label: 'Full access' } : value
    })
}

export function workspacePermission(runtimeKind, requested, configuration = runtimeConfiguration) {
  if (configuration.accessMode !== 'fullRoot') return requested
  return fullAccessPermissions[runtimeKind] ?? requested
}

// A saved permission Woven no longer offers runs as the product's Full access
// default, which inherits native policy when the adapter does not offer it.
export function workspaceExecutionConfiguration(value, configuration = runtimeConfiguration) {
  const supported = supportedPermission(value.runtimeKind, value.permission)
  if (supported !== value.permission) value = { ...value, permission: supported, usesProductPermissionDefault: true }
  const permission = workspacePermission(value.runtimeKind, value.permission, configuration)
  return configuration.accessMode === 'fullRoot'
    ? { ...value, permission, usesProductPermissionDefault: false } : value
}

export const runtimeConfiguration = loadRuntimeConfiguration()
