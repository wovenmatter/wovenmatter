// Woven preview forwarder: one TCP connection to a port inside the bot's container, carried over
// this process's stdio (a Docker exec stream). The runtime's activity proxy runs one per client
// connection, so previews need no published container ports.
import { connect } from "node:net";

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  process.stderr.write("usage: forward.mjs <port>\n");
  process.exit(2);
}
// A preview connection may be what woke the container: its restart list is still starting, so a
// refused connection is retried for a while instead of failing the visitor's first request.
const WAIT_MS = Number(process.env.WOVEN_FORWARD_WAIT_MS ?? 20_000);
const deadline = Date.now() + WAIT_MS;
let current;
// The client finished sending: half-close toward the service, keep reading its reply. (stdin only
// flows once piped to a connected socket, so this never fires before that.)
process.stdin.on("end", () => current?.end());

function open() {
  const socket = connect({ host: "127.0.0.1", port });
  current = socket;
  let connected = false;
  socket.on("connect", () => {
    connected = true;
    process.stdin.pipe(socket);
    socket.pipe(process.stdout);
  });
  socket.on("end", () => process.stdout.end());
  socket.on("close", () => {
    if (connected) process.exit(0);
  });
  socket.on("error", (error) => {
    if (!connected && error.code === "ECONNREFUSED" && Date.now() < deadline) {
      socket.destroy();
      setTimeout(open, 250);
      return;
    }
    process.stderr.write(`forward: ${error.code ?? error.message}\n`);
    process.exit(1);
  });
}
open();
