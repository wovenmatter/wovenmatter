import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { constants } from 'node:fs';
import { link, mkdir, open, readdir, rename, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import lockfile from 'proper-lockfile';
import { readJSON, searchProviderNames, writePrivateJSON } from './config.mjs';

// The workspace that names a device-owned vault (`openDevice`).
export const deviceVaultWorkspace = 'device';
// A host stores and renews its own sign-ins: the Linux server and its
// helpers open the vault with this device's own key (`openDevice`). The
// older `unlock` (a key held by a Mac) remains for tests and older callers.
export const deviceVaultEnabled = (environment = process.env) => environment.WOVEN_DEFAULT_AGENT_DEVICE_VAULT === '1';

// Hard links are missing on some file systems (FUSE, SMB, NFS); there the
// fallbacks below are used, and none of them follows a link. Replaceable in tests.
export const vaultFiles = { link };
const linksUnsupported = error => ['EPERM', 'ENOTSUP', 'EOPNOTSUPP', 'ENOSYS', 'EXDEV', 'EMLINK', 'EACCES'].includes(error?.code);
const lockOptions = { realpath: false, retries: { retries: 60, minTimeout: 50, maxTimeout: 500 }, stale: 60000 };
const missing = error => { if (error.code !== 'ENOENT') throw error; };
const apiKeyProviders = ['openai', 'anthropic', 'xai-api', 'openrouter', 'opencode-go', ...Object.keys(searchProviderNames)];
const localServerID = /^local-server-[a-f0-9-]{36}$/;

export class CredentialVault {
  constructor(directory) {
    this.directory = directory; this.path = join(directory, 'credentials.enc.json'); this.keyPath = join(directory, 'credentials.key');
  }
  // A device vault whose key is missing or does not open it reads as signed
  // out: it is never deleted, and an explicit new sign-in replaces it.
  get unlocked() { return Boolean(this.key) || this.device === true; }
  // Opens this device's own vault with the key beside it in the private
  // directory (0600, created on first use). A vault sealed with a Mac's key
  // (before sign-ins were per device) is set aside, unread, until a Mac that
  // holds its key brings its sign-ins over (`importLegacy`).
  async openDevice() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const release = await lockfile.lock(this.path, lockOptions);
    try {
      const stored = await readJSON(this.path, null).catch(() => ({ damaged: true }));
      if (stored && !stored.damaged && stored.workspace !== deviceVaultWorkspace) await setAside(this.path, 'legacy');
      let key = await readDeviceKey(this.keyPath);
      if (key === null && !(await exists(this.path))) key = await createDeviceKey(this.keyPath);
      this.device = true; this.workspace = deviceVaultWorkspace;
      this.adopt(key);
      await this.importPlaintext();
      return this;
    } finally { await release(); }
  }
  adopt(key) {
    if (this.key && key && this.key.equals(key)) { key.fill(0); return; }
    this.key?.fill(0);
    this.key = key || undefined;
  }
  // Sign-ins from before the vault (`oauth.json`, a configuration's
  // credentials) were kept in plain files; they join the device vault, and
  // the plain copies are removed only once the vault holds them.
  async importPlaintext() {
    const oauthPath = join(this.directory, 'oauth.json'), configurationPath = join(this.directory, 'configuration.json');
    const owned = await readJSON(oauthPath, null).catch(() => null);
    const configuration = await readJSON(configurationPath, {}).catch(() => ({}));
    if (!owned && !('credentials' in configuration)) return;
    const incoming = { owned: ownedSignIns(owned ?? {}), shared: sharedCredentials(configuration.credentials ?? {}) };
    if (Object.keys(incoming.owned).length || Object.keys(incoming.shared).length) {
      await this.modifyLocked(async stored => mergeLegacy(stored, incoming, configuration.config));
    }
    if (owned) await unlink(oauthPath).catch(missing);
    if ('credentials' in configuration) await writePrivateJSON(configurationPath, { config: configuration.config });
  }
  // Whether a vault sealed with a Mac's key is waiting for that Mac: not once
  // this device has signed in to anything itself, and not after a Mac's key
  // failed to open it (the file stays on disk either way).
  async legacyPending() {
    if (!(await legacyFiles(this.directory)).length) return false;
    const stored = await this.read().catch(() => ({}));
    const own = Object.keys(stored.owned ?? {}).length || Object.values(stored.accounts ?? {}).some(list => list?.length) || (stored.servers ?? []).length;
    return !own;
  }
  // A control session's `reset`: this device's sign-ins are cleared, and the
  // vault as it was is kept beside it.
  async reset() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const release = await lockfile.lock(this.path, lockOptions);
    try {
      if (await exists(this.path)) await keepCopy(this.path, 'reset');
      return await this.modifyLocked(async () => ({}));
    } finally { await release(); }
  }
  // A Mac that held this workspace's key opens the set-aside vault once: its
  // own and saved sign-ins join this device's vault (a Mac's borrowed
  // subscription access does not: this device signs in itself), and the old
  // file is removed only after the device vault holds them. A wrong key
  // leaves it in place.
  async importLegacy(workspace, encodedKey) {
    if (typeof workspace !== 'string' || !/^[a-z0-9-]{1,64}$/i.test(workspace) || typeof encodedKey !== 'string') return { imported: false };
    const key = Buffer.from(encodedKey, 'base64');
    try {
      if (key.length !== 32) return { imported: false };
      let imported = false;
      for (const file of await legacyFiles(this.directory)) {
        const sealed = await readJSON(file, null).catch(() => null);
        if (sealed?.workspace !== workspace) continue;
        let value;
        try { value = decrypt(sealed, key, workspace); }
        catch {
          // That Mac's key does not open it: it stops waiting, and stays on disk.
          await rename(file, file.replace(/\.enc\.json$/, '') + '.unopened.enc.json').catch(missing);
          continue;
        }
        const configuration = await readJSON(join(this.directory, 'configuration.json'), {}).catch(() => ({}));
        const release = await lockfile.lock(this.path, lockOptions);
        try {
          await this.modifyLocked(async stored => mergeLegacy(stored, { owned: ownedSignIns(value.owned ?? {}), shared: sharedCredentials(value.shared ?? {}), accounts: sharedAccounts(value.accounts ?? {}) }, configuration.config));
        } finally { await release(); }
        await unlink(file).catch(missing);
        imported = true;
      }
      return { imported };
    } finally { key.fill(0); }
  }
  seal() { this.key?.fill(0); this.key = undefined; this.workspace = undefined; this.device = undefined; }
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
        // Migrate only Pi Durable-owned stores, never external harness auth.
        const config = await readJSON(join(this.directory, 'configuration.json'));
        const owned = await readJSON(join(this.directory, 'oauth.json'));
        return { shared: sharedCredentials(config.credentials), owned, ...value };
      });
      const config = await readJSON(join(this.directory, 'configuration.json'));
      if ('credentials' in config) await writePrivateJSON(join(this.directory, 'configuration.json'), { config: config.config });
      await unlink(join(this.directory, 'oauth.json')).catch(missing);
      this.key?.fill(0);
      this.key = key; this.workspace = workspace;
    } catch (e) { key.fill(0); throw e; }
  }
  // The device vault's key is read on every use, so a key another process of
  // this host created or replaced is the one used.
  async currentKey() {
    if (this.device) this.adopt(await readDeviceKey(this.keyPath));
    return this.key;
  }
  async read() {
    if (!this.unlocked) throw Object.assign(new Error('Pi Durable credentials are locked. Reconnect Woven Matter to unlock this workspace.'), { statusCode: 423 });
    const key = await this.currentKey();
    const stored = await readJSON(this.path, null).catch(error => { if (this.device) return { damaged: true }; throw error; });
    if (!stored) return {};
    try { return decrypt(stored, key, this.workspace); }
    catch {
      // Unreadable here (a restored or copied workspace, a damaged key): signed out.
      if (this.device) return {};
      throw new Error('Pi Durable credential store could not be decrypted. Check the workspace key or reset its credentials.');
    }
  }
  async modify(fn) {
    if (!this.unlocked) throw Object.assign(new Error('Pi Durable credentials are locked on this device.'), { statusCode: 423 });
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const release = await lockfile.lock(this.path, lockOptions);
    try { return await this.modifyLocked(fn); } finally { await release(); }
  }
  // Holding the vault lock.
  async modifyLocked(fn) {
    let current;
    if (this.device) {
      let key = await this.currentKey();
      const stored = await readJSON(this.path, null).catch(() => ({ damaged: true }));
      if (stored) {
        try { current = decrypt(stored, key, this.workspace); } catch { current = undefined; }
      } else current = {};
      if (current === undefined || !key) {
        // A sign-in made now replaces a vault this device cannot read. Both
        // the vault and its key are kept beside it, never deleted.
        if (stored) await keepCopy(this.path, 'unreadable');
        const replacing = await exists(this.keyPath);
        if (replacing) await keepCopy(this.keyPath, 'unreadable');
        key = await createDeviceKey(this.keyPath, { replacing });
        this.adopt(key);
        current = {};
      }
    } else current = await this.read();
    const next = await fn(current);
    const nonce = randomBytes(12);
    const cipher = createCipheriv('aes-256-gcm', this.key, nonce);
    cipher.setAAD(Buffer.from('wovenmatter/default-agent/v1/' + this.workspace));
    const data = Buffer.concat([cipher.update(JSON.stringify(next), 'utf8'), cipher.final()]);
    await writePrivateJSON(this.path, { version: 1, workspace: this.workspace, nonce: nonce.toString('base64'), tag: cipher.getAuthTag().toString('base64'), data: data.toString('base64') });
    return next;
  }
}

