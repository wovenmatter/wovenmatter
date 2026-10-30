import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, mkdir, readFile, writeFile, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { createRuntimeMaintenance, sanitize } from '../src/runtime-maintenance.mjs'
import { loadRuntimeConfiguration } from '../src/config.mjs'







const registryMetadata = version => ({ versions: { [version]: {} }, 'dist-tags': { latest: version } })
const npmInvocation = (command, action) => command.startsWith('npm ' + action) || command.includes("/npm-cli.js' " + action)

const opencode = {id:'opencode',displayName:'OpenCode',command:'opencode',cliCommand:'opencode',install:{kind:'npm-global',package:'@opencode/cli@2'}}
async function fixture(t, overrides = {}) {
  const root = await mkdtemp(resolve(tmpdir(),'wm-maintenance-'))
  t.after(() => rm(root, {recursive:true,force:true}))
  let installed = false, executions = 0, requests = 0
  const calls = []
  const options = {acquireLock:async()=>()=>{},catalog:new Map([['opencode',opencode]]),workspaceRoot:root,environment:()=>({HOME:root,SECRET_TOKEN:'very-secret-token'}),verifiedInstaller:async()=>{throw Error('unexpected')},
    execute:async(command,env,cwd)=>{
      assert.equal(cwd,root); assert.equal(env.HOME,root); assert.equal(env.npm_config_cache, resolve(root, ".wovenmatter/npm-cache")); calls.push(command)
      if(command==='ps -eo pid=,args=') return {code:0,output:''}
      if(command.startsWith('command -v')) return {code:installed?0:1,output:root+'/opencode'}
      if(command.endsWith('--version')) return {code:0,output:'opencode 2.1.0'}
      if(npmInvocation(command,'install')) { executions++; installed=true; return {code:0,output:'installed'} }
      throw Error('Unexpected command: '+command)
    },fetchImplementation:async()=>{requests++;return {ok:true,json:async()=>registryMetadata('2.1.1')}},...overrides}
  return {root,service:createRuntimeMaintenance(options),options,calls,install:()=>{installed=true},get executions(){return executions},get requests(){return requests}}
}
async function finished(service) {
  for(let i=0;i<100;i++){const value=(await service.list()).runtimes[0];if(value.operation?.status!=='running')return value;await new Promise(r=>setTimeout(r,5))}
  throw Error('operation timeout')
}
test('installation alone controls availability and update checks never install software', async t => {
  const f = await fixture(t)
  assert.equal(await f.service.isInstalled('opencode'), false)
  await f.service.check(); assert.equal(f.requests, 0); assert.equal(f.executions, 0)
  await f.service.start(opencode, 'install', { confirmed: true })
  const installed = await finished(f.service)
  assert.equal(installed.installed, true)
  assert.equal(installed.enabled, true) // Compatibility fields for older apps.
  assert.equal(installed.visible, true)
  assert.equal(await f.service.isInstalled('opencode'), true)
  const calls = f.calls.length
  await f.service.isInstalled('opencode')
  assert.equal(f.calls.length, calls, 'execution checks reuse verified inventory')
  const requests = f.requests
  await f.service.check(); assert.equal(f.requests, requests + 1); assert.equal(f.executions, 1)
})

test('duplicate operations share a reservation and verify actual installed result',async t=>{
  const f=await fixture(t)
  const [a,b]=await Promise.all([f.service.start(opencode,'install',{confirmed:true}),f.service.start(opencode,'install',{confirmed:true})])
  assert.equal(a.id,b.id)
  assert.equal((await f.service.operation(a.id.toUpperCase())).id, a.id)
  const value=await finished(f.service)
  assert.equal(value.operation.status,'succeeded');assert.equal(value.installed,true);assert.equal(f.executions,1)
})
test('active host conversation or instance prevents mutation and two failures yield sanitized diagnostics',async t=>{
  const f=await fixture(t,{hasActiveRuntime:async()=>true})
  await f.service.start(opencode,'install',{confirmed:true});await finished(f.service)
  await f.service.start(opencode,'install',{confirmed:true});const value=await finished(f.service)
  assert.equal(f.executions,0);assert.equal(value.failureCount,2)
  assert.match(value.diagnosticPrompt,/OpenCode.*remote workspace host/)
  assert.match(value.diagnosticPrompt,/runtime_active/)
  assert.equal(sanitize('very-secret-token https://secret.example/?token=x Bearer abc123',{SECRET_TOKEN:'very-secret-token'}),'[redacted] [URL redacted] [redacted]')
})

