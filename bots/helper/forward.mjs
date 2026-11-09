// Woven preview forwarder: one TCP connection to a port inside the bot's container, carried over
// this process's stdio (a Docker exec stream). The runtime's activity proxy runs one per client
// connection, so previews need no published container ports.
import { connect } from "node:net";

const port = Number(process.argv[2]);
if (!Number.isInteger(port) || port < 1 || port > 65535) {
  process.stderr.write("usage: forward.mjs <port>\n");
  process.exit(2);
}
const socket = connect({ host: "127.0.0.1", port });
socket.on("connect", () => {
  process.stdin.pipe(socket);
  socket.pipe(process.stdout);
});
// The client finished sending: half-close toward the service, keep reading its reply.
process.stdin.on("end", () => socket.end());
socket.on("end", () => process.stdout.end());
socket.on("close", () => process.exit(0));
socket.on("error", (error) => {
  process.stderr.write(`forward: ${error.code ?? error.message}\n`);
  process.exit(1);
});
