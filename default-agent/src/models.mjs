import { join } from 'node:path';
import { ModelRuntime } from '@earendil-works/pi-coding-agent';
import { getSupportedThinkingLevels } from '@earendil-works/pi-ai/models';
import { registerClaude } from './claude.mjs';

export const subscriptions = [
  { id: 'openai-codex', name: 'ChatGPT', kind: 'subscription' },
  { id: 'xai', name: 'Grok', kind: 'subscription' },
  { id: 'claude-subscription', name: 'Claude', kind: 'subscription' },
];
// Stock providers that need more than one key (accounts, regions, gateways) are left out.
const needsMoreThanAKey = new Set(['amazon-bedrock', 'azure', 'google-vertex', 'cloudflare-ai-gateway', 'cloudflare-workers-ai', 'github-copilot', 'openai-codex', 'xai']);
const searchProviders = [
  { id: 'exa', name: 'Exa web search', kind: 'apiKey' },
  { id: 'brave', name: 'Brave web search', kind: 'apiKey' },
  { id: 'firecrawl', name: 'Firecrawl web search', kind: 'apiKey' },
];
const preferred = ['openai-codex', 'claude-subscription', 'xai', 'anthropic', 'openai'];

// pi-ai's model runtime with its stock catalogs (cached in the data folder),
// credentials from the server, the Claude subscription, and an API-key route to xAI
// beside the Grok subscription.
export async function createModels({ dataDirectory, credentials, extraProviders = [] }) {
  const runtime = await ModelRuntime.create({ credentials, modelsPath: null, modelsStorePath: join(dataDirectory, 'models.json'), refreshOnCreate: false });
  const xai = runtime.getProvider('xai');
  runtime.registerNativeProvider({ ...xai, id: 'xai-api', name: 'xAI', auth: { apiKey: xai.auth.apiKey }, refreshModels: undefined,
    getModels: () => runtime.getModels('xai').map(model => ({ ...model, provider: 'xai-api' })),
    getAllModels: () => runtime.getModels('xai').map(model => ({ ...model, provider: 'xai-api' })) });
  const claude = registerClaude(runtime, { dataDirectory, credentials });
  for (const provider of extraProviders) runtime.registerNativeProvider(provider);
  return { runtime, claude, credentials };
}

export function providerList(runtime) {
  const apiKey = runtime.getProviders().filter(provider => provider.auth?.apiKey && !needsMoreThanAKey.has(provider.id) && provider.id !== 'claude-subscription')
    .map(provider => ({ id: provider.id, name: provider.name, kind: 'apiKey' }));
  return [...subscriptions, ...apiKey, ...searchProviders];
}

// The models the supplied credentials can use, preferred providers first.
export async function availableModels({ runtime, claude, credentials }) {
  const ids = await credentials.providers();
  if (ids.includes('claude-subscription')) await claude.loadModels();
  const order = id => { const index = preferred.indexOf(id); return index < 0 ? preferred.length : index; };
  return ids.filter(id => runtime.getProvider(id)).sort((a, b) => order(a) - order(b))
    .flatMap(id => runtime.getModels(id).filter(model => model.type === undefined || model.type === 'chat'));
}

// Refresh catalogs of the providers in use in the background; resolves true when anything changed.
export async function refreshCatalogs({ runtime, credentials }) {
  const ids = (await credentials.providers()).filter(id => runtime.getProvider(id)?.refreshModels);
  if (!ids.length) return false;
  const before = JSON.stringify(ids.map(id => runtime.getModels(id).map(model => model.id)));
  await runtime.refresh({ allowNetwork: true, providers: ids, signal: AbortSignal.timeout(15000) }).catch(() => {});
  return before !== JSON.stringify(ids.map(id => runtime.getModels(id).map(model => model.id)));
}