function decrypt(stored, key, workspace) {
  if (!key || stored?.version !== 1 || stored.workspace !== workspace) throw new Error('unreadable');
  const nonce = Buffer.from(stored.nonce, 'base64'), tag = Buffer.from(stored.tag, 'base64');
  if (nonce.length !== 12 || tag.length !== 16) throw new Error('unreadable');
  const decipher = createDecipheriv('aes-256-gcm', key, nonce);
  decipher.setAAD(Buffer.from('wovenmatter/default-agent/v1/' + workspace));
  decipher.setAuthTag(tag);
  return JSON.parse(Buffer.concat([decipher.update(Buffer.from(stored.data, 'base64')), decipher.final()]).toString('utf8'));
}

async function exists(path) {
  try { await open(path, constants.O_RDONLY | constants.O_NOFOLLOW).then(file => file.close()); return true; }
  catch (error) { if (error.code === 'ENOENT') return false; return true; }
}

// The key file is this user's regular file, never a link, and 0600. Its
// content is a 32-byte base64 key; anything else (`false`) is a damaged key,
// which leaves the vault signed out rather than replaced.
async function readDeviceKey(path) {
  let file;
  try { file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    if (error.code === 'ELOOP') throw new Error('The Pi Durable key on this device is a link. Remove it to sign in again.');
    throw error;
  }
  try {
    const info = await file.stat();
    if (!info.isFile() || (typeof process.getuid === 'function' && info.uid !== process.getuid())) {
      throw new Error('The Pi Durable key on this device belongs to another user. Remove it to sign in again.');
    }
    if ((info.mode & 0o777) !== 0o600) await file.chmod(0o600);
    const text = (await file.readFile('utf8')).trim();
    const key = Buffer.from(text, 'base64');
    return /^[A-Za-z0-9+/]{43}=$/.test(text) && key.length === 32 ? key : false;
  } finally { await file.close(); }
}

