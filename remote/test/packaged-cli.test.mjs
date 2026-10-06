import test from 'node:test'
import assert from 'node:assert/strict'
import { cpSync, existsSync, mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'

test('deployed service layout loads CLI integrations and installs a standalone OpenClaw plugin', async t => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'woven-packaged-cli-')))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  // Match remote/Dockerfile's COPY destinations without building an image.
  const service = join(root, 'service with spaces')
  cpSync(resolve(import.meta.dirname, '../src'), join(service, 'src'), { recursive: true, verbatimSymlinks: true })
  cpSync(resolve(import.meta.dirname, '../../harnesses'), join(service, 'harnesses'), { recursive: true })
  const load = name => import(pathToFileURL(join(service, 'src', name)))
  const { createWorkspaceInstances } = await load('workspace-instances.mjs')
  const home = join(root, 'home')
  const info = { url: 'http://127.0.0.1:4242', pid: 42, password: 'fixture', version: '2.0.22' }
  const instances = createWorkspaceInstances({ workspaceRoot: root, environment: () => ({ HOME: home }),
    readFile: async () => JSON.stringify(info), signal() {},
    fetch: async () => ({ ok: true, json: async () => info }) })
  await instances.handle({ method: 'POST' }, { writeHead() {}, end() {} },
    new URL('http://localhost/v1/workspace-instances/opencode/start'))
  const openCode = await import(pathToFileURL(join(home, '.config/opencode/plugins/wovenmatter-cli.js')))
  assert.equal(typeof openCode.default.setup, 'function')
  const { createDurableACP } = await load('durable-acp.mjs')
  const child = Object.assign(new EventEmitter(), {
    stdin: new PassThrough(), stdout: new PassThrough(), stderr: new PassThrough(),
    kill() { this.emit('close', 0) },
  })
  let launched
  const relay = createDurableACP({ directory: join(root, 'journal'), workspaceRoot: root,
    catalog: new Map([['codex', { transport: 'acp', command: 'codex-acp' }]]), environment: () => ({}),
    isEnabled: async () => true, spawnProcess: (command, args) => { launched = [command, ...args]; return child } })
  await relay.handle('POST', '/v1/durable-acp/attach', { channelID: 'session', harnessID: 'codex' })
  assert.equal(launched[0], process.execPath)
  assert.equal(launched[1], join(service, 'harnesses/cli/adapter.mjs'))
  assert.ok(existsSync(launched[1]))
  await relay.stopAll()

  const { prepareOpenClawResults } = await load('prepare-openclaw-results.mjs')
  await prepareOpenClawResults({ environment: { HOME: home }, execute: async () => ({ stdout: '{}' }) })
  // A copied plugin must still load after the original service/app is removed.
  rmSync(service, { recursive: true, force: true })
  const plugin = await import(pathToFileURL(join(home, '.wovenmatter/wovenmatter-scheduled-results/index.mjs')))
  const methods = new Map()
  plugin.default.register({ pluginConfig: { directory: join(root, 'results') }, on() {},
    registerGatewayMethod: (name, callback) => methods.set(name, callback) })
  let ready
  methods.get('wovenmatter.cli.bind')({ params: { sessionKey: 'native', inputID: 'input',
    context: { executablePath: '/app/wovenmatter', captureID: 'capture' } },
    respond: (ok, result) => { assert.equal(ok, true); ready = result.ready } })
  assert.equal(ready, true)
})
