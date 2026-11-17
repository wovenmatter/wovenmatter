import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, mkdir, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { createRuntimeMaintenance, sanitize, nativeInstaller, nativeUpdateArguments } from '../src/runtime-maintenance.mjs'
import { loadRuntimeConfiguration } from '../src/config.mjs'

const registryMetadata = version => ({ versions: { [version]: {} }, 'dist-tags': { latest: version } })
const opencode = { id: 'opencode', displayName: 'OpenCode', command: 'opencode', cliCommand: 'opencode', install: { kind: 'npm-global', package: '@opencode/cli@2' } }
const claude = { id: 'claude_code', displayName: 'Claude Code', command: 'claude-agent-acp', cliCommand: 'claude', adapterPackage: '@agentclientprotocol/claude-agent-acp',
  install: { kind: 'official-script', source: 'https://claude.ai/install.sh', interpreter: 'bash', arguments: ['latest'] } }
const grok = { id: 'grok_build', displayName: 'Grok Build', command: 'grok', cliCommand: 'grok', install: { kind: 'official-script', source: 'https://x.ai/cli/install.sh', interpreter: 'bash', arguments: [] } }

/**
 * A fake host: `commands` maps a command name to { path, version } (absent when not
 * installed). `on(command)` may handle installer and updater commands.
 */
async function fixture(t, { catalog = [opencode], commands = {}, on = () => null, latest = '2.1.1', ...overrides } = {}) {
  const root = await mkdtemp(resolve(tmpdir(), 'wm-maintenance-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const calls = [], installers = []
  const configuration = loadRuntimeConfiguration({ HOME: root, WOVENMATTER_STATE_DIRECTORY: resolve(root, 'run') })
  const options = {
    acquireLock: async () => () => {}, catalog: new Map(catalog.map(h => [h.id, h])), workspaceRoot: root, configuration,
    environment: () => ({ HOME: root, SECRET_TOKEN: 'very-secret-token' }),
    officialInstaller: async (h, source) => { installers.push([h.id, source]); return resolve(root, `.wovenmatter/installers/${h.id}.sh`) },
    execute: async (command, env, cwd, timeout) => {
      assert.equal(cwd, root); assert.equal(env.HOME, root); calls.push([command, timeout])
      const handled = await on(command, { root, commands })
      if (handled) return handled
      const which = command.match(/^command -v '([^']+)'$/)
      if (which) return commands[which[1]] ? { code: 0, output: commands[which[1]].path } : { code: 1, output: '' }
      const version = command.match(/^'([^']+)' --version$/)
      if (version) {
        const found = Object.values(commands).find(value => value.path === version[1])
        return found ? { code: 0, output: found.version } : { code: 127, output: '' }
      }
      throw Error('Unexpected command: ' + command)
    },
    fetchImplementation: async () => ({ ok: true, json: async () => registryMetadata(latest), text: async () => latest }),
    ...overrides,
  }
  return { root, configuration, calls, installers, commands, options, service: createRuntimeMaintenance(options) }
}
async function finished(service, id) {
  for (let i = 0; i < 200; i++) {
    const value = (await service.list()).runtimes.find(row => !id || row.id === id)
    if (value.operation?.status !== 'running') return value
    await new Promise(r => setTimeout(r, 5))
  }
  throw Error('operation timeout')
}

test('a missing OpenCode installs with its official v2 installer, never npm or a digest review', async t => {
  const f = await fixture(t, {
    on: (command, { root, commands }) => {
      if (command.startsWith("'bash' ")) { commands.opencode = { path: resolve(root, '.opencode/bin/opencode'), version: 'opencode v2.1.0' }; return { code: 0, output: 'installed' } }
    },
  })
  assert.equal(await f.service.isInstalled('opencode'), false)
  await f.service.start(opencode, 'install', { confirmed: true })
  const installed = await finished(f.service)
  assert.equal(installed.operation.status, 'succeeded')
  assert.equal(installed.installed, true)
  assert.equal(installed.source, 'native')
  assert.deepEqual(f.installers, [['opencode', 'https://opencode.ai/v2/install']])
  const install = f.calls.find(([command]) => command.startsWith("'bash' "))
  assert.equal(install[0], `'bash' '${resolve(f.root, '.wovenmatter/installers/opencode.sh')}'`)
  assert.equal(install[1], 300000)
  assert.equal(f.calls.some(([command]) => /npm/.test(command)), false)
  const calls = f.calls.length
  assert.equal(await f.service.isInstalled('opencode'), true)
  assert.equal(f.calls.length, calls, 'execution checks reuse verified inventory')
  const preview = f.service.installPreview(opencode)
  assert.equal(preview.sha256, null); assert.equal(preview.packageSpec, null); assert.equal(preview.verification, 'official-installer')
})

