import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createInferenceAdapter } from '../src/inference-adapter.mjs';

const model = { provider: 'openai-codex', id: 'fixture-model', name: 'Fixture', api: 'openai-codex-responses', reasoning: true, baseUrl: 'https://fixture.invalid', contextWindow: 16000, maxTokens: 4096 };
const request = () => ({ model: { ...model }, accountID: 'second', context: { messages: [{ role: 'user', content: 'Inspect fixture' }] }, scope: { conversationID: 'conversation', requestID: 'conversation:task' }, options: { reasoning: 'low' } });
async function setup(t, stream) {
  const directory = await mkdtemp(join(tmpdir(), 'woven-inference-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const accounts = [{ id: 'first', label: 'First account', credential: { type: 'oauth', access: 'fixture-one', expires: Date.now() + 60000 } }, { id: 'second', label: 'Second account', credential: { type: 'oauth', access: 'fixture-two', expires: Date.now() + 60000 } }];
  const selected = [], calls = [];
  const engine = { directory, config: { providers: ['openai-codex'] }, credentials: { candidates: async () => accounts },
    browse: async () => {}, ensureModel: async reference => reference === `${model.provider}/${model.id}` ? model : undefined,
    withAccount: async (provider, account, operation) => { selected.push(account.id); return operation(); },
    runtime: { getModels: () => [model], streamSimple: (selectedModel, context, options) => { calls.push({ model: selectedModel, context, options }); return stream?.(options) ?? success(); } } };
  function* success() {
    const message = { role: 'assistant', content: [{ type: 'toolCall', id: 'tool', name: 'write', arguments: { path: 'device-only' } }], stopReason: 'toolUse', wovenNativeAuthIdentity: 'private-hash' };
    yield { type: 'start', partial: message }; yield { type: 'done', reason: 'toolUse', message };
  }
  return { adapter: createInferenceAdapter(engine), engine, calls, selected, accounts };
}

test('completed request replays after process recreation without new provider inference', async t => {
  const fixture = await setup(t), initialEvents = [];
  const value = await fixture.adapter.catalog();
  assert.deepEqual(value.accounts.map(account => account.id), ['first', 'second']);
  assert.equal(JSON.stringify(value).includes('fixture-two'), false);
  assert.equal(value.accounts[1].connected, true);
  await fixture.adapter.stream(request(), { principalID: 'device', onEvent: event => initialEvents.push(event) });
  assert.deepEqual(fixture.selected, ['second']);
  assert.equal(fixture.calls.length, 1);
  assert.equal(initialEvents.at(-1).message.content[0].name, 'write');
  assert.equal(initialEvents.at(-1).message.wovenNativeAuthIdentity, undefined);
  assert.equal(fixture.calls[0].options.maxRetries, 0);
  const restarted = createInferenceAdapter(fixture.engine), events = [];
  await restarted.stream(request(), { principalID: 'device', onEvent: event => events.push(event) });
  assert.equal(fixture.calls.length, 1); assert.equal(events.at(-1).type, 'done');
  const changed = request(); changed.context.messages[0].content = 'Different input';
  await assert.rejects(restarted.stream(changed, { principalID: 'device' }), /different input/);
  fixture.accounts[1].credential.access = 'replacement';
  await assert.rejects(fixture.adapter.stream(request(), { principalID: 'device' }), /different input or credentials/);
  fixture.accounts.splice(1);
  await assert.rejects(fixture.adapter.stream(request(), { principalID: 'device' }), /No account fallback/);
  assert.equal(fixture.calls.length, 1);
});

test('uncertain interrupted receipt is not replayed and error does not disclose provider data', async t => {
  const fixture = await setup(t, async function* () { throw Error('token=private-provider-secret https://sensitive.invalid'); });
  await assert.rejects(fixture.adapter.stream(request(), { principalID: 'device' }), error => !error.message.includes('private-provider-secret'));
  await assert.rejects(createInferenceAdapter(fixture.engine).stream(request(), { principalID: 'device' }), /outcome is uncertain/);
  assert.equal(fixture.calls.length, 1);
});
test('client-provided auth, endpoint and native filesystem scope cannot override owner routing', async t => {
  const fixture = await setup(t), value = request();
  value.model.baseUrl = 'https://malicious.invalid';
  value.options.apiKey = 'injected'; value.options.headers = { Authorization: 'injected' };
  value.options.wovenNativeContext = { directory: '/private/elsewhere' };
  await fixture.adapter.stream(value, { principalID: 'device' });
  const options = fixture.calls[0].options;
  assert.equal(options.apiKey, undefined); assert.equal(options.headers, undefined);
  assert.ok(options.wovenNativeContext.directory.startsWith(fixture.engine.directory));
  assert.equal(fixture.calls[0].model.baseUrl, 'https://fixture.invalid');
});

test('cancellation reaches provider and preserves uncertain receipt', async t => {
  let cancellation;
  const fixture = await setup(t, async function* (options) {
    cancellation = options.signal;
    yield { type: 'start', partial: { role: 'assistant', content: [] } };
    options.signal.throwIfAborted();
    await new Promise(resolve => options.signal.addEventListener('abort', resolve, { once: true }));
    options.signal.throwIfAborted();
  });
  const controller = new AbortController();
  await assert.rejects(fixture.adapter.stream(request(), { principalID: 'device', signal: controller.signal, onEvent: () => queueMicrotask(() => controller.abort()) }), /Cancelled/);
  assert.equal(cancellation.aborted, true);
});

test('owner inference proxy requests visible summaries for reasoning-enabled device turns',async t=>{
  const fixture=await setup(t);
  await fixture.adapter.stream(request(),{principalID:'device'});
  const options=fixture.calls[0].options;
  assert.equal(options.reasoning,'low');
  const payload=await options.onPayload({reasoning:{effort:'low',summary:'auto'}},model);
  assert.deepEqual(payload.reasoning,{effort:'low',summary:'detailed'});
});
