import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { setTimeout as delay } from 'node:timers/promises';
import { SessionMCPContext, validateMCPConnection } from '../src/mcp-context.mjs';
import { WovenMCPClient, wovenMCPTools } from '../src/woven-mcp.mjs';

const connection = captureID => ({ endpointURL: 'http://127.0.0.1:7337/mcp', bearerToken: 'fixture-token', captureID });

test('MCP input authority advances on native consumption and stays fixed for running calls and children', () => {
  const session = new SessionMCPContext();
  session.reconnect(connection());
  assert.throws(() => session.connection(), /no Woven MCP connection/);
  session.enqueue(connection('first')); session.consumed();
  const running = session.connection(), child = session.fork();
  const reject = session.enqueue(connection('rejected'));
  assert.equal(session.connection().captureID, 'first'); reject();
  session.enqueue(connection('stopped')); session.finish();
  assert.equal(session.connection().captureID, 'first');
  session.enqueue(connection('second')); session.consumed();
  assert.equal(session.connection().captureID, 'second');
  assert.equal(running.captureID, 'first');
  assert.equal(child.connection().captureID, 'first');
  assert.throws(() => child.reconnect(connection('third')), /cannot be changed/);
  assert.throws(() => child.enqueue(connection('third')), /cannot be changed/);
  session.enqueue(undefined); session.consumed();
  assert.throws(() => session.connection(), /no Woven MCP connection/);
  assert.throws(() => validateMCPConnection({ ...connection(), endpointURL: 'http://example.test/mcp' }), /HTTPS/);
  assert.throws(() => validateMCPConnection({ ...connection(), endpointURL: 'https://example.test/mcp', bearerToken: 'bad\nheader' }), /Invalid/);
});

test('restored children renew only their originating session credential and never adopt a later capture', () => {
  const parent = new SessionMCPContext();
  parent.enqueue({ ...connection('origin-input'), sessionID: 'origin-session' }); parent.consumed();
  const origin = JSON.parse(JSON.stringify(parent.origin()));
  assert.deepEqual(origin, { sessionID: 'origin-session', captureID: 'origin-input' });
  const child = SessionMCPContext.restore(origin, () => parent.discoveryConnection());
  parent.reconnect({ ...connection('later-input'), sessionID: 'origin-session', bearerToken: 'renewed-credential' });
  assert.deepEqual(child.connection(), { endpointURL: connection().endpointURL, bearerToken: 'renewed-credential', sessionID: 'origin-session', captureID: 'origin-input' });
  parent.enqueue({ ...connection('latest-input'), sessionID: 'origin-session', bearerToken: 'renewed-credential' }); parent.consumed();
  assert.equal(child.connection().captureID, 'origin-input');
  parent.reconnect({ ...connection('foreign-input'), sessionID: 'another-session' });
  assert.throws(() => child.connection(), /originating Woven session is unavailable/);
  assert.throws(() => SessionMCPContext.restore(undefined, () => parent.discoveryConnection()).connection(), /no original Woven MCP input binding/);
  assert.ok(!JSON.stringify(origin).includes('fixture-token'));
});

async function fixture(t, handler) {
  const packets = [], authorizations = [];
  const server = createServer(async (request, response) => {
    authorizations.push(request.headers.authorization);
    if (request.method !== 'POST') { response.writeHead(405).end(); return; }
    let bytes = ''; for await (const part of request) bytes += part;
    const packet = JSON.parse(bytes); packets.push(packet);
    if (packet.id === undefined) { response.writeHead(202).end(); return; }
    const result = packet.method === 'initialize'
      ? { protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'Woven MCP fixture', version: '1' } }
      : await handler(packet, response);
    if (result === undefined) return;
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ jsonrpc: '2.0', id: packet.id, result }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const bound = { endpointURL: `http://127.0.0.1:${server.address().port}/mcp`, bearerToken: 'fixture-token' };
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  return { bound, packets, authorizations };
}

test('MCP discovers focused tools and preserves images, structured results, errors and per-input capture', async t => {
  const definitions = [
    { name: 'woven_notes_read', description: 'Read a note.', inputSchema: { type: 'object', properties: { noteID: { type: 'string' }, requestID: { type: 'string' } }, required: ['noteID'] }, annotations: { readOnlyHint: true } },
    { name: 'woven_browser_use', inputSchema: { type: 'object' } },
  ];
  const { bound, packets, authorizations } = await fixture(t, packet => packet.method === 'tools/list'
    ? { tools: definitions } : { content: [{ type: 'image', mimeType: 'image/png', data: 'ZmFrZQ==' }], structuredContent: { requestID: packet.params.arguments.requestID, value: 42 }, isError: packet.params.arguments.action === 'fail' });
  const client = new WovenMCPClient(); t.after(() => client.close());
  const tools = wovenMCPTools(await client.listTools(bound), client, () => ({ ...bound, captureID: 'native-first' }));
  assert.deepEqual(tools.map(tool => tool.name), ['woven_notes_read', 'woven_browser_use']);
  assert.equal(tools[0].replay, 'safe'); assert.equal(tools[1].replay, 'unsafe');
  const result = await tools[0].execute('native-tool-id', { noteID: 'note' });
  assert.deepEqual(result.content, [{ type: 'image', mimeType: 'image/png', data: 'ZmFrZQ==' }]);
  assert.equal(result.structuredContent.value, 42);
  assert.equal(packets.find(packet => packet.method === 'tools/call').params._meta.wovenContextID, 'native-first');
  assert.match(result.structuredContent.requestID, /^[0-9a-f-]{36}$/);
  assert.equal((await tools[1].execute('native-tool-id', { action: 'fail' })).isError, true);
  assert.ok(authorizations.length && authorizations.every(value => value === 'Bearer fixture-token'));
});

test('MCP cancellation aborts the active request and cancels only its own automation operation', { timeout: 10000 }, async t => {
  const { bound, packets } = await fixture(t, (packet, response) => {
    if (packet.method === 'tools/call' && packet.params.name === 'woven_computer_use') {
      response.writeHead(200, { 'content-type': 'text/event-stream' }); response.write(': waiting\n\n'); return;
    }
    return { content: [] };
  });
  const client = new WovenMCPClient(); t.after(() => client.close());
  const controller = new AbortController();
  const pending = client.callTool({ ...bound, captureID: 'native-input' }, 'woven_computer_use', { action: 'type', text: 'fixture' }, controller.signal);
  const outcome = pending.then(() => null, error => error);
  const deadline = Date.now() + 5000;
  while (!packets.some(packet => packet.method === 'tools/call')) { assert.ok(Date.now() < deadline); await delay(10); }
  controller.abort(); assert.ok(await outcome);
  const original = packets.find(packet => packet.method === 'tools/call' && packet.params.name === 'woven_computer_use');
  const cancellation = packets.find(packet => packet.method === 'tools/call' && packet.params.name === 'woven_computer_use_cancel');
  assert.equal(cancellation.params.arguments.id, original.params.arguments.requestID);
  assert.equal(cancellation.params._meta.wovenContextID, 'native-input');
  assert.equal(packets.filter(packet => packet.params?.name === 'woven_computer_use').length, 1);
});
