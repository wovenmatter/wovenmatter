import { mkdir, readFile, writeFile, rename } from 'node:fs/promises';
import { dirname } from 'node:path';
import { localServers } from './local-servers.mjs';

export const providers = ['openai-codex', 'openai', 'openrouter', 'opencode-go', 'xai'];
export const providerNames = { 'openai-codex': 'OpenAI · ChatGPT subscription', openai: 'OpenAI · API key', openrouter: 'OpenRouter', 'opencode-go': 'OpenCode Go', xai: 'Grok subscription' };
export const emptyConfig = { providers, models: [], defaultModel: null, fallbackModels: [], searchProvider: 'exa' };

// Only app-authored messages may cross the helper boundary. SDK/provider
// exceptions can include response bodies, URLs, or credentials.
export class DefaultAgentError extends Error {}
export function operationErrorMessage(error) {
  return error instanceof DefaultAgentError ? error.message
    : 'Default Agent could not complete this operation. Check its connections and workspace unlock state in Settings → Connections.';
}
export async function readJSON(path, fallback = {}) {
  try { return JSON.parse(await readFile(path, 'utf8')); } catch (e) { if (e.code === 'ENOENT') return fallback; throw e; }
}
export async function writePrivateJSON(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${crypto.randomUUID()}.tmp`;
  await writeFile(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
  await rename(temporary, path);
}
export function validateConfig(input) {
  if (!input || typeof input !== 'object') throw new Error('Invalid Default Agent settings.');
  const uniqueStrings = (value) => Array.isArray(value) && value.length <= 2000 && value.every(v => typeof v === 'string' && v.length < 512) ? [...new Set(value)] : [];
  const customServers = localServers(input.customServers);
  const supported = [...providers, ...customServers.map(s => s.id)];
  return { customServers, providers: uniqueStrings(input.providers ?? providers).filter(p => supported.includes(p)),
    models: uniqueStrings(input.models), defaultModel: typeof input.defaultModel === 'string' ? input.defaultModel : null,
    fallbackModels: uniqueStrings(input.fallbackModels), searchProvider: 'exa' };
}
// Deliberately excludes generic 429s, transport failures and ambiguous permission errors.
export function accessFailure(error) {
  const text = String(error?.message ?? error ?? '').toLowerCase();
  if (/insufficient_quota|usage_limit_reached|usage_not_included|monthly usage limit reached|out of budget|credit_balance|credits? (?:exhausted|depleted)|insufficient (?:credits|balance)|quota (?:exceeded|exhausted)|subscription.*(?:expired|exhausted)|payment.required|\b402\b/.test(text)) return 'The connection has exhausted its available usage.';
  if (/invalid_api_key|invalid_grant|token_expired|unauthorized|\b401\b|not authenticated|not signed in|no api key|no credentials|authentication required|refresh.*(?:failed|invalid)|token.*(?:revoked|expired)/.test(text)) return 'The connection needs sign-in or a valid API key.';
  return null;
}
export function modelRef(model) { return `${model.provider}/${model.id}`; }
