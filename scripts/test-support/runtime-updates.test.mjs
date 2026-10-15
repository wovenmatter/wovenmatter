import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { runtimeUpdatePlan } from '../update-runtime-dependencies.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const paths = ['remote/Dockerfile', 'remote/Executor.Dockerfile', 'scripts/prepare-default-agent.sh',
  'app/Sources/WovenMatterClient/LocalACPManagedRuntime.swift', 'default-agent/package.json', 'docs/reference/DEFAULT_AGENT.md',
  'THIRD_PARTY_NOTICES.md', 'ios/Runtime/README.md'];
async function fixture(t) {
  const root = await mkdtemp(resolve(tmpdir(), 'woven-runtime-updates-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const original = new Map();
  for (const name of paths) {
    let content = await readFile(resolve(repo, name), 'utf8');
    // Fixed fixture releases keep these tests independent of future pin refreshes.
    const baseline = '24.22.0';
    if (name.endsWith('.Dockerfile') || name === 'remote/Dockerfile') content = content
      .replace(/^FROM node:[^\n]+/m, `FROM node:${baseline}-trixie-slim@sha256:${'d'.repeat(64)}`)
      .replace(/npm@\d+\.\d+\.\d+/g, 'npm@12.2.0').replace(/playwright@\d+\.\d+\.\d+/g, 'playwright@1.64.1');
    if (name === 'scripts/prepare-default-agent.sh') content = content.replace(/^version=[^\n]+/m, `version=${baseline}`);
    if (name.endsWith('LocalACPManagedRuntime.swift')) content = content.replace(/v\d+\.\d+\.\d+/g, 'v' + baseline);
    if (name === 'default-agent/package.json') {
      const manifest = JSON.parse(content);
      Object.assign(manifest.dependencies, { '@anthropic-ai/claude-agent-sdk': '~0.3.300',
        '@earendil-works/pi-ai': '^1.2.0', '@earendil-works/pi-coding-agent': '^1.2.0', '@earendil-works/pi-durable': '^1.2.0',
        '@modelcontextprotocol/sdk': '^1.32.1', 'playwright-core': '1.64.1', ws: '8.22.0', 'proper-lockfile': '^4.1.2', typebox: '^1.3.37' });
      manifest.devDependencies.esbuild = '~0.28.2';
      content = JSON.stringify(manifest, null, 2) + '\n';
    }
    original.set(name, content);
    await mkdir(dirname(resolve(root, name)), { recursive: true });
    await writeFile(resolve(root, name), content);
  }
  return { root, original };
}
function metadata({ missingChecksum = false } = {}) {
  const releases = {
    '@anthropic-ai/claude-agent-sdk': ['0.4.0', '0.3.301'],
    '@earendil-works/pi-ai': ['2.0.0', '1.3.0'],
    '@earendil-works/pi-coding-agent': ['2.0.0', '1.3.0'],
    '@earendil-works/pi-durable': ['2.0.0', '1.3.0'],
    '@earendil-works/chord': ['2.0.0', '1.3.0'],
    '@modelcontextprotocol/sdk': ['1.32.1'], 'proper-lockfile': ['4.1.2'], 'typebox': ['1.3.38'],
    'playwright-core': ['2.0.0', '1.65.0'], 'ws': ['9.0.0', '8.23.0'],
    'esbuild': ['0.29.0', '0.28.3'], 'npm': ['13.0.0', '12.3.0'], 'playwright': ['2.0.0', '1.65.0'],
  };
  return async url => {
    if (url.endsWith('/index.json')) return Response.json([
      { version: 'v24.23.0', lts: 'Krypton' }, { version: 'v26.13.0', lts: 'New LTS' }, { version: 'v24.24.0-rc.1', lts: 'Krypton' },
    ]);
    if (url.endsWith('/SHASUMS256.txt')) return new Response(`${'a'.repeat(64)}  node-v24.23.0-darwin-arm64.tar.gz\n` +
      (missingChecksum ? '' : `${'b'.repeat(64)}  node-v24.23.0-darwin-x64.tar.gz\n`));
    if (url.includes('hub.docker.com')) {
      assert.ok(url.endsWith('/24.23.0-trixie-slim'));
      return Response.json({ digest: 'sha256:' + 'c'.repeat(64), images: ['amd64', 'arm64'].map(architecture => ({ architecture, os: 'linux', status: 'active' })) });
    }
    const name = decodeURIComponent(url.slice('https://registry.npmjs.org/'.length).replace(/\/latest$/, ''));
    const versions = releases[name];
    assert.ok(versions, name);
    return Response.json(url.endsWith('/latest') ? { version: versions[0] } : { versions: Object.fromEntries(versions.map(version => [version, {}])) });
  };
}
test('check plans synchronized runtime pins, stays on supported channels, and never writes', async t => {
  const { root, original } = await fixture(t);
  const plan = await runtimeUpdatePlan({ root, fetchImplementation: metadata() });
  for (const name of paths) assert.equal(await readFile(resolve(root, name), 'utf8'), original.get(name));
  const packages = JSON.parse(plan.files.get('default-agent/package.json'));
  assert.equal(packages.dependencies['@anthropic-ai/claude-agent-sdk'], '~0.3.301');
  assert.equal(packages.dependencies['@earendil-works/pi-durable'], '^1.3.0');
  assert.equal(packages.devDependencies.esbuild, '~0.28.3');
  assert.equal(packages.dependencies['playwright-core'], '1.65.0');
  assert.equal(packages.dependencies.ws, '8.23.0');
  assert.equal(plan.files.get('remote/Dockerfile').split('\n')[0], 'FROM node:24.23.0-trixie-slim@sha256:' + 'c'.repeat(64));
  assert.ok(plan.files.get('remote/Executor.Dockerfile').includes('npm@12.3.0'));
  for (const file of ['scripts/prepare-default-agent.sh', 'app/Sources/WovenMatterClient/LocalACPManagedRuntime.swift']) {
    assert.ok(plan.files.get(file).includes('24.23.0'));
    assert.ok(plan.files.get(file).includes('a'.repeat(64)));
    assert.ok(plan.files.get(file).includes('b'.repeat(64)));
  }
});
test('incomplete archive metadata fails before any source changes', async t => {
  const { root, original } = await fixture(t);
  await assert.rejects(runtimeUpdatePlan({ root, fetchImplementation: metadata({ missingChecksum: true }) }), /checksum/);
  for (const name of paths) assert.equal(await readFile(resolve(root, name), 'utf8'), original.get(name));
});
test('diverged image pins require reconciliation rather than silently selecting one', async t => {
  const { root, original } = await fixture(t);
  await writeFile(resolve(root, 'remote/Executor.Dockerfile'), original.get('remote/Executor.Dockerfile').replace('trixie-slim', 'bookworm-slim'));
  await assert.rejects(runtimeUpdatePlan({ root, fetchImplementation: metadata() }), /base pins differ/);
  assert.equal(await readFile(resolve(root, 'remote/Dockerfile'), 'utf8'), original.get('remote/Dockerfile'));
});
