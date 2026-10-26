import { mkdir, open, readFile, rename, unlink } from 'node:fs/promises';
import { dirname } from 'node:path';
import { localServers } from './local-servers.mjs';

export const providers = ['openai-codex', 'openai', 'openrouter', 'opencode-go', 'xai', 'xai-api', 'claude-subscription', 'anthropic'];
export const providerNames = { 'openai-codex': 'OpenAI · ChatGPT subscription', openai: 'OpenAI · API key', openrouter: 'OpenRouter', 'opencode-go': 'OpenCode Go', xai: 'Grok subscription', 'xai-api': 'xAI · API key', 'claude-subscription': 'Claude · Subscription', anthropic: 'Claude · API key' };
export const emptyConfig = { providers, models: [], defaultModel: null, fallbackModels: [], searchProvider: 'exa', codeMode: 'on', subagentConcurrency: 8 };

// Only app-authored messages may cross the helper boundary. SDK/provider
// exceptions can include response bodies, URLs, or credentials.
export class DefaultAgentError extends Error {}
export function operationErrorMessage(error) {
  return error instanceof DefaultAgentError ? error.message
    : 'Pi Durable could not complete this operation. Check its connections and workspace unlock state in Settings → Pi Durable.';
}

// Only fixed, app-authored diagnostics cross the provider/native-state boundary.
// Never include response bodies, request URLs, headers or exception text.
export function providerFailure(statusOrMessage) {
  const messages = {
    400: 'The provider rejected the model request (HTTP 400).',
    403: 'The connection does not have access to this model (HTTP 403).',
    404: 'The provider could not find the selected model or endpoint (HTTP 404). Refresh models in Settings → Pi Durable.',
    408: 'The provider timed out while processing the model request (HTTP 408). Try again.',
    422: 'The provider rejected the model request (HTTP 422).',
    429: 'The provider is rate limiting this connection (HTTP 429). Wait and try again.',
  };
  if (typeof statusOrMessage === 'string') {
    return Object.values(messages).includes(statusOrMessage) || statusOrMessage === 'The provider is temporarily unavailable (HTTP 5xx). Try again.'
      ? statusOrMessage : null;
  }
  return messages[statusOrMessage] ?? (Number.isInteger(statusOrMessage) && statusOrMessage >= 500 && statusOrMessage <= 599
    ? 'The provider is temporarily unavailable (HTTP 5xx). Try again.' : null);
}
export async function readJSON(path, fallback = {}) {
  try { return JSON.parse(await readFile(path, 'utf8')); } catch (e) { if (e.code === 'ENOENT') return fallback; throw e; }
}
export async function writePrivateJSON(path, value) {
  await mkdir(dirname(path), { recursive: true, mode: 0o700 });
  const temporary = `${path}.${process.pid}.${crypto.randomUUID()}.tmp`;
  try {
    const file = await open(temporary, 'wx', 0o600);
    try { await file.writeFile(JSON.stringify(value)); await file.sync(); }
    finally { await file.close(); }
    await rename(temporary, path);
    const directory = await open(dirname(path), 'r');
    try { await directory.sync(); } finally { await directory.close(); }
  } finally {
    await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
}
export function validateConfig(input) {
  if (!input || typeof input !== 'object') throw new Error('Invalid Pi Durable settings.');
  const uniqueStrings = (value) => Array.isArray(value) && value.length <= 2000 && value.every(v => typeof v === 'string' && v.length < 512) ? [...new Set(value)] : [];
  const customServers = localServers(input.customServers);
  const supported = [...providers, ...customServers.map(s => s.id)];
  return { customServers, providers: uniqueStrings(input.providers ?? providers).filter(p => supported.includes(p)),
    models: uniqueStrings(input.models), defaultModel: typeof input.defaultModel === 'string' ? input.defaultModel : null,
    fallbackModels: uniqueStrings(input.fallbackModels), searchProvider: 'exa', codeMode: ['on', 'only', 'off'].includes(input.codeMode) ? input.codeMode : 'on',
    subagentConcurrency: Number.isInteger(input.subagentConcurrency) && input.subagentConcurrency >= 2 && input.subagentConcurrency <= 24 ? input.subagentConcurrency : 8 };
}
// Deliberately excludes generic 429s, transport failures and ambiguous permission errors.
export function accessFailure(error) {
  const text = String(error?.message ?? error ?? '').toLowerCase();
  // Safe assistant diagnostics pass this boundary again after native storage.
  // Recognize our exact classifications without widening SDK error matching.
  if (text === 'the connection has exhausted its available usage.') return 'The connection has exhausted its available usage.';
  if (text === 'the connection needs sign-in or a valid api key.') return 'The connection needs sign-in or a valid API key.';
  if (/insufficient_quota|usage_limit_reached|usage_not_included|monthly usage limit reached|out of budget|credit_balance|credits? (?:exhausted|depleted)|insufficient (?:credits|balance)|quota (?:exceeded|exhausted)|subscription.*(?:expired|exhausted)|payment.required|\b402\b/.test(text)) return 'The connection has exhausted its available usage.';
  if (/invalid_api_key|invalid_grant|token_expired|unauthorized|\b401\b|not authenticated|not signed in|not logged in|no api key|no credentials|authentication required|refresh.*(?:failed|invalid)|token.*(?:revoked|expired)/.test(text)) return 'The connection needs sign-in or a valid API key.';
  return null;
}
export function modelRef(model) { return `${model.provider}/${model.id}`; }
