import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, chmod, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { ClaudeRuntime, claudeDirectories, claudeEnvironment } from '../src/claude-runtime.mjs';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { createSignInPrompt } from '../src/sign-in-interaction.mjs';
import { inlineClaudeLogin } from '../src/claude-runtime.mjs';
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

test('inline native login exposes only provider link and returns native account status', async () => {
  const child = new EventEmitter(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
  const notifications = [];
  const runtime = { environment: async (_key, profile) => ({ PROFILE: profile }), status: async profile => ({ connected: true, account: profile }) };
  const result = inlineClaudeLogin(runtime, 'fixture-profile', { notify: value => notifications.push(value), spawnCommand: (_path, args, options) => {
    assert.deepEqual(args, ['auth', 'login', '--claudeai']);
    assert.equal(options.env.PROFILE, 'fixture-profile');
    setImmediate(() => { child.stdout.write('Ignore secret output. https://claude.ai/oauth/authorize?state=fixture\n'); child.emit('close', 0); });
    return child;
  } });
  assert.deepEqual(await result, { connected: true, account: 'fixture-profile' });
  assert.equal(notifications[0].url, 'https://claude.ai/oauth/authorize?state=fixture');
  assert.ok(!JSON.stringify(notifications).includes('Ignore secret'));
});

test('cancelling inline native login terminates its child and does not report success', async () => {
  const controller = new AbortController();
  const child = new EventEmitter(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
  const signals = [];
  child.kill = signal => { signals.push(signal); setImmediate(() => child.emit('close', 0)); };
  const result = inlineClaudeLogin({ environment: async () => ({}), status: async () => { throw Error('must not check status'); } }, 'fixture', {
    signal: controller.signal, spawnCommand: () => { setImmediate(() => controller.abort()); return child; },
  });
  await assert.rejects(result, /Sign-in cancelled/);
  assert.deepEqual(signals, ['SIGTERM']);
});

for (const host of ['claude.com', 'claude.ai', 'platform.claude.com', 'console.anthropic.com']) {
  test(`inline Claude login forwards the authorization link on ${host}`, async () => {
    const child = new EventEmitter(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
    const notifications = [];
    const url = `https://${host}/cai/oauth/authorize?state=fixture&code_challenge=fixture`;
    const result = inlineClaudeLogin({ environment: async () => ({}), status: async () => ({ connected: true }) }, 'fixture', {
      notify: value => notifications.push(value),
      spawnCommand: () => {
        setImmediate(() => {
          child.stderr.write(`Opening browser: ${url}\n`);
          child.emit('close', 0);
        });
        return child;
      },
    });
    await result;
    assert.equal(notifications.length, 1);
    assert.equal(notifications[0].url, url);
  });
}

test('inline Claude login does not forward unrelated or lookalike domains', async () => {
  const child = new EventEmitter(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
  const notifications = [];
  await inlineClaudeLogin({ environment: async () => ({}), status: async () => ({ connected: true }) }, 'fixture', {
    notify: value => notifications.push(value),
    spawnCommand: () => {
      setImmediate(() => {
        child.stdout.write('https://claude.com.example.test/cai/oauth/authorize https://example.test/ https://claude.com/help\n');
        child.emit('close', 0);
      });
      return child;
    },
  });
  assert.deepEqual(notifications, []);
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

test('native completion and cancellation retire a pending sign-in prompt', async () => {
  for (const cancel of [false, true]) {
    const controller = new AbortController();
    const child = new EventEmitter();
    child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.stderr = new PassThrough();
    child.stdin.on('data', () => assert.fail('a retired prompt must not forward a code'));
    child.kill = () => setImmediate(() => child.emit('close', 0));
    const pending = new Map();
    let staleReply;
    const prompt = createSignInPrompt({ provider: 'claude-subscription', signal: controller.signal, pending,
      send: message => {
        staleReply = pending.get(message.id);
        if (cancel) controller.abort();
        else setImmediate(() => child.emit('close', 0));
      },
    });
    const result = inlineClaudeLogin({ environment: async () => ({}), status: async () => ({ connected: true }) }, 'fixture', {
      signal: controller.signal, prompt,
      spawnCommand: () => {
        setImmediate(() => child.stdout.write('https://claude.com/cai/oauth/authorize?state=fixture\n'));
        return child;
      },
    });
    if (cancel) await assert.rejects(result, /cancelled/);
    else assert.deepEqual(await result, { connected: true });
    assert.equal(pending.size, 0);
    staleReply('late-code#fixture');
    await new Promise(resolve => setImmediate(resolve));
  }
});

test('cancellation during native environment preparation never starts a login process', async () => {
  const controller = new AbortController();
  await assert.rejects(inlineClaudeLogin({ environment: async () => { controller.abort(); return {}; } }, 'fixture', {
    signal: controller.signal, spawnCommand: () => assert.fail('cancelled sign-in must not spawn'),
  }), /cancelled/);
});
