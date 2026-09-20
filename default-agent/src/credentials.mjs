import { homedir } from 'node:os';
import { join } from 'node:path';
import lockfile from 'proper-lockfile';
import { InMemoryCredentialStore } from '@earendil-works/pi-ai';
import { readJSON, writePrivateJSON, providers } from './config.mjs';

function expiry(access) {
  try { return JSON.parse(Buffer.from(access.split('.')[1], 'base64url')).exp * 1000; } catch { return 0; }
}
// External OAuth credentials are borrowed, not refreshed here. Their owning CLI
// controls rotation; independent SDK sign-ins own and persist their refresh tokens.
export async function discoverCredentials(home = homedir()) {
  const result = {};
  const codex = await readJSON(join(process.env.CODEX_HOME ?? join(home, '.codex'), 'auth.json'));
  if (codex.tokens?.access_token) result['openai-codex'] = { type: 'oauth', access: codex.tokens.access_token, refresh: '', expires: expiry(codex.tokens.access_token), accountId: codex.tokens.account_id, borrowed: true };
  const grok = await readJSON(join(process.env.GROK_HOME ?? join(home, '.grok'), 'auth.json'));
  for (const entry of Object.values(grok)) {
    if (!entry || typeof entry !== 'object') continue;
    const access = entry.access_token ?? entry.accessToken ?? entry.key;
    if (access) { result.xai = { type: 'oauth', access, refresh: '', expires: expiry(access), borrowed: true }; break; }
  }
  const openCode = await readJSON(join(home, '.local/share/opencode/auth.json'));
  for (const p of ['openrouter', 'opencode-go', 'openai']) if (openCode[p]?.type === 'api' && openCode[p].key) result[p] = { type: 'api_key', key: openCode[p].key };
  return result;
}
export class Credentials extends InMemoryCredentialStore {
  constructor(path, supplied = {}, discover = true) { super(); this.path = path; this.supplied = supplied; this.discover = discover; this.initializing = true; }
  async initialize() {
    const owned = await readJSON(this.path);
    const external = this.discover ? await discoverCredentials() : {};
    for (const [provider, value] of Object.entries({ ...external, ...owned, ...this.supplied })) if (providers.includes(provider) && value) await super.modify(provider, async () => value);
    this.initializing = false;
    return this;
  }
  async read(provider, options) {
    const owned = await readJSON(this.path);
    if (owned[provider]) return owned[provider];
    if (this.supplied[provider]) return this.supplied[provider];
    if (this.discover) return (await discoverCredentials())[provider];
    return super.read(provider, options);
  }
  async list() {
    const values = await Promise.all(providers.map(async providerId => {
      const credential = await this.read(providerId);
      return credential ? { providerId, type: credential.type } : null;
    }));
    return values.filter(Boolean);
  }
  async modify(provider, fn, options) {
    return super.modify(provider, async () => {
      if (this.initializing) return fn(undefined);
      // Each local conversation has a helper. Serialize refresh-token rotation
      // across helpers, and reread after locking before making a refresh request.
      const unlock = await lockfile.lock(this.path, { realpath: false, retries: { retries: 30, minTimeout: 100, maxTimeout: 500 }, stale: 60000 });
      try {
        const current = await this.read(provider, options);
        if (!this.signingIn && current?.borrowed && current.expires < Date.now() + 300000) throw new Error('Authentication required: refresh the existing sign-in in Settings → Default Agent.');
        const next = await fn(current);
        if (next && !next.borrowed && next.type === 'oauth') {
          const stored = await readJSON(this.path); stored[provider] = next; await writePrivateJSON(this.path, stored);
        }
        return next ?? current;
      } finally { await unlock(); }
    }, options);
  }
}
