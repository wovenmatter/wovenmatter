#!/usr/bin/env node
// Maintenance-time selection for coordinated runtime records that Dependabot
// cannot update coherently: Node, CEF, Sparkle, Peekaboo, and the npm packages
// that generate the offline mobile bundles. Builds and tests only consume the
// committed records and lockfiles. Never deploys, publishes, or starts services.
import { readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { tmpdir } from 'node:os';
import { compareVersions, rangeFloor, satisfiesRange, selectPackageRelease } from '../default-agent/src/package-versions.mjs';

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), '..');
export const recordFiles = {
  node: 'default-agent/.node-version', prepare: 'scripts/prepare-default-agent.sh',
  managed: 'app/Sources/WovenMatterClient/LocalACPManagedRuntime.swift',
  workspace: 'remote/Dockerfile', executor: 'remote/Executor.Dockerfile', cef: 'app/Browser/cef-version.json',
  project: 'app/WovenMatter.xcodeproj/project.pbxproj', resolved: 'app/Package.resolved', manifest: 'app/Package.swift',
  sparkle: 'app/Updater/sparkle-version.json', agent: 'default-agent/package.json', embedded: 'ios/EmbeddedRuntime/package.json',
  notices: 'THIRD_PARTY_NOTICES.md', appNotices: 'app/App/ThirdPartyNotices.txt', updates: 'docs/DESKTOP_UPDATES.md',
};
// [npm/Node arch, prepare-script/CEF arch, CEF platform]
const architectures = [['arm64', 'arm64', 'macosarm64'], ['x64', 'x86_64', 'macosx64']];
const pi = ['@earendil-works/pi-durable', '@earendil-works/pi-ai', '@earendil-works/pi-coding-agent'];
// Generated mobile resources depend on these, so they refresh together here;
// Dependabot maintains the other npm dependencies.
const npmGroups = [
  { name: 'Pi SDK family and Chord', declared: pi, select: [...pi, '@earendil-works/chord'], manifests: ['agent'] },
  { name: 'Claude agent SDK', declared: ['@anthropic-ai/claude-agent-sdk'], manifests: ['agent'] },
  { name: 'esbuild (mobile bundle builds)', declared: ['esbuild'], manifests: ['agent', 'embedded'] },
  { name: 'Pyodide (iOS Python runtime)', declared: ['pyodide'], manifests: ['embedded'] },
];
// Only the V2 APIs are implemented; a new upstream major needs an app change.
const apiLines = [['OpenCode', '@opencode/cli', 2, false], ['Executor', 'executor', 2, true]];

const stable = value => typeof value === 'string' && /^\d+\.\d+\.\d+$/.test(value);
const major = value => Number(value.split('.')[0]);
const compareDotted = (a, b) => { const x = a.split('.').map(Number), y = b.split('.').map(Number); for (let i = 0; i < Math.max(x.length, y.length); i++) if ((x[i] ?? 0) !== (y[i] ?? 0)) return (x[i] ?? 0) - (y[i] ?? 0); return 0; };
const match = (text, pattern, description) => {
  const result = text.match(pattern);
  if (!result) throw new Error(`Cannot find ${description}; review the maintenance script before updating.`);
  return result;
};
const replaceOnce = (text, from, to, description) => {
  if (text.split(from).length !== 2) throw new Error(`Cannot find a single ${description}; review the maintenance script before updating.`);
  return text.replace(from, () => to);
};
const pin = (resolved, identity) => {
  const value = resolved.pins.find(entry => entry.identity === identity);
  if (!value) throw new Error(`Cannot find ${identity} in app/Package.resolved; review the maintenance script before updating.`);
  return value;
};
const newestBy = (values, compare) => [...values].sort(compare).at(-1);

