import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, realpath, rm, readFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { ProviderCatalog } from '../src/provider-catalog.mjs';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { assistantMessage, emitAssistant } from './fixtures/synthetic-stream.mjs';
import { fakeClaudeRuntime } from './fixtures/claude-runtime.mjs';

async function fixture(t, { credentials = {}, credentialAccounts = {}, config = {}, models } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'woven-claude-engine-'));
  const claude = fakeClaudeRuntime({
    checks: 0,
    models: models ?? [{ value: 'sonnet', displayName: 'Claude Sonnet', supportedEffortLevels: ['low', 'medium', 'high'] }, { value: 'fixture-other', displayName: 'Other fixture', supportedEffortLevels: [] }],
    async status() { this.checks++; return { connected: true }; },
    environment: async () => ({}),
    // Metadata-only initialization is supported without inference. Synthetic
    // Models streams below own every fixture generation.
    sdkQuery: async () => ({ accountInfo: async () => ({ email: 'fixture@example.invalid', organization: 'fixture-org', apiProvider: 'firstParty' }), close() {} }),
  });
  const catalog = new ProviderCatalog(root, { fetchCatalog: async () => { throw Error('Fixture catalog network forbidden'); } });
  await catalog.write('openai', { checkedAt: Date.now(), models: [{ id: 'gpt-4o', name: 'Offline fixture', provider: 'openai', api: 'openai-responses', baseUrl: 'https://api.openai.com/v1', contextWindow: 16384, maxTokens: 4096, reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
  const options = { cwd: root, directory: root, claude, catalog, credentials, credentialAccounts,
    config: { providers: ['claude-subscription'], defaultModel: 'claude-subscription/sonnet', ...config } };
  const engine = await new DefaultAgentEngine(options).initialize();
  t.after(async () => {
    for (const record of [...engine.sessions.values()]) await record.session.dispose();
    await rm(root, { recursive: true, force: true });
  });
  await engine.runtime.refresh({ allowNetwork: false });
  return { root, engine, claude, options };
}

function syntheticAssistant(content, beforeRespond) {
  return (model, context) => {
    const stream = createAssistantMessageEventStream();
    const result = assistantMessage(model, typeof content === 'function' ? content() : content);
    const finish = () => emitAssistant(stream, result);
    if (beforeRespond) void beforeRespond(model, context).then(finish);
    else finish();
    return stream;
  };
}

test('fast mode is a model selector variant that persists and reaches the native request', async t => {
  const { engine, root, options } = await fixture(t, { models: [
    { value: 'sonnet', displayName: 'Claude Sonnet', supportedEffortLevels: ['low', 'medium', 'high'], supportsFastMode: true },
    { value: 'fixture-other', displayName: 'Other fixture', supportedEffortLevels: [] }],
    config: { models: ['claude-subscription/sonnet', 'claude-subscription/fixture-other'] } });
  const opened = await engine.handle('session/new', { cwd: root });
  const record = engine.sessions.get(opened.sessionId);
  const menu = configuration => configuration.configOptions.find(option => option.id === 'model');
  let model = menu(engine.configuration(record));
  assert.equal(model.currentValue, 'claude-subscription/sonnet');
  assert.deepEqual(model.options.map(option => option.value), ['claude-subscription/sonnet', 'claude-subscription/sonnet#fast', 'claude-subscription/fixture-other']);
  assert.equal(model.options[1].name, model.options[0].name);
  assert.equal(model.options[1]._meta.speed, 'fast');
  await assert.rejects(engine.select(record, 'claude-subscription/sonnet#ultrafast'), /speed is unavailable/);
  await assert.rejects(engine.select(record, 'claude-subscription/fixture-other#fast'), /speed is unavailable/);
  model = menu(await engine.select(record, 'claude-subscription/sonnet#fast'));
  assert.equal(model.currentValue, 'claude-subscription/sonnet#fast');
  assert.equal(record.selected, 'claude-subscription/sonnet');
  const seen = [];
  record.streamFunction = (selected, context, resolved) => { seen.push(resolved.wovenSpeed); return syntheticAssistant([{ type: 'text', text: 'Fast' }])(selected, context); };
  await engine.prompt(record, 'Answer quickly', () => {}, undefined, { runID: record.runID, inputID: record.inputID });
  assert.deepEqual(seen, ['fast']);

  await record.session.dispose();
  const restarted = await new DefaultAgentEngine(options).initialize();
  t.after(async () => { for (const value of [...restarted.sessions.values()]) await value.session.dispose(); });
  const loaded = await restarted.handle('session/load', { sessionId: opened.sessionId });
  const restored = restarted.sessions.get(loaded.sessionId);
  assert.equal(menu(restarted.configuration(restored)).currentValue, 'claude-subscription/sonnet#fast');
  assert.equal(menu(await restarted.select(restored, 'claude-subscription/fixture-other')).currentValue, 'claude-subscription/fixture-other');
  assert.equal(restored.speed, undefined);
  assert.equal(menu(await restarted.select(restored, 'claude-subscription/sonnet')).currentValue, 'claude-subscription/sonnet');
  seen.length = 0;
  restored.streamFunction = (selected, context, resolved) => { seen.push(resolved.wovenSpeed); return syntheticAssistant([{ type: 'text', text: 'Standard' }])(selected, context); };
  await restarted.prompt(restored, 'Answer normally', () => {}, undefined, { runID: restored.runID, inputID: restored.inputID });
  assert.deepEqual(seen, [undefined]);
});

test('session working directories stay isolated and survive a service restart', async t => {
  const { engine, root, options } = await fixture(t);
  const first = join(root, 'first-project'), second = join(root, 'second-project');
  await Promise.all([mkdir(first), mkdir(second)]);
  const opened = await engine.handle('session/new', { cwd: first });
  const record = engine.sessions.get(opened.sessionId);
  assert.equal(record.cwd, await realpath(first));
  await engine.select(record, 'full', 'permission_mode');
  let firstCalls = 0; record.streamFunction = syntheticAssistant(() => ++firstCalls === 1 ? [{ type: 'toolCall', id: 'write-first', name: 'write', arguments: { path: 'location.txt', content: 'first project' } }] : [{ type: 'text', text: 'Saved' }]);
  await engine.prompt(record, 'Write in this project', () => {}, undefined, { runID: record.runID, inputID: record.inputID });
  assert.equal(await readFile(join(first, 'location.txt'), 'utf8'), 'first project');
  await assert.rejects(access(join(root, 'location.txt')));
  await assert.rejects(engine.handle('session/load', { sessionId: opened.sessionId, cwd: second }), /different working directory/);
  assert.equal(engine.sessions.get(opened.sessionId), record);

  await record.session.dispose();
  const restarted = await new DefaultAgentEngine({ ...options, cwd: second }).initialize();
  t.after(async () => { for (const value of [...restarted.sessions.values()]) await value.session.dispose(); });
  await assert.rejects(restarted.handle('session/load', { sessionId: opened.sessionId, cwd: second }), /different working directory/);
  assert.equal(restarted.sessions.size, 0);
  const loaded = await restarted.handle('session/load', { sessionId: opened.sessionId });
  const restored = restarted.sessions.get(loaded.sessionId);
  assert.equal(restored.cwd, await realpath(first));
  let restoredCalls = 0; restored.streamFunction = syntheticAssistant(() => ++restoredCalls === 1 ? [{ type: 'toolCall', id: 'write-restored', name: 'write', arguments: { path: 'restored.txt', content: 'same project' } }] : [{ type: 'text', text: 'Saved' }]);
  await restarted.prompt(restored, 'Write in the reopened project', () => {}, undefined, { runID: restored.runID, inputID: restored.inputID });
  assert.equal(await readFile(join(first, 'restored.txt'), 'utf8'), 'same project');
  await assert.rejects(access(join(second, 'restored.txt')));
  assert.equal((await restarted.handle('session/load', { sessionId: opened.sessionId, cwd: first })).sessionId, opened.sessionId);
});
