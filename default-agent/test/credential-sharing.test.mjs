import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { SignInStore } from '../src/sign-in-store.mjs';
import { signInStatuses } from '../src/sign-in-status.mjs';

async function temporary(t) {
  const directory = await mkdtemp('/tmp/woven-default-agent-test-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

test('status checks never start login and do not equate a timeout with sign-out', async () => {
  const calls = [];
  const statuses = await signInStatuses([
    { id: 'codex', name: 'Codex', executable: '/fixture/codex' },
    { id: 'claude_code', name: 'Claude', executable: '/fixture/claude' },
    { id: 'disabled_fixture', name: 'Disabled', enabled: false },
    { id: 'opencode', executable: '/fixture/opencode' },
    { id: 'grok_build', executable: '/fixture/grok' },
    ...['unknown_one', 'unknown_two'].map(id => ({ id, executable: '/fixture/' + id })),
  ], async (file, args) => {
    calls.push(args);
    if (file.endsWith('claude')) throw { killed: true };
    return { stdout: file.endsWith('opencode') ? '└  2 credentials\n└  0 environment variables' : file.endsWith('grok') ? 'Available models: fixture' : 'Logged in using ChatGPT' };
  });
  assert.equal(statuses[0].state, 'verified');
  assert.equal(statuses[1].state, 'check_failed');
  assert.equal(statuses[2].state, 'not_checked');
  assert.equal(statuses[3].state, 'credentials_present');
  assert.equal(statuses[4].state, 'not_checked');
  assert.ok(statuses.slice(5).every(status => status.state === 'not_checked'));
  assert.equal(calls.length, 4);
  assert.deepEqual(calls[0], ['login', 'status']);
  assert.ok(!calls.some(args => args.includes('prompt')));
});

for (const provider of ['openai-codex', 'claude-subscription', 'xai']) {
  test(`${provider} exposes one account and never falls back from workspace-owned auth`, async t => {
    const { Credentials } = await import('../src/credentials.mjs');
    const credential = id => provider === 'claude-subscription'
      ? { type: 'native', accountId: id } : { type: 'oauth', access: id, expires: 9000000000000 };
    const entries = ['preferred', 'backup'].map(id => ({ id, label: id, credential: credential(id) }));
    const directory = await temporary(t), vault = await new SignInStore(directory).open();
    await vault.modify(async value => ({ ...value, accounts: { [provider]: entries } }));
    const credentials = await new Credentials({}, vault).initialize();
    assert.deepEqual((await credentials.candidates(provider)).map(a => a.id), ['preferred']);
    assert.equal(await credentials.runWithAccount(provider, entries[1], () => credentials.read(provider)), undefined);
    await vault.modify(async value => ({ ...value, owned: { [provider]: credential('workspace') } }));
    assert.deepEqual((await credentials.candidates(provider)).map(a => a.credential), [credential('workspace')]);
    assert.equal(await credentials.runWithAccount(provider, entries[0], () => credentials.read(provider)), undefined);
    const [owned] = await credentials.candidates(provider);
    await vault.modify(async value => ({ ...value, owned: {} }));
    assert.equal(await credentials.runWithAccount(provider, owned, () => credentials.read(provider)), undefined);
    // A later explicit removal of the workspace sign-in restores shared auth.
    assert.deepEqual((await credentials.candidates(provider)).map(a => a.id), ['preferred']);
  });
}
