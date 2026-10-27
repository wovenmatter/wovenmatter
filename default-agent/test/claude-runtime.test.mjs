import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm, chmod, readFile, rename, stat, statfs, lstat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ClaudeRuntime, claudeDirectories, claudeEnvironment } from '../src/claude-runtime.mjs';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { createSignInPrompt } from '../src/sign-in-interaction.mjs';
import { inlineClaudeLogin } from '../src/claude-runtime.mjs';



test('Mac native storage rejects preexisting plaintext without reading or removing it', { skip: process.platform !== 'darwin' }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-claude-existing-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const storage = join(root, 'claude-keychain');
  await mkdir(storage, { mode: 0o700 });
  const file = join(storage, '.credentials.json');
  await writeFile(file, 'nonsecret fixture', { mode: 0o600 });
  await assert.rejects(claudeDirectories(root, { platform: 'darwin' }), /unexpected file/);
  assert.equal(await readFile(file, 'utf8'), 'nonsecret fixture');
});


test('Linux native credential directories use private isolated real tmpfs storage', { skip: process.platform !== 'linux' }, async t => {
  const root = await mkdtemp('/dev/shm/woven-claude-policy-');
  t.after(() => rm(root, { recursive: true, force: true }));
  assert.equal((await statfs(root)).type, 0x01021994, 'Linux CI must provide actual tmpfs');
  const profile = join(root, 'profile-a');
  const first = await claudeDirectories(profile, { platform: 'linux', memoryRoot: root });
  assert.equal(first.config, first.storage);
  assert.ok(first.config.startsWith(root + '/woven-claude-'));
  assert.equal((await lstat(first.config)).uid, process.getuid());
  assert.equal((await lstat(first.config)).mode & 0o777, 0o700);
  await chmod(first.config, 0o755);
  assert.deepEqual(await claudeDirectories(profile, { platform: 'linux', memoryRoot: root }), first);
  assert.equal((await lstat(first.config)).mode & 0o777, 0o700);
  const other = await claudeDirectories(join(root, 'profile-b'), { platform: 'linux', memoryRoot: root });
  assert.notEqual(other.config, first.config);
  assert.equal(other.config, other.storage);
  assert.ok(other.config.startsWith(root + '/woven-claude-'));
  assert.equal((await lstat(other.config)).uid, process.getuid());
  assert.equal((await lstat(other.config)).mode & 0o777, 0o700);
});

test('native profiles are isolated across concurrent asynchronous operations', async () => {
  const runtime = new ClaudeRuntime('/fixture', { directories: async path => ({ config: path, storage: path }) });
  const values = await Promise.all(['first', 'second'].map(profile => runtime.withProfile(profile, async () => {
    await new Promise(resolve => setTimeout(resolve, 1));
    return (await runtime.environment()).CLAUDE_CONFIG_DIR;
  })));
  assert.deepEqual(values, ['/fixture/claude-accounts/first', '/fixture/claude-accounts/second']);
  assert.equal((await runtime.environment()).CLAUDE_CONFIG_DIR, '/fixture');
  await assert.rejects(runtime.environment(undefined, '../unsafe'), /Invalid Claude account/);
});


test('Claude sign-in joins streamed links and forwards the UI code only to native stdin', { timeout: 2000 }, async () => {
  const child = new EventEmitter();
  child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
  const controller = new AbortController();
  const pending = new Map(), messages = [], notifications = [], input = [];
  const url = 'https://claude.com/cai/oauth/authorize?state=fixture&code_challenge=fixture';
  const prompt = createSignInPrompt({ provider: 'claude-subscription', signal: controller.signal, pending,
    send: message => {
      messages.push(message);
      queueMicrotask(() => pending.get(message.id)(messages.length === 1 ? 'incomplete' : 'fixture-code#fixture-state'));
    },
  });
  child.stdin.on('data', data => { input.push(data.toString()); setImmediate(() => child.emit('close', 0)); });
  await inlineClaudeLogin({ environment: async () => ({}), status: async () => ({ connected: true }) }, 'fixture', {
    signal: controller.signal, prompt, notify: value => notifications.push(value),
    spawnCommand: (_path, _args, options) => {
      assert.equal(options.stdio[0], 'pipe');
      setImmediate(() => {
        child.stdout.write('If the browser did not open: ' + url.slice(0, 55));
        assert.equal(notifications.length, 0, 'a partial URL must not reach the UI');
        child.stderr.write('Native progress on a separate stream\n');
        child.stdout.write(url.slice(55) + '\n');
        child.stdout.write(`\x1b]8;;${url}\x07${url}\x1b]8;;\x07\nPaste code here if prompted > `);
      });
      return child;
    },
  });
  assert.deepEqual(input, ['fixture-code#fixture-state\n']);
  assert.deepEqual(notifications.map(value => value.url), [url]);
  assert.equal(messages.length, 2);
  assert.match(messages[1].prompt.message, /full code/);
  assert.equal(pending.size, 0);
  assert.ok(!JSON.stringify(messages).includes('fixture-code'));
});
