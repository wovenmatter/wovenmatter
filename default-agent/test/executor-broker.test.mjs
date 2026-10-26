import { EventEmitter } from 'node:events';
import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { ExecutorBroker, validateConfiguration, supportsExecutorVersion, latestExecutorVersion, tailnetSSHOptions } from '../src/executor/broker.mjs';
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
async function fixture(t, run) {
  const directory = await mkdtemp(join(tmpdir(), 'woven-executor-manager-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const calls = [], scopes = new Map();
  const broker = await new ExecutorBroker(directory, { fetcher: async (url, input) => {
    calls.push([url, input]);
    const id = url.split('/').at(-1);
    if (input.method === 'PUT') scopes.set(id, JSON.parse(input.body));
    return new Response('{}', { status: 200, headers: { 'content-type': 'application/json' } });
  }, connect: async () => ({ callTool: run, close: async () => {} }) }).load();
  broker.config = { id: randomUUID(), location: 'local' }; broker.server = { apiKey: 'manager-secret' }; broker.origin = 'http://127.0.0.1:4312';
  const scope = await broker.scope('conversation-a', [{ app: 'app-a', account: 'account-a' }], true);
  scope.grant = { token: 'scoped-secret', expires: Date.now() + 3600000 };
  return { broker, scope, calls, scopes, directory };
}

test('Executor updates follow every V2 release but never select another API major', async () => {
  const metadata = version => version.endsWith('-win32-x64')
    ? { version, os: ['win32'], cpu: ['x64'] } : { version, bin: { executor: 'bin.mjs' } };
  const registry = (latest, versions) => async url => new Response(JSON.stringify(url.endsWith('/latest')
    ? metadata(latest) : { versions: Object.fromEntries(versions.map(version => [version, metadata(version)])) }));
  assert.equal(await latestExecutorVersion(registry('1.6.10', ['1.6.10', '2.0.0-beta.17', '2.0.0-beta.19', '2.0.0-beta.99-win32-x64'])), '2.0.0-beta.19');
  assert.equal(await latestExecutorVersion(registry('2.1.0-beta.1', ['2.0.0', '2.1.0-beta.1'])), '2.0.0');
  assert.equal(await latestExecutorVersion(registry('1.6.10', ['2.0.0-beta-hotfix.1', '2.0.0-beta-hotfix.2'])), '2.0.0-beta-hotfix.2');
  await assert.rejects(latestExecutorVersion(registry('3.0.0', ['3.0.0'])), /compatible/);
  for (const version of ['2.0.0-beta.19', '2.0.0', '2.1.0', '2.99.3']) {
    assert.equal(supportsExecutorVersion(version), true);
    assert.equal(await latestExecutorVersion(registry(version, [version])), version);
  }
  // A new upstream major leaves installs on the newest V2 release.
  assert.equal(await latestExecutorVersion(registry('3.0.0', ['2.4.1', '3.0.0'])), '2.4.1');
  for (const version of ['1.6.10', '3.0.0', 'invalid']) assert.equal(supportsExecutorVersion(version), false);
});
test('Execute waits for trusted approval, deduplicates IDs and binds jobs to their conversation', async t => {
  let executions = 0;
  const { broker, scope, directory } = await fixture(t, async () => { executions++; return { structuredContent: { status: 'completed', execution: { ok: true, value: 1 } } }; });
  const request = { id: randomUUID(), session: 'conversation-a', code: 'return 1;', scope };
  assert.equal((await broker.start(request)).status, 'awaiting-approval');
  assert.equal(executions, 0);
  assert.equal((await broker.start(request)).status, 'awaiting-approval');
  await assert.rejects(broker.start({ ...request, code: 'return 2;' }), /different program/);
  assert.throws(() => broker.owned(request.id, 'conversation-b'), /unavailable/);
  await broker.advance(broker.owned(request.id, request.session), { action: 'accept', content: {} });
  while (broker.jobs.get(request.id).status === 'running') await wait(10);
  assert.equal(executions, 1);
  assert.equal((await broker.start(request)).status, 'completed');
  assert.equal(executions, 1);
  assert.ok(!JSON.stringify(broker.publicJob(broker.jobs.get(request.id))).includes('secret'));
  assert.equal((await stat(join(directory, 'manager.json'))).mode & 0o777, 0o600);
});

test('cancellation and uncertain transport never replay a program, including after manager restart', async t => {
  let executions = 0;
  const { broker, scope, directory } = await fixture(t, async () => { executions++; throw new Error('uncertain transport'); });
  const request = { id: randomUUID(), session: 'conversation-a', scope, code: 'return tools.mutate({});' };
  await broker.start(request); await broker.advance(broker.jobs.get(request.id), { action: 'accept' });
  while (broker.jobs.get(request.id).status === 'running') await wait(10);
  assert.equal(broker.jobs.get(request.id).status, 'interrupted');
  const restored = await new ExecutorBroker(directory).load(); restored.config = broker.config;
  assert.equal((await restored.start(request)).status, 'interrupted');
  assert.equal(executions, 1);
  const next = { ...request, id: randomUUID() };
  await broker.start(next); await broker.cancel(broker.jobs.get(next.id));
  assert.equal((await broker.start(next)).status, 'cancelled');
  assert.equal(executions, 1);
});
test('cloud/public/insecure origins and shell injection are rejected', () => {
  const config = { id: randomUUID(), location: 'remote', origin: 'https://machine.tailnet.ts.net:8443', host: 'machine.tailnet.ts.net', user: 'trey' };
  assert.equal(validateConfiguration(config), config);
  for (const origin of ['http://machine.tailnet.ts.net', 'https://executor.sh', 'https://user:secret@machine.tailnet.ts.net', 'https://machine.tailnet.ts.net/mcp']) assert.throws(() => validateConfiguration({ ...config, origin }));
  assert.throws(() => validateConfiguration({ ...config, host: 'host; printf secret' }));
});

test('remote Executor SSH is pinned to one online Tailscale peer', () => {
  const status = { BackendState: 'Running', Peer: {
    first: { HostName: 'workstation', DNSName: 'workstation.example.ts.net.', Online: true, Expired: false, TailscaleIPs: ['fd7a:115c:a1e0::2'] },
  } };
  const options = tailnetSSHOptions('workstation.example.ts.net', '/Applications/Tailscale.app/Contents/MacOS/Tailscale', status);
  assert.ok(options.includes("ProxyCommand=exec '/Applications/Tailscale.app/Contents/MacOS/Tailscale' nc fd7a:115c:a1e0::2 %p"));
  assert.ok(options.includes('ProxyJump=none'));
  assert.ok(options.includes('Hostname=fd7a:115c:a1e0::2'));
  assert.ok(options.includes('ControlMaster=no'));
  assert.throws(() => tailnetSSHOptions('lan.invalid', '/usr/bin/tailscale', status), /online Tailscale machine/);
  assert.throws(() => tailnetSSHOptions('workstation', '/usr/bin/tailscale', { ...status, BackendState: 'Stopped' }), /Connect Tailscale/);
  assert.throws(() => tailnetSSHOptions('workstation', '/usr/bin/tailscale', { ...status, Peer: { ...status.Peer, duplicate: status.Peer.first } }), /online Tailscale machine/);
});

test('remote Executor deployment passes only the resolved Tailscale transport to ssh', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'woven-executor-deploy-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const version = '2.0.0-beta.29'; let resolvedHost, invocation;
  const broker = await new ExecutorBroker(directory, {
    fetcher: async () => new Response(JSON.stringify({ versions: { [version]: { version, bin: { executor: 'bin.mjs' } } } })),
    tailnetOptions: async host => { resolvedHost = host; return ['-o', 'ProxyCommand=exec tailscale nc fd7a:115c:a1e0::2 %p', '-o', 'Hostname=fd7a:115c:a1e0::2']; },
  }).load();
  broker.config = { id: randomUUID(), location: 'remote', origin: 'https://workstation.example.ts.net:8443', host: 'workstation', user: 'trey' };
  broker.server = { apiKey: 'a'.repeat(64), encryptionKey: 'b'.repeat(64), port: 4312 };
  broker.run = async (...args) => { invocation = args; };
  await broker.deployRemote();
  assert.equal(resolvedHost, 'workstation');
  assert.equal(invocation[0], '/usr/bin/ssh');
  assert.ok(invocation[1].includes('ProxyCommand=exec tailscale nc fd7a:115c:a1e0::2 %p'));
  assert.ok(invocation[1].includes('Hostname=fd7a:115c:a1e0::2'));
  assert.equal(invocation[1].at(-2), 'trey@workstation');
});

test('invalid typed input remains pending and a valid response resumes once', async t => {
  let resumes = 0;
  const { broker, scope } = await fixture(t, async request => {
    if (request.name === 'resume') { resumes++; return { structuredContent: { status: 'completed', execution: { ok: true } } }; }
    return { structuredContent: { status: 'input-required', requestId: 'input-private', elicitation: {
      requestedSchema: { type: 'object', properties: { count: { type: 'integer', minimum: 1 } }, required: ['count'] }
    } } };
  });
  const id = randomUUID(); await broker.start({ id, session: 'conversation-a', scope, code: 'return tools.ask({});' });
  const job = broker.owned(id, 'conversation-a');
  await broker.advance(job, { action: 'accept' });
  while (job.status === 'running') await wait(10);
  assert.equal(job.status, 'input-required');
  assert.ok(!JSON.stringify(broker.publicJob(job)).includes('input-private'));
  await assert.rejects(broker.advance(job, { action: 'accept', content: { count: 'three' } }), /requested form/);
  assert.equal(job.status, 'input-required'); assert.equal(resumes, 0);
  await broker.advance(job, { action: 'accept', content: { count: 3 } });
  while (job.status === 'running') await wait(10);
  assert.equal(job.status, 'completed'); assert.equal(resumes, 1);
});
for (const dialect of ['implicit draft-07', 'explicit draft-07', 'explicit 2020-12']) test(`Executor preserves ${dialect} tuple forms and resumes only a valid answer`, async t => {
  const modern = dialect === 'explicit 2020-12';
  const tuple = [{ type: 'integer' }, { type: 'string' }];
  const requestedSchema = { type: 'object', required: ['pair'], properties: {
    pair: { type: 'array', minItems: 2, ...(modern ? { prefixItems: tuple, items: false } : { items: tuple, additionalItems: false }) }
  }, ...(dialect === 'implicit draft-07' ? {} : {
    $schema: modern ? 'https://json-schema.org/draft/2020-12/schema' : 'http://json-schema.org/draft-07/schema#'
  }) };
  let resumes = 0;
  const { broker, scope } = await fixture(t, async request => {
    if (request.name === 'resume') { resumes++; return { structuredContent: { status: 'completed' } }; }
    return { structuredContent: { status: 'input-required', requestId: 'tuple-form', elicitation: { requestedSchema } } };
  });
  const id = randomUUID();
  await broker.start({ id, session: 'conversation-a', scope, code: 'return tools.ask({});' });
  const job = broker.owned(id, 'conversation-a');
  await broker.advance(job, { action: 'accept' });
  while (job.busy) await wait(10);
  assert.equal(job.status, 'input-required');
  for (const pair of [['wrong type', 'label'], [3], [3, 'label', 'extra']]) {
    await assert.rejects(broker.advance(job, { action: 'accept', content: { pair } }), /requested form/);
    assert.equal(job.status, 'input-required');
    assert.equal(resumes, 0);
  }
  await broker.advance(job, { action: 'accept', content: { pair: [3, 'label'] } });
  while (job.busy) await wait(10);
  assert.equal(job.status, 'completed');
  assert.equal(resumes, 1);
});

test('corrupt manager keys fail before runtime startup without replacing storage', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'woven-executor-corrupt-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const path = join(directory, 'manager.json');
  await writeFile(path, JSON.stringify({ servers: { broken: { location: 'local', apiKey: 'old', encryptionKey: 'old', port: 4312 } }, scopes: {}, jobs: {} }));
  await assert.rejects(new ExecutorBroker(directory).load(), /Existing credentials were retained/);
});

