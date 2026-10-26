import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { randomBytes } from 'node:crypto';
import { join } from 'node:path';
import { validateConfig } from '../src/config.mjs';
import { searchTools } from '../src/search.mjs';
import { sharedAccounts, sharedCredentials } from '../src/vault.mjs';
import { createDefaultAgentService } from '../src/service.mjs';

const source = { title: 'Source', url: 'https://example.com/article' };
const resultsOf = result => JSON.parse(result.content[0].text).results;
const credentials = Object.fromEntries(['exa', 'brave', 'firecrawl'].map(provider => [provider, { type: 'api_key', key: `${provider}-fixture` }]));

test('search preferences accept supported providers and retain the Exa default for legacy or invalid settings', () => {
  for (const searchProvider of ['exa', 'brave', 'firecrawl']) {
    assert.equal(validateConfig({ searchProvider }).searchProvider, searchProvider);
    assert.ok(!validateConfig({ providers: [searchProvider] }).providers.includes(searchProvider));
  }
  for (const searchProvider of [undefined, null, 'unknown', 'toString', ['brave'], 42]) {
    assert.equal(validateConfig({ searchProvider }).searchProvider, 'exa');
  }
});

test('Brave uses authenticated LLM Context search with bounded, cited extracted content', async () => {
  let request;
  const [search] = searchTools({ provider: 'brave', key: 'brave-fixture' }, async (url, options) => {
    request = { url, ...options };
    return { ok: true, json: async () => ({ grounding: { generic: Array.from({ length: 12 }, () => ({ ...source, snippets: ['First passage', 'x'.repeat(20000)] })) } }) };
  });
  const results = resultsOf(await search.execute('search', { query: 'woven & matter', numResults: 99 }));
  assert.equal(request.url, 'https://api.search.brave.com/res/v1/llm/context');
  assert.equal(request.method, 'POST');
  assert.deepEqual(request.headers, { 'Content-Type': 'application/json', 'X-Subscription-Token': 'brave-fixture' });
  assert.deepEqual(JSON.parse(request.body), { q: 'woven & matter', count: 10, maximum_number_of_urls: 10,
    maximum_number_of_tokens: 8192, maximum_number_of_tokens_per_url: 4096 });
  assert.equal(results.length, 10);
  assert.equal(results[0].url, source.url);
  assert.equal(results[0].text.length, 16000);
  assert.ok(results[0].text.startsWith('First passage\n\n'));
  assert.ok(request.signal instanceof AbortSignal);
});

test('Firecrawl v2 search requests Markdown and normalizes web results and snippets', async () => {
  let request;
  const [search] = searchTools({ provider: 'firecrawl', key: 'firecrawl-fixture' }, async (url, options) => {
    request = { url, ...options };
    return { ok: true, json: async () => ({ success: true, data: { web: [
      { ...source, markdown: 'x'.repeat(20000) }, { ...source, description: 'Snippet when scraping is unavailable' },
    ] } }) };
  });
  const results = resultsOf(await search.execute('search', { query: 'question', numResults: 2 }));
  assert.equal(request.url, 'https://api.firecrawl.dev/v2/search');
  assert.equal(request.headers.Authorization, 'Bearer firecrawl-fixture');
  assert.deepEqual(JSON.parse(request.body), { query: 'question', limit: 2, sources: ['web'], scrapeOptions: { formats: ['markdown'] } });
  assert.equal(results[0].text.length, 16000);
  assert.equal(results[0].url, source.url);
  assert.equal(results[1].text, 'Snippet when scraping is unavailable');
});

test('Exa and Firecrawl read pages through their own endpoints; Brave explains its page-reading boundary', async () => {
  for (const provider of ['exa', 'firecrawl']) {
    const [, read] = searchTools({ provider, key: `${provider}-fixture` }, async (url, options) => {
      assert.equal(url, provider === 'exa' ? 'https://api.exa.ai/contents' : 'https://api.firecrawl.dev/v2/scrape');
      assert.deepEqual(JSON.parse(options.body), provider === 'exa'
        ? { urls: [source.url], text: { maxCharacters: 16000 } }
        : { url: source.url, formats: ['markdown'] });
      return { ok: true, json: async () => provider === 'exa' ? { results: [{ ...source, text: 'Page text' }] }
        : { success: true, data: { metadata: { title: source.title }, markdown: 'Page text' } } };
    });
    assert.deepEqual(resultsOf(await read.execute('read', { url: source.url })), [{ ...source, text: 'Page text' }]);
    assert.throws(() => read.execute('read', { url: 'file:///private/fixture' }), /public HTTP or HTTPS/);
  }
  const [, braveRead] = searchTools({ provider: 'brave', key: 'brave-fixture' }, () => assert.fail('Brave must not call another provider to read a page'));
  await assert.rejects(braveRead.execute('read', { url: source.url }), /Brave.*not direct webpage reading/);
});

