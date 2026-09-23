import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { mkdir, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import lockfile from 'proper-lockfile';
import { readJSON, writePrivateJSON } from './config.mjs';

// Only the Mac persists the key. Every new helper starts sealed.
export class CredentialVault {
  constructor(directory) { this.directory = directory; this.path = join(directory, 'credentials.enc.json'); }
  get unlocked() { return Boolean(this.key); }
  seal() { this.key?.fill(0); this.key = undefined; this.workspace = undefined; }
  async unlock(workspace, encodedKey) {
    if (typeof workspace !== 'string' || !/^[a-z0-9-]{1,64}$/i.test(workspace) || typeof encodedKey !== 'string') throw new Error('Invalid credential unlock request.');
    const key = Buffer.from(encodedKey, 'base64');
    if (key.length !== 32) throw new Error('Invalid credential unlock key.');
    // Validate with a separate candidate: a rejected unlock must never expose
    // an unverified key to a running session, even while disk I/O is pending.
    const candidate = new CredentialVault(this.directory);
    candidate.key = key; candidate.workspace = workspace;
    try {
      await candidate.modify(async value => {
        // Migrate only Built-in-owned stores, never external harness auth.
        const config = await readJSON(join(this.directory, 'configuration.json'));
        const owned = await readJSON(join(this.directory, 'oauth.json'));
        return { shared: sharedCredentials(config.credentials), owned, ...value };
      });
      const config = await readJSON(join(this.directory, 'configuration.json'));
      if ('credentials' in config) await writePrivateJSON(join(this.directory, 'configuration.json'), { config: config.config });
      await unlink(join(this.directory, 'oauth.json')).catch(e => { if (e.code !== 'ENOENT') throw e; });
      this.key?.fill(0);
      this.key = key; this.workspace = workspace;
    } catch (e) { key.fill(0); throw e; }
  }
  async read() {
    if (!this.key) throw Object.assign(new Error('Built-in credentials are locked. Reconnect Woven Matter to unlock this workspace.'), { statusCode: 423 });
    const stored = await readJSON(this.path, null);
    if (!stored) return {};
    try {
      if (stored.version !== 1 || stored.workspace !== this.workspace) throw new Error();
      const nonce = Buffer.from(stored.nonce, 'base64'), tag = Buffer.from(stored.tag, 'base64');
      if (nonce.length !== 12 || tag.length !== 16) throw new Error();
      const decipher = createDecipheriv('aes-256-gcm', this.key, nonce);
      decipher.setAAD(Buffer.from('wovenmatter/default-agent/v1/' + this.workspace));
      decipher.setAuthTag(tag);
      return JSON.parse(Buffer.concat([decipher.update(Buffer.from(stored.data, 'base64')), decipher.final()]).toString('utf8'));
    } catch { throw new Error('Built-in credential store could not be decrypted. Check the workspace key or reset its credentials.'); }
  }
  async modify(fn) {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const release = await lockfile.lock(this.path, { realpath: false, retries: { retries: 60, minTimeout: 50, maxTimeout: 500 }, stale: 60000 });
    try {
      const next = await fn(await this.read());
      const nonce = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', this.key, nonce);
      cipher.setAAD(Buffer.from('wovenmatter/default-agent/v1/' + this.workspace));
      const data = Buffer.concat([cipher.update(JSON.stringify(next), 'utf8'), cipher.final()]);
      await writePrivateJSON(this.path, { version: 1, workspace: this.workspace, nonce: nonce.toString('base64'), tag: cipher.getAuthTag().toString('base64'), data: data.toString('base64') });
      return next;
    } finally { await release(); }
  }
}

export function sharedCredentials(input = {}) {
  const result = {};
  for (const id of ['openai', 'anthropic', 'xai-api', 'openrouter', 'opencode-go', 'exa', ...Object.keys(input).filter(id => /^local-server-[a-f0-9-]{36}$/.test(id)).slice(0, 12)]) {
    if (input[id]?.type === 'api_key' && typeof input[id].key === 'string') result[id] = { type: 'api_key', key: input[id].key };
  }
  for (const id of ['openai-codex', 'xai']) {
    const c = input[id];
    if (c?.type === 'oauth' && typeof c.access === 'string' && Number.isFinite(c.expires)) {
      result[id] = { type: 'oauth', access: c.access, expires: c.expires, refresh: '', borrowed: true,
        ...(typeof c.accountId === 'string' ? { accountId: c.accountId } : {}),
        ...(typeof c.displayName === 'string' ? { displayName: c.displayName } : {}) };
    }
  }
  // Only the native profile identifier is shared; Claude keeps its own tokens.
  const native = input['claude-subscription'];
  if (native?.type === 'native' && typeof native.accountId === 'string' && /^[a-zA-Z0-9-]{1,64}$/.test(native.accountId)) {
    result['claude-subscription'] = { type: 'native', accountId: native.accountId };
  }
  return result;
}

// Account ordering and credentials are encrypted alongside the canonical slot.
export function sharedAccounts(input = {}) {
  const result = {};
  for (const provider of ['openai', 'openai-codex', 'anthropic', 'xai', 'xai-api', 'openrouter', 'opencode-go', 'exa']) {
    if (!Array.isArray(input[provider])) continue;
    const entries = input[provider].slice(0, 4).flatMap(account => {
      const credential = sharedCredentials({ [provider]: account?.credential })[provider];
      return credential && typeof account.id === 'string' && typeof account.label === 'string'
        ? [{ id: account.id, label: account.label, credential }] : [];
    });
    if (entries.length) result[provider] = entries;
  }
  // Native profile names are identifiers, never native token material.
  for (const provider of ['claude-subscription', 'cursor']) {
    if (!Array.isArray(input[provider])) continue;
    result[provider] = input[provider].slice(0, 4).filter(a => typeof a.id === 'string' && typeof a.label === 'string' && a.credential?.type === 'native' && typeof a.credential.accountId === 'string')
      .map(a => ({ id: a.id, label: a.label, credential: { type: 'native', accountId: a.credential.accountId } }));
  }
  return result;
}
