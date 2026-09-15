import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, writeFile, readFile, symlink, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { spawn, execFileSync } from 'node:child_process'
import { databaseOperation } from '../src/database-catalog.mjs'

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'remote-databases-'))
  t.after(() => rm(root, { recursive: true, force: true }))
  await mkdir(join(root, 'Databases'))
  return root
}
const create = (root, databaseID = 'Metrics', preference = 'none') => databaseOperation(root, { action: 'create', databaseID, preference })
const data = (root, relativePath, sqliteQuery) => databaseOperation(root, { action: 'data', databaseID: 'Metrics', relativePath, sqliteQuery })

test('catalog creation, agent-written discovery and preferences remain workspace scoped', async t => {
  const first = await fixture(t), second = await fixture(t)
  assert.deepEqual(await create(first, 'Metrics', 'sqlite'), { id: 'Metrics', name: 'Metrics', preference: 'sqlite' })
  await mkdir(join(first, 'Databases', 'Agent data'))
  assert.deepEqual((await databaseOperation(first, { action: 'list' })).databases.map(r => r.id), ['Agent data', 'Metrics'])
  assert.deepEqual(await databaseOperation(second, { action: 'list' }), { databases: [] })
  await databaseOperation(first, { action: 'preference', databaseID: 'Metrics', preference: 'json' })
  assert.deepEqual(JSON.parse(await readFile(join(first, 'Databases/Metrics/.wovenmatter/database.json'))), { schema: 'wovenmatter.database.v1', preference: 'json' })
  await assert.rejects(create(first), /already exists/)
  for (const invalid of ['../escape', '.hidden', 'a/b', 'a\\b', '', 'a'.repeat(129)]) await assert.rejects(create(first, invalid), /Invalid database name/)
  await assert.rejects(create(first, 'Invalid', 'xml'), /Invalid data preference/)
})

test('JSON reads reject traversal, symlinks, special files and oversized content', async t => {
  const root = await fixture(t)
  await create(root, 'Metrics', 'json')
  const db = join(root, 'Databases/Metrics')
  await writeFile(join(db, 'rows.json'), '[{"value":42}]')
  assert.equal(Buffer.from((await data(root, 'rows.json')).jsonBase64, 'base64').toString(), '[{"value":42}]')
  await writeFile(join(root, 'secret.json'), 'secret')
  await symlink(join(root, 'secret.json'), join(db, 'escape.json'))
  await symlink(root, join(db, 'outside'))
  await symlink(db, join(root, 'Databases/Alias'))
  for (const path of ['../secret.json', '/secret.json', 'outside/secret.json', 'escape.json', '.wovenmatter/database.json', 'a//b']) {
    await assert.rejects(data(root, path))
  }
  assert.equal((await databaseOperation(root, { action: 'list' })).databases.length, 1)
  await assert.rejects(databaseOperation(root, { action: 'preference', databaseID: 'Alias', preference: 'sqlite' }))
  execFileSync('mkfifo', [join(db, 'pipe.json')])
  await assert.rejects(data(root, 'pipe.json'), /regular file/)
  await writeFile(join(db, 'large.json'), Buffer.alloc(4 * 1024 * 1024 + 1))
  await assert.rejects(data(root, 'large.json'), /too large/)
  await rm(join(db, '.wovenmatter'), { recursive: true })
  await symlink(root, join(db, '.wovenmatter'))
  await assert.rejects(databaseOperation(root, { action: 'preference', databaseID: 'Metrics', preference: 'sqlite' }))
  assert.equal(await readFile(join(root, 'secret.json'), 'utf8'), 'secret')
})

test('root confinement refuses a linked Databases directory', async t => {
  const root = await fixture(t), outside = await fixture(t)
  await rm(join(root, 'Databases'), { recursive: true })
  await symlink(join(outside, 'Databases'), join(root, 'Databases'))
  await assert.rejects(create(root))
  assert.deepEqual(await databaseOperation(outside, { action: 'list' }), { databases: [] })
})

test('SQLite snapshot includes committed WAL and rejects writes, attachment and unsafe sidecars', async t => {
  const root = await fixture(t)
  await create(root, 'Metrics', 'sqlite')
  const db = join(root, 'Databases/Metrics/events.sqlite')
  // Keep the writer alive: closing the final connection would checkpoint the WAL.
  const writer = spawn('python3', ['-c', `import sqlite3,sys
c=sqlite3.connect(sys.argv[1])
c.execute('PRAGMA journal_mode=WAL')
c.execute('CREATE TABLE events(value INTEGER)')
c.execute('INSERT INTO events VALUES (42)')
c.commit()
print('ready',flush=True)
sys.stdin.read()
`, db], { stdio: ['pipe', 'pipe', 'inherit'] })
  t.after(() => { writer.stdin.end(); writer.kill() })
  await new Promise((resolve, reject) => { writer.stdout.once('data', resolve); writer.once('error', reject) })
  const result = await data(root, 'events.sqlite', 'SELECT value FROM events')
  assert.deepEqual(result.query, { contractVersion: 1, columns: ['value'], rows: [['42']] })
  for (const query of ["ATTACH '/tmp/foreign' AS foreign_db", 'DELETE FROM events', 'PRAGMA writable_schema=ON', 'SELECT 1; SELECT 2', "SELECT load_extension('bad')"]) {
    await assert.rejects(data(root, 'events.sqlite', query), /read-only SQLite/)
  }
  assert.equal((await data(root, 'events.sqlite', 'SELECT count(*) AS count FROM events')).query.rows[0][0], '1')
  await writeFile(db + '-journal', Buffer.alloc(513, 1))
  await assert.rejects(data(root, 'events.sqlite', 'SELECT value FROM events'), /changing/)
  await writeFile(db + '-journal', Buffer.alloc(513)) // Retained PERSIST journal is not hot.
  assert.equal((await data(root, 'events.sqlite', 'SELECT value FROM events')).query.rows[0][0], '42')
  await rm(db + '-journal')
  await symlink(join(root, 'secret'), db + '-journal')
  await assert.rejects(data(root, 'events.sqlite', 'SELECT value FROM events'))
})

