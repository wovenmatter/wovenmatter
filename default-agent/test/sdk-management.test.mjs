import test from 'node:test';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, readdir, rename, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { resolveSDKRuntime, sdkStatus, checkSDKUpdates, updateSDK } from '../src/sdk-management.mjs';
import { ClaudeRuntime, defaultClaudeModels } from '../src/claude-runtime.mjs';

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
    const dependencies = { '@earendil-works/pi-coding-agent': '0.86.1', '@earendil-works/pi-ai': '0.86.1', '@anthropic-ai/claude-agent-sdk': '0.3.284', ...versions };
    await writeFile(join(root, 'package.json'), JSON.stringify({ dependencies }));
    await writeFile(join(root, 'package-lock.json'), JSON.stringify({ lockfileVersion: 3, packages: {} }));
    for (const [name, version] of Object.entries(dependencies)) {
      await mkdir(join(root, 'node_modules', name), { recursive: true });
      await writeFile(join(root, 'node_modules', name, 'package.json'), JSON.stringify({ version }));
    }
    return { id, root, activate: () => writeFile(active, JSON.stringify({ base: bundled.base, generation: id })) };
  }
  return { directory, bundled, active, generation };
}

test('helper generation selection remains immutable while new launches see activation', async t => {
  const f = await fixture(t), first = await f.generation(), second = await f.generation({ '@anthropic-ai/claude-agent-sdk': '0.3.285' });
  await first.activate();
  const running = await resolveSDKRuntime({ directory: f.directory });
  await second.activate();
  const next = await resolveSDKRuntime({ directory: f.directory });
  assert.equal(running.root, first.root);
  assert.equal(next.root, second.root);
  assert.equal(JSON.parse(await readFile(join(running.root, 'node_modules/@anthropic-ai/claude-agent-sdk/package.json'))).version, '0.3.284');
});

test('metadata status detects an inconsistent Pi pair without loading SDKs', async t => {
  const f = await fixture(t), installed = await f.generation({ '@earendil-works/pi-ai': '0.85.0' });
  await installed.activate();
  const status = await sdkStatus({ directory: f.directory });
  assert.equal(status.sdks.find(sdk => sdk.id === 'pi').consistent, false);
  assert.equal(status.sdks.find(sdk => sdk.id === 'claude').consistent, true);
});

test('a per-SDK check never queries the other SDK and preserves active installation', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8'), calls = [];
  const status = await checkSDKUpdates({ directory: f.directory, id: 'pi', fetchImplementation: async url => {
    calls.push(url); return new Response(JSON.stringify({ version: '0.87.1' }));
  } });
  assert.equal(calls.length, 1); assert.match(decodeURIComponent(calls[0]), /pi-coding-agent/);
  assert.equal(status.sdks.find(sdk => sdk.id === 'pi').latestVersion, '0.87.1');
  assert.equal(status.sdks.find(sdk => sdk.id === 'claude').latestVersion, null);
  assert.equal(await readFile(f.active, 'utf8'), before);
});

test('incompatible or cancelled updates cannot replace the active generation', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8');
  await assert.rejects(checkSDKUpdates({ directory: f.directory, id: 'claude', fetchImplementation: async () => new Response(JSON.stringify({ version: '1.0.0' })) }), /incompatible/);
  await assert.rejects(updateSDK({ directory: f.directory, id: 'claude', signal: AbortSignal.abort() }), /cancelled/);
  assert.equal(await readFile(f.active, 'utf8'), before);
});

test('an app-source fingerprint change rejects stale copied helper code', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  await writeFile(f.active, JSON.stringify({ base: 'old-app-build', generation: installed.id }));
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).root, f.bundled.root);
});

test('Claude cached aliases are accepted only for the installed SDK version', async t => {
  const f = await fixture(t);
  const runtime = new ClaudeRuntime(f.directory);
  runtime.sdkVersion = async () => '0.3.284';
  const models = [{ value: 'opus', displayName: 'Opus', resolvedModel: 'claude-opus-5' }];
  const cache = join(f.directory, 'claude-models.json');
  await writeFile(cache, JSON.stringify(models)); await runtime.loadModels();
  assert.deepEqual(runtime.models, defaultClaudeModels);
  await writeFile(cache, JSON.stringify({ runtimeVersion: '0.3.278', models })); await runtime.loadModels();
  assert.deepEqual(runtime.models, defaultClaudeModels);
  await writeFile(cache, JSON.stringify({ runtimeVersion: '0.3.284', models })); await runtime.loadModels();
  assert.deepEqual(runtime.models, models);
});


test('symlinked updater ancestors cannot select an external runtime', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const generations = join(f.directory, 'sdk-runtime/generations');
  const moved = join(f.directory, 'external-generations');
  await rename(generations, moved);
  await symlink(moved, generations);
  assert.equal((await resolveSDKRuntime({ directory: f.directory })).generation, f.bundled.generation);
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


function mockInstaller(latest, install) {
  return {
    registryFetch: async () => new Response(JSON.stringify({ version: latest })),
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
  await assert.rejects(updateSDK({ directory: f.directory, id: 'pi' }, mockInstaller('0.87.1', async () => {
    throw Error('fixture installer failure');
  })), /previous SDKs were kept/);
  assert.equal(await readFile(f.active, 'utf8'), before);
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [installed.id]);
});

test('cancellation after mock installation but before activation keeps the old generation', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const before = await readFile(f.active, 'utf8'), controller = new AbortController();
  await assert.rejects(updateSDK({ directory: f.directory, id: 'pi', signal: controller.signal },
    mockInstaller('0.87.1', async (...args) => { await materializeManifest(...args); controller.abort(); })), /cancelled/);
  assert.equal(await readFile(f.active, 'utf8'), before);
  assert.deepEqual(await readdir(join(f.directory, 'sdk-runtime/generations')), [installed.id]);
});

test('successful mock installation activates coherent Pi packages and retains the untouched SDK', async t => {
  const f = await fixture(t), installed = await f.generation(); await installed.activate();
  const result = await updateSDK({ directory: f.directory, id: 'pi', version: '0.87.1' },
    mockInstaller('0.87.1', materializeManifest));
  assert.notEqual(result.generation, installed.id);
  assert.equal(result.sdks.find(sdk => sdk.id === 'pi').installedVersion, '0.87.1');
  assert.equal(result.sdks.find(sdk => sdk.id === 'claude').installedVersion, '0.3.284');
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
