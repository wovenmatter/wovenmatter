import { join } from 'node:path';
import { readJSON, writePrivateJSON } from './config.mjs';
import { tokenAccount } from './provider-compaction.mjs';

// Faster inference is a subscription route choice, not a different model. The
// selector carries it as a variant of the model reference (`provider/id#fast`),
// like other selectable model variants, so every client and remote workspace
// round-trips it without a separate session option.
export const speedProviders = new Set(['claude-subscription', 'openai-codex']);
const speeds = { fast: 'Fast', ultrafast: 'Ultrafast' };

export function splitSpeedReference(reference) {
  const index = typeof reference === 'string' ? reference.lastIndexOf('#') : -1;
  if (index < 0) return { reference, speed: undefined };
  const base = reference.slice(0, index), speed = reference.slice(index + 1);
  if (!Object.hasOwn(speeds, speed) || !speedProviders.has(base.split('/')[0])) return { reference, speed: undefined };
  return { reference: base, speed };
}

export const speedReference = (reference, speed) => speed ? `${reference}#${speed}` : reference;

// Claude owns subscription eligibility, extra-usage billing and rate-limit
// cooldown. Woven only opts the bundled runtime in for models it reports.
export function claudeSpeeds(claude, model) {
  if (model?.provider !== 'claude-subscription') return [];
  return claude.models.some(entry => entry.value === model.id && entry.supportsFastMode === true)
    ? [{ id: 'fast', name: speeds.fast }] : [];
}

// The ChatGPT Codex catalog advertises each account's service tiers per model.
// Plans differ (Ultrafast is plan- and model-gated), so never infer tiers from
// the public model catalog. Tier ids are Codex request values.
const codexModelsURL = 'https://chatgpt.com/backend-api/codex/models';
// The Codex catalog filters models by client release. Refresh with the
// current Codex CLI release during dependency maintenance.
export const codexCatalogClientVersion = '0.169.0';
const refreshInterval = 60 * 60 * 1000;
const byteLimit = 4 * 1024 * 1024;
const text = (value, limit) => typeof value === 'string' && value.length > 0 && value.length <= limit && !/[\x00-\x1f\x7f]/u.test(value) ? value : undefined;
const codexSpeed = id => ({ priority: 'fast', fast: 'fast', ultrafast: 'ultrafast' })[id];

export function parseCodexServiceTiers(value) {
  if (!value || !Array.isArray(value.models) || value.models.length > 4096) throw new Error('Invalid Codex model catalog.');
  const models = {};
  for (const entry of value.models) {
    const slug = text(entry?.slug, 512);
    if (!slug || !Array.isArray(entry.service_tiers)) continue;
    const tiers = [];
    for (const tier of entry.service_tiers.slice(0, 16)) {
      const id = text(tier?.id, 64), speed = codexSpeed(id);
      if (!speed || tiers.some(existing => existing.id === speed)) continue;
      tiers.push({ id: speed, tier: id, name: text(tier.name, 64) ?? speeds[speed], ...(text(tier.description, 512) ? { description: tier.description } : {}) });
    }
    if (tiers.length) models[slug] = tiers.sort((a, b) => Object.keys(speeds).indexOf(a.id) - Object.keys(speeds).indexOf(b.id));
  }
  return models;
}

export class CodexServiceTiers {
  constructor(directory, { fetcher = globalThis.fetch } = {}) {
    this.file = join(directory, 'codex-service-tiers.json'); this.fetcher = fetcher;
    this.entry = undefined; this.loaded = false; this.pending = undefined;
  }
  async load() {
    if (this.loaded) return;
    this.loaded = true;
    const saved = await readJSON(this.file, null).catch(() => null);
    if (saved && text(saved.account, 512) && Number.isFinite(saved.checkedAt) && saved.models && typeof saved.models === 'object') this.entry = saved;
  }
  speeds(model) {
    if (model?.provider !== 'openai-codex') return [];
    return structuredClone(this.entry?.models?.[model.id] ?? []);
  }
  tier(model, speed) { return this.speeds(model).find(entry => entry.id === speed)?.tier; }
  // `auth` is the selected ChatGPT credential's resolved route. Only its
  // non-secret account claim is persisted with the advertised tiers.
  async refresh(auth, { signal, force = false } = {}) {
    await this.load();
    const token = auth?.apiKey, account = token ? tokenAccount(token) : undefined;
    if (!account) return;
    // Another account's tiers never describe this one, even while offline.
    if (this.entry && this.entry.account !== account) this.entry = undefined;
    if (!force && this.entry?.account === account && Date.now() >= this.entry.checkedAt && Date.now() - this.entry.checkedAt < refreshInterval) return;
    if (this.pending) return this.pending;
    this.pending = (async () => {
      const response = await this.fetcher(`${codexModelsURL}?client_version=${codexCatalogClientVersion}`, {
        headers: { Authorization: `Bearer ${token}`, 'chatgpt-account-id': account, originator: 'pi', accept: 'application/json' },
        credentials: 'omit', redirect: 'error', signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(15000)]) : AbortSignal.timeout(15000),
      });
      if (response.status !== 200 || Number(response.headers.get('content-length')) > byteLimit) { await response.body?.cancel(); throw new Error('Codex model catalog unavailable.'); }
      const chunks = []; let length = 0;
      for await (const chunk of response.body) {
        length += chunk.length;
        if (length > byteLimit) throw new Error('Codex model catalog too large.');
        chunks.push(Buffer.from(chunk));
      }
      const entry = { account, checkedAt: Date.now(), models: parseCodexServiceTiers(JSON.parse(Buffer.concat(chunks).toString('utf8'))) };
      await writePrivateJSON(this.file, entry);
      this.entry = entry;
    })().finally(() => { this.pending = undefined; });
    return this.pending;
  }
}

// Apply the root conversation's selected speed at the provider boundary. An
// unadvertised speed is not sent; the provider serves the request normally.
export function withSpeed(model, options, { speed, claude, codexTiers }) {
  if (!speed) return options;
  if (model.provider === 'claude-subscription') {
    return claudeSpeeds(claude, model).some(entry => entry.id === speed) ? { ...options, wovenSpeed: speed } : options;
  }
  const tier = model.provider === 'openai-codex' && model.api === 'openai-codex-responses' ? codexTiers.tier(model, speed) : undefined;
  if (!tier) return options;
  // Pi's streamSimple drops serviceTier; set it on the Responses payload.
  const prior = options.onPayload;
  return { ...options, async onPayload(payload, requestedModel) {
    const changed = await prior?.(payload, requestedModel);
    return { ...(changed === undefined ? payload : changed), service_tier: tier };
  } };
}