test('Stop while a client is connecting prevents dispatch even if transport ignores abort', async t => {
  let release, executions = 0;
  const { broker, scope } = await fixture(t, async () => { executions++; return {}; });
  broker.connectOverride = async () => { await new Promise(resolve => { release = resolve; }); return { callTool: async () => { executions++; return {}; } }; };
  const id = randomUUID(); await broker.start({ id, session: 'conversation-a', scope, code: 'return tools.mutate({});' });
  const job = broker.owned(id, 'conversation-a');
  await broker.advance(job, { action: 'accept' });
  while (!release) await wait(10);
  await broker.cancel(job); release();
  while (job.busy) await wait(10);
  assert.equal(executions, 0); assert.equal(job.status, 'cancelled');
});

test('an in-flight grant stays bound to its original origin and is discarded after replacement', async t => {
  const { broker, scope } = await fixture(t, async () => ({}));
  delete scope.grant;
  const oldOrigin = broker.origin, oldKey = broker.server.apiKey, visited = [];
  let release, registered, state;
  const started = new Promise(resolve => { registered = resolve; });
  broker.fetch = async (url, options) => {
    visited.push(url);
    assert.equal(new URL(url).origin, oldOrigin);
    const path = new URL(url).pathname;
    const reply = (body, headers = {}) => new Response(JSON.stringify(body), { headers: { 'content-type': 'application/json', ...headers } });
    if (path.endsWith('/register')) {
      registered(); await new Promise(resolve => { release = resolve; });
      return reply({client_id:'fixture'});
    }
    if (path === '/auth/pair') {
      assert.equal(options.headers.authorization, `Bearer ${oldKey}`);
      return reply({url: oldOrigin + '/#pair=fixture'});
    }
    if (path === '/auth/exchange') return reply({}, {'set-cookie':'operator=fixture; HttpOnly'});
    if (path.endsWith('/authorize')) {
      state = new URL(url).searchParams.get('state');
      return reply({url:oldOrigin + '/consent?fixture=yes'});
    }
    if (path.endsWith('/consent')) return reply({url:`http://127.0.0.1:9/woven-executor-callback?code=fixture&state=${state}`});
    if (path.endsWith('/token')) return reply({access_token:'scoped', refresh_token:'refresh', expires_in:3600});
    throw new Error('Unexpected fixture request');
  };
  const pending = broker.client(scope);
  await started;
  await broker.shutdownClients();
  broker.origin = 'https://replacement.tailnet.ts.net:8443'; broker.server = {apiKey:'replacement'};
  release();
  await assert.rejects(pending, /connection changed/);
  assert.equal(visited.length, 6);
  assert.equal(scope.grant, undefined); assert.equal(broker.clients.size, 0);
});

