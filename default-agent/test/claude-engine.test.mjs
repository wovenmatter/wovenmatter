import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, realpath, rm, readFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { ProviderCatalog } from '../src/provider-catalog.mjs';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { ClaudeRuntime } from '../src/claude-runtime.mjs';














async function fixture(t, { credentials = {}, credentialAccounts = {}, config = {} } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'woven-claude-engine-'));
  const claude = {
    checks: 0,
    models: [{ value: 'sonnet', displayName: 'Claude Sonnet', supportedEffortLevels: ['low', 'medium', 'high'] }, { value: 'fixture-other', displayName: 'Other fixture', supportedEffortLevels: [] }],
    loadModels: async () => {},
    async status() { this.checks++; return { connected: true }; },
    environment: async () => ({}),
    // Metadata-only initialization is supported without inference. Synthetic
    // Models streams below own every fixture generation.
    sdkQuery: async () => ({ accountInfo: async () => ({ email: 'fixture@example.invalid', organization: 'fixture-org', apiProvider: 'firstParty' }), close() {} }),
  };
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
    const value = typeof content === 'function' ? content() : content;
    const result = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
      content: value, timestamp: Date.now(), stopReason: value.some(block => block.type === 'toolCall') ? 'toolUse' : 'stop',
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
    const finish = () => {
      stream.push({ type: 'start', partial: result });
      stream.push({ type: 'done', reason: result.stopReason, message: result });
      stream.end(result);
    };
    if (beforeRespond) void beforeRespond(model, context).then(finish);
    else finish();
    return stream;
  };
}






test('session working directories stay isolated and survive a service restart', async t => {
  const { engine, root, options } = await fixture(t);
  const first = join(root, 'first-project'), second = join(root, 'second-project');
  await Promise.all([mkdir(first), mkdir(second)]);
  const opened = await engine.handle('session/new', { cwd: first });
  const record = engine.sessions.get(opened.sessionId);
  assert.equal(record.cwd, await realpath(first));
  await engine.select(record, 'full', 'permission_mode');
  let firstCalls = 0; record.streamFunction = syntheticAssistant(() => ++firstCalls === 1 ? [{ type: 'toolCall', id: 'write-first', name: 'write', arguments: { path: 'location.txt', content: 'first project' } }] : [{ type: 'text', text: 'Saved' }]);
  await engine.prompt(record, 'Write in this project', () => {});
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
  await restarted.prompt(restored, 'Write in the reopened project', () => {});
  assert.equal(await readFile(join(first, 'restored.txt'), 'utf8'), 'same project');
  await assert.rejects(access(join(second, 'restored.txt')));
  assert.equal((await restarted.handle('session/load', { sessionId: opened.sessionId, cwd: first })).sessionId, opened.sessionId);
});
