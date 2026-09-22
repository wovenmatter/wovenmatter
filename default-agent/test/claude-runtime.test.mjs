import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, chmod, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ClaudeRuntime, claudeDirectories, claudeEnvironment } from '../src/claude-runtime.mjs';
import { PermissionRequests } from '../src/permissions.mjs';

test('subscription runtime cannot inherit API keys, provider overrides, or another Claude login', () => {
  const paths = { config: '/fixture/config', storage: '/fixture/native-store' };
  const inherited = { PATH: '/bin', ANTHROPIC_API_KEY: 'billed-key', ANTHROPIC_AUTH_TOKEN: 'bearer',
    ANTHROPIC_BASE_URL: 'https://wrong.example', ANTHROPIC_PROFILE: 'other-account',
    CLAUDE_CODE_OAUTH_TOKEN: 'external-subscription', CLAUDE_CONFIG_DIR: '/other',
    CLAUDE_CODE_USE_BEDROCK: '1', CLAUDECODE: '1' };
  const subscription = claudeEnvironment(paths, undefined, inherited);
  assert.equal(subscription.PATH, '/bin');
  assert.equal(subscription.CLAUDE_CONFIG_DIR, paths.config);
  assert.equal(subscription.CLAUDE_SECURESTORAGE_CONFIG_DIR, paths.storage);
  for (const key of Object.keys(inherited).filter(k => k !== 'PATH' && k !== 'CLAUDE_CONFIG_DIR')) assert.equal(subscription[key], undefined, key);
  assert.equal(claudeEnvironment(paths, 'explicit-api-key', inherited).ANTHROPIC_API_KEY, 'explicit-api-key');
});

test('Mac native credential directory blocks disk fallback without making session storage read-only', async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-claude-storage-'));
  t.after(async () => { await chmod(join(root, 'claude-keychain'), 0o700); await rm(root, { recursive: true, force: true }); });
  const paths = await claudeDirectories(root, { platform: 'darwin' });
  assert.equal((await stat(paths.storage)).mode & 0o777, 0o500);
  assert.equal((await stat(paths.config)).mode & 0o777, 0o700);
  if (process.getuid() !== 0) await assert.rejects(writeFile(join(paths.storage, '.credentials.json'), 'fixture'), /EACCES|EPERM/);
  await writeFile(join(paths.config, 'fixture-session'), 'nonsecret');
  await claudeDirectories(root, { platform: 'darwin' });
  assert.equal((await stat(paths.storage)).mode & 0o777, 0o500);
});

test('remote native storage rejects disk-backed directories', async () => {
  await assert.rejects(claudeDirectories('/fixture', { platform: 'linux', memoryRoot: tmpdir() }), /memory-backed/);
});

test('native status exposes only account metadata and never treats a Console key as subscription sign-in', async () => {
  let value = { loggedIn: true, authMethod: 'claude.ai', apiProvider: 'firstParty', email: 'fixture@example.test', ignored: 'not-exported' };
  const runtime = new ClaudeRuntime('/fixture', {
    directories: async () => ({ config: '/fixture/config', storage: '/fixture/native-store' }),
    executeCommand: async (_path, args, options) => {
      assert.deepEqual(args, ['auth', 'status', '--json']);
      assert.equal(options.env.ANTHROPIC_API_KEY, undefined);
      return { stdout: JSON.stringify(value) };
    },
  });
  assert.equal((await runtime.status()).account, 'fixture@example.test');
  assert.ok(!JSON.stringify(await runtime.status()).includes('not-exported'));
  value = { loggedIn: true, authMethod: 'api_key', apiProvider: 'firstParty' };
  assert.equal((await runtime.status()).connected, false);
});

test('approval cancellation and stale replies cannot authorize another turn', async () => {
  const requests = new PermissionRequests();
  const controller = new AbortController();
  let oldID;
  const first = requests.request({ sessionId: 'a' }, controller.signal, id => { oldID = id; });
  controller.abort();
  assert.equal(await first, false);
  let newID;
  const second = requests.request({ sessionId: 'b' }, undefined, id => { newID = id; });
  requests.resolve(oldID, { outcome: { outcome: 'selected', optionId: 'allow' } });
  assert.ok(requests.pending.has(newID));
  requests.cancelSession('b');
  assert.equal(await second, false);
  assert.equal(requests.pending.size, 0);
});
