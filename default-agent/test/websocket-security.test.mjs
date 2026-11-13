import test from 'node:test';
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { WebSocket, WebSocketServer } from 'ws';

test('default WebSocket transport bounds automatic pongs and accepts a healthy peer after a ping flood', { timeout: 10000 }, async () => {
  const server = new WebSocketServer({ host: '127.0.0.1', port: 0 });
  const peers = new Set();
  server.on('connection', peer => {
    peers.add(peer);
    peer.on('error', () => {});
    peer.on('close', () => peers.delete(peer));
  });
  await once(server, 'listening');
  const origin = `ws://127.0.0.1:${server.address().port}`;
  let attacker, healthy;
  try {
    const connected = once(server, 'connection');
    attacker = new WebSocket(origin);
    attacker.on('error', () => {});
    const [peer] = await connected;
    await once(attacker, 'open');
    const closed = once(peer, 'close');
    // A peer that stops reading must not make the transport queue unbounded
    // automatic pong writes. Coalesce the ping frames into one network batch
    // so the server receives them before write callbacks can drain the queue.
    attacker.pause();
    attacker._socket.cork();
    for (let i = 0; i < 512; i++) attacker.ping(Buffer.alloc(125));
    attacker._socket.uncork();
    const deadline = AbortSignal.timeout(3000);
    await Promise.race([closed, new Promise((_, reject) => deadline.addEventListener('abort', () => reject(new Error('Ping flood was not bounded.')), { once: true }))]);
    assert.equal(peer.readyState, WebSocket.CLOSED);

    healthy = new WebSocket(origin);
    await once(healthy, 'open');
    const pong = once(healthy, 'pong');
    healthy.ping('healthy');
    const [payload] = await pong;
    assert.equal(payload.toString(), 'healthy');
  } finally {
    attacker?.terminate(); healthy?.terminate();
    for (const peer of peers) peer.terminate();
    await new Promise(resolve => server.close(resolve));
  }
});
