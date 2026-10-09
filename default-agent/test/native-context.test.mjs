import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { BACKGROUND_CONTEXT as ctx } from '@earendil-works/chord/context';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { ProviderCompactionError } from '../src/provider-compaction.mjs';
import { NativeContext, compatibleCanonicalMessages } from '../src/native-context.mjs';
import { DefaultAgentEngine } from '../src/engine.mjs';
const usage = { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
const response = model => ({ role: 'assistant', content: [{ type: 'thinking', thinking: 'Visible reasoning', thinkingSignature: JSON.stringify({ type: 'reasoning', id: 'rs_a', encrypted_content: 'opaque-account-a', summary: [] }) }, { type: 'text', text: 'Answer' }], provider: model.provider, api: model.api, model: model.id, stopReason: 'stop', timestamp: Date.now(), usage });
function stream(message) { const value = createAssistantMessageEventStream(); value.push({ type: 'start', partial: message }); value.push({ type: 'done', reason: 'stop', message }); value.end(message); return value; }
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'woven-native-context-'));
  const accounts = ['a', 'b'].map(id => ({ id, credential: { type: 'api_key', key: 'fixture-' + id } }));
  const calls = [];
  const engine = await new DefaultAgentEngine({ cwd: root, directory: root, claude: { loadModels: async () => {}, models: [], status: async () => ({ connected: false }) }, credentials: { openai: accounts[0].credential }, credentialAccounts: { openai: accounts }, config: { providers: ['openai'], defaultModel: 'openai/native-fixture' } }).initialize();
  engine.runtime.registerProvider('openai', { baseUrl: 'https://api.openai.com/v1', api: 'openai-responses', authHeader: true, models: [{ id: 'native-fixture', name: 'Fixture', reasoning: true, input: ['text'], contextWindow: 200000, maxTokens: 4096, cost: { input: 1, output: 2, cacheRead: 0.1, cacheWrite: 0 } }] });
  engine.runtime.getAuth = async () => ({ auth: { apiKey: (await engine.credentials.read('openai')).key } });
  engine.compactionFetch = async (url, options) => { calls.push({ url, body: JSON.parse(options.body), account: engine.credentials.context.getStore()?.id }); return new Response(JSON.stringify({ model: 'native-fixture', output: [{ type: 'compaction', encrypted_content: 'opaque-window-' + calls.length, future: { keep: true } }, { type: 'message', role: 'user', content: [{ type: 'input_text', text: 'native-retained' }] }], usage: { input_tokens: 100, output_tokens: 3, total_tokens: 103 } })); };
  t.after(async () => { for (const record of [...engine.sessions.values()]) await record.session.dispose(); await rm(root, { recursive: true, force: true }); });
  return { accounts, calls, engine };
}
async function seed(record, marker = 'original') {
  await record.conversation.commit(async tx => {
    for (let i = 0; i < 8; i++) {
      await tx.appendEntry(record.conversation.id, { kind: 'pi.user', model: [{ role: 'user', content: [{ type: 'text', text: `${marker}-${i}:` + 'x'.repeat(18000) }], timestamp: i }] });
      const model = record.session.model;
      await tx.appendEntry(record.conversation.id, { kind: 'pi.assistant', model: [{ ...response(model), content: [{ type: 'text', text: 'saved answer ' + i }] }] });
    }
  }, ctx);
}
async function compact(record) {
  const id = await record.conversation.compact(undefined, ctx);
  const result = await record.harness.waitForTask(id, ctx);
  assert.equal(result.state.outcome.status, 'completed', JSON.stringify(result.state.outcome));
  await record.conversation.waitForIdle(ctx);
  return id;
}

