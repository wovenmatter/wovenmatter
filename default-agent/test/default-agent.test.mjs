import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, stat } from 'node:fs/promises';
import { join } from 'node:path';
import { accessFailure, validateConfig, writePrivateJSON } from '../src/config.mjs';
import { searchTools } from '../src/search.mjs';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { createDefaultAgentService } from '../src/service.mjs';
import { Credentials } from '../src/credentials.mjs';
import { providerFetch } from '../src/transport.mjs';

const temporary = () => mkdtemp('/tmp/woven-default-agent-test-');
test('fallback classifies unavailable credentials and exhausted allowances, not ordinary throttling', () => {
  for (const message of ['401 Unauthorized', 'invalid_api_key', 'invalid_grant', 'Authentication required', 'insufficient_quota', 'usage_limit_reached', '402 Payment Required', 'insufficient credits']) assert.ok(accessFailure(message), message);
  for (const message of ['429 Too Many Requests', '500 server error', 'fetch failed', '403 forbidden', 'cancelled']) assert.equal(accessFailure(message), null, message);
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
test('real SDK loads the complete selected tool set and resumes an empty draft without a Pi install', async () => {
  const directory = await temporary();
  const engine = await new DefaultAgentEngine({ cwd: directory, directory, discover: false }).initialize();
  const record = await engine.create();
  assert.deepEqual(new Set(record.session.getActiveToolNames()), new Set(['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls', 'web_search', 'web_read']));
  const second = await new DefaultAgentEngine({ cwd: directory, directory, discover: false }).initialize();
  const resumed = await second.create(record.session.sessionId);
  assert.equal(resumed.session.sessionId, record.session.sessionId);
  await assert.rejects(engine.prompt(record, 'No provider should be consumed', () => {}), /No configured connection/);
});
function fixtureEngine({ errors = [], connected = ['openai-codex', 'openrouter'], visible = false } = {}) {
  const engine = new DefaultAgentEngine({ cwd: '/tmp', directory: '/tmp', config: { defaultModel: 'openai-codex/primary', fallbackModels: ['openrouter/fallback'] }, discover: false });
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
test('credentials stay in private files and external refresh ownership is never duplicated', async () => {
  const directory = await temporary();
  const path = join(directory, 'oauth.json');
  await writePrivateJSON(path, { xai: { type: 'oauth', access: 'fixture', refresh: 'owned', expires: Date.now() + 3600000 } });
  assert.equal((await stat(path)).mode & 0o777, 0o600);
  const credentials = await new Credentials(path, {}, false).initialize();
  await credentials.modify('xai', async old => ({ ...old, access: 'rotated' }));
  assert.equal(JSON.parse(await readFile(path, 'utf8')).xai.access, 'rotated');
  const borrowed = await new Credentials(join(directory, 'borrowed.json'), { xai: { type: 'oauth', access: 'fixture', refresh: '', borrowed: true, expires: 0 } }, false).initialize();
  await assert.rejects(borrowed.modify('xai', async c => c), /Authentication required/);
});
test('remote service owns an accepted run and completion can be recovered without resubmission', async () => {
  const directory = await temporary();
  const service = createDefaultAgentService({ cwd: directory, directory, discover: false });
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
  const recovered = createDefaultAgentService({ cwd: directory, directory, discover: false });
  const restored = await recovered.poll(operationID);
  assert.equal(restored.done, true);
  assert.equal(restored.result.stopReason, 'end_turn');
  assert.equal(JSON.parse(await readFile(join(directory, `run-${operationID}.json`))).snapshot.runID, operationID);
});

test('credential refresh observes rotations made by another helper and permits an explicit replacement sign-in', async () => {
  const directory = await temporary();
  const path = join(directory, 'oauth.json');
  await writePrivateJSON(path, { xai: { type: 'oauth', access: 'old', refresh: 'old', expires: 0 } });
  const credentials = await new Credentials(path, {}, false).initialize();
  await writePrivateJSON(path, { xai: { type: 'oauth', access: 'new', refresh: 'new', expires: Date.now() + 3600000 } });
  const current = await credentials.modify('xai', async () => undefined);
  assert.equal(current.access, 'new');
  const borrowed = await new Credentials(join(directory, 'borrowed.json'), { xai: { type: 'oauth', access: 'expired', refresh: '', borrowed: true, expires: 0 } }, false).initialize();
  borrowed.signingIn = true;
  await borrowed.modify('xai', async () => ({ type: 'oauth', access: 'new-login', refresh: 'owned', expires: Date.now() + 3600000 }));
  assert.equal((await borrowed.read('xai')).access, 'new-login');
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