test('OpenCode v1 is never replaced silently: installing v2 needs the person to agree', async t => {
  const f = await fixture(t, {
    commands: { opencode: { path: '/home/fixture/.opencode/bin/opencode', version: '1.19.5' } },
    on: (command, { commands }) => {
      if (command.startsWith("'bash' ")) { commands.opencode = { path: commands.opencode.path, version: 'opencode v2.1.0' }; return { code: 0, output: '' } }
    },
  })
  const before = await f.service.inventory(opencode)
  assert.deepEqual(before.openCodeV1, { path: '/home/fixture/.opencode/bin/opencode', version: '1.19.5' })
  assert.equal(before.installed, false)
  assert.match(before.notice, /replaces the v1 opencode command/)
  await f.service.start(opencode, 'install', { confirmed: true })
  assert.equal((await finished(f.service)).operation.error, 'opencode_v1_replacement_confirmation_required')
  assert.deepEqual(f.installers, [])
  await f.service.start(opencode, 'install', { confirmed: true, replaceOpenCodeV1: true })
  const replaced = await finished(f.service)
  assert.equal(replaced.operation.status, 'succeeded')
  assert.equal(replaced.openCodeV1, null)
})

test('the OpenCode v2 alias is used when opencode itself is v1', async t => {
  const f = await fixture(t, { commands: {
    opencode: { path: '/usr/bin/opencode', version: '1.19.5' },
    opencode2: { path: '/home/fixture/.npm-global/bin/opencode2', version: 'opencode v2.2.7' },
  } })
  const row = await f.service.inventory(opencode)
  assert.equal(row.installed, true)
  assert.equal(row.path, '/home/fixture/.npm-global/bin/opencode2')
})

test('updates run the vendor command where its installer put the CLI, then prove the version moved', async t => {
  let version = '1.0.77'
  const f = await fixture(t, { catalog: [grok], latest: '1.0.88', on: (command, { root }) => {
    if (command === `'${resolve(root, '.grok/bin/grok')}' 'update'`) { version = '1.0.88'; return { code: 0, output: 'Updated' } }
    if (command === 'grok agent stdio --help') return { code: 0, output: '' }
  } })
  f.commands.grok = { path: resolve(f.root, '.grok/bin/grok'), get version() { return 'grok ' + version } }
  const grokWithTransport = { ...grok, transportCheckCommand: 'grok agent stdio --help' }
  const service = createRuntimeMaintenance({ ...f.options, catalog: new Map([['grok_build', grokWithTransport]]) })
  const checked = await service.inventory(grokWithTransport, true)
  assert.equal(checked.source, 'native')
  assert.equal(checked.updateAvailable, true)
  await service.start(grokWithTransport, 'update', { confirmed: true })
  const updated = await finished(service)
  assert.equal(updated.operation.status, 'succeeded')
  const update = f.calls.find(([command]) => command.endsWith("'update'"))
  assert.equal(update[1], 180000, 'the vendor update has a short background time limit')
  assert.deepEqual(f.installers, [], 'an update never reinstalls')
})

test('an updater that exits 0 without changing the version fails the update', async t => {
  const f = await fixture(t, { catalog: [grok], latest: '1.0.88', on: command => {
    if (command.endsWith("'update'")) return { code: 0, output: 'Updated to 1.0.88. Restart Grok to use it.' }
  } })
  f.commands.grok = { path: resolve(f.root, '.local/bin/grok'), version: 'grok 1.0.77' }
  await f.service.inventory(grok, true)
  await f.service.start(grok, 'update', { confirmed: true })
  const result = await finished(f.service)
  assert.equal(result.operation.status, 'failed')
  assert.equal(result.operation.error, 'Update finished but a required component is still behind the checked version.')
})

test('a stalled updater is stopped at its time limit and reported', async t => {
  const f = await fixture(t, { catalog: [grok], latest: '1.0.88', on: command => {
    if (command.endsWith("'update'")) return { code: -1, output: '', timedOut: true }
  } })
  f.commands.grok = { path: resolve(f.root, '.grok/bin/grok'), version: 'grok 1.0.77' }
  await f.service.inventory(grok, true)
  await f.service.start(grok, 'update', { confirmed: true })
  assert.equal((await finished(f.service)).operation.error, 'update_timed_out')
})