test('each provider requires its own key and reports safe HTTP, transport, and JSON errors', async () => {
  for (const provider of ['exa', 'brave', 'firecrawl']) {
    const [missing] = searchTools({ provider }, () => assert.fail('Missing key must not send a request'));
    await assert.rejects(missing.execute('search', { query: 'question' }), /API key.*Accounts/);
    for (const fetchRequest of [
      async () => ({ ok: false, status: 401, json: () => assert.fail('Do not read error bodies') }),
      async () => { throw new Error('sensitive-key in https://private-endpoint.invalid'); },
      async () => ({ ok: true, json: async () => { throw new Error('sensitive-key'); } }),
      async () => ({ ok: true, status: 200, json: async () => ({ success: false, error: 'sensitive-key' }) }),
    ]) {
      const [search] = searchTools({ provider, key: 'sensitive-key' }, fetchRequest);
      await assert.rejects(search.execute('search', { query: 'question' }), error => {
        assert.match(error.message, /request failed/);
        assert.ok(!error.message.includes('sensitive-key') && !error.message.includes('private-endpoint'));
        return true;
      });
    }
  }
});

test('search calls resolve the latest provider and key, clamp counts, and propagate cancellation', async () => {
  let settings = { provider: 'exa', key: 'first' };
  const requests = [];
  const [search] = searchTools(async () => settings, async (url, options) => {
    requests.push({ url, ...options });
    return { ok: true, json: async () => ({ results: [], grounding: { generic: [] }, data: { web: [] } }) };
  });
  await search.execute('first', { query: 'question', numResults: 0 });
  settings = { provider: 'brave', key: 'second' };
  await search.execute('second', { query: 'question', numResults: 2.9 });
  settings = { provider: 'firecrawl', key: 'third' };
  await search.execute('third', { query: 'question' });
  assert.equal(JSON.parse(requests[0].body).numResults, 1);
  assert.equal(requests[0].headers['x-api-key'], 'first');
  assert.equal(JSON.parse(requests[1].body).count, 2);
  assert.equal(requests[1].headers['X-Subscription-Token'], 'second');
  assert.equal(JSON.parse(requests[2].body).limit, 5);
  assert.equal(requests[2].headers.Authorization, 'Bearer third');
  const controller = new AbortController();
  const [cancelled] = searchTools(settings, async (_url, { signal }) => {
    assert.ok(!signal.aborted);
    controller.abort();
    signal.throwIfAborted();
  });
  await assert.rejects(cancelled.execute('cancel', { query: 'question' }, controller.signal), { name: 'AbortError' });
  await assert.rejects(search.execute('cancel-before-send', { query: 'question' }, controller.signal), { name: 'AbortError' });
  assert.equal(requests.length, 3);
});

test('remote configuration preserves search selection and encrypted provider keys/accounts across updates and restart', async t => {
  const directory = await mkdtemp('/tmp/woven-search-sharing-');
  t.after(() => rm(directory, { recursive: true, force: true }));
  const base = { workspace: 'fixture', unlockKey: randomBytes(32).toString('base64') };
  const accounts = Object.fromEntries(Object.entries(credentials).map(([provider, credential]) => [provider, [{ id: provider, label: provider, credential }]]));
  assert.deepEqual(sharedCredentials(credentials), credentials);
  assert.deepEqual(sharedAccounts(accounts), accounts);
  const service = createDefaultAgentService({ cwd: directory, directory });
  await service.configure({ ...base, config: { searchProvider: 'brave' }, credentials, credentialAccounts: accounts });
  const engine = await service.engine();
  engine.claude.status = async () => ({ connected: false });
  assert.equal(engine.config.searchProvider, 'brave');
  assert.equal((await engine.status()).searchConfigured, true);
  assert.equal((await engine.credentials.read('brave')).key, 'brave-fixture');
  await service.configure({ ...base, config: { searchProvider: 'firecrawl' }, credentials: { exa: credentials.exa } });
  assert.equal(await service.engine(), engine);
  assert.equal(engine.config.searchProvider, 'firecrawl');
  assert.equal((await engine.status()).searchConfigured, false);
  await service.configure({ ...base, config: { searchProvider: 'firecrawl' }, credentials, credentialAccounts: accounts });
  const restarted = createDefaultAgentService({ cwd: directory, directory });
  await assert.rejects(restarted.engine(), /locked/);
  await restarted.unlockForClient(base);
  const restored = await restarted.engine();
  assert.equal(restored.config.searchProvider, 'firecrawl');
  assert.equal((await restored.credentials.candidates('firecrawl'))[0].credential.key, 'firecrawl-fixture');
  const disk = await readFile(join(directory, 'credentials.enc.json'), 'utf8');
  const config = await readFile(join(directory, 'configuration.json'), 'utf8');
  for (const { key } of Object.values(credentials)) {
    assert.ok(!disk.includes(key) && !config.includes(key));
  }
});
