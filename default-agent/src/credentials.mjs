import { InMemoryCredentialStore } from '@earendil-works/pi-ai';
import { providers } from './config.mjs';

// Local sessions use access-only credentials supplied over private IPC. Only
// control operations own local refresh tokens; their results go back to Keychain.
export class Credentials extends InMemoryCredentialStore {
  constructor(supplied = {}, vault) { super(); this.supplied = supplied; this.vault = vault; this.owned = {}; }
  async initialize() { return this; }
  async replace(supplied) { this.supplied = supplied; }
  async read(provider) {
    const stored = this.vault ? await this.vault.read() : { shared: this.supplied, owned: this.owned };
    return stored.owned?.[provider] ?? stored.shared?.[provider];
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
