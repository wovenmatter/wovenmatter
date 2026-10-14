import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { createInferenceAdapter } from '../src/inference-adapter.mjs';

const model = { provider: 'openai-codex', id: 'fixture-model', name: 'Fixture', api: 'openai-codex-responses', baseUrl: 'https://fixture.invalid', contextWindow: 16000, maxTokens: 4096 };
const request = () => ({ model: { ...model }, accountID: 'second', context: { messages: [{ role: 'user', content: 'Inspect fixture' }] }, scope: { conversationID: 'conversation', requestID: 'conversation:task' }, options: { reasoning: 'low' } });
async function setup(t, stream) {
  const directory = await mkdtemp(join(tmpdir(), 'woven-inference-test-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const accounts = [{ id: 'first', label: 'First account', credential: { type: 'oauth', access: 'fixture-one', expires: Date.now() + 60000 } }, { id: 'second', label: 'Second account', credential: { type: 'oauth', access: 'fixture-two', expires: Date.now() + 60000 } }];
  const selected = [], calls = [];
  const engine = { directory, config: { providers: ['openai-codex'] }, credentials: {
    candidates: async () => accounts,
    runWithAccount: async (provider, account, operation) => { selected.push(account.id); return operation(); },
  }, runtime: { getModels: () => [model], streamSimple: (selectedModel, context, options) => { calls.push({ model: selectedModel, context, options }); return stream?.(options) ?? success(); } } };
  function* success() {
    const message = { role: 'assistant', content: [{ type: 'toolCall', id: 'tool', name: 'write', arguments: { path: 'device-only' } }], stopReason: 'toolUse', wovenNativeAuthIdentity: 'private-hash' };
    yield { type: 'start', partial: message }; yield { type: 'done', reason: 'toolUse', message };
  }
  return { adapter: createInferenceAdapter(engine), engine, calls, selected, accounts };
}
test('catalog exposes identities and supported models without credential material', async t => {
  const fixture = await setup(t);
  const value = await fixture.adapter.catalog();
  assert.deepEqual(value.accounts.map(account => account.id), ['first', 'second']);
  assert.equal(JSON.stringify(value).includes('fixture-two'), false);
  assert.equal(value.accounts[1].connected, true);
});
test('adapter pins account and returns tool calls without executing tools or creating an agent', async t => {
  const fixture = await setup(t), events = [];
  await fixture.adapter.stream(request(), { principalID: 'device', onEvent: event => events.push(event) });
  assert.deepEqual(fixture.selected, ['second']);
  assert.equal(fixture.calls.length, 1);
  assert.equal(events.at(-1).message.content[0].name, 'write');
  assert.equal(events.at(-1).message.wovenNativeAuthIdentity, undefined);
  assert.equal(fixture.calls[0].options.maxRetries, 0);
});
test('completed request replays after process recreation without new provider inference', async t => {
  const fixture = await setup(t);
  await fixture.adapter.stream(request(), { principalID: 'device' });
  const restarted = createInferenceAdapter(fixture.engine), events = [];
  await restarted.stream(request(), { principalID: 'device', onEvent: event => events.push(event) });
  assert.equal(fixture.calls.length, 1); assert.equal(events.at(-1).type, 'done');
  const changed = request(); changed.context.messages[0].content = 'Different input';
  await assert.rejects(restarted.stream(changed, { principalID: 'device' }), /different input/);
});
test('explicit model changes retain each selected descriptor across refresh, restart and receipt replay', async t => {
  const { DefaultAgentEngine } = await import('../src/engine.mjs');
  const fixture = await setup(t);
  // Exercise the real saved-descriptor validation with two synthetic custom-host models.
  const first = { ...model, provider: 'local-server-fixture', api: 'openai-responses' }, second = { ...first, id: 'second-model' };
  let catalog = [first, second];
  fixture.engine.config.providers = [first.provider];
  fixture.engine.config.customServers = [{ id: first.provider, url: first.baseUrl }];
  fixture.engine.validateModelDestination = DefaultAgentEngine.prototype.validateModelDestination;
  fixture.engine.resolveModel = reference => catalog.find(item => `${item.provider}/${item.id}` === reference);
  fixture.engine.ensureModel = DefaultAgentEngine.prototype.ensureModel;
  const initial = request(); initial.model = first;
  await fixture.adapter.stream(initial, { principalID: 'device' });
  const changed = request(); changed.model = second; changed.scope.requestID = 'conversation:changed-model';
  await fixture.adapter.stream(changed, { principalID: 'device' });
  catalog = [];
  const restarted = createInferenceAdapter(fixture.engine);
  await restarted.stream(initial, { principalID: 'device' });
  await restarted.stream(changed, { principalID: 'device' });
  assert.deepEqual(fixture.calls.map(call => call.model), [first, second]);
  const continued = structuredClone(initial); continued.scope.requestID = 'conversation:return-to-first';
  await restarted.stream(continued, { principalID: 'device' });
  assert.deepEqual(fixture.calls.map(call => call.model), [first, second, first]);
});
test('account removal and credential replacement fail closed without fallback', async t => {
  const fixture = await setup(t);
  await fixture.adapter.stream(request(), { principalID: 'device' });
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
test('expired borrowed subscription fails promptly instead of waiting for central forever', async t => {
  const fixture = await setup(t);
  fixture.accounts[1].credential.borrowed = true; fixture.accounts[1].credential.expires = 1;
  await assert.rejects(fixture.adapter.stream(request(), { principalID: 'device' }), /access has expired/);
  assert.equal(fixture.calls.length, 0);
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

test('client vault unlock after restart preserves accounts and rejects an incorrect grant key', async t => {
  const { createDefaultAgentService } = await import('../src/service.mjs');
  const { randomBytes } = await import('node:crypto');
  const { readFile } = await import('node:fs/promises');
  const directory = await mkdtemp(join(tmpdir(), 'woven-inference-unlock-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const key = randomBytes(32).toString('base64');
  const original = createDefaultAgentService({ cwd: directory, directory });
  await original.configure({ workspace: 'fixture', unlockKey: key, config: { providers: ['openai'] },
    credentials: { openai: { type: 'api_key', key: 'fixture-only-key' } }, credentialAccounts: {}, revision: 'fixture' });
  const before = await readFile(join(directory, 'configuration.json'), 'utf8');
  const restarted = createDefaultAgentService({ cwd: directory, directory });
  assert.equal((await restarted.status()).locked, true);
  await assert.rejects(restarted.unlockForClient({ workspace: 'fixture', unlockKey: randomBytes(32).toString('base64') }), /could not be decrypted/);
  assert.equal((await restarted.status()).locked, true);
  assert.deepEqual(await restarted.unlockForClient({ workspace: 'fixture', unlockKey: key }), { unlocked: true });
  assert.equal(await readFile(join(directory, 'configuration.json'), 'utf8'), before);
  assert.deepEqual(await restarted.unlockForClient({ workspace: 'fixture', unlockKey: key }), { unlocked: true });
  // Read the encrypted vault directly; do not initialize an actual provider runtime for this storage test.
  const { CredentialVault } = await import('../src/vault.mjs');
  const vault = new CredentialVault(directory); await vault.unlock('fixture', key);
  assert.equal((await vault.read()).shared.openai.key, 'fixture-only-key');
});

test('generation-aware inference helper returns catalog without agent execution or persistent credentials', async t => {
  const { spawn } = await import('node:child_process');
  const { readdir, readFile } = await import('node:fs/promises');
  const directory = await mkdtemp(join(tmpdir(), 'woven-inference-helper-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const child = spawn(process.execPath, [new URL('../src/main.mjs', import.meta.url).pathname, '--inference'], {
    cwd: directory, env: { ...process.env, WOVEN_DEFAULT_AGENT_DIRECTORY: directory, WOVEN_INFERENCE_DIRECTORY: directory },
    stdio: ['pipe', 'pipe', 'pipe'],
  });
  t.after(() => { if (child.exitCode === null) child.kill('SIGKILL'); });
  let output = ''; child.stdout.on('data', value => { output += value; });
  child.stdin.end(JSON.stringify({ action: 'catalog', payload: { config: { providers: [] }, credentials: { openai: { type: 'api_key', key: 'fixture-transient-secret' } } }, principalID: 'fixture' }) + '\n');
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('exit', resolve); });
  assert.equal(code, 0); assert.deepEqual(JSON.parse(output), { models: [], accounts: [] });
  assert.equal(output.includes('fixture-transient-secret'), false);
  for (const name of await readdir(directory)) if (name.endsWith('.json')) assert.equal((await readFile(join(directory, name), 'utf8')).includes('fixture-transient-secret'), false);
});
