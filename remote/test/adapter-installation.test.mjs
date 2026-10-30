import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, writeFile, readFile, readlink, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { installAdapter } from '../../harnesses/install-adapter.mjs';

const exec = promisify(execFile);
const adapter = '@agentclientprotocol/codex-acp', engine = '@openai/codex';

test('real npm installs a newer engine outside the adapter range; failed verification preserves the previous generation', { timeout: 60000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-adapter-graph-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const archives = new Map();
  const metadata = new Map();
  const npm = ['npm', '--cache', join(root, 'cache')];
  async function pack(name, version, files, extra = {}) {
    const directory = join(root, name.replaceAll('/', '-'), version);
    await mkdir(directory, { recursive: true });
    const manifest = { name, version, bin: { [name === engine ? 'codex' : 'codex-acp']: 'index.js' }, ...extra };
    await writeFile(join(directory, 'package.json'), JSON.stringify(manifest));
    for (const [name, text] of Object.entries(files)) { await mkdir(dirname(join(directory, name)), { recursive: true }); await writeFile(join(directory, name), text); }
    const { stdout } = await exec(npm[0], [...npm.slice(1), 'pack', '--json', '--ignore-scripts'], { cwd: directory });
    const packed = JSON.parse(stdout);
    // npm 12 keys pack results by package name; older versions return an array.
    const file = (Array.isArray(packed) ? packed[0] : packed[name]).filename;
    const bytes = await readFile(join(directory, file));
    archives.set('/' + file, bytes);
    const versions = metadata.get(name) ?? {};
    versions[version] = { ...manifest, dist: { tarball: file, integrity: 'sha512-' + createHash('sha512').update(bytes).digest('base64') } };
    metadata.set(name, versions);
  }
  await pack(engine, '0.166.0', {
    'index.js': '#!/usr/bin/env node\nconsole.log("codex-cli 0.166.0");',
    'bin/codex.js': '#!/usr/bin/env node\nconsole.log("codex-cli 0.166.0");',
  });
  const fixture = (version, protocol) => `#!/usr/bin/env node
    const fs = require('node:fs');
    const readline = require('node:readline');
    if (process.env.WOVEN_TEST_SECRET || process.env.CODEX_PATH) process.exit(4);
    const dependency = require('@openai/codex/package.json');
    if (dependency.version !== '0.166.0') process.exit(5);
    if (!fs.existsSync(process.env.CODEX_HOME)) process.exit(6);
    readline.createInterface({ input: process.stdin }).on('line', line => {
      const request = JSON.parse(line);
      if (request.method !== 'initialize') process.exit(7);
      console.log(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { protocolVersion: ${protocol}, agentInfo: { name: 'fixture', version: '${version}' } } }));
    });`;
  for (const [version, protocol] of [['2.5.0', 1], ['2.6.0', 2]]) await pack(adapter, version, { 'index.js': fixture(version, protocol) }, { dependencies: { [engine]: '^0.165.0' } });
  const server = createServer((request, response) => {
    const path = decodeURIComponent(request.url);
    if (archives.has(path)) return response.end(archives.get(path));
    const name = path.slice(1);
    if (!metadata.has(name)) { response.statusCode = 404; return response.end('{}'); }
    const versions = structuredClone(metadata.get(name));
    for (const value of Object.values(versions)) value.dist.tarball = `http://127.0.0.1:${server.address().port}/${value.dist.tarball}`;
    response.setHeader('content-type', 'application/json');
    response.end(JSON.stringify({ name, versions, 'dist-tags': { latest: Object.keys(versions).at(-1) } }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise(resolve => server.close(resolve)));
  const prefix = join(root, 'installed');
  const options = { prefix, adapter, adapterVersion: '2.5.0', engineVersion: '0.166.0',
    npm: [...npm, '--registry', `http://127.0.0.1:${server.address().port}`] };
  const previousSecret = process.env.WOVEN_TEST_SECRET, previousOverride = process.env.CODEX_PATH;
  process.env.WOVEN_TEST_SECRET = 'must-not-reach-probe'; process.env.CODEX_PATH = '/must-not-be-used';
  t.after(() => {
    if (previousSecret === undefined) delete process.env.WOVEN_TEST_SECRET; else process.env.WOVEN_TEST_SECRET = previousSecret;
    if (previousOverride === undefined) delete process.env.CODEX_PATH; else process.env.CODEX_PATH = previousOverride;
  });
  const executable = await installAdapter(options);
  const target = await readlink(executable);
  const generation = join(target, '../../..');
  const lock = JSON.parse(await readFile(join(generation, 'package-lock.json'), 'utf8'));
  assert.equal(lock.packages['node_modules/@openai/codex'].version, '0.166.0');
  assert.equal(lock.packages['node_modules/@agentclientprotocol/codex-acp'].dependencies[engine], '^0.165.0', 'upstream manifest remains intact');
  for (const name of [adapter, engine]) assert.match(lock.packages['node_modules/' + name].integrity, /^sha512-/);
  const verification = JSON.parse(await readFile(join(generation, 'verification.json'), 'utf8'));
  assert.equal(verification.engineVersion, '0.166.0');
  assert.equal(verification.protocolVersion, 1);
  await assert.rejects(installAdapter({ ...options, adapterVersion: '2.6.0' }), /ACP v1 verification/);
  assert.equal(await readlink(executable), target, 'failed candidate must not retire or replace the working graph');
  assert.equal((await readdir(join(prefix, 'Installations'))).length, 1, 'failed generation is removed');
});
