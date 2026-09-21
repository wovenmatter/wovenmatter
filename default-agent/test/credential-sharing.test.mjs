import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { CredentialVault } from '../src/vault.mjs';
import { createDefaultAgentService } from '../src/service.mjs';
import { signInStatuses } from '../src/sign-in-status.mjs';
const temporary = () => mkdtemp('/tmp/woven-default-agent-test-');

test('active sessions survive credential and settings updates and use the latest search key', async () => {
  const directory = await temporary(), key = randomBytes(32).toString('base64');
  const service = createDefaultAgentService({ cwd: directory, directory });
  assert.equal((await service.status()).locked, true);
  const base = { workspace: 'fixture', unlockKey: key, config: {} };
  await service.configure({ ...base, revision: 'first', credentials: { exa: { type: 'api_key', key: 'old-search-secret' } } });
  const engine = await service.engine(), record = await engine.create();
  record.busy = true;
  const receipt = await service.configure({ ...base, revision: 'second', credentials: {
    exa: { type: 'api_key', key: 'new-search-secret' },
    xai: { type: 'oauth', access: 'borrowed-access', refresh: 'must-never-copy', refreshToken: 'also-never-copy', expires: Date.now() + 10000 },
  } });
  assert.equal(receipt.revision, 'second');
  assert.equal(await service.engine(), engine);
  assert.equal(engine.sessions.get(record.session.sessionId), record);
  assert.equal((await engine.credentials.read('exa')).key, 'new-search-secret');
  assert.equal((await engine.credentials.read('xai')).refresh, '');
  assert.equal((await engine.credentials.read('xai')).borrowed, true);
  assert.equal((await engine.credentials.read('xai')).refreshToken, undefined);
  const settings = await readFile(join(directory, 'configuration.json'), 'utf8');
  assert.ok(!settings.includes('secret') && !settings.includes('credentials'));
  const disk = await readFile(join(directory, 'credentials.enc.json'), 'utf8');
  assert.ok(!disk.includes('new-search-secret') && !disk.includes('must-never-copy'));
  const restarted = createDefaultAgentService({ cwd: directory, directory });
  await assert.rejects(restarted.engine(), /locked/);
});

test('tampering fails closed and repeated writes never reuse the GCM nonce', async () => {
  const directory = await temporary(), vault = new CredentialVault(directory);
  await vault.unlock('fixture', randomBytes(32).toString('base64'));
  const initial = JSON.parse(await readFile(vault.path, 'utf8'));
  await vault.modify(async value => ({ ...value, shared: { secret: 'fixture' } }));
  const next = JSON.parse(await readFile(vault.path, 'utf8'));
  assert.notEqual(next.nonce, initial.nonce);
  next.tag = Buffer.alloc(16).toString('base64');
  await writeFile(vault.path, JSON.stringify(next));
  await assert.rejects(vault.read(), /decrypted/);
});

test('expired borrowed auth waits between model requests and resumes without replaying a turn', async () => {
  const directory = await temporary(), service = createDefaultAgentService({ cwd: directory, directory });
  const base = { workspace: 'fixture', unlockKey: randomBytes(32).toString('base64'), config: {} };
  await service.configure({ ...base, revision: 'old', credentials: { xai: { type: 'oauth', access: 'expired', expires: 0 } } });
  const engine = await service.engine();
  let settled = false;
  const auth = engine.runtime.getAuth('xai', { signal: AbortSignal.timeout(5000) }).then(value => { settled = true; return value; });
  await new Promise(resolve => setTimeout(resolve, 30));
  assert.equal(settled, false);
  await service.configure({ ...base, revision: 'new', credentials: { xai: { type: 'oauth', access: 'renewed', expires: Date.now() + 3600000 } } });
  assert.equal((await auth).auth.apiKey, 'renewed');
  // No model calls or tools are submitted by credential recovery.
  assert.equal(engine.sessions.size, 0);
});

test('status checks never start login and do not equate a timeout with sign-out', async () => {
  const calls = [];
  const statuses = await signInStatuses([
    { id: 'codex', name: 'Codex', executable: '/fixture/codex' },
    { id: 'claude_code', name: 'Claude', executable: '/fixture/claude' },
    { id: 'pi', name: 'Pi', enabled: false },
  ], async (file, args) => {
    calls.push(args);
    if (file.endsWith('claude')) throw { killed: true };
    return { stdout: 'Logged in using ChatGPT' };
  });
  assert.equal(statuses[0].state, 'verified');
  assert.equal(statuses[1].state, 'check_failed');
  assert.equal(statuses[2].state, 'not_checked');
  assert.deepEqual(calls[0], ['login', 'status']);
  assert.ok(!calls.some(args => args.includes('prompt')));
});

test('a rejected unlock never replaces a live workspace key', async () => {
  const directory = await temporary(), vault = new CredentialVault(directory);
  await vault.unlock('fixture', randomBytes(32).toString('base64'));
  await vault.modify(async value => ({ ...value, shared: { exa: { type: 'api_key', key: 'still-usable' } } }));
  const rejected = assert.rejects(vault.unlock('fixture', randomBytes(32).toString('base64')), /decrypted/);
  for (let i = 0; i < 20; i++) assert.equal((await vault.read()).shared.exa.key, 'still-usable');
  await rejected;
  assert.equal((await vault.read()).shared.exa.key, 'still-usable');
});

test('an expired borrowed request remains cancellable without attempting OAuth refresh', async () => {
  const directory = await temporary(), service = createDefaultAgentService({ cwd: directory, directory });
  await service.configure({ workspace: 'fixture', unlockKey: randomBytes(32).toString('base64'), config: {},
    credentials: { xai: { type: 'oauth', access: 'expired', expires: 0 } } });
  const engine = await service.engine(), controller = new AbortController();
  const waiting = engine.runtime.getAuth('xai', { signal: controller.signal });
  setTimeout(() => controller.abort(), 20);
  await assert.rejects(waiting, error => error.name === 'AbortError');
  assert.equal(engine.sessions.size, 0);
});

test('OpenCode lists credential presence and ambiguous successful output stays unknown', async () => {
  const rows = await signInStatuses([
    { id: 'opencode', executable: '/fixture/opencode' },
    { id: 'grok_build', executable: '/fixture/grok' },
  ], async file => ({ stdout: file.endsWith('opencode') ? '└  2 credentials\n└  0 environment variables' : 'Available models: fixture' }));
  assert.equal(rows[0].state, 'credentials_present');
  assert.equal(rows[1].state, 'not_checked');
});
