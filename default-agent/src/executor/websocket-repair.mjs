// Executor's immutable archive still carries ws 8.21.0. Stage the signed
// helper's locked, security-fixed transport before promoting that archive.
import { cp, lstat, readFile, readdir, rm } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
const bundled = fileURLToPath(new URL('../../', import.meta.url));
const json = async path => JSON.parse(await readFile(path, 'utf8'));
async function ownedDirectory(path) {
  const stat = await lstat(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) throw new Error('Executor WebSocket repair directory is not privately owned.');
}
async function digest(root) {
  const hash = createHash('sha256');
  async function visit(directory, prefix = '') {
    await ownedDirectory(directory);
    for (const name of (await readdir(directory)).sort()) {
      const path = join(directory, name), relative = prefix + name, stat = await lstat(path);
      if (stat.isDirectory() && !stat.isSymbolicLink()) await visit(path, relative + '/');
      else if (stat.isFile() && !stat.isSymbolicLink()) hash.update(relative + '\0').update(createHash('sha256').update(await readFile(path)).digest());
      else throw new Error('Executor WebSocket repair contains an unsafe file.');
    }
  }
  await visit(root); return hash.digest('hex');
}
async function selection() {
  const lock = await json(join(bundled, 'package-lock.json'));
  const record = lock.packages['node_modules/ws'];
  const source = join(bundled, 'node_modules/ws');
  const parts = record?.version?.match(/^(\d+)\.(\d+)\.(\d+)$/)?.slice(1).map(Number);
  const fixed = parts && (parts[0] > 8 || parts[0] === 8 && parts[1] >= 23);
  if (!record?.integrity || (await json(join(source, 'package.json'))).version !== record.version
      || !fixed) throw new Error('The bundled WebSocket security selection is unavailable.');
  return { source, version: record.version, integrity: record.integrity };
}
export async function repairExecutorWebSocket(candidate) {
  const selected = await selection();
  const runtime = join(candidate, 'runtime'), modules = join(runtime, 'node_modules');
  await ownedDirectory(runtime); await ownedDirectory(modules);
  const destination = join(modules, 'ws');
  await rm(destination, { recursive: true, force: true });
  await cp(selected.source, destination, { recursive: true, dereference: false });
  return { version: selected.version, integrity: selected.integrity, sha256: await digest(destination) };
}
export async function verifyExecutorWebSocket(candidate, record) {
  const expected = await selection(), destination = join(candidate, 'runtime/node_modules/ws');
  await ownedDirectory(join(candidate, 'runtime')); await ownedDirectory(join(candidate, 'runtime/node_modules'));
  if (record?.version !== expected.version || record.integrity !== expected.integrity
      || (await json(join(destination, 'package.json'))).version !== expected.version
      || await digest(destination) !== record.sha256) throw new Error('Executor WebSocket security provenance differs; reinstall Executor in Settings.');
}
