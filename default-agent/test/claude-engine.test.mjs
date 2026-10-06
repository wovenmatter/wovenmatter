import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, realpath, rm, readFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { ClaudeRuntime } from '../src/claude-runtime.mjs';
import { createDefaultAgentService } from '../src/service.mjs';

async function fixture(t, { credentials = {}, credentialAccounts = {}, config = {} } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'woven-claude-engine-'));
  const claude = {
    checks: 0,
    models: [{ value: 'sonnet', displayName: 'Claude Sonnet', supportedEffortLevels: ['low', 'medium', 'high'] }],
    loadModels: async () => {},
    async status() { this.checks++; return { connected: true }; },
    environment: async () => ({}),
    // Metadata-only initialization is supported without inference. Synthetic
    // Models streams below own every fixture generation.
    sdkQuery: async () => ({ accountInfo: async () => ({ email: 'fixture@example.invalid', organization: 'fixture-org', apiProvider: 'firstParty' }), close() {} }),
  };
  const options = { cwd: root, directory: root, claude, credentials, credentialAccounts,
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

async function pollUntil(service, id, predicate) {
  const deadline = Date.now() + 5000;
  while (true) {
    const page = await service.poll(id);
    if (predicate(page)) return page;
    if (Date.now() >= deadline) assert.fail('Timed out waiting for the synthetic remote run.');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

test('ordinary Claude submissions reuse the selected model without spawning native status checks', async t => {
  const { engine, claude } = await fixture(t);
  const record = await engine.create();
  record.streamFunction = syntheticAssistant([{ type: 'text', text: 'Fixture reply' }]);
  const beforeChecks = claude.checks;
  await engine.prompt(record, 'First', () => {});
  await engine.prompt(record, 'Second', () => {});
  assert.equal(claude.checks, beforeChecks);
  assert.equal(record.selected, 'claude-subscription/sonnet');
});

test('Durable fallback rebuilds canonical history without replaying the failed prompt', async t => {
  const { engine, options } = await fixture(t, {
    credentials: { openai: { type: 'api_key', key: 'fixture' } },
    config: { providers: ['openai', 'claude-subscription'], defaultModel: 'openai/gpt-4o',
      models: ['claude-subscription/sonnet'], fallbackModels: ['claude-subscription/sonnet'] },
  });
  const record = await engine.create();
  const respond = syntheticAssistant([{ type: 'text', text: 'Fixture reply' }]);
  record.streamFunction = respond;
  await engine.prompt(record, 'Earlier question', () => {});
  const contexts = [];
  record.streamFunction = (model, context) => {
    contexts.push({ provider: model.provider, messages: context.messages });
    if (model.provider === 'openai') {
      const stream = createAssistantMessageEventStream();
      const result = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
        content: [], timestamp: Date.now(), stopReason: 'error', errorMessage: 'insufficient_quota',
        usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
          cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
      stream.push({ type: 'error', reason: 'error', error: result }); stream.end(result);
      return stream;
    }
    return respond(model);
  };
  assert.equal((await engine.prompt(record, 'New question', () => {})).stopReason, 'end_turn');
  assert.deepEqual(contexts.map(context => context.provider), ['openai', 'claude-subscription']);
  const fallback = contexts[1].messages;
  assert.equal(fallback.filter(message => message.role === 'user').length, 2);
  assert.ok(fallback.some(message => message.role === 'assistant' && message.content.some(block => block.text === 'Fixture reply')));
  assert.ok(!fallback.some(message => message.stopReason === 'error'));
  await record.session.dispose();
  const restored = await new DefaultAgentEngine(options).initialize();
  const resumed = await restored.create(record.session.sessionId);
  t.after(() => resumed.session.dispose());
  assert.equal(resumed.session.messages.filter(message => message.role === 'user').length, 2);
  assert.equal(resumed.session.messages.filter(message => message.role === 'assistant').length, 2);
});

test('handled Pi preflight cannot acknowledge steering as injected', async t => {
  const { engine } = await fixture(t);
  const record = await engine.create();
  const started = Promise.withResolvers(), finish = Promise.withResolvers();
  record.session.prompt = async (text, options) => {
    options.preflightResult(text === 'start' ? 'started' : 'handled');
    if (text === 'start') { started.resolve(); await finish.promise; }
  };
  const turn = engine.prompt(record, 'start', () => {});
  await started.promise;
  await assert.rejects(engine.steer(record, 'intercepted'), /without entering the model conversation/);
  finish.resolve();
  await turn;
});

test('real ModelRuntime uses ambient Claude auth while native profiles retain account routing', async t => {
  const first = { type: 'native', accountId: 'profile-first' };
  const second = { type: 'native', accountId: 'profile-second' };
  const accounts = [
    { id: 'first', label: 'First', credential: first },
    { id: 'second', label: 'Second', credential: second },
  ];
  const { engine, claude, root } = await fixture(t, {
    credentials: { 'claude-subscription': first },
    credentialAccounts: { 'claude-subscription': accounts },
  });
  // Use the real native profile context without starting a native process.
  const profiles = new ClaudeRuntime(root);
  claude.withProfile = profiles.withProfile.bind(profiles);
  const seenProfiles = [];
  const synthetic = syntheticAssistant([{ type: 'text', text: 'Fixture reply' }]);
  const stream = (...args) => {
    seenProfiles.push(profiles.profileDirectory());
    return synthetic(...args);
  };
  const provider = engine.runtime.getProvider('claude-subscription');
  engine.runtime.registerNativeProvider({ ...provider, stream, streamSimple: stream });
  await engine.runtime.refresh({ allowNetwork: false });
  const selected = engine.resolveModel('claude-subscription/sonnet');
  const auth = await engine.runtime.getAuth(selected);
  assert.equal(auth.source, 'Claude runtime');
  assert.equal(auth.auth.apiKey, undefined);
  assert.equal(auth.auth.headers, undefined);
  assert.deepEqual(await engine.runtime.models.getAuth(selected), { auth: {}, source: 'Claude runtime' });
  assert.deepEqual(await engine.credentials.read('claude-subscription'), first);
  assert.deepEqual((await engine.credentials.candidates('claude-subscription')).map(value => value.credential), [first, second]);

  // Keep Pi's real stream/auth machinery; replace only the provider transport.
  const checks = claude.checks;
  const record = await engine.create();
  assert.equal((await engine.prompt(record, 'First account', () => {})).stopReason, 'end_turn');
  assert.equal(record.session.messages.at(-1).content[0].text, 'Fixture reply');
  await engine.apply({ credentials: { 'claude-subscription': second },
    credentialAccounts: { 'claude-subscription': [accounts[1], accounts[0]] } });
  assert.equal((await engine.prompt(record, 'Second account', () => {})).stopReason, 'end_turn');
  assert.deepEqual(seenProfiles, [join(root, 'claude-accounts', 'profile-first'), join(root, 'claude-accounts', 'profile-second')]);
  assert.equal(claude.checks, checks);
  assert.deepEqual(await engine.credentials.read('claude-subscription'), second);
  const controller = new AbortController(); controller.abort();
  await assert.rejects(engine.runtime.getAuth(selected, { signal: controller.signal }), { name: 'AbortError' });
});

test('Claude profile adaptation preserves unrelated provider credentials and rejects unknown types', async t => {
  const key = { type: 'api_key', key: 'fixture-key' };
  const oauth = { type: 'oauth', access: 'fixture-access', refresh: 'fixture-refresh', expires: Date.now() + 3600000 };
  const unknown = { type: 'native', accountId: 'not-an-openrouter-credential' };
  const { engine } = await fixture(t, { credentials: {
    'claude-subscription': { type: 'native', accountId: 'fixture-profile' },
    openai: key, xai: oauth, openrouter: unknown,
  } });
  const store = engine.credentials.forModelRuntime();
  assert.equal(await store.read('claude-subscription'), undefined);
  assert.deepEqual(await store.read('openai'), key);
  assert.deepEqual(await store.read('xai'), oauth);
  assert.deepEqual(await store.read('openrouter'), unknown);
  assert.equal((await engine.runtime.getAuth('openai')).auth.apiKey, key.key);
  assert.equal(await engine.runtime.getAuth('openrouter'), undefined);
  assert.equal((await store.list()).some(value => value.providerId === 'claude-subscription'), false);
  assert.equal((await engine.credentials.list()).some(value => value.providerId === 'claude-subscription'), true);
  await store.modify('openai', current => ({ ...current, key: 'fixture-replacement' }));
  assert.equal((await engine.credentials.read('openai')).key, 'fixture-replacement');
  await store.delete('openai');
  assert.equal(await engine.credentials.read('openai'), undefined);
  // A wrong credential type on Claude is not treated as native profile metadata.
  await engine.apply({ credentials: { 'claude-subscription': oauth } });
  assert.equal(await engine.runtime.getAuth('claude-subscription'), undefined);
});

test('an Exa key and disabled model credentials do not hide the native Claude default', async t => {
  const { engine } = await fixture(t, {
    config: { providers: ['openai', 'claude-subscription'], defaultModel: null },
    credentials: { exa: { type: 'api_key', key: 'fixture-search' }, openrouter: { type: 'api_key', key: 'fixture-disabled' } },
  });
  assert.equal((await engine.create()).selected, 'claude-subscription/sonnet');
});

test('Built-in Durable exposes only native Full Access and never asks Woven file/command approvals', async t => {
  const { engine, root } = await fixture(t);
  const record = await engine.create();
  const permission = engine.configuration(record).configOptions.find(o => o.id === 'permission_mode');
  assert.deepEqual(permission.options.map(o => o.value), ['full']);
  let calls = 0; record.streamFunction = syntheticAssistant(() => ++calls === 1 ? [{ type: 'toolCall', id: 'native-write', name: 'write', arguments: { path: 'note.txt', content: 'allowed' } }] : [{ type: 'text', text: 'Saved' }]);
  await engine.prompt(record, 'Write the note', () => {});
  assert.equal(await readFile(join(root, 'note.txt'), 'utf8'), 'allowed');
  await assert.rejects(engine.select(record, 'normal', 'permission_mode'), /Unknown permission mode/);
});

test('model, thinking, and permission choices survive an empty draft restart', async t => {
  const { engine, options } = await fixture(t);
  const record = await engine.create();
  await engine.select(record, 'high', 'thinking');
  await engine.select(record, 'full', 'permission_mode');
  await record.session.dispose();
  const restarted = await new DefaultAgentEngine(options).initialize();
  t.after(async () => { for (const record of [...restarted.sessions.values()]) await record.session.dispose(); });
  const restored = await restarted.create(record.session.sessionId);
  assert.equal(restored.selected, 'claude-subscription/sonnet');
  assert.equal(restored.session.thinkingLevel, 'high');
  assert.equal(restored.permission, 'full');
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

test('invalid or unavailable working directories fail before a Built-in session is created', async t => {
  const { engine, root } = await fixture(t);
  for (const cwd of ['relative/project', '', 'invalid\0directory', join(root, 'missing')]) {
    await assert.rejects(engine.handle('session/new', { cwd }), /working directory/);
  }
  assert.equal(engine.sessions.size, 0);
});

test('remote Durable journals native records alongside current run output', async t => {
  const { engine, root } = await fixture(t);
  const service = createDefaultAgentService({ cwd: root, directory: root, engineFactory: () => engine });
  const record = await engine.create();
  let generation = 0;
  record.streamFunction = syntheticAssistant(() => ++generation === 1
    ? [{ type: 'toolCall', id: 'write-remote', name: 'write', arguments: { path: 'remote.txt', content: 'native' } }]
    : [{ type: 'text', text: 'Done' }]);
  const id = crypto.randomUUID();
  await service.invoke({ method: 'session/prompt', operationID: id, params: { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Write fixture' }] } });
  const page = await pollUntil(service, id, page => page.done);
  assert.equal(page.error, null);
  assert.ok(page.updates.some(u => u.sessionUpdate === 'woven_native_record'));
  assert.equal(await readFile(join(root, 'remote.txt'), 'utf8'), 'native');
});

test('composer offers only the default and explicitly enabled models', async t => {
  const { engine } = await fixture(t, { config: { providers: ['claude-subscription', 'openai'] } });
  const catalog = engine.catalog();
  const other = catalog.find(model => model.id !== engine.config.defaultModel);
  assert.deepEqual(engine.modelOptions().map(model => model.id), [engine.config.defaultModel]);
  assert.ok(other, 'Fixture must include another catalog model');
  engine.config.models = [other.id];
  assert.deepEqual(engine.modelOptions().map(model => model.id), [engine.config.defaultModel, other.id]);
  engine.config.models = [];
  assert.deepEqual(engine.modelOptions().map(model => model.id), [engine.config.defaultModel]);
});


test('removed models normalize idle and restored selections to the visible default', async t => {
  const { engine } = await fixture(t);
  const record = await engine.create();
  const expected = record.selected;
  record.selected = 'openrouter/disabled';
  record.saveOptions({ selected: record.selected });
  await engine.apply({ config: engine.config });
  assert.equal(record.selected, expected);
  record.selected = 'openrouter/disabled';
  record.saveOptions({ selected: record.selected });
  engine.sessions.delete(record.session.sessionId);
  await record.session.dispose();
  const restored = await engine.create(record.session.sessionId);
  assert.equal(restored.selected, expected);
  engine.config.defaultModel = 'disabled/model';
  assert.equal(engine.modelOptions()[0].id, expected);
});

test('Built-in steering reaches the next model call inside the same native run', async t => {
  const { engine } = await fixture(t);
  const record = await engine.create();
  let started, release;
  const ready = new Promise(resolve => { started = resolve; });
  const gate = new Promise(resolve => { release = resolve; });
  const contexts = [];
  record.streamFunction = syntheticAssistant([{ type: 'text', text: 'reply' }], async (_model, context) => {
    contexts.push(structuredClone(context.messages));
    if (contexts.length === 1) { started(); await gate; }
  });
  const init = await engine.handle('initialize');
  assert.equal(init._meta.steering.supported, true);
  const turn = engine.prompt(record, 'start', () => {});
  await ready;
  for (const text of ['first correction', 'second correction']) {
    assert.deepEqual(await engine.handle('_session/steering', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text }] }), { outcome: 'injected' });
  }
  assert.equal(record.busy, true);
  release();
  assert.equal((await turn).stopReason, 'end_turn');
  assert.ok(contexts.length >= 2);
  const users = record.session.messages.filter(message => message.role === 'user').map(message => message.content.filter(block => block.type === 'text').map(block => block.text).join(''));
  assert.deepEqual(users, ['start', 'first correction', 'second correction']);
  assert.deepEqual(await engine.steer(record, 'idle'), { outcome: 'promptRequired' });
});

for (const stopped of [false, true]) test(`Built-in owns late steering preflight through completion or Stop (stopped=${stopped})`, { timeout: 5000 }, async t => {
  const { engine } = await fixture(t);
  const record = await engine.create();
  let finishFirst, preflightStarted, releasePreflight, originalSettled;
  const firstGate = new Promise(resolve => { finishFirst = resolve; });
  const preflightReady = new Promise(resolve => { preflightStarted = resolve; });
  const preflightGate = new Promise(resolve => { releasePreflight = resolve; });
  const originalDone = new Promise(resolve => { originalSettled = resolve; });
  let calls = 0;
  record.streamFunction = syntheticAssistant([{ type: 'text', text: 'reply' }], async () => {
    if (++calls === 1) await firstGate;
  });
  const nativePrompt = record.session.prompt.bind(record.session);
  record.session.prompt = async (text, options) => {
    if (options?.streamingBehavior === 'steer') { preflightStarted(); await preflightGate; }
    const result = await nativePrompt(text, options);
    if (text === 'start') originalSettled();
    return result;
  };
  const turn = engine.prompt(record, 'start', () => {});
  // Submit immediately, while the engine is still preparing its first prompt.
  const correction = engine.steer(record, 'late correction');
  await preflightReady;
  finishFirst();
  await originalDone;
  assert.equal(record.busy, true);
  if (stopped) await engine.handle('session/cancel', { sessionId: record.session.sessionId });
  const rejected = stopped ? assert.rejects(correction, /abort/i) : null;
  releasePreflight();
  if (stopped) await rejected;
  else assert.deepEqual(await correction, { outcome: 'injected' });
  assert.equal((await turn).stopReason, stopped ? 'cancelled' : 'end_turn');
  assert.equal(calls, stopped ? 1 : 2);
  assert.equal(record.session.messages.filter(message => message.role === 'user').length, stopped ? 1 : 2);
  assert.equal((await record.harness.inspect(BACKGROUND_CONTEXT)).submissions.length, 0);
});

test('an accepted continuation failure drains newer inputs before retiring the run', { timeout: 5000 }, async t => {
  const { engine } = await fixture(t);
  const record = await engine.create();
  const gate = () => Promise.withResolvers();
  const initial = gate(), first = gate(), second = gate(), ready = gate();
  record.session.prompt = async (text, options) => {
    options.preflightResult(text === 'start' ? 'started' : 'queued');
    if (text === 'start') { ready.resolve(); await initial.promise; }
    else await (text === 'first' ? first : second).promise;
  };
  const turn = engine.prompt(record, 'start', () => {});
  const failed = assert.rejects(turn, /model request failed/i);
  await ready.promise;
  await engine.steer(record, 'first');
  initial.resolve();
  await new Promise(resolve => setImmediate(resolve));
  await engine.steer(record, 'second');
  first.reject(new Error('late failure'));
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(record.busy, true);
  second.resolve();
  await failed;
  assert.equal(record.busy, false);
});
