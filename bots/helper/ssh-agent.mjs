// Woven SSH agent relay (Settings → GitHub). Runs inside a bot's container (as the `bot` user)
// over a long-lived Docker exec and listens on the agent socket git's ssh asks
// (`IdentityAgent` in github.conf). Each request goes to the runtime over stdio and from there
// to the machine's signing agent, which holds the key and checks the bot is on every time. It
// holds no key. Mounted read-only from the runtime's helper volume.
//
// Out: { ready: true }   listening (the runtime then writes github.conf)
//      { id, m }   one agent request (base64, without its length prefix)
// In:  { id, m }   its reply
import { chmodSync, mkdirSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:net";
import { dirname } from "node:path";
import { createInterface } from "node:readline";

const path = process.argv[2];
if (!path) {
  process.stderr.write("usage: ssh-agent.mjs <socket>\n");
  process.exit(2);
}
const FAILURE = Buffer.from([5]);
const MAXIMUM = 256 * 1024;
const waiting = new Map();
let next = 1;
let listening;

/** Removes the socket only if it is still this relay's: a replacement may already listen there. */
function removeOwnSocket() {
  try {
    if (listening && statSync(path).ino === listening) rmSync(path, { force: true });
  } catch {}
}

createInterface({ input: process.stdin })
  .on("line", (line) => {
    try {
      const { id, m } = JSON.parse(line);
      waiting.get(id)?.(Buffer.from(String(m), "base64"));
      waiting.delete(id);
    } catch {}
  })
  // The runtime went away: nobody can answer, so stop listening.
  .on("close", () => {
    removeOwnSocket();
    process.exit(0);
  });

function ask(message) {
  return new Promise((resolve) => {
    const id = next++;
    waiting.set(id, resolve);
    process.stdout.write(`${JSON.stringify({ id, m: message.toString("base64") })}\n`);
    setTimeout(() => {
      if (waiting.delete(id)) resolve(FAILURE);
    }, 30_000).unref();
  });
}

const frame = (body) => {
  const length = Buffer.alloc(4);
  length.writeUInt32BE(body.length);
  return Buffer.concat([length, body]);
};

mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
rmSync(path, { force: true });
const server = createServer((socket) => {
  let pending = Buffer.alloc(0);
  let replies = Promise.resolve();
  socket.on("data", (chunk) => {
    pending = Buffer.concat([pending, chunk]);
    while (pending.length >= 4) {
      const length = pending.readUInt32BE(0);
      if (length === 0 || length > MAXIMUM) return socket.destroy();
      if (pending.length < 4 + length) return;
      const message = Buffer.from(pending.subarray(4, 4 + length));
      pending = pending.subarray(4 + length);
      // Replies go back in request order.
      replies = replies.then(async () => {
        const answer = await ask(message);
        if (!socket.destroyed) socket.write(frame(answer));
      });
    }
  });
  socket.on("error", () => {});
});
server.listen(path, () => {
  chmodSync(path, 0o600);
  listening = statSync(path).ino;
  process.stdout.write(`${JSON.stringify({ ready: true })}\n`);
});
