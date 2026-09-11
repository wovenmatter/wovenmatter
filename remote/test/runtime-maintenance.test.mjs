import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm, mkdir, writeFile, symlink } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { createRuntimeMaintenance, sanitize } from '../src/runtime-maintenance.mjs'

const pi = {id:'pi',displayName:'Pi',command:'pi',cliCommand:'pi',install:{kind:'npm-global',package:'@earendil-works/pi-coding-agent@0.84.3'}}
async function fixture(t, overrides = {}) {
  const root = await mkdtemp(resolve(tmpdir(),'wm-maintenance-'))
  t.after(() => rm(root, {recursive:true,force:true}))
  let installed = false, executions = 0, requests = 0
  const calls = []
  const options = {acquireLock:async()=>()=>{},catalog:new Map([['pi',pi]]),workspaceRoot:root,environment:()=>({HOME:root,SECRET_TOKEN:'very-secret-token'}),verifiedInstaller:async()=>{throw Error('unexpected')},
    execute:async(command,env,cwd)=>{
      assert.equal(cwd,root); assert.equal(env.HOME,root); calls.push(command)
      if(command==='ps -eo pid=,args=') return {code:0,output:''}
      if(command.startsWith('command -v')) return {code:installed?0:1,output:root+'/pi'}
      if(command.endsWith('--version')) return {code:0,output:'pi 0.84.4'}
      if(command.startsWith('npm install')) { executions++; installed=true; return {code:0,output:'installed'} }
      throw Error('Unexpected command: '+command)
    },fetchImplementation:async()=>{requests++;return {ok:true,json:async()=>({version:'0.84.5'})}},...overrides}
  return {root,service:createRuntimeMaintenance(options),options,calls,install:()=>{installed=true},get executions(){return executions},get requests(){return requests}}
}
async function finished(service) {
  for(let i=0;i<100;i++){const value=(await service.list()).runtimes[0];if(value.operation?.status!=='running')return value;await new Promise(r=>setTimeout(r,5))}
  throw Error('operation timeout')
}
test('host state gates enable, persists visibility, checks latest only for enabled and never installs at startup',async t=>{
  const f=await fixture(t)
  assert.equal((await f.service.list()).runtimes[0].installed,false)
  await assert.rejects(f.service.preferences(pi,{enabled:true}),/requirements_not_verified/)
  await f.service.check();assert.equal(f.requests,0);assert.equal(f.executions,0)
  f.install(); await f.service.preferences(pi,{enabled:true,visible:false})
  await f.service.check();assert.equal(f.requests,1);assert.equal(f.executions,0)
  const service=createRuntimeMaintenance(f.options)
  const value=(await service.list()).runtimes[0]
  assert.equal(value.enabled,true);assert.equal(value.visible,false)
})
test('preference migration preserves verified legacy runtimes without enabling later installs or overriding choices', async t => {
  const legacy = await fixture(t)
  legacy.install()
  assert.equal(await legacy.service.isEnabled('pi'), true, 'gateway/start checks can be the first migration caller')
  await legacy.service.check()
  assert.equal(legacy.requests, 1, 'migrated enabled runtimes receive the startup latest check')
  assert.equal(legacy.executions, 0)
  await legacy.service.preferences(pi, { enabled: false, visible: false })
  const restarted = createRuntimeMaintenance(legacy.options)
  const retained = (await restarted.list()).runtimes[0]
  assert.equal(retained.enabled, false)
  assert.equal(retained.visible, false)

  const missing = await fixture(t)
  assert.equal(await missing.service.isEnabled('pi'), false)
  missing.install()
  assert.equal((await createRuntimeMaintenance(missing.options).list()).runtimes[0].enabled, false)
})
test('migration of one catalog entry does not silently disable another uninspected entry', async t => {
  const other = { ...pi, id: 'other', command: 'other' }
  const f = await fixture(t, { catalog: new Map([['pi', pi], ['other', other]]) })
  f.install()
  await f.service.inventory(pi)
  const restarted = createRuntimeMaintenance(f.options)
  assert.equal((await restarted.inventory(other)).enabled, true)
})
test('corrupt saved preferences fail closed instead of re-enabling runtimes', async t => {
  const f = await fixture(t)
  f.install()
  await mkdir(resolve(f.root, '.wovenmatter'), { recursive: true })
  await writeFile(resolve(f.root, '.wovenmatter/runtime-preferences.json'), 'invalid saved preferences')
  assert.equal(await createRuntimeMaintenance(f.options).isEnabled('pi'), false)
})
test('duplicate operations share a reservation and verify actual installed result',async t=>{
  const f=await fixture(t)
  const [a,b]=await Promise.all([f.service.start(pi,'install',{confirmed:true}),f.service.start(pi,'install',{confirmed:true})])
  assert.equal(a.id,b.id)
  const value=await finished(f.service)
  assert.equal(value.operation.status,'succeeded');assert.equal(value.installed,true);assert.equal(f.executions,1)
})
test('active host conversation or instance prevents mutation and two failures yield sanitized diagnostics',async t=>{
  const f=await fixture(t,{hasActiveRuntime:async()=>true})
  await f.service.start(pi,'install',{confirmed:true});await finished(f.service)
  await f.service.start(pi,'install',{confirmed:true});const value=await finished(f.service)
  assert.equal(f.executions,0);assert.equal(value.failureCount,2)
  assert.match(value.diagnosticPrompt,/Pi.*remote workspace host/)
  assert.match(value.diagnosticPrompt,/runtime_active/)
  assert.equal(sanitize('very-secret-token https://secret.example/?token=x Bearer abc123',{SECRET_TOKEN:'very-secret-token'}),'[redacted] [URL redacted] [redacted]')
})
test('successful exit without verifiable required runtime fails and supports retry',async t=>{
  const f=await fixture(t,{execute:async cmd=>cmd==='ps -eo pid=,args='?{code:0,output:''}:cmd.startsWith('npm install')?{code:0,output:'ok'}:{code:1,output:''}})
  await f.service.start(pi,'install',{confirmed:true});const value=await finished(f.service)
  assert.equal(value.operation.status,'failed');assert.equal(value.installed,false)
  assert.match(value.operation.error,/could not be verified/)
})
test('Codex inventory resolves adapter bundled dependency independently from sign-in CLI',async t=>{
  const root=await mkdtemp(resolve(tmpdir(),'wm-codex-inventory-'));t.after(()=>rm(root,{recursive:true,force:true}))
  const adapter=resolve(root,'node_modules/@agentclientprotocol/codex-acp')
  const dependency=resolve(root,'node_modules/@openai/codex')
  await mkdir(resolve(adapter,'bin'),{recursive:true});await mkdir(resolve(dependency,'bin'),{recursive:true})
  await writeFile(resolve(adapter,'package.json'),JSON.stringify({name:'@agentclientprotocol/codex-acp',version:'1.11.0'}))
  await writeFile(resolve(adapter,'bin/cli.js'),'');await writeFile(resolve(dependency,'package.json'),JSON.stringify({name:'@openai/codex',version:'0.153.4'}))
  await symlink(resolve(adapter,'bin/cli.js'),resolve(root,'codex-acp'))
  const h={id:'codex',displayName:'Codex',command:'codex-acp',cliCommand:'codex',minimumAdapterVersion:'1.11.0',adapterPackage:'@agentclientprotocol/codex-acp'}
  const service=createRuntimeMaintenance({catalog:new Map([['codex',h]]),workspaceRoot:root,environment:()=>({HOME:root}),execute:async command=>({code:0,output:command.startsWith('command -v')?resolve(root,command.includes('codex-acp')?'codex-acp':'codex'):command.includes('/bin/codex.js')?'codex 0.153.4':command.includes('codex-acp')?'1.11.0':'codex 0.154.0'})})
  const result=await service.inventory(h)
  assert.equal(result.installed,true)
  assert.equal(result.components.find(c=>c.id==='bundled').installedVersion,'0.153.4')
  assert.equal(result.components.find(c=>c.id==='signin').installedVersion,'0.154.0')
})

