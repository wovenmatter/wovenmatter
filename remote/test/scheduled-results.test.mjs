import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, readFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { resolve } from 'node:path'
import { createResultStore } from '../src/openclaw-results/store.mjs'
import plugin from '../src/openclaw-results/index.mjs'
import { prepareOpenClawResults } from '../src/prepare-openclaw-results.mjs'

function fixture(t) {
  const directory = mkdtempSync(resolve(tmpdir(), 'woven-results-'))
  t.after(() => rmSync(directory, { recursive: true, force: true }))
  return directory
}
const run = (id = 'run-1') => ({ action: 'finished', jobId: 'job-1', runId: id,
  sessionId: id, sessionKey: `agent:main:cron:job-1:run:${id}`,
  runAtMs: 1700000000000, durationMs: 100, status: 'ok', job: { name: 'Daily report' } })
// The native embedded-agent context does not currently include jobId.
const context = event => ({ sessionId: event.sessionId, sessionKey: event.sessionKey })
const reply = text => ({ messages: [{ role: 'assistant', content: [{ type: 'text', text }] }], success: true })

test('full output and native run identity survive either hook order, restart, and acknowledgement retry', t => {
  const directory = fixture(t)
  let store = createResultStore(directory)
  const first = run()
  const second = run('run-2')
  const text = 'Report 🌲\n'.repeat(20000)
  store.captureCron(first)
  store = createResultStore(directory)
  assert.equal(store.list({ consumer: 'desktop' }).entries[0].available, false)
  store.captureAgent(reply(text), context(first))
  store.captureAgent(reply('Second report'), context(second))
  store = createResultStore(directory)
  store.captureCron(second)
  const page = store.list({ consumer: 'desktop', limit: 1 })
  assert.equal(page.entries.length, 1)
  const next = store.list({ consumer: 'desktop', after: page.next, limit: 1 })
  assert.equal(next.entries.length, 1)
  const entry = [...page.entries, ...next.entries].find(value => value.run.runId === first.runId)
  let offset = 0, output = ''
  do {
    const chunk = store.output({ id: entry.id, offset })
    output += chunk.text
    offset = chunk.nextOffset
  } while (offset !== null)
  assert.equal(output, text)
  store.acknowledge({ consumer: 'desktop', id: entry.id })
  store = createResultStore(directory)
  store.acknowledge({ consumer: 'desktop', id: entry.id })
  store.captureCron(first)
  assert.equal(store.list({ consumer: 'desktop' }).entries.length, 1)
  assert.equal(store.list({ consumer: 'other-desktop' }).entries.length, 2)
})

test('summary-only success is never acknowledged as complete and unrelated sessions are excluded', t => {
  const store = createResultStore(fixture(t))
  const completed = { ...run(), summary: 'Shortened summary' }
  store.captureAgent(reply('Unrelated text'), { ...context(completed), sessionKey: 'agent:main:main' })
  store.captureCron(completed)
  const entry = store.list({ consumer: 'desktop' }).entries[0]
  assert.equal(entry.available, false)
  assert.throws(() => store.acknowledge({ consumer: 'desktop', id: entry.id }))
  assert.throws(() => store.output({ id: '../../private' }))
  assert.throws(() => store.list({ consumer: '../another-profile' }))
  store.captureCron({ ...run('failure'), status: 'error', error: 'Job failed before a model ran.' })
  const failed = store.list({ consumer: 'desktop' }).entries.find(value => value.run.status === 'error')
  assert.equal(store.output({ id: failed.id }).text, 'Job failed before a model ran.')
})

test('plugin callbacks persist before returning and RPCs use explicit operator scopes', t => {
  const hooks = new Map(), methods = new Map()
  plugin.register({ pluginConfig: { directory: fixture(t) }, logger: { error: assert.fail },
    on: (name, handler) => hooks.set(name, handler),
    registerGatewayMethod: (name, handler, options) => methods.set(name, { handler, options }) })
  assert.equal(hooks.get('agent_end')(reply('Durable now'), context(run())), undefined)
  assert.equal(hooks.get('cron_changed')(run()), undefined)
  let response
  methods.get('wovenmatter.results.list').handler({ params: { consumer: 'desktop' },
    respond: (ok, value) => { assert.equal(ok, true); response = value } })
  assert.equal(response.entries[0].available, true)
  assert.equal(methods.get('wovenmatter.results.list').options.scope, 'operator.read')
  assert.equal(methods.get('wovenmatter.results.ack').options.scope, 'operator.write')
})

test('native plugin configuration patch preserves unrelated secrets and existing plugin policies', async t => {
  const home = fixture(t), calls = []
  const plugins = { load: { paths: ['/existing'] }, allow: ['existing'],
    entries: { existing: { config: { secret: '__OPENCLAW_REDACTED__' } } } }
  await prepareOpenClawResults({ environment: { HOME: home }, execute: async (_, args) => {
    calls.push(args)
    if (args[1] === 'get') return { stdout: JSON.stringify(plugins) }
    assert.deepEqual(args.slice(0, 3), ['config', 'patch', '--file'])
    const patch = JSON.parse(readFileSync(args[3], 'utf8'))
    assert.equal(patch.plugins.entries.existing, undefined)
    assert.ok(patch.plugins.load.paths.includes('/existing'))
    assert.deepEqual(patch.plugins.allow, ['existing', 'wovenmatter-scheduled-results'])
    return { stdout: '' }
  } })
  assert.equal(calls.length, 2)
  await assert.rejects(prepareOpenClawResults({ environment: { HOME: home }, execute: async () => ({ stdout: '{"enabled":false}' }) }), /disabled/)
})