test('local updates stage before retirement and roll back failed startup', async t => {
  for (const outcome of ['registry', 'npm', 'startup', 'success']) {
    const { broker, directory } = await fixture(t, async () => ({}));
    const root = join(directory, 'runtime');
    await mkdir(join(root, 'node_modules/executor'), { recursive: true });
    await writeFile(join(root, 'node_modules/executor/package.json'), JSON.stringify({ version: '2.0.0-beta.7' }));
    const actions = [];
    const child = running => Object.assign(new EventEmitter(), { exitCode: running ? null : 1, signalCode: null,
      kill() { actions.push('retire'); this.signalCode = 'SIGTERM'; queueMicrotask(() => this.emit('exit', null)); } });
    const original = child(true); broker.child = original; broker.runtimeVersion = '2.0.0-beta.7';
    broker.fetch = async url => {
      if (outcome === 'registry') throw Error('offline');
      return new Response(JSON.stringify(url.endsWith('/latest') ? { version: '1.6.10' } : { versions: { '2.0.0-beta.12': { bin: { executor: 'bin.mjs' } } } }));
    };
    broker.run = async (_, args) => {
      actions.push('stage'); if (outcome === 'npm') throw Error('download failed');
      const stage = args[args.indexOf('--prefix') + 1];
      await mkdir(join(stage, 'node_modules/executor'), { recursive: true });
      await writeFile(join(stage, 'node_modules/executor/package.json'), JSON.stringify({ version: '2.0.0-beta.12' }));
    };
    broker.spawnProcess = (_, args) => { actions.push(args[0].includes('/generations/') ? 'new' : 'old'); return child(outcome !== 'startup' || !args[0].includes('/generations/')); };
    broker.request = async () => { if (outcome === 'startup' && broker.runtimeVersion === '2.0.0-beta.12') throw Error('not ready'); return { body: {} }; };
    if (outcome === 'success') {
      await broker.startLocal(true);
      assert.equal(broker.runtimeVersion, '2.0.0-beta.12'); assert.ok(broker.server.runtimeGeneration);
    } else {
      await assert.rejects(broker.startLocal(true));
      assert.equal(broker.runtimeVersion, '2.0.0-beta.7'); assert.equal(broker.server.runtimeGeneration, undefined);
      if (outcome !== 'startup') assert.equal(broker.child, original);
      else assert.ok(actions.includes('old'));
    }
    if (actions.includes('retire')) assert.ok(actions.indexOf('stage') < actions.indexOf('retire'));
    await broker.stop();
  }
});

