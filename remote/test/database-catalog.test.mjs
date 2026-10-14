import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, readFile, symlink, rm, readdir } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { spawn, execFileSync } from 'node:child_process'
import { databaseOperation } from '../src/database-catalog.mjs'

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'managed-databases-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  return root
}
const create = (root, name = 'Metrics') => databaseOperation(root, { action: 'create', name })
const execute = (root, id, sql) => databaseOperation(root, { action: 'execute', databaseID: id, sql })
const data = (root, id, sql) => databaseOperation(root, { action: 'data', databaseID: id, sqliteQuery: sql })

test('named datasets have distinct identities and workspace-owned schema and data', async t => {
  const first = await fixture(t), second = await fixture(t)
  const row = await create(first, 'Sales / Q1'), other = await create(second, 'Sales / Q1')
  assert.notEqual(row.id, other.id)
  assert.notEqual(row.owner, other.owner)
  assert.equal(row.preference, 'sqlite')
  assert.equal(fileURLToPath(row.url), join(first, row.id + '.sqlite'))
  assert.equal((await execute(first, row.id, 'CREATE TABLE events(value); INSERT INTO events VALUES(42);')).revision, 2)
  assert.deepEqual((await data(first, row.id, 'SELECT value FROM events')).query.rows, [['42']])
  await assert.rejects(execute(second, row.id, 'DELETE FROM events'), /owner is unavailable/)
  assert.deepEqual((await databaseOperation(first, { action: 'list' })).databases.map(r => r.id), [row.id])
  await mkdir(join(first, 'Unregistered user files'))
  assert.equal((await databaseOperation(first, { action: 'list' })).databases.length, 1)
  await assert.rejects(create(first, 'sales / q1'), /already exists/)
  for (const invalid of ['', 'a'.repeat(129), 'bad\0name']) await assert.rejects(create(first, invalid), /database name/)
})

test('failed multi-statement SQL rolls back data, schema and revision', async t => {
  const root = await fixture(t), row = await create(root)
  await execute(root, row.id, 'CREATE TABLE events(value)')
  for (const sql of ['INSERT INTO events VALUES(1); INSERT INTO missing VALUES(2)',
    'CREATE TABLE transient(value); SELECT * FROM missing', 'BEGIN; INSERT INTO events VALUES(3); COMMIT',
    "ATTACH '/tmp/wovenmatter-forbidden.sqlite' AS foreign_db", 'PRAGMA writable_schema=ON']) {
    await assert.rejects(execute(root, row.id, sql))
  }
  assert.deepEqual((await data(root, row.id, 'SELECT count(*) AS count FROM events')).query.rows, [['0']])
  assert.deepEqual((await data(root, row.id, "SELECT count(*) AS count FROM sqlite_master WHERE name='transient'")).query.rows, [['0']])
  assert.equal((await databaseOperation(root, { action: 'list' })).databases[0].revision, 2)
})

test('queries reject writes, attachments, transaction controls, duplicate names and multiple statements', async t => {
  const root = await fixture(t), row = await create(root)
  await execute(root, row.id, 'CREATE TABLE events(value); INSERT INTO events VALUES(42)')
  for (const sql of ["ATTACH '/tmp/foreign' AS foreign_db", 'DELETE FROM events', 'PRAGMA writable_schema=ON',
    'SELECT 1; SELECT 2', "SELECT load_extension('bad')", 'SELECT 1 AS same, 2 AS same']) {
    await assert.rejects(data(root, row.id, sql))
  }
  assert.deepEqual((await data(root, row.id, 'SELECT value FROM events')).query,
    { contractVersion: 1, columns: ['value'], rows: [['42']] })
})

test('SQLite backups include committed WAL and copy makes an independent writable destination', async t => {
  const root = await fixture(t), destination = await fixture(t), row = await create(root)
  const writer = spawn('/usr/bin/python3', ['-c', `import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute('PRAGMA journal_mode=WAL')
c.execute('CREATE TABLE events(value INTEGER)')
c.execute('INSERT INTO events VALUES (42)')
c.commit()
print('ready',flush=True)
sys.stdin.read()
`, fileURLToPath(row.url)], { stdio: ['pipe', 'pipe', 'inherit'] })
  t.after(() => { writer.stdin.end(); writer.kill() })
  await new Promise((resolve, reject) => { writer.stdout.once('data', resolve); writer.once('error', reject) })
  const snapshot = await databaseOperation(root, { action: 'snapshot', databaseID: row.id })
  const copy = await databaseOperation(destination, { action: 'copy', name: 'Copied metrics', snapshot })
  assert.notEqual(copy.id, row.id)
  assert.notEqual(copy.owner, row.owner)
  assert.equal(copy.revision, 1)
  assert.deepEqual((await data(destination, copy.id, 'SELECT value FROM events')).query.rows, [['42']])
  await execute(destination, copy.id, 'ALTER TABLE events ADD COLUMN label; INSERT INTO events VALUES(43,"copy")')
  assert.deepEqual((await data(root, row.id, 'SELECT value FROM events')).query.rows, [['42']])
  await assert.rejects(databaseOperation(destination, { action: 'copy', name: 'Bad', snapshot: { ...snapshot, sqliteBase64: Buffer.from('not sqlite').toString('base64') } }))
  assert.equal((await databaseOperation(destination, { action: 'list' })).databases.length, 1)
})

