import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, access, readdir, rm, copyFile, symlink } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { prepareNPM } from '../../harnesses/prepare-npm.mjs';

test('Mac bundle preparation uses verified private npm before installing SDKs and keys its cache by tooling provenance', async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-bundle-npm-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  const temporary = join(root, 'temporary'), runtime = join(temporary, 'wovenmatter-node-0.0.1-arm64');
  for (const path of ['scripts', 'default-agent', 'harnesses', 'temporary/wovenmatter-node-0.0.1-arm64/bin']) await mkdir(join(root, path), { recursive: true });
  await copyFile(new URL('../../scripts/prepare-default-agent.sh', import.meta.url), join(root, 'scripts/prepare-default-agent.sh'));
  await writeFile(join(root, 'default-agent/.node-version'), '0.0.1\n');
  await writeFile(join(root, 'default-agent/package.json'), '{}\n');
  await writeFile(join(root, 'default-agent/package-lock.json'), '{}\n');
  await symlink(process.execPath, join(runtime, 'bin/node'));
  const trace = join(root, 'trace');
  await writeFile(join(runtime, 'bin/npm'), '#!/bin/sh\nprintf "bootstrap-ci\\n" >> "$WOVEN_NPM_FIXTURE_TRACE"\nexit 43\n', { mode: 0o755 });
  const provenance = '{"version":"fixture-current"}\n';
  await writeFile(join(root, 'harnesses/prepare-npm.mjs'), `
    import { mkdir, writeFile, appendFile } from 'node:fs/promises';
    import { join } from 'node:path';
    const selection = JSON.parse(process.argv[2]);
    const prefix = join(selection.prefix, 'verified');
    await mkdir(join(prefix, 'bin'), { recursive: true });
    await writeFile(join(prefix, 'provenance.json'), ${JSON.stringify(provenance)});
    await writeFile(join(prefix, 'bin/npm'), '#!/bin/sh\\nprintf "private-ci\\n%s\\n" "$PWD" >> "$WOVEN_NPM_FIXTURE_TRACE"\\nexit 42\\n', { mode: 0o755 });
    await appendFile(process.env.WOVEN_NPM_FIXTURE_TRACE, 'prepare-tooling\\n');
    console.log(join(prefix, 'bin/npm'));
  `);
  const result = spawnSync('/bin/bash', [join(root, 'scripts/prepare-default-agent.sh')], {
    encoding: 'utf8', timeout: 10000,
    env: { ...process.env, TMPDIR: temporary, CURRENT_ARCH: 'arm64', WOVEN_NPM_FIXTURE_TRACE: trace },
  });
  assert.equal(result.status, 42, result.stderr);
  const lines = (await readFile(trace, 'utf8')).trim().split('\n');
  assert.deepEqual(lines.slice(0, 2), ['prepare-tooling', 'private-ci']);
  assert.ok(lines[2].endsWith('-npm-' + createHash('sha256').update(provenance).digest('hex')));
});

test('private npm verifies the archive before execution and applies the locked vendor repairs', async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-private-npm-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  const graph = join(root, 'security'); await mkdir(graph);
  const versions = { undici: '8.12.3', 'ip-address': '10.7.5', minimatch: '11.0.3', '@isaacs/nonrecursive-glob-match': '1.0.3' };
  const packages = Object.fromEntries(Object.entries(versions).map(([name, version]) => ['node_modules/' + name, { version }]));
  await writeFile(join(graph, 'package-lock.json'), JSON.stringify({ packages }));
  await writeFile(join(graph, 'package.json'), '{}');
  const archive = Buffer.from('integrity-verified fixture archive');
  const record = join(root, 'record.json');
  await writeFile(record, JSON.stringify({ version: '12.2.1', url: 'https://registry.npmjs.org/npm/-/fixture.tgz', integrity: 'sha512-' + createHash('sha512').update(archive).digest('base64') }));
  const marker = join(root, 'bootstrap-ran');
  const bootstrap = join(root, 'bootstrap.cjs');
  await writeFile(bootstrap, `
    const fs = require('node:fs'), path = require('node:path');
    fs.writeFileSync(${JSON.stringify(marker)}, 'executed');
    const prefix = process.argv[process.argv.indexOf('--prefix') + 1];
    const write = (name, text) => { const p=path.join(prefix,name); fs.mkdirSync(path.dirname(p), {recursive:true}); fs.writeFileSync(p,text); };
    if (process.argv.includes('install')) {
      write('lib/node_modules/npm/package.json', JSON.stringify({version:'12.2.1'}));
      write('lib/node_modules/npm/bin/npm-cli.js', 'console.log("12.2.1");');
      write('lib/node_modules/npm/node_modules/undici/package.json', JSON.stringify({version:'6.29.0'}));
      fs.mkdirSync(path.join(prefix,'bin'), {recursive:true});
      fs.symlinkSync('../lib/node_modules/npm/bin/npm-cli.js',path.join(prefix,'bin/npm'));
    } else {
      write('node_modules/undici/package.json', JSON.stringify({version:'8.12.3',main:'index.js'}));
      write('node_modules/undici/index.js', 'exports.request = function() {};');
      write('node_modules/ip-address/package.json', JSON.stringify({version:'10.7.5',main:'index.js'}));
      write('node_modules/ip-address/index.js', 'exports.Address6 = class {};');
      write('node_modules/minimatch/package.json', JSON.stringify({version:'11.0.3',main:'index.js'}));
      write('node_modules/minimatch/index.js', 'exports.minimatch = function() {};');
      write('node_modules/@isaacs/nonrecursive-glob-match/package.json', JSON.stringify({version:'1.0.3'}));
    }
  `);
  const options = { prefix: join(root, 'private'), node: process.execPath, bootstrap: [process.execPath, bootstrap], securityGraph: graph, recordPath: record };
  await assert.rejects(prepareNPM({ ...options, fetchImplementation: async () => new Response('tampered') }), /integrity mismatch/);
  await assert.rejects(access(marker), { code: 'ENOENT' }, 'unverified archive must not reach the bootstrap');
  assert.equal((await readdir(join(root, 'private'))).length, 0, 'failed staging is removed');
  const npm = await prepareNPM({ ...options, fetchImplementation: async () => new Response(archive) });
  const directory = join(npm, '../..');
  for (const [name, version] of Object.entries(versions)) assert.equal(JSON.parse(await readFile(join(directory, 'lib/node_modules/npm/node_modules', name, 'package.json'), 'utf8')).version, version);
  const provenance = JSON.parse(await readFile(join(directory, 'provenance.json'), 'utf8'));
  assert.equal(provenance.version, '12.2.1');
  assert.equal(typeof provenance.securityLockSHA256, 'string');
  assert.equal(await prepareNPM({ ...options, fetchImplementation: async () => { throw Error('cached selection must not download'); } }), npm);
});