test('repeated native compaction keeps exact windows, new prefix, usage and canonical history in the current conversation', async t => {
  const { engine, calls } = await fixture(t), record = await engine.create();
  record.accountID = 'a';
  await seed(record);
  await engine.credentials.runWithAccount('openai', (await engine.credentials.candidates('openai'))[0], () => compact(record));
  assert.equal(calls.length, 1);
  const head = (await record.conversation.context(ctx)).head;
  assert.equal(head.kind, 'woven.native-compaction');
  assert.deepEqual((await record.harness.snapshot(NativeContext, record.conversation.id, ctx)).active.continuation.output[0], { type: 'compaction', encrypted_content: 'opaque-window-1', future: { keep: true } });
  assert.equal(head.data.usage.total_tokens, 103);
  const totals = await record.harness.usage(ctx); assert.equal(totals.models['openai/native-fixture'].totalTokens, 103);
  await seed(record, 'later');
  await engine.credentials.runWithAccount('openai', (await engine.credentials.candidates('openai'))[0], () => compact(record));
  assert.equal(calls.length, 2); assert.equal(calls[1].body.input[0].encrypted_content, 'opaque-window-1');
  assert.ok(!JSON.stringify(calls[1].body.input).includes('original-0:')); assert.ok(JSON.stringify(calls[1].body.input).includes('later-0:'));
  assert.equal((await record.harness.usage(ctx)).models['openai/native-fixture'].totalTokens, 206);
  const window = (await record.harness.snapshot(NativeContext, record.conversation.id, ctx)).active.continuation;
  let sent;
  record.streamFunction = (model, input, options) => { const result = stream(response(model)); sent = options.onPayload({ model: model.id, input: [{ role: 'user', content: 'new canonical input' }] }, model); return result; };
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Continue' }] });
  assert.deepEqual(sent.input[0], window.output[0]);
  assert.equal(calls.length, 2);
  let after = 0, text = ''; do { const page = await record.history(after); text += page.recordBatch.records.map(r => r.payload).join(''); after = page.nextAfter; if (!page.hasMore) break; } while (true);
  assert.ok(text.includes('original-0')); assert.ok(text.includes('opaque-window-1')); assert.ok(text.includes('opaque-window-2')); assert.ok(!text.includes('fixture-a'));
});

test('foreign or unknown canonical signatures and item IDs are stripped while readable content and paired call IDs remain', () => {
  const origin = { provider: 'openai', accountID: 'a', modelID: 'same', authIdentity: 'old', endpoint: 'https://api.openai.com/v1/responses' };
  const message = { role: 'assistant', wovenNativeRoute: origin, content: [{ type: 'thinking', thinking: 'Visible summary', thinkingSignature: 'secret-opaque' }, { type: 'text', text: 'text', textSignature: 'native-id' }, { type: 'toolCall', id: 'call_a|fc_a', name: 'read', arguments: {}, thoughtSignature: 'opaque-tool' }] };
  const result = compatibleCanonicalMessages([message, { role: 'toolResult', toolCallId: 'call_a|fc_a', content: [] }], { ...origin, accountID: 'b' });
  assert.ok(!JSON.stringify(result).includes('secret-opaque')); assert.ok(!JSON.stringify(result).includes('native-id')); assert.ok(!JSON.stringify(result).includes('opaque-tool'));
  assert.equal(result[0].content[0].thinking, 'Visible summary'); assert.equal(result[0].content[2].id, 'call_a'); assert.equal(result[1].toolCallId, 'call_a');
  assert.equal(message.content[2].id, 'call_a|fc_a');
  assert.deepEqual(compatibleCanonicalMessages([message], origin), [message]);
});

