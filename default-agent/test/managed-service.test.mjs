import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { resolveSDKRuntime } from '../src/sdk-management.mjs';
import { createManagedDefaultAgentService } from '../src/managed-service.mjs';

// Workers contain only fixture services, with no SDK imports, credentials,
// package installation, network access, providers, or real workspace files.
async function fixture(t, source) {
  const directory = await mkdtemp(join(tmpdir(), 'woven-sdk-worker-'));
  const bundled = await resolveSDKRuntime({ directory });
  const generations = join(directory, 'sdk-runtime/generations');
  async function activate() {
    const generation = randomUUID(), root = join(generations, generation);
    await mkdir(join(root, 'src'), { recursive: true });
    await writeFile(join(root, 'src/main-runtime.mjs'), '');
    await writeFile(join(root, 'src/service.mjs'), source);
    await writeFile(join(root, 'woven-sdk-generation.json'), JSON.stringify({ base: bundled.base, generation }));
    await writeFile(join(directory, 'sdk-runtime/active.json'), JSON.stringify({ base: bundled.base, generation }));
  }
  await activate();
  const service = createManagedDefaultAgentService({ cwd: directory, directory });
  t.after(async () => { await service.close(); await rm(directory, { recursive: true, force: true }); });
  return { directory, service, activate };
}
async function waitForFile(path) {
  const deadline = performance.now() + 5000;
  while (true) {
    try { return await readFile(path, 'utf8'); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (performance.now() > deadline) throw Error('Fixture worker did not start');
    await delay(10);
  }
}

test('shutdown unblocks selection waiting for retirement', async t => {
  const f = await fixture(t, `
    import { writeFile } from 'node:fs/promises';
    import { join } from 'node:path';
    export function createDefaultAgentService({ directory }) {
      return {
        status: async () => ({ ready: true }),
        cancelActive: async () => {},
        prepareRetirement: async () => {
          await writeFile(join(directory, 'retiring'), 'started');
          return new Promise(() => {});
        },
      };
    }
  `);
  assert.deepEqual(await f.service.status(), { ready: true });
  await f.activate();
  const rejected = assert.rejects(f.service.status(), /stopped|shutting down/);
  await waitForFile(join(f.directory, 'retiring'));
  const start = performance.now();
  await f.service.close();
  await rejected;
  assert.ok(performance.now() - start < 8000, 'owned worker shutdown must be bounded');
  await assert.rejects(f.service.status(), /shutting down/);
});

test('shutdown stops a worker while its initialization import is pending', async t => {
  const f = await fixture(t, `
    import { writeFile } from 'node:fs/promises';
    await writeFile('initializing', 'started');
    await new Promise(() => {});
    export function createDefaultAgentService() { return {}; }
  `);
  const rejected = assert.rejects(f.service.status(), /stopped|shutting down/);
  await waitForFile(join(f.directory, 'initializing'));
  await f.service.close();
  await rejected;
});
