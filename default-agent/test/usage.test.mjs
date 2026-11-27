import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';
import { USAGE_TABLE, countingSummaries, saveSummaryUsage } from '../src/usage.mjs';

test('saves one usage row, with its time, for each stock summariser call and none for other calls', async t => {
  const root = await mkdtemp(join(tmpdir(), 'pi-usage-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const path = join(root, 'pi-durable.sqlite');
  const reply = (input) => ({ provider: 'p', model: 'm', timestamp: 1767610800000,
    usage: { input, output: 3, cacheRead: 0, cacheWrite: 0, cost: { total: 0.25 } } });
  const models = countingSummaries({
    completeSimple: async (_model, input) => reply(input.messages.length * 10),
  }, saved => saveSummaryUsage(path, 'session-1', saved));
  const summary = { messages: [{ role: 'system', content: 'You are a context summarization assistant. Your task is to read…' }, { role: 'user', content: 'x' }] };
  await models.completeSimple({}, summary, {});
  await models.completeSimple({}, summary, {});
  await models.completeSimple({}, { messages: [{ role: 'user', content: 'hello' }] }, {});
  const database = new DatabaseSync(path);
  t.after(() => database.close());
  const rows = database.prepare(`SELECT session, created_at, provider, model, input, output, cost FROM ${USAGE_TABLE}`).all();
  assert.deepEqual(rows.map(row => ({ ...row })), [
    { session: 'session-1', created_at: 1767610800000, provider: 'p', model: 'm', input: 20, output: 3, cost: 0.25 },
    { session: 'session-1', created_at: 1767610800000, provider: 'p', model: 'm', input: 20, output: 3, cost: 0.25 },
  ]);
});
