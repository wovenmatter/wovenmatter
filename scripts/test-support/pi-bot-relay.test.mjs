// The relay on a bot device, over its real stdio and real loopback sockets.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import { fileURLToPath } from "node:url";
import { readFileSync } from "node:fs";
import test from "node:test";

const source = readFileSync(fileURLToPath(new URL("../pi-bot-relay.mjs", import.meta.url)), "utf8");
const T = { connect: 1, data: 2, close: 3, hello: 4, accept: 5 };

function frame(type, id, payload = Buffer.alloc(0)) {
  const header = Buffer.alloc(9);
  header.writeUInt8(type, 0);
  header.writeUInt32BE(id, 1);
  header.writeUInt32BE(payload.length, 5);
  return Buffer.concat([header, payload]);
}

function startRelay(...args) {
  const child = spawn(process.execPath, ["--input-type=module", "-e", source, "--", ...args.map(String)], { stdio: ["pipe", "pipe", "pipe"] });
  const frames = [];
  const waiters = [];
  let pending = Buffer.alloc(0);
  child.stdout.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 9) {
      const length = pending.readUInt32BE(5);
      if (pending.length < 9 + length) break;
      frames.push({ type: pending.readUInt8(0), id: pending.readUInt32BE(1), payload: pending.subarray(9, 9 + length) });
      pending = pending.subarray(9 + length);
      for (const wake of waiters.splice(0)) wake();
    }
  });
  const next = async (type, id) => {
    const deadline = Date.now() + 10_000;
    for (;;) {
      const index = frames.findIndex((f) => f.type === type && (id === undefined || f.id === id));
      if (index >= 0) return frames.splice(index, 1)[0];
      assert.ok(Date.now() < deadline, `no frame of type ${type}`);
      await Promise.race([new Promise((r) => waiters.push(r)), new Promise((r) => setTimeout(r, 100))]);
    }
  };
  return { child, next, send: (...f) => child.stdin.write(frame(...f)) };
}

const listen = (handler) => new Promise((resolve) => {
  const server = net.createServer(handler);
  server.listen(0, "127.0.0.1", () => resolve(server));
});
const exited = (child) => new Promise((resolve) => child.on("exit", resolve));

test("a stream reaches the target and comes back, and closing it reaches the other end", async () => {
  const target = await listen((socket) => socket.on("data", (d) => socket.write(Buffer.concat([Buffer.from("echo:"), d]))));
  const relay = startRelay(target.address().port, "none");
  assert.deepEqual(JSON.parse((await relay.next(T.hello)).payload), { reversePort: null });
  relay.send(T.connect, 1);
  relay.send(T.data, 1, Buffer.from("hi"));
  assert.equal((await relay.next(T.data, 1)).payload.toString(), "echo:hi");
  relay.send(T.close, 1);
  await relay.next(T.close, 1);
  relay.child.stdin.end();
  assert.equal(await exited(relay.child), 0);
  target.close();
});

test("a refused target closes only its stream", async () => {
  const unused = await listen(() => {});
  const port = unused.address().port;
  await new Promise((r) => unused.close(r));
  const relay = startRelay(port, "none");
  await relay.next(T.hello);
  relay.send(T.connect, 1);
  await relay.next(T.close, 1);
  assert.equal(relay.child.exitCode, null);
  relay.child.stdin.end();
  await exited(relay.child);
});

test("the reverse port accepts clients on loopback, and a taken port falls back to a free one", async () => {
  const taken = await listen(() => {});
  const relay = startRelay(9, taken.address().port);
  const { reversePort } = JSON.parse((await relay.next(T.hello)).payload);
  assert.notEqual(reversePort, taken.address().port);
  const client = net.connect({ host: "127.0.0.1", port: reversePort });
  const accepted = await relay.next(T.accept);
  assert.equal(accepted.id % 2, 0, "device streams are even, so they never collide with the Mac's");
  client.write("request");
  assert.equal((await relay.next(T.data, accepted.id)).payload.toString(), "request");
  const reply = new Promise((resolve) => client.once("data", resolve));
  relay.send(T.data, accepted.id, Buffer.from("response"));
  assert.equal((await reply).toString(), "response");
  relay.send(T.close, accepted.id);
  await new Promise((resolve) => client.on("close", resolve));
  relay.child.stdin.end();
  await exited(relay.child);
  taken.close();
});

test("a client that finishes sending still gets its reply, in both directions", async () => {
  const halfOpen = net.createServer({ allowHalfOpen: true }, (socket) => {
    socket.on("end", () => socket.end("reply-after-eof"));
    socket.resume();
  });
  await new Promise((r) => halfOpen.listen(0, "127.0.0.1", r));
  const relay = startRelay(halfOpen.address().port, 0);
  const { reversePort } = JSON.parse((await relay.next(T.hello)).payload);
  // The Mac's client finishes first, as `nc` or a one-shot request does.
  relay.send(T.connect, 1);
  relay.send(T.data, 1, Buffer.from("request"));
  relay.send(T.close, 1);
  assert.equal((await relay.next(T.data, 1)).payload.toString(), "reply-after-eof");
  await relay.next(T.close, 1);
  // A client on the device does the same through the reverse port.
  const client = net.connect({ host: "127.0.0.1", port: reversePort, allowHalfOpen: true });
  const chunks = [];
  client.on("data", (d) => chunks.push(d));
  const accepted = await relay.next(T.accept);
  client.end("tools");
  assert.equal((await relay.next(T.data, accepted.id)).payload.toString(), "tools");
  await relay.next(T.close, accepted.id);
  relay.send(T.data, accepted.id, Buffer.from("mcp-reply"));
  relay.send(T.close, accepted.id);
  await new Promise((resolve) => client.on("close", resolve));
  assert.equal(Buffer.concat(chunks).toString(), "mcp-reply");
  relay.child.stdin.end();
  await exited(relay.child);
  halfOpen.close();
});

test("a large transfer survives a slow reader intact in both directions", async () => {
  const size = 32 * 1024 * 1024;
  const payload = Buffer.alloc(1024 * 1024, 7);
  const target = await listen((socket) => {
    let received = 0;
    socket.on("data", (d) => {
      received += d.length;
      if (received === size) {
        socket.write(Buffer.from("got-it"));
      }
    });
  });
  const relay = startRelay(target.address().port, "none");
  await relay.next(T.hello);
  relay.send(T.connect, 1);
  for (let i = 0; i < 32; i++) relay.send(T.data, 1, payload);
  assert.equal((await relay.next(T.data, 1)).payload.toString(), "got-it");
  relay.child.stdin.end();
  await exited(relay.child);
  target.close();
});

test("the relay exits when the Mac goes away", async () => {
  const relay = startRelay(9, 0);
  await relay.next(T.hello);
  relay.child.stdin.destroy();
  assert.equal(await exited(relay.child), 0);
});

test("an invalid port stops before listening", async () => {
  const relay = startRelay("nope", "none");
  assert.equal(await exited(relay.child), 64);
});
