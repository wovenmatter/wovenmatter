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
// The number an earlier release may have left in the file. Nothing reads or writes it.
const leftNumber = path => inspect(path, db => db.prepare('PRAGMA user_version').get().user_version)
const schema = path => inspect(path, db => db.prepare("SELECT type,name,sql FROM sqlite_master ORDER BY type,name").all().map(row => ({ ...row })))
// SQLite's own count of schema changes: every CREATE, ALTER or DROP that does something advances it.
const schemaChanges = path => inspect(path, db => db.prepare('PRAGMA schema_version').get().schema_version)
const v042 = `CREATE TABLE central_publication (id INTEGER PRIMARY KEY CHECK(id=1), envelope TEXT NOT NULL, acknowledged INTEGER NOT NULL DEFAULT 0);
  CREATE TABLE retained_publication_receipts (event_id TEXT PRIMARY KEY);
  CREATE TABLE central_publication_lanes (name TEXT PRIMARY KEY, failures INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0, last_success TEXT, last_error_code TEXT);
  INSERT INTO central_publication_lanes(name,failures) VALUES ('journal',3),('artifacts',0);
  CREATE TABLE saved_execution_artifacts (id TEXT PRIMARY KEY, manifest TEXT NOT NULL, bytes BLOB NOT NULL, uploaded INTEGER NOT NULL DEFAULT 0);
  INSERT INTO saved_execution_artifacts VALUES ('artifact', '{}', x'01', 1);
  CREATE TABLE mcp_library_connection (id INTEGER PRIMARY KEY CHECK(id=1), envelope TEXT NOT NULL);`
const v042Tables = ['central_publication', 'retained_publication_receipts', 'central_publication_lanes', 'mcp_library_connection']

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
  // v0.4.3 and v0.4.4 stamped 1; no release wrote 7.
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

test('a v0.4.2 execution store is converted once, by its shape, whatever number the file carries', async t => {
  for (const number of [0, 1, 7]) {
    const path = directory(t)
    inspect(path, db => db.exec(`${v042} PRAGMA user_version=${number}`))
    await open(path).close()
    const converted = schema(path), changes = schemaChanges(path)
    for (const name of v042Tables) assert.ok(!converted.some(row => row.name === name), `${name} (${number})`)
    inspect(path, db => {
      assert.equal(db.prepare("SELECT failures FROM publication_lanes WHERE name='journal'").get().failures, 3)
      assert.deepEqual(db.prepare('PRAGMA table_info(saved_execution_artifacts)').all().map(column => column.name), ['id', 'manifest', 'bytes'])
      assert.equal(db.prepare('SELECT count(*) AS n FROM saved_execution_artifacts').get().n, 1)
    })
    assert.equal(leftNumber(path), number)
    // What the conversion looked for is gone: the next open finds a current store.
    await open(path).close()
    assert.deepEqual(schema(path), converted)
    assert.equal(schemaChanges(path), changes)
  }
})

test('v0.4.2 lanes beside current ones are dropped, and the current ones kept', async t => {
  const path = directory(t)
  await open(path).close()
  inspect(path, db => db.exec(`UPDATE publication_lanes SET failures=2 WHERE name='journal';
    CREATE TABLE central_publication_lanes (name TEXT PRIMARY KEY, failures INTEGER NOT NULL DEFAULT 0, next_attempt INTEGER NOT NULL DEFAULT 0, last_success TEXT, last_error_code TEXT);
    INSERT INTO central_publication_lanes(name,failures) VALUES ('journal',9)`))
  await open(path).close()
  assert.ok(!schema(path).some(row => row.name === 'central_publication_lanes'))
  assert.equal(inspect(path, db => db.prepare("SELECT failures FROM publication_lanes WHERE name='journal'").get().failures), 2)
})

test('an execution store without the later tables gains them at its next open', async t => {
  const path = directory(t)
  inspect(path, db => db.exec(`CREATE TABLE identity (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL);
    CREATE TABLE conversations (id TEXT PRIMARY KEY, body TEXT NOT NULL);`))
  await open(path).close()
  const names = schema(path).map(row => row.name)
  for (const name of ['commands', 'events', 'publication_lanes', 'mcp_tool_receipts', 'mcp_session_messages', 'member_session_watch']) assert.ok(names.includes(name), name)
  assert.equal(leftNumber(path), 0)
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
  const current = randomUUID(), older = randomUUID(), transcript = id => ({ conversationID: id, messages: [], activities: [] })
  inspect(path, db => {
    const insert = db.prepare('INSERT INTO conversations(id,body) VALUES (?,?)')
    insert.run(current, JSON.stringify({ native: {}, creating: true, pending: [], conversation: { id: current, title: 'New conversation', preview: '', runtimeKind: 'default_agent', updatedAt: new Date().toISOString() }, transcript: transcript(current) }))
    // As v0.4.2 saved it: no `creating` mark, title or `updatedAt`.
    insert.run(older, JSON.stringify({ native: {}, pending: [], conversation: { id: older, runtimeKind: 'default_agent' }, transcript: transcript(older) }))
  })
  const second = open(path)
  t.after(() => second.close())
  assert.deepEqual(second.conversations().map(item => item.id), [created.conversationID])
})
