import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, mkdir, symlink, rm, readdir } from 'node:fs/promises';
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


test('Linux service bounds SQLite materialization and returns a controlled memory error', { skip: process.platform !== 'linux' }, async t => {
  const root = await fixture(t), row = await create(root)
  for (const expression of ["printf('%1000000s','')", 'zeroblob(1000000)']) {
    const query = 'SELECT ' + Array.from({ length: 128 }, (_, i) => `${expression} AS c${i}`).join(',')
    await assert.rejects(data(root, row.id, query), error => error.statusCode === 400 && /memory limit/.test(error.message))
  }
  assert.deepEqual((await data(root, row.id, 'SELECT 7 AS answer')).query.rows, [['7']])
})