// Written whole to a new private file, then moved into place: another
// process sees no key, the previous key or the complete new key. A new key
// never replaces one another process created meanwhile; an unreadable key is
// replaced only after the caller kept a copy of it.
async function createDeviceKey(path, { replacing = false } = {}) {
  const key = randomBytes(32), temporary = `${path}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  try {
    const file = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { await file.writeFile(key.toString('base64')); await file.sync(); } finally { await file.close(); }
    try {
      if (replacing) await rename(temporary, path);
      else {
        try { await vaultFiles.link(temporary, path); }
        catch (error) {
          if (!linksUnsupported(error)) throw error;
          // No hard links here: create the key file itself, exclusively, never
          // through a link, with the whole key written and synced. Every
          // creator holds the vault lock, so no writer sees it half written.
          const file = await open(path, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
          try { await file.writeFile(key.toString('base64')); await file.sync(); } finally { await file.close(); }
        }
      }
    }
    catch (error) {
      if (error.code !== 'EEXIST') throw error;
      key.fill(0);
      const existing = await readDeviceKey(path);
      if (!existing) throw new Error('The Pi Durable key on this device could not be created.');
      return existing;
    }
    const directory = await open(join(path, '..'), 'r');
    try { await directory.sync(); } finally { await directory.close(); }
    return key;
  } finally { await unlink(temporary).catch(missing); }
}

const asideName = (path, reason) => `${path.replace(/\.enc\.json$|\.key$/, '')}.${reason}-${Date.now()}-${randomBytes(3).toString('hex')}${path.endsWith('.key') ? '.key' : '.enc.json'}`;
async function setAside(path, reason) { await rename(path, asideName(path, reason)); }
// A second name for the file, so replacing it in place keeps the old content;
// a whole copy where the file system has no hard links. Neither follows a link.
async function keepCopy(path, reason) {
  const aside = asideName(path, reason);
  try { await vaultFiles.link(path, aside); return; }
  catch (error) { if (!linksUnsupported(error)) throw error; }
  const source = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW);
  try {
    const data = await source.readFile();
    const copy = await open(aside, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { await copy.writeFile(data); await copy.sync(); } finally { await copy.close(); }
  } finally { await source.close(); }
}

async function legacyFiles(directory) {
  const names = await readdir(directory).catch(error => { if (error.code === 'ENOENT') return []; throw error; });
  return names.filter(name => /^credentials\.legacy-[0-9]+-[0-9a-f]{6}\.enc\.json$/.test(name)).sort().map(name => join(directory, name));
}

// A host's own subscriptions (with their refresh tokens) and local model server keys.
function ownedSignIns(input = {}) {
  const result = {};
  for (const id of ['openai-codex', 'xai']) {
    const c = input[id];
    if (c?.type === 'oauth' && !c.borrowed && typeof c.access === 'string' && typeof c.refresh === 'string' && c.refresh) result[id] = c;
  }
  const native = input['claude-subscription'];
  if (native?.type === 'native' && typeof native.accountId === 'string' && /^[a-zA-Z0-9-]{1,64}$/.test(native.accountId)) result['claude-subscription'] = { type: 'native', accountId: native.accountId };
  for (const [id, c] of Object.entries(input)) if (localServerID.test(id) && c?.type === 'api_key' && typeof c.key === 'string') result[id] = { type: 'api_key', key: c.key };
  return result;
}

// Adds what the device vault does not hold yet; nothing it holds is replaced.
function mergeLegacy(stored, { owned = {}, shared = {}, accounts = {} }, config = {}) {
  const next = { ...stored, owned: { ...stored.owned }, accounts: { ...stored.accounts }, servers: [...(stored.servers ?? [])] };
  for (const [id, credential] of Object.entries(owned)) if (!localServerID.test(id) && !next.owned[id]) next.owned[id] = credential;
  const native = shared['claude-subscription'];
  if (native && !next.owned['claude-subscription']) next.owned['claude-subscription'] = native;
  for (const provider of apiKeyProviders) {
    const list = [...(next.accounts[provider] ?? [])];
    const incoming = [...(accounts[provider] ?? []), ...(shared[provider] ? [{ id: undefined, label: undefined, credential: shared[provider] }] : [])];
    for (const entry of incoming) {
      if (entry.credential?.type !== 'api_key' || list.length >= 4 || list.some(item => item.credential?.key === entry.credential.key)) continue;
      list.push({ id: entry.id ?? crypto.randomUUID(), label: entry.label ?? `API key ${list.length + 1}`, credential: { type: 'api_key', key: entry.credential.key } });
    }
    if (list.length) next.accounts[provider] = list;
  }
  // Local model servers this workspace used: their address from its chat
  // settings, their key from the old store.
  const keys = { ...Object.fromEntries(Object.entries(shared).filter(([id]) => localServerID.test(id))), ...Object.fromEntries(Object.entries(owned).filter(([id]) => localServerID.test(id))) };
  for (const server of Array.isArray(config?.customServers) ? config.customServers : []) {
    if (!localServerID.test(server?.id) || !keys[server.id] || next.servers.length >= 12 || next.servers.some(item => item.id === server.id)) continue;
    if (typeof server.url !== 'string' || !Array.isArray(server.models)) continue;
    next.servers.push({ id: server.id, url: server.url, models: server.models.filter(model => typeof model === 'string').slice(0, 256), verifiedAt: new Date().toISOString() });
    next.owned[server.id] = keys[server.id];
  }
  return next;
}

export function sharedCredentials(input = {}) {
  const result = {};
  for (const id of ['openai', 'anthropic', 'xai-api', 'openrouter', 'opencode-go', ...Object.keys(searchProviderNames), ...Object.keys(input).filter(id => /^local-server-[a-f0-9-]{36}$/.test(id)).slice(0, 12)]) {
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
  for (const provider of ['openai', 'openai-codex', 'anthropic', 'xai', 'xai-api', 'openrouter', 'opencode-go', ...Object.keys(searchProviderNames)]) {
    if (!Array.isArray(input[provider])) continue;
    const entries = input[provider].slice(0, ['openai-codex', 'xai'].includes(provider) ? 1 : 4).flatMap(account => {
      const credential = sharedCredentials({ [provider]: account?.credential })[provider];
      return credential && typeof account.id === 'string' && typeof account.label === 'string'
        ? [{ id: account.id, label: account.label, credential }] : [];
    });
    if (entries.length) result[provider] = entries;
  }
  // Native profile names are identifiers, never native token material.
  const profiles = input['claude-subscription'];
  if (Array.isArray(profiles)) {
    result['claude-subscription'] = profiles.slice(0, 1).filter(a => typeof a.id === 'string' && typeof a.label === 'string' && a.credential?.type === 'native' && typeof a.credential.accountId === 'string' && /^[a-zA-Z0-9-]{1,64}$/.test(a.credential.accountId))
      .map(a => ({ id: a.id, label: a.label, credential: { type: 'native', accountId: a.credential.accountId } }));
  }
  return result;
}
