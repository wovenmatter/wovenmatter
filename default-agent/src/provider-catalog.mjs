import { open, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import { VERSION } from '@earendil-works/pi-coding-agent';
import { DefaultAgentError, writePrivateJSON } from './config.mjs';

export const refreshInterval = 4 * 60 * 60 * 1000;
const byteLimit = 4 * 1024 * 1024;
// Fixed protocol policy; never downloaded and never a model inventory.
export const providerEndpoints = {
  openai: { 'openai-responses': 'https://api.openai.com/v1' },
  'openai-codex': { 'openai-codex-responses': 'https://chatgpt.com/backend-api' },
  openrouter: { 'openai-completions': 'https://openrouter.ai/api/v1', 'anthropic-messages': 'https://openrouter.ai/api' },
  'opencode-go': { 'openai-completions': 'https://opencode.ai/zen/go/v1', 'openai-responses': 'https://opencode.ai/zen/go/v1', 'anthropic-messages': 'https://opencode.ai/zen/go' },
  xai: { 'openai-responses': 'https://api.x.ai/v1' },
  'xai-api': { 'openai-responses': 'https://api.x.ai/v1' },
};
const invalid = () => new DefaultAgentError('The provider returned invalid model metadata. Refresh models to retry.');
const id = value => typeof value === 'string' && value.length > 0 && Buffer.byteLength(value) <= 512 && !/[\x00-\x1f\x7f]/u.test(value);
const validator = value => typeof value === 'string' && value.length <= 1024 && !/[\r\n]/u.test(value) ? value : undefined;
export function validatePublicModel(model, provider = model?.provider) {
  if (!model || model.provider !== provider || !id(model.id) || !id(model.name)
      || ![undefined, 'chat'].includes(model.type) || !providerEndpoints[provider]?.[model.api]
      || model.baseUrl !== providerEndpoints[provider][model.api] || model.headers !== undefined
      || !Number.isSafeInteger(model.contextWindow) || model.contextWindow <= 0 || model.contextWindow > 100_000_000
      || !Number.isSafeInteger(model.maxTokens) || model.maxTokens <= 0 || model.maxTokens > 100_000_000
      || typeof model.reasoning !== 'boolean' || !Array.isArray(model.input) || !model.input.includes('text')
      || model.input.some(value => !['text', 'image'].includes(value)) || Buffer.byteLength(JSON.stringify(model)) > 65536) throw invalid();
  function numbers(value) {
    if (typeof value === 'number') { if (!Number.isFinite(value) || value < 0) throw invalid(); }
    else if (value && typeof value === 'object') { for (const nested of Object.values(value)) numbers(nested); }
    else throw invalid();
  }
  if (!model.cost || typeof model.cost !== 'object' || Array.isArray(model.cost)) throw invalid();
  numbers(model.cost);
  return model;
}
export function parseProviderModels(value, provider) {
  const entries = Array.isArray(value) ? value : value && typeof value === 'object' ? value.models ?? Object.values(value) : undefined;
  if (!Array.isArray(entries) || entries.length > 4096) throw invalid();
  const source = provider === 'xai-api' ? 'xai' : provider, seen = new Set(), models = [];
  for (const entry of entries) {
    if (!entry || entry.provider !== source) throw invalid();
    if (![undefined, 'chat'].includes(entry.type)) continue;
    if (!providerEndpoints[provider]?.[entry.api]) continue;
    const model = validatePublicModel({ ...entry, provider }, provider);
    if (seen.has(model.id)) throw invalid();
    seen.add(model.id); models.push(model);
  }
  if (!models.length) throw new DefaultAgentError('No supported chat models were returned. Refresh models to retry.');
  return models;
}

/** Implements Pi's public ModelsStore, with one bounded, version-aware provider file. */
export class ProviderCatalog {
  constructor(directory, { fetchCatalog = globalThis.fetch, now = Date.now, version = VERSION } = {}) {
    this.directory = join(directory, 'provider-models'); this.fetchCatalog = fetchCatalog; this.now = now; this.version = version;
    this.entries = new Map();
  }
  path(provider) {
    if (!Object.hasOwn(providerEndpoints, provider)) throw invalid();
    return join(this.directory, provider + '.json');
  }
  async read(provider, { signal } = {}) {
    signal?.throwIfAborted();
    if (this.entries.has(provider)) return structuredClone(this.entries.get(provider));
    let file;
    try {
      file = await open(this.path(provider), 'r');
      const info = await file.stat();
      if (!info.isFile() || info.size > byteLimit) return undefined;
      const buffer = Buffer.alloc(byteLimit + 1);
      const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
      if (bytesRead > byteLimit) return undefined;
      const saved = JSON.parse(buffer.subarray(0, bytesRead));
      if (saved.piVersion !== this.version || !Number.isFinite(saved.checkedAt) || !Array.isArray(saved.models) || !saved.models.length || saved.models.length > 4096 || new Set(saved.models.map(model => model.id)).size !== saved.models.length) return undefined;
      for (const model of saved.models) validatePublicModel(model, provider);
      signal?.throwIfAborted();
      this.entries.set(provider, saved);
      return structuredClone(saved);
    } catch (error) { signal?.throwIfAborted(); return undefined; }
    finally { await file?.close(); }
  }
  async write(provider, entry, { signal } = {}) {
    for (const model of entry.models) validatePublicModel(model, provider);
    const value = { ...entry, piVersion: this.version };
    if (Buffer.byteLength(JSON.stringify(value)) > byteLimit) throw invalid();
    signal?.throwIfAborted();
    await writePrivateJSON(this.path(provider), value);
    this.entries.set(provider, structuredClone(value));
  }
  async delete(provider, { signal } = {}) {
    signal?.throwIfAborted();
    await unlink(this.path(provider)).catch(error => { if (error.code !== 'ENOENT') throw error; });
    this.entries.delete(provider);
  }
  async load(provider, { signal, force = false } = {}) {
    signal?.throwIfAborted();
    const saved = await this.read(provider, { signal });
    if (!force && saved && this.now() >= saved.checkedAt && this.now() - saved.checkedAt < refreshInterval) return saved;
    const source = provider === 'xai-api' ? 'xai' : provider;
    this.path(provider);
    const response = await this.fetchCatalog(`https://pi.dev/api/models/providers/${source}?types=chat`, {
      headers: { accept: 'application/json', 'User-Agent': `pi/${this.version}`,
        ...(saved && validator(saved.etag) ? { 'If-None-Match': saved.etag } : {}),
        ...(saved && validator(saved.lastModifiedHeader) ? { 'If-Modified-Since': saved.lastModifiedHeader } : {}) },
      credentials: 'omit', redirect: 'error', signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000),
    });
    signal?.throwIfAborted();
    let entry;
    if (response.status === 304 && saved) entry = { ...saved, checkedAt: this.now() };
    else {
      if (response.status !== 200) throw new DefaultAgentError('Models could not be loaded. Refresh models to retry.');
      if (Number(response.headers.get('content-length')) > byteLimit) { await response.body?.cancel(); throw invalid(); }
      const chunks = []; let length = 0;
      for await (const chunk of response.body) {
        signal?.throwIfAborted(); length += chunk.length;
        if (length > byteLimit) throw invalid();
        chunks.push(Buffer.from(chunk));
      }
      const models = parseProviderModels(JSON.parse(Buffer.concat(chunks).toString('utf8')), provider);
      const lastModifiedHeader = validator(response.headers.get('last-modified'));
      entry = { models, checkedAt: this.now(), etag: validator(response.headers.get('etag')), lastModifiedHeader,
        ...(Number.isFinite(Date.parse(lastModifiedHeader)) ? { lastModified: Date.parse(lastModifiedHeader) } : {}) };
    }
    signal?.throwIfAborted();
    await this.write(provider, entry, { signal });
    return structuredClone(entry);
  }
}

/** Keep SDK auth/stream implementations, replacing only their bundled inventory and refresher. */
export function installPublicCatalog(runtime) {
  const installed = new Map();
  for (const id of Object.keys(providerEndpoints).filter(id => id !== 'xai-api')) {
    const original = runtime.getProvider(id);
    const provider = { ...original, getModels: () => [], getAllModels: () => [], refreshModels: undefined };
    runtime.registerNativeProvider(provider);
    installed.set(provider.id, provider);
  }
  const xai = installed.get('xai');
  const api = { ...xai, id: 'xai-api', name: 'xAI API key', auth: { apiKey: xai.auth.apiKey } };
  runtime.registerNativeProvider(api); installed.set(api.id, api);
  return (provider, models) => {
    const base = installed.get(provider);
    if (!base) throw invalid();
    for (const model of models) validatePublicModel(model, provider);
    const snapshot = structuredClone(models);
    runtime.registerNativeProvider({ ...base, getModels: () => snapshot, getAllModels: () => snapshot });
  };
}
