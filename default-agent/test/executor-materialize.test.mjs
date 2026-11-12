import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile, readFile, readdir, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { materializeExecutor, executorCommand } from '../src/executor/materialize.mjs';

const version = '2.0.0-beta.37', target = process.platform + '-' + process.arch;
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'woven-executor-native-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, 'node_modules/executor'), { recursive: true });
  await writeFile(join(root, 'node_modules/executor/package.json'), JSON.stringify({ version, runtimes: { [target]: 'a'.repeat(64) } }));
  return root;
}
async function candidate(options) {
  const path = join(options.env.HOME, '.executor/v2/launcher', version);
  await mkdir(path, { recursive: true });
  await mkdir(join(path, 'runtime/node_modules/ws'), { recursive: true });
  await writeFile(join(path, 'runtime/node_modules/ws/package.json'), JSON.stringify({ version: '8.21.0' }));
  await writeFile(join(path, process.platform === 'win32' ? 'executor.exe' : 'executor'), 'fixture');
  return path;
}

test('native Executor is verified before promotion with a generation-private launcher cache', async t => {
  const root = await fixture(t);
  await materializeExecutor(root, { run: async (node, args, options) => {
    assert.equal(node, process.execPath);
    assert.deepEqual(args, [join(root, 'node_modules/executor/bin.mjs'), '--version']);
    assert.ok(options.env.HOME.startsWith(root + '/.native-'));
    assert.equal(options.env.EXECUTOR_DOWNLOAD_URL, undefined);
    assert.equal(options.env.EXECUTOR_API_KEY, undefined);
    await candidate(options);
    return { stdout: `executor v${version}\n` };
  } });
  const command = await executorCommand(root);
  assert.equal(command.executable, join(root, 'native', process.platform === 'win32' ? 'executor.exe' : 'executor'));
  assert.deepEqual(command.args, []);
  assert.equal((await readdir(root)).some(name => name.startsWith('.native-')), false);
  const provenance = JSON.parse(await readFile(join(root, 'native/woven-provenance.json')));
  assert.equal(provenance.archiveSHA256, 'a'.repeat(64));
  assert.equal(provenance.webSocket.version, '8.23.0');
  await writeFile(join(root, 'native/woven-provenance.json'), JSON.stringify({ ...provenance, webSocket: undefined }));
  await assert.rejects(executorCommand(root), /security provenance differs/);
  await writeFile(join(root, 'native/woven-provenance.json'), JSON.stringify(provenance));
  const repaired = join(root, 'native/runtime/node_modules/ws');
  assert.equal(JSON.parse(await readFile(join(repaired, 'package.json'))).version, '8.23.0');
  const original = await readFile(join(repaired, 'index.js'));
  await writeFile(join(repaired, 'index.js'), 'tampered');
  await assert.rejects(executorCommand(root), /security provenance differs/);
  await writeFile(join(repaired, 'index.js'), original);
  provenance.archiveSHA256 = 'b'.repeat(64);
  await writeFile(join(root, 'native/woven-provenance.json'), JSON.stringify(provenance));
  await assert.rejects(executorCommand(root), /provenance differs/);
});

test('failed native candidates leave earlier generations intact and refuse version or integrity failures', async t => {
  for (const failure of ['checksum', 'version', 'symlink', 'repair-symlink']) {
    const root = await fixture(t);
    await writeFile(join(root, 'previous-generation'), 'retained');
    await assert.rejects(materializeExecutor(root, { run: async (_node, _args, options) => {
      if (failure === 'checksum') throw new Error('archive SHA-256 mismatch');
      const path = await candidate(options);
      if (failure === 'symlink') {
        await rm(join(path, 'executor'));
        await symlink(process.execPath, join(path, 'executor'));
      }
      if (failure === 'repair-symlink') {
        await rm(join(path, 'runtime'), { recursive: true });
        await symlink(root, join(path, 'runtime'));
      }
      return { stdout: failure === 'version' ? '2.0.0-beta.36' : version };
    } }));
    assert.equal(await readFile(join(root, 'previous-generation'), 'utf8'), 'retained');
    assert.equal((await readdir(root)).some(name => name === 'native' || name.startsWith('.native-')), false);
  }
});