test('revoking one conversation empties its live scope and cancels active and queued jobs without touching another', async t => {
  let release, entered;
  const held = new Promise(resolve => { release = resolve; });
  const started = new Promise(resolve => { entered = resolve; });
  const executions = [];
  const f = await fixture(t, async request => {
    executions.push(request.arguments.code);
    if (request.arguments.code === 'active-a') { entered(); await held; }
    return { structuredContent: { status: 'completed', execution: { ok: true } } };
  });
  const { broker, scope } = f;
  const other = await broker.scope('conversation-b', [
    { app: 'app-b', account: 'account-b' }, { app: 'app-b', account: 'account-b2' },
    { app: 'app-b', account: 'account-b' },
  ], true);
  other.grant = { token: 'other-scoped-secret', expires: Date.now() + 3600000 };
  const active = { id: randomUUID(), session: 'conversation-a', code: 'active-a', scope };
  const queued = { ...active, id: randomUUID(), code: 'queued-a' };
  const independent = { id: randomUUID(), session: 'conversation-b', code: 'independent-b', scope: other };
  const settle = async job => {
    const deadline = Date.now() + 2000;
    while (job.busy && Date.now() < deadline) await new Promise(resolve => setImmediate(resolve));
    assert.equal(Boolean(job.busy), false, 'Executor fixture did not settle');
    await broker.saveTail;
  };
  try {
    await broker.start(active); await broker.advance(broker.owned(active.id, active.session), { action: 'accept' });
    await started;
    await broker.start(queued); await broker.start(independent);
    await broker.scope('conversation-a', [{ app: 'app-a', account: 'account-a' }], false);
    assert.deepEqual(f.scopes.get(scope.id).apps, []);
    assert.deepEqual(f.scopes.get(other.id).apps, [{ app: 'app-b', runsAs: [{ kind: 'account', id: 'account-b' }, { kind: 'account', id: 'account-b2' }], tools: { kind: 'all' } }]);
    assert.equal(broker.jobs.get(active.id).controller.signal.aborted, true);
    assert.equal(broker.jobs.get(queued.id).status, 'cancelled');
    await broker.advance(broker.jobs.get(queued.id), { action: 'accept' });
    assert.deepEqual(executions, ['active-a']);
    release(); await settle(broker.jobs.get(active.id));
    assert.equal(broker.jobs.get(active.id).status, 'cancelled');
    await broker.advance(broker.jobs.get(independent.id), { action: 'accept' });
    await settle(broker.jobs.get(independent.id));
    assert.equal(broker.jobs.get(independent.id).status, 'completed');
    assert.deepEqual(executions, ['active-a', 'independent-b']);
    const reopened = await new ExecutorBroker(f.directory).load(); reopened.config = broker.config;
    assert.equal((await reopened.start(active)).status, 'cancelled');
    assert.equal((await reopened.start(queued)).status, 'cancelled');
    assert.equal((await reopened.start(independent)).status, 'completed');
  } finally {
    release();
    for (const job of broker.jobs.values()) { await broker.cancel(job); await settle(job); }
    await broker.shutdownClients();
  }
});

