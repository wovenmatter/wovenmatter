import test from 'node:test';
import assert from 'node:assert/strict';
import { providerFetch } from '../src/transport.mjs';
import { safeAssistantDiagnostic } from '../src/native-context.mjs';

test('provider HTTP diagnostics survive native normalization without retaining response secrets', async () => {
  for (const status of [400, 403, 404, 408, 422, 429, 503]) {
    const record = {};
    await providerFetch(record, async () => new Response('private response secret-token', {status}))();
    const message = safeAssistantDiagnostic({stopReason:'error',errorMessage:'SDK exception secret-token'}, record.httpFailure);
    assert.match(message.errorMessage, /HTTP/);
    assert.equal(message.errorMessage.includes('secret-token'), false);
    assert.deepEqual(safeAssistantDiagnostic(message), message);
    assert.equal(record.httpAccessFailure, null, 'transport failures must not select another account');
  }
});

test('a later network failure cannot reuse a previous authentication or quota diagnosis', async () => {
  const record = {};
  let requests = 0;
  const request = providerFetch(record, async () => {
    if (++requests === 1) return new Response('unauthorized', {status:401});
    throw new TypeError('fetch failed');
  });
  await request();
  assert.match(record.httpAccessFailure, /sign-in/);
  await assert.rejects(request(), /fetch failed/);
  assert.equal(record.httpAccessFailure, undefined);
  assert.equal(record.httpFailure, undefined);
});
