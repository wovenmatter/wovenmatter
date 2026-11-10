// One control request to the in-container supervisor, for health checks and debugging:
//   node /opt/woven-bot/ctl.mjs <method> [json-args]
// Prints the reply value as JSON; exits 1 on an error reply or when the supervisor is not up.
import { connect } from "node:net";

const SOCKET = process.env.WOVEN_CONTROL_SOCKET ?? "/tmp/woven-bot/control.sock";
const [method = "ping", rawArgs = "{}"] = process.argv.slice(2);
const deadline = Date.now() + Number(process.env.WOVEN_CTL_WAIT_MS ?? 20_000);

function once() {
  return new Promise((resolve, reject) => {
    const socket = connect(SOCKET);
    let buffer = "";
    socket.setEncoding("utf8");
    socket.on("connect", () => socket.write(`${JSON.stringify({ method, args: JSON.parse(rawArgs) })}\n`));
    socket.on("data", (chunk) => {
      buffer += chunk;
      if (buffer.includes("\n")) {
        socket.end();
        resolve(JSON.parse(buffer.slice(0, buffer.indexOf("\n"))));
      }
    });
    socket.on("error", reject);
  });
}

for (;;) {
  try {
    const reply = await once();
    if (reply.error) {
      process.stderr.write(`${reply.error}\n`);
      process.exit(1);
    }
    process.stdout.write(`${JSON.stringify(reply.value)}\n`);
    process.exit(0);
  } catch (error) {
    if (Date.now() > deadline) {
      process.stderr.write(`supervisor unavailable: ${error.code ?? error.message}\n`);
      process.exit(1);
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
}
