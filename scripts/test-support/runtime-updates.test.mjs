import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { readRecords, recordFiles, renderReport, runtimeUpdatePlan } from '../update-runtime-dependencies.mjs';
import { satisfiesRange } from '../../default-agent/src/package-versions.mjs';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
// Fixed fixture records keep these tests independent of future refreshes.
async function fixture(t) {
  const root = await mkdtemp(resolve(tmpdir(), 'woven-runtime-updates-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const original = new Map(), live = await readRecords(repo);
  for (const name of Object.values(recordFiles)) {
    let content = await readFile(resolve(repo, name), 'utf8');
    const swap = (from, to) => { content = content.replaceAll(from, to); };
    if (name === recordFiles.node) content = '24.22.0\n';
    if ([recordFiles.prepare, recordFiles.managed].includes(name)) {
      swap(live.node.checksums.arm64, '1'.repeat(64)); swap(live.node.checksums.x64, '2'.repeat(64));
      swap(`v${live.node.version}`, 'v24.22.0');
    }
    if ([recordFiles.workspace, recordFiles.executor].includes(name)) content = content.replace(/^FROM node:\d+-/m, 'FROM node:24-');
    if (name === recordFiles.cef) content = JSON.stringify({ version: '154.0.34+g14c5a08+chromium-154.0.8037.98', chromium: '154.0.8037.98',
      archives: { arm64: { platform: 'macosarm64', sha1: '3'.repeat(40) }, x86_64: { platform: 'macosx64', sha1: '4'.repeat(40) } } }, null, 2);
    if (name === recordFiles.sparkle) content = JSON.stringify({ version: '2.10.0', revision: '7'.repeat(40), toolsSHA256: '5'.repeat(64) }, null, 2) + '\n';
    if ([recordFiles.project, recordFiles.notices, recordFiles.appNotices, recordFiles.updates].includes(name)) {
      swap(`revision = ${live.sparkle.revision};`, `revision = ${'7'.repeat(40)};`);
      swap(`Sparkle ${live.sparkle.version}`, 'Sparkle 2.10.0'); swap(live.peekaboo.revision, '6'.repeat(40));
    }
    if (name === recordFiles.manifest) swap(`exact: "${live.peekaboo.version}"`, 'exact: "4.9.5"');
    if (name === recordFiles.resolved) {
      const resolved = JSON.parse(content);
      for (const pin of resolved.pins) {
        if (pin.identity === 'peekaboo') pin.state = { revision: '6'.repeat(40), version: '4.9.5' };
        if (pin.identity === 'sparkle') pin.state = { revision: '7'.repeat(40) };
      }
      content = JSON.stringify(resolved, null, 2).replace(/": /g, '" : ') + '\n';
    }
    if (name === recordFiles.agent || name === recordFiles.embedded) {
      const manifest = JSON.parse(content);
      for (const section of [manifest.dependencies, manifest.devDependencies ?? {}]) for (const key of Object.keys(section)) {
        section[key] = { '@anthropic-ai/claude-agent-sdk': '^0.3.302', esbuild: '^0.28.2', pyodide: '^314.0.7' }[key]
          ?? (key.startsWith('@earendil-works/') ? '^1.3.0' : section[key]);
      }
      content = JSON.stringify(manifest, null, 2) + '\n';
    }
    original.set(name, content);
    await mkdir(dirname(resolve(root, name)), { recursive: true });
    await writeFile(resolve(root, name), content);
  }
  return { root, original };
}

const npmReleases = {
  '@earendil-works/pi-durable': ['1.3.0', '1.4.0', '2.0.0'], '@earendil-works/pi-ai': ['1.3.0', '1.4.0', '2.0.0'],
  '@earendil-works/pi-coding-agent': ['1.3.0', '1.4.0', '2.0.0'], '@earendil-works/chord': ['1.3.0', '1.4.0', '2.0.0'],
  '@anthropic-ai/claude-agent-sdk': ['0.3.302', '0.3.310', '0.4.0'], esbuild: ['0.28.2', '0.28.5', '0.29.0'],
  pyodide: ['314.0.7', '314.0.9', '315.0.0'], '@opencode/cli': ['2.4.0', '3.0.0'], executor: ['2.0.0-beta.20', '3.0.0'],
};
function upstream({ missingChecksum = false, cefArchitectures = ['macosarm64', 'macosx64'], releases = npmReleases } = {}) {
  const cefBuild = (version, chromium, channel = 'stable') => ({ cef_version: version, chromium_version: chromium, channel,
    files: [{ type: 'minimal', sha1: (chromium.endsWith('99') ? 'a' : 'b').repeat(40), name: `cef_binary_${version}_minimal.tar.bz2` }] });
  return async url => {
    if (url === 'https://nodejs.org/dist/index.json') return Response.json([
      { version: 'v27.1.0', lts: false }, { version: 'v26.3.0', lts: 'Next' }, { version: 'v24.24.0-rc.1', lts: 'Krypton' },
      { version: 'v24.23.0', lts: 'Krypton' }, { version: 'v24.22.0', lts: 'Krypton' }, { version: 'v22.30.0', lts: 'Jod' },
    ]);
    const sums = url.match(/^https:\/\/nodejs\.org\/dist\/v([\d.]+)\/SHASUMS256\.txt$/);
    if (sums) return new Response(`${'c'.repeat(64)}  node-v${sums[1]}-darwin-arm64.tar.gz\n` + (missingChecksum ? '' : `${'d'.repeat(64)}  node-v${sums[1]}-darwin-x64.tar.gz\n`));
    if (url === 'https://cef-builds.spotifycdn.com/index.json') return Response.json(Object.fromEntries(cefArchitectures.map(platform => [platform, { versions: [
      cefBuild('154.0.34+g14c5a08+chromium-154.0.8037.98', '154.0.8037.98'), cefBuild('156.0.2+gabc+chromium-156.0.9000.99', '156.0.9000.99'),
      cefBuild('157.0.1+gdef+chromium-157.0.9100.1', '157.0.9100.1', 'beta'),
    ] }])));
    if (url.startsWith('https://api.github.com/repos/sparkle-project/Sparkle/releases')) return Response.json(['2.10.0', '2.11.1', '3.0.0', '3.1.0-beta.1']
      .map(tag => ({ tag_name: tag, draft: false, prerelease: tag.includes('-'), assets: [{ name: `Sparkle-${tag}.tar.xz`, digest: 'sha256:' + (tag === '3.0.0' ? 'f' : 'e').repeat(64) }] })));
    const commit = url.match(/^https:\/\/api\.github\.com\/repos\/sparkle-project\/Sparkle\/commits\/(.+)$/);
    if (commit) return new Response((commit[1] === '3.0.0' ? '9' : '8').repeat(40));
    if (url.startsWith('https://api.github.com/repos/openclaw/Peekaboo/tags')) return Response.json(['v5.0.0', 'v4.10.1', 'v4.9.5', 'nightly']
      .map((name, index) => ({ name, commit: { sha: String(index).repeat(40) } })));
    const name = decodeURIComponent(url.slice('https://registry.npmjs.org/'.length).replace(/\/latest$/, ''));
    const versions = releases[name];
    assert.ok(versions, url);
    const metadata = version => ({ version, bin: { executor: 'bin.mjs', opencode: 'bin.js' } });
    return Response.json(url.endsWith('/latest') ? metadata(versions.filter(version => !version.includes('-')).at(-1))
      : { versions: Object.fromEntries(versions.map(version => [version, metadata(version)])) });
  };
}
const component = (plan, prefix) => plan.updates.find(update => update.component.startsWith(prefix));

test('the committed records are coherent: one Node release, Sparkle release, and npm range per component', async () => {
  const records = await readRecords(repo);
  // readRecords rejects drift between the bundled, managed, and Linux Node copies,
  // the Sparkle record, Xcode revision and shared lockfile, and Peekaboo's manifest and lockfile.
  assert.match(records.node.version, /^\d+\.\d+\.\d+$/);
  assert.equal(records.sparkle.revision, JSON.parse(records.text.resolved).pins.find(pin => pin.identity === 'sparkle').state.revision);
  const lock = JSON.parse(await readFile(resolve(repo, 'default-agent/package-lock.json'), 'utf8'));
  // The bundled snapshot sits inside the declared line the updater will honour.
  for (const group of records.npm.filter(value => value.manifests.includes('agent'))) {
    assert.ok(satisfiesRange(lock.packages[`node_modules/${group.declared[0]}`].version, group.range), group.name);
  }
});

test('a routine refresh takes the newest LTS patch and compatible releases, reporting newer lines without applying them', async t => {
  const { root, original } = await fixture(t);
  const plan = await runtimeUpdatePlan({ root, fetchImplementation: upstream() });
  for (const [name, content] of original) assert.equal(await readFile(resolve(root, name), 'utf8'), content, 'planning never writes');
  const files = plan.files;
  // Node: newest 24.x LTS, never the Current line or a release candidate.
  assert.equal(files.get(recordFiles.node), '24.23.0\n');
  for (const name of [recordFiles.prepare, recordFiles.managed]) {
    assert.ok(files.get(name).includes('c'.repeat(64)) && files.get(name).includes('d'.repeat(64)), name);
    assert.ok(!files.get(name).includes('1'.repeat(64)), name);
  }
  assert.ok(files.get(recordFiles.managed).includes('archiveFileName: "node-v24.23.0-darwin-x64.tar.gz"'));
  assert.ok(!files.has(recordFiles.workspace), 'the Linux base already floats on the 24 line');
  assert.equal(component(plan, 'Node').blocked, '26.3.0');
  // CEF always takes the newest stable build for both architectures.
  assert.deepEqual(JSON.parse(files.get(recordFiles.cef)), { version: '156.0.2+gabc+chromium-156.0.9000.99', chromium: '156.0.9000.99',
    archives: { arm64: { platform: 'macosarm64', sha1: 'a'.repeat(40) }, x86_64: { platform: 'macosx64', sha1: 'a'.repeat(40) } } });
  // Sparkle: the release record, exact Xcode revision, tools digest, and notices move together.
  assert.deepEqual(JSON.parse(files.get(recordFiles.sparkle)), { version: '2.11.1', revision: '8'.repeat(40), toolsSHA256: 'e'.repeat(64) });
  assert.ok(files.get(recordFiles.project).includes(`kind = revision; revision = ${'8'.repeat(40)};`));
  assert.ok(!files.get(recordFiles.project).includes('7'.repeat(40)));
  assert.ok(files.get(recordFiles.updates).includes('Sparkle 2.11.1'));
  assert.equal(component(plan, 'Sparkle').blocked, '3.0.0');
  // Peekaboo follows release tags; native resolvers, not this plan, regenerate Package.resolved.
  assert.ok(files.get(recordFiles.manifest).includes('exact: "4.10.1"'));
  assert.ok(files.get(recordFiles.notices).includes('1'.repeat(40)) && plan.swiftResolve);
  assert.ok(!files.has(recordFiles.resolved));
  // npm groups raise their caret floors inside the declared lines.
  const agent = JSON.parse(files.get(recordFiles.agent)), embedded = JSON.parse(files.get(recordFiles.embedded));
  assert.equal(agent.dependencies['@earendil-works/pi-durable'], '^1.4.0');
  assert.equal(agent.dependencies['@anthropic-ai/claude-agent-sdk'], '^0.3.310');
  assert.equal(agent.devDependencies.esbuild, '^0.28.5');
  assert.equal(embedded.dependencies.esbuild, '^0.28.5');
  assert.equal(embedded.dependencies.pyodide, '^314.0.9');
  assert.deepEqual(['Pi', 'Claude', 'esbuild', 'Pyodide'].map(prefix => component(plan, prefix).blocked), ['2.0.0', '0.4.0', '0.29.0', '315.0.0']);
  // V2-only integrations surface a new upstream major instead of silently staying behind.
  assert.ok(plan.notices.some(notice => notice.startsWith('OpenCode 3.0.0')));
  assert.ok(plan.notices.some(notice => notice.startsWith('Executor 3.0.0')));
  const report = renderReport(plan);
  assert.match(report, /Node\.js LTS .*\| 24\.22\.0 \| \*\*24\.23\.0\*\* \| 26\.3\.0 \|/);
  assert.match(report, /Newer major lines not applied in this run/);
});

test('an owner-run major refresh proposes newest stable lines, never Node Current, and flags each major for review', async t => {
  const { root } = await fixture(t);
  const plan = await runtimeUpdatePlan({ root, fetchImplementation: upstream(), includeMajors: true });
  // Newest LTS (26), not Current (27) or a release candidate; every Node copy moves together.
  assert.equal(plan.files.get(recordFiles.node), '26.3.0\n');
  assert.ok(plan.files.get(recordFiles.managed).includes('archiveFileName: "node-v26.3.0-darwin-arm64.tar.gz"'));
  for (const name of [recordFiles.workspace, recordFiles.executor]) assert.match(plan.files.get(name), /^FROM node:26-trixie-slim$/m);
  // Critical native selections stay exact within the proposal.
  assert.deepEqual(JSON.parse(plan.files.get(recordFiles.sparkle)), { version: '3.0.0', revision: '9'.repeat(40), toolsSHA256: 'f'.repeat(64) });
  assert.ok(plan.files.get(recordFiles.project).includes(`revision = ${'9'.repeat(40)};`));
  assert.ok(plan.files.get(recordFiles.manifest).includes('exact: "5.0.0"'));
  const agent = JSON.parse(plan.files.get(recordFiles.agent));
  assert.equal(agent.dependencies['@earendil-works/pi-ai'], '^2.0.0');
  assert.equal(agent.dependencies['@anthropic-ai/claude-agent-sdk'], '^0.4.0');
  assert.ok(plan.updates.every(update => !update.blocked));
  // Majors and 0.x minors leave the caret line, so each is flagged for review.
  for (const prefix of ['Node', 'Sparkle', 'Peekaboo', 'Pi', 'Claude', 'esbuild', 'Pyodide']) assert.match(component(plan, prefix).note, /Breaking-line update/, prefix);
  // V2-only integrations are still reported, never auto-selected.
  assert.ok(plan.notices.some(notice => notice.startsWith('OpenCode 3.0.0')));
});

test('missing archive checksums or partial CEF publication never produce a half-updated record', async t => {
  const { root, original } = await fixture(t);
  await assert.rejects(runtimeUpdatePlan({ root, fetchImplementation: upstream({ missingChecksum: true }) }), /checksum/);
  const plan = await runtimeUpdatePlan({ root, fetchImplementation: upstream({ cefArchitectures: ['macosarm64'] }) });
  assert.ok(!plan.files.has(recordFiles.cef));
  assert.ok(plan.notices.some(notice => notice.startsWith('CEF:')));
  for (const [name, content] of original) assert.equal(await readFile(resolve(root, name), 'utf8'), content);
});

test('a partially published Pi release is skipped until every family package has it', async t => {
  const { root } = await fixture(t);
  const releases = { ...npmReleases, '@earendil-works/chord': ['1.3.0', '1.3.1'],
    '@earendil-works/pi-durable': ['1.3.0', '1.3.1', '1.4.0'], '@earendil-works/pi-ai': ['1.3.0', '1.3.1', '1.4.0'], '@earendil-works/pi-coding-agent': ['1.3.0', '1.3.1', '1.4.0'] };
  const plan = await runtimeUpdatePlan({ root, fetchImplementation: upstream({ releases }) });
  assert.equal(JSON.parse(plan.files.get(recordFiles.agent)).dependencies['@earendil-works/pi-coding-agent'], '^1.3.1');
});

test('drifted copies of one selection are rejected before any upstream request', async t => {
  const { root, original } = await fixture(t);
  await writeFile(resolve(root, recordFiles.managed), original.get(recordFiles.managed).replace('2'.repeat(64), '9'.repeat(64)));
  await assert.rejects(runtimeUpdatePlan({ root, fetchImplementation: () => assert.fail('no request') }), /managed Node runtime/);
  await writeFile(resolve(root, recordFiles.managed), original.get(recordFiles.managed));
  await writeFile(resolve(root, recordFiles.executor), original.get(recordFiles.executor).replace('node:24-', 'node:22-'));
  await assert.rejects(runtimeUpdatePlan({ root, fetchImplementation: () => assert.fail('no request') }), /Linux base images/);
  await writeFile(resolve(root, recordFiles.executor), original.get(recordFiles.executor));
  await writeFile(resolve(root, recordFiles.project), original.get(recordFiles.project).replace('7'.repeat(40), '8'.repeat(40)));
  await assert.rejects(runtimeUpdatePlan({ root, fetchImplementation: () => assert.fail('no request') }), /Xcode Sparkle requirement/);
  await writeFile(resolve(root, recordFiles.project), original.get(recordFiles.project));
  await writeFile(resolve(root, recordFiles.resolved), original.get(recordFiles.resolved).replace('7'.repeat(40), '8'.repeat(40)));
  await assert.rejects(runtimeUpdatePlan({ root, fetchImplementation: () => assert.fail('no request') }), /shared Swift lockfile/);
});


test('CEF wrapper fixes are refreshed even when the Chromium version is unchanged', async t => {
  const { root } = await fixture(t);
  const chromium = '154.0.8037.98', version = '154.0.35+gfix+chromium-' + chromium;
  const originalFetch = upstream();
  const fetchImplementation = url => url === 'https://cef-builds.spotifycdn.com/index.json'
    ? Response.json(Object.fromEntries(['macosarm64', 'macosx64'].map(platform => [platform, { versions: [
      { cef_version: version, chromium_version: chromium, channel: 'stable', files: [{ type: 'minimal', sha1: 'f'.repeat(40) }] },
      { cef_version: '154.0.34+g14c5a08+chromium-' + chromium, chromium_version: chromium, channel: 'stable', files: [{ type: 'minimal', sha1: 'e'.repeat(40) }] },
    ] }]))) : originalFetch(url);
  const plan = await runtimeUpdatePlan({ root, fetchImplementation });
  const cef = JSON.parse(plan.files.get(recordFiles.cef));
  assert.equal(cef.version, version);
  assert.equal(cef.chromium, chromium);
  assert.equal(cef.archives.arm64.sha1, 'f'.repeat(40));
});