test('equal-model account and credential replacement rebuild from readable original history and never replay foreign opaque state', async t => {
  const { engine, accounts, calls } = await fixture(t), record = await engine.create();
  const account = accounts[0]; record.accountID = 'a';
  record.streamFunction = model => stream(response(model));
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'signed original input' }] });
  assert.equal(record.session.messages.at(-1).wovenNativeRoute.accountID, 'a');
  await seed(record);
  await engine.credentials.runWithAccount('openai', account, () => compact(record));
  assert.ok(JSON.stringify(calls[0].body).includes('opaque-account-a'));
  await engine.apply({ credentials: { openai: accounts[1].credential }, credentialAccounts: { openai: accounts.toReversed() } });
  let native;
  record.streamFunction = (model, input, options) => { const value = stream(response(model)); native = options.onPayload({ model: model.id, input: [{ role: 'user', content: 'kept-new' }] }, model); return value; };
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'switch account' }] });
  assert.equal(calls.length, 2); assert.equal(calls[1].account, 'b');
  assert.ok(JSON.stringify(calls[1].body).includes('signed original input'));
  assert.ok(!JSON.stringify(calls[1].body).includes('opaque-account-a'));
  assert.ok(!JSON.stringify(calls[1].body).includes('opaque-window-1'));
  assert.equal(native.input[0].encrypted_content, 'opaque-window-2');
  const replacement = { ...accounts[1], credential: { type: 'api_key', key: 'new-fixture-key' } };
  await engine.apply({ credentials: { openai: replacement.credential }, credentialAccounts: { openai: [replacement, accounts[0]] } });
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'replace credential' }] });
  assert.equal(calls.length, 3); assert.ok(!JSON.stringify(calls[2].body).includes('opaque-window-2'));
  const saved = await record.harness.snapshot(NativeContext, record.conversation.id, ctx);
  assert.equal(saved.active.continuation.accountID, 'b'); assert.ok(!JSON.stringify(saved).includes('new-fixture-key'));
});

test('unsupported target route uses actual Pi summary of full original lineage while native auth errors never fallback', async t => {
  const { engine, accounts, calls } = await fixture(t), record = await engine.create();
  record.accountID = 'a';
  await seed(record);
  await engine.credentials.runWithAccount('openai', accounts[0], () => compact(record));
  const originalModel = engine.runtime.getModel('openai', 'native-fixture');
  engine.runtime.registerProvider('openai', { baseUrl: 'https://api.openai.com/v1', api: 'openai-responses', authHeader: true, models: [originalModel, { id: 'portable', name: 'Portable', api: 'openai-completions', reasoning: false, input: ['text'], contextWindow: 200000, maxTokens: 4096, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }] });
  engine.config.models = ['openai/native-fixture', 'openai/portable'];
  await record.session.setModel(engine.runtime.getModel('openai', 'portable'));
  let summaryCalls = 0;
  engine.runtime.completeSimple = async (model, input) => { summaryCalls++; assert.ok(JSON.stringify(input).includes('original-0:')); return { ...response(model), content: [{ type: 'text', text: 'Portable factual summary' }] }; };
  let seen;
  record.streamFunction = (model, input) => { seen = input; return stream({ ...response(model), content: [{ type: 'text', text: 'Continued' }] }); };
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Use portable route' }] });
  assert.equal(summaryCalls, 1); assert.equal(calls.length, 1); assert.ok(JSON.stringify(seen).includes('Portable factual summary')); assert.ok(!JSON.stringify(seen).includes('opaque-window-1'));
  await record.session.setModel(engine.runtime.getModel('openai', 'native-fixture'));
  engine.compactionFetch = async () => new Response(JSON.stringify({ error: { code: 'invalid_api_key' } }), { status: 401 });
  await assert.rejects(engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'native auth failure' }] }), /model request failed|compaction failed/i);
  assert.equal(summaryCalls, 1);
});

