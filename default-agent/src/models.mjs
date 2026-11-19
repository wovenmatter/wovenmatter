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

export const modelReference = model => `${model.provider}/${model.id}`;
export const thinkingLevels = model => model ? getSupportedThinkingLevels(model) : [];
