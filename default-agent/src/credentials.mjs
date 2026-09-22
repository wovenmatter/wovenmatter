import { AsyncLocalStorage } from 'node:async_hooks';
import { InMemoryCredentialStore } from '@earendil-works/pi-ai';
import { providers } from './config.mjs';

// Local sessions use access-only credentials supplied over private IPC. Only
// control operations own local refresh tokens; their results go back to Keychain.
export class Credentials extends InMemoryCredentialStore {
  constructor(supplied = {}, vault, accounts = {}) { super(); this.supplied = supplied; this.vault = vault; this.owned = {}; this.accounts = accounts; this.context = new AsyncLocalStorage(); }
  async initialize() { return this; }
  async replace(supplied, accounts) { this.supplied = supplied; if (accounts) this.accounts = accounts; }
  async candidates(provider) {
    const vault = this.vault ? await this.vault.read() : undefined;
    const entries = (vault ? vault.accounts : this.accounts)?.[provider] ?? [];
    const owned = vault?.owned?.[provider] ?? this.owned[provider];
    if (owned) return [{ id: 'default', label: 'Workspace account', credential: owned }, ...entries];
    return entries.length ? entries : [{ id: 'default', label: 'Current account', credential: await this.read(provider) }];
  }
  runWithAccount(provider, account, operation) { return this.context.run({ provider, id: account.id, fallback: account.credential }, operation); }
  async read(provider) {
    const context = this.context.getStore();
    if (context?.provider === provider && context.id !== 'default') {
      const accounts = this.vault ? (await this.vault.read()).accounts : this.accounts;
      return accounts?.[provider]?.find(a => a.id === context.id)?.credential;
    }
    const stored = this.vault ? await this.vault.read() : { shared: this.supplied, owned: this.owned };
    return stored.owned?.[provider] ?? stored.shared?.[provider] ?? stored.accounts?.[provider]?.[0]?.credential;
  }
  async list() {
    const stored = this.vault ? await this.vault.read() : { shared: this.supplied, owned: this.owned };
    const custom = Object.keys({ ...stored.shared, ...stored.owned }).filter(id => /^local-server-[a-f0-9-]{36}$/.test(id));
    const values = await Promise.all([...providers, ...custom].map(async providerId => {
      const credential = await this.read(providerId);
      return credential ? { providerId, type: credential.type } : null;
    }));
    return values.filter(Boolean);
  }
  async delete(provider) {
    if (this.vault) await this.vault.modify(async stored => { const owned = { ...stored.owned }; delete owned[provider]; return { ...stored, owned }; });
    else { delete this.owned[provider]; delete this.supplied[provider]; }
  }
  async modify(provider, fn, options) {
    return super.modify(provider, async () => {
      let next;
      const update = async stored => {
        const current = stored.owned?.[provider] ?? stored.shared?.[provider];
        if (!this.signingIn && current?.borrowed) throw new Error('Authentication required. Reconnect Woven Matter or sign in in Settings → Connections.');
        next = await fn(current) ?? current;
        if (!this.signingIn && next && current?.displayName && !next.displayName) next = { ...next, displayName: current.displayName };
        return { ...stored, owned: { ...stored.owned, ...(next ? { [provider]: next } : {}) } };
      };
      if (this.vault) await this.vault.modify(update);
      else { const stored = await update({ shared: this.supplied, owned: this.owned }); this.owned = stored.owned; }
      return next;
    }, options);
  }
}
