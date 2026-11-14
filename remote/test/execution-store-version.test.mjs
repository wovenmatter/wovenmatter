import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtempSync, readdirSync, readFileSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { randomUUID } from 'node:crypto'
import { DatabaseSync } from 'node:sqlite'
import { createClientExecution, executionSchemaVersion } from '../src/client-execution.mjs'
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
const version = path => inspect(path, db => db.prepare('PRAGMA user_version').get().user_version)
const schema = path => inspect(path, db => db.prepare("SELECT type,name,sql FROM sqlite_master ORDER BY type,name").all().map(row => ({ ...row })))

test('a new execution store records the current schema version', async t => {
  const path = directory(t)
  await (await open(path)).close()
  assert.equal(executionSchemaVersion, 1)
  assert.equal(version(path), executionSchemaVersion)
})

test('an execution store from a newer Woven Matter is refused and left unchanged', async t => {
  const path = directory(t)
  await (await open(path)).close()
  inspect(path, db => db.exec(`PRAGMA user_version=${executionSchemaVersion + 1}`))
  const file = join(path, 'execution.sqlite'), before = readFileSync(file), files = readdirSync(path).sort()
  assert.throws(() => open(path), error => {
    assert.equal(error.code, 'execution_store_newer')
    assert.match(error.message, /written by a newer Woven Matter/)
    assert.match(error.message, new RegExp(`version ${executionSchemaVersion + 1}\\b`))
    assert.match(error.message, new RegExp(`supports version ${executionSchemaVersion}\\b`))
    assert.match(error.message, /Update Woven Matter/)
    return true
  })
  assert.deepEqual(readFileSync(file), before)
  assert.deepEqual(readdirSync(path).sort(), files)
})

test('reopening a current execution store changes nothing, and skips the conversions of older shapes', async t => {
  const path = directory(t)
  const first = open(path)
  const { enrollment, principal } = enroll(first)
  const created = await first.command({ commandID: randomUUID(), deviceID: enrollment.deviceID, kind: 'createSession' }, principal)
  assert.equal(created.status, 'completed')
  await first.close()
  const tables = schema(path)
  const second = open(path)
  assert.deepEqual(second.conversations().map(item => item.id), [created.conversationID])
  await second.close()
  assert.deepEqual(schema(path), tables)
  assert.equal(version(path), executionSchemaVersion)
  // Step 1 drops this v0.4.2 table from a version-0 file only.
  inspect(path, db => db.exec('CREATE TABLE mcp_library_connection (id INTEGER PRIMARY KEY CHECK(id=1), envelope TEXT NOT NULL)'))
  await open(path).close()
  assert.ok(schema(path).some(row => row.name === 'mcp_library_connection'))
})

test('a version-0 execution store without the later tables is upgraded and stamped', async t => {
  const path = directory(t)
  inspect(path, db => db.exec(`CREATE TABLE identity (id INTEGER PRIMARY KEY CHECK(id=1), body TEXT NOT NULL);
    CREATE TABLE conversations (id TEXT PRIMARY KEY, body TEXT NOT NULL);
    CREATE TABLE mcp_library_connection (id INTEGER PRIMARY KEY CHECK(id=1), envelope TEXT NOT NULL);`))
  assert.equal(version(path), 0)
  await open(path).close()
  const names = schema(path).map(row => row.name)
  for (const name of ['commands', 'events', 'publication_lanes', 'mcp_tool_receipts', 'mcp_session_messages', 'member_session_watch']) assert.ok(names.includes(name), name)
  assert.ok(!names.includes('mcp_library_connection'))
  assert.equal(version(path), executionSchemaVersion)
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
    // As builds before the version was recorded saved it.
    insert.run(older, JSON.stringify({ native: {}, pending: [], conversation: { id: older, runtimeKind: 'default_agent' }, transcript: transcript(older) }))
  })
  const second = open(path)
  t.after(() => second.close())
  assert.deepEqual(second.conversations().map(item => item.id), [created.conversationID])
})
