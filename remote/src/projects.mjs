import { mkdir, realpath, lstat, rm } from 'node:fs/promises';
import { join } from 'node:path';

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
