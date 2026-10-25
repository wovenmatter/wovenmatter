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
