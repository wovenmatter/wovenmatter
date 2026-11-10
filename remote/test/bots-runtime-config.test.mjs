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

// Bots run the default agent's Claude binary instead of shipping their own
// copy, so both packages must select the same Claude Agent SDK.
test('the runtime is pointed at the default agent’s Claude binary, which matches the bots SDK', async t => {
  const { defaultAgentClaude } = await import('../src/bots-service.mjs')
  const present = new Set(['/release/default-agent/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64-musl/claude'])
  assert.equal(defaultAgentClaude('/release', { platform: 'linux', arch: 'x64', exists: path => present.has(path) }), [...present][0])
  assert.equal(defaultAgentClaude('/release', { platform: 'linux', arch: 'arm64', exists: path => present.has(path) }), null)
  const sdk = path => JSON.parse(readFileSync(new URL(path, import.meta.url), 'utf8')).packages['node_modules/@anthropic-ai/claude-agent-sdk'].version
  assert.equal(sdk('../../bots/package-lock.json'), sdk('../../default-agent/package-lock.json'), 'refresh bots/ and default-agent/ to the same Claude Agent SDK')
  if (!runnable) return
  const directory = mkdtempSync(join(tmpdir(), 'woven-bots-claude-')); t.after(() => rmSync(directory, { recursive: true, force: true }))
  const service = createBotsService({ configuration: { stateDirectory: directory, dataRoot: directory, serviceRoot: join(directory, 'none'), botsEnabled: true, workspaceEnabled: true, botsInstance: 'wmtest',
    claudeExecutable: '/release/default-agent/node_modules/@anthropic-ai/claude-agent-sdk-linux-x64/claude' },
    runtime: { start() {}, stop: async () => {}, endpoint: () => null, status: () => ({}) }, engine: { layout: { socket: '/run/wmtest/docker.sock' }, status: async () => ({ installed: false }) },
    previews: { recover: async () => {}, close: async () => {} }, library: createBotConversationLibrary(createMemoryBotLibraryAdapter()), machine: { deviceID: randomUUID(), name: 'box' },
    serverPort: () => 7337, authorizeClient: () => false, log: () => {} })
  const { validateRuntimeConfig } = await import(runtimeConfig.href)
  const configuration = { ...await service.runtimeConfiguration(), listen: { host: '127.0.0.1', port: 40001 }, runtimeToken: 'r'.repeat(43) }
  assert.equal(validateRuntimeConfig(configuration).claude.executable, configuration.claude.executable)
})