test('OpenCode upgrades with its own command and restarts the shared service onto it', async t => {
  let version = '2.2.7', restarts = 0
  const f = await fixture(t, { latest: '2.3.0', on: (command, { root }) => {
    if (command === `'${resolve(root, '.opencode/bin/opencode')}' 'upgrade'`) { version = '2.3.0'; return { code: 0, output: '' } }
  }, restartOpenCodeService: async () => { restarts++ } })
  f.commands.opencode = { path: resolve(f.root, '.opencode/bin/opencode'), get version() { return 'opencode v' + version } }
  const service = createRuntimeMaintenance({ ...f.options, restartOpenCodeService: async () => { restarts++ } })
  await service.inventory(opencode, true)
  await service.start(opencode, 'update', { confirmed: true })
  const result = await finished(service)
  assert.equal(result.operation.status, 'succeeded')
  assert.equal(restarts, 1)
})

test('a CLI outside the home folder belongs to the system and is not updated', async t => {
  const f = await fixture(t, { latest: '2.3.0', commands: { opencode: { path: '/usr/bin/opencode', version: 'opencode v2.2.7' } } })
  const checked = await f.service.inventory(opencode, true)
  assert.equal(checked.source, 'system')
  assert.equal(checked.updateAvailable, false)
  await f.service.start(opencode, 'update', { confirmed: true })
  assert.equal((await finished(f.service)).operation.error, 'system_install_update_forbidden')
})

test('each harness has its own lock, so different harnesses update side by side', async t => {
  const locks = [], held = new Set()
  let overlapped = false, releaseFirst
  const gate = new Promise(done => { releaseFirst = done })
  const f = await fixture(t, { catalog: [grok, opencode], latest: '9.9.9', on: async command => {
    if (command.endsWith("'update'") || command.endsWith("'upgrade'")) {
      held.add(command); if (held.size === 2) { overlapped = true; releaseFirst() }
      await gate; return { code: 0, output: '' }
    }
  } })
  f.commands.grok = { path: resolve(f.root, '.grok/bin/grok'), version: 'grok 1.0.0' }
  f.commands.opencode = { path: resolve(f.root, '.opencode/bin/opencode'), version: 'opencode v2.0.0' }
  const service = createRuntimeMaintenance({ ...f.options, acquireLock: async path => { locks.push(path); return () => {} } })
  await service.inventory(grok, true); await service.inventory(opencode, true)
  await Promise.all([service.start(grok, 'update', { confirmed: true }), service.start(opencode, 'update', { confirmed: true })])
  await finished(service, 'grok_build'); await finished(service, 'opencode')
  assert.equal(overlapped, true)
  assert.deepEqual(locks.sort(), [resolve(f.root, 'run/runtime-operation-grok_build.lock'), resolve(f.root, 'run/runtime-operation-opencode.lock')])
})

test('Claude Code installs the native CLI and its ACP connection in Woven’s folder', async t => {
  const f = await fixture(t, { catalog: [claude], latest: '0.200.0', on: (command, { root, commands }) => {
    if (command.startsWith("'bash' ")) { commands.claude = { path: resolve(root, '.local/bin/claude'), version: '2.1.322 (Claude Code)' }; return { code: 0, output: '' } }
    if (command.includes('install-adapter.mjs')) {
      const selection = JSON.parse(command.slice(command.lastIndexOf(" '") + 2, -1))
      assert.equal(selection.prefix, resolve(root, '.local/share/wovenmatter/acp-adapters'))
      assert.equal(selection.adapter, '@agentclientprotocol/claude-agent-acp')
      commands['claude-agent-acp'] = { path: resolve(root, '.local/share/wovenmatter/acp-adapters/bin/claude-agent-acp'), version: '0.200.0' }
      return { code: 0, output: '' }
    }
  } })
  await f.service.start(claude, 'install', { confirmed: true })
  const result = await finished(f.service)
  assert.equal(result.operation.status, 'succeeded')
  assert.deepEqual(f.installers, [['claude_code', 'https://claude.ai/install.sh']])
  assert.ok(f.calls.some(([command]) => command.endsWith(`'${resolve(f.root, '.wovenmatter/installers/claude_code.sh')}' 'latest'`)))
  assert.equal(result.components.find(c => c.id === 'cli').source, 'native')
  assert.equal(result.components.find(c => c.id === 'runtime').source, 'managed')
  // An installed CLI is never reinstalled when only the connection is missing.
  delete f.commands['claude-agent-acp']
  f.installers.length = 0
  await f.service.start(claude, 'install', { confirmed: true })
  assert.equal((await finished(f.service)).operation.status, 'succeeded')
  assert.deepEqual(f.installers, [])
})