test('bundled Codex latest is checked separately and refresh respects adapter range', async t => {
  const root = await mkdtemp(resolve(tmpdir(), 'wm-codex-refresh-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  const adapter = resolve(root, 'node_modules/@agentclientprotocol/codex-acp')
  const dependency = resolve(root, 'node_modules/@openai/codex')
  await mkdir(resolve(adapter, 'bin'), { recursive: true })
  await mkdir(resolve(dependency, 'bin'), { recursive: true })
  await writeFile(resolve(adapter, 'package.json'), JSON.stringify({ name: '@agentclientprotocol/codex-acp', version: '1.11.0', dependencies: { '@openai/codex': '~0.153.0' } }))
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
      return { ok: true, json: async () => ({ version: String(url).includes('codex-acp') ? '1.11.0' : '0.154.0' }) }
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
  const initial = await service.inventory(h, true)
  const bundled = initial.components.find(c => c.id === 'bundled')
  assert.equal(bundled.latestVersion, '0.154.0')
  assert.equal(bundled.updateTargetVersion, '0.153.4')
  assert.equal(initial.updateAvailable, true)
  assert.match(initial.notice, /declared compatibility/)
  assert.ok(requests.includes('https://registry.npmjs.org/@openai/codex/latest'))
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

test('copyable failure diagnostics use only allowlisted categories, never arbitrary errors or paths', async t => {
  const f = await fixture(t)
  const secret = '/home/private-account/project confidential-provider-response unknown-unstructured-secret'
  await f.service.recordFailure(pi, 'install-preview', new Error(secret))
  await f.service.recordFailure(pi, 'install-preview', new Error('Installer exited 1. ' + secret))
  const result = (await f.service.list()).runtimes[0]
  assert.match(result.diagnosticPrompt, /Failure: installer_failed/)
  assert.doesNotMatch(result.diagnosticPrompt, /private-account|confidential|unknown-unstructured-secret|\/home\//)
})

test('Hermes check is explicit, bounded and reports allowlisted status without automatic updates', async t => {
  const h = { id: 'hermes', displayName: 'Hermes', command: 'hermes', cliCommand: 'hermes' }
  const calls = []
  let output = 'Update available (behind 3 commits) /private/secret-checkout'
  const f = await fixture(t, {
    catalog: new Map([['hermes', h]]),
    execute: async (command, _env, _cwd, timeout) => {
      calls.push(command)
      if (command.endsWith('update --check')) { assert.equal(timeout, 30000); return { code: 0, output } }
      return { code: 0, output: command.startsWith('command -v') ? '/fixture/hermes' : 'hermes 1.0.0' }
    },
  })
  await f.service.inventory(h)
  assert.equal(calls.some(c => c.endsWith('update --check')), false)
  let result = await f.service.inventory(h, true)
  assert.match(result.notice, /reports an update available/)
  assert.doesNotMatch(result.notice, /secret-checkout/)
  assert.equal(result.updateAvailable, false)
  assert.equal(result.components[0].latestVersion, null)
  output = 'Already up to date.'
  result = await f.service.inventory(h, true)
  assert.match(result.notice, /reports this checkout is up to date/)
  output = 'unexpected private output'
  result = await f.service.inventory(h, true)
  assert.match(result.notice, /information is unavailable/)
  assert.doesNotMatch(result.notice, /unexpected private output/)
})

test('reviewed Pi preview pins execution even when registry latest changes', async t => {
  let version = '0.84.4'
  const f = await fixture(t, { fetchImplementation: async () => ({ ok: true, json: async () => ({ version }) }) })
  const preview = await f.service.npmPreview(pi)
  assert.equal(preview.packageSpec, '@earendil-works/pi-coding-agent@0.84.4')
  assert.ok(preview.command.includes(preview.packageSpec))
  version = '0.85.0'
  await f.service.start(pi, 'install', { confirmed: true, packageSpec: preview.packageSpec })
  assert.equal((await finished(f.service)).operation.status, 'succeeded')
  assert.ok(f.calls.includes(preview.command))
  assert.equal(f.calls.some(c => c.includes('@latest') || c.includes('@0.85.0')), false)
})

test('npm action rejects foreign packages, tags and incompatible OpenCode pins; legacy Pi stays pinned', async t => {
  const f = await fixture(t)
  for (const packageSpec of ['@foreign/package@0.84.4', '@earendil-works/pi-coding-agent@latest', '@earendil-works/pi-coding-agent@0.84.4;touch /tmp/unsafe']) {
    await f.service.start(pi, 'install', { confirmed: true, packageSpec })
    const value = await finished(f.service)
    assert.equal(value.operation.status, 'failed')
    assert.match(value.operation.error, /invalid_package_spec/)
  }
  assert.equal(f.executions, 0)
  await f.service.start(pi, 'install', { confirmed: true })
  await finished(f.service)
  assert.ok(f.calls.some(c => c.includes("'@earendil-works/pi-coding-agent@0.84.3'")))
  const h = { id: 'opencode', displayName: 'OpenCode', command: 'opencode2', cliCommand: 'opencode2', install: { kind: 'npm-global', package: '@opencode/cli@0.0.0-beta-19278' } }
  const other = await fixture(t, { catalog: new Map([['opencode', h]]) })
  const preview = await other.service.npmPreview(h)
  assert.equal(preview.packageSpec, h.install.package)
  assert.equal(other.requests, 0)
  await other.service.start(h, 'install', { confirmed: true, packageSpec: '@opencode/cli@0.0.0-beta-99999' })
  const failed = await finished(other.service)
  assert.equal(failed.operation.error, 'opencode_version_incompatible')
  assert.equal(other.executions, 0)
})
