import test from 'node:test';
import assert from 'node:assert/strict';
import { grokAccountProfile } from '../src/account-profile.mjs';
import { Credentials } from '../src/credentials.mjs';

test('Grok identity uses the shared OAuth token and survives renewal without becoming authorization', async () => {
  const credential = { type: 'oauth', access: 'fixture-access', refresh: 'fixture-refresh', expires: 1 };
  const profile = await grokAccountProfile(credential, async (url, request) => {
    assert.equal(url, 'https://auth.x.ai/oauth2/userinfo');
    assert.equal(request.headers.Authorization, 'Bearer fixture-access');
    assert.equal(request.redirect, 'error');
    return Response.json({ email: 'fixture@example.invalid', sub: 'fixture-user' });
  });
  assert.deepEqual(profile, { displayName: 'fixture@example.invalid' });
  const store = new Credentials({ xai: { ...credential, ...profile } });
  await store.modify('xai', current => ({ type: 'oauth', access: 'replacement', refresh: current.refresh, expires: 2 }));
  assert.equal((await store.read('xai')).displayName, profile.displayName);
  store.signingIn = true;
  await store.modify('xai', () => ({ type: 'oauth', access: 'different-account' }));
  assert.equal((await store.read('xai')).displayName, undefined);
});

test('profile failures retain the sign-in and API keys never enter the profile flow', async () => {
  assert.deepEqual(await grokAccountProfile({ type: 'api_key', key: 'fixture-key' }, () => { throw new Error('must not fetch'); }), {});
  assert.deepEqual(await grokAccountProfile({ type: 'oauth', access: 'fixture' }, async () => new Response('', { status: 403 })), {});
});