// Parses every committed record and rejects drift between copies of one selection.
export async function readRecords(root = repoRoot) {
  const text = Object.fromEntries(await Promise.all(Object.entries(recordFiles).map(async ([key, name]) => [key, await readFile(resolve(root, name), 'utf8')])));
  const node = text.node.trim();
  if (!stable(node)) throw new Error('default-agent/.node-version must name one stable Node release.');
  const checksums = {};
  for (const [arch, prefix] of architectures) {
    checksums[arch] = match(text.prepare, new RegExp(`${prefix}\\) node_arch=${arch}; checksum=([a-f0-9]{64})`), `Node ${arch} checksum`)[1];
    if (!text.managed.includes(`archiveFileName: "node-v${node}-darwin-${arch}.tar.gz",\n            sha256: "${checksums[arch]}"`)) {
      throw new Error('The managed Node runtime and the bundled Node record differ; reconcile them before updating.');
    }
  }
  const bases = [text.workspace, text.executor].map(content => match(content, /^FROM node:(\d+)-([a-z]+)-slim$/m, 'Linux Node base line'));
  if (bases.some(base => Number(base[1]) !== major(node) || base[2] !== bases[0][2])) throw new Error('Linux base images must follow the bundled Node LTS line.');
  const cef = JSON.parse(text.cef);
  // Xcode resolves Sparkle directly from the project; this record names that
  // release, its exact revision, and the matching tools archive digest.
  const sparkle = JSON.parse(text.sparkle);
  if (!stable(sparkle.version) || !/^[a-f0-9]{40}$/.test(sparkle.revision ?? '') || !/^[a-f0-9]{64}$/.test(sparkle.toolsSHA256 ?? '')) {
    throw new Error('app/Updater/sparkle-version.json is incomplete.');
  }
  if (match(text.project, /sparkle-project\/Sparkle";\s*requirement = \{ kind = revision; revision = ([a-f0-9]{40}); \}/, 'Sparkle requirement')[1] !== sparkle.revision) {
    throw new Error('The Xcode Sparkle requirement and app/Updater/sparkle-version.json differ.');
  }
  // SwiftPM alone writes app/Package.resolved; it is only read to check Peekaboo.
  const resolved = JSON.parse(text.resolved);
  const peekaboo = { version: match(text.manifest, /openclaw\/Peekaboo\.git", exact: "(\d+\.\d+\.\d+)"/, 'Peekaboo release')[1], revision: pin(resolved, 'peekaboo').state.revision };
  if (pin(resolved, 'peekaboo').state.version !== peekaboo.version) throw new Error('Peekaboo requirement and resolved pin differ.');
  const manifests = { agent: JSON.parse(text.agent), embedded: JSON.parse(text.embedded) };
  const declaration = (manifest, name) => manifest.dependencies?.[name] ?? manifest.devDependencies?.[name];
  const npm = npmGroups.map(group => {
    const ranges = new Set(group.manifests.flatMap(key => group.declared.map(name => declaration(manifests[key], name))));
    const [range] = ranges;
    if (ranges.size !== 1 || !rangeFloor(range) || !/^\^/.test(range)) throw new Error(`${group.name} declarations must share one caret range.`);
    return { ...group, range };
  });
  return { text, node: { version: node, checksums, codename: bases[0][2] }, cef, sparkle, peekaboo, manifests, npm };
}

export async function runtimeUpdatePlan({ root = repoRoot, fetchImplementation = fetch, includeMajors = false, githubToken } = {}) {
  const records = await readRecords(root);
  const request = async (url, accept) => {
    const headers = { 'User-Agent': 'wovenmatter-dependency-refresh', ...(accept ? { Accept: accept } : {}),
      ...(githubToken && url.startsWith('https://api.github.com/') ? { Authorization: `Bearer ${githubToken}` } : {}) };
    const response = await fetchImplementation(url, { headers, signal: AbortSignal.timeout(60000) });
    if (!response.ok) throw new Error(`Upstream metadata unavailable: ${url}`);
    return response;
  };
  const json = async url => (await request(url)).json();
  const text = async (url, accept) => (await request(url, accept)).text();
  const files = new Map(), updates = [], notices = [];
  const edit = (key, change) => files.set(recordFiles[key], change(files.get(recordFiles[key]) ?? records.text[key]));
  // `blocked` is a newer upstream line this plan did not apply. A proposal outside
  // the current caret line (a major, or a 0.x minor) is flagged for review.
  const breaking = (current, proposed) => stable(current) && stable(proposed) ? !satisfiesRange(proposed, '^' + current) : major(current) !== major(proposed);
  const report = (component, current, proposed, newest, note) => updates.push({ component, current, proposed, newest,
    note: note ?? (breaking(current, proposed) ? 'Breaking-line update: review upstream release notes' : undefined),
    changed: proposed !== current, blocked: newest !== proposed && compareVersions(newest, proposed) > 0 ? newest : null });

  // Node: the newest patch of the bundled LTS line, or the newest LTS line with
  // --include-majors. Current (non-LTS) releases are never selected.
  const current = records.node.version;
  const lts = (await json('https://nodejs.org/dist/index.json')).filter(release => release.lts && /^v\d+\.\d+\.\d+$/.test(release.version))
    .map(release => release.version.slice(1)).sort(compareVersions);
  const newestNode = lts.at(-1) ?? current;
  let node = (includeMajors ? newestNode : lts.filter(version => major(version) === major(current)).at(-1)) ?? current;
  if (compareVersions(node, current) < 0) node = current;
  if (node !== current) {
    const sums = Object.fromEntries((await text(`https://nodejs.org/dist/v${node}/SHASUMS256.txt`)).trim().split('\n').map(line => line.trim().split(/\s+/).reverse()));
    const checksums = Object.fromEntries(architectures.map(([arch]) => [arch, sums[`node-v${node}-darwin-${arch}.tar.gz`]]));
    if (!Object.values(checksums).every(value => /^[a-f0-9]{64}$/.test(value ?? ''))) throw new Error('Node archive checksum is unavailable for every macOS architecture.');
    edit('node', () => node + '\n');
    for (const key of ['prepare', 'managed']) edit(key, content => {
      for (const [arch] of architectures) content = replaceOnce(content, records.node.checksums[arch], checksums[arch], `Node ${arch} checksum`);
      return content.replaceAll(`v${current}`, `v${node}`);
    });
    if (major(node) !== major(current)) for (const key of ['workspace', 'executor']) {
      edit(key, content => replaceOnce(content, `FROM node:${major(current)}-`, `FROM node:${major(node)}-`, 'Linux Node base line'));
    }
  }
  report('Node.js LTS (bundled app, managed adapters, CI, Linux base line)', current, node, newestNode);

  // CEF: always the newest stable build. Chromium fixes only ship on its current
  // major, so staying on an old CEF line is a security risk; CI validates the build.
  const index = await json('https://cef-builds.spotifycdn.com/index.json');
  const builds = architectures.map(([, key, platform]) => {
    const build = newestBy((index[platform]?.versions ?? []).filter(version => version.channel === 'stable'
      && version.files?.some(file => file.type === 'minimal' && /^[a-f0-9]{40}$/.test(file.sha1 ?? ''))), (a, b) => compareDotted(a.chromium_version, b.chromium_version)
        || compareDotted(a.cef_version.split('+')[0], b.cef_version.split('+')[0]));
    return build && { key, platform, version: build.cef_version, chromium: build.chromium_version, sha1: build.files.find(file => file.type === 'minimal').sha1 };
  });
  let cef = records.cef.version;
  if (builds.some(build => !build) || new Set(builds.map(build => build.version)).size !== 1) {
    notices.push('CEF: the newest stable build is not published for every macOS architecture yet; the current build is kept.');
  } else if (compareDotted(builds[0].chromium, records.cef.chromium) > 0
    || (builds[0].chromium === records.cef.chromium
      && compareDotted(builds[0].version.split('+')[0], records.cef.version.split('+')[0]) > 0)) {
    cef = builds[0].version;
    edit('cef', () => JSON.stringify({ version: cef, chromium: builds[0].chromium,
      archives: Object.fromEntries(builds.map(build => [build.key, { platform: build.platform, sha1: build.sha1 }])) }, null, 2)
      .replace(/\{\n\s+"platform": ("[^"]+"),\n\s+"sha1": ("[^"]+")\n\s+\}/g, '{"platform": $1, "sha1": $2}') + '\n');
  }
  report('CEF (embedded Chromium)', records.cef.version, cef, cef,
    major(cef) !== major(records.cef.version) ? `Chromium ${major(records.cef.version)} → ${major(cef)}: review browser behavior` : undefined);

  // Sparkle framework and tools: one release record and the matching exact
  // Xcode revision, because the updater delivers every later fix.
  const sparkleReleases = (await json('https://api.github.com/repos/sparkle-project/Sparkle/releases?per_page=50'))
    .filter(release => !release.draft && !release.prerelease && stable(release.tag_name));
  const sparkleCurrent = records.sparkle.version;
  const sparkleNewest = newestBy(sparkleReleases.map(release => release.tag_name), compareVersions) ?? sparkleCurrent;
  let sparkle = (includeMajors ? sparkleNewest : newestBy(sparkleReleases.map(release => release.tag_name).filter(version => major(version) === major(sparkleCurrent)), compareVersions)) ?? sparkleCurrent;
  if (compareVersions(sparkle, sparkleCurrent) < 0) sparkle = sparkleCurrent;
  if (sparkle !== sparkleCurrent) {
    const release = sparkleReleases.find(value => value.tag_name === sparkle);
    const digest = release.assets?.find(asset => asset.name === `Sparkle-${sparkle}.tar.xz`)?.digest?.replace(/^sha256:/, '');
    const revision = (await text(`https://api.github.com/repos/sparkle-project/Sparkle/commits/${sparkle}`, 'application/vnd.github.sha')).trim();
    if (!/^[a-f0-9]{64}$/.test(digest ?? '') || !/^[a-f0-9]{40}$/.test(revision)) throw new Error('Sparkle release digest or revision is unavailable.');
    edit('sparkle', () => JSON.stringify({ version: sparkle, revision, toolsSHA256: digest }, null, 2) + '\n');
    edit('project', content => replaceOnce(content, `kind = revision; revision = ${records.sparkle.revision};`, `kind = revision; revision = ${revision};`, 'Sparkle requirement'));
    for (const key of ['notices', 'appNotices', 'updates']) edit(key, content => content.replaceAll(`Sparkle ${sparkleCurrent}`, `Sparkle ${sparkle}`));
  }
  report('Sparkle (updater framework and tools)', sparkleCurrent, sparkle, sparkleNewest);

  // Peekaboo: exact release tags only.
  const tags = (await json('https://api.github.com/repos/openclaw/Peekaboo/tags?per_page=100'))
    .map(tag => ({ version: tag.name.replace(/^v/, ''), revision: tag.commit?.sha })).filter(tag => stable(tag.version) && /^[a-f0-9]{40}$/.test(tag.revision ?? ''));
  const peekabooCurrent = records.peekaboo.version;
  const peekabooNewest = newestBy(tags.map(tag => tag.version), compareVersions) ?? peekabooCurrent;
  let peekaboo = (includeMajors ? peekabooNewest : newestBy(tags.map(tag => tag.version).filter(version => major(version) === major(peekabooCurrent)), compareVersions)) ?? peekabooCurrent;
  if (compareVersions(peekaboo, peekabooCurrent) < 0) peekaboo = peekabooCurrent;
  if (peekaboo !== peekabooCurrent) {
    const { revision } = tags.find(tag => tag.version === peekaboo);
    edit('manifest', content => replaceOnce(content, `exact: "${peekabooCurrent}"`, `exact: "${peekaboo}"`, 'Peekaboo requirement'));
    // --write runs SwiftPM, which alone regenerates app/Package.resolved.
    for (const key of ['notices', 'appNotices']) edit(key, content => content.replaceAll(records.peekaboo.revision, revision));
  }
  report('Peekaboo (computer use, in the signed app process)', peekabooCurrent, peekaboo, peekabooNewest);

  // npm packages behind generated resources: newest in the declared caret line
  // (or newest stable with --include-majors); the floor rises to the selection.
  const npm = [];
  for (const group of records.npm) {
    const floor = rangeFloor(group.range);
    const { selected, latest } = await selectPackageRelease(group.select ?? group.declared, { range: includeMajors ? undefined : group.range, fetchImplementation });
    const proposed = compareVersions(selected, floor) > 0 ? selected : floor;
    if (proposed !== floor) {
      for (const key of group.manifests) {
        const manifest = JSON.parse(files.get(recordFiles[key]) ?? records.text[key]);
        for (const section of ['dependencies', 'devDependencies']) for (const name of group.declared) if (manifest[section]?.[name]) manifest[section][name] = '^' + proposed;
        edit(key, () => JSON.stringify(manifest, null, 2) + '\n');
      }
      npm.push(...group.declared.map(name => [name, proposed, group.manifests]));
    }
    report(group.name, floor, proposed, latest);
  }

  for (const [name, packageName, supported, prerelease] of apiLines) {
    const { latest } = await selectPackageRelease(packageName, { major: supported, prerelease, fetchImplementation });
    if (major(latest) > supported) notices.push(`${name} ${latest} is available upstream. Woven Matter implements the v${supported} API, so installs stay on v${supported} until the app supports the new API.`);
  }
  return { updates, notices, files, npm, swiftResolve: peekaboo !== peekabooCurrent, includeMajors };
}

export function renderReport(plan) {
  const row = update => `| ${update.component} | ${update.current} | ${update.changed ? `**${update.proposed}**` : 'unchanged'} | ${update.newest} | ${update.note ?? ''} |`;
  const blocked = plan.updates.filter(update => update.blocked);
  return [
    '## Coordinated dependency refresh', '',
    '| Component | Current | Proposed | Newest upstream | Notes |', '| --- | --- | --- | --- | --- |', ...plan.updates.map(row), '',
    ...(blocked.length ? ['### Newer major lines not applied in this run', '',
      ...blocked.map(update => `- ${update.component}: ${update.newest}. Rerun with \`--include-majors\` (the daily workflow always does) to propose it through CI.`), ''] : []),
    ...(plan.notices.length ? ['### Notices', '', ...plan.notices.map(notice => `- ${notice}`), ''] : []),
    'Delivery: the Node runtime, CEF, Sparkle, Peekaboo, and the bundled SDK snapshot reach installed Mac apps only through a signed app or refresh build; iOS resources require an App Store build. Linux images pick these up when rebuilt. In-app SDK and harness updates within the declared ranges do not wait for this PR.', '',
  ].join('\n');
}

async function main() {
  const args = process.argv.slice(2);
  const reportIndex = args.indexOf('--report');
  const reportPath = reportIndex >= 0 ? args.splice(reportIndex, 2)[1] : undefined;
  const includeMajors = args.includes('--include-majors');
  const modes = args.filter(arg => arg !== '--include-majors');
  if ((reportIndex >= 0 && !reportPath) || modes.length > 1 || !['--check', '--write', undefined].includes(modes[0])) {
    throw new Error('usage: node scripts/update-runtime-dependencies.mjs [--check|--write] [--include-majors] [--report file]');
  }
  const plan = await runtimeUpdatePlan({ includeMajors, githubToken: process.env.GITHUB_TOKEN || process.env.GH_TOKEN });
  const report = renderReport(plan);
  if (reportPath) await writeFile(reportPath, report);
  console.log(report);
  if (modes[0] !== '--write') return;
  const run = (executable, runArgs, cwd = repoRoot) => {
    const result = spawnSync(executable, runArgs, { cwd, stdio: 'inherit' });
    if (result.error) throw result.error;
    if (result.status !== 0) throw new Error(`${executable} ${runArgs.join(' ')} failed. Review the worktree before committing.`);
  };
  for (const [name, content] of plan.files) await writeFile(resolve(repoRoot, name), content);
  const npmOptions = ['--ignore-scripts', '--no-audit', '--no-fund', '--registry=https://registry.npmjs.org'];
  if (plan.npm.length) {
    for (const directory of ['default-agent', 'ios/EmbeddedRuntime']) run('npm', ['install', '--package-lock-only', '--prefix', directory, ...npmOptions]);
    for (const [name, version, manifests] of plan.npm) for (const key of manifests) {
      const lock = JSON.parse(await readFile(resolve(repoRoot, dirname(recordFiles[key]), 'package-lock.json'), 'utf8'));
      if (lock.packages[`node_modules/${name}`]?.version !== version) throw new Error(`${name} ${version} was not locked; upstream changed during refresh. Rerun.`);
    }
  }
  // One maintenance pipeline owns app/Package.resolved. Refresh allowed Swift
  // transitives, then let Xcode generate the complete shared graph, including
  // Sparkle. Normal SwiftPM/Xcode builds consume this file with resolution frozen.
  const beforeNative = JSON.parse(await readFile(resolve(repoRoot, recordFiles.resolved), 'utf8'));
  const nativeCache = resolve(process.env.WOVENMATTER_DEPENDENCY_CACHE_DIR || process.env.RUNNER_TEMP || tmpdir(), 'wovenmatter-dependency-refresh');
  run('swift', ['package', 'update', '--package-path', 'app', '--scratch-path', resolve(nativeCache, 'SwiftPM')]);
  run('xcodebuild', ['-resolvePackageDependencies', '-project', 'app/WovenMatter.xcodeproj', '-scheme', 'WovenMatter',
    '-clonedSourcePackagesDirPath', resolve(nativeCache, 'NativeSwiftPackages')]);
  const afterNative = JSON.parse(await readFile(resolve(repoRoot, recordFiles.resolved), 'utf8'));
  const lockedSparkle = afterNative.pins.find(value => value.identity === 'sparkle');
  const sparkleRecord = JSON.parse(await readFile(resolve(repoRoot, recordFiles.sparkle), 'utf8'));
  if (lockedSparkle?.state?.revision !== sparkleRecord.revision) throw new Error('Xcode did not lock the recorded Sparkle release.');
  const nativeChanges = afterNative.pins.flatMap(value => {
    const previous = beforeNative.pins.find(before => before.identity === value.identity);
    if (previous?.state?.revision === value.state.revision) return [];
    const label = state => state?.version || state?.revision?.slice(0, 12) || 'not present';
    return [`| ${value.identity} | ${label(previous?.state)} | ${label(value.state)} |`];
  });
  if (nativeChanges.length) {
    const details = '\n## Resolved Swift packages\n\n| Package | Previous | Selected |\n| --- | --- | --- |\n' + nativeChanges.join('\n') + '\n';
    console.log(details);
    if (reportPath) await writeFile(reportPath, report + details);
  }
  // Regenerate offline mobile resources and provenance from the tested lockfiles.
  for (const directory of ['default-agent', 'ios/EmbeddedRuntime']) run('npm', ['ci', '--prefix', directory, ...npmOptions]);
  run(process.execPath, ['scripts/build-ios-pi-runtime.mjs']);
  run(process.execPath, ['scripts/build-ios-embedded-runtime.mjs']);
  await readRecords(repoRoot);
  console.log('Updated coordinated records, lockfiles, and generated resources. Review the diff and validate with scripts/test-changes.sh --all.');
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) await main();
