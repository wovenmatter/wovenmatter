import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, readdir, rename, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomUUID } from 'node:crypto';
import { resolveSDKRuntime, sdkStatus, checkSDKUpdates, updateSDK } from '../src/sdk-management.mjs';

// Fixtures follow the bundled declarations, which are the updater's policy.
const declared = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8')).dependencies;
const piFloor = declared['@earendil-works/pi-durable'].slice(2), claudeFloor = declared['@anthropic-ai/claude-agent-sdk'].slice(2);
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

test('no compatible release or a cancelled update leaves the active generation unchanged', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8');
  await assert.rejects(checkSDKUpdates({ directory: f.directory, id: 'claude',
    fetchImplementation: registry({ '@anthropic-ai/claude-agent-sdk': ['0.0.0'] }) }), /compatible release/);
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
// The Claude SDK's binary package for this machine, which npm installs with it.
const claudeBinary = root => join(root, 'node_modules/@anthropic-ai', `claude-agent-sdk-${process.platform}-${process.arch}`, 'claude');
async function materializeManifest(_args, { cwd }) {
  const manifest = JSON.parse(await readFile(join(cwd, 'package.json'), 'utf8'));
  for (const [name, version] of Object.entries(manifest.dependencies)) {
    await mkdir(join(cwd, 'node_modules', name), { recursive: true });
    await writeFile(join(cwd, 'node_modules', name, 'package.json'), JSON.stringify({ version }));
  }
  if (manifest.dependencies['@anthropic-ai/claude-agent-sdk']) {
    await mkdir(dirname(claudeBinary(cwd)), { recursive: true });
    await writeFile(claudeBinary(cwd), '#!/bin/sh\n', { mode: 0o755 });
  }
  return '';
}

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

test('oversized activation and latest metadata do not block bundled fallback', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  await writeFile(f.active, JSON.stringify({ base: f.bundled.base, generation: installed.id, padding: 'x'.repeat(4096) }));
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).generation, f.bundled.generation);
  await writeFile(f.active, JSON.stringify({ base: 'previous-app-release', generation: installed.id }));
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).root, f.bundled.root);
  await installed.activate();
  await writeFile(join(f.directory, 'sdk-runtime/latest.json'), 'x'.repeat(16385));
  const status = await sdkStatus({ directory: f.directory });
  assert.equal(status.generation, installed.id);
  assert.equal(status.sdks.find(sdk => sdk.id === 'claude').latestVersion, null);
});

test('a candidate failing its staged API verification is discarded and the active generation remains', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8'), options = mockInstaller(bump(piFloor, 0), materializeManifest);
  const install = options.run;
  options.run = async (executable, args, runOptions) => {
    if (args.includes('--eval')) throw Error('fixture Pi API unavailable');
    return install(executable, args, runOptions);
  };
  await assert.rejects(updateSDK({ directory: f.directory, id: 'pi', version: bump(piFloor, 0) }, options), /previous SDKs were kept/);
  assert.equal(await readFile(f.active, 'utf8'), before);
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [installed.id]);
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).root, installed.root);
});

test('combined update failure preserves both active SDKs', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8');
  const options = mockInstaller(bump(piFloor), materializeManifest);
  options.registryFetch = registry({ ...piReleases([piFloor, bump(piFloor)]), '@anthropic-ai/claude-agent-sdk': [claudeFloor, bump(claudeFloor)] });
  const run = options.run;
  options.run = async (...args) => { if (args[1].includes('--eval')) throw Error('fixture verification failure'); return run(...args); };
  await assert.rejects(updateSDK({ directory: f.directory }, options), /previous SDKs were kept/);
  assert.equal(await readFile(f.active, 'utf8'), before);
});

test('a verified update becomes active and deletes the generation it replaced, even while it is open', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  // A running conversation's open file does not keep its generation.
  const open = await import('node:fs/promises').then(fs => fs.open(join(installed.root, 'src/main-runtime.mjs')));
  t.after(() => open.close());
  const result = await updateSDK({ directory: f.directory, id: 'pi', version: bump(piFloor) }, mockInstaller(bump(piFloor), materializeManifest));
  assert.equal(result.activated, true);
  const active = await resolveSDKRuntime({ directory: f.directory });
  assert.equal(active.generation, result.generation);
  assert.notEqual(active.generation, installed.id);
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [result.generation]);
  assert.equal((await sdkStatus({ directory: f.directory })).sdks.find(sdk => sdk.id === 'pi').installedVersion, bump(piFloor));
  const next = await updateSDK({ directory: f.directory, id: 'pi', version: bump(piFloor, 2, 2) },
    mockInstaller(bump(piFloor, 2, 2), materializeManifest));
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [next.generation]);
  // An update over the bundled copy never touches Woven Matter's own files.
  await rm(f.active);
  const fresh = await updateSDK({ directory: f.directory, id: 'pi', version: bump(piFloor, 2, 3) },
    mockInstaller(bump(piFloor, 2, 3), materializeManifest));
  assert.equal(fresh.activated, true);
  assert.equal((await readdir(f.bundled.root)).includes('src'), true);
  // Only the copy it replaced: an orphan from before goes nowhere (no other cleanup).
  assert.deepEqual((await readdir(join(f.directory, 'sdk-runtime/generations'))).sort(), [next.generation, fresh.generation].sort());
});

