// One private npm selection for the Mac SDK updater and managed CLI installs.
// Bootstrap npm only unpacks the integrity-verified npm archive and the committed
// vendor-repair graph. Never change the Node archive or a system installation.
import { createHash } from 'node:crypto';
import { createRequire } from 'node:module';
import { mkdir, mkdtemp, readFile, writeFile, rm, cp, symlink, rename, realpath } from 'node:fs/promises';
import { resolve, join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { run } from './install-adapter.mjs';

const root = dirname(fileURLToPath(import.meta.url));
const json = async path => JSON.parse(await readFile(path, 'utf8'));
export async function prepareNPM({ prefix, node, bootstrap, securityGraph = resolve(root, '../remote/npm-runtime'), recordPath = join(root, 'npm-version.json'), fetchImplementation = fetch }) {
  const recordBytes = await readFile(recordPath);
  const record = JSON.parse(recordBytes);
  const lockBytes = await readFile(join(securityGraph, 'package-lock.json'));
  const lock = JSON.parse(lockBytes);
  const modules = Object.keys(lock.packages).filter(path => path.startsWith('node_modules/') && !path.slice(13).includes('/node_modules/')).map(path => path.slice(13));
  const key = createHash('sha256').update(recordBytes).update(lockBytes).update(node).digest('hex');
  prefix = resolve(prefix, key);
  async function verified(at) {
    try {
      if ((await json(join(at, 'lib/node_modules/npm/package.json'))).version !== record.version) return false;
      for (const name of modules) if ((await json(join(at, 'lib/node_modules/npm/node_modules', name, 'package.json'))).version !== lock.packages['node_modules/' + name].version) return false;
      const npm = join(at, 'lib/node_modules/npm/bin/npm-cli.js');
      const version = await run(node, [npm, '--version']);
      return version.trim() === record.version;
    } catch { return false; }
  }
  if (await verified(prefix)) return join(prefix, 'bin/npm');
  await mkdir(dirname(prefix), { recursive: true, mode: 0o700 });
  const stage = await realpath(await mkdtemp(join(dirname(prefix), '.npm-')));
  try {
    const response = await fetchImplementation(record.url, { signal: AbortSignal.timeout(30000) });
    if (!response.ok) throw new Error('Private npm archive unavailable.');
    const reader = response.body.getReader(); let size = 0; const chunks = [];
    for (;;) { const { done, value } = await reader.read(); if (done) break; size += value.length; if (size > 32 * 1024 * 1024) { await reader.cancel(); throw new Error('Private npm archive exceeded its limit.'); } chunks.push(value); }
    const archive = Buffer.concat(chunks);
    const [algorithm, expected] = record.integrity.split('-');
    if (createHash(algorithm).update(archive).digest('base64') !== expected) throw new Error('Private npm archive integrity mismatch.');
    const file = join(stage, 'npm.tgz'); await writeFile(file, archive, { mode: 0o600 });
    await run(bootstrap[0], [...bootstrap.slice(1), 'install', '--global', '--prefix', stage, '--ignore-scripts', '--no-audit', '--no-fund', file], { cwd: stage });
    const repairs = join(stage, 'security'); await mkdir(repairs, { mode: 0o700 });
    for (const name of ['package.json', 'package-lock.json']) await cp(join(securityGraph, name), join(repairs, name));
    await run(bootstrap[0], [...bootstrap.slice(1), 'ci', '--prefix', repairs, '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund'], { cwd: repairs });
    for (const name of modules) {
      const destination = join(stage, 'lib/node_modules/npm/node_modules', name);
      await rm(destination, { force: true, recursive: true }); await cp(join(repairs, 'node_modules', name), destination, { recursive: true });
    }
    const require = createRequire(join(stage, 'lib/node_modules/npm/bin/npm-cli.js'));
    if (typeof require('undici').request !== 'function' || typeof require('ip-address').Address6 !== 'function' || typeof require('minimatch').minimatch !== 'function') throw new Error('Private npm security API verification failed.');
    await symlink(node, join(stage, 'bin/node'));
    if (!await verified(stage)) throw new Error('Private npm selection failed verification.');
    await rm(file); await rm(join(repairs, 'node_modules'), { recursive: true, force: true });
    await writeFile(join(stage, 'provenance.json'), JSON.stringify({ version: record.version, integrity: record.integrity, securityLockSHA256: createHash('sha256').update(lockBytes).digest('hex') }) + '\n', { mode: 0o600 });
    // Concurrent builders may have finished the same immutable selection first.
    try { await rename(stage, prefix); } catch (error) { if (!await verified(prefix)) throw error; }
    return join(prefix, 'bin/npm');
  } finally { await rm(stage, { force: true, recursive: true }); }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try { console.log(await prepareNPM(JSON.parse(process.argv[2]))); }
  catch (error) { console.error(error.message); process.exitCode = 1; }
}