test('active work blocks changes; two failures give an allowlisted diagnostic', async t => {
  const f = await fixture(t, { hasActiveRuntime: async () => true })
  await f.service.start(opencode, 'install', { confirmed: true }); await finished(f.service)
  await f.service.start(opencode, 'install', { confirmed: true }); const value = await finished(f.service)
  assert.deepEqual(f.installers, []); assert.equal(value.failureCount, 2)
  assert.match(value.diagnosticPrompt, /OpenCode.*remote workspace host/)
  assert.match(value.diagnosticPrompt, /runtime_active/)
  assert.equal(sanitize('very-secret-token https://secret.example/?token=x Bearer abc123', { SECRET_TOKEN: 'very-secret-token' }), '[redacted] [URL redacted] [redacted]')
  const secret = '/home/private-account/project confidential-provider-response'
  await f.service.recordFailure(opencode, 'install', new Error('Installer exited 1. ' + secret))
  const result = (await f.service.list()).runtimes[0]
  assert.match(result.diagnosticPrompt, /Failure: installer_failed/)
  assert.doesNotMatch(result.diagnosticPrompt, /private-account|confidential/)
})

test('duplicate operations share one reservation', async t => {
  const f = await fixture(t, { on: (command, { root, commands }) => {
    if (command.startsWith("'bash' ")) { commands.opencode = { path: resolve(root, '.opencode/bin/opencode'), version: '2.1.0' }; return { code: 0, output: '' } }
  } })
  const [a, b] = await Promise.all([f.service.start(opencode, 'install', { confirmed: true }), f.service.start(opencode, 'install', { confirmed: true })])
  assert.equal(a.id, b.id)
  assert.equal((await f.service.operation(a.id.toUpperCase())).id, a.id)
  assert.equal((await finished(f.service)).operation.status, 'succeeded')
  assert.equal(f.installers.length, 1)
})

test('older preference files keep their failure counts and nothing else', async t => {
  const f = await fixture(t, { commands: { opencode: { path: '/home/x/.opencode/bin/opencode', version: '2.1.0' } } })
  await mkdir(resolve(f.root, '.wovenmatter'), { recursive: true })
  await writeFile(resolve(f.root, '.wovenmatter/runtime-preferences.json'), JSON.stringify({
    opencode: { enabled: false, visible: false, failureCount: 2, managedComponents: { runtime: { path: '/x', target: '/x' } } },
  }))
  const service = createRuntimeMaintenance(f.options)
  assert.equal(await service.isInstalled('opencode'), true)
  assert.equal((await service.list()).runtimes[0].failureCount, 2)
  await service.recordFailure(opencode, 'install', new Error('fixture'))
  const saved = JSON.parse(await readFile(resolve(f.root, '.wovenmatter/runtime-preferences.json'), 'utf8'))
  assert.deepEqual(saved.opencode, { failureCount: 3 })
  await writeFile(resolve(f.root, '.wovenmatter/runtime-preferences.json'), 'corrupt legacy file')
  assert.equal(await createRuntimeMaintenance(f.options).isInstalled('opencode'), true)
  assert.equal(await service.isInstalled('unknown'), false)
})

test('the native installer and update command come from the catalog when it names them', () => {
  assert.deepEqual(nativeInstaller(opencode), { source: 'https://opencode.ai/v2/install', interpreter: 'bash', arguments: [] })
  assert.deepEqual(nativeInstaller(claude), { source: 'https://claude.ai/install.sh', interpreter: 'bash', arguments: ['latest'] })
  assert.deepEqual(nativeInstaller({ ...opencode, install: { kind: 'official-script', source: 'https://opencode.ai/v2/install', interpreter: 'bash' } }).source, 'https://opencode.ai/v2/install')
  assert.deepEqual(nativeUpdateArguments(opencode), ['upgrade'])
  assert.deepEqual(nativeUpdateArguments({ ...grok, update: { arguments: ['update', '--stable'] } }), ['update', '--stable'])
  assert.deepEqual(nativeUpdateArguments(claude), ['update'])
})
