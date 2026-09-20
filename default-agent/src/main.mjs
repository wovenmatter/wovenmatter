import { createInterface } from 'node:readline';
import { homedir } from 'node:os';
import { resolve, join } from 'node:path';
import { DefaultAgentEngine } from './engine.mjs';

const send = value => process.stdout.write(JSON.stringify(value) + '\n');
const remote = process.argv.includes('--remote');
const control = process.argv.includes('--control');
const directory = process.env.WOVEN_DEFAULT_AGENT_DIRECTORY ?? join(homedir(), '.wovenmatter', 'default-agent');
let payload = JSON.parse(process.env.WOVEN_DEFAULT_AGENT_CONFIGURATION ?? '{}');
// Never pass provider keys to bash or other agent tools through the environment.
delete process.env.WOVEN_DEFAULT_AGENT_CONFIGURATION;
let instance;
async function engine() { return instance ??= await new DefaultAgentEngine({ cwd: process.cwd(), directory, config: payload.config, credentials: payload.credentials }).initialize(); }
async function remoteRequest(path, body) {
  const response = await fetch(`http://127.0.0.1:7337/v1/default-agent/${path}`, { method: body ? 'POST' : 'GET', headers: { Authorization: `Bearer ${process.env.WOVENMATTER_API_TOKEN}`, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(path === 'rpc' ? 24 * 60 * 60 * 1000 : 30000) });
  if (!response.ok) throw new Error(`Default Agent workspace service failed (HTTP ${response.status}).`);
  return response.json();
}
async function invoke(message) {
  const update = value => send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: message.params?.sessionId, update: value } });
  if (control) {
    payload = message;
    const e = await engine();
    if (message.action === 'login') {
      const controller = new AbortController();
      process.stdin.on('end', () => controller.abort());
      e.credentials.signingIn = true;
      const credential = await e.runtime.login(message.provider, 'oauth', { signal: controller.signal,
        notify: notification => send({ notification }),
        prompt: prompt => new Promise((resolve, reject) => { const id = crypto.randomUUID(); pendingPrompts.set(id, resolve); send({ prompt: { ...prompt, signal: undefined }, id }); controller.signal.addEventListener('abort', () => reject(new Error('Sign-in cancelled.')), { once: true }); }) }).finally(() => { e.credentials.signingIn = false; });
      // SDK login persists through the app-owned credential store.
      return { connected: Boolean(credential) };
    }
    return e.status();
  }
  if (!remote) {
    if (message.method === 'woven/configure') {
      const previous = await engine();
      if ([...previous.sessions.values()].some(s => s.busy)) throw new Error('Wait for the active response before applying settings.');
      const sessionIDs = [...previous.sessions.keys()];
      for (const record of previous.sessions.values()) record.session.dispose();
      payload = message.params; instance = undefined;
      const replacement = await engine();
      for (const id of sessionIDs) await replacement.create(id);
      return sessionIDs.length ? replacement.configuration(replacement.sessions.get(sessionIDs[0])) : {};
    }
    return (await engine()).handle(message.method, message.params, update);
  }
  const response = await remoteRequest('rpc', { ...message, operationID: message.method === 'session/prompt' ? (message.params?._meta?.wovenRunID ?? crypto.randomUUID()) : undefined });
  if (!response.operationID) return response.result;
  let cursor = 0;
  while (true) {
    const page = await remoteRequest(`runs/${response.operationID}?after=${cursor}`);
    for (const event of page.updates) update(event);
    cursor = page.cursor;
    if (page.done) { if (page.error) throw new Error(page.error); return page.result; }
    await new Promise(resolve => setTimeout(resolve, 150));
  }
}
const pendingPrompts = new Map();
const lines = createInterface({ input: process.stdin });
lines.on('line', line => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (message.answerTo) { pendingPrompts.get(message.answerTo)?.(message.answer); pendingPrompts.delete(message.answerTo); return; }
  invoke(message).then(result => { if (control) { send({ result }); process.exit(0); } else if (message.id !== undefined) send({ jsonrpc: '2.0', id: message.id, result }); }, error => { const text = error.message?.startsWith('No configured') || /Settings|Default Agent|sign-in|model|connection/i.test(error.message) ? error.message : 'Default Agent could not complete this operation.'; if (control) { send({ error: text }); process.exitCode = 1; lines.close(); } else if (message.id !== undefined) send({ jsonrpc: '2.0', id: message.id, error: { code: -32000, message: text } }); });
});
lines.on('close', () => { if (!control) process.exit(0); });
