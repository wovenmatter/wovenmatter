// The npm launcher now downloads its native archive on first use. Materialize
// it in this candidate generation before stopping an active Executor. Its own
// checksum verification runs with a private HOME, never the user's shared cache.
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { lstat, mkdtemp, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';

const exec = promisify(execFile);
const json = async path => JSON.parse(await readFile(path, 'utf8'));
const target = process.platform + '-' + process.arch;
const executableName = process.platform === 'win32' ? 'executor.exe' : 'executor';
const environment = home => ({ HOME: home, PATH: '/usr/bin:/bin:/usr/sbin:/sbin',
  EXECUTOR_NO_UPDATE_CHECK: '1', DISABLE_TELEMETRY: '1' });
const owned = async path => {
  const stat = await lstat(path);
  if (!stat.isDirectory() || stat.isSymbolicLink() || stat.uid !== process.getuid()) throw new Error('Executor candidate directory is not privately owned.');
};

export async function executorCommand(root) {
  const manifest = await json(join(root, 'node_modules/executor/package.json'));
  if (!manifest.runtimes) return { executable: process.execPath, args: [join(root, 'node_modules/executor/bin.mjs')] };
  await owned(root);
  const native = join(root, 'native');
  await owned(native);
  const record = await json(join(native, 'woven-provenance.json'));
  if (record.version !== manifest.version || record.target !== target || record.archiveSHA256 !== manifest.runtimes[target]) throw new Error('Executor native runtime provenance differs from its package.');
  const executable = join(native, executableName), stat = await lstat(executable);
  if (!stat.isFile() || stat.isSymbolicLink() || stat.uid !== process.getuid()) throw new Error('Executor executable is not privately owned.');
  return { executable, args: [] };
}

export async function materializeExecutor(root, { run = exec } = {}) {
  await owned(root);
  const manifest = await json(join(root, 'node_modules/executor/package.json'));
  if (!manifest.runtimes) return; // Existing V2 packages already carry their runtime.
  const digest = manifest.runtimes[target];
  if (!/^2\.\d+\.\d+(?:-beta\.\d+)?$/.test(manifest.version) || !/^[a-f0-9]{64}$/.test(digest ?? '')) throw new Error('Executor has no verified native archive for this platform.');
  const stage = await mkdtemp(join(root, '.native-'));
  try {
    const options = { env: environment(stage), timeout: 600000, maxBuffer: 1024 * 1024 };
    const result = await run(process.execPath, [join(root, 'node_modules/executor/bin.mjs'), '--version'], options);
    if (!new RegExp('(?:^|\\s)v?' + manifest.version.replaceAll('.', '\\.') + '(?:\\s|$)').test(result.stdout.trim())) throw new Error('Executor native version differs from its package.');
    const candidate = join(stage, '.executor/v2/launcher', manifest.version);
    await owned(candidate);
    const binary = await lstat(join(candidate, executableName));
    if (!binary.isFile() || binary.isSymbolicLink() || binary.uid !== process.getuid()) throw new Error('Executor candidate executable is not privately owned.');
    await writeFile(join(candidate, 'woven-provenance.json'), JSON.stringify({ version: manifest.version, target, archiveSHA256: digest }) + '\n', { mode: 0o600, flag: 'wx' });
    await rename(candidate, join(root, 'native'));
  } finally { await rm(stage, { recursive: true, force: true }); }
}
