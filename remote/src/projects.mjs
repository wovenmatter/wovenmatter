import { mkdir, realpath, lstat, rm } from 'node:fs/promises';
import { join } from 'node:path';

export async function createProject(root, name) {
  if (typeof name !== 'string' || !name.trim() || name.startsWith('.') || /[\\/:\x00-\x1f\x7f]/.test(name) || Buffer.byteLength(name) > 255) {
    throw Object.assign(new Error('Use a directory name without slashes or a leading period.'), { statusCode: 400 });
  }
  const path = join(await realpath(root), name.trim());
  await mkdir(path); // No recursive creation, normalization, or project instructions.
  return { path };
}

export async function deleteProject(root, path) {
  const managed = await realpath(root);
  if (typeof path !== 'string' || !path.startsWith(managed + '/') || path.slice(managed.length + 1).includes('/')) {
    throw Object.assign(new Error('Only a managed project root can be deleted.'), { statusCode: 400 });
  }
  const name = path.slice(managed.length + 1);
  if (!name || name.startsWith('.') || /[\\/:\x00-\x1f\x7f]/.test(name) || await realpath(path) !== path) {
    throw Object.assign(new Error('Only a managed project root can be deleted.'), { statusCode: 400 });
  }
  const info = await lstat(path);
  if (!info.isDirectory() || info.isSymbolicLink()) throw Object.assign(new Error('Project root is not a managed directory.'), { statusCode: 400 });
  await rm(path, { recursive: true });
  return { path };
}
