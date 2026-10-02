// Provider-free acceptance against the unchanged published Executor executable.
// Usage: node scripts/test-support/test-executor-runtime.mjs /path/to/executor/bin.mjs
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createServer } from 'node:net';
import { randomUUID, randomBytes } from 'node:crypto';
import { ExecutorBroker } from '../../default-agent/src/executor/broker.mjs';
const executable = process.argv[2];
if (!executable) throw new Error('Pass the unchanged published Executor bin.mjs path.');
const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
const root = await mkdtemp(join(tmpdir(), 'woven-executor-acceptance-'));
const listener = createServer(); await new Promise(resolve => listener.listen(0, '127.0.0.1', resolve));
const port = listener.address().port; await new Promise(resolve => listener.close(resolve));
const config = { id: randomUUID(), location: 'local' };
const server = { location: 'local', apiKey: randomBytes(32).toString('hex'), encryptionKey: randomBytes(32).toString('hex'), port };
await mkdir(join(root, 'data'));
const child = spawn(process.execPath, [resolve(executable), 'serve'], { stdio: 'ignore', env: {
  ...process.env, PATH: process.env.PATH, EXECUTOR_DATA_DIR: join(root, 'data'), EXECUTOR_PORT: String(port),
  EXECUTOR_API_KEY: server.apiKey, EXECUTOR_ENCRYPTION_KEY: server.encryptionKey, EXECUTOR_NO_UPDATE_CHECK: '1',
} });
const broker = await new ExecutorBroker(join(root, 'manager')).load();
broker.state.servers[config.id] = server; broker.child = child;
let passed = 0;
const check = name => { passed++; console.log(`PASS ${name}`); };
try {
  const deadline = Date.now() + 90000;
  while (true) {
    try { await broker.configure(config); break; }
    catch { if (child.exitCode !== null || Date.now() > deadline) throw new Error('Fixture runtime failed to start.'); await wait(500); }
  }
  check('Unchanged runtime starts with isolated state');
  const apps = [];
  for (const label of ['alpha', 'beta']) {
    const source = `import {defineApp,query,mutation,object,router} from 'apps'; import {always} from 'apps/operations/approval'; export default defineApp({accounts:{}},async ctx=>({tools:router({read:query({input:object({})},async()=>({fixture:'${label}'})),approved:mutation({input:object({}),approval:always()},async()=>({changed:'${label}'})),ask:query({input:object({})},async()=>await ctx.elicit({mode:'form',message:'Fixture input',requestedSchema:{type:'object',properties:{answer:{type:'string'}},required:['answer']}})),blocked:mutation({input:object({}),approval:async()=> 'denied'},async()=>({bad:true}))})}));`;
    const deployed = await broker.request('/v1/apps/deploy', { method: 'POST', value: { owner: 'woven-fixture', name: `Fixture ${label}`, files: [{ path: 'index.ts', content: source }, { path: 'package.json', content: JSON.stringify({ dependencies: { apps: '0.0.1-beta.14' } }) }] } });
    apps.push(deployed.body.app);
  }
  const profiles = await broker.inventory();
  assert.equal(profiles.length, 2); assert.ok(profiles.every(profile => profile.name.startsWith('Fixture')));
  check('Account-free profiles are saved and the administrator app is excluded');
  const selected = apps.map(app => profiles.find(profile => profile.app === app.id));
  const a = await broker.scope('conversation-a', [selected[0]], true);
  const b = await broker.scope('conversation-b', [selected[1]], true);
  async function run(scope, session, code, respond) {
    const id = randomUUID(); await broker.start({ id, scope, session, code });
    const job = broker.owned(id, session); await broker.advance(job, { action: 'accept', content: {} });
    while (true) {
      if (['approval-required', 'input-required'].includes(job.status)) {
        if (!respond) return job;
        await broker.advance(job, await respond(job.pending));
      }
      if (['completed', 'cancelled', 'interrupted'].includes(job.status)) return job;
      await wait(100);
    }
  }
  const path = (app, profile) => `tools[${JSON.stringify(app.slug)}].profiles[${JSON.stringify(profile.profile)}]`;
  assert.equal((await run(a, 'conversation-a', `return await ${path(apps[0], selected[0])}.read({});`)).result.execution.value.fixture, 'alpha');
  assert.equal((await run(b, 'conversation-b', `return await ${path(apps[1], selected[1])}.read({});`)).result.execution.value.fixture, 'beta');
  check('Broker issues working conversation-bound grants through the public API');
  const blocked = await run(a, 'conversation-a', `const app=${JSON.stringify(apps[1].slug)}; return await tools[app].read({});`);
  assert.equal(blocked.result.execution.ok, false);
  assert.deepEqual((await run(a, 'conversation-a', `return await tools.search({namespace:${JSON.stringify(apps[1].slug)}});`)).result.execution.value.items, []);
  check('Execute and search exclude unselected apps, including dynamic names');
  const approval = await run(a, 'conversation-a', `return await ${path(apps[0], selected[0])}.approved({});`);
  assert.equal(approval.status, 'approval-required');
  await broker.advance(approval, { action: 'accept', content: {} });
  while (approval.status === 'running') await wait(100);
  assert.equal(approval.result.execution.value.changed, 'alpha');
  check('Structured action approvals resume the same program');
  const input = await run(a, 'conversation-a', `return await ${path(apps[0], selected[0])}.ask({});`, pending => {
    assert.equal(pending.status, 'input-required'); return { action: 'accept', content: { answer: 'test' } };
  });
  assert.equal(input.result.execution.value.content.answer, 'test');
  check('Typed input remains distinct from action approval');
  const denied = await run(a, 'conversation-a', `return await ${path(apps[0], selected[0])}.blocked({});`);
  assert.equal(denied.result.execution.ok, false);
  check('A hard app denial remains blocked');
  const pending = await run(a, 'conversation-a', `return await ${path(apps[0], selected[0])}.approved({});`);
  await broker.scope('conversation-a', [], true);
  await broker.advance(pending, { action: 'accept', content: {} });
  while (pending.status === 'running') await wait(100);
  assert.equal(pending.result.execution.ok, false);
  assert.equal((await run(b, 'conversation-b', `return await ${path(apps[1], selected[1])}.read({});`)).result.execution.value.fixture, 'beta');
  check('App removal during approval takes effect without changing another conversation');
  await broker.scope('conversation-a', [selected[0]], true);
  const cancellation = await run(a, 'conversation-a', `return await ${path(apps[0], selected[0])}.approved({});`);
  await broker.scope('conversation-a', [], false);
  assert.equal(cancellation.status, 'cancelled');
  check('Master off empties the remote scope and cancels pending work');
  console.log(`${passed} runtime checks passed; no provider accounts or API services used.`);
} finally {
  await broker.stop(); child.kill('SIGTERM');
  if (child.exitCode === null) await Promise.race([new Promise(resolve => child.once('exit', resolve)), wait(10000).then(() => child.kill('SIGKILL'))]);
  await rm(root, { recursive: true, force: true });
}