test('inventory reads linked account targets and never creates profiles or exposes the administrator app', async t => {
  const { broker } = await fixture(t, async () => ({}));
  const calls = [];
  broker.request = async (path, input) => { calls.push([path, input]); return { body: {
    apps: [
      { id: 'admin', owner: 'executor-local', requirements: { accounts: {} } },
      { id: 'plain', name: 'Plain', requirements: { accounts: {} } },
      { id: 'shared', name: 'Shared', requirements: { accounts: { key: { scope: 'app' } } } },
      { id: 'user', name: 'User', requirements: { accounts: { key: { scope: 'user' } } } },
      { id: 'unlinked', requirements: { accounts: { key: { scope: 'user' } } } },
    ], links: [{ app: 'user', account: 'first' }, { app: 'user', account: 'second' }, { app: 'user', account: 'missing' }],
    accounts: [{ id: 'first', label: 'Personal' }, { id: 'second', label: 'Work' }, { id: 'unlinked', label: 'Do not grant' }],
  } }; };
  assert.deepEqual(await broker.inventory(), [
    { id: 'plain:app', app: 'plain', name: 'Plain', profileName: 'App' },
    { id: 'shared:app', app: 'shared', name: 'Shared', profileName: 'App' },
    { id: 'user:account:first', app: 'user', name: 'User', account: 'first', profileName: 'Personal' },
    { id: 'user:account:second', app: 'user', name: 'User', account: 'second', profileName: 'Work' },
  ]);
  assert.deepEqual(calls, [['/dashboard/api/overview', undefined]]);
});

