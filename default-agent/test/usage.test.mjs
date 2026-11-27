import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { openNodeSqliteDatabase } from '@earendil-works/pi-durable/storage/sqlite/node';
import { USAGE_TABLE, countingSummaries, createUsageTable, saveSummaryUsage } from '../src/usage.mjs';

const summary = { messages: [{ role: 'system', content: 'You are a context summarization assistant. Your task is to read…' }, { role: 'user', content: 'x' }] };
const reply = (input, stopReason = 'stop') => ({ provider: 'p', model: 'm', timestamp: 1767610800000, stopReason,
  usage: { input, output: 3, cacheRead: 0, cacheWrite: 0, cost: { total: 0.25 } } });

async function store(t) {
  const root = await mkdtemp(join(tmpdir(), 'pi-usage-test-'));
  const database = await openNodeSqliteDatabase(join(root, 'pi-durable.sqlite'));
  t.after(async () => { await database.close(); await rm(root, { recursive: true, force: true }); });
  await createUsageTable(database);
  return database;
}

const rows = database => database.all(`SELECT session, created_at, provider, model, input, output, cost FROM ${USAGE_TABLE}`);

test('saves one usage row, with its time, for each stock summariser call and none for other calls', async t => {
  const database = await store(t);
  const models = countingSummaries({
    completeSimple: async (_model, input) => reply(input.messages.length * 10),
  }, saved => saveSummaryUsage(database, 'session-1', saved));
  await models.completeSimple({}, summary, {});
  await models.completeSimple({}, summary, {});
  await models.completeSimple({}, { messages: [{ role: 'user', content: 'hello' }] }, {});
  assert.deepEqual((await rows(database)).map(row => ({ ...row })), [
    { session: 'session-1', created_at: 1767610800000, provider: 'p', model: 'm', input: 20, output: 3, cost: 0.25 },
    { session: 'session-1', created_at: 1767610800000, provider: 'p', model: 'm', input: 20, output: 3, cost: 0.25 },
  ]);
});

test('a summariser call that failed or was stopped saves nothing', async t => {
  const database = await store(t);
  let next = 'aborted';
  const models = countingSummaries({ completeSimple: async () => reply(10, next) },
    saved => saveSummaryUsage(database, 'session-1', saved));
  await models.completeSimple({}, summary, {});
  next = 'error';
  await models.completeSimple({}, summary, {});
  next = 'stop';
  const stopped = new AbortController();
  stopped.abort();
  await models.completeSimple({}, summary, { signal: stopped.signal });
  assert.deepEqual(await rows(database), []);
});

test("a summariser call while Pi Durable holds its write transaction neither waits for it nor loses its usage", async t => {
  const database = await store(t);
  await database.exec('CREATE TABLE pi (id INTEGER PRIMARY KEY)');
  let release;
  const held = new Promise(resolve => { release = resolve; });
  let entered;
  const inside = new Promise(resolve => { entered = resolve; });
  const writing = database.transaction(async transaction => {
    await transaction.run('INSERT INTO pi VALUES (1)');
    entered();
    await held;
  });
  await inside;
  const models = countingSummaries({ completeSimple: async () => reply(10) },
    saved => saveSummaryUsage(database, 'session-1', saved));
  const started = Date.now();
  const answered = await Promise.race([models.completeSimple({}, summary, {}).then(() => true),
    new Promise(resolve => setTimeout(() => resolve(false), 1000))]);
  assert.equal(answered, true);
  assert.ok(Date.now() - started < 500);
  release();
  await writing;
  assert.equal((await rows(database)).length, 1);
});
