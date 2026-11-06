import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';
import { mkdtemp, rm, symlink } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { WebSocket } from 'ws';
import { chromium } from 'playwright-core';
import { browserAction, createCEFBridge } from '../src/browser-runtime.mjs';

test('the published Playwright client connects to the single-page CEF bridge without browser defaults', { timeout: 10000 }, async t => {
  let receive;
  const calls = [];
  const bridge = await createCEFBridge({ target: { id: 'owned', url: 'https://fixture.test/', title: 'Fixture' }, version: '156.0.8078.80',
    receiveNative: callback => { receive = callback; return () => {}; },
    sendNative: packet => {
      calls.push(packet);
      const result = packet.method === 'Page.getFrameTree'
        ? { frameTree: { frame: { id: 'owned', url: 'https://fixture.test/', securityOrigin: 'https://fixture.test', mimeType: 'text/html' } } }
        : packet.method === 'Page.createIsolatedWorld' ? { executionContextId: 2 }
        : ['Runtime.evaluate', 'Runtime.callFunctionOn'].includes(packet.method) ? { result: { type: 'number', value: 42 } } : {};
      queueMicrotask(() => {
        receive({ id: packet.id, result });
        if (packet.method === 'Runtime.enable') receive({ method: 'Runtime.executionContextCreated', params: { context: {
          id: 1, origin: 'https://fixture.test', name: '', auxData: { isDefault: true, frameId: 'owned' },
        } } });
      });
    } });
  t.after(() => bridge.close());
  const browser = await chromium.connectOverCDP(bridge.endpoint, { noDefaults: true, timeout: 5000 });
  t.after(() => browser.close());
  const pages = browser.contexts()[0].pages();
  assert.equal(pages.length, 1);
  assert.equal(pages[0].url(), 'https://fixture.test/');
  assert.deepEqual(await browserAction(pages[0], { action: 'evaluate', code: '6 * 7' }), { content: [{ type: 'text', text: '42' }] });
  assert.ok(calls.some(packet => packet.method === 'Runtime.evaluate'));
  assert.equal(calls.some(packet => packet.method === 'Target.createTarget'), false);
});

test('browser helper launches through a symlink and waits for the host to acknowledge its terminal result', { timeout: 5000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-browser-entrypoint-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const entrypoint = join(root, 'browser-runtime.mjs');
  await symlink(fileURLToPath(new URL('../src/browser-runtime.mjs', import.meta.url)), entrypoint);
  const child = spawn(process.execPath, [entrypoint], {
    env: { PATH: process.env.PATH }, stdio: ['pipe', 'pipe', 'pipe'],
  });
  const exited = once(child, 'close');
  t.after(async () => { if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL'); await exited; });
  const lines = createInterface({ input: child.stdout });
  t.after(() => lines.close());
  let nativeCalls = 0;
  const result = new Promise((resolve, reject) => {
    child.once('error', reject);
    lines.on('line', line => {
      const packet = JSON.parse(line);
      if (packet.cdp) {
        nativeCalls++;
        assert.equal(packet.cdp.method, 'Page.handleJavaScriptDialog');
        child.stdin.write(JSON.stringify({ native: { id: packet.cdp.id, result: {} } }) + '\n');
      }
      if (packet.result) resolve(packet.result);
      if (packet.error) reject(new Error(packet.error));
    });
  });
  child.stdin.write(JSON.stringify({ target: { id: 'fixture', url: 'about:blank' }, version: '156', input: { action: 'dialog', accept: true } }) + '\n');
  assert.deepEqual(await result, { content: [{ type: 'text', text: 'Browser dialog handled.' }] });
  assert.equal(nativeCalls, 1);
  assert.equal(await Promise.race([exited.then(() => false), delay(100).then(() => true)]), true,
    'CEF can still deliver native events while the host is consuming the result');
  await new Promise((resolve, reject) => child.stdin.write(JSON.stringify({ native: { method: 'Runtime.executionContextsCleared', params: {} } }) + '\n', error => error ? reject(error) : resolve()));
  child.stdin.end();
  assert.deepEqual(await exited, [0, null]);
});

test('private CDP bridge owns one page, rejects discovery outside it and maps native sessions', async t => {
  let receiver;
  const native = [];
  const bridge = await createCEFBridge({ target: { id: 'owned', url: 'https://fixture.test', title: 'Fixture' }, version: '154',
    sendNative: packet => native.push(packet), receiveNative: callback => { receiver = callback; return () => { receiver = undefined; }; } });
  t.after(() => bridge.close());
  const refused = new WebSocket(bridge.endpoint.replace(/\/[\w-]+$/, '/wrong-token'));
  await new Promise(resolve => refused.once('close', resolve));
  const socket = new WebSocket(bridge.endpoint);
  await new Promise(resolve => socket.once('open', resolve));
  const packets = [];
  socket.on('message', value => packets.push(JSON.parse(value)));
  const request = async packet => {
    const response = new Promise(resolve => socket.once('message', value => resolve(JSON.parse(value))));
    socket.send(JSON.stringify(packet)); return response;
  };
  const targets = await request({ id: 1, method: 'Target.getTargets' });
  assert.deepEqual(targets.result.targetInfos.map(x => x.targetId), ['owned']);
  assert.ok((await request({ id: 2, method: 'Target.createTarget', params: { url: 'file:///private/fixture' } })).error);
  socket.send(JSON.stringify({ id: 3, sessionId: 'woven-page', method: 'Runtime.evaluate', params: { expression: '42' } }));
  await new Promise(resolve => setImmediate(resolve));
  while (!native.length) await new Promise(resolve => setTimeout(resolve, 1));
  assert.equal(native[0].sessionId, undefined);
  receiver({ id: native[0].id, result: { result: { value: 42 } } });
  await new Promise(resolve => setTimeout(resolve, 5));
  assert.ok(packets.some(x => x.id === 3 && x.sessionId === 'woven-page' && x.result.result.value === 42));
  const dialog = bridge.command('Page.handleJavaScriptDialog', { accept: true });
  receiver({ id: native.at(-1).id, result: {} });
  await dialog;
  socket.terminate();
});

test('browser upload accepts 2 MiB and rejects one extra byte before changing the file input', async () => {
  const files = [];
  const page = { setDefaultTimeout() {}, setDefaultNavigationTimeout() {},
    url: () => 'about:blank', title: async () => 'Upload fixture',
    locator: () => ({ setInputFiles: async file => { files.push(file); } }) };
  const input = { action: 'upload', selector: '#file', name: 'boundary.bin', data: Buffer.alloc(2 * 1024 * 1024).toString('base64') };
  await browserAction(page, input);
  assert.equal(files.length, 1);
  assert.equal(files[0].buffer.length, 2 * 1024 * 1024);
  const oversized = { ...input, data: Buffer.alloc(2 * 1024 * 1024 + 1).toString('base64') };
  assert.equal(oversized.data.length, input.data.length);
  await assert.rejects(browserAction(page, oversized), /at most 2 MiB/);
  assert.equal(files.length, 1);
});
