import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, readdir, rename, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { resolveSDKRuntime, sdkStatus, checkSDKUpdates, updateSDK } from '../src/sdk-management.mjs';

import { rangeFloor } from '../src/package-versions.mjs';

// Fixtures follow the bundled declarations, which are the updater's policy.
const declared = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8')).dependencies;
const piFloor = rangeFloor(declared['@earendil-works/pi-durable']), claudeFloor = rangeFloor(declared['@anthropic-ai/claude-agent-sdk']);
const bump = (version, part = 2, by = 1) => version.split('.').map((value, index) => index < part ? value : index === part ? String(Number(value) + by) : '0').join('.');
const piPackages = ['@earendil-works/pi-durable', '@earendil-works/pi-ai', '@earendil-works/pi-coding-agent', '@earendil-works/chord'];
// npm registry fixture: `releases` maps package names to published versions.
function registry(releases) {
  return async url => {
    const name = decodeURIComponent(url.slice('https://registry.npmjs.org/'.length).replace(/\/latest$/, ''));
    const versions = releases[name] ?? [];
    return new Response(JSON.stringify(url.endsWith('/latest') ? { version: versions.at(-1) }
      : { versions: Object.fromEntries(versions.map(version => [version, {}])) }));
  };
}
const piReleases = versions => Object.fromEntries(piPackages.map(name => [name, versions]));

async function fixture(t) {
  const directory = await mkdtemp(join(tmpdir(), 'woven-sdk-metadata-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  const bundled = await resolveSDKRuntime({ directory });
  const active = join(directory, 'sdk-runtime/active.json');
  async function generation(versions = {}) {
    const id = randomUUID(), root = join(directory, 'sdk-runtime/generations', id);
    await mkdir(join(root, 'src'), { recursive: true });
    await writeFile(join(root, 'src/main-runtime.mjs'), 'export const fixture = true;');
    await writeFile(join(root, 'woven-sdk-generation.json'), JSON.stringify({ base: bundled.base, generation: id }));
    const dependencies = { ...Object.fromEntries(piPackages.map(name => [name, piFloor])), '@anthropic-ai/claude-agent-sdk': claudeFloor, ...versions };
    await writeFile(join(root, 'package.json'), JSON.stringify({ dependencies }));
    await writeFile(join(root, 'package-lock.json'), JSON.stringify({ lockfileVersion: 3, packages: {} }));
    await materializeManifest([], { cwd: root });
    return { id, root, activate: () => writeFile(active, JSON.stringify({ base: bundled.base, generation: id })) };
  }
  return { directory, bundled, active, generation };
}

test('helper generation selection remains immutable while new launches see activation', async t => {
  const f = await fixture(t), first = await f.generation(), second = await f.generation({ '@anthropic-ai/claude-agent-sdk': bump(claudeFloor) });
  await first.activate();
  const running = await resolveSDKRuntime({ directory: f.directory });
  await second.activate();
  const next = await resolveSDKRuntime({ directory: f.directory });
  assert.equal(running.root, first.root);
  assert.equal(next.root, second.root);
  assert.equal(JSON.parse(await readFile(join(running.root, 'node_modules/@anthropic-ai/claude-agent-sdk/package.json'))).version, claudeFloor);
});

test('no compatible release or a cancelled update leaves the active generation unchanged', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8');
  await assert.rejects(checkSDKUpdates({ directory: f.directory, id: 'claude',
    fetchImplementation: registry({ '@anthropic-ai/claude-agent-sdk': [bump(claudeFloor, 0)] }) }), /compatible release/);
  await assert.rejects(updateSDK({ directory: f.directory, id: 'claude', signal: AbortSignal.abort() }), /cancelled/);
  assert.equal(await readFile(f.active, 'utf8'), before);
});

test('symlinked updater ancestors cannot select an external runtime', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const generations = join(f.directory, 'sdk-runtime/generations');
  const moved = join(f.directory, 'external-generations');
  await rename(generations, moved);
  await symlink(moved, generations);
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).generation, f.bundled.generation);
});

