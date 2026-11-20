// The Woven MCP as a stdio MCP server, for runtimes that start one: it
// connects to the Woven server's tool socket (owner-only, on this machine),
// says the key the server gave this runtime, then passes MCP's
// newline-delimited JSON-RPC through in both directions.
//
//     node woven-mcp.mjs SOCKET        (key in WOVEN_MCP_KEY)
import { connect } from 'node:net';

const [socketPath] = process.argv.slice(2);
const key = process.env.WOVEN_MCP_KEY;
if (!socketPath || !key) {
  process.stderr.write('usage: WOVEN_MCP_KEY=… node woven-mcp.mjs SOCKET\n');
  process.exit(2);
}

const socket = connect(socketPath, () => {
  socket.write(JSON.stringify({ key }) + '\n');
  process.stdin.pipe(socket);
  socket.pipe(process.stdout);
});
socket.on('error', error => {
  process.stderr.write(`woven-mcp: the Woven server is not reachable (${error.message}).\n`);
  process.exit(1);
});
socket.on('close', () => process.exit(0));
process.stdin.on('end', () => socket.end());
