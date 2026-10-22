import test from 'node:test';
import assert from 'node:assert/strict';
import { claudeModelName } from '../src/model-presentation.mjs';

// Pure metadata fixtures: no runtime, account, SDK or provider invocation.
test('Claude aliases display their reported version without changing selection IDs', () => {
  for (const [model, expected] of [
    [{ value: 'opus', displayName: 'Opus', description: 'Opus 5 · Best for everyday, complex tasks', resolvedModel: 'claude-opus-5' }, 'Opus 5'],
    [{ value: 'opus', displayName: 'Opus', description: 'Opus 5.5 · Fixture future version' }, 'Opus 5.5'],
    [{ value: 'opus', displayName: 'Opus 5.5', resolvedModel: 'claude-opus-5' }, 'Opus 5'],
    [{ value: 'opus', displayName: 'Opus 5', resolvedModel: {} }, 'Opus 5'],
    [{ value: 'sonnet[1m]', displayName: 'Sonnet', description: 'Sonnet 5 with extended context' }, 'Sonnet 5'],
    [{ value: 'fable', displayName: 'Fable', resolvedModel: 'claude-fable-5-1' }, 'Fable 5.1'],
    [{ value: 'haiku', displayName: 'Haiku', resolvedModel: 'claude-haiku-4-5-20251001' }, 'Haiku 4.5'],
    [{ value: 'opus', displayName: 'Claude Opus' }, 'Claude Opus'],
    [{ value: 'sonnet', displayName: 'Sonnet', description: 'Opus 5 is another option' }, 'Sonnet'],
  ]) {
    const original = structuredClone(model);
    assert.equal(claudeModelName(model), expected);
    assert.deepEqual(model, original);
  }
});
