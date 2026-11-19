import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { DatabaseSync } from 'node:sqlite'
import { createClientExecution } from '../src/client-execution.mjs'
import { enroll } from './fixtures/execution.mjs'

const runtime = (create = async () => ({ sessionID: randomUUID() })) => ({
  providers: async () => [{ id: 'default_agent', runtimeKind: 'default_agent', available: true, canStart: true }],
  create, run: async () => {}, close: async () => {} })
function directory(t) {
  const path = mkdtempSync(join(tmpdir(), 'wm-execution-store-'))
  t.after(() => rmSync(path, { recursive: true, force: true }))
  return path
}
const open = (path, options = {}) => createClientExecution({ directory: path, runtime: runtime(), publisherIntervalMilliseconds: 0, ...options })
function inspect(path, read) {
  const db = new DatabaseSync(join(path, 'execution.sqlite'))
  try { return read(db) } finally { db.close() }
}
// The number the current release left in the file. Nothing reads or writes it.
const leftNumber = path => inspect(path, db => db.prepare('PRAGMA user_version').get().user_version)
const schema = path => inspect(path, db => db.prepare("SELECT type,name,sql FROM sqlite_master ORDER BY type,name").all().map(row => ({ ...row })))
// SQLite's own count of schema changes: every CREATE, ALTER or DROP that does something advances it.
const schemaChanges = path => inspect(path, db => db.prepare('PRAGMA schema_version').get().schema_version)
test('a new execution store carries no version number', async t => {
  const path = directory(t)
  await open(path).close()
  assert.equal(leftNumber(path), 0)
})

test('an execution store carrying a number opens as any other and keeps the number', async t => {
  const path = directory(t)
  const first = open(path)
  const { enrollment, principal } = enroll(first)
  const created = await first.command({ commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'createSession' }, principal)
  assert.equal(created.status, 'completed')
  await first.close()
  const tables = schema(path)
  // Whatever the number is, the store opens the same and keeps it.
  for (const number of [1, 7]) {
    inspect(path, db => db.exec(`PRAGMA user_version=${number}`))
    const service = open(path)
    assert.deepEqual(service.conversations().map(item => item.id), [created.conversationID])
    await service.close()
    assert.equal(leftNumber(path), number)
    assert.deepEqual(schema(path), tables)
  }
})

test('reopening a current execution store changes nothing', async t => {
  const path = directory(t)
  const first = open(path)
  const { enrollment, principal } = enroll(first)
  const created = await first.command({ commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'createSession' }, principal)
  assert.equal(created.status, 'completed')
  await first.close()
  const tables = schema(path), changes = schemaChanges(path)
  const second = open(path)
  assert.deepEqual(second.conversations().map(item => item.id), [created.conversationID])
  await second.close()
  assert.deepEqual(schema(path), tables)
  assert.equal(schemaChanges(path), changes)
  assert.equal(leftNumber(path), 0)
})

test('native records the current release journaled take today\'s format names, once', async t => {
  const path = directory(t)
  const first = open(path)
  const { enrollment, principal } = enroll(first)
  const created = await first.command({ commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'createSession' }, principal)
  await first.close()
  // As the current release wrote them: an update in two parts, an activity, and an ordinary entry between.
  const record = (format, partIndex, partCount) => ({ eventID: randomUUID(), recordedAt: '2026-11-18T10:00:00.000Z', workspaceID: enrollment.workspaceID,
    conversationID: created.conversationID, kind: 'nativeRecord', runID: randomUUID(),
    nativeRecord: { recordID: 'r-' + format, format, partIndex, partCount, byteCount: 5.0, sha256: 'ab'.repeat(32), data: Buffer.from('héllo "quoted" \\ 1e3').toString('base64') } })
  const stored = [record('woven-native-update-v1', 0, 2), record('woven-native-update-v1', 1, 2),
    { eventID: randomUUID(), recordedAt: '2026-11-18T10:00:01.000Z', workspaceID: enrollment.workspaceID, conversationID: created.conversationID, kind: 'receipt', note: 'format "woven-native-update-v1" in prose stays' },
    record('wovenmatter.activity.v2', 0, 1)]
  const bodies = () => inspect(path, db => db.prepare("SELECT body FROM events WHERE json_extract(body,'$.eventID') IN (" + stored.map(() => '?').join(',') + ') ORDER BY sequence').all(...stored.map(entry => entry.eventID)).map(row => row.body))
  inspect(path, db => { for (const entry of stored) db.prepare('INSERT INTO events(body) VALUES (?)').run(JSON.stringify(entry)) })
  const second = open(path)
  const replayed = second.events(0).entries.filter(entry => stored.some(item => item.eventID === entry.eventID))
  await second.close()
  assert.deepEqual(replayed.map(entry => entry.nativeRecord?.format ?? null), ['woven-native-update', 'woven-native-update', null, 'wovenmatter.activity.chained'])
  // Nothing but the name changed, byte for byte.
  const expected = stored.map(entry => JSON.stringify(entry.nativeRecord ? { ...entry, nativeRecord: { ...entry.nativeRecord,
    format: { 'woven-native-update-v1': 'woven-native-update', 'wovenmatter.activity.v2': 'wovenmatter.activity.chained' }[entry.nativeRecord.format] } } : entry))
  const converted = bodies()
  assert.deepEqual(converted, expected)
  // Nothing is left to find: the next open leaves every row as it is, and so does one after new records.
  await open(path).close()
  assert.deepEqual(bodies(), converted)
  assert.equal(inspect(path, db => db.prepare("SELECT count(*) AS n FROM events WHERE body LIKE '%\"format\":\"woven-native-update-v1\"%' OR body LIKE '%\"format\":\"wovenmatter.activity.v2\"%'").get().n), 0)
})