test('a smaller target window recompresses original canonical turns incrementally with exact prior native windows', async t => {
  const { engine, accounts, calls } = await fixture(t), record = await engine.create();
  record.accountID = 'a'; await seed(record);
  await engine.credentials.runWithAccount('openai', accounts[0], () => compact(record));
  const original = engine.runtime.getModel('openai', 'native-fixture');
  engine.runtime.registerProvider('openai', { baseUrl: 'https://api.openai.com/v1', api: 'openai-responses', authHeader: true, models: [original, { ...original, id: 'smaller', name: 'Smaller fixture', contextWindow: 16000 }] });
  engine.config.models = ['openai/native-fixture', 'openai/smaller'];
  engine.compactionFetch = async (_url, options) => { const body = JSON.parse(options.body); calls.push({ body }); return new Response(JSON.stringify({ model: body.model, output: [{ type: 'compaction', encrypted_content: 'small-window-' + calls.length }], usage: { input_tokens: 10, output_tokens: 1, total_tokens: 11 } })); };
  await record.session.setModel(engine.runtime.getModel('openai', 'smaller'));
  let sent; record.streamFunction = (model, input, options) => { sent = options.onPayload({ model: model.id, input: [{ role: 'user', content: 'new input' }] }, model); return stream(response(model)); };
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Use smaller target' }] });
  assert.ok(calls.length > 2);
  assert.ok(!JSON.stringify(calls[1].body).includes('opaque-window-1'));
  for (let index = 2; index < calls.length; index++) assert.equal(calls[index].body.input[0].encrypted_content, 'small-window-' + index);
  assert.equal(sent.input[0].encrypted_content, 'small-window-' + calls.length);
  assert.equal((await record.harness.usage(ctx)).models['openai/smaller'].totalTokens, (calls.length - 1) * 11 + 2);
});

test('incomplete portable fallback preserves its exposed native response and does not commit a replacement boundary', async t => {
  const { engine, accounts } = await fixture(t), record = await engine.create();
  record.accountID = 'a'; await seed(record);
  await engine.credentials.runWithAccount('openai', accounts[0], () => compact(record));
  const head = (await record.conversation.context(ctx)).head;
  const original = engine.runtime.getModel('openai', 'native-fixture');
  engine.runtime.registerProvider('openai', { baseUrl: 'https://api.openai.com/v1', api: 'openai-responses', authHeader: true, models: [original, { ...original, id: 'portable', api: 'openai-completions' }] });
  engine.config.models = ['openai/native-fixture', 'openai/portable']; await record.session.setModel(engine.runtime.getModel('openai', 'portable'));
  engine.runtime.completeSimple = async model => ({ ...response(model), stopReason: 'length' });
  await assert.rejects(engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Do not keep incomplete summary' }] }), /model request failed|summarization/i);
  assert.equal((await record.conversation.context(ctx)).head.id, head.id);
});

test('manual /compact uses one native task, accounts usage and continues without ordinary generation', async t => {
  const { engine, calls } = await fixture(t), record = await engine.create(); await seed(record);
  let generations = 0; record.streamFunction = model => { generations++; return stream(response(model)); };
  const result = await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: '/compact preserve exact tool IDs' }], _meta: { wovenRunID: 'compact-run' } });
  assert.equal(generations, 0); assert.equal(calls.length, 1); assert.equal(result.stopReason, 'end_turn'); assert.equal(result.usage.inputTokens, 100);
  let captured; record.streamFunction = (model, input, options) => { captured = options.onPayload({ model: model.id, input: [{ role: 'user', content: 'continue' }] }, model); return stream(response(model)); };
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Continue after manual compact' }] });
  assert.equal(captured.input[0].encrypted_content, 'opaque-window-1');
  let after = 0, found = false; do { const page = await record.history(after); found ||= page.recordBatch.records.some(item => item.runID === 'compact-run' && item.kind === 'woven.native-compaction'); after = page.nextAfter; if (!page.hasMore) break; } while (true);
  assert.ok(found);
});

