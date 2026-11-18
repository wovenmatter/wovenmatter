import { constants } from 'node:fs';
import { chmod, mkdir, open } from 'node:fs/promises';
import { join } from 'node:path';
import lockfile from 'proper-lockfile';
import { writePrivateJSON } from './config.mjs';

// A host stores and renews its own sign-ins in one private file, like the CLIs'
// own logins (`~/.claude/.credentials.json`, `~/.codex/auth.json`): 0600 in the
// host's Pi Durable folder (0700), outside the workspace, readable only by this
// user. Only the Mac's own helper runs without it (its credentials come from Keychain).
export const deviceSignInsEnabled = (environment = process.env) => environment.WOVEN_DEFAULT_AGENT_DEVICE_VAULT === '1';
const lockOptions = { realpath: false, retries: { retries: 60, minTimeout: 50, maxTimeout: 500 }, stale: 60000 };

export class SignInStore {
  constructor(directory) { this.directory = directory; this.path = join(directory, 'sign-ins.json'); }
  async open() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    await chmod(this.directory, 0o700);
    return this;
  }
  // No file is no sign-ins; malformed content reads as signed out.
  async read() { const value = await readStore(this.path); return value === unreadable ? {} : value; }
  // Written whole to a new private file and renamed into place, under the lock.
  // A malformed store is replaced; any other read error fails with nothing written.
  async modify(fn) {
    await this.open();
    const release = await lockfile.lock(this.path, lockOptions);
    try {
      const stored = await readStore(this.path);
      const next = await fn(stored === unreadable ? {} : stored);
      await writePrivateJSON(this.path, next);
      return next;
    } finally { await release(); }
  }
}

// Only a missing file is no store, and only a JSON syntax error is an unreadable
// one. Any other error (EACCES, EIO, EMFILE…) is thrown: nothing is replaced on a guess.
const unreadable = Symbol('unreadable');
async function readStore(path) {
  let file;
  try { file = await open(path, constants.O_RDONLY | constants.O_NOFOLLOW); }
  catch (error) {
    if (error.code === 'ENOENT') return {};
    if (error.code === 'ELOOP') throw new Error('The sign-ins file on this device is a link. Remove it to sign in again.');
    throw error;
  }
  try {
    const info = await file.stat();
    if (!info.isFile() || info.uid !== process.getuid?.()) throw new Error('The sign-ins file on this device belongs to another user. Remove it to sign in again.');
    if ((info.mode & 0o777) !== 0o600) await file.chmod(0o600);
    let value;
    try { value = JSON.parse(await file.readFile('utf8')); }
    catch (error) { if (error instanceof SyntaxError) return unreadable; throw error; }
    return value && typeof value === 'object' && !Array.isArray(value) ? value : unreadable;
  } finally { await file.close(); }
}
