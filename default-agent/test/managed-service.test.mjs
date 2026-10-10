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


test('SDK retirement transfers only the current attachment authority and trusted cancellation', async t => {
  const source = `
    import { createDefaultAgentService as createService } from ${JSON.stringify(new URL('../src/service.mjs', import.meta.url).href)};
    export function createDefaultAgentService(options) {
      const engine = {
        sessions: new Map(), create: async () => ({}), configuration: () => ({}),
        handle: async (method, params) => {
          if (method === 'fixture/crash') process.exit(19);
          return { sessionId: params?.sessionId ?? 'native', worker: process.pid };
        },
      };
      return createService({ ...options, engineFactory: async () => engine });
    }
  `;
  const f = await fixture(t, source);
  const load = sessionId => f.service.invoke({ method: 'session/load', attachmentProtocol: 1, params: { sessionId } });
  const old = (await load('native')).result._meta.attachmentToken;
  const attached = await load('native');
  const current = attached.result._meta.attachmentToken;
  const other = (await load('other')).result._meta.attachmentToken;
  const selection = (sessionId, attachmentToken) => f.service.invoke({
    method: 'session/set_config_option', attachmentToken, params: { sessionId },
  });
  await f.activate();
  await assert.rejects(selection('native', old), /attachment was replaced/);
  await assert.rejects(selection('native', undefined), /attachment was replaced/);
  await assert.rejects(selection('native', other), /attachment was replaced/);
  const selected = await selection('native', current);
  assert.notEqual(selected.result.worker, attached.result.worker, 'the SDK generation must actually rotate');
  assert.equal((await selection('other', other)).result.sessionId, 'other');
  assert.equal((await f.service.cancelSession('native')).sessionId, 'native');

  // A later replacement followed by a crash must not replay the retired
  // generation's authority into another worker.
  const replacement = (await load('native')).result._meta.attachmentToken;
  await assert.rejects(f.service.invoke({ method: 'fixture/crash' }), /stopped/);
  for (const token of [old, current, replacement]) await assert.rejects(selection('native', token), /attachment was replaced/);
  const reattached = (await load('native')).result._meta.attachmentToken;
  assert.equal((await selection('native', reattached)).result.sessionId, 'native');
});

test('inference streaming crosses worker IPC and cancellation reaches only that request', async t => {
  const f = await fixture(t, `
    export function createDefaultAgentService() {
      return {
        inferenceCatalog: async () => ({ models: [], accounts: [{ id: 'second', provider: 'fixture', label: 'Second' }] }),
        inferenceStream: async (request, { signal, onEvent, principalID }) => {
          onEvent({ type: 'start', principalID });
          if (request.wait) {
            await new Promise(resolve => { if (signal.aborted) resolve(); else signal.addEventListener('abort', resolve, { once: true }); });
            throw Error('Cancelled fixture inference');
          }
          onEvent({ type: 'done', message: { text: request.input } });
        },
        unlockForClient: async value => ({ unlocked: value.workspace === 'fixture' }),
        cancelActive: async () => {}, prepareRetirement: async () => ({ attachmentState: {} }),
      };
    }
  `);
  assert.equal((await f.service.inferenceCatalog()).accounts[0].id, 'second');
  assert.equal((await f.service.unlockForClient({ workspace: 'fixture', unlockKey: 'fixture' })).unlocked, true);
  const controller = new AbortController(), received = [];
  await assert.rejects(f.service.inferenceStream({ wait: true }, { principalID: 'phone', signal: controller.signal, onEvent: event => {
    received.push(event); controller.abort();
  } }), /Cancelled fixture inference/);
  assert.equal(received[0].principalID, 'phone');
  await f.service.inferenceStream({ input: 'next' }, { principalID: 'phone', onEvent: event => received.push(event) });
  assert.equal(received.at(-1).message.text, 'next');
});
