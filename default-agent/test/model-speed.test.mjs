import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { zstdDecompressSync } from 'node:zlib';
import { streamSimple as codexStream } from '@earendil-works/pi-ai/api/openai-codex-responses';
import { CodexServiceTiers, claudeSpeeds, codexCatalogClientVersion, parseCodexServiceTiers, speedReference, splitSpeedReference, withSpeed } from '../src/model-speed.mjs';
import { speedModelOption } from '../src/model-presentation.mjs';
import { withReasoningSummaries } from '../src/reasoning-stream-options.mjs';

const jwt = account => ['fixture', Buffer.from(JSON.stringify({ 'https://api.openai.com/auth': { chatgpt_account_id: account } })).toString('base64url'), 'fixture'].join('.');
const codexModel = { id: 'gpt-fixture-sol', name: 'GPT Fixture Sol', provider: 'openai-codex', api: 'openai-codex-responses', reasoning: true,
  baseUrl: 'https://fixture.invalid', input: ['text'], contextWindow: 128000, maxTokens: 4096, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
const catalog = { models: [
  { slug: 'gpt-fixture-sol', service_tiers: [{ id: 'ultrafast', name: 'Ultrafast', description: 'Fastest.' }, { id: 'priority', name: 'Fast', description: '2x speed' }, { id: 'flex', name: 'Flex', description: 'Slower' }] },
  { slug: 'gpt-fixture-astra', service_tiers: [{ id: 'priority', name: 'Fast', description: '1.5x speed' }] },
  { slug: 'gpt-fixture-plain', service_tiers: [] },
] };

test('speed variants parse only for subscription routes and known speeds', () => {
  assert.deepEqual(splitSpeedReference('claude-subscription/opus#fast'), { reference: 'claude-subscription/opus', speed: 'fast' });
  assert.deepEqual(splitSpeedReference('openai-codex/gpt-6.2-sol#ultrafast'), { reference: 'openai-codex/gpt-6.2-sol', speed: 'ultrafast' });
  for (const reference of ['openai-codex/gpt-6.2-sol', 'openai/gpt-6.2-sol#fast', 'anthropic/opus#fast', 'openai-codex/gpt#priority', undefined]) {
    assert.deepEqual(splitSpeedReference(reference), { reference, speed: undefined });
  }
  assert.equal(speedReference('openai-codex/gpt', 'fast'), 'openai-codex/gpt#fast');
  assert.equal(speedReference('openai-codex/gpt', undefined), 'openai-codex/gpt');
  const option = speedModelOption({ id: 'openai-codex/gpt', name: 'GPT', provider: 'openai-codex', providerName: 'OpenAI · ChatGPT subscription' }, { id: 'fast', name: 'Fast' });
  assert.equal(option.value, 'openai-codex/gpt#fast');
  assert.equal(option.name, 'GPT · ChatGPT subscription');
  assert.deepEqual(option._meta, { modelName: 'GPT', speed: 'fast', speedName: 'Fast' });
});

test('Codex tiers map to Woven speeds in a stable order and ignore other tiers', () => {
  assert.deepEqual(parseCodexServiceTiers(catalog), {
    'gpt-fixture-sol': [{ id: 'fast', tier: 'priority', name: 'Fast', description: '2x speed' }, { id: 'ultrafast', tier: 'ultrafast', name: 'Ultrafast', description: 'Fastest.' }],
    'gpt-fixture-astra': [{ id: 'fast', tier: 'priority', name: 'Fast', description: '1.5x speed' }],
  });
  assert.throws(() => parseCodexServiceTiers({}));
});

test('Codex tiers come from the signed-in account catalog and never carry over to another account', async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-speed-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const requests = [];
  let response = catalog;
  const tiers = new CodexServiceTiers(root, { fetcher: async (url, init) => {
    requests.push({ url, headers: init.headers, redirect: init.redirect });
    return new Response(JSON.stringify(response), { status: 200 });
  } });
  await tiers.refresh({ apiKey: jwt('account-a') });
  assert.equal(requests[0].url, `https://chatgpt.com/backend-api/codex/models?client_version=${codexCatalogClientVersion}`);
  assert.equal(requests[0].headers.Authorization, `Bearer ${jwt('account-a')}`);
  assert.equal(requests[0].headers['chatgpt-account-id'], 'account-a');
  assert.equal(requests[0].redirect, 'error');
  assert.deepEqual(tiers.speeds(codexModel).map(entry => entry.id), ['fast', 'ultrafast']);
  assert.equal(tiers.tier(codexModel, 'ultrafast'), 'ultrafast');
  assert.deepEqual(tiers.speeds({ ...codexModel, provider: 'openai' }), []);
  const saved = JSON.parse(await readFile(join(root, 'codex-service-tiers.json'), 'utf8'));
  assert.equal(saved.account, 'account-a');
  assert.equal(JSON.stringify(saved).includes('fixture.'), false, 'the access token is never persisted');
  // Cached for the same account.
  await tiers.refresh({ apiKey: jwt('account-a') });
  assert.equal(requests.length, 1);
  // A restarted engine restores the cache.
  const restored = new CodexServiceTiers(root, { fetcher: async () => { throw new Error('offline'); } });
  await restored.load();
  assert.deepEqual(restored.speeds(codexModel).map(entry => entry.id), ['fast', 'ultrafast']);
  // Another account: its own catalog, and no stale tiers while it is unavailable.
  await assert.rejects(restored.refresh({ apiKey: jwt('account-b') }));
  assert.deepEqual(restored.speeds(codexModel), []);
  response = { models: [{ slug: 'gpt-fixture-sol', service_tiers: [{ id: 'priority', name: 'Fast', description: '2x speed' }] }] };
  await tiers.refresh({ apiKey: jwt('account-b') });
  assert.deepEqual(tiers.speeds(codexModel).map(entry => entry.id), ['fast']);
});

