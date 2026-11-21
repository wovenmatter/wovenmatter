import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';

const agent = fileURLToPath(new URL('./agent.mjs', import.meta.url));

// Plays the server: starts the agent, answers `woven/credentials` and `woven/settings`, and records what it sends.
export function startAgent({ data, cwd, credentials = { synthetic: { type: 'apiKey', key: 'test-key' } }, settings = {} }) {
  const child = spawn(process.execPath, [agent], { cwd, env: { ...process.env, WOVEN_PI_DATA: data }, stdio: ['pipe', 'pipe', 'inherit'] });
  const waiting = new Map(), updates = [], notifications = [];
  let credentialRequests = 0, next = 0;
  const send = message => child.stdin.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
  createInterface({ input: child.stdout }).on('line', line => {
    const message = JSON.parse(line);
    if (message.method === 'woven/credentials') { credentialRequests++; send({ id: message.id, result: { credentials } }); }
    else if (message.method === 'woven/settings') send({ id: message.id, result: { settings } });
    else if (message.method === 'session/update') updates.push(message.params);
    else if (message.method) notifications.push(message);
    else waiting.get(message.id)?.(message);
  });
  const exited = new Promise(resolve => child.once('exit', resolve));
  return {
    updates, notifications, get credentialRequests() { return credentialRequests; },
    request(method, params) {
      const id = ++next;
      return new Promise(resolve => { waiting.set(id, resolve); send({ id, method, params }); });
    },
    async stop() { child.stdin.end(); await exited; },
  };
}