// OpenAI Responses-compatible model servers on this machine or the tailnet. Each is
// a provider `local-server-<uuid>` whose API key comes with the other credentials.
export function registerLocalServers(runtime, servers = []) {
  for (const server of Array.isArray(servers) ? servers : []) {
    if (!/^local-server-[a-f0-9-]{36}$/.test(server?.id ?? '') || typeof server.url !== 'string' || !Array.isArray(server.models)) continue;
    runtime.registerProvider(server.id, {
      name: new URL(server.url).host, baseUrl: server.url, api: 'openai-responses', authHeader: true,
      models: server.models.map(id => ({ id, name: id, reasoning: false, input: ['text'],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 16384, maxTokens: 4096 })),
    });
  }
}

// Checks a model server: its catalog, then a tiny unsaved Responses turn.
export async function probeLocalServer(address, key) {
  let url;
  try { url = new URL(String(address ?? '').trim()); } catch { throw new Error('Enter a full server URL, such as http://localhost:32100/v1.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error('Use an HTTP or HTTPS URL without embedded credentials, query parameters, or fragments.');
  }
  url.pathname = url.pathname.replace(/\/+$/, '') || '/v1';
  const base = url.href.replace(/\/$/, '');
  if (typeof key !== 'string' || !key.trim() || /[\r\n]/.test(key)) throw new Error('Enter the server API key.');
  async function request(path, body) {
    let response;
    try {
      response = await fetch(base + path, { method: body ? 'POST' : 'GET', redirect: 'error', signal: AbortSignal.timeout(20000),
        headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
    } catch { throw new Error('The server could not be reached. Check the URL, server, and Tailscale connection. Redirects are not followed.'); }
    if ([401, 403].includes(response.status)) throw new Error('The server rejected this API key. Check the key and its permissions.');
    if (response.status === 404) throw new Error(`The server does not expose ${path}. Use an OpenAI Responses-compatible server URL ending in /v1.`);
    if (!response.ok) throw new Error(`The server returned HTTP ${response.status} for ${path}. Check that its model is loaded and the Responses API is enabled.`);
    try { return await response.json(); } catch { throw new Error('The server did not return an OpenAI-compatible JSON response.'); }
  }
  const listed = await request('/models');
  const models = Array.isArray(listed?.data) ? [...new Set(listed.data.map(model => model?.id).filter(id => typeof id === 'string' && id && id.length <= 256))] : [];
  if (!models.length || models.length > 1000) throw new Error('The server did not return a usable model catalog. Load a model and reconnect.');
  const reply = await request('/responses', { model: models[0], input: 'Reply OK.', max_output_tokens: 1, store: false, stream: false });
  if (reply?.object !== 'response' || !Array.isArray(reply.output) || !['completed', 'incomplete'].includes(reply.status)) {
    throw new Error('The server listed models but did not complete a compatible Responses API check.');
  }
  return { url: base, models };
}

export const modelReference = model => `${model.provider}/${model.id}`;

// The models Pi Durable's settings offer, from those available: the enabled
// providers' models (a model server's always) that are listed, the default first
// (every one when none is listed).
export function offeredModels(available, settings = {}) {
  const providers = Array.isArray(settings.providers) ? new Set(settings.providers) : undefined;
  const enabled = providers ? available.filter(model => providers.has(model.provider) || model.provider.startsWith('local-server-')) : available;
  const listed = [settings.defaultModel, ...(Array.isArray(settings.models) ? settings.models : [])].filter(Boolean);
  if (!listed.length) return enabled;
  const byReference = new Map(enabled.map(model => [modelReference(model), model]));
  const offered = [...new Set(listed)].map(reference => byReference.get(reference)).filter(Boolean);
  return offered.length ? offered : enabled;
}

// Every model of the providers the credentials reach, for the settings' catalog.
export async function catalog(models, { refresh = false } = {}) {
  if (refresh) await refreshCatalogs(models);
  return (await availableModels(models)).map(model => ({
    id: modelReference(model), name: model.name ?? model.id, provider: model.provider,
    providerName: models.runtime.getProvider(model.provider)?.name ?? model.provider,
  }));
}
export const thinkingLevels = model => model ? getSupportedThinkingLevels(model) : [];