test('the actual Codex stream submits the selected account tier as its service tier', async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-speed-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const codexTiers = new CodexServiceTiers(root, { fetcher: async () => new Response(JSON.stringify(catalog), { status: 200 }) });
  await codexTiers.refresh({ apiKey: jwt('fixture-account') });
  for (const [speed, expected] of [['fast', 'priority'], ['ultrafast', 'ultrafast'], [undefined, undefined]]) {
    let submitted;
    const base = withReasoningSummaries(codexModel, { reasoning: 'medium', transport: 'sse', maxRetries: 0, apiKey: jwt('fixture-account'),
      fetch: async (_url, init) => {
        const headers = new Headers(init.headers), body = headers.get('content-encoding') === 'zstd' ? zstdDecompressSync(init.body) : init.body;
        submitted = JSON.parse(Buffer.isBuffer(body) || body instanceof Uint8Array ? Buffer.from(body).toString('utf8') : body);
        throw new Error('Offline fixture: no provider contacted');
      } });
    await codexStream(codexModel, { messages: [{ role: 'user', content: 'offline fixture', timestamp: 0 }] }, withSpeed(codexModel, base, { speed, codexTiers, claude: { models: [] } })).result();
    assert.equal(submitted.service_tier, expected);
    assert.deepEqual(submitted.reasoning, { effort: 'medium', summary: 'detailed' });
  }
  // A speed the account does not advertise for this model is not sent.
  const astra = { ...codexModel, id: 'gpt-fixture-astra' };
  assert.equal(withSpeed(astra, {}, { speed: 'ultrafast', codexTiers, claude: { models: [] } }).onPayload, undefined);
});

test('Claude fast mode is offered only where the subscription runtime reports it', () => {
  const claude = { models: [{ value: 'opus', supportsFastMode: true }, { value: 'sonnet' }] };
  const opus = { provider: 'claude-subscription', id: 'opus' };
  assert.deepEqual(claudeSpeeds(claude, opus), [{ id: 'fast', name: 'Fast' }]);
  assert.deepEqual(claudeSpeeds(claude, { ...opus, id: 'sonnet' }), []);
  assert.deepEqual(claudeSpeeds(claude, { ...opus, provider: 'anthropic' }), []);
  assert.deepEqual(withSpeed(opus, { reasoning: 'high' }, { speed: 'fast', claude }), { reasoning: 'high', wovenSpeed: 'fast' });
  assert.deepEqual(withSpeed({ ...opus, id: 'sonnet' }, { reasoning: 'high' }, { speed: 'fast', claude }), { reasoning: 'high' });
  assert.deepEqual(withSpeed(opus, { reasoning: 'high' }, { speed: 'ultrafast', claude }), { reasoning: 'high' });
});
