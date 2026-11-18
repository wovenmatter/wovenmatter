import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { SignInStore } from '../src/sign-in-store.mjs';
import { changeSignIns, deviceConfig, listSignIns } from '../src/device-sign-ins.mjs';
import { createDefaultAgentService } from '../src/service.mjs';

async function temporary(t) {
  const directory = await mkdtemp('/tmp/woven-device-sign-ins-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

test('sign-ins are one plain private file in a private folder; malformed content is signed out and replaced', async t => {
  const directory = join(await temporary(t), 'default-agent');
  const vault = await new SignInStore(directory).open();
  assert.equal((await stat(directory)).mode & 0o777, 0o700);
  assert.deepEqual(await vault.read(), {});
  await changeSignIns(vault, { action: 'saveKey', provider: 'openai', key: 'first-secret' });
  assert.deepEqual(await readdir(directory), ['sign-ins.json']);
  assert.equal((await stat(vault.path)).mode & 0o777, 0o600);
  assert.equal(JSON.parse(await readFile(vault.path, 'utf8')).accounts.openai[0].credential.key, 'first-secret');
  // A widened mode is narrowed again on the next read.
  await chmod(vault.path, 0o644);
  await vault.read();
  assert.equal((await stat(vault.path)).mode & 0o777, 0o600);
  for (const malformed of ['{"accounts":', 'null', '[]']) {
    await writeFile(vault.path, malformed, { mode: 0o600 });
    assert.deepEqual(await vault.read(), {});
  }
  await changeSignIns(vault, { action: 'saveKey', provider: 'anthropic', key: 'second-secret' });
  assert.deepEqual(Object.keys((await vault.read()).accounts), ['anthropic']);
  // Several processes changing it at once lose nothing.
  await Promise.all(['xai', 'exa', 'openrouter'].map(id => new SignInStore(directory).modify(async value => ({ ...value, owned: { ...value.owned, [id]: { type: 'api_key', key: id } } }))));
  assert.deepEqual(Object.keys((await vault.read()).owned).sort(), ['exa', 'openrouter', 'xai']);
});

test('a sign-ins file that cannot be read right now fails every change and loses nothing', async t => {
  if (process.getuid?.() === 0) return t.skip('root reads any file');
  const directory = await temporary(t);
  const vault = await new SignInStore(directory).open();
  await changeSignIns(vault, { action: 'saveKey', provider: 'openai', key: 'first-secret' });
  await changeSignIns(vault, { action: 'saveKey', provider: 'anthropic', key: 'second-secret' });
  const before = await readFile(vault.path);
  await chmod(vault.path, 0o000);
  t.after(() => chmod(vault.path, 0o600).catch(() => {}));
  await assert.rejects(vault.modify(async value => ({ ...value, accounts: { exa: [] } })), { code: 'EACCES' });
  await assert.rejects(vault.read(), { code: 'EACCES' });
  await chmod(vault.path, 0o600);
  assert.deepEqual(await readFile(vault.path), before);
  assert.deepEqual(Object.keys((await vault.read()).accounts).sort(), ['anthropic', 'openai']);
});

test('a sign-ins file that is a link is refused, and nothing is written through it', async t => {
  const directory = await temporary(t), target = join(directory, 'elsewhere');
  await writeFile(target, '{}', { mode: 0o600 });
  await symlink(target, join(directory, 'sign-ins.json'));
  const vault = await new SignInStore(directory).open();
  await assert.rejects(vault.read(), /link/);
  await assert.rejects(vault.modify(async () => ({ owned: { xai: { type: 'api_key', key: 'k' } } })), /link/);
  assert.equal(await readFile(target, 'utf8'), '{}');
});

test('API keys are added, ordered and removed on the device and never listed', async t => {
  const vault = await new SignInStore(await temporary(t)).open();
  const first = await changeSignIns(vault, { action: 'saveKey', provider: 'openai', key: ' first-secret ', label: 'Work' });
  const second = await changeSignIns(vault, { action: 'saveKey', provider: 'openai', key: 'second-secret' });
  await changeSignIns(vault, { action: 'saveKey', provider: 'openai', key: 'third-secret' });
  assert.deepEqual(second.accounts.openai.map(a => [a.label, a.isSelected]), [['Work', true], ['API key 2', false]]);
  assert.ok(!JSON.stringify(second).includes('secret'));
  const [, b, c] = (await vault.read()).accounts.openai;
  let listed = await changeSignIns(vault, { action: 'move', provider: 'openai', id: c.id, offset: -1 });
  assert.deepEqual(listed.accounts.openai.map(a => a.id), [first.accounts.openai[0].id, c.id, b.id]);
  listed = await changeSignIns(vault, { action: 'select', provider: 'openai', id: b.id });
  assert.equal(listed.accounts.openai[0].id, b.id);
  assert.equal((await vault.read()).accounts.openai[0].credential.key, 'second-secret');
  listed = await changeSignIns(vault, { action: 'remove', provider: 'openai', id: b.id });
  assert.equal(listed.accounts.openai.length, 2);
  await changeSignIns(vault, { action: 'saveKey', provider: 'exa', key: 'search-secret' });
  for (let i = 0; i < 3; i++) await changeSignIns(vault, { action: 'saveKey', provider: 'exa', key: 'search-' + i });
  await assert.rejects(changeSignIns(vault, { action: 'saveKey', provider: 'exa', key: 'fifth' }), /up to four/);
  await assert.rejects(changeSignIns(vault, { action: 'saveKey', provider: 'openai-codex', key: 'x' }), /provider/);
  await assert.rejects(changeSignIns(vault, { action: 'saveKey', provider: 'openai', key: 'a\nb' }), /API key/);
  await assert.rejects(changeSignIns(vault, { action: 'unknown' }), /sign-in change/);
});

test('subscriptions signed in on the device are listed by label and removed there', async t => {
  const vault = await new SignInStore(await temporary(t)).open();
  const claims = Buffer.from(JSON.stringify({ email: 'person@example.test' })).toString('base64url');
  await vault.modify(async value => ({ ...value, owned: {
    'openai-codex': { type: 'oauth', access: `h.${claims}.s`, refresh: 'r', expires: Date.now() + 3600_000 },
    'claude-subscription': { type: 'native', accountId: 'default', displayName: 'claude@example.test' },
  } }));
  const listed = listSignIns(await vault.read());
  assert.deepEqual(listed.accounts['openai-codex'], [{ id: 'default', label: 'person@example.test', isSelected: true }]);
  assert.deepEqual(listed.accounts['claude-subscription'].map(a => a.label), ['claude@example.test']);
  assert.deepEqual(listed.accounts.xai, []);
  const removed = await changeSignIns(vault, { action: 'remove', provider: 'openai-codex', id: 'default' });
  assert.deepEqual(removed.accounts['openai-codex'], []);
  assert.equal((await vault.read()).owned['openai-codex'], undefined);
});

test('local model servers are checked by the device and their keys stay in its vault', async t => {
  const vault = await new SignInStore(await temporary(t)).open();
  const probes = [];
  const probe = async (url, key) => { probes.push([url, key]); return { url: 'http://localhost:32100/v1', models: ['fixture-model'] }; };
  const added = await changeSignIns(vault, { action: 'connectServer', url: 'http://localhost:32100', key: 'server-secret' }, { probe });
  assert.deepEqual(probes, [['http://localhost:32100', 'server-secret']]);
  const [server] = added.servers;
  assert.match(server.id, /^local-server-/);
  assert.ok(!JSON.stringify(added).includes('server-secret'));
  const stored = await vault.read();
  assert.equal(stored.owned[server.id].key, 'server-secret');
  const config = deviceConfig({ providers: ['openai', 'local-server-00000000-0000-4000-8000-000000000000'], customServers: [{ id: 'other' }] }, stored);
  assert.deepEqual(config.customServers, [{ id: server.id, url: server.url, models: ['fixture-model'] }]);
  assert.deepEqual(config.providers, ['openai', server.id]);
  await assert.rejects(changeSignIns(vault, { action: 'connectServer', url: 'http://other', key: 'k', server: { id: server.id } },
    { probe: async () => ({ url: 'http://other/v1', models: ['m'] }) }), /different server URL/);
  // A caller's server id reaches only a listed server: never another sign-in,
  // and nothing is probed for a server that is not listed or changed address.
  await vault.modify(async value => ({ ...value, owned: { ...value.owned, 'openai-codex': { type: 'oauth', access: 'a', refresh: 'device-refresh', expires: 1 } } }));
  for (const id of ['openai-codex', 'local-server-00000000-0000-4000-8000-000000000000', undefined]) {
    await assert.rejects(changeSignIns(vault, { action: 'removeServer', server: { id } }), /server connection/);
  }
  probes.length = 0;
  await assert.rejects(changeSignIns(vault, { action: 'connectServer', url: 'https://attacker.example', key: 'k', server: { id: 'openai-codex' } }, { probe }), /changed or was removed/);
  await assert.rejects(changeSignIns(vault, { action: 'connectServer', url: 'https://attacker.example', key: 'k', server: { id: server.id } }, { probe }), /different server URL/);
  assert.deepEqual(probes, []);
  assert.equal((await vault.read()).owned['openai-codex'].refresh, 'device-refresh');
  const removed = await changeSignIns(vault, { action: 'removeServer', server: { id: server.id } });
  assert.deepEqual(removed.servers, []);
  assert.equal((await vault.read()).owned[server.id], undefined);
});

test('a device service keeps only chat settings from another device and renews its own subscriptions', async t => {
  const directory = await temporary(t);
  const renewals = [];
  const engine = {
    config: { searchProvider: 'exa' },
    runtime: { getAuth: async provider => { renewals.push(provider);
      await vault.modify(async value => ({ ...value, owned: { ...value.owned, [provider]: { ...value.owned[provider], access: 'renewed', expires: Date.now() + 3600_000 } } })); } },
    credentials: { candidates: async provider => [{ id: 'default', credential: (await vault.read()).owned?.[provider] }], read: async () => undefined },
    apply: async () => {},
  };
  const vault = await new SignInStore(directory).open();
  const service = createDefaultAgentService({ cwd: directory, directory, engineFactory: async () => engine });
  await service.configure({ workspace: 'mac', revision: 'r1', config: {}, credentials: { openai: { type: 'api_key', key: 'relayed-secret' } },
    credentialAccounts: { openai: [{ id: 'a', label: 'a', credential: { type: 'api_key', key: 'relayed-secret' } }] } });
  const stored = await vault.read();
  assert.ok(!JSON.stringify(stored).includes('relayed-secret'));
  // Nothing is due yet.
  await vault.modify(async value => ({ ...value, owned: { xai: { type: 'oauth', access: 'current', refresh: 'r', expires: Date.now() + 3600_000 } } }));
  assert.deepEqual(await service.renewSignIns(), { renewed: [] });
  await vault.modify(async value => ({ ...value, owned: { xai: { type: 'oauth', access: 'old', refresh: 'r', expires: Date.now() + 60_000 } } }));
  assert.deepEqual(await service.renewSignIns(), { renewed: ['xai'] });
  assert.equal((await vault.read()).owned.xai.access, 'renewed');
  // Bots get a renewed subscription instead of being refused an expired one.
  await vault.modify(async value => ({ ...value, owned: { 'openai-codex': { type: 'oauth', access: 'expired', refresh: 'r', expires: Date.now() - 1 } } }));
  const reply = await service.botCredentials({ provider: 'openai-codex' });
  assert.equal(reply.credential.access, 'renewed');
  assert.ok(!JSON.stringify(reply).includes('"refresh"'));
  assert.deepEqual(renewals, ['xai', 'openai-codex']);
});

test('the control helper on a device signs out there and never returns credentials', async t => {
  const { spawn } = await import('node:child_process');
  const directory = await temporary(t);
  const vault = await new SignInStore(directory).open();
  await vault.modify(async value => ({ ...value, owned: { 'openai-codex': { type: 'oauth', access: 'a', refresh: 'device-refresh', expires: Date.now() + 3600_000 } } }));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/main.mjs', import.meta.url)), '--control'], {
    cwd: directory, env: { ...process.env, WOVEN_DEFAULT_AGENT_DIRECTORY: directory, WOVEN_DEFAULT_AGENT_DEVICE_VAULT: '1' }, stdio: ['pipe', 'pipe', 'ignore'] });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  // Credentials in the request are never stored here.
  child.stdin.write(JSON.stringify({ action: 'logout', provider: 'openai-codex', workspace: 'mac', config: {},
    credentials: { openai: { type: 'api_key', key: 'relayed-secret' } } }) + '\n');
  await new Promise(resolve => child.once('close', resolve));
  const result = JSON.parse(output.trim().split('\n').at(-1));
  assert.deepEqual(result, { result: { disconnected: true } });
  const stored = await vault.read();
  assert.equal(stored.owned['openai-codex'], undefined);
  assert.ok(!JSON.stringify(stored).includes('relayed-secret'));
});
