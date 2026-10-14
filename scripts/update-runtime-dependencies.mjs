#!/usr/bin/env node
// Developer maintenance only. Never deploys, starts services, or uses provider APIs.
import { readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { latestSupportedPackage, compareVersions } from '../default-agent/src/package-versions.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const sourceFiles = [
  'remote/Dockerfile', 'remote/Executor.Dockerfile', 'scripts/prepare-default-agent.sh',
  'app/Sources/WovenMatterClient/LocalACPManagedRuntime.swift', 'default-agent/package.json',
  'docs/reference/DEFAULT_AGENT.md',
  'THIRD_PARTY_NOTICES.md', 'ios/Runtime/README.md',
];
const match = (text, pattern, description) => {
  const result = text.match(pattern);
  if (!result) throw new Error(`Cannot find ${description}; review the maintenance script before updating.`);
  return result;
};
async function source(url, fetchImplementation) {
  const response = await fetchImplementation(url, { signal: AbortSignal.timeout(30000) });
  if (!response.ok) throw new Error(`Runtime metadata unavailable: ${url}`);
  return response.text();
}

export async function runtimeUpdatePlan({ root = repoRoot, fetchImplementation = fetch } = {}) {
  const files = new Map(await Promise.all(sourceFiles.map(async name => [name, await readFile(resolve(root, name), 'utf8')])));
  const original = new Map(files);
  const preparation = files.get('scripts/prepare-default-agent.sh');
  const oldNode = match(preparation, /^version=(\d+\.\d+\.\d+)$/m, 'bundled Node version')[1];
  const nodeMajor = Number(oldNode.split('.')[0]);
  const releases = JSON.parse(await source('https://nodejs.org/dist/index.json', fetchImplementation));
  const node = releases.filter(item => item.lts && new RegExp(`^v${nodeMajor}\\.\\d+\\.\\d+$`).test(item.version))
    .sort((a, b) => compareVersions(a.version.slice(1), b.version.slice(1))).at(-1)?.version.slice(1);
  if (!node || compareVersions(node, oldNode) < 0) throw new Error('No current supported Node LTS release is available.');
  const sums = await source(`https://nodejs.org/dist/v${node}/SHASUMS256.txt`, fetchImplementation);
  const checksums = Object.fromEntries(sums.trim().split('\n').map(line => line.trim().split(/\s+/).reverse()));
  for (const arch of ['arm64', 'x64']) {
    if (!/^[a-f0-9]{64}$/.test(checksums[`node-v${node}-darwin-${arch}.tar.gz`] ?? '')) throw new Error('Node archive checksum is unavailable.');
  }

  const workspace = files.get('remote/Dockerfile');
  const oldBase = match(workspace, /^FROM (node:\d+\.\d+\.\d+-([a-z]+)-slim@sha256:[a-f0-9]{64})$/m, 'pinned workspace base');
  const executor = files.get('remote/Executor.Dockerfile');
  if (!executor.includes(`FROM ${oldBase[1]}\n`)) throw new Error('Workspace and Executor base pins differ; reconcile them before updating.');
  const tag = `${node}-${oldBase[2]}-slim`;
  const image = JSON.parse(await source(`https://hub.docker.com/v2/repositories/library/node/tags/${tag}`, fetchImplementation));
  if (!/^sha256:[a-f0-9]{64}$/.test(image.digest ?? '') || !['amd64', 'arm64'].every(arch =>
    image.images?.some(item => item.os === 'linux' && item.architecture === arch && item.status === 'active'))) {
    throw new Error('The Node image is missing a manifest digest or a supported Linux architecture.');
  }
  const base = `node:${tag}@${image.digest}`;
  const updates = [{ name: 'Node LTS', installed: oldNode, latest: node },
    { name: 'Linux base image', installed: oldBase[1], latest: base }];
  for (const name of ['remote/Dockerfile', 'remote/Executor.Dockerfile']) files.set(name, files.get(name).replace(oldBase[1], base));
  for (const name of ['scripts/prepare-default-agent.sh', 'app/Sources/WovenMatterClient/LocalACPManagedRuntime.swift']) {
    let content = files.get(name);
    if (!content.includes(oldNode)) throw new Error('Managed and bundled Node versions differ.');
    for (const arch of ['arm64', 'x64']) {
      const prefix = arch === 'arm64' ? 'arm64' : 'x86_64';
      const oldChecksum = match(preparation, new RegExp(`${prefix}\\) node_arch=${arch}; checksum=([a-f0-9]{64})`), `Node ${arch} checksum`)[1];
      if (!content.includes(oldChecksum)) throw new Error('Managed and bundled Node archive checksums differ.');
      content = content.replaceAll(oldChecksum, checksums[`node-v${node}-darwin-${arch}.tar.gz`]);
    }
    files.set(name, content.replaceAll(oldNode, node));
  }
  files.set('docs/reference/DEFAULT_AGENT.md', files.get('docs/reference/DEFAULT_AGENT.md').replace(`Node ${oldNode}`, `Node ${node}`));

  const packages = JSON.parse(files.get('default-agent/package.json'));
  const oldPi = packages.dependencies['@earendil-works/pi-durable'].replace(/^[~^]/, '');
  for (const group of ['dependencies', 'devDependencies']) for (const [name, range] of Object.entries(packages[group] ?? {})) {
    const [, prefix, major, minor] = match(range, /^(\^|~)?(\d+)\.(\d+)\.\d+$/, `${name} supported range`);
    const latest = await latestSupportedPackage(name, { major: Number(major), minor: Number(major) === 0 ? Number(minor) : undefined, fetchImplementation });
    const installed = range.replace(/^[~^]/, '');
    if (compareVersions(latest, installed) < 0) throw new Error(`Refusing to downgrade ${name}.`);
    packages[group][name] = (prefix ?? '') + latest;
    updates.push({ name, installed, latest });
  }
  const piVersions = Object.entries(packages.dependencies).filter(([name]) => name.startsWith('@earendil-works/pi-')).map(([, range]) => range.replace(/^[~^]/, ''));
  if (new Set(piVersions).size !== 1) throw new Error('Pi package releases are not aligned; retry after publication finishes.');
  const chord = await latestSupportedPackage('@earendil-works/chord', { major: Number(piVersions[0].split('.')[0]), fetchImplementation });
  if (chord !== piVersions[0]) throw new Error('Pi and Chord releases are not aligned; retry after publication finishes.');
  for (const name of ['THIRD_PARTY_NOTICES.md', 'ios/Runtime/README.md']) files.set(name, files.get(name).replaceAll(oldPi, piVersions[0]));
  files.set('default-agent/package.json', JSON.stringify(packages, null, 2) + '\n');
  for (const name of ['npm', 'playwright']) {
    const oldVersion = match(workspace, new RegExp(`\\b${name}@(\\d+\\.\\d+\\.\\d+)`), `${name} image pin`)[1];
    const latest = await latestSupportedPackage(name, { major: Number(oldVersion.split('.')[0]), fetchImplementation });
    if (compareVersions(latest, oldVersion) < 0) throw new Error(`Refusing to downgrade ${name}.`);
    if (name === 'npm' && !executor.includes(`npm@${oldVersion}`)) throw new Error('Workspace and Executor npm pins differ.');
    for (const file of ['remote/Dockerfile', 'remote/Executor.Dockerfile']) files.set(file, files.get(file).replace(`${name}@${oldVersion}`, `${name}@${latest}`));
    updates.push({ name, installed: oldVersion, latest });
  }
  return { updates, files: new Map([...files].filter(([name, content]) => content !== original.get(name))) };
}

