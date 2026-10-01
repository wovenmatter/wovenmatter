import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { probeServer, serverURL, localServers } from '../src/local-servers.mjs';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { sharedCredentials } from '../src/vault.mjs';

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
test('model listing alone is not a connected Responses server and errors do not echo secrets', async () => {
  await assert.rejects(probeServer(url, 'fixture-secret', async target => target.endsWith('/models')
    ? Response.json({ data: [{ id: 'local/active' }] }) : new Response('fixture-secret', { status: 404 })), /does not expose \/responses/);
  await assert.rejects(probeServer(url, 'fixture-secret', async () => new Response('fixture-secret', { status: 401 })), error => !error.message.includes('fixture-secret') && error.message.includes('API key'));
  await assert.rejects(probeServer(url, 'fixture-key', async () => Response.json({ data: [] })), /Load a model/);
});
test('server addresses and provider identities are bounded and reject embedded credentials', () => {
  assert.equal(serverURL('http://localhost:32100/'), 'http://localhost:32100/v1');
  for (const value of ['file:///tmp/server', 'http://user:secret@localhost/v1', url + '?api_key=secret', url + '#secret']) assert.throws(() => serverURL(value));
  assert.throws(() => localServers(Array(13).fill({ id, url, models: ['model'] })), /12/);
  assert.throws(() => localServers([{ id: 'openai', url, models: ['model'] }]), /identity/);
});
test('custom models enter the existing picker and use literal stored keys; removal retires models', async () => {
  const directory = await mkdtemp(join(tmpdir(), 'woven-local-model-'));
  try {
    const key = '!must-not-run $MUST_NOT_EXPAND';
    const config = { providers: [id], customServers: [{ id, url, models: ['local/active', 'local/qwen3.8-27b-mtp'] }] };
    const engine = await new DefaultAgentEngine({ cwd: directory, directory, config, credentials: { [id]: { type: 'api_key', key } } }).initialize();
    assert.equal(engine.modelOptions()[0].id, id + '/local/active');
    const model = engine.resolveModel(id + '/local/active');
    assert.equal(model.api, 'openai-responses'); assert.equal(model.baseUrl, url);
    const auth = await engine.runtime.getAuth(model);
    assert.equal(auth.auth.apiKey, key);
    assert.ok((await engine.credentials.list()).some(c => c.providerId === id));
    assert.deepEqual(sharedCredentials({ [id]: { type: 'api_key', key } })[id], { type: 'api_key', key });
    await engine.apply({ config: { providers: [], customServers: [] }, credentials: {} });
    assert.equal(engine.modelOptions().length, 0);
  } finally { await rm(directory, { recursive: true, force: true }); }
});
