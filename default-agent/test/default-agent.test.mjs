import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { accessFailure, DefaultAgentError, operationErrorMessage, validateConfig, writePrivateJSON } from '../src/config.mjs';
import { searchTools } from '../src/search.mjs';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { createDefaultAgentService } from '../src/service.mjs';
import { Credentials } from '../src/credentials.mjs';
import { CredentialVault } from '../src/vault.mjs';
import { randomBytes } from 'node:crypto';
import { providerFetch } from '../src/transport.mjs';

async function temporary(t) {
  const directory = await mkdtemp('/tmp/woven-default-agent-test-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}
test('fallback classifies unavailable credentials and exhausted allowances, not ordinary throttling', () => {
  for (const message of ['401 Unauthorized', 'invalid_api_key', 'invalid_grant', 'Authentication required', 'insufficient_quota', 'usage_limit_reached', '402 Payment Required', 'insufficient credits']) assert.ok(accessFailure(message), message);
  for (const message of ['429 Too Many Requests', '500 server error', 'fetch failed', '403 forbidden', 'cancelled']) assert.equal(accessFailure(message), null, message);
});
test('helper errors preserve actionable app messages without exposing raw provider errors', () => {
  const safe = 'The connection has exhausted its available usage.';
  assert.equal(operationErrorMessage(new DefaultAgentError(safe)), safe);
  assert.ok(!operationErrorMessage(new Error('provider echoed fixture-secret')).includes('fixture-secret'));
});
test('search needs its own key and sends bounded, cited results through Exa', async () => {
  await assert.rejects(searchTools()[0].execute('1', { query: 'anything' }), /Add an Exa API key/);
  let request;
  const tool = searchTools('fixture-key', async (url, options) => {
    request = { url, ...options };
    return { ok: true, json: async () => ({ results: [{ title: 'Source', url: 'https://example.com', text: 'x'.repeat(20000) }] }) };
  })[0];
  const result = await tool.execute('1', { query: 'question', numResults: 99 });
  assert.equal(request.url, 'https://api.exa.ai/search');
  assert.equal(request.headers['x-api-key'], 'fixture-key');
  assert.equal(JSON.parse(request.body).numResults, 10);
  const parsed = JSON.parse(result.content[0].text);
  assert.equal(parsed.results[0].url, 'https://example.com');
  assert.equal(parsed.results[0].text.length, 16000);
});
test('configuration preserves provider identities, model order, and explicit fallbacks', () => {
  const value = validateConfig({ providers: ['openai', 'openai-codex', 'unknown', 'openai'], models: ['openrouter/kimi', 'openai/gpt'], defaultModel: 'openai/gpt', fallbackModels: ['openrouter/kimi'] });
  assert.deepEqual(value.providers, ['openai', 'openai-codex']);
  assert.deepEqual(value.models, ['openrouter/kimi', 'openai/gpt']);
  assert.deepEqual(value.fallbackModels, ['openrouter/kimi']);
});
test('real SDK loads the complete selected tool set and resumes an empty draft without a Pi install', async t => {
  const directory = await temporary(t);
  const engine = await new DefaultAgentEngine({ cwd: directory, directory }).initialize();
  const record = await engine.create();
  assert.deepEqual(new Set(record.session.getActiveToolNames()), new Set(['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls', 'web_search', 'web_read']));
  const second = await new DefaultAgentEngine({ cwd: directory, directory }).initialize();
  const resumed = await second.create(record.session.sessionId);
  assert.equal(resumed.session.sessionId, record.session.sessionId);
  await assert.rejects(engine.prompt(record, 'No provider should be consumed', () => {}), /No configured connection/);
});
function fixtureEngine({ errors = [], connected = ['openai-codex', 'openrouter'], visible = false } = {}) {
  const engine = new DefaultAgentEngine({ cwd: '/tmp', directory: '/tmp', config: { defaultModel: 'openai-codex/primary', fallbackModels: ['openrouter/fallback'] } });
  const selected = [];
  let listener;
  const record = { selected: 'openai-codex/primary', busy: false, manager: { getLeafId: () => 'before', branch: () => {} }, session: { messages: [], agent: { state: { messages: [] } }, subscribe(fn) { listener = fn; return () => {}; }, async setModel(m) { selected.push(m.provider); }, async prompt() { if (visible) listener({ type: 'tool_execution_start', toolCallId: 't', toolName: 'bash', args: {} }); if (errors.length) throw new Error(errors.shift()); } } };
  engine.resolveModel = ref => { const [provider, id] = ref.split('/'); return { provider, id, name: id }; };
  engine.credentials = { read: async p => connected.includes(p) ? { type: 'api_key', key: 'fixture' } : undefined };
  engine.runtime = { getAuth: async () => ({}), getModels: () => [] };
  return { engine, record, selected };
}
test('signed-out subscription falls back to configured API provider and updates selector with a reason', async () => {
  const { engine, record, selected } = fixtureEngine({ connected: ['openrouter'] });
  const events = [];
  await engine.prompt(record, 'hello', event => events.push(event));
  assert.deepEqual(selected, ['openrouter']);
  assert.equal(record.selected, 'openrouter/fallback');
  assert.equal(events[0].configOptions[0].currentValue, 'openrouter/fallback');
  assert.match(events[0]._meta.fallbackReason, /sign-in/);
});
test('exhausted credits fall back while temporary throttling does not', async () => {
  const exhausted = fixtureEngine({ errors: ['insufficient_quota'] });
  await exhausted.engine.prompt(exhausted.record, 'hello', () => {});
  assert.equal(exhausted.record.selected, 'openrouter/fallback');
  const throttled = fixtureEngine({ errors: ['429 Too Many Requests'] });
  await assert.rejects(throttled.engine.prompt(throttled.record, 'hello', () => {}));
  assert.deepEqual(throttled.selected, ['openai-codex']);
});
test('a failed turn that already ran tools is never silently replayed', async () => {
  const { engine, record, selected } = fixtureEngine({ errors: ['insufficient_quota'], visible: true });
  await assert.rejects(engine.prompt(record, 'change files', () => {}));
  assert.deepEqual(selected, ['openai-codex']);
});
test('cancel during credential preparation never starts a model turn or fallback', async () => {
  const { engine, record, selected } = fixtureEngine();
  let release;
  let entered;
  const preparing = new Promise(resolve => { entered = resolve; });
  engine.runtime.getAuth = async () => {
    entered();
    await new Promise(resolve => { release = resolve; });
    return {};
  };
  let prompts = 0;
  record.session.prompt = async () => { prompts++; };
  record.session.abort = async () => {};
  engine.sessions.set('fixture', record);
  const prompt = engine.prompt(record, 'do not send', () => {});
  await preparing;
  await engine.handle('session/cancel', { sessionId: 'fixture' });
  release();
  assert.equal((await prompt).stopReason, 'cancelled');
  assert.equal(prompts, 0);
  assert.deepEqual(selected, []);
  assert.equal(record.busy, false);
});

test('valid borrowed access survives a failed early renewal request', async t => {
  const directory = await temporary(t);
  const engine = await new DefaultAgentEngine({
    cwd: directory, directory,
    credentials: { xai: { type: 'oauth', access: 'still-valid', borrowed: true, expires: Date.now() + 30000 } },
    requestCredentials: async () => { throw new Error('temporarily disconnected'); },
  }).initialize();
  assert.equal((await engine.runtime.getAuth('xai', { allowWait: false })).auth.apiKey, 'still-valid');
});
test('credentials migrate to encrypted storage and refresh ownership remains separate', async t => {
  const directory = await temporary(t);
  const key = randomBytes(32).toString('base64');
  await writePrivateJSON(join(directory, 'oauth.json'), { xai: { type: 'oauth', access: 'fixture-access', refresh: 'owned-refresh', expires: 0 } });
  const vault = new CredentialVault(directory);
  await vault.unlock('workspace-a', key);
  const credentials = await new Credentials({}, vault).initialize();
  await credentials.modify('xai', async old => ({ ...old, access: 'rotated-access' }));
  const contents = await readFile(vault.path, 'utf8');
  assert.ok(!contents.includes('owned-refresh') && !contents.includes('rotated-access'));
  assert.equal((await stat(vault.path)).mode & 0o777, 0o600);
  await assert.rejects(readFile(join(directory, 'oauth.json')), { code: 'ENOENT' });
  const restarted = new CredentialVault(directory);
  await assert.rejects(restarted.read(), /locked/);
  await assert.rejects(restarted.unlock('workspace-a', randomBytes(32).toString('base64')), /decrypted/);
  await assert.rejects(restarted.read(), /locked/);
  await assert.rejects(restarted.unlock('workspace-b', key), /decrypted/);
  await restarted.unlock('workspace-a', key);
  assert.equal((await restarted.read()).owned.xai.access, 'rotated-access');
  const borrowed = await new Credentials({ xai: { type: 'oauth', access: 'fixture', refresh: '', borrowed: true, expires: 0 } }).initialize();
  await assert.rejects(borrowed.modify('xai', async c => c), /Authentication required/);
});
test('remote service owns an accepted run and completion can be recovered without resubmission', async t => {
  const directory = await temporary(t);
  const service = createDefaultAgentService({ cwd: directory, directory });
  await service.configure({ workspace: 'fixture', unlockKey: randomBytes(32).toString('base64'), config: {}, credentials: {}, revision: '1' });
  // Inject a provider-free fake session at the SDK boundary, retain real service journaling.
  const engine = await service.engine();
  let release;
  let calls = 0;
  const sessionID = crypto.randomUUID();
  engine.handle = async (method, params, emit) => {
    if (method === 'session/prompt') { calls++; emit({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'finished remotely' } }); await new Promise(resolve => { release = resolve; }); return { stopReason: 'end_turn' }; }
    return { sessionId: sessionID };
  };
  const operationID = crypto.randomUUID();
  const request = { method: 'session/prompt', operationID, params: { sessionId: sessionID, _meta: { wovenRunID: operationID } } };
  await Promise.all(Array.from({ length: 12 }, () => service.invoke(request)));
  assert.equal(calls, 1);
  assert.equal((await service.poll(operationID)).done, false);
  // No reader is attached while the task finishes.
  release();
  let page;
  do { await new Promise(resolve => setTimeout(resolve, 5)); page = await service.poll(operationID); } while (!page.done);
  assert.equal(page.updates[0].content.text, 'finished remotely');
  const recovered = createDefaultAgentService({ cwd: directory, directory });
  const restored = await recovered.poll(operationID);
  assert.equal(restored.done, true);
  assert.equal(restored.result.stopReason, 'end_turn');
  assert.equal(JSON.parse(await readFile(join(directory, `run-${operationID}.json`))).snapshot.runID, operationID);
});

test('independent remote sign-in takes priority over updates and is encrypted across helpers', async t => {
  const directory = await temporary(t), key = randomBytes(32).toString('base64');
  const first = new CredentialVault(directory), second = new CredentialVault(directory);
  await first.unlock('fixture', key); await second.unlock('fixture', key);
  await first.modify(async () => ({ shared: { xai: { type: 'oauth', access: 'borrowed', borrowed: true, expires: 0 } } }));
  const login = await new Credentials({}, second).initialize();
  login.signingIn = true;
  await login.modify('xai', async () => ({ type: 'oauth', access: 'new-login', refresh: 'owned', expires: Date.now() + 3600000 }));
  const running = await new Credentials({}, first).initialize();
  assert.equal((await running.read('xai')).access, 'new-login');
  await first.modify(async stored => ({ ...stored, shared: { xai: { type: 'oauth', access: 'new-borrowed', borrowed: true, expires: 1 } } }));
  assert.equal((await running.read('xai')).access, 'new-login');
});
test('raw Codex HTTP errors distinguish subscription exhaustion from transient 429s before SDK rewriting', async () => {
  for (const [code, shouldFallback] of [['usage_limit_reached', true], ['rate_limit_exceeded', false]]) {
    const record = {};
    const fetchRequest = providerFetch(record, async () => new Response(JSON.stringify({ error: { code } }), { status: 429 }));
    const response = await fetchRequest('https://example.test');
    assert.equal(Boolean(record.httpAccessFailure), shouldFallback);
    assert.equal((await response.json()).error.code, code);
  }
});

test('HTTP failure inspection stops at its byte limit and leaves the SDK body intact', async () => {
  const body = 'x'.repeat(65536) + ' insufficient_quota';
  const record = {};
  const request = providerFetch(record, async () => new Response(body, { status: 429 }));
  const response = await request('https://example.test');
  assert.equal(record.httpAccessFailure, null);
  assert.equal(await response.text(), body);
});
