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

// This is shared by the HTTP service, maintenance and host launch helpers. Keep
// container defaults stable: persisted volumes and older clients depend on them.
export function loadRuntimeConfiguration(environment = process.env) {
  const home = environment.HOME ?? homedir()
  const serviceRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..')
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

export function runtimeNPMCommand(configuration = runtimeConfiguration, nodeExecutable = process.execPath) {
  if (configuration.runtimeKind !== 'host') return 'npm'
  // This is the release's patched npm, not Node's stock bundled npm or a user
  // shim. Explicit Node also prevents npm's /usr/bin/env shebang selecting an
  // unrelated runtime earlier in the user's harness PATH.
  return [nodeExecutable, resolve(configuration.serviceRoot, 'tooling/lib/node_modules/npm/bin/npm-cli.js')].map(shellQuote).join(' ')
}

// Each harness's native Full access mode. New sessions start here unless the
// user saved a different default; Full root workspaces always use it.
export const fullAccessPermissions = Object.freeze({ codex: 'agent-full-access', claude_code: 'bypassPermissions', grok_build: 'bypassPermissions', default_agent: 'full', opencode: 'allow' })

const autoApprovePermissions = Object.freeze({ codex: ['agent'], claude_code: ['auto', 'acceptEdits'], grok_build: ['auto', 'acceptEdits'] })
const askPermissions = Object.freeze({ codex: ['workspace-write'], claude_code: ['default'], grok_build: ['default'], opencode: ['ask'], default_agent: ['ask'] })

// The Mac's names and descriptions for native permission modes
// (`LocalACPSessionPermissions.nativeMetadata`); a mode it does not rename
// keeps its native name and description.
const permissionPresentation = Object.freeze({
  codex: { 'read-only': ['Read only', "Codex's native read-only sandbox and approval policy.", true],
    'agent-full-access': ['Full access'] },
  claude_code: { default: ['Ask for approval'], bypassPermissions: ['Full access'],
    auto: ['Auto', "Claude's model classifier decides which actions may run automatically."], acceptEdits: ['Auto-accept edits'],
    plan: ['Plan', 'Plan without executing commands or editing files.', true],
    dontAsk: ["Don't ask", 'Deny actions requiring permission instead of asking for approval.', true] },
})
function permissionMetadata(runtimeKind, item, choices) {
  if (runtimeKind === 'codex' && item.id === 'agent') {
    // Codex's agent preset auto-reviews unsafe actions when the adapter offers it.
    const reviewed = choices.some(choice => choice.id === 'workspace-write' || choice.kind === 'auto_review')
    return reviewed ? { ...item, label: 'Approve for me', description: 'Only ask for actions detected as potentially unsafe.' }
      : { ...item, label: 'Workspace access', description: "Use Codex's workspace access preset with its native approval and sandbox rules." }
  }
  const [label, description, fallback] = permissionPresentation[runtimeKind]?.[item.id] ?? []
  const value = { ...item, ...(label ? { label } : {}) }
  if (description && (!fallback || !item.description)) value.description = description
  return value
}

// Present native permission modes as Full access first, then the harness's
// auto-approve modes, then its other modes, with ask-for-approval last. Every
// Full access mode is labeled "Full access"; the others keep native names
// unless the Mac names them (`permissionMetadata`). A choice may carry the
// native `description`; `kind` (the adapter's `_meta.kind`) is dropped.
export function presentPermissionChoices(runtimeKind, choices) {
  const rank = id => id === fullAccessPermissions[runtimeKind] ? 0
    : autoApprovePermissions[runtimeKind]?.includes(id) ? 1
    : askPermissions[runtimeKind]?.includes(id) ? 3 : 2
  return choices.map((item, index) => ({ item, index }))
    .sort((a, b) => rank(a.item.id) - rank(b.item.id) || a.index - b.index)
    .map(({ item }) => {
      const value = permissionMetadata(runtimeKind, item, choices)
      delete value.kind
      if (!value.description) delete value.description
      return item.id === fullAccessPermissions[runtimeKind] ? { ...value, label: 'Full access' } : value
    })
}

export function workspacePermission(runtimeKind, requested, configuration = runtimeConfiguration) {
  if (configuration.runtimeKind !== 'host' || configuration.accessMode !== 'fullRoot') return requested
  return fullAccessPermissions[runtimeKind] ?? requested
}

export function workspaceExecutionConfiguration(value, configuration = runtimeConfiguration) {
  const permission = workspacePermission(value.runtimeKind, value.permission, configuration)
  return configuration.runtimeKind === 'host' && configuration.accessMode === 'fullRoot'
    ? { ...value, permission, usesProductPermissionDefault: false } : value
}

export const runtimeConfiguration = loadRuntimeConfiguration()