test('the registration the current release stored keeps what a workspace stores today, once', async t => {
  const path = directory(t)
  const first = open(path)
  const { enrollment } = enroll(first)
  const registered = first.descriptor()
  await first.close()
  assert.deepEqual(Object.keys(registered).sort(), ['capabilities', 'deleted', 'executionDeviceID', 'id', 'kind', 'libraryID', 'name', 'ownerDeviceID', 'revision'])
  const body = () => inspect(path, db => db.prepare('SELECT body FROM identity WHERE id=1').get().body)
  const today = body()
  assert.deepEqual(Object.keys(JSON.parse(today)).sort(), ['deleted', 'executionDeviceID', 'id', 'kind', 'libraryID', 'name', 'ownerDeviceID', 'revision'])
  // As the current release stored it: with the capabilities it served and the devices following its journal.
  inspect(path, db => db.prepare('UPDATE identity SET body=? WHERE id=1').run(JSON.stringify({ ...JSON.parse(today),
    capabilities: ['execution', 'historyReplay', 'idempotentCommands'], journalDeviceIDs: [] })))
  const second = open(path)
  assert.deepEqual(second.descriptor(), registered)
  assert.equal(second.descriptor().id, enrollment.workspaceID)
  await second.close()
  const converted = body()
  assert.deepEqual(JSON.parse(converted), JSON.parse(today))
  // Nothing is left to find: the next open leaves the row as it is.
  await open(path).close()
  assert.equal(body(), converted)
})

test('a session being created is listed as a complete conversation before its harness starts', async t => {
  const path = directory(t)
  let started, release
  const gate = new Promise(resolve => { release = resolve })
  const service = open(path, { runtime: runtime(async () => { started(); await gate; return { sessionID: randomUUID() } }) })
  t.after(() => service.close())
  const { enrollment, principal } = enroll(service)
  const conversationID = randomUUID(), creating = new Promise(resolve => { started = resolve })
  const reply = service.command({ commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'createSession', conversationID, title: 'Named' }, principal)
  await creating
  const placeholder = service.summary(conversationID).conversation
  assert.equal(placeholder.title, 'Named'); assert.equal(placeholder.preview, ''); assert.equal(typeof placeholder.updatedAt, 'string')
  assert.ok(placeholder.updatedAt); assert.equal(placeholder.providerID, 'default_agent'); assert.equal(placeholder.workspaceID, enrollment.workspaceID)
  release()
  assert.equal((await reply).status, 'completed')
  const conversation = service.summary(conversationID).conversation
  assert.equal(conversation.title, 'Named')
  assert.deepEqual(Object.keys(conversation), Object.keys(placeholder))
})

test('a session whose creation the process did not finish is removed at startup', async t => {
  const path = directory(t)
  const first = open(path)
  const { enrollment, principal } = enroll(first)
  const created = await first.command({ commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'createSession' }, principal)
  await first.close()
  const current = randomUUID(), transcript = id => ({ conversationID: id, messages: [], activities: [] })
  inspect(path, db => {
    const insert = db.prepare('INSERT INTO conversations(id,body) VALUES (?,?)')
    insert.run(current, JSON.stringify({ native: {}, creating: true, pending: [], conversation: { id: current, title: 'New conversation', preview: '', runtimeKind: 'default_agent', updatedAt: new Date().toISOString() }, transcript: transcript(current) }))
  })
  const second = open(path)
  t.after(() => second.close())
  assert.deepEqual(second.conversations().map(item => item.id), [created.conversationID])
})
