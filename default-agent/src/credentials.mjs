// The server owns every credential. This process holds them in memory only,
// asks the server for them with `woven/credentials`, and reports a renewed
// OAuth credential with `woven/credentials/update` so the server can store it.

// Wire form ({type: "apiKey" | "oauth" | "native"}) to pi-ai's form and back.
export function fromWire(credential) {
  if (credential?.type === 'apiKey' && typeof credential.key === 'string') return { type: 'api_key', key: credential.key };
  if (credential?.type === 'oauth' && typeof credential.access === 'string') return { ...credential };
  if (credential?.type === 'native') return { type: 'native' };
  return undefined;
}
export function toWire(credential) {
  if (credential?.type === 'api_key') return { type: 'apiKey', key: credential.key };
  return credential ? { ...credential } : undefined;
}

const refetchAfterMs = 2000;
const expiresSoon = credential => credential?.type === 'oauth' && Number(credential.expires) <= Date.now() + 60000;

// pi-ai's CredentialStore, backed by the server.
export class ServerCredentials {
  constructor({ fetch, report }) {
    this.fetchFromServer = fetch; this.report = report;
    this.values = new Map(); this.fetchedAt = 0; this.fetching = undefined; this.chains = new Map();
  }
  async refresh() {
    this.fetching ??= (async () => {
      try {
        const reply = await this.fetchFromServer();
        this.values = new Map(Object.entries(reply?.credentials ?? {}).flatMap(([id, value]) => {
          const credential = fromWire(value);
          return credential ? [[id, credential]] : [];
        }));
        this.fetchedAt = Date.now();
      } finally { this.fetching = undefined; }
    })();
    return this.fetching;
  }
  // Ask the server at first need, and again when a credential is missing or about to expire.
  async current(providerId) {
    const value = this.values.get(providerId);
    if (!this.fetchedAt || ((!value || expiresSoon(value)) && Date.now() - this.fetchedAt > refetchAfterMs)) await this.refresh();
    return this.values.get(providerId);
  }
  async providers() {
    if (!this.fetchedAt) await this.refresh();
    return [...this.values.keys()];
  }
  has(providerId) { return this.values.has(providerId); }
  async read(providerId) {
    const value = await this.current(providerId);
    return value?.type === 'native' ? undefined : structuredClone(value);
  }
  async list() {
    if (!this.fetchedAt) await this.refresh();
    return [...this.values].filter(([, value]) => value.type !== 'native').map(([providerId, value]) => ({ providerId, type: value.type }));
  }
  modify(providerId, fn) {
    const run = async () => {
      const before = await this.read(providerId);
      const next = await fn(before);
      if (next === undefined) return before;
      this.values.set(providerId, structuredClone(next));
      if (JSON.stringify(next) !== JSON.stringify(before)) await this.report(providerId, toWire(next));
      return structuredClone(next);
    };
    const result = (this.chains.get(providerId) ?? Promise.resolve()).then(run, run);
    this.chains.set(providerId, result.catch(() => {}));
    return result;
  }
  async delete(providerId) { this.values.delete(providerId); }
}
