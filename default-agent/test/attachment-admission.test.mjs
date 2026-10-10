import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, access } from 'node:fs/promises';
import { join } from 'node:path';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import { createDefaultAgentService } from '../src/service.mjs';
import { writePrivateJSON } from '../src/config.mjs';

function gate() {
  let release;
  const promise = new Promise(resolve => { release = resolve; });
  return { promise, release };
}

async function fixture(t, { holdAdmission = false } = {}) {
  const directory = await mkdtemp('/tmp/woven-attachment-test-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  const writing = gate(), written = gate(), execution = gate();
  const calls = [];
  const engine = {
    sessions: new Map(), create: async () => ({}), configuration: () => ({}),
    handle: async (method, params, emit) => {
      calls.push({ method, session: params?.sessionId });
      if (method === 'session/prompt') {
        emit({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: 'finished' } });
        await execution.promise;
        return { stopReason: 'end_turn' };
      }
      return { sessionId: params?.sessionId ?? 'native' };
    },
  };
  const service = createDefaultAgentService({ cwd: directory, directory, engineFactory: async () => engine,
    writeState: async (path, value) => {
      writing.release();
      if (holdAdmission) await written.promise;
      return writePrivateJSON(path, value);
    } });
  const load = token => service.invoke({ method: 'session/load', attachmentProtocol: 1, attachmentToken: token, params: { sessionId: 'native' } });
  const prompt = token => ({ method: 'session/prompt', operationID: crypto.randomUUID(), attachmentToken: token,
    params: { sessionId: 'native', _meta: { wovenRunID: 'logical-run' } } });
  return { service, load, prompt, calls, writing, written, execution, directory };
}

test('replacement load follows queued admission and fences the previous attachment', async t => {
  const f = await fixture(t, { holdAdmission: true });
  const old = (await f.load()).result._meta.attachmentToken;
  const request = f.prompt(old);
  const accepted = f.service.invoke(request);
  await f.writing.promise;
  const replacing = f.load();
  // Another session has its own queue, even while this journal write waits.
  const other = await f.service.invoke({ method: 'session/load', attachmentProtocol: 1, params: { sessionId: 'other' } });
  assert.ok(other.result._meta.attachmentToken);
  f.written.release();
  await accepted;
  const loading = await replacing;
  assert.equal(loading.result.sessionId, 'native');
  assert.notEqual(loading.result._meta.attachmentToken, old);
  const late = f.prompt(old);
  await assert.rejects(f.service.invoke(late), /attachment was replaced/);
  await assert.rejects(access(join(f.directory, `accepted-${late.operationID}.json`)));
  f.execution.release();
  while (!(await f.service.poll(request.operationID)).done) await new Promise(resolve => setImmediate(resolve));
  assert.equal(f.calls.filter(call => call.method === 'session/prompt').length, 1);
});

test('stale prompt, steering, cancel and selection cannot mutate the replacement attachment', async t => {
  const f = await fixture(t);
  const old = (await f.load()).result._meta.attachmentToken;
  const current = (await f.load()).result._meta.attachmentToken;
  for (const method of ['session/prompt', '_session/steering', 'session/cancel', 'session/set_config_option']) {
    await assert.rejects(f.service.invoke({ ...f.prompt(old), method }), /attachment was replaced/);
    await assert.rejects(f.service.invoke({ ...f.prompt(undefined), method }), /attachment was replaced/);
  }
  assert.equal(f.calls.some(call => call.method !== 'session/load'), false);
  assert.ok((await f.load(current)).result._meta.attachmentToken);
});

for (const trusted of [false, true]) test(`Stop during admission prevents a later native prompt (trusted=${trusted})`, async t => {
  const f = await fixture(t, { holdAdmission: true });
  const token = (await f.load()).result._meta.attachmentToken;
  const accepted = f.service.invoke(f.prompt(token));
  const rejected = assert.rejects(accepted, /stopped before native dispatch/);
  await f.writing.promise;
  if (trusted) await f.service.cancelSession('native');
  else await f.service.invoke({ method: 'session/cancel', attachmentToken: token, params: { sessionId: 'native' } });
  f.written.release();
  await rejected;
  assert.equal(f.calls.some(call => call.method === 'session/prompt'), false);
  assert.ok((await f.load()).result._meta.attachmentToken);
});

for (const failure of ['receipt', 'poll', 'terminal']) test(`Built-in adapter distinguishes remote ${failure} outcome`, { timeout: 10000 }, async t => {
  const directory = await mkdtemp('/tmp/woven-adapter-test-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  const mock = `globalThis.fetch = async (url, options) => {
    const body = options.body && JSON.parse(options.body);
    let result;
    if (body?.method === 'session/new') result = { result: { sessionId: 'native', _meta: { attachmentToken: 'fixture' } } };
    else if (body?.method === 'session/prompt') {
      if (${JSON.stringify(failure)} === 'receipt') throw new Error('lost admission receipt');
      result = { operationID: 'fixture-operation' };
    } else if (String(url).includes('/runs/')) {
      if (${JSON.stringify(failure)} === 'poll') throw new Error('lost observation transport');
      result = { done: true, updates: [], cursor: 0, error: 'Native task failed' };
    } else throw new Error('Unexpected fixture request: ' + url);
    return { ok: true, status: 200, json: async () => result };
  };`;
  const child = spawn(process.execPath, ['--import', 'data:text/javascript,' + encodeURIComponent(mock),
    fileURLToPath(new URL('../src/main.mjs', import.meta.url)), '--remote'], {
      env: { ...process.env, WOVEN_DEFAULT_AGENT_DIRECTORY: directory }, stdio: ['pipe', 'pipe', 'pipe'],
    });
  t.after(() => child.kill('SIGTERM'));
  const pending = new Map();
  const lines = createInterface({ input: child.stdout });
  lines.on('line', line => { const value = JSON.parse(line); pending.get(value.id)?.(value); });
  const send = message => new Promise(resolve => {
    pending.set(message.id, resolve); child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
  });
  await send({ id: 1, method: 'session/new', params: {} });
  const response = await send({ id: 2, method: 'session/prompt', params: { sessionId: 'native', prompt: [] } });
  assert.equal(response.error.data?.deliveryUncertain === true, failure !== 'terminal');
  child.stdin.end();
});

test('idle adoption rotates an attachment only after the engine confirms no active work',async t=>{
  const directory=await mkdtemp('/tmp/woven-idle-adoption-')
  t.after(()=>rm(directory,{recursive:true,force:true}))
  let idle=false,prompts=0
  const service=createDefaultAgentService({cwd:directory,directory,engineFactory:async()=>({sessions:new Map(),handle:async(method,params)=>{
    if(method==='session/prompt')prompts++
    if(method==='woven/adopt'&&!idle)throw new Error('Session is not idle')
    return {sessionId:params.sessionId}
  }})})
  const old=(await service.invoke({method:'session/load',attachmentProtocol:1,params:{sessionId:'native'}})).result._meta.attachmentToken
  const adopt=()=>service.invoke({method:'woven/adopt',attachmentProtocol:1,params:{sessionId:'native'}})
  await assert.rejects(adopt(),/not idle/)
  await service.invoke({method:'woven/history',attachmentToken:old,params:{sessionId:'native'}})
  idle=true
  const current=(await adopt()).result._meta.attachmentToken
  assert.notEqual(current,old)
  await assert.rejects(service.invoke({method:'woven/history',attachmentToken:old,params:{sessionId:'native'}}),/attachment was replaced/)
  await service.invoke({method:'woven/history',attachmentToken:current,params:{sessionId:'native'}})
  assert.equal(prompts,0)
})