test('automatic threshold compaction installs the native window before the current generation', async t => {
  const { engine, calls } = await fixture(t), record = await engine.create();
  const model = engine.runtime.getModel('openai', 'native-fixture');
  engine.runtime.registerProvider('openai', { baseUrl: model.baseUrl, api: model.api, authHeader: true, models: [{ ...model, contextWindow: 80000 }] });
  await record.session.setModel(engine.runtime.getModel('openai', 'native-fixture')); await seed(record);
  await record.conversation.commit(tx => tx.appendEntry(record.conversation.id, { kind: 'pi.assistant', model: [{ ...response(record.session.model), usage: { ...usage, totalTokens: 70000 } }] }), ctx);
  let generations = 0;
  engine.runtime.completeSimple = async () => assert.fail('A supported native route must not use Pi summarization');
  record.streamFunction = (model, input, options) => {
    generations++; assert.equal(calls.length, 1);
    assert.equal(options.onPayload({ model: model.id, input: [] }, model).input[0].encrypted_content, 'opaque-window-1');
    return stream(response(model));
  };
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Continue above the blocking threshold' }] });
  assert.equal(generations, 1); assert.equal(calls.length, 1);
  assert.ok((await record.harness.snapshot(NativeContext, record.conversation.id, ctx)).covered.length > 0);
});

test('cancelling manual compaction aborts its native request without generating an answer', async t => {
  const { engine } = await fixture(t), record = await engine.create(); await seed(record);
  let reached, attempts = 0, generations = 0; const ready = new Promise(resolve => { reached = resolve; });
  record.streamFunction = model => { generations++; return stream(response(model)); };
  engine.compactionFetch = async (_url, options) => { attempts++; reached(); return new Promise((resolve, reject) => options.signal.addEventListener('abort', () => reject(options.signal.reason), { once: true })); };
  const pending = engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: '/compact' }] }); await ready;
  await engine.handle('session/cancel', { sessionId: record.session.sessionId });
  assert.equal((await pending).stopReason, 'cancelled'); assert.equal(attempts, 1); assert.equal(generations, 0);
  assert.notEqual((await record.conversation.context(ctx)).head?.kind, 'woven.native-compaction');
});

test('unsupported-first Pi summary preserves original lineage when switching to a supported native route', async t => {
  const { engine, accounts, calls } = await fixture(t), record = await engine.create();
  const original = engine.runtime.getModel('openai', 'native-fixture');
  engine.runtime.registerProvider('openai', { baseUrl: 'https://api.openai.com/v1', api: 'openai-responses', authHeader: true, models: [original, { ...original, id: 'portable', api: 'openai-completions' }] });
  engine.config.models = ['openai/native-fixture', 'openai/portable']; await record.session.setModel(engine.runtime.getModel('openai', 'portable'));
  record.accountID = 'a'; await seed(record, 'before-portable');
  engine.runtime.completeSimple = async model => ({ ...response(model), content: [{ type: 'thinking', thinking: 'Exposed portable thinking' }, { type: 'text', text: 'portable-summary-that-is-not-the-original' }] });
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: '/compact' }] });
  assert.equal(calls.length, 0); assert.ok((await record.harness.snapshot(NativeContext, record.conversation.id, ctx)).covered.length > 0);
  await record.session.setModel(engine.runtime.getModel('openai', 'native-fixture'));
  record.streamFunction = model => stream(response(model));
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Restore on native provider' }] });
  assert.equal(calls.length, 1); assert.ok(JSON.stringify(calls[0].body).includes('before-portable-0:')); assert.ok(!JSON.stringify(calls[0].body).includes('portable-summary-that-is-not-the-original'));
});

