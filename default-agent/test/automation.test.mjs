import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { setTimeout as delay } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';
import { WebSocket } from 'ws';
import { browserAction, createCEFBridge } from '../src/browser-runtime.mjs';

test('browser helper keeps its input open until the host acknowledges its terminal result', { timeout: 5000 }, async t => {
  const child = spawn(process.execPath, [fileURLToPath(new URL('../src/browser-runtime.mjs', import.meta.url))], {
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

test('browser viewport clicks and hover stay on the page and reject invalid coordinates', async () => {
  const calls = [];
  const page = { setDefaultTimeout() {}, setDefaultNavigationTimeout() {},
    url: () => 'about:blank', title: async () => 'Coordinate fixture',
    mouse: { click: async (...args) => calls.push(['click', ...args]), move: async (...args) => calls.push(['move', ...args]) } };
  await browserAction(page, { action: 'click', x: 12, y: 34, button: 'right', clickCount: 2 });
  await browserAction(page, { action: 'hover', x: 56, y: 78 });
  assert.deepEqual(calls, [['click', 12, 34, { button: 'right', clickCount: 2 }], ['move', 56, 78]]);
  await assert.rejects(browserAction(page, { action: 'click', x: -1, y: 0 }), /viewport x\/y/);
  await assert.rejects(browserAction(page, { action: 'hover', x: 0 }), /viewport x\/y/);
  assert.equal(calls.length, 2);
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
