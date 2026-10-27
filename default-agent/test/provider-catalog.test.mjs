import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { ProviderCatalog, parseProviderModels, refreshInterval } from '../src/provider-catalog.mjs';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { ClaudeRuntime } from '../src/claude-runtime.mjs';

const descriptor = (patch = {}) => ({ id: 'fixture-chat', name: 'Fixture chat', provider: 'openai', api: 'openai-responses',
  baseUrl: 'https://api.openai.com/v1', reasoning: true, input: ['text', 'image'], contextWindow: 16384, maxTokens: 4096,
  cost: { input: 1, output: 2, cacheRead: 0, cacheWrite: 0, tiers: [{ inputTokensAbove: 100, input: 2 }] },
  thinkingLevelMap: { off: null, high: 'high' }, compat: { supportsStrictMode: true }, inputLimits: { maxRequestBytes: 1024 }, ...patch });
async function directory(t) {
  const value = await mkdtemp('/tmp/woven-provider-catalog-'); t.after(() => rm(value, { recursive: true, force: true })); return value;
}
const reply = (models = [descriptor()], headers = {}) => new Response(JSON.stringify(models), { headers: { etag: '"fixture"', 'last-modified': 'Thu, 01 Oct 2026 12:00:00 GMT', ...headers } });



test('OpenCode Go cold startup and ID-only session restore pin current metadata for offline reopening', async t => {
  const root = await directory(t), reference = 'opencode-go/glm-5.3-flash'; let requests = 0;
  const model = descriptor({ id: 'glm-5.3-flash', provider: 'opencode-go', api: 'openai-completions', baseUrl: 'https://opencode.ai/inference/go/v1' });
  const config = { providers: ['opencode-go'], defaultModel: reference };
  const makeEngine = catalog => new DefaultAgentEngine({ cwd: root, directory: root, config, catalog,
    claude: { models: [], loadModels: async () => {} } }).initialize();
  const catalog = () => new ProviderCatalog(root, { fetchCatalog: async () => { requests++; return reply([model]); } });
  const engine = await makeEngine(catalog());
  assert.equal(requests, 0);
  const record = await engine.create(), sessionID = record.session.sessionId;
  assert.equal(record.selected, reference); assert.deepEqual(record.session.model, model);
  // Older sessions stored only the model ID, before descriptors were pinned.
  record.saveOptions({ selectedModel: null });
  await record.configurationQueue;
  await record.session.dispose();
  const freshCatalog = catalog(); await freshCatalog.delete('opencode-go');
  const restarted = await makeEngine(freshCatalog);
  const restored = await restarted.create(sessionID);
  assert.equal(restored.selected, reference); assert.deepEqual(restored.session.model, model);
  assert.equal(requests, 2);
  await restored.session.dispose();
  const offline = new ProviderCatalog(root, { fetchCatalog: async () => { throw Error('Reopening a pinned session must stay offline'); } });
  await offline.delete('opencode-go');
  const offlineEngine = await makeEngine(offline), reopened = await offlineEngine.create(sessionID);
  t.after(() => reopened.session.dispose());
  assert.deepEqual(reopened.session.model, model);
});

test('foreign destinations, provider mismatches, malformed fields and oversized bodies fail closed', async t => {
  for (const patch of [{ baseUrl: 'https://foreign.invalid' }, { baseUrl: 'https://api.openai.com:8443/v1' }, { baseUrl: 'https://api.openai.com/v1/other' },
    { baseUrl: 'https://user:secret@api.openai.com/v1' }, { baseUrl: 'https://api.openai.com/v1?key=secret' }, { provider: 'openrouter' },
    { headers: { Authorization: 'secret' } }, { id: '../\nmodel' }, { contextWindow: 0 }, { maxTokens: -1 }, { cost: { input: -1 } }, { cost: { input: 'invalid' } }, { input: ['audio'] }, { reasoning: 'yes' }]) {
    assert.throws(() => parseProviderModels([descriptor(patch)], 'openai'), /invalid model metadata/);
  }
  assert.throws(() => parseProviderModels([descriptor(), descriptor()], 'openai'));
  const cache = new ProviderCatalog(await directory(t), { fetchCatalog: async () => new Response('x'.repeat(4 * 1024 * 1024 + 1)) });
  await assert.rejects(cache.load('openai')); assert.equal(await cache.read('openai'), undefined);

});


