import test from 'node:test'
import assert from 'node:assert/strict'
import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'
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

// Bots load the SDK copy this machine's Pi Durable runs: the server names Pi
// Durable's bundle and SDK workspace, and the runtime resolves the copy from them.
test('the runtime is pointed at this machine’s Pi Durable, whose SDK copy it loads', async t => {
  const { defaultAgentBundle } = await import('../src/bots-service.mjs')
  const present = new Set(['/release/default-agent/src/sdk-management.mjs'])
  assert.equal(defaultAgentBundle('/release', { exists: path => present.has(path) }), '/release/default-agent')
  assert.equal(defaultAgentBundle('/checkout/remote', { exists: path => path === '/checkout/default-agent/src/sdk-management.mjs' }), join('/checkout/remote', '..', 'default-agent'))
  assert.equal(defaultAgentBundle('/elsewhere', { exists: () => false }), null)
  if (!runnable) return
  const directory = mkdtempSync(join(tmpdir(), 'woven-bots-sdk-')); t.after(() => rmSync(directory, { recursive: true, force: true }))
  const serviceRoot = fileURLToPath(new URL('..', import.meta.url)).replace(/\/$/, '')
  const sdkDirectory = join(directory, 'workspace/.wovenmatter/default-agent')
  let restarts = 0, running = false
  const service = createBotsService({ configuration: { stateDirectory: directory, dataRoot: directory, serviceRoot, botsEnabled: true, workspaceEnabled: true, botsInstance: 'wmtest' },
    defaultAgentDirectory: sdkDirectory,
    runtime: { start() {}, stop: async () => {}, restart: async () => { restarts++ }, endpoint: () => null, status: () => ({ running }) }, engine: { layout: { socket: '/run/wmtest/docker.sock' }, status: async () => ({ installed: false }) },
    previews: { recover: async () => {}, close: async () => {} }, library: createBotConversationLibrary(createMemoryBotLibraryAdapter()), machine: { deviceID: randomUUID(), name: 'box' },
    serverPort: () => 7337, authorizeClient: () => false, log: () => {} })
  const { validateRuntimeConfig } = await import(runtimeConfig.href)
  const configuration = { ...await service.runtimeConfiguration(), listen: { host: '127.0.0.1', port: 40001 }, runtimeToken: 'r'.repeat(43) }
  const validated = validateRuntimeConfig(configuration)
  assert.deepEqual(validated.piDurable, { bundle: join(serviceRoot, '..', 'default-agent'), directory: sdkDirectory })
  // The runtime takes the Claude binary from that copy; the server names none.
  assert.equal(validated.claude, undefined)
  // After an SDK update a running runtime restarts onto the new copy; a stopped one waits.
  await service.piDurableSDKUpdated()
  assert.equal(restarts, 0)
  running = true
  await service.piDurableSDKUpdated()
  assert.equal(restarts, 1)
})