test('managed storage rejects linked roots and database files without touching their targets', async t => {
  const root = await fixture(t), outside = await fixture(t)
  const linkedRoot = join(root, 'linked')
  await symlink(outside, linkedRoot)
  await assert.rejects(create(linkedRoot))
  assert.deepEqual(await readdir(outside), [])
  const row = await create(root)
  const external = join(outside, 'user.sqlite')
  execFileSync('/usr/bin/python3', ['-c', 'import sqlite3,sys; c=sqlite3.connect(sys.argv[1]); c.execute("CREATE TABLE user_data(value)"); c.commit()', external])
  await rm(fileURLToPath(row.url))
  await symlink(external, fileURLToPath(row.url))
  await assert.rejects(execute(root, row.id, 'DROP TABLE user_data'))
  assert.equal(execFileSync('/usr/bin/python3', ['-c', 'import sqlite3,sys; print(sqlite3.connect(sys.argv[1]).execute("SELECT name FROM sqlite_master").fetchone()[0])', external], { encoding: 'utf8' }).trim(), 'user_data')
})

test('oversized multi-column conversion is bounded before hex and JSON allocation', async t => {
  const root = await fixture(t), row = await create(root)
  const measurement = JSON.parse(execFileSync('/usr/bin/python3', ['-I', '-c', `
import importlib.util,json,sys,tracemalloc
spec=importlib.util.spec_from_file_location('catalog',sys.argv[1])
catalog=importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)
tracemalloc.start()
try:
    catalog.operation(sys.argv[2],{'action':'query','databaseID':sys.argv[3],'sql':'SELECT '+','.join('zeroblob(1000000) AS c%d'%i for i in range(16))})
except Exception as error:
    print(json.dumps({'error':str(error),'peak':tracemalloc.get_traced_memory()[1]}))
`, join(import.meta.dirname, '../src/database-catalog.py'), root, row.id], { encoding: 'utf8' }))
  assert.match(measurement.error, /too large|memory limit/)
  assert.ok(measurement.peak < 32 * 1024 * 1024, `conversion used ${measurement.peak} Python bytes`)
  for (const expression of ['zeroblob(1000000)', "printf('%1000000s','')", "replace(printf('%700000s',''),' ',char(1))"]) {
    const query = 'SELECT ' + Array.from({ length: 16 }, (_, i) => `${expression} AS c${i}`).join(',')
    await assert.rejects(data(root, row.id, query), error => error.statusCode === 400 && /too large|memory limit/.test(error.message))
  }
  assert.deepEqual((await data(root, row.id, 'SELECT 42 AS answer')).query.rows, [['42']])
})

test('bounded results retain 128 columns within the response budget', async t => {
  const root = await fixture(t), row = await create(root)
  for (const [expression, length] of [["printf('%6000s','')", 6000], ['zeroblob(3000)', 6000]]) {
    const query = 'SELECT ' + Array.from({ length: 128 }, (_, i) => `${expression} AS c${i}`).join(',')
    const result = (await data(root, row.id, query)).query
    assert.equal(result.columns.length, 128)
    assert.equal(result.rows[0].length, 128)
    assert.ok(result.rows[0].every(value => value.length === length))
    assert.ok(Buffer.byteLength(JSON.stringify(result)) < 1024 * 1024)
  }
})

test('Linux service bounds SQLite materialization and returns a controlled memory error', { skip: process.platform !== 'linux' }, async t => {
  const root = await fixture(t), row = await create(root)
  for (const expression of ["printf('%1000000s','')", 'zeroblob(1000000)']) {
    const query = 'SELECT ' + Array.from({ length: 128 }, (_, i) => `${expression} AS c${i}`).join(',')
    await assert.rejects(data(root, row.id, query), error => error.statusCode === 400 && /memory limit/.test(error.message))
  }
  assert.deepEqual((await data(root, row.id, 'SELECT 7 AS answer')).query.rows, [['7']])
})
