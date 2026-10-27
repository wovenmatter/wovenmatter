import test from 'node:test'
import assert from 'node:assert/strict'
import { loadRuntimeConfiguration, runtimeHarnessEnvironment, runtimeNPMCommand, workspacePermission, workspaceExecutionConfiguration } from '../src/config.mjs'

test('configuration defaults reproduce existing container paths and listener', () => {
  const value = loadRuntimeConfiguration({ HOME: '/home', PATH: '/usr/bin:/bin' }, { serviceRoot: '/opt/wovenmatter' })
  assert.equal(value.runtimeKind, 'container')
  assert.equal(value.workspaceRoot, '/home/.woven-matter')
  assert.equal(value.managedDataRoot, '/home/.local/share/wovenmatter/databases')
  assert.equal(value.stateDirectory, '/home/.wovenmatter')
  assert.equal(value.legacyBrowserProfile, '/home/.local/share/wovenmatter/browser')
  assert.equal(value.browserProfilesRoot, '/home/.local/share/wovenmatter/browser-profiles')
  assert.equal(value.catalogPath, '/opt/wovenmatter/harnesses/catalog.json')
  assert.equal(value.listenHost, '127.0.0.1'); assert.equal(value.listenPort, 7337)
  assert.equal(value.serviceFingerprint, null)
  assert.equal(runtimeHarnessEnvironment({ HOME: '/home', PATH: '/usr/bin:/bin' }, value).PATH,
    '/home/.local/bin:/home/.npm-global/bin:/usr/bin:/bin')
  assert.equal(loadRuntimeConfiguration({ HOME: '/home', WOVENMATTER_LISTEN_HOST: '0.0.0.0' }).listenHost, '0.0.0.0')
})

test('host overrides share paths, fingerprint, access and managed PATH precedence', () => {
  const environment = {
    HOME: '/home/alex', PATH: '/usr/bin:/bin', WOVENMATTER_RUNTIME_KIND: 'host', WOVENMATTER_ACCESS_MODE: 'fullRoot',
    WOVENMATTER_WORKSPACE: '/srv/dev', WOVENMATTER_DATA_DIRECTORY: '/srv/woven/databases',
    WOVENMATTER_DATA_ROOT: '/srv/woven', WOVENMATTER_STATE_DIRECTORY: '/srv/woven/run',
    WOVENMATTER_BROWSER_PROFILES: '/srv/woven/profiles', WOVENMATTER_HARNESS_PATH: '/home/alex/.local/share/mise/shims:/opt/tools/bin',
    WOVENMATTER_SERVICE_FINGERPRINT: 'a'.repeat(64), WOVENMATTER_LISTEN_PORT: '7441',
    WOVENMATTER_HARNESS_CATALOG: '/srv/woven/current/harnesses/catalog.json',
  }
  const value = loadRuntimeConfiguration(environment)
  assert.equal(value.workspaceRoot, '/srv/dev'); assert.equal(value.managedDataRoot, '/srv/woven/databases')
  assert.equal(value.dataRoot, '/srv/woven'); assert.equal(value.stateDirectory, '/srv/woven/run')
  assert.equal(value.browserProfilesRoot, '/srv/woven/profiles'); assert.equal(value.accessMode, 'fullRoot')
  assert.equal(value.listenPort, 7441); assert.equal(value.serviceFingerprint, 'a'.repeat(64))
  assert.equal(value.catalogPath, '/srv/woven/current/harnesses/catalog.json')
  const child = runtimeHarnessEnvironment(environment, value)
  assert.equal(child.PATH, '/home/alex/.local/bin:/home/alex/.npm-global/bin:/home/alex/.local/share/mise/shims:/opt/tools/bin:/usr/bin:/bin')
  assert.equal(child.WOVENMATTER_WORKSPACE, '/srv/dev')
})

test('host listener and configuration enum validation fail closed', () => {
  assert.throws(() => loadRuntimeConfiguration({ WOVENMATTER_RUNTIME_KIND: 'other' }), /invalid_runtime_kind/)
  assert.throws(() => loadRuntimeConfiguration({ WOVENMATTER_ACCESS_MODE: 'sudo' }), /invalid_access_mode/)
  for (const address of ['0.0.0.0', '::', 'localhost', 'remote.invalid']) {
    assert.throws(() => loadRuntimeConfiguration({ WOVENMATTER_RUNTIME_KIND: 'host', WOVENMATTER_LISTEN_HOST: address }), /loopback/)
  }
  assert.equal(loadRuntimeConfiguration({ WOVENMATTER_RUNTIME_KIND: 'host', WOVENMATTER_LISTEN_HOST: '::1' }).listenHost, '::1')
  for (const port of ['0', '-1', '65536', 'invalid']) assert.equal(loadRuntimeConfiguration({ WOVENMATTER_LISTEN_PORT: port }).listenPort, 7337)
})

test('full-root workspace policy selects native nonprompting modes and overrides stale saved approvals', () => {
  const root = loadRuntimeConfiguration({ WOVENMATTER_RUNTIME_KIND: 'host', WOVENMATTER_ACCESS_MODE: 'fullRoot' })
  for (const [runtimeKind, permission] of Object.entries({ codex: 'agent-full-access', claude_code: 'bypassPermissions', grok_build: 'bypassPermissions', default_agent: 'full', opencode: 'allow' })) {
    assert.equal(workspacePermission(runtimeKind, 'ask', root), permission)
    assert.deepEqual(workspaceExecutionConfiguration({ runtimeKind, permission: 'ask', model: 'unchanged', usesProductPermissionDefault: true }, root),
      { runtimeKind, permission, model: 'unchanged', usesProductPermissionDefault: false })
  }
  for (const environment of [{}, { WOVENMATTER_RUNTIME_KIND: 'host', WOVENMATTER_ACCESS_MODE: 'user' }]) {
    assert.equal(workspacePermission('codex', 'saved', loadRuntimeConfiguration(environment)), 'saved')
  }
})

test('host npm uses the pinned Node and patched private release CLI without changing harness PATH precedence', () => {
  const environment = { HOME: '/home/alex', PATH: '/usr/local/bin:/usr/bin', WOVENMATTER_RUNTIME_KIND: 'host' }
  const configuration = loadRuntimeConfiguration(environment, { serviceRoot: '/home/alex/.local/share/wovenmatter/releases/abc' })
  assert.equal(runtimeNPMCommand(configuration, '/home/alex/.local/share/wovenmatter/node/26.12.1/bin/node'),
    "'/home/alex/.local/share/wovenmatter/node/26.12.1/bin/node' '/home/alex/.local/share/wovenmatter/releases/abc/tooling/lib/node_modules/npm/bin/npm-cli.js'")
  assert.equal(runtimeHarnessEnvironment(environment, configuration).PATH, '/home/alex/.local/bin:/home/alex/.npm-global/bin:/usr/local/bin:/usr/bin')
  assert.equal(runtimeNPMCommand(loadRuntimeConfiguration({ HOME: '/home' })), 'npm')
})
