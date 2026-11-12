import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID, createHash } from 'node:crypto'
import { createClientExecution } from '../src/client-execution.mjs'
import { lineCounts, summary, toolActivity } from '../src/activity-projection.mjs'
import { enroll } from './fixtures/execution.mjs'

const turn = () => new Promise(resolve => setImmediate(resolve))
function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'wm-activity-'))
  const runs = []
  const runtime = { providers: async () => [{ id: 'default_agent', runtimeKind: 'default_agent', available: true, canStart: true }], create: async () => ({ sessionID: randomUUID() }),
    run: async input => { const done = Promise.withResolvers(); runs.push({ ...input, done }); await done.promise },
    settings: async () => ({ model: 'gpt', thinking: null, permission: null, models: [], thinkingLevels: [], permissions: [], canConfigure: true }),
    stop: async () => {}, respond: async () => {}, steer: async () => {}, close: async () => { for (const run of runs) run.done.resolve() } }
  const service = createClientExecution({ directory, runtime })
  const { enrollment, principal } = enroll(service, { endpoint: 'https://machine.tail.ts.net:8443/wovenmatter-execution/test' })
  const command = (kind, values = {}) => ({ commandID: randomUUID(), deviceID: enrollment.deviceID, libraryID: enrollment.libraryID, workspaceID: enrollment.workspaceID, kind, ...values })
  t.after(async () => { await service.close(); rmSync(directory, { recursive: true, force: true }) })
  return { service, runs, principal, command }
}
async function running(f, text = 'work') {
  const opened = await f.service.command(f.command('createSession'), f.principal)
  const receipt = await f.service.command(f.command('send', { conversationID: opened.conversationID, text }), f.principal)
  await turn()
  return { id: opened.conversationID, runID: receipt.runID, run: f.runs.at(-1) }
}
const flushed = () => new Promise(resolve => setTimeout(resolve, 600))
const projection = activity => JSON.parse(activity.projectionJSON)

test('a tool row carries the compact projection; its disclosure reads the full one', async t => {
  const f = fixture(t), { id, runID, run } = await running(f)
  run.publish({ sessionUpdate: 'tool_call', toolCallId: 'edit', title: 'Edit app.swift', kind: 'edit', status: 'in_progress',
    rawInput: { path: '/work/app.swift' }, locations: [{ path: '/work/app.swift', line: 3 }] })
  run.publish({ sessionUpdate: 'tool_call_update', toolCallId: 'edit', status: 'completed', rawOutput: { ok: true },
    content: [{ type: 'diff', path: '/work/app.swift', oldText: 'a\nb\nc', newText: 'a\nB\nc\nd' }, { type: 'content', content: { type: 'text', text: 'Edited' } }] })
  const row = f.service.transcript(id).activities.find(item => item.id === runID + ':edit')
  const compact = projection(row)
  assert.equal(compact.kind, 'tool'); assert.equal(compact.toolName, 'edit'); assert.equal(compact.status, 'completed')
  assert.equal(compact.title, 'Edit app.swift'); assert.equal(compact.content, 'Edited')
  assert.deepEqual(compact.locations, [{ path: '/work/app.swift', line: 3 }])
  assert.deepEqual(compact.changes, [{ path: '/work/app.swift', newText: '', additionCount: 2, deletionCount: 1 }])
  assert.equal(compact.detailsAvailable, true); assert.equal(compact.rawInputJSON, undefined)
  assert.equal(row.detail, 'Edited'); assert.equal(row.status, 'completed'); assert.ok(row.sequence > 0); assert.ok(row.createdAt)
  const full = projection(f.service.activityDetails(id, row.id))
  assert.equal(full.rawInputJSON, JSON.stringify({ path: '/work/app.swift' }))
  assert.equal(full.rawOutputJSON, JSON.stringify({ ok: true }))
  assert.deepEqual(full.changes, [{ path: '/work/app.swift', oldText: 'a\nb\nc', newText: 'a\nB\nc\nd' }])
  assert.equal(full.position, compact.position)
  assert.throws(() => f.service.activityDetails(id, 'missing'), { statusCode: 404 })
  // The settled tool's full projection is journaled once, for library history.
  assert.match(row.detailsRecordID, /^activity-[0-9a-f]{64}-[0-9a-f]{64}$/)
  const parts = f.service.events().entries.flatMap(entry => entry.nativeRecord?.recordID === row.detailsRecordID ? [entry.nativeRecord] : [])
  assert.equal(parts[0].format, 'wovenmatter.activity.v2')
  const bytes = Buffer.concat(parts.map(part => Buffer.from(part.data, 'base64')))
  assert.equal(createHash('sha256').update(bytes).digest('hex'), parts[0].sha256)
  assert.equal(JSON.parse(bytes).activity.rawInputJSON, full.rawInputJSON)
})

