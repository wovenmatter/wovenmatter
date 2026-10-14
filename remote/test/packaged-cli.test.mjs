import test from 'node:test'
import assert from 'node:assert/strict'
import { cpSync, existsSync, mkdtempSync, realpathSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { pathToFileURL } from 'node:url'
import { EventEmitter } from 'node:events'
import { PassThrough } from 'node:stream'
import { spawnSync } from 'node:child_process'

test('deployed service layout loads retained CLI integrations and shared instructions', async t => {
  const root = realpathSync(mkdtempSync(join(tmpdir(), 'woven-packaged-cli-')))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  // Match remote/Dockerfile's COPY destinations without building an image.
  const service = join(root, 'service with spaces')
  cpSync(resolve(import.meta.dirname, '../src'), join(service, 'src'), { recursive: true, verbatimSymlinks: true })
  cpSync(resolve(import.meta.dirname, '../../harnesses'), join(service, 'harnesses'), { recursive: true })
  cpSync(resolve(import.meta.dirname, '../../default-agent/src/package-versions.mjs'), join(service, 'default-agent/src/package-versions.mjs'), { recursive: true })
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

  const instructions = await import(pathToFileURL(join(service, 'harnesses/cli/instructions.mjs')))
  assert.match(instructions.wovenInstructions, /wovenmatter help/)
  // SDK updates copy src into an independent generation. Its worker still
  // points at the central shipped resource, without copying model instructions.
  const generation = join(root, 'generation/src')
  cpSync(resolve(import.meta.dirname, '../../default-agent/src/woven-instructions.mjs'),
    join(generation, 'woven-instructions.mjs'))
  const loaded = spawnSync(process.execPath, ['--input-type=module', '--eval',
    `const { wovenInstructions } = await import(${JSON.stringify(pathToFileURL(join(generation, 'woven-instructions.mjs')).href)}); process.stdout.write(wovenInstructions);`],
    { env: { ...process.env, WOVENMATTER_INSTRUCTIONS_FILE: join(service, 'harnesses/woven-instructions.txt') }, encoding: 'utf8' })
  assert.equal(loaded.status, 0, loaded.stderr)
  assert.equal(loaded.stdout, instructions.wovenInstructions)
})