function mockInstaller(latest, install) {
  return {
    registryFetch: registry({ ...piReleases([piFloor, latest]), '@anthropic-ai/claude-agent-sdk': [claudeFloor] }),
    installer: async () => '/fixture/npm-cli.js',
    lock: async () => async () => {},
    run: async (_executable, args, options) => {
      if (args.includes('install')) return install(args, options);
      return '2.1.115 (Claude Code)';
    },
  };
}
async function materializeManifest(_args, { cwd }) {
  const manifest = JSON.parse(await readFile(join(cwd, 'package.json'), 'utf8'));
  for (const [name, version] of Object.entries(manifest.dependencies)) {
    await mkdir(join(cwd, 'node_modules', name), { recursive: true });
    await writeFile(join(cwd, 'node_modules', name, 'package.json'), JSON.stringify({ version }));
  }
  return '';
}

test('mock installer failure rolls back staging and preserves the exact prior activation', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8');
  await assert.rejects(updateSDK({ directory: f.directory, id: 'pi' }, mockInstaller(bump(piFloor), async () => {
    throw Error('fixture installer failure');
  })), /previous SDKs were kept/);
  assert.equal(await readFile(f.active, 'utf8'), before);
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [installed.id]);
});

test('successful mock installation activates coherent Pi packages and retains the untouched SDK', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const result = await updateSDK({ directory: f.directory, id: 'pi', version: bump(piFloor) },
    mockInstaller(bump(piFloor), materializeManifest));
  assert.notEqual(result.generation, installed.id);
  assert.equal(result.sdks.find(sdk => sdk.id === 'pi').installedVersion, bump(piFloor));
  assert.equal(result.sdks.find(sdk => sdk.id === 'claude').installedVersion, claudeFloor);
  const actual = await sdkStatus({ directory: f.directory });
  assert.equal(actual.generation, result.generation);
  assert.equal(actual.sdks.find(sdk => sdk.id === 'pi').consistent, true);
  assert.ok((await readdir(join(f.directory, 'sdk-runtime/generations'))).includes(installed.id));
});

test('FIFO activation metadata is rejected without blocking on open', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  await rm(f.active);
  await promisify(execFile)('/usr/bin/mkfifo', [f.active]);
  const moduleURL = new URL('../src/sdk-management.mjs', import.meta.url).href;
  const source = `import { resolveSDKRuntime } from ${JSON.stringify(moduleURL)};
    console.log(JSON.stringify(await resolveSDKRuntime({ directory: process.argv[1] })));`;
  // The child watchdog also bounds this fixture if the nonblocking-open guard regresses.
  const { stdout } = await promisify(execFile)(process.execPath,
    ['--input-type=module', '--eval', source, f.directory], { timeout: 2000, killSignal: 'SIGKILL', maxBuffer: 4096 });
  assert.equal(JSON.parse(stdout).generation, f.bundled.generation);
});

test('cancellation after mock installation but before activation keeps the old generation', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8'), controller = new AbortController();
  await assert.rejects(updateSDK({ directory: f.directory, id: 'pi', signal: controller.signal },
    mockInstaller(bump(piFloor), async (...args) => { await materializeManifest(...args); controller.abort(); })), /cancelled/);
  assert.equal(await readFile(f.active, 'utf8'), before);
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [installed.id]);
});

test('metadata status detects an inconsistent Pi pair without loading SDKs', async t => {
  const f = await fixture(t), installed = await f.generation({ '@earendil-works/pi-ai': bump(piFloor) });
  await installed.activate();
  const status = await sdkStatus({ directory: f.directory });
  assert.equal(status.sdks.find(sdk => sdk.id === 'pi').consistent, false);
  assert.equal(status.sdks.find(sdk => sdk.id === 'claude').consistent, true);
});