test('an update with nothing to install activates nothing', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const result = await updateSDK({ directory: f.directory, id: 'pi' }, mockInstaller(piFloor, materializeManifest));
  assert.equal(result.activated, undefined);
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [installed.id]);
});

// Bots on this machine (here the checkout's bots/) run on the copy Pi Durable activates.
const bots = resolve(fileURLToPath(new URL('../../bots', import.meta.url)));

test('a candidate the bots runtime cannot load is discarded and the working copy stays active', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8'), options = mockInstaller(bump(piFloor, 0), materializeManifest);
  const run = options.run, verified = [];
  options.run = async (executable, args, runOptions) => {
    if (args.includes('verify-sdk')) {
      verified.push({ executable, args, cwd: runOptions.cwd, active: await readFile(f.active, 'utf8'),
        staged: await readdir(join(args.at(-1), 'node_modules/@earendil-works')) });
      throw Error('fixture: bots import an export the new major dropped');
    }
    return run(executable, args, runOptions);
  };
  await assert.rejects(updateSDK({ directory: f.directory, id: 'pi', version: bump(piFloor, 0) }, options), /previous SDKs were kept/);
  // Bots' real entry graph ran against the staged copy, before anything was activated.
  assert.equal(verified.length, 1);
  assert.equal(verified[0].executable, process.execPath);
  assert.deepEqual(verified[0].args.slice(0, 2), [join(bots, 'src/cli.ts'), 'verify-sdk']);
  assert.match(verified[0].args[2], /\/sdk-runtime\/generations\/\.staging-[0-9a-f-]{36}$/);
  assert.equal(verified[0].cwd, bots);
  assert.equal(verified[0].active, before);
  assert.deepEqual(verified[0].staged.sort(), piPackages.map(name => name.split('/')[1]).sort());
  assert.equal(await readFile(f.active, 'utf8'), before);
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [installed.id]);
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).root, installed.root);
});

test('a copy without its Claude binary needs the update, which reinstalls the same version', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const options = mockInstaller(piFloor, materializeManifest);
  await checkSDKUpdates({ directory: f.directory, fetchImplementation: options.registryFetch });
  let claude = (await sdkStatus({ directory: f.directory })).sdks.find(sdk => sdk.id === 'claude');
  assert.equal(claude.consistent, true);
  assert.equal(claude.updateAvailable, false);
  await rm(claudeBinary(installed.root));
  // Pi Durable still selects this copy; bots cannot run on it.
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).root, installed.root);
  claude = (await sdkStatus({ directory: f.directory })).sdks.find(sdk => sdk.id === 'claude');
  assert.equal(claude.consistent, false);
  assert.equal(claude.updateAvailable, true);
  assert.equal(claude.latestVersion, claude.installedVersion);
  const repaired = await updateSDK({ directory: f.directory }, options);
  assert.equal(repaired.activated, true);
  const active = await resolveSDKRuntime({ directory: f.directory });
  assert.notEqual(active.root, installed.root);
  claude = (await sdkStatus({ directory: f.directory })).sdks.find(sdk => sdk.id === 'claude');
  assert.equal(claude.consistent, true);
  assert.equal(claude.installedVersion, claudeFloor);
  assert.equal(claude.updateAvailable, false);
});

test('a copy missing an SDK package needs the update even with no version to compare', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const options = mockInstaller(piFloor, materializeManifest);
  await checkSDKUpdates({ directory: f.directory, fetchImplementation: options.registryFetch });
  await rm(join(installed.root, 'node_modules/@earendil-works/pi-durable'), { recursive: true });
  const pi = (await sdkStatus({ directory: f.directory })).sdks.find(sdk => sdk.id === 'pi');
  assert.equal(pi.installedVersion, null);
  assert.equal(pi.consistent, false);
  assert.equal(pi.updateAvailable, true);
});
