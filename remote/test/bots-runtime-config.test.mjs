import test from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { createBotsService } from '../src/bots-service.mjs'
import { createBotConversationLibrary, createMemoryBotLibraryAdapter } from '../src/bots-library.mjs'

const runtimeConfig = new URL('../../bots/src/config.ts', import.meta.url)
const runnable = existsSync(new URL('../../bots/node_modules/zod/package.json', import.meta.url))

// The server writes the runtime's config; the runtime refuses unknown keys.
test('the supervised runtime config passes the bots runtime schema', { skip: !runnable && 'bots dependencies are not installed' }, async t => {
  const directory = mkdtempSync(join(tmpdir(), 'woven-bots-config-')); t.after(() => rmSync(directory, { recursive: true, force: true }))
  let configuration
  const runtime = { start() {}, stop: async () => {}, restart: async () => {}, endpoint: () => null, status: () => ({}) }
  const service = createBotsService({ configuration: { stateDirectory: directory, dataRoot: directory, serviceRoot: join(directory, 'none'), botsEnabled: true, workspaceEnabled: true, botsInstance: 'wmtest' },
    runtime, engine: { layout: { socket: '/run/wmtest/docker.sock' }, status: async () => ({ installed: false }) }, previews: { recover: async () => {}, close: async () => {} },
    library: createBotConversationLibrary(createMemoryBotLibraryAdapter()), machine: { deviceID: randomUUID(), name: 'box' }, serverPort: () => 7337, authorizeClient: () => false, log: () => {} })
  // Build the same object the supervisor writes, plus its listener and token.
  const { createBotsRuntime } = await import('../src/bots-runtime.mjs')
  const spawned = []
  const supervisor = createBotsRuntime({ packageRoot: '/release/bots', configPath: join(directory, 'runtime.json'), portImpl: async () => 40001,
    spawnImpl: () => { const child = { once() {}, kill() {} }; spawned.push(child); return child }, configuration: async () => configuration })
  configuration = await service.runtimeConfiguration()
  supervisor.start()
  for (let i = 0; i < 50 && !spawned.length; i++) await new Promise(resolve => setTimeout(resolve, 10))
  const { validateRuntimeConfig } = await import(runtimeConfig.href)
  const validated = validateRuntimeConfig(JSON.parse(readFileSync(join(directory, 'runtime.json'), 'utf8')))
  assert.equal(validated.engine.kind, 'linux-dockerd')
  assert.equal(validated.image.tag, 'wovenmatter-bots')
  assert.equal(validated.host.url, 'http://127.0.0.1:7337/')
})