test('a per-SDK check never queries the other SDK and preserves active installation', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8'), calls = [], query = registry(piReleases([piFloor, bump(piFloor)]));
  const status = await checkSDKUpdates({ directory: f.directory, id: 'pi', fetchImplementation: async url => {
    calls.push(decodeURIComponent(url)); return query(url);
  } });
  assert.ok(calls.length && calls.every(url => url.includes('/@earendil-works/')), calls.join());
  assert.equal(status.sdks.find(sdk => sdk.id === 'pi').latestVersion, bump(piFloor));
  assert.equal(status.sdks.find(sdk => sdk.id === 'claude').latestVersion, null);
  assert.equal(await readFile(f.active, 'utf8'), before);
});

test('oversized activation and latest metadata do not block bundled fallback', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  await writeFile(f.active, JSON.stringify({ base: f.bundled.base, generation: installed.id, padding: 'x'.repeat(4096) }));
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).generation, f.bundled.generation);
  await installed.activate();
  await writeFile(join(f.directory, 'sdk-runtime/latest.json'), 'x'.repeat(16385));
  const status = await sdkStatus({ directory: f.directory });
  assert.equal(status.generation, installed.id);
  assert.equal(status.sdks.find(sdk => sdk.id === 'claude').latestVersion, null);
});

test('checks select the newest release in the bundled range and report a newer blocked line', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  // Claude 0.x minors are breaking lines; Pi uses its major line.
  const claudePatch = bump(claudeFloor, 2, 3), claudeNext = bump(claudeFloor, 1), piMinor = bump(piFloor, 1), piNext = bump(piFloor, 0);
  const releases = { ...piReleases([piFloor, piMinor, piNext]), '@anthropic-ai/claude-agent-sdk': [claudeFloor, claudePatch, claudeNext] };
  const checked = await checkSDKUpdates({ directory: f.directory, fetchImplementation: registry(releases) });
  const claude = checked.sdks.find(sdk => sdk.id === 'claude'), pi = checked.sdks.find(sdk => sdk.id === 'pi');
  assert.deepEqual([claude.latestVersion, claude.newerVersion, claude.updateAvailable], [claudePatch, claudeNext, true]);
  assert.equal(claude.notice, `Claude SDK ${claudeNext} needs a Woven Matter update. ${claudePatch} is the newest compatible release.`);
  assert.deepEqual([pi.latestVersion, pi.newerVersion, pi.updateAvailable], [piMinor, piNext, true]);
  // The blocked line survives later status reads, so it cannot silently disappear.
  assert.equal((await sdkStatus({ directory: f.directory })).sdks.find(sdk => sdk.id === 'pi').newerVersion, piNext);
  // It clears once nothing newer exists outside the range.
  const current = await checkSDKUpdates({ directory: f.directory, id: 'pi', fetchImplementation: registry(piReleases([piFloor, piMinor])) });
  assert.equal(current.sdks.find(sdk => sdk.id === 'pi').newerVersion, null);
  assert.equal(current.sdks.find(sdk => sdk.id === 'claude').newerVersion, claudeNext);
});

test('Pi selects only a release every family package, including Chord, has published', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const aligned = bump(piFloor), partial = bump(piFloor, 1);
  const releases = { ...piReleases([piFloor, aligned, partial]), '@earendil-works/chord': [piFloor, aligned] };
  const checked = await checkSDKUpdates({ directory: f.directory, id: 'pi', fetchImplementation: registry(releases) });
  assert.equal(checked.sdks.find(sdk => sdk.id === 'pi').latestVersion, aligned);
});

test('a candidate failing its staged API verification is discarded and the active generation remains', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8'), options = mockInstaller(bump(piFloor), materializeManifest);
  const install = options.run;
  options.run = async (executable, args, runOptions) => {
    if (args.includes('--eval')) throw Error('fixture Pi API unavailable');
    return install(executable, args, runOptions);
  };
  await assert.rejects(updateSDK({ directory: f.directory, id: 'pi', version: bump(piFloor) }, options), /previous SDKs were kept/);
  assert.equal(await readFile(f.active, 'utf8'), before);
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [installed.id]);
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).root, installed.root);
});
