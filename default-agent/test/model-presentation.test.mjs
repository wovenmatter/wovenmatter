import test from 'node:test';
import assert from 'node:assert/strict';
import { claudeModelName, modelOption } from '../src/model-presentation.mjs';

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

test('menu attribution is distinct from inline names and actual connection routes', () => {
  for (const [provider, attribution] of Object.entries({
    'openai-codex': 'ChatGPT subscription', openai: 'OpenAI subscription',
    openrouter: 'OpenRouter subscription', 'opencode-go': 'OpenCode Go',
    xai: 'Grok subscription', 'xai-api': 'XAI subscription',
    'claude-subscription': 'Anthropic subscription', anthropic: 'Anthropic subscription',
  })) {
    const option = modelOption({ id: `${provider}/fixture`, name: 'Fixture Model', provider, providerName: 'Actual connection route' });
    assert.equal(option.value, `${provider}/fixture`);
    assert.equal(option.name, `Fixture Model · ${attribution}`);
    assert.equal(option._meta.modelName, 'Fixture Model');
    assert.equal(option.description, 'Actual connection route');
  }
  const custom = modelOption({ id: 'custom/model', name: 'Model · Native Variant', provider: 'custom', providerName: 'Local server' });
  assert.equal(custom.name, 'Model · Native Variant · Local server');
  assert.equal(custom._meta.modelName, 'Model · Native Variant');
});
