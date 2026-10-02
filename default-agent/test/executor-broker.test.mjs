import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { ExecutorBroker, validateConfiguration } from '../src/executor/broker.mjs';
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
  const scope = await broker.scope('conversation-a', [{ app: 'app-a', profile: 'profile-a' }], true);
  scope.grant = { token: 'scoped-secret', expires: Date.now() + 3600000 };
  return { broker, scope, calls, scopes, directory };
}
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
test('pending input and approval are distinct and their continuation never reaches CLI results', async t => {
  const { broker, scope } = await fixture(t, async request => request.name === 'resume' ? { structuredContent: { status: 'completed', execution: { ok: true } } } : { structuredContent: { status: 'input-required', requestId: 'elc_private', elicitation: { requestedSchema: { type: 'object', properties: {} } } } });
  const id = randomUUID(); await broker.start({ id, session: 'conversation-a', scope, code: 'return tools.ask({});' });
  const job = broker.owned(id, 'conversation-a');
  await broker.advance(job, { action: 'accept' });
  while (job.status === 'running') await wait(10);
  assert.equal(job.status, 'input-required');
  assert.ok(!JSON.stringify(broker.publicJob(job)).includes('elc_private'));
  await broker.advance(job, { action: 'accept', content: {} });
  while (job.status === 'running') await wait(10);
  assert.equal(job.status, 'completed');
});
test('scope updates group profiles by app, preserve independent scopes, and master off empties authority', async t => {
  const { broker, scopes } = await fixture(t, async () => ({}));
  const a = await broker.scope('conversation-a', [{ app: 'one', profile: 'first' }, { app: 'one', profile: 'second' }], true);
  const b = await broker.scope('conversation-b', [{ app: 'two', profile: 'third' }], true);
  assert.equal(scopes.get(a.id).apps.length, 1);
  assert.equal(scopes.get(a.id).apps[0].runsAs.length, 2);
  await broker.scope('conversation-a', [], false);
  assert.deepEqual(scopes.get(a.id).apps, []);
  assert.equal(scopes.get(b.id).apps[0].app, 'two');
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
  await assert.rejects(broker.advance(job, { action: 'accept', content: { count: 'three' } }), /requested form/);
  assert.equal(job.status, 'input-required'); assert.equal(resumes, 0);
  await broker.advance(job, { action: 'accept', content: { count: 3 } });
  while (job.status === 'running') await wait(10);
  assert.equal(job.status, 'completed'); assert.equal(resumes, 1);
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

test('remote deployment waits for its private endpoint to become ready', async t => {
  let attempts = 0;
  const { broker } = await fixture(t, async () => ({}));
  broker.deployRemote = async () => {};
  broker.fetch = async () => { attempts++; if (attempts === 1) throw new Error('still starting'); return new Response('{}'); };
  const result = await broker.configure({ id: randomUUID(), location: 'remote', origin: 'https://fixture.tailnet.ts.net:8443', host: 'fixture.tailnet.ts.net' }, true);
  assert.equal(result.ready, true); assert.equal(attempts, 3);
});

test('large output stays bounded and cancelling completed work preserves its receipt', async t => {
  const { broker, scope } = await fixture(t, async () => ({structuredContent:{status:'completed', execution:{ok:true, value:'x'.repeat(1048576)}}}));
  const id = randomUUID(); await broker.start({id, session:'conversation-a', scope, code:'return large;'});
  const job = broker.owned(id, 'conversation-a'); await broker.advance(job, {action:'accept'});
  while (job.busy) await wait(10);
  const result = broker.publicJob(job);
  assert.equal(result.status, 'completed'); assert.match(result.error, /response limit/);
  assert.ok(Buffer.byteLength(JSON.stringify(result)) < 1048576);
  await broker.cancel(job); assert.equal(job.status, 'completed');
});