test('Claude starts unavailable, discovers without a prompt, retains only valid discovered metadata across restart', async t => {
  const root = await directory(t); let fail = true, closed = 0;
  const models = [{ value: 'fixture-native', displayName: 'Native fixture', supportedEffortLevels: ['high'] }];
  const runtime = new ClaudeRuntime(root, { directories: async () => ({ config: root, storage: root }), query: async options => {
    assert.equal(typeof options.prompt, 'object'); assert.equal(options.options.persistSession, false);
    return { supportedModels: async () => { if (fail) throw Error('offline'); return models; }, close: () => { closed++; } };
  } });
  await runtime.loadModels(); assert.deepEqual(runtime.models, []);
  await assert.rejects(runtime.discover(), /unavailable.*retry/); assert.deepEqual(runtime.models, []);
  fail = false; assert.deepEqual(await runtime.discover(), models);
  fail = true; assert.deepEqual(await runtime.discover(), models); assert.equal(closed, 3);
  const restarted = new ClaudeRuntime(root); await restarted.loadModels(); assert.deepEqual(restarted.models, models);
});


test('an attached child keeps its configured saved model when refresh removes that catalog entry', { timeout: 15000 }, async t => {
  const root = await directory(t);
  const config = { providers: ['openai'], defaultModel: 'openai/fixture-chat' };
  const engine = await new DefaultAgentEngine({ cwd: root, directory: root, config,
    credentials: { openai: { type: 'api_key', key: 'offline-test-only' } },
    claude: { models: [], loadModels: async () => {} } }).initialize();
  engine.publishProviderModels('openai', [descriptor()]);
  await writeFile(join(root, 'fixture.txt'), 'fixture');
  const record = await engine.create();
  t.after(() => record.session.dispose());
  let parentCalls = 0, childCalls = 0, followUp = false;
  engine.runtime.streamSimple = (model, input, options) => {
    const child = options.wovenNativeContext.sessionID !== record.session.sessionId;
    const call = child ? ++childCalls : ++parentCalls;
    if (child && call === 1) engine.publishProviderModels('openai', [descriptor({ id: 'replacement', name: 'Replacement' })]);
    const content = child && call === 1 ? [{ type: 'toolCall', id: 'read-fixture', name: 'read', arguments: { path: 'fixture.txt' } }]
      : !child && call === 1 ? [{ type: 'toolCall', id: 'delegate', name: 'subagent', arguments: followUp ? { action: 'message', name: 'reader', message: 'Use your pinned model again.' } : { action: 'spawn', name: 'reader', task: 'Read the fixture.' } }]
      : [{ type: 'text', text: 'Completed' }];
    const message = { role: 'assistant', content, provider: model.provider, api: model.api, model: model.id, timestamp: Date.now(), stopReason: content[0].type === 'toolCall' ? 'toolUse' : 'stop',
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
    const output = createAssistantMessageEventStream();
    output.push({ type: 'start', partial: message }); output.push({ type: 'done', reason: message.stopReason, message }); output.end(message);
    return output;
  };
  await engine.prompt(record, 'Delegate the fixture reading', () => {});
  assert.equal(childCalls, 2);
  assert.equal(record.session.model.id, 'fixture-chat');
  followUp = true; parentCalls = 0;
  await engine.prompt(record, 'Follow up with the existing child', () => {});
  assert.equal(childCalls, 3);
  await engine.apply({ config: { ...config, providers: [] } });
  parentCalls = 0;
  await assert.rejects(engine.prompt(record, 'Follow up after disabling the connection', () => {}), /No configured connection/);
  assert.equal(childCalls, 3);
});