test('oversized multi-column conversion is bounded before hex and JSON allocation', async t => {
  const root = await fixture(t)
  await create(root, 'Metrics', 'sqlite')
  const db = join(root, 'Databases/Metrics/bounds.sqlite')
  execFileSync('/usr/bin/python3', ['-c', 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).close()', db])
  // Trace the real query/conversion path. Previously 16 MB of blobs expanded to
  // 112 MB of Python allocations before the response-size check rejected it.
  const measurement = JSON.parse(execFileSync('/usr/bin/python3', ['-I', '-c', `
import importlib.util,json,os,sys,tracemalloc
spec=importlib.util.spec_from_file_location('catalog',sys.argv[1])
catalog=importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)
fd=os.open(sys.argv[2],os.O_RDONLY)
tracemalloc.start()
try:
    catalog.sqlite_query(fd,'bounds.sqlite','SELECT '+','.join('zeroblob(1000000) AS c%d'%i for i in range(16)))
except catalog.CatalogError as error:
    print(json.dumps({'error':str(error),'peak':tracemalloc.get_traced_memory()[1]}))
finally:
    os.close(fd)
`, join(import.meta.dirname, '../src/database-catalog.py'), join(root, 'Databases/Metrics')], { encoding: 'utf8' }))
  assert.match(measurement.error, /result is too large/)
  assert.ok(measurement.peak < 32 * 1024 * 1024, `conversion used ${measurement.peak} Python bytes`)
  for (const expression of ['zeroblob(1000000)', "printf('%1000000s','')", "replace(printf('%700000s',''),' ',char(1))"]) {
    const query = 'SELECT ' + Array.from({ length: 16 }, (_, i) => `${expression} AS c${i}`).join(',')
    await assert.rejects(data(root, 'bounds.sqlite', query), error => error.statusCode === 400 && /too large|memory limit/.test(error.message))
  }
  assert.deepEqual((await data(root, 'bounds.sqlite', 'SELECT 42 AS answer')).query.rows, [['42']])
})

test('bounded results retain 128 columns and nearly 4 MiB of text or hex output', async t => {
  const root = await fixture(t)
  await create(root, 'Metrics', 'sqlite')
  const db = join(root, 'Databases/Metrics/bounds.sqlite')
  execFileSync('/usr/bin/python3', ['-c', 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).close()', db])
  for (const [expression, length] of [["printf('%32700s','')", 32700], ['zeroblob(16000)', 32000]]) {
    const query = 'SELECT ' + Array.from({ length: 128 }, (_, i) => `${expression} AS c${i}`).join(',')
    const result = (await data(root, 'bounds.sqlite', query)).query
    assert.equal(result.columns.length, 128)
    assert.equal(result.rows[0].length, 128)
    assert.ok(result.rows[0].every(value => value.length === length))
    assert.ok(Buffer.byteLength(JSON.stringify(result)) < 4 * 1024 * 1024)
  }
})

test('Linux service bounds SQLite materialization and returns a controlled memory error', { skip: process.platform !== 'linux' }, async t => {
  // Apple's SQLite disables native memory accounting; the deployed Linux service
  // fails closed unless hard_heap_limit is enforced. CI runs this on Linux.
  const root = await fixture(t)
  await create(root, 'Metrics', 'sqlite')
  const db = join(root, 'Databases/Metrics/bounds.sqlite')
  execFileSync('/usr/bin/python3', ['-c', 'import sqlite3,sys; sqlite3.connect(sys.argv[1]).close()', db])
  for (const expression of ["printf('%1000000s','')", 'zeroblob(1000000)']) {
    const query = 'SELECT ' + Array.from({ length: 128 }, (_, i) => `${expression} AS c${i}`).join(',')
    await assert.rejects(data(root, 'bounds.sqlite', query), error => error.statusCode === 400 && /memory limit/.test(error.message))
  }
  assert.deepEqual((await data(root, 'bounds.sqlite', 'SELECT 7 AS answer')).query.rows, [['7']])
})
