import test from 'node:test';
import assert from 'node:assert/strict';
import { chmod, mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CredentialVault, vaultFiles } from '../src/vault.mjs';
import { changeSignIns, deviceConfig, listSignIns } from '../src/device-sign-ins.mjs';
import { createDefaultAgentService } from '../src/service.mjs';

const files = async directory => (await readdir(directory)).filter(name => name.startsWith('credentials.')).sort();

async function temporary(t) {
  const directory = await mkdtemp('/tmp/woven-device-sign-ins-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  return directory;
}

test('a device vault opens with its own key and sets a vault sealed with a Mac key aside for that Mac', async t => {
  const directory = await temporary(t);
  const sealed = new CredentialVault(directory), macKey = randomBytes(32).toString('base64');
  await sealed.unlock('mac-workspace', macKey);
  await sealed.modify(async value => ({ ...value,
    owned: { xai: { type: 'oauth', access: 'host-access', refresh: 'host-refresh', expires: 1 } },
    shared: { openai: { type: 'api_key', key: 'saved-secret' }, 'openai-codex': { type: 'oauth', access: 'mac-access', refresh: '', borrowed: true, expires: 1 } } }));
  await writeFile(join(directory, 'configuration.json'), JSON.stringify({ config: { providers: [] } }));
  const vault = await new CredentialVault(directory).openDevice();
  assert.deepEqual(await vault.read(), {});
  assert.equal((await stat(join(directory, 'credentials.key'))).mode & 0o777, 0o600);
  // Kept, unread, until the Mac that holds its key brings its sign-ins over.
  assert.equal(await vault.legacyPending(), true);
  assert.deepEqual(await vault.importLegacy('mac-workspace', macKey), { imported: true });
  assert.equal(await vault.legacyPending(), false);
  const stored = await vault.read();
  // The host's own subscription and saved keys join it, and a Mac's borrowed
  // subscription access does not come over.
  assert.equal(stored.owned.xai.refresh, 'host-refresh');
  assert.equal(stored.owned['openai-codex'], undefined);
  assert.deepEqual(stored.accounts.openai.map(entry => entry.credential.key), ['saved-secret']);
  // Another process of the same host reads the same sign-ins with the same key.
  const other = await new CredentialVault(directory).openDevice();
  assert.equal((await other.read()).owned.xai.refresh, 'host-refresh');
  assert.ok(!(await readFile(vault.path, 'utf8')).includes('host-refresh'));
});

test('a vault sealed with a Mac key stops waiting once this device signs in or a Mac key fails to open it, and stays on disk', async t => {
  for (const ending of ['own sign-in', 'wrong key']) {
    const directory = await temporary(t);
    const sealed = new CredentialVault(directory), macKey = randomBytes(32).toString('base64');
    await sealed.unlock('mac-workspace', macKey);
    await sealed.modify(async value => ({ ...value, owned: { xai: { type: 'oauth', access: 'a', refresh: 'old-refresh', expires: 1 } } }));
    const vault = await new CredentialVault(directory).openDevice();
    assert.equal(await vault.legacyPending(), true);
    if (ending === 'own sign-in') await changeSignIns(vault, { action: 'saveKey', provider: 'openai', key: 'own-key' });
    else assert.deepEqual(await vault.importLegacy('mac-workspace', randomBytes(32).toString('base64')), { imported: false });
    assert.equal(await vault.legacyPending(), false, ending);
    const kept = (await files(directory)).filter(name => name.startsWith('credentials.legacy-'));
    assert.equal(kept.length, 1, ending);
    assert.equal(JSON.parse(await readFile(join(directory, kept[0]), 'utf8')).workspace, 'mac-workspace');
  }
});

test('a reset clears this device\'s sign-ins and keeps the vault as it was beside it', async t => {
  const directory = await temporary(t);
  const vault = await new CredentialVault(directory).openDevice();
  await vault.modify(async value => ({ ...value, owned: { xai: { type: 'oauth', access: 'a', refresh: 'before-reset', expires: 1 } } }));
  const before = await readFile(vault.path, 'utf8');
  await vault.reset();
  assert.deepEqual(await vault.read(), {});
  const kept = (await files(directory)).find(name => /^credentials\.reset-.*\.enc\.json$/.test(name));
  assert.ok(kept, (await files(directory)).join());
  assert.equal(await readFile(join(directory, kept), 'utf8'), before);
});

test('without hard links the key is still created whole and unreadable vaults are still kept', async t => {
  const original = vaultFiles.link;
  t.after(() => { vaultFiles.link = original; });
  vaultFiles.link = async () => { throw Object.assign(new Error('operation not permitted'), { code: 'EPERM' }); };
  const directory = await temporary(t);
  const vault = await new CredentialVault(directory).openDevice();
  await vault.modify(async value => ({ ...value, owned: { xai: { type: 'oauth', access: 'a', refresh: 'no-links', expires: 1 } } }));
  assert.match(await readFile(vault.keyPath, 'utf8'), /^[A-Za-z0-9+/]{43}=$/);
  assert.equal((await stat(vault.keyPath)).mode & 0o777, 0o600);
  assert.equal((await new CredentialVault(directory).openDevice().then(other => other.read())).owned.xai.refresh, 'no-links');
  // Concurrent openers of a new vault agree on one key.
  const fresh = await temporary(t);
  const opened = await Promise.all(Array.from({ length: 4 }, () => new CredentialVault(fresh).openDevice()));
  await opened[0].modify(async () => ({ owned: { xai: { type: 'oauth', access: 'a', refresh: 'shared', expires: 1 } } }));
  for (const other of opened) assert.equal((await other.read()).owned.xai.refresh, 'shared');
  // A damaged key is replaced on the next sign-in, with copies of both kept.
  const vaultBefore = await readFile(vault.path, 'utf8');
  await writeFile(vault.keyPath, 'damaged', { mode: 0o600 });
  await changeSignIns(await new CredentialVault(directory).openDevice(), { action: 'saveKey', provider: 'openai', key: 'k' });
  const names = await files(directory);
  const keptVault = names.find(name => /^credentials\.unreadable-.*\.enc\.json$/.test(name));
  assert.equal(await readFile(join(directory, keptVault), 'utf8'), vaultBefore);
  assert.equal(await readFile(join(directory, names.find(name => /^credentials\.unreadable-.*\.key$/.test(name))), 'utf8'), 'damaged');
  // A reset keeps its copy too.
  await (await new CredentialVault(directory).openDevice()).reset();
  assert.ok((await files(directory)).some(name => /^credentials\.reset-/.test(name)));
});

test('plain sign-in files from before the vault join it and are removed only once it holds them', async t => {
  const directory = await temporary(t);
  await writeFile(join(directory, 'oauth.json'), JSON.stringify({ xai: { type: 'oauth', access: 'a', refresh: 'plain-refresh', expires: 1 } }));
  await writeFile(join(directory, 'configuration.json'), JSON.stringify({ config: { providers: [] }, credentials: { openai: { type: 'api_key', key: 'plain-key' } } }));
  const vault = await new CredentialVault(directory).openDevice();
  const stored = await vault.read();
  assert.equal(stored.owned.xai.refresh, 'plain-refresh');
  assert.equal(stored.accounts.openai[0].credential.key, 'plain-key');
  await assert.rejects(stat(join(directory, 'oauth.json')));
  assert.ok(!(await readFile(join(directory, 'configuration.json'), 'utf8')).includes('credentials'));
});

for (const damage of ['mismatched key', 'missing key', 'truncated key', 'corrupt vault']) {
  test(`a device vault with a ${damage} reads as signed out, is never deleted, and a new sign-in replaces it`, async t => {
    const directory = await temporary(t);
    const vault = await new CredentialVault(directory).openDevice();
    await vault.modify(async value => ({ ...value, accounts: { openai: [{ id: 'a', label: 'Key', credential: { type: 'api_key', key: 'original-secret' } }] } }));
    const original = await readFile(vault.path, 'utf8'), originalKey = await readFile(vault.keyPath, 'utf8');
    if (damage === 'mismatched key') await writeFile(vault.keyPath, randomBytes(32).toString('base64'), { mode: 0o600 });
    if (damage === 'missing key') await rm(vault.keyPath);
    if (damage === 'truncated key') await writeFile(vault.keyPath, originalKey.slice(0, 20), { mode: 0o600 });
    if (damage === 'corrupt vault') await writeFile(vault.path, original.slice(0, 40));
    const reopened = await new CredentialVault(directory).openDevice();
    assert.deepEqual(await reopened.read(), {});
    assert.deepEqual(listSignIns(await reopened.read()).accounts.openai, []);
    // Opening it changed nothing on disk: no vault removed, no key written over it.
    assert.equal(await readFile(vault.path, 'utf8'), damage === 'corrupt vault' ? original.slice(0, 40) : original);
    if (damage === 'missing key') await assert.rejects(stat(vault.keyPath));
    // Status, bots and listings work: a service on it is signed out, not failing.
    const service = createDefaultAgentService({ cwd: directory, directory, deviceVault: true, engineFactory: async () => ({
      credentials: { candidates: async provider => (await reopened.read()).accounts?.[provider] ?? [], read: async () => undefined }, status: async () => ({ providers: [], models: [] }) }) });
    assert.equal((await service.status()).locked, false);
    assert.deepEqual(await service.botCredentials({ provider: 'openai' }), { credential: null });
    // A key saved now replaces it; the unreadable vault and key are kept beside it.
    await changeSignIns(reopened, { action: 'saveKey', provider: 'anthropic', key: 'new-secret' });
    const replaced = await new CredentialVault(directory).openDevice();
    assert.deepEqual(Object.keys((await replaced.read()).accounts), ['anthropic']);
    const names = await files(directory);
    assert.ok(names.some(name => /^credentials\.unreadable-.*\.enc\.json$/.test(name)), names.join());
    if (damage !== 'missing key') assert.ok(names.some(name => /^credentials\.unreadable-.*\.key$/.test(name)), names.join());
    if (damage === 'mismatched key' || damage === 'truncated key') {
      const kept = names.find(name => /^credentials\.unreadable-.*\.enc\.json$/.test(name));
      assert.equal(await readFile(join(directory, kept), 'utf8'), original);
    }
    assert.equal((await stat(vault.keyPath)).mode & 0o777, 0o600);
  });
}

test('the device key is created whole, kept 0600 and never read through a link or from another owner', async t => {
  const directory = await temporary(t);
  const vault = await new CredentialVault(directory).openDevice();
  await vault.modify(async value => ({ ...value, owned: { xai: { type: 'oauth', access: 'a', refresh: 'r', expires: 1 } } }));
  const key = await readFile(vault.keyPath, 'utf8');
  assert.match(key, /^[A-Za-z0-9+/]{43}=$/);
  assert.deepEqual((await files(directory)), ['credentials.enc.json', 'credentials.key']);
  // A widened mode is narrowed again on the next open.
  await chmod(vault.keyPath, 0o644);
  await new CredentialVault(directory).openDevice();
  assert.equal((await stat(vault.keyPath)).mode & 0o777, 0o600);
  // Several processes opening a new vault at once agree on one key.
  const fresh = await temporary(t);
  const opened = await Promise.all(Array.from({ length: 6 }, () => new CredentialVault(fresh).openDevice()));
  await opened[0].modify(async () => ({ owned: { xai: { type: 'oauth', access: 'a', refresh: 'shared-r', expires: 1 } } }));
  for (const other of opened) assert.equal((await other.read()).owned.xai.refresh, 'shared-r');
  // A key file that is a link is refused, and nothing is written through it.
  const linked = await temporary(t), target = join(linked, 'elsewhere');
  await writeFile(target, key, { mode: 0o600 });
  await symlink(target, join(linked, 'credentials.key'));
  await assert.rejects(new CredentialVault(linked).openDevice(), /link/);
  assert.equal(await readFile(target, 'utf8'), key);
});

test('API keys are added, ordered and removed on the device and never listed', async t => {
  const vault = await new CredentialVault(await temporary(t)).openDevice();
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
  const vault = await new CredentialVault(await temporary(t)).openDevice();
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
  const vault = await new CredentialVault(await temporary(t)).openDevice();
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

test('a device service ignores relayed credentials, needs no unlock and renews its own subscriptions', async t => {
  const directory = await temporary(t);
  const renewals = [];
  const engine = {
    config: { searchProvider: 'exa' },
    runtime: { getAuth: async provider => { renewals.push(provider);
      await vault.modify(async value => ({ ...value, owned: { ...value.owned, [provider]: { ...value.owned[provider], access: 'renewed', expires: Date.now() + 3600_000 } } })); } },
    credentials: { candidates: async provider => [{ id: 'default', credential: (await vault.read()).owned?.[provider] }], read: async () => undefined },
    apply: async () => {},
  };
  const vault = await new CredentialVault(directory).openDevice();
  const service = createDefaultAgentService({ cwd: directory, directory, deviceVault: true, engineFactory: async () => engine });
  assert.deepEqual(await service.unlockForClient({ workspace: 'mac', unlockKey: randomBytes(32).toString('base64') }), { unlocked: true, deviceVault: true, legacyVault: false });
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
  const vault = await new CredentialVault(directory).openDevice();
  await vault.modify(async value => ({ ...value, owned: { 'openai-codex': { type: 'oauth', access: 'a', refresh: 'device-refresh', expires: Date.now() + 3600_000 } } }));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/main.mjs', import.meta.url)), '--control'], {
    cwd: directory, env: { ...process.env, WOVEN_DEFAULT_AGENT_DIRECTORY: directory, WOVEN_DEFAULT_AGENT_DEVICE_VAULT: '1' }, stdio: ['pipe', 'pipe', 'ignore'] });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  // A Mac's relayed credentials and key in the request are ignored.
  child.stdin.write(JSON.stringify({ action: 'logout', provider: 'openai-codex', workspace: 'mac', unlockKey: randomBytes(32).toString('base64'), config: {},
    credentials: { openai: { type: 'api_key', key: 'relayed-secret' } } }) + '\n');
  await new Promise(resolve => child.once('close', resolve));
  const result = JSON.parse(output.trim().split('\n').at(-1));
  assert.deepEqual(result, { result: { disconnected: true } });
  const stored = await vault.read();
  assert.equal(stored.owned['openai-codex'], undefined);
  assert.ok(!JSON.stringify(stored).includes('relayed-secret'));
});

test('a control session reset on a device keeps the vault as it was beside it', async t => {
  const { spawn } = await import('node:child_process');
  const directory = await temporary(t);
  const vault = await new CredentialVault(directory).openDevice();
  await vault.modify(async value => ({ ...value, owned: { 'openai-codex': { type: 'oauth', access: 'a', refresh: 'kept-refresh', expires: Date.now() + 3600_000 } } }));
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/main.mjs', import.meta.url)), '--control'], {
    cwd: directory, env: { ...process.env, WOVEN_DEFAULT_AGENT_DIRECTORY: directory, WOVEN_DEFAULT_AGENT_DEVICE_VAULT: '1' }, stdio: ['pipe', 'pipe', 'ignore'] });
  let output = '';
  child.stdout.on('data', chunk => { output += chunk; });
  child.stdin.write(JSON.stringify({ action: 'reset', workspace: 'device', config: {} }) + '\n');
  await new Promise(resolve => child.once('close', resolve));
  assert.deepEqual(JSON.parse(output.trim().split('\n').at(-1)), { result: { reset: true } });
  assert.deepEqual(await vault.read(), {});
  const kept = (await files(directory)).find(name => /^credentials\.reset-.*\.enc\.json$/.test(name));
  assert.ok(kept);
  const copy = new CredentialVault(directory);
  copy.device = true; copy.workspace = 'device'; copy.path = join(directory, kept);
  assert.equal((await copy.read()).owned['openai-codex'].refresh, 'kept-refresh');
});