test('text written before work becomes commentary at its position, then the work follows', async t => {
  const f = fixture(t), { id, runID, run } = await running(f)
  run.publish({ sessionUpdate: 'agent_message_chunk', content: { text: 'Looking first.' } })
  run.publish({ sessionUpdate: 'tool_call', toolCallId: 'read', title: 'Read', kind: 'read', status: 'in_progress' })
  run.publish({ sessionUpdate: 'agent_message_chunk', content: { text: ' Done.' } })
  run.publish({ sessionUpdate: 'plan', entries: [{ content: 'Read', status: 'completed', priority: 'high' }, { content: 'Write', status: 'pending' }] })
  run.done.resolve(); await turn()
  const transcript = f.service.transcript(id)
  const values = transcript.activities.map(projection)
  assert.deepEqual(values.map(value => value.kind), ['assistant', 'tool', 'assistant', 'plan'])
  assert.deepEqual(values.filter(value => value.kind === 'assistant').map(value => [value.assistantMessageID, value.content]), [[runID, 'Looking first.'], [runID, ' Done.']])
  assert.deepEqual(values.map(value => value.position), [...values.map(value => value.position)].sort((a, b) => a - b))
  assert.deepEqual(values[3].planEntries, [{ content: 'Read', status: 'completed', priority: 'high' }, { content: 'Write', status: 'pending' }])
  assert.equal(values[3].planOperation, 'replace')
  assert.equal(transcript.messages.find(message => message.id === runID).content, 'Looking first. Done.')
  // The run's timing reaches the transcript.
  const timing = transcript.runs.find(item => item.id === runID)
  assert.equal(timing.status, 'completed'); assert.ok(timing.startedAt <= timing.completedAt)
  // The journal's transcript entries carry the run too.
  await flushed()
  assert.ok(f.service.events().entries.some(entry => entry.transcript?.runs?.some(item => item.id === runID && item.status === 'completed')))
})

test('the session settings carry the harness command palette', async t => {
  const f = fixture(t), { id, run } = await running(f)
  run.publish({ sessionUpdate: 'available_commands_update', availableCommands: [{ name: 'review', description: 'Review changes', input: { hint: 'path' } }, { name: '' }] })
  const result = await f.service.readWorkspace({ session: { id } })
  assert.deepEqual(result.session._0.commands, [{ name: 'review', detail: 'Review changes', argumentHint: 'path' }])
})

test('compact projections count changed lines and bound their text', () => {
  assert.deepEqual(lineCounts('a\nb', 'a\nb\nc'), { additions: 1, deletions: 0 })
  assert.deepEqual(lineCounts('', '', '--- a\n+++ b\n+x\n-y\n-z'), { additions: 1, deletions: 2 })
  const long = 'x'.repeat(1000), full = toolActivity({ toolCallId: 'a', title: long, content: [{ type: 'content', content: { text: long } }] }, undefined, 'a')
  const compact = summary(full, 4)
  assert.equal(compact.title.length, 280); assert.equal(compact.content.length, 280); assert.equal(compact.detailVersion, 4)
  assert.equal(compact.detailsAvailable, true); assert.equal(compact.rawPayloadJSON, undefined)
  // Terminal output deltas append to what the tool already showed.
  const next = toolActivity({ toolCallId: 'a', _meta: { terminal_output_delta: { data: '!' } } }, full, 'a')
  assert.equal(next.content, long + '!')
})
