import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import { mkdtemp, mkdir, writeFile, readFile, readlink, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { installAdapter, linkedGeneration } from '../../harnesses/install-adapter.mjs';

const exec = promisify(execFile);
const adapter = '@agentclientprotocol/codex-acp', engine = '@openai/codex';

test('real npm installs the adapter exactly as published, pointed at the native CLI; success deletes the replaced generation, failure keeps the working one', { timeout: 60000 }, async t => {
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
  // A newer ACP SDK is published, but the adapter keeps the one its release names.
  for (const version of ['2.1.0', '2.2.0']) await pack('@agentclientprotocol/sdk', version, { 'index.js': `exports.version = "${version}";` }, { bin: undefined });
  // Vendors ship the full CLI build as optional platform packages; Woven never installs them.
  const bundledBuild = '@openai/codex-fixture-platform';
  await pack(bundledBuild, '0.165.4', { 'index.js': 'process.exit(9);' }, { bin: undefined });
  await pack(engine, '0.165.4', {
    'index.js': '#!/usr/bin/env node\nconsole.log("codex-cli 0.165.4");',
    'bin/codex.js': '#!/usr/bin/env node\nconsole.log("codex-cli 0.165.4");',
  }, { optionalDependencies: { [bundledBuild]: '0.165.4' } });
  const nativeCLI = join(root, 'home/.local/bin/codex');
  const fixture = (version, protocol) => `#!/usr/bin/env node
    const fs = require('node:fs');
    const readline = require('node:readline');
    if (process.env.WOVEN_TEST_SECRET) process.exit(4);
    if (process.env.CODEX_PATH !== ${JSON.stringify(nativeCLI)}) process.exit(5);
    if (require('@agentclientprotocol/sdk').version !== '2.1.0') process.exit(8);
    if (!fs.existsSync(process.env.CODEX_HOME)) process.exit(6);
    readline.createInterface({ input: process.stdin }).on('line', line => {
      const request = JSON.parse(line);
      if (request.method !== 'initialize') process.exit(7);
      console.log(JSON.stringify({ jsonrpc: '2.0', id: request.id, result: { protocolVersion: ${protocol}, agentInfo: { name: 'fixture', version: '${version}' } } }));
    });`;
  for (const [version, protocol] of [['2.5.0', 1], ['2.5.1', 1], ['2.6.0', 2]]) await pack(adapter, version, { 'index.js': fixture(version, protocol) }, { dependencies: { [engine]: '^0.165.0', '@agentclientprotocol/sdk': '2.1.0' } });
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
  const options = { prefix, adapter, adapterVersion: '2.5.0', cli: nativeCLI,
    npm: [...npm, '--registry', `http://127.0.0.1:${server.address().port}`] };
  const previousSecret = process.env.WOVEN_TEST_SECRET, previousOverride = process.env.CODEX_PATH;
  process.env.WOVEN_TEST_SECRET = 'must-not-reach-probe'; process.env.CODEX_PATH = '/must-not-be-used';
  t.after(() => {
    if (previousSecret === undefined) delete process.env.WOVEN_TEST_SECRET; else process.env.WOVEN_TEST_SECRET = previousSecret;
    if (previousOverride === undefined) delete process.env.CODEX_PATH; else process.env.CODEX_PATH = previousOverride;
  });
  const executable = await installAdapter(options);
  const first = await readlink(executable);
  const firstGeneration = join(first, '../../..');
  // Installed exactly as published: one dependency, no overrides, the adapter's own SDK.
  assert.deepEqual(JSON.parse(await readFile(join(firstGeneration, 'package.json'), 'utf8')), { private: true, dependencies: { [adapter]: '2.5.0' } });
  // A folder Woven did not just replace is not swept.
  const leftover = join(prefix, 'Installations', 'adapter-leftover');
  await mkdir(leftover);
  const target = await readlink(await installAdapter({ ...options, adapterVersion: '2.5.1' }));
  const generation = join(target, '../../..');
  assert.notEqual(generation, firstGeneration);
  await assert.rejects(readdir(firstGeneration), { code: 'ENOENT' }, 'the replaced generation is deleted once the new one is linked');
  assert.deepEqual((await readdir(join(prefix, 'Installations'))).sort(), ['adapter-leftover', generation.split('/').at(-1)].sort());
  const lock = JSON.parse(await readFile(join(generation, 'package-lock.json'), 'utf8'));
  assert.equal(lock.packages['node_modules/@openai/codex'].version, '0.165.4', 'no engine is selected: the adapter keeps its own dependency');
  assert.equal(lock.packages['node_modules/@agentclientprotocol/codex-acp'].dependencies[engine], '^0.165.0', 'upstream manifest remains intact');
  for (const name of [adapter, engine]) assert.match(lock.packages['node_modules/' + name].integrity, /^sha512-/);
  await assert.rejects(readFile(join(generation, 'node_modules', bundledBuild, 'package.json')), { code: 'ENOENT' }, 'the bundled CLI build is never installed');
  const verification = JSON.parse(await readFile(join(generation, 'verification.json'), 'utf8'));
  assert.equal(verification.engineVersion, undefined);
  assert.equal(verification.cli, nativeCLI);
  assert.equal(verification.protocolVersion, 1);
  assert.equal(verification.adapterVersion, '2.5.1');
  assert.equal(verification.protocolSDKVersion, undefined);
  const manifest = JSON.parse(await readFile(join(generation, 'package.json'), 'utf8'));
  assert.deepEqual(manifest, { private: true, dependencies: { [adapter]: '2.5.1' } });
  assert.equal(lock.packages[''].overrides, undefined);
  assert.equal(lock.packages['node_modules/@agentclientprotocol/sdk'].version, '2.1.0', 'the ACP SDK is the one the adapter release names');
  assert.equal(lock.packages['node_modules/' + adapter].dependencies['@agentclientprotocol/sdk'], '2.1.0');
  assert.match(lock.packages['node_modules/@agentclientprotocol/sdk'].integrity, /^sha512-/);
  await assert.rejects(installAdapter({ ...options, adapterVersion: '2.6.0' }), /ACP v1 verification/);
  await assert.rejects(installAdapter({ ...options, cli: undefined }), /requires the native CLI/);
  assert.equal(await readlink(executable), target, 'failed candidate must not retire or replace the working graph');
  assert.ok((await readdir(generation)).includes('node_modules'), 'the working generation is kept');
  assert.equal((await readdir(join(prefix, 'Installations'))).length, 2, 'failed generation is removed');
});

test('harness scripts run their entry point when started through a symlinked path', async t => {
  // Dev bundles live under /private/tmp but Foundation reports /tmp; Node resolves import.meta.url through the link.
  const { symlink } = await import('node:fs/promises');
  const { fileURLToPath } = await import('node:url');
  const root = await mkdtemp(join(tmpdir(), 'woven-harness-link-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const link = join(root, 'harnesses');
  await symlink(fileURLToPath(new URL('../../harnesses', import.meta.url)), link);
  for (const [script, message] of [['install-adapter.mjs', /requires one selection/], ['prepare-npm.mjs', /not valid JSON/]]) {
    const failure = await exec(process.execPath, [join(link, script)]).then(() => null, error => error);
    assert.ok(failure, `${script} must run and reject missing input instead of exiting silently`);
    assert.match(failure.stderr, message);
  }
});

test('only the generation a link points into is ever chosen for deletion', async t => {
  const { symlink, realpath } = await import('node:fs/promises');
  const root = await realpath(await mkdtemp(join(tmpdir(), 'woven-adapter-links-')));
  t.after(() => rm(root, { recursive: true, force: true }));
  const prefix = join(root, 'prefix'), installations = join(prefix, 'Installations'), bin = join(prefix, 'bin');
  const file = async path => { await mkdir(dirname(path), { recursive: true }); await writeFile(path, ''); return path; };
  await mkdir(bin, { recursive: true });
  // The layout this installer writes.
  await symlink(await file(join(installations, 'adapter-abc123/node_modules/.bin/codex-acp')), join(bin, 'current'));
  assert.equal(await linkedGeneration(prefix, join(bin, 'current')), join(installations, 'adapter-abc123'));
  // The layout v0.4.5 and earlier wrote: bin -> Installations/<UUID>/bin -> ../lib/node_modules/...
  const legacy = join(installations, '348945E6-11D7-42AD-A243-BCDD2BCB2A4C');
  await file(join(legacy, 'lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js'));
  await mkdir(join(legacy, 'bin'), { recursive: true });
  await symlink('../lib/node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js', join(legacy, 'bin/claude-agent-acp'));
  await symlink(join(legacy, 'bin/claude-agent-acp'), join(bin, 'legacy'));
  assert.equal(await linkedGeneration(prefix, join(bin, 'legacy')), legacy);
  // Nothing outside Installations is ever chosen: an npm-global connector, a generation that is
  // itself a link to somewhere else, a missing link, and a plain file.
  await symlink(await file(join(prefix, 'lib/node_modules/@agentclientprotocol/codex-acp/dist/index.js')), join(bin, 'global'));
  assert.equal(await linkedGeneration(prefix, join(bin, 'global')), null);
  const outside = join(root, 'elsewhere');
  await file(join(outside, 'node_modules/.bin/codex-acp'));
  await symlink(outside, join(installations, 'adapter-linked'));
  await symlink(join(installations, 'adapter-linked/node_modules/.bin/codex-acp'), join(bin, 'escaped'));
  assert.equal(await linkedGeneration(prefix, join(bin, 'escaped')), null);
  assert.equal(await linkedGeneration(prefix, join(bin, 'missing')), null);
  assert.equal(await linkedGeneration(prefix, await file(join(bin, 'plain'))), null);
});
