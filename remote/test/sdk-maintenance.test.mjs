import test from 'node:test';
import assert from 'node:assert/strict';
import { Readable } from 'node:stream';
import { EventEmitter } from 'node:events';
import { defaultAgentSDKRequest } from '../src/server.mjs';

function request(body) {
  return Object.assign(Readable.from([Buffer.from(JSON.stringify(body))]), { method: 'POST' });
}

test('remote combined update forwards no SDK filter and rejects invalid selections', async () => {
  let calls = 0;
  const response = new EventEmitter();
  const service = { updateSDK: async ({ id, version, signal }) => {
    ++calls;
    assert.equal(id, undefined);
    assert.equal(version, undefined);
    assert.equal(signal.aborted, false);
    return { sdks: [{ id: 'pi' }, { id: 'claude' }] };
  } };
  const result = await defaultAgentSDKRequest(request({ action: 'update' }), response, service);
  assert.equal(result.sdks.length, 2);
  await assert.rejects(defaultAgentSDKRequest(request({ action: 'update', id: 'unknown' }), response, service), /invalid_sdk_identifier/);
  await assert.rejects(defaultAgentSDKRequest(request({ action: 'update', version: '1.2.3' }), response, service), /invalid_sdk_version/);
  assert.equal(calls, 1);
  assert.equal(response.listenerCount('close'), 0);
});

test('an update that activates a new SDK copy restarts bots onto it; a no-op or failed restart does not fail it', async () => {
  const response = new EventEmitter();
  let restarts = 0;
  const onActivated = async () => { restarts++; };
  const updated = { updateSDK: async () => ({ sdks: [], generation: 'new', activated: true }) };
  assert.equal((await defaultAgentSDKRequest(request({ action: 'update' }), response, updated, { onActivated })).generation, 'new');
  assert.equal(restarts, 1);
  const current = { updateSDK: async () => ({ sdks: [], generation: 'same' }) };
  await defaultAgentSDKRequest(request({ action: 'update' }), response, current, { onActivated });
  assert.equal(restarts, 1);
  const failing = async () => { throw new Error('restart failed'); };
  assert.equal((await defaultAgentSDKRequest(request({ action: 'update' }), response, updated, { onActivated: failing })).activated, true);
  const checked = { checkSDKUpdates: async () => ({ sdks: [], activated: true }) };
  await defaultAgentSDKRequest(request({ action: 'check' }), response, checked, { onActivated });
  assert.equal(restarts, 1);
});

test('a rejected SDK candidate answers with its readable failure, not internal_error', async () => {
  class SDKMaintenanceError extends Error {}
  const response = new EventEmitter();
  for (const action of ['update', 'check']) {
    const service = { [action === 'update' ? 'updateSDK' : 'checkSDKUpdates']: async () => { throw new SDKMaintenanceError('SDK installation or verification failed. The previous SDKs were kept.'); } };
    await assert.rejects(defaultAgentSDKRequest(request({ action }), response, service),
      error => error.statusCode === 409 && error.message === 'SDK installation or verification failed. The previous SDKs were kept.');
  }
  // Anything else still answers as before.
  await assert.rejects(defaultAgentSDKRequest(request({ action: 'update' }), response, { updateSDK: async () => { throw new Error('/private/path detail'); } }),
    error => error.statusCode === undefined);
});
