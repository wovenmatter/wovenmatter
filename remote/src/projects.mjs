import { mkdir, realpath, lstat, rm, access, opendir, stat } from 'node:fs/promises';
import { constants } from 'node:fs';
import { join, isAbsolute, dirname } from 'node:path';

// Native host folders follow the owning Linux account's permissions. Linking a
// directory records its canonical path; it never copies, moves or deletes it.
export async function linkHostProject(path) {
  if (typeof path !== 'string' || !isAbsolute(path) || /[\x00-\x1f\x7f]/.test(path)) {
    throw Object.assign(new Error('Choose an absolute directory on this host.'), { statusCode: 400 });
  }
  try {
    const canonical = await realpath(path);
    if (!(await stat(canonical)).isDirectory()) throw new Error('not_directory');
    await access(canonical, constants.R_OK | constants.X_OK);
    return { path: canonical };
  } catch {
    throw Object.assign(new Error('This directory is unavailable to the workspace user.'), { statusCode: 400 });
  }
}

export async function listHostDirectories(path, { limit = 200, scanLimit = 4096 } = {}) {
  const { path: canonical } = await linkHostProject(path);
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 200 || !Number.isSafeInteger(scanLimit) || scanLimit < limit || scanLimit > 4096) throw new TypeError('Invalid directory listing limit');
  const directories = [];
  let scanned = 0, truncated = false;
  const directory = await opendir(canonical);
  for await (const entry of directory) {
    if (++scanned > scanLimit) { truncated = true; break; }
    if (!entry.isDirectory() && !entry.isSymbolicLink()) continue;
    if (/[\x00-\x1f\x7f]/.test(entry.name)) continue;
    try { directories.push({ name: entry.name, ...(await linkHostProject(join(canonical, entry.name))) }); }
    catch { /* Inaccessible or stale links are not selectable. */ }
  }
  directories.sort((a, b) => a.name.localeCompare(b.name, 'en'));
  return { path: canonical, parent: dirname(canonical) === canonical ? null : dirname(canonical), directories: directories.slice(0, limit), truncated: truncated || directories.length > limit };
}

export async function createProject(root, name, { reuseExisting = false } = {}) {
  const cleanName = typeof name === 'string' ? name.trim() : '';
  if (!cleanName || cleanName.toLowerCase() === 'scratch' || cleanName.startsWith('.') || /[\\/:\x00-\x1f\x7f]/.test(cleanName) || Buffer.byteLength(cleanName) > 255) {
    throw Object.assign(new Error('Use a directory name without slashes or a leading period. Scratch is reserved for chats in All Workspaces.'), { statusCode: 400 });
  }
  const path = join(await realpath(root), cleanName);
  try { await mkdir(path); } // No recursive creation, normalization, or project instructions.
  catch (error) { if (!reuseExisting || error.code !== 'EEXIST') throw error; }
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink()) throw Object.assign(new Error('Project roots must be ordinary directories.'), { statusCode: 400 });
  return { path };
}

export async function deleteProject(root, path) {
  const managed = await realpath(root);
  if (typeof path !== 'string' || !path.startsWith(managed + '/') || path.slice(managed.length + 1).includes('/')) {
    throw Object.assign(new Error('Only a managed project root can be deleted.'), { statusCode: 400 });
  }
  const name = path.slice(managed.length + 1);
  if (!name || name.toLowerCase() === 'scratch' || name.startsWith('.') || /[\\/:\x00-\x1f\x7f]/.test(name) || await realpath(path) !== path) {
    throw Object.assign(new Error('Only a managed project root can be deleted.'), { statusCode: 400 });
  }
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink()) throw Object.assign(new Error('Project root is not a managed directory.'), { statusCode: 400 });
  await rm(path, { recursive: true });
  return { path };
}

export function scratchFolderName(sessionID, firstMessage, date = new Date(), fullID = false) {
  const words = String(firstMessage).toLowerCase().split(/[^a-z0-9]+/).filter(Boolean).slice(0, 5).join('-').slice(0, 48).replace(/-+$/, '');
  const id = sessionID.toLowerCase().replace(/[^a-z0-9]/g, '');
  return [new Date(date).toISOString().slice(0, 10), words, fullID ? id : id.slice(-8)].filter(Boolean).join('-');
}

export async function ensureScratchDirectory(root, path) {
  const scratch = join(root, 'scratch');
  if (typeof path !== 'string' || !path.startsWith(scratch + '/') || !path.slice(scratch.length + 1)
      || /[\\/\x00-\x1f\x7f]/.test(path.slice(scratch.length + 1)) || path.slice(scratch.length + 1).startsWith('.')) {
    throw Object.assign(new Error('Invalid chat scratch directory.'), { statusCode: 400 });
  }
  for (const directory of [scratch, path]) {
    try { await mkdir(directory); } catch (error) { if (error.code !== 'EEXIST') throw error; }
    const info = await lstat(directory);
    if (!info.isDirectory() || info.isSymbolicLink()) throw Object.assign(new Error('Scratch directories must be ordinary directories.'), { statusCode: 400 });
  }
  return { path };
}
