import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { setTimeout as delay } from 'node:timers/promises';
import { ExecutorBroker } from '../src/executor/broker.mjs';

async function until(predicate) {
  const deadline = Date.now() + 5000;
  while (!await predicate()) {
    assert.ok(Date.now() < deadline, 'Fixture did not reach the expected state.');
    await delay(10);
  }
}

test('Executor uses the v2 HTTP client with a legacy server, scoped credentials and cancellable non-replayed calls', { timeout: 15000 }, async t => {
  const directory = await mkdtemp(join(tmpdir(), 'woven-mcp-http-'));
  const packets = [], headers = [], paths = [];
  const server = createServer(async (request, response) => {
    headers.push(request.headers.authorization); paths.push(request.url);
    if (request.method !== 'POST') { response.writeHead(405).end(); return; }
    let input = ''; for await (const bytes of request) input += bytes;
    const packet = JSON.parse(input); packets.push(packet);
    if (packet.id === undefined) { response.writeHead(202).end(); return; }
    let result;
    if (packet.method === 'initialize') result = { protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'fixture-executor', version: '2' } };
    else if (packet.method === 'tools/list') result = { tools: [{ name: 'execute', inputSchema: { type: 'object' } }] };
    else if (packet.method === 'tools/call') {
      if (packet.params.arguments.code === 'wait') {
        response.writeHead(200, { 'content-type': 'text/event-stream' }); response.write(': fixture waiting\n\n'); return;
      }
      // Deployed v1 servers may omit content alongside structuredContent.
      result = { structuredContent: { status: 'completed', execution: { ok: true, value: 42 } } };
    } else { response.writeHead(400).end(); return; }
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ jsonrpc: '2.0', id: packet.id, result }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const broker = await new ExecutorBroker(directory).load();
  t.after(async () => {
    await broker.stop(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
    await rm(directory, { recursive: true, force: true });
  });
  broker.config = { id: randomUUID(), location: 'local' };
  broker.origin = `http://127.0.0.1:${server.address().port}`;
  broker.server = { apiKey: 'fixture-manager-key' };
  const scope = { id: randomUUID(), grant: { resource: `${broker.origin}/mcp?connection=fixture`, token: 'fixture-scoped-token', expires: Date.now() + 3600000 } };
  const start = async code => {
    const request = { id: randomUUID(), session: 'fixture-session', scope, code };
    await broker.start(request); const job = broker.owned(request.id, request.session);
    await broker.advance(job, { action: 'accept' }); return { job, request };
  };
  const completed = await start('return 42');
  await until(() => !completed.job.busy);
  assert.equal(completed.job.status, 'completed');
  assert.equal(completed.job.result.execution.value, 42);
  const stopped = await start('wait');
  await until(() => packets.some(packet => packet.method === 'tools/call' && packet.params.arguments.code === 'wait'));
  const inFlight = packets.find(packet => packet.method === 'tools/call' && packet.params.arguments.code === 'wait');
  await broker.cancel(stopped.job);
  await until(() => !stopped.job.busy);
  await until(() => packets.some(packet => packet.method === 'notifications/cancelled' && packet.params.requestId === inFlight.id));
  assert.equal((await broker.start(stopped.request)).status, 'cancelled');
  assert.equal(packets.filter(packet => packet.method === 'tools/call').length, 2);
  assert.ok(headers.length > 0 && headers.every(value => value === 'Bearer fixture-scoped-token'));
  assert.ok(paths.every(value => value === '/mcp?connection=fixture'));
});
