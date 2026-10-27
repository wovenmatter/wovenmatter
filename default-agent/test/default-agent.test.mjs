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


function fixtureEngine({ errors = [], connected = ['openai', 'openrouter'], visible = false, streamEvents = [] } = {}) {
  const engine = new DefaultAgentEngine({ cwd: '/tmp', directory: '/tmp', config: { defaultModel: 'openai/primary', models: ['openrouter/fallback'], fallbackModels: ['openrouter/fallback'] } });
  const selected = [];
  let listener;
  const record = {
    selected: 'openai/primary', busy: false,
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
  engine.runtime = { getAuth: async () => ({}), getModels: () => [{ provider: 'openai', id: 'primary', name: 'Primary' }, { provider: 'openrouter', id: 'fallback', name: 'Fallback' }] };
  return { engine, record, selected };
}



test('account fallback follows priority without changing another session credential', async () => {
  const { engine, record } = fixtureEngine({ errors: ['insufficient_quota'] });
  engine.config.fallbackModels = [];
  engine.credentials.accounts = { 'openai': [
    { id: 'first', label: 'First', credential: { type: 'api_key', key: 'first-secret' } },
    { id: 'second', label: 'Second', credential: { type: 'api_key', key: 'second-secret' } },
  ] };
  const used = []; const events = [];
  engine.runtime.getAuth = async () => { used.push((await engine.credentials.read('openai')).key); return {}; };
  await engine.prompt(record, 'hello', event => events.push(event));
  assert.deepEqual(used, ['first-secret', 'second-secret']);
  assert.match(events.at(-1)._meta.fallbackReason, /Second/);
  assert.equal((await engine.credentials.read('openai')).key, 'fixture');
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