async function main() {
  const mode = process.argv[2] ?? '--check';
  if (!['--check', '--write'].includes(mode) || process.argv.length > 3) throw new Error('usage: node scripts/update-runtime-dependencies.mjs [--check|--write]');
  const plan = await runtimeUpdatePlan();
  for (const update of plan.updates) console.log(`${update.name}: ${update.installed} -> ${update.latest}`);
  if (mode === '--check') {
    console.log(`${plan.files.size} source files need updates. Check only; lockfile and generated resources were not changed.`);
    return;
  }
  for (const [name, content] of plan.files) await writeFile(resolve(repoRoot, name), content);
  const run = (executable, args) => {
    const result = spawnSync(executable, args, { cwd: repoRoot, stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error('Runtime refresh failed. Review the worktree diff and rerun before committing.');
  };
  const npmOptions = ['--prefix', 'default-agent', '--ignore-scripts', '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'];
  run('npm', ['update', '--package-lock-only', ...npmOptions]);
  const manifest = JSON.parse(await readFile(resolve(repoRoot, 'default-agent/package.json'), 'utf8'));
  const lock = JSON.parse(await readFile(resolve(repoRoot, 'default-agent/package-lock.json'), 'utf8'));
  for (const update of plan.updates) if (manifest.dependencies?.[update.name] || manifest.devDependencies?.[update.name]) {
    if (lock.packages[`node_modules/${update.name}`]?.version !== update.latest) throw new Error('Package releases changed during refresh. Rerun before generating resources.');
  }
  run('npm', ['ci', ...npmOptions]);
  run(process.execPath, ['scripts/build-ios-pi-runtime.mjs']);
  console.log('Updated runtime pins, lockfile, and mobile SDK resources. Review the diff and run scripts/test-changes.sh --all.');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