test('interrupted native compact archives available failed stream records and usage without installing a continuation', async t => {
  const { engine } = await fixture(t), record = await engine.create(); await seed(record);
  const native = { route: { provider: 'openai', accountID: 'a' }, rawSSE: 'event: response.output_item.added\ndata: {"partial":"exposed partial native 🙂"}\n\nevent: response.failed\ndata: {"error":"interrupted native compact"}\n\n', nativeEvents: [{ event: 'response.output_item.added', data: { partial: 'exposed partial native 🙂' } }, { event: 'response.failed', data: { error: 'interrupted native compact' } }], usage: { input_tokens: 10, output_tokens: 2, total_tokens: 12 } };
  engine.compactionFetch = async () => { const error = new ProviderCompactionError('transport', 'Synthetic native interruption'); error.nativeResponse = native; throw error; };
  await assert.rejects(engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: '/compact' }] }), /model request failed|compaction|Synthetic/);
  assert.notEqual((await record.conversation.context(ctx)).head?.kind, 'woven.native-compaction');
  assert.equal((await record.harness.usage(ctx)).models['openai/native-fixture'].totalTokens, 12);
  let after = 0, saved; do { const page = await record.history(after); saved ??= page.recordBatch.records.find(item => item.kind === 'provider.compaction.interrupted'); after = page.nextAfter; if (!page.hasMore) break; } while (true);
  assert.deepEqual(JSON.parse(saved.payload), native);
});

test('manual native authentication, network and invalid-window failures fault the task without a Pi request or ordinary generation', async t => {
  for (const [label, failure] of [
    ['authentication', async () => new Response('{"error":{"code":"invalid_api_key"}}', { status: 401 })],
    ['network', async () => { throw new Error('Synthetic disconnected transport'); }],
    ['invalid-window', async () => new Response('{"output":[],"model":"native-fixture"}')],
  ]) await t.test(label, async t => {
    const { engine } = await fixture(t), record = await engine.create(); await seed(record);
    let nativeCalls = 0, summaries = 0, generations = 0;
    engine.compactionFetch = async (...args) => { nativeCalls++; return failure(...args); };
    engine.runtime.completeSimple = async () => { summaries++; throw new Error('A failed native compact must not call Pi'); };
    record.streamFunction = model => { generations++; return stream(response(model)); };
    const params = { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: '/compact preserve identifiers' }], _meta: { wovenInputID: 'failed-' + label, wovenRunID: 'failed-run-' + label } };
    await assert.rejects(engine.handle('session/prompt', params), /native|compaction/i);
    assert.equal(nativeCalls, 1); assert.equal(summaries, 0); assert.equal(generations, 0);
    assert.notEqual((await record.conversation.context(ctx)).head?.kind, 'woven.native-compaction');
  });
});

test('generation native route preparation failure rejects before the provider boundary without retaining prepared opaque context', async t => {
  const { engine, accounts } = await fixture(t), record = await engine.create(); record.accountID = 'a'; await seed(record);
  await engine.credentials.runWithAccount('openai', accounts[0], () => compact(record));
  await engine.apply({ credentials: { openai: accounts[1].credential }, credentialAccounts: { openai: accounts.toReversed() } });
  let nativeCalls = 0, summaries = 0, generations = 0;
  engine.compactionFetch = async () => { nativeCalls++; return new Response('{"error":{"code":"invalid_api_key"}}', { status: 401 }); };
  engine.runtime.completeSimple = async () => { summaries++; throw new Error('No Pi fallback'); };
  record.streamFunction = model => { generations++; return stream(response(model)); };
  await assert.rejects(engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Must not replay old account opaque state' }], _meta: { wovenInputID: 'failed-switch', wovenRunID: 'failed-switch-run' } }), /native.*compaction|compaction failed/i);
  assert.equal(nativeCalls, 1); assert.equal(summaries, 0); assert.equal(generations, 0);
  assert.equal(record.nativePrepared, undefined);
});

test('explicit native unsupported response remains archived when Pi supplies the portable fallback', async t => {
  const { engine } = await fixture(t), record = await engine.create(); await seed(record);
  const exposed = JSON.stringify({ error: { code: 'unsupported_compaction', message: 'Synthetic unsupported native endpoint' }, future: { detail: 'visible unsupported native record' } });
  engine.compactionFetch = async () => new Response(exposed, { status: 404 });
  engine.runtime.completeSimple = async model => ({ ...response(model), content: [{ type: 'text', text: 'Clean portable fallback' }] });
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: '/compact focus on identifiers' }] });
  let after = 0, saved; do { const page = await record.history(after); saved ??= page.recordBatch.records.find(item => item.kind === 'provider.compaction.unsupported'); after = page.nextAfter; if (!page.hasMore) break; } while (true);
  assert.equal(JSON.parse(saved.payload).responseJSON, exposed);
  assert.equal((await record.harness.snapshot(NativeContext, record.conversation.id, ctx)).active.portableMessage.content[0].text, 'Clean portable fallback');
});

