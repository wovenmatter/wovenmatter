import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, mkdir, readFile, writeFile, symlink, chmod } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { createRuntimeMaintenance, sanitize, nativeInstaller, nativeUpdateArguments, runHost, claudeCodeNativeChannel, operationFailureCodes } from '../src/runtime-maintenance.mjs'
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
  assert.equal(install[1], 600000)
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
  assert.equal(update[1], 600000, 'the vendor update has a ten-minute background time limit')
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
  assert.equal(result.operation.error, 'update_verification_failed')
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

test('the real catalog has no version gates: any runnable connector is installed, a newer npm release is an update, and the update installs it as published', async t => {
  const real = JSON.parse(await readFile(new URL('../../harnesses/catalog.json', import.meta.url), 'utf8')).harnesses
  for (const h of real) assert.deepEqual(Object.keys(h).filter(key => /minimum/i.test(key)), [], h.id)
  for (const h of real.filter(h => h.adapterPackage)) {
    const selections = []
    const f = await fixture(t, { catalog: [h], latest: '9.0.0', on: (command, { root, commands }) => {
      if (command.includes('install-adapter.mjs')) {
        selections.push(JSON.parse(command.slice(command.lastIndexOf(" '") + 2, -1)))
        commands[h.command].version = '9.0.0'
        return { code: 0, output: '' }
      }
      if (command.endsWith("'update'")) return { code: 0, output: '' }
    } })
    // A very old connector beside a CLI from any release still runs, so it is installed.
    f.commands[h.cliCommand] = { path: resolve(f.root, '.local/bin', h.cliCommand), version: '9.0.0' }
    f.commands[h.command] = { path: resolve(f.root, '.local/share/wovenmatter/acp-adapters/bin', h.command), version: '0.0.1' }
    const before = await f.service.inventory(h, true)
    assert.equal(before.installed, true, h.id)
    assert.deepEqual(before.components.map(c => c.id), ['cli', 'runtime'], 'only the CLI and its connector are tracked')
    assert.equal(before.components.find(c => c.id === 'runtime').updateAvailable, true)
    assert.equal(before.components.find(c => c.id === 'cli').updateAvailable, false)
    await f.service.start(h, 'update', { confirmed: true })
    assert.equal((await finished(f.service)).operation.status, 'succeeded', h.id)
    assert.equal(selections.length, 1)
    assert.deepEqual(Object.keys(selections[0]).sort(), ['adapter', 'adapterVersion', 'cli', 'npm', 'prefix'])
    assert.equal(selections[0].adapterVersion, '9.0.0')
    assert.equal(selections[0].cli, resolve(f.root, '.local/bin', h.cliCommand))
  }
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
  assert.equal(result.operation.error, 'installer_failed')
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

test('a host command settles when it exits even if a child it left behind holds its output open', async () => {
  const started = Date.now()
  const result = await runHost('sleep 20 & echo started', process.env, tmpdir(), 10_000)
  assert.equal(result.code, 0)
  assert.equal(result.timedOut, false)
  assert.match(result.output, /started/)
  assert.ok(Date.now() - started < 5000)
})

test('a host command that runs past its limit is killed and reported as timed out', async () => {
  const started = Date.now()
  const result = await runHost('sleep 20', process.env, tmpdir(), 300)
  assert.equal(result.timedOut, true)
  assert.equal(result.code, -1)
  assert.ok(Date.now() - started < 5000)
})

test('Claude Code compares with its native release channel, which can trail npm', async t => {
  const fetched = []
  const f = await fixture(t, { catalog: [claude], fetchImplementation: async url => {
    fetched.push(String(url))
    return url === claudeCodeNativeChannel
      ? { ok: true, text: async () => '2.1.326\n' }
      : { ok: true, json: async () => registryMetadata(String(url).includes('claude-code') ? '2.1.327' : '0.200.0'), text: async () => '' }
  } })
  f.commands.claude = { path: resolve(f.root, '.local/bin/claude'), version: '2.1.326 (Claude Code)' }
  f.commands['claude-agent-acp'] = { path: resolve(f.root, '.local/share/wovenmatter/acp-adapters/bin/claude-agent-acp'), version: '0.200.0' }
  const checked = await f.service.inventory(claude, true)
  const cli = checked.components.find(c => c.id === 'cli')
  assert.equal(cli.latestVersion, '2.1.326')
  assert.equal(checked.updateAvailable, false)
  assert.ok(fetched.includes(claudeCodeNativeChannel))
  assert.equal(fetched.some(url => url.includes('%40anthropic-ai%2Fclaude-code') || url.includes('@anthropic-ai/claude-code')), false)
})

test('a failed command reports a fixed id; what it printed stays in the sanitized output', async t => {
  const f = await fixture(t, { catalog: [grok], latest: '1.0.88', on: command => {
    if (command.endsWith("'update'")) return { code: 3, output: 'network down very-secret-token https://x.ai/cli' }
  } })
  f.commands.grok = { path: resolve(f.root, '.grok/bin/grok'), version: 'grok 1.0.77' }
  await f.service.inventory(grok, true)
  await f.service.start(grok, 'update', { confirmed: true })
  const { operation } = await finished(f.service)
  assert.equal(operation.error, 'update_failed')
  assert.ok(operationFailureCodes.includes(operation.error))
  assert.match(operation.output, /network down \[redacted\] \[URL redacted\]/)
  // A thrown message outside the allowlist never reaches the apps.
  const odd = await fixture(t, { officialInstaller: async () => { throw new Error('ENOSPC /home/private-account/x') } })
  await odd.service.start(opencode, 'install', { confirmed: true })
  assert.equal((await finished(odd.service)).operation.error, 'runtime_operation_failed')
})

test('an npm-installed OpenCode is replaced by the official installer, never upgraded through npm', async t => {
  let restarts = 0
  const f = await fixture(t, { latest: '2.3.0', restartOpenCodeService: async () => { restarts++ }, on: async (command, { root, commands }) => {
    if (command.startsWith("'bash' ")) {
      const official = resolve(root, '.opencode/bin/opencode')
      await mkdir(resolve(root, '.opencode/bin'), { recursive: true })
      await writeFile(official, '#!/bin/sh\n'); await chmod(official, 0o700)
      // The npm copy stays first on this PATH; the official location still wins.
      commands['opencode-official'] = { path: official, version: 'opencode v2.3.0' }
      return { code: 0, output: '' }
    }
    if (command.endsWith("'upgrade'")) throw Error('npm-installed OpenCode was upgraded through npm')
  } })
  // `npm --prefix ~/.local install -g @opencode/cli@2`, as older Woven hosts did.
  const packaged = resolve(f.root, '.local/lib/node_modules/@opencode/cli/bin/opencode')
  await mkdir(resolve(packaged, '..'), { recursive: true }); await writeFile(packaged, '#!/bin/sh\n')
  await mkdir(resolve(f.root, '.local/bin'), { recursive: true })
  await symlink(packaged, resolve(f.root, '.local/bin/opencode'))
  f.commands.opencode = { path: resolve(f.root, '.local/bin/opencode'), version: 'opencode v2.2.7' }
  const before = await f.service.inventory(opencode, true)
  assert.equal(before.source, 'npm')
  assert.equal(before.installed, true)
  assert.equal(before.updateAvailable, true)
  assert.match(before.notice, /installed with npm/)
  await f.service.start(opencode, 'update', { confirmed: true })
  const after = await finished(f.service)
  assert.equal(after.operation.status, 'succeeded', after.operation.error)
  assert.deepEqual(f.installers, [['opencode', 'https://opencode.ai/v2/install']])
  assert.equal(after.path, resolve(f.root, '.opencode/bin/opencode'))
  assert.equal(after.source, 'native')
  assert.equal(after.updateAvailable, false)
  assert.equal(restarts, 1, 'the shared service moves to the official CLI')
  assert.equal(f.calls.some(([command]) => /npm|'upgrade'/.test(command)), false)
})

test('an npm-installed CLI that the official installer does not replace fails verification', async t => {
  const f = await fixture(t, { catalog: [grok], on: command => { if (command.startsWith("'bash' ")) return { code: 0, output: '' } } })
  const packaged = resolve(f.root, '.npm-global/lib/node_modules/@xai/grok/bin/grok')
  await mkdir(resolve(packaged, '..'), { recursive: true }); await writeFile(packaged, '#!/bin/sh\n')
  f.commands.grok = { path: packaged, version: 'grok 1.0.77' }
  assert.equal((await f.service.inventory(grok)).source, 'npm')
  await f.service.start(grok, 'install', { confirmed: true })
  const result = await finished(f.service)
  assert.deepEqual(f.installers, [['grok_build', 'https://x.ai/cli/install.sh']])
  assert.equal(result.operation.error, 'installation_verification_failed')
})
