import test from 'node:test';
import assert from 'node:assert/strict';
import { preferredSignInAnswer } from '../src/sign-in-interaction.mjs';

test('OpenAI Connections chooses device sign-in while leaving other prompts to the user', () => {
  const choice = { options: [{ id: 'browser' }, { id: 'device_code' }] };
  assert.equal(preferredSignInAnswer('openai-codex', choice), 'device_code');
  assert.equal(preferredSignInAnswer('xai', choice), undefined);
  assert.equal(preferredSignInAnswer('openai-codex', { message: 'Enter code' }), undefined);
  assert.equal(preferredSignInAnswer('openai-codex', { options: [{ id: 'browser' }] }), undefined);
});