test('provider exceptions and returned SDK diagnostics preserve exposed content while excluding transport credentials', async t => {
  for (const mode of ['auth-resolution', 'stream-setup', 'stream-iteration', 'error-event', 'terminal-result', 'portable-result']) await t.test(mode, async t => {
    const { engine } = await fixture(t), record = await engine.create();
    const secret = 'synthetic-bearer-DO-NOT-ARCHIVE', capability = 'http://127.0.0.1:12345/woven/tools?capability=private-capability';
    const failure = () => { throw new Error(`Unexpected transport Authorization: Bearer ${secret} ${capability}`); };
    const message = model => ({ ...response(model), stopReason: 'error', errorMessage: `Transport diagnostic Authorization: Bearer ${secret}`, content: [{ type: 'thinking', thinking: 'Exposed partial thinking remains' }, { type: 'text', text: 'Exposed partial answer remains' }] });
    let generations = 0;
    record.streamFunction = model => {
      generations++;
      if (mode === 'stream-setup') failure();
      if (mode === 'stream-iteration') return { async *[Symbol.asyncIterator]() { failure(); } };
      const value = createAssistantMessageEventStream(), result = message(model);
      if (mode === 'error-event') { value.push({ type: 'start', partial: result }); value.push({ type: 'error', reason: 'error', error: result }); }
      value.end(result); return value;
    };
    if (mode === 'auth-resolution') { let calls = 0; engine.runtime.getAuth = async () => ++calls === 1 ? { auth: { apiKey: 'fixture-a' } } : failure(); }
    if (mode === 'portable-result') {
      const model = engine.runtime.getModel('openai', 'native-fixture'); engine.runtime.registerProvider('openai', { baseUrl: model.baseUrl, api: 'openai-responses', authHeader: true, models: [model, { ...model, id: 'portable', api: 'openai-completions' }] });
      engine.config.models = ['openai/native-fixture', 'openai/portable']; await record.session.setModel(engine.runtime.getModel('openai', 'portable')); await seed(record);
      engine.runtime.completeSimple = async model => message(model);
    }
    await assert.rejects(engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: mode === 'portable-result' ? '/compact' : 'Ordinary canonical user input remains' }] }), /operation|connections|request failed/i);
    if (mode === 'auth-resolution' || mode === 'portable-result') assert.equal(generations, 0);
    let after = 0, payload = '', assistant;
    do {
      const page = await record.history(after); payload += page.recordBatch.records.map(item => item.payload).join('');
      for (const item of page.recordBatch.records) { if (item.kind === 'pi.assistant') assistant ??= JSON.parse(item.payload).value.model?.find(message => message.role === 'assistant' && message.stopReason === 'error'); else if (item.kind === 'pi.compaction.response') assistant ??= JSON.parse(item.payload); }
      after = page.nextAfter; if (!page.hasMore) break;
    } while (true);
    assert.ok(!payload.includes(secret)); assert.ok(!payload.includes(capability)); assert.ok(!payload.includes('private-capability'));
    if (mode !== 'portable-result') assert.ok(payload.includes('Ordinary canonical user input remains'));
    if (['error-event', 'terminal-result', 'portable-result'].includes(mode)) { assert.ok(assistant); assert.equal(assistant.usage.totalTokens, 2); assert.ok(!assistant.errorMessage.includes(secret)); assert.ok(payload.includes('Exposed partial thinking remains')); assert.ok(payload.includes('Exposed partial answer remains')); }
  });
});
