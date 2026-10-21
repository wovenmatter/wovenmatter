import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, readFile, stat, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { writePrivateJSON } from '../src/config.mjs';
import { searchTools } from '../src/search.mjs';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { createDefaultAgentService } from '../src/service.mjs';
import { Credentials } from '../src/credentials.mjs';
import { CredentialVault, sharedAccounts, sharedCredentials } from '../src/vault.mjs';
import { randomBytes } from 'node:crypto';


async function temporary(t) {
  const directory = await mkdtemp('/tmp/woven-default-agent-test-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

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

test('real SDK loads the complete selected tool set and resumes an empty draft without a Pi install', async t => {
  const directory = await temporary(t);
  // A user's global/workspace Pi extensions must never execute in Built-in,
  // even when they register tools or mutate the tool loadout.
  const marker = join(directory, 'extension-loaded');
  const extension = `import { writeFileSync } from 'node:fs';
    export default pi => {
      writeFileSync(${JSON.stringify(marker)}, 'loaded');
      pi.registerTool({ name: 'unexpected_extension_tool' });
    };`;
  for (const extensions of [join(directory, 'extensions'), join(directory, '.pi/extensions')]) {
    await mkdir(extensions, { recursive: true });
    await writeFile(join(extensions, 'unexpected.mjs'), extension);
  }
  const engine = await new DefaultAgentEngine({ cwd: directory, directory, config: { providers: ['openai'] } }).initialize();
  const record = await engine.create();
  const selected = (await record.conversation.agent(BACKGROUND_CONTEXT)).tools.map(tool => tool.name);
  assert.deepEqual(new Set(selected), new Set(['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls', 'web_search', 'web_read', 'update_checklist', 'browser', 'computer', 'subagent', 'codemode']));
  assert.deepEqual(new Set(record.registry.snapshot().tools().map(({ tool }) => tool.name)), new Set(selected));
  await assert.rejects(readFile(marker), { code: 'ENOENT' });
  const second = await new DefaultAgentEngine({ cwd: directory, directory, config: { providers: ['openai'] } }).initialize();
  await assert.rejects(engine.prompt(record, 'No provider should be consumed', () => {}), /No configured connection/);
  await record.session.dispose();
  const resumed = await second.create(record.session.sessionId);
  assert.equal(resumed.session.sessionId, record.session.sessionId);
  await assert.rejects(readFile(marker), { code: 'ENOENT' });
  t.after(() => resumed.session.dispose());
});
function fixtureEngine({ errors = [], connected = ['openai-codex', 'openrouter'], visible = false, streamEvents = [] } = {}) {
  const engine = new DefaultAgentEngine({ cwd: '/tmp', directory: '/tmp', config: { defaultModel: 'openai-codex/primary', models: ['openrouter/fallback'], fallbackModels: ['openrouter/fallback'] } });
  const selected = [];
  let listener;
  const record = {
    selected: 'openai-codex/primary', busy: false,
    manifest: { storeID: 'fixture' }, subagents: { async beginGroup() {} },
    contextLeaf: () => 'before', rewind() {}, saveOptions() {},
    subscribe(fn) { listener = fn; return () => {}; },
    session: {
      messages: [], refreshContext() {},
      async setModel(model) { selected.push(model.provider); record.selected = model.provider + '/' + model.id; },
      async prompt() {
        for (const update of streamEvents) listener({ update });
        if (visible) listener({ update: { sessionUpdate: 'tool_call', toolCallId: 't', title: 'bash' } });
        if (errors.length) throw new Error(errors.shift());
      },
    },
  };
  engine.resolveModel = ref => { const [provider, id] = ref.split('/'); return { provider, id, name: id }; };
  engine.credentials = new Credentials(Object.fromEntries(connected.map(p => [p, { type: 'api_key', key: 'fixture' }])));
  engine.runtime = { getAuth: async () => ({}), getModels: () => [{ provider: 'openai-codex', id: 'primary', name: 'Primary' }, { provider: 'openrouter', id: 'fallback', name: 'Fallback' }] };
  return { engine, record, selected };
}

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
  let aborted = false;
  record.session.abort = async () => { aborted = true; };
  engine.sessions.set('fixture', record);
  const prompt = engine.prompt(record, 'do not send', () => {});
  await preparing;
  await engine.handle('session/cancel', { sessionId: 'fixture' });
  release();
  assert.equal((await prompt).stopReason, 'cancelled');
  assert.equal(prompts, 0);
  assert.equal(aborted, true);
  assert.deepEqual(selected, []);
  assert.equal(record.busy, false);
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
test('remote admission deduplicates current output and fences uncertain prior acceptance', async t => {
  const directory = await temporary(t);
  let release, calls = 0;
  const sessionID = crypto.randomUUID(), operationID = crypto.randomUUID();
  const engine = { handle: async (method, params, emit) => {
    calls++; await emit({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'finished remotely' } });
    await new Promise(resolve => { release = resolve; }); return { stopReason: 'end_turn' };
  } };
  const service = createDefaultAgentService({ cwd: directory, directory, engineFactory: async () => engine });
  const request = { method: 'session/prompt', operationID, params: { sessionId: sessionID, prompt: [{ type: 'text', text: 'Original' }] } };
  const changed = { ...request, params: { ...request.params, prompt: [{ type: 'text', text: 'Different' }] } };
  const first = service.invoke(request);
  await assert.rejects(service.invoke(changed), /different request/);
  await first;
  await Promise.all(Array.from({ length: 12 }, () => service.invoke(request)));
  await service.invoke({ ...request, params: { prompt: [{ text: 'Original', type: 'text' }], sessionId: sessionID } });
  assert.equal(calls, 1); assert.equal((await service.poll(operationID)).done, false);
  release();
  let page;
  do { await new Promise(resolve => setImmediate(resolve)); page = await service.poll(operationID); } while (!page.done);
  assert.equal(page.updates[0].content.text, 'finished remotely'); assert.equal(page.result.stopReason, 'end_turn');
  assert.equal((await service.poll(operationID, 1)).updates.length, 0);
  await assert.rejects(service.invoke(changed), /different request/);
  const tombstone = JSON.parse(await readFile(join(directory, `accepted-${operationID}.json`)));
  assert.deepEqual(Object.keys(tombstone), ['fingerprint']);
  const restarted = createDefaultAgentService({ cwd: directory, directory, engineFactory: async () => engine });
  await assert.rejects(restarted.invoke(changed), /different request/);
  await assert.rejects(restarted.invoke(request), /uncertain.*not be replayed/);
  await assert.rejects(restarted.poll(operationID), /no longer available/); assert.equal(calls, 1);
});

test('account fallback follows priority without changing another session credential', async () => {
  const { engine, record } = fixtureEngine({ errors: ['insufficient_quota'] });
  engine.config.fallbackModels = [];
  engine.credentials.accounts = { 'openai-codex': [
    { id: 'first', label: 'First', credential: { type: 'api_key', key: 'first-secret' } },
    { id: 'second', label: 'Second', credential: { type: 'api_key', key: 'second-secret' } },
  ] };
  const used = []; const events = [];
  engine.runtime.getAuth = async () => { used.push((await engine.credentials.read('openai-codex')).key); return {}; };
  await engine.prompt(record, 'hello', event => events.push(event));
  assert.deepEqual(used, ['first-secret', 'second-secret']);
  assert.match(events.at(-1)._meta.fallbackReason, /Second/);
  assert.equal((await engine.credentials.read('openai-codex')).key, 'fixture');
});

test('account backups are encrypted and borrowed tokens never export renewal secrets', async t => {
  const directory = await temporary(t);
  const vault = new CredentialVault(directory);
  await vault.unlock('accounts-test', randomBytes(32).toString('base64'));
  const accounts = sharedAccounts({
    'openai-codex': [{ id: 'account', label: 'Work', credential: { type: 'oauth', access: 'borrowed-access', refresh: 'never-export', expires: Date.now() + 10000 } }],
    anthropic: [{ id: 'key', label: 'API key', credential: { type: 'api_key', key: 'private-api-key' } }],
  });
  assert.equal(accounts['openai-codex'][0].credential.refresh, '');
  await vault.modify(async () => ({ accounts, owned: { 'openai-codex': { type: 'oauth', access: 'workspace-owned' } } }));
  const disk = await readFile(vault.path, 'utf8');
  assert.ok(!disk.includes('borrowed-access') && !disk.includes('private-api-key') && !disk.includes('never-export'));
  const credentials = new Credentials({}, vault);
  const candidates = await credentials.candidates('openai-codex');
  assert.equal(candidates[0].credential.access, 'workspace-owned');
  assert.equal(candidates[1].credential.access, 'borrowed-access');
});
test('account fallback never retries throttling or a turn with visible output', async () => {
  for (const [error, visible] of [['429 Too Many Requests', false], ['insufficient_quota', true]]) {
    const { engine, record } = fixtureEngine({ errors: [error], visible });
    engine.config.fallbackModels = [];
    engine.credentials.accounts = { 'openai-codex': ['one', 'two'].map(id => ({ id, label: id, credential: { type: 'api_key', key: id } })) };
    let attempts = 0; engine.runtime.getAuth = async () => { attempts++; return {}; };
    await assert.rejects(engine.prompt(record, 'hello', () => {}));
    assert.equal(attempts, 1);
  }
});

test('native profile sharing includes only an identifier, never native credentials', () => {
  assert.deepEqual(sharedCredentials({ 'claude-subscription': { type: 'native', accountId: 'profile-1', access: 'must-not-share', refresh: 'must-not-share' } }),
    { 'claude-subscription': { type: 'native', accountId: 'profile-1' } });
  assert.deepEqual(sharedCredentials({ 'claude-subscription': { type: 'native', accountId: '../outside' } }), {});
  assert.deepEqual(sharedAccounts({ 'claude-subscription': [{ id: 'fixture', label: 'Invalid', credential: { type: 'native', accountId: '../outside' } }] }), { 'claude-subscription': [] });
});

test('removing a workspace-owned account does not silently switch an active turn to shared credentials', async () => {
  const credentials = new Credentials({ openai: { type: 'api_key', key: 'shared' } });
  credentials.owned.openai = { type: 'api_key', key: 'workspace' };
  const [account] = await credentials.candidates('openai');
  await credentials.runWithAccount('openai', account, async () => {
    assert.equal((await credentials.read('openai')).key, 'workspace');
    delete credentials.owned.openai;
    assert.equal(await credentials.read('openai'), undefined);
  });
  assert.equal((await credentials.read('openai')).key, 'shared');
});
