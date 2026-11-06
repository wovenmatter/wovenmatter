// Runs on a bot device, started by Woven Matter over one SSH command. Carries Pi Bot's
// loopback port to the Mac, and a loopback port on this device back to the Mac's MCP
// endpoint, over this process's stdio. It needs no SSH port forwarding, which hardened
// servers turn off, and it listens on loopback only.
//
// Frame: u8 type, u32 stream id, u32 payload length, payload.
//   connect  Mac -> device  open a stream to Pi Bot
//   data     both           bytes for a stream
//   close    both           the sender has finished this stream
//   hello    device -> Mac  {"reversePort": number|null}, once, when listening
//   accept   device -> Mac  a client connected to the reverse port
import net from "node:net";

const TYPE = { connect: 1, data: 2, close: 3, hello: 4, accept: 5 };
const HEADER = 9;
const MAX_PAYLOAD = 16 * 1024 * 1024;
const EMPTY = Buffer.alloc(0);

const targetPort = Number(process.argv[1]);
const preferredReverse = Number(process.argv[2]) || 0;
const wantsReverse = process.argv[2] !== undefined && process.argv[2] !== "none";
if (!Number.isInteger(targetPort) || targetPort < 1 || targetPort > 65535) {
  process.stderr.write("relay: invalid target port\n");
  process.exit(64);
}

const streams = new Map();
let nextAccept = 2; // The Mac's streams are odd, this device's even.
let outputBlocked = false;

function send(type, id, payload = EMPTY) {
  const header = Buffer.allocUnsafe(HEADER);
  header.writeUInt8(type, 0);
  header.writeUInt32BE(id, 1);
  header.writeUInt32BE(payload.length, 5);
  process.stdout.write(header);
  if (process.stdout.write(payload) === false && !outputBlocked) {
    outputBlocked = true;
    for (const socket of streams.values()) socket.pause();
    process.stdout.once("drain", () => {
      outputBlocked = false;
      for (const socket of streams.values()) socket.resume();
    });
  }
}

function adopt(id, socket) {
  streams.set(id, socket);
  socket.setNoDelay(true);
  if (outputBlocked) socket.pause();
  socket.on("data", (chunk) => send(TYPE.data, id, chunk));
  socket.on("error", () => {});
  socket.on("close", () => {
    if (streams.delete(id)) send(TYPE.close, id);
  });
}

function receive(type, id, payload) {
  if (type === TYPE.connect) {
    adopt(id, net.connect({ host: "127.0.0.1", port: targetPort }));
    return;
  }
  const socket = streams.get(id);
  if (!socket) return;
  if (type === TYPE.close) {
    socket.end();
  } else if (type === TYPE.data && socket.write(payload) === false) {
    process.stdin.pause();
    socket.once("drain", () => process.stdin.resume());
    socket.once("close", () => process.stdin.resume());
  }
}

let pending = EMPTY;
process.stdin.on("data", (chunk) => {
  pending = pending.length === 0 ? chunk : Buffer.concat([pending, chunk]);
  let offset = 0;
  while (pending.length - offset >= HEADER) {
    const length = pending.readUInt32BE(offset + 5);
    if (length > MAX_PAYLOAD) {
      process.stderr.write("relay: oversized frame\n");
      process.exit(65);
    }
    if (pending.length - offset - HEADER < length) break;
    const start = offset + HEADER;
    receive(pending.readUInt8(offset), pending.readUInt32BE(offset + 1), pending.subarray(start, start + length));
    offset = start + length;
  }
  pending = offset === pending.length ? EMPTY : pending.subarray(offset);
});

function finish() {
  for (const socket of streams.values()) socket.destroy();
  process.exit(0);
}
// The Mac or SSH went away. Nothing here outlives the connection.
process.stdin.on("end", finish);
process.stdin.on("close", finish);
process.stdout.on("error", finish);

function hello(reversePort) {
  send(TYPE.hello, 0, Buffer.from(JSON.stringify({ reversePort })));
}

if (!wantsReverse) {
  hello(null);
} else {
  const server = net.createServer((socket) => {
    const id = nextAccept;
    nextAccept += 2;
    send(TYPE.accept, id);
    adopt(id, socket);
  });
  server.on("error", (error) => {
    if (error.code === "EADDRINUSE" && preferredReverse !== 0 && !server.listening) {
      server.listen(0, "127.0.0.1"); // Taken: any free port will do, and the Mac is told which.
      return;
    }
    process.stderr.write(`relay: reverse port: ${error.code ?? error.message}\n`);
    process.exit(70);
  });
  server.on("listening", () => hello(server.address().port));
  server.listen(preferredReverse, "127.0.0.1");
}
