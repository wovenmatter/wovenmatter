import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { constants } from 'node:fs';
import { mkdir, open, rename, unlink } from 'node:fs/promises';
import { join } from 'node:path';
import lockfile from 'proper-lockfile';
import { readJSON, writePrivateJSON } from './config.mjs';

// A host stores and renews its own sign-ins in this device vault, sealed with
// its own key beside it in the private directory. Only the Mac's own helper
// runs without it (its credentials come from Keychain in each request).
export const deviceVaultEnabled = (environment = process.env) => environment.WOVEN_DEFAULT_AGENT_DEVICE_VAULT === '1';
const workspace = 'device';
const lockOptions = { realpath: false, retries: { retries: 60, minTimeout: 50, maxTimeout: 500 }, stale: 60000 };
const missing = error => { if (error.code !== 'ENOENT') throw error; };

export class CredentialVault {
  constructor(directory) {
    this.directory = directory; this.path = join(directory, 'credentials.enc.json'); this.keyPath = join(directory, 'credentials.key');
  }
  // Creates the key on first use. A vault file that is not this device's own is
  // replaced by a fresh one: nothing from elsewhere is read or kept.
  async openDevice() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const release = await lockfile.lock(this.path, lockOptions);
    try {
      const stored = await readJSON(this.path, null).catch(() => null);
      if (stored?.workspace !== workspace) await unlink(this.path).catch(missing);
      if (!(await readKey(this.keyPath))) await writeKey(this.keyPath);
      return this;
    } finally { await release(); }
  }
  // An unreadable vault or key (a restored or copied workspace) reads as signed out.
  async read() {
    const key = await readKey(this.keyPath);
    const stored = await readJSON(this.path, null).catch(() => null);
    if (!key || !stored) return {};
    try { return decrypt(stored, key); } catch { return {}; } finally { key.fill(0); }
  }
  // A sign-in made while the vault is unreadable replaces it with a new key.
  async modify(fn) {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const release = await lockfile.lock(this.path, lockOptions);
    try {
      let key = await readKey(this.keyPath), current;
      const stored = await readJSON(this.path, null).catch(() => null);
      try { current = key ? (stored ? decrypt(stored, key) : {}) : undefined; } catch { current = undefined; }
      if (current === undefined) { key?.fill(0); key = await writeKey(this.keyPath); current = {}; }
      const next = await fn(current);
      const nonce = randomBytes(12);
      const cipher = createCipheriv('aes-256-gcm', key, nonce);
      cipher.setAAD(Buffer.from('wovenmatter/default-agent/v1/' + workspace));
      const data = Buffer.concat([cipher.update(JSON.stringify(next), 'utf8'), cipher.final()]);
      key.fill(0);
      await writePrivateJSON(this.path, { version: 1, workspace, nonce: nonce.toString('base64'), tag: cipher.getAuthTag().toString('base64'), data: data.toString('base64') });
      return next;
    } finally { await release(); }
  }
}

function decrypt(stored, key) {
  if (stored.version !== 1 || stored.workspace !== workspace) throw new Error('unreadable');
  const decipher = createDecipheriv('aes-256-gcm', key, Buffer.from(stored.nonce, 'base64'));
  decipher.setAAD(Buffer.from('wovenmatter/default-agent/v1/' + workspace));
  decipher.setAuthTag(Buffer.from(stored.tag, 'base64'));
  return JSON.parse(Buffer.concat([decipher.update(Buffer.from(stored.data, 'base64')), decipher.final()]).toString('utf8'));
}

// The key file is this user's own regular file, never a link, kept 0600. A
// missing or malformed key is `null`.
async function readKey(path) {
  let file;
  try { file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    if (error.code === 'ELOOP') throw new Error('The Pi Durable key on this device is a link. Remove it to sign in again.');
    throw error;
  }
  try {
    const info = await file.stat();
    if (!info.isFile() || info.uid !== process.getuid?.()) throw new Error('The Pi Durable key on this device belongs to another user. Remove it to sign in again.');
    if ((info.mode & 0o777) !== 0o600) await file.chmod(0o600);
    const text = (await file.readFile('utf8')).trim(), key = Buffer.from(text, 'base64');
    return /^[A-Za-z0-9+/]{43}=$/.test(text) && key.length === 32 ? key : null;
  } finally { await file.close(); }
}

// Written whole to a new private file (exclusive, never through a link), then
// moved into place, so no reader sees part of a key. Callers hold the vault lock.
async function writeKey(path) {
  const key = randomBytes(32), temporary = `${path}.${process.pid}.${randomBytes(6).toString('hex')}.tmp`;
  try {
    const file = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    try { await file.writeFile(key.toString('base64')); await file.sync(); } finally { await file.close(); }
    await rename(temporary, path);
    return key;
  } finally { await unlink(temporary).catch(missing); }
}
