import test from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { PassThrough } from 'node:stream';
import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StdioClientTransport } from '@modelcontextprotocol/sdk/client/stdio.js';
import { WebSocket } from 'ws';
import { createCEFBridge } from '../src/browser-runtime.mjs';
import { callAutomation, automationSchemas } from '../src/automation-tools.mjs';

test('bundled MCP server negotiates tools and delivers inline screenshots over stdio', async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-mcp-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const cli = join(root, 'wovenmatter');
  await writeFile(cli, `#!${process.execPath}\nlet text=''; for await(const bytes of process.stdin) text+=bytes; const input=JSON.parse(text); const content=input.action==='upload' ? [{type:'text',text:JSON.stringify({argv:process.argv.slice(2),size:input.data.length})}] : [{type:'image',mimeType:'image/jpeg',data:'ZmFrZQ=='}]; process.stdout.write(JSON.stringify({success:true,result:{content}})+'\\n');\n`, { mode: 0o700 });
  const transport = new StdioClientTransport({ command: process.execPath, args: [fileURLToPath(new URL('../src/automation-mcp.mjs', import.meta.url))], env: { PATH: process.env.PATH, WOVENMATTER_CLI: cli, WOVENMATTER_SOCKET: '/fixture/caller.sock' } });
  const client = new Client({ name: 'fixture', version: '1' });
  t.after(() => client.close());
  await client.connect(transport);
  assert.deepEqual((await client.listTools()).tools.map(x => x.name), ['browser', 'computer']);
  const result = await client.callTool({ name: 'computer', arguments: { action: 'screenshot' } });
  assert.deepEqual(result.content, [{ type: 'image', mimeType: 'image/jpeg', data: 'ZmFrZQ==' }]);
  const data = Buffer.alloc(2 * 1024 * 1024).toString('base64');
  const upload = await client.callTool({ name: 'browser', arguments: { action: 'upload', data } });
  const received = JSON.parse(upload.content[0].text);
  assert.equal(received.size, data.length);
  assert.deepEqual(received.argv.slice(0, 4), ['browser', 'call', '--json', '-']);
  assert.ok(received.argv.join(' ').length < 200);
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

test('automation adapter uses the current scoped CLI, preserves images and cancels its own request', async () => {
  const calls = [];
  const run = (path, args, options) => {
    const child = new EventEmitter(); child.stdin = new PassThrough(); child.stdout = new PassThrough(); child.kill = signal => { child.killed = signal; }; child.unref = () => {};
    calls.push({ path, args, options, child }); return child;
  };
  const environment = { WOVENMATTER_CLI: '/fixture/scoped-cli', WOVENMATTER_SOCKET: '/fixture/owner.sock' };
  const result = callAutomation('browser', { action: 'screenshot', tabId: 'owned' }, environment, undefined, run);
  const content = [{ type: 'image', mimeType: 'image/jpeg', data: 'ZmFrZQ==' }];
  calls[0].child.stdout.write(JSON.stringify({ success: true, result: { content } })); calls[0].child.emit('close', 0);
  assert.deepEqual((await result).content, content);
  assert.equal(calls[0].path, environment.WOVENMATTER_CLI);
  assert.equal(calls[0].options.env, environment);
  assert.deepEqual(JSON.parse(calls[0].child.stdin.read().toString()), { action: 'screenshot', tabId: 'owned' });
  const controller = new AbortController();
  const interrupted = callAutomation('computer', { action: 'type', text: 'fixture' }, environment, controller.signal, run);
  controller.abort(); calls[1].child.emit('close', 1);
  await assert.rejects(interrupted, /interrupted/);
  assert.equal(calls[1].child.killed, 'SIGTERM');
  assert.deepEqual(calls[2].args, ['computer', 'cancel', '--id', calls[1].args.at(-1)]);
  assert.equal(automationSchemas.computer.additionalProperties, false);
  assert.ok(!('sessionId' in automationSchemas.computer.properties));
});
