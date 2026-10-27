import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { probeServer, serverURL, localServers } from '../src/local-servers.mjs';
import { DefaultAgentEngine } from '../src/engine.mjs';


const id = 'local-server-12345678-1234-1234-1234-123456789012';
const url = 'http://localhost:32100/v1';
test('Connect discovers models and verifies Responses through the same key without redirects', async () => {
  const calls = [];
  const result = await probeServer(url, 'fixture-key', async (target, options) => {
    calls.push({ target, options });
    return Response.json(target.endsWith('/models') ? { data: [{ id: 'local/active' }, { id: 'local/qwen3.8-27b-mtp' }] }
      : { object: 'response', status: 'incomplete', output: [] });
  });
  assert.deepEqual(result.models, ['local/active', 'local/qwen3.8-27b-mtp']);
  assert.deepEqual(calls.map(c => c.target), [url + '/models', url + '/responses']);
  for (const { options } of calls) {
    assert.equal(options.headers.Authorization, 'Bearer fixture-key'); assert.equal(options.redirect, 'error');
  }
  const probe = JSON.parse(calls[1].options.body);
  assert.equal(probe.store, false); assert.equal(probe.max_output_tokens, 1);
});

test('saved custom models cannot send replacement credentials to a previous server endpoint', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'woven-local-destination-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const config = { providers: [id], defaultModel: id + '/fixture', customServers: [{ id, url, models: ['fixture'] }] };
  const engine = await new DefaultAgentEngine({ cwd: directory, directory, config,
    credentials: { [id]: { type: 'api_key', key: 'original-fixture-key' } } }).initialize();
  assert.equal(engine.providerName(id), url);
  const selected = structuredClone(await engine.ensureModel(config.defaultModel));
  const nextURL = 'http://localhost:32101/v1';
  await engine.apply({ config: { ...config, customServers: [{ id, url: nextURL, models: ['fixture'] }] },
    credentials: { [id]: { type: 'api_key', key: 'replacement-fixture-key' } } });
  let credentialsRead = 0;
  const read = engine.credentials.read.bind(engine.credentials);
  engine.credentials.read = (...args) => { credentialsRead++; return read(...args) };
  await assert.rejects(engine.ensureModel(config.defaultModel, selected), /endpoint changed/);
  credentialsRead = 0;
  const auth = engine.runtime.getAuth(selected);
  assert.equal(credentialsRead, 0);
  await assert.rejects(auth, /endpoint changed/);
  assert.equal((await engine.ensureModel(config.defaultModel)).baseUrl, nextURL);
  assert.equal(engine.providerName(id), nextURL);
});