test('a signal-terminated local runtime is not mistaken for a running child', async t => {
  const { broker } = await fixture(t, async () => ({}));
  // Node leaves exitCode null when the child is killed by a signal.
  broker.child = { exitCode: null, signalCode: 'SIGKILL' };
  await assert.rejects(broker.startLocal(false), /Install Executor/);
});

test('remote deployment waits for its private endpoint to become ready', async t => {
  let attempts = 0;
  const { broker } = await fixture(t, async () => ({}));
  broker.runtimeVersion = '2.0.0-beta.12';
  broker.deployRemote = async () => {};
  broker.fetch = async () => { attempts++; if (attempts === 1) throw new Error('still starting'); return new Response('{}'); };
  const result = await broker.configure({ id: randomUUID(), location: 'remote', origin: 'https://fixture.tailnet.ts.net:8443', host: 'fixture.tailnet.ts.net' }, true);
  assert.equal(result.ready, true); assert.equal(attempts, 3);
  assert.equal(result.version, null);
});

test('concurrent jobs share scoped grant refresh and one client connection', async t => {
  const { broker, scope } = await fixture(t, async () => ({}));
  let refreshes = 0, connections = 0, release;
  const gate = new Promise(resolve => { release = resolve; });
  scope.grant.expires = 0;
  broker.token = async () => { refreshes++; await gate; return { token: 'new-scoped-token', refresh: 'next', expires: Date.now() + 3600000 }; };
  const client = { close: async () => {} };
  broker.connectOverride = async () => { connections++; return client; };
  const first = broker.client(scope), second = broker.client(scope);
  release();
  assert.deepEqual(await Promise.all([first, second]), [client, client]);
  assert.equal(refreshes, 1); assert.equal(connections, 1);
});

test('concurrent first programs share authorization and a failed attempt can retry', async t => {
  const { broker, scope } = await fixture(t, async () => ({}));
  delete scope.grant;
  let authorizations = 0, release;
  const gate = new Promise(resolve => { release = resolve; });
  broker.authorize = async () => { authorizations++; await gate; throw new Error('offline'); };
  const attempts = Promise.allSettled([broker.client(scope), broker.client(scope)]);
  release();
  assert.ok((await attempts).every(result => result.status === 'rejected'));
  assert.equal(authorizations, 1);
  broker.authorize = async () => { authorizations++; return { token: 'scoped', expires: Date.now() + 3600000 }; };
  await broker.client(scope);
  assert.equal(authorizations, 2);
});

test('connection replacement closes a late transport instead of caching it', async t => {
  const { broker, scope } = await fixture(t, async () => ({}));
  let release, connected, closes = 0;
  const started = new Promise(resolve => { connected = resolve; });
  broker.connectOverride = async () => {
    connected(); await new Promise(resolve => { release = resolve; });
    return { close: async () => { closes++; } };
  };
  const pending = broker.client(scope);
  await started;
  await broker.shutdownClients();
  release();
  await assert.rejects(pending, /connection changed/);
  assert.equal(closes, 1); assert.equal(broker.clients.size, 0);
});
