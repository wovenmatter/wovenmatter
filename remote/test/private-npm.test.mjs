import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtemp, mkdir, writeFile, readFile, access, readdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { prepareNPM } from '../../harnesses/prepare-npm.mjs';

test('private npm verifies the archive before execution and applies the locked vendor repairs', async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-private-npm-'));
  t.after(() => rm(root, { force: true, recursive: true }));
  const graph = join(root, 'security'); await mkdir(graph);
  const versions = { undici: '8.12.3', 'ip-address': '10.7.5' };
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