test('copyable failure diagnostics use only allowlisted categories, never arbitrary errors or paths', async t => {
  const f = await fixture(t)
  const secret = '/home/private-account/project confidential-provider-response unknown-unstructured-secret'
  await f.service.recordFailure(opencode, 'install-preview', new Error(secret))
  await f.service.recordFailure(opencode, 'install-preview', new Error('Installer exited 1. ' + secret))
  const result = (await f.service.list()).runtimes[0]
  assert.match(result.diagnosticPrompt, /Failure: installer_failed/)
  assert.doesNotMatch(result.diagnosticPrompt, /private-account|confidential|unknown-unstructured-secret|\/home\//)
})

test('npm actions reject foreign packages, tags and OpenCode v1; reviewed releases stay fixed for each operation', async t => {
  const f = await fixture(t)
  for (const packageSpec of ['@foreign/package@2.1.0', '@opencode/cli@latest', '@opencode/cli@2.1.0;touch /tmp/unsafe']) {
    await f.service.start(opencode, 'install', { confirmed: true, packageSpec })
    const value = await finished(f.service)
    assert.equal(value.operation.status, 'failed')
    assert.match(value.operation.error, /invalid_package_spec/)
  }
  assert.equal(f.executions, 0)
  await f.service.start(opencode, 'install', { confirmed: true })
  await finished(f.service)
  assert.ok(f.calls.some(c => c.includes("'@opencode/cli@2.1.1'")))
  const h = { id: 'opencode', displayName: 'OpenCode', command: 'opencode2', cliCommand: 'opencode2', install: { kind: 'npm-global', package: '@opencode/cli@2' } }
  const other = await fixture(t, { catalog: new Map([['opencode', h]]), fetchImplementation: async () => ({ ok: true, json: async () => registryMetadata('2.1.0') }) })
  const preview = await other.service.npmPreview(h)
  assert.equal(preview.packageSpec, '@opencode/cli@2.1.0')
  await other.service.start(h, 'install', { confirmed: true, packageSpec: '@opencode/cli@1.18.29' })
  const failed = await finished(other.service)
  assert.equal(failed.operation.error, 'opencode_version_incompatible')
  assert.equal(other.executions, 0)
})

test('retired hidden and disabled preferences cannot suppress installed harnesses', async t => {
  const f = await fixture(t)
  await mkdir(resolve(f.root, '.wovenmatter'), { recursive: true })
  await writeFile(resolve(f.root, '.wovenmatter/runtime-preferences.json'), JSON.stringify({
    opencode: { enabled: false, visible: false, failureCount: 2 },
  }))
  f.install()
  const service = createRuntimeMaintenance(f.options)
  assert.equal(await service.isInstalled('opencode'), true)
  const row = (await service.list()).runtimes[0]
  assert.equal(row.enabled, true); assert.equal(row.visible, true); assert.equal(row.failureCount, 2)
  await service.recordFailure(opencode, 'install', new Error('fixture'))
  const saved = JSON.parse(await (await import('node:fs/promises')).readFile(resolve(f.root, '.wovenmatter/runtime-preferences.json'), 'utf8'))
  assert.deepEqual(saved.opencode, { failureCount: 3 })
  await writeFile(resolve(f.root, '.wovenmatter/runtime-preferences.json'), 'corrupt legacy file')
  assert.equal(await createRuntimeMaintenance(f.options).isInstalled('opencode'), true)
  assert.equal(await service.isInstalled('unknown'), false)
})

test('bundled Codex latest is checked separately and refresh respects adapter range', async t => {
  const root = await mkdtemp(resolve(tmpdir(), 'wm-codex-refresh-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const adapter = resolve(root, 'node_modules/@agentclientprotocol/codex-acp')
  const dependency = resolve(root, 'node_modules/@openai/codex')
  await mkdir(resolve(adapter, 'bin'), { recursive: true })
  await mkdir(resolve(dependency, 'bin'), { recursive: true })
  await writeFile(resolve(adapter, 'package.json'), JSON.stringify({ name: '@agentclientprotocol/codex-acp', version: '1.11.0' }))
  await writeFile(resolve(adapter, 'bin/cli.js'), '')
  await writeFile(resolve(dependency, 'package.json'), JSON.stringify({ name: '@openai/codex', version: '0.153.1' }))
  await symlink(resolve(adapter, 'bin/cli.js'), resolve(root, 'codex-acp'))
  const h = { id: 'codex', displayName: 'Codex', command: 'codex-acp', cliCommand: 'codex', minimumAdapterVersion: '1.11.0', adapterPackage: '@agentclientprotocol/codex-acp', install: { interpreter: 'sh', arguments: [] } }
  const calls = [], requests = []
  let engine = '0.153.1', refresh = true
  const service = createRuntimeMaintenance({
    catalog: new Map([['codex', h]]), workspaceRoot: root, environment: () => ({ HOME: root }), acquireLock: async () => () => {},
    verifiedInstaller: async () => ({ path: resolve(root, 'fixture-installer.sh') }),
    fetchImplementation: async url => {
      requests.push(decodeURIComponent(url))
      return { ok: true, json: async () => registryMetadata(String(url).includes('codex-acp') ? '1.11.0' : '0.154.0') }
    },
    execute: async command => {
      calls.push(command)
      if (command === 'ps -eo pid=,args=') return { code: 0, output: '' }
      if (command.startsWith('command -v')) return { code: 0, output: resolve(root, command.includes('codex-acp') ? 'codex-acp' : 'codex') }
      if (command.startsWith('npm view')) return { code: 0, output: JSON.stringify(['0.153.1', '0.153.4']) }
      if (command.startsWith('npm update')) {
        if (refresh) { engine = '0.153.4'; await writeFile(resolve(dependency, 'package.json'), JSON.stringify({ name: '@openai/codex', version: engine })) }
        return { code: 0, output: '' }
      }
      if (command.endsWith('--version')) return { code: 0, output: command.includes('/bin/codex.js') ? engine : command.includes('codex-acp') ? '1.11.0' : '0.154.0' }
      return { code: 0, output: '' }
    },
  })
  const installed = await service.inventory(h)
  assert.equal(installed.installed, true)
  assert.equal(installed.components.find(c => c.id === 'bundled').installedVersion, '0.153.1')
  assert.equal(installed.components.find(c => c.id === 'signin').installedVersion, '0.154.0')
  await writeFile(resolve(adapter, 'package.json'), JSON.stringify({ name: '@agentclientprotocol/codex-acp', version: '1.11.0', dependencies: { '@openai/codex': '~0.153.0' } }))
  const initial = await service.inventory(h, true)
  const bundled = initial.components.find(c => c.id === 'bundled')
  assert.equal(bundled.latestVersion, '0.154.0')
  assert.equal(bundled.updateTargetVersion, '0.153.4')
  assert.equal(initial.updateAvailable, true)
  assert.match(initial.notice, /declared compatibility/)
  assert.ok(requests.includes('https://registry.npmjs.org/@openai/codex'))
  assert.ok(calls.some(c => c.includes("'@openai/codex@~0.153.0'")))
  // A successful installer exit is insufficient if its compatible bundled target is unchanged.
  refresh = false
  await service.start(h, 'update', { confirmed: true, sourceSHA256: 'fixture' })
  assert.equal((await finished(service)).operation.status, 'failed')
  refresh = true
  await service.start(h, 'update', { confirmed: true, sourceSHA256: 'fixture' })
  const result = await finished(service)
  assert.equal(result.operation.status, 'succeeded')
  assert.equal(result.components.find(c => c.id === 'bundled').installedVersion, '0.153.4')
  assert.equal(result.updateAvailable, false, 'upstream outside adapter compatibility does not create another update action')
  const update = calls.find(c => c.startsWith('npm update'))
  assert.ok(update.includes('/node_modules/@agentclientprotocol/codex-acp\''))
  assert.match(update, /--no-save --package-lock=false/)
  assert.doesNotMatch(update, /@latest|CODEX_PATH/)
  // An unknown declaration reports upstream latest without inventing a compatible update.
  await writeFile(resolve(adapter, 'package.json'), JSON.stringify({ name: '@agentclientprotocol/codex-acp', version: '1.11.0', dependencies: { '@openai/codex': 'workspace:*' } }))
  const unknown = await service.inventory(h, true)
  assert.equal(unknown.components.find(c => c.id === 'bundled').latestVersion, '0.154.0')
  assert.equal(unknown.components.find(c => c.id === 'bundled').updateTargetVersion, null)
  assert.equal(unknown.updateAvailable, false)
})

test('OpenCode latest previews and updates accept newer v2 releases independently', async t => {
  const root = await mkdtemp(resolve(tmpdir(), 'wm-opencode-update-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const harness = { id: 'opencode', displayName: 'OpenCode', command: 'opencode', cliCommand: 'opencode', install: { kind: 'npm-global', package: '@opencode/cli@2' } }
  let installed = '2.0.22', latest = '2.1.7'
  const service = createRuntimeMaintenance({ catalog: new Map([['opencode', harness]]), workspaceRoot: root,
    environment: () => ({ HOME: root }), acquireLock: async () => () => {},
    fetchImplementation: async url => { assert.equal(decodeURIComponent(url), 'https://registry.npmjs.org/@opencode/cli'); return { ok: true, json: async () => registryMetadata(latest) } },
    execute: async command => {
      if (command.startsWith('command -v')) return { code: 0, output: '/fixture/opencode' }
      if (command.endsWith('--version')) return { code: 0, output: installed }
      if (command.startsWith('npm install')) { assert.ok(command.includes('@opencode/cli@2.1.7')); installed = '2.1.7'; return { code: 0, output: '' } }
      if (command === 'ps -eo pid=,args=') return { code: 0, output: '' }
      throw Error('Unexpected command: ' + command)
    },
  })
  assert.equal((await service.inventory(harness, true)).updateAvailable, true)
  const preview = await service.npmPreview(harness)
  assert.equal(preview.packageSpec, '@opencode/cli@2.1.7')
  await service.start(harness, 'update', { confirmed: true, packageSpec: preview.packageSpec })
  assert.equal((await finished(service)).operation.status, 'succeeded')
  latest = '2.99.0'
  assert.equal((await service.npmPreview(harness)).packageSpec, '@opencode/cli@2.99.0')
  latest = '1.18.29'
  await assert.rejects(service.npmPreview(harness), /latest_package_version_unavailable/)
})

test('OpenCode updates refuse active canonical and compatibility-alias processes', async t => {
  const harness = { id: 'opencode', displayName: 'OpenCode', command: 'opencode', cliCommand: 'opencode', install: { kind: 'npm-global', package: '@opencode/cli@2' } }
  for (const process of ['opencode', 'opencode2', '/host/bin/opencode2', 'node /host/bin/opencode2.js']) {
    let installs = 0
    const f = await fixture(t, { catalog: new Map([['opencode', harness]]),
      execute: async command => {
        if (command === 'ps -eo pid=,args=') return { code: 0, output: `1234 ${process} serve --service` }
        if (command.startsWith('command -v')) return { code: 0, output: '/host/bin/opencode' }
        if (command.endsWith('--version')) return { code: 0, output: '2.0.22' }
        if (command.startsWith('npm install')) { installs++; return { code: 0, output: '' } }
        throw Error('Unexpected command: ' + command)
      },
    })
    await f.service.start(harness, 'update', { confirmed: true, packageSpec: '@opencode/cli@2.1.7' })
    const result = await finished(f.service)
    assert.equal(result.operation.error, 'runtime_active_stop_conversations_or_server_first', process)
    assert.equal(installs, 0, process)
  }
})

test('host reuses preexisting local installs as system-owned and refuses their updates', async t => {
  const f = await fixture(t)
  f.install()
  const configuration = loadRuntimeConfiguration({ HOME: f.root, WOVENMATTER_RUNTIME_KIND: 'host' })
  const service = createRuntimeMaintenance({ ...f.options, configuration })
  const checked = await service.inventory(opencode, true)
  assert.equal(checked.source, 'system')
  assert.equal(checked.components[0].source, 'system')
  assert.equal(checked.updateAvailable, false)
  assert.equal(checked.components[0].updateAvailable, false)
  await service.start(opencode, 'update', { confirmed: true, packageSpec: '@opencode/cli@2.1.1' })
  const result = await finished(service)
  assert.equal(result.operation.error, 'system_install_update_forbidden')
  assert.equal(f.executions, 0)
})

test('host records only Woven installs as managed and uses its configured operation lock', async t => {
  const f = await fixture(t), locks = []
  const configuration = loadRuntimeConfiguration({ HOME: f.root, WOVENMATTER_RUNTIME_KIND: 'host', WOVENMATTER_STATE_DIRECTORY: resolve(f.root, 'run') })
  const service = createRuntimeMaintenance({ ...f.options, configuration, acquireLock: async path => { locks.push(path); return () => {} } })
  await service.start(opencode, 'install', { confirmed: true, packageSpec: '@opencode/cli@2.1.1' })
  const result = await finished(service)
  assert.equal(result.operation.status, 'succeeded')
  assert.equal(result.source, 'managed')
  assert.deepEqual(locks, [resolve(f.root, 'run/runtime-operation.lock')])
  const persisted = JSON.parse(await readFile(resolve(f.root, '.wovenmatter/runtime-preferences.json'), 'utf8'))
  assert.deepEqual(persisted.opencode.managedComponents.runtime, { path: resolve(f.root, 'opencode'), target: resolve(f.root, 'opencode') })
  assert.equal((await createRuntimeMaintenance({ ...f.options, configuration }).inventory(opencode)).source, 'managed')
})

test('host installs a missing adapter alongside an active system CLI and blocks active managed adapter updates', async t => {
  const root = await mkdtemp(resolve(tmpdir(), 'woven-host-adapter-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const configuration = loadRuntimeConfiguration({ HOME: root, WOVENMATTER_RUNTIME_KIND: 'host' })
  const h = { id: 'codex', displayName: 'Codex', command: 'codex-acp', cliCommand: 'codex', adapterPackage: '@agentclientprotocol/codex-acp', minimumAdapterVersion: '2.3.0', install: { kind: 'official-script' } }
  const adapter = resolve(root, '.local/lib/node_modules/@agentclientprotocol/codex-acp')
  const dependency = resolve(adapter, 'node_modules/@openai/codex')
  const bin = resolve(root, '.local/bin/codex-acp')
  let installed = false, scripts = 0, activeAdapter = false
  const calls = []
  const service = createRuntimeMaintenance({ catalog: new Map([['codex', h]]), workspaceRoot: root, configuration,
    environment: () => ({ HOME: root }), acquireLock: async () => () => {},
    verifiedInstaller: async () => { scripts++; throw new Error('system CLI must not be reinstalled') },
    fetchImplementation: async () => ({ ok: true, json: async () => registryMetadata('2.3.1') }),
    execute: async command => {
      calls.push(command)
      if (command === 'ps -eo pid=,args=') return { code: 0, output: '5471 /usr/bin/codex resume\n' + (activeAdapter ? '6001 node ' + resolve(adapter, 'bin/cli.js') : '') }
      if (command.startsWith('command -v')) return command.includes("'codex-acp'") ? { code: installed ? 0 : 1, output: installed ? bin : '' } : { code: 0, output: '/usr/bin/codex' }
      if (command.endsWith('--version')) return { code: 0, output: command.includes('codex-acp') ? '2.3.1' : '0.154.0' }
      if (npmInvocation(command, 'install')) {
        assert.equal(command, `'${process.execPath}' '${configuration.serviceRoot}/tooling/lib/node_modules/npm/bin/npm-cli.js' install --global --prefix "$HOME/.local" '@agentclientprotocol/codex-acp@2.3.1'`)
        await mkdir(resolve(adapter, 'bin'), { recursive: true }); await mkdir(resolve(dependency, 'bin'), { recursive: true }); await mkdir(resolve(root, '.local/bin'), { recursive: true })
        await writeFile(resolve(adapter, 'package.json'), JSON.stringify({ name: h.adapterPackage, version: '2.3.1' }))
        await writeFile(resolve(adapter, 'bin/cli.js'), '')
        await writeFile(resolve(dependency, 'package.json'), JSON.stringify({ name: '@openai/codex', version: '0.154.0' }))
        await symlink(resolve(adapter, 'bin/cli.js'), bin)
        installed = true
        return { code: 0, output: 'adapter installed' }
      }
      throw new Error('Unexpected command: ' + command)
    },
  })
  const preview = await service.hostAdapterPreview(h)
  assert.equal(preview.packageSpec, '@agentclientprotocol/codex-acp@2.3.1')
  assert.equal(preview.verification, 'npm-registry-integrity')
  await service.start(h, 'install', { confirmed: true, packageSpec: preview.packageSpec })
  const result = await finished(service)
  assert.equal(result.operation.status, 'succeeded')
  assert.equal(result.components.find(c => c.id === 'runtime').source, 'managed')
  assert.equal(result.components.find(c => c.id === 'signin').source, 'system')
  assert.equal(scripts, 0)
  assert.equal(calls.filter(command => npmInvocation(command, 'install')).length, 1)
  activeAdapter = true
  await service.start(h, 'update', { confirmed: true, packageSpec: preview.packageSpec })
  const blocked = await finished(service)
  assert.equal(blocked.operation.error, 'runtime_active_stop_conversations_or_server_first')
  assert.equal(calls.filter(command => npmInvocation(command, 'install')).length, 1)
})

test('host keeps service-owned active sessions fenced and refuses unmanaged adapter updates', async t => {
  const active = await fixture(t, { hasActiveRuntime: async () => true })
  const protectedService = createRuntimeMaintenance({ ...active.options,
    configuration: loadRuntimeConfiguration({ HOME: active.root, WOVENMATTER_RUNTIME_KIND: 'host' }) })
  await protectedService.start(opencode, 'install', { confirmed: true, packageSpec: '@opencode/cli@2.1.1' })
  assert.equal((await finished(protectedService)).operation.error, 'runtime_active_stop_conversations_or_server_first')
  assert.equal(active.executions, 0)
  const h = { id: 'codex', displayName: 'Codex', command: 'codex-acp', cliCommand: 'codex', adapterPackage: '@agentclientprotocol/codex-acp', minimumAdapterVersion: '2.3.0', install: { kind: 'official-script' } }
  let installs = 0
  const other = await fixture(t, { catalog: new Map([['codex', h]]), execute: async command => {
    if (command.startsWith('command -v')) return { code: 0, output: command.includes('codex-acp') ? '/usr/bin/codex-acp' : '/usr/bin/codex' }
    if (command.endsWith('--version')) return { code: 0, output: '2.3.1' }
    if (command === 'ps -eo pid=,args=') return { code: 0, output: '5471 /usr/bin/codex-acp' }
    if (command.startsWith('npm install')) { installs++; return { code: 0, output: '' } }
    throw new Error('Unexpected command: ' + command)
  } })
  const unmanaged = createRuntimeMaintenance({ ...other.options,
    configuration: loadRuntimeConfiguration({ HOME: other.root, WOVENMATTER_RUNTIME_KIND: 'host' }) })
  await unmanaged.start(h, 'update', { confirmed: true, packageSpec: '@agentclientprotocol/codex-acp@2.3.1' })
  assert.equal((await finished(unmanaged)).operation.error, 'system_install_update_forbidden')
  assert.equal(installs, 0)
})

test('host installer rc writes fail the operation and restore the original shell setup', async t => {
  const f = await fixture(t)
  await writeFile(resolve(f.root, '.bashrc'), 'existing configuration\n')
  const execute = f.options.execute
  const service = createRuntimeMaintenance({ ...f.options,
    configuration: loadRuntimeConfiguration({ HOME: f.root, WOVENMATTER_RUNTIME_KIND: 'host' }),
    execute: async (...arguments_) => {
      const result = await execute(...arguments_)
      if (npmInvocation(arguments_[0], 'install')) await writeFile(resolve(f.root, '.bashrc'), 'unwanted installer changes\n')
      return result
    },
  })
  await service.start(opencode, 'install', { confirmed: true, packageSpec: '@opencode/cli@2.1.1' })
  const result = await finished(service)
  assert.equal(result.operation.error, 'installer_modified_shell_config')
  assert.equal(await readFile(resolve(f.root, '.bashrc'), 'utf8'), 'existing configuration\n')
})

test('reviewed adapters update their engine even when the connector itself is current', async t => {
  const root = await mkdtemp(resolve(tmpdir(), 'wm-independent-engine-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const adapter = resolve(root, 'node_modules/@agentclientprotocol/codex-acp')
  const dependency = resolve(root, 'node_modules/@openai/codex')
  await mkdir(resolve(adapter, 'bin'), { recursive: true }); await mkdir(resolve(dependency, 'bin'), { recursive: true })
  await writeFile(resolve(adapter, 'package.json'), JSON.stringify({ name: '@agentclientprotocol/codex-acp', version: '2.5.0', dependencies: { '@openai/codex': '^0.165.0' } }))
  await writeFile(resolve(adapter, 'bin/cli.js'), '')
  await symlink(resolve(adapter, 'bin/cli.js'), resolve(root, 'codex-acp'))
  let engine = '0.165.0', selected
  await writeFile(resolve(dependency, 'package.json'), JSON.stringify({ name: '@openai/codex', version: engine }))
  const h = { id: 'codex', displayName: 'Codex', command: 'codex-acp', cliCommand: 'codex', adapterPackage: '@agentclientprotocol/codex-acp', minimumAdapterVersion: '2.5.0', minimumEngineVersion: '0.166.0', install: { interpreter: 'sh', arguments: [] } }
  const service = createRuntimeMaintenance({ catalog: new Map([['codex', h]]), workspaceRoot: root, environment: () => ({ HOME: root }), acquireLock: async () => () => {},
    verifiedInstaller: async () => ({ path: resolve(root, 'fixture-installer.sh') }),
    fetchImplementation: async url => ({ ok: true, json: async () => registryMetadata(String(url).includes('codex-acp') ? '2.5.0' : '0.166.0') }),
    execute: async command => {
      if (command === 'ps -eo pid=,args=') return { code: 0, output: '' }
      if (command.startsWith('command -v')) return { code: 0, output: resolve(root, command.includes('codex-acp') ? 'codex-acp' : 'codex') }
      if (command.endsWith('--version')) return { code: 0, output: command.includes('/bin/codex.js') ? engine : command.includes('codex-acp') ? '2.5.0' : '0.166.0' }
      assert.ok(!command.includes('npm view'), 'reviewed engine selection must not fall back to the old upstream range')
      const match = command.match(/'(\{"prefix":.*\})'$/)
      if (match) {
        selected = JSON.parse(match[1]); engine = selected.engineVersion
        await writeFile(resolve(dependency, 'package.json'), JSON.stringify({ name: '@openai/codex', version: engine }))
      }
      return { code: 0, output: '' }
    },
  })
  const before = await service.inventory(h, true)
  assert.equal(before.components[0].updateAvailable, false)
  assert.equal(before.components.find(c => c.id === 'bundled').updateTargetVersion, '0.166.0')
  assert.equal(before.updateAvailable, true)
  await service.start(h, 'update', { confirmed: true, sourceSHA256: 'fixture' })
  const after = await finished(service)
  assert.equal(after.operation.status, 'succeeded')
  assert.equal(selected.adapterVersion, '2.5.0'); assert.equal(selected.engineVersion, '0.166.0')
  assert.equal(after.components.find(c => c.id === 'bundled').installedVersion, '0.166.0')
  assert.equal(after.updateAvailable, false)
})
