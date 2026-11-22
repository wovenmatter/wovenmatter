import { spawn } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import { claudeExecutable, claudeProvider, claudeStatus } from './claude.mjs';
import { ServerCredentials, toWire } from './credentials.mjs';
import { catalog, createModels, probeLocalServer, providerList, registerLocalServers, subscriptions } from './models.mjs';
import { humanMessage } from './rpc.mjs';
import { updateSDK } from './sdk.mjs';
import { dataDirectory } from './data.mjs';

// One request on stdin, JSON lines on stdout, then exit. Logins can ask questions:
// `{"event":{"prompt":{id,message}}}` is answered with `{"answerTo":id,"answer":…}`.
export async function runControl() {
  const data = dataDirectory();
  await mkdir(data, { recursive: true, mode: 0o700 });
  const write = value => new Promise(resolve => process.stdout.write(JSON.stringify(value) + '\n', resolve));
  const answers = new Map();
  const lines = createInterface({ input: process.stdin, crlfDelay: Infinity });
  // A login ends when the server closes stdin.
  const closed = new Promise(resolve => lines.once('close', resolve));
  const request = await new Promise((resolve, reject) => {
    lines.on('line', line => {
      let message;
      try { message = JSON.parse(line); } catch { return; }
      if (message.answerTo !== undefined) { answers.get(message.answerTo)?.(String(message.answer ?? '')); answers.delete(message.answerTo); }
      else resolve(message);
    });
    lines.once('close', () => reject(new Error('No request was given.')));
  });
  const ask = message => new Promise(resolve => {
    const id = randomUUID();
    answers.set(id, resolve);
    void write({ event: { prompt: { id, message } } });
  });
  try {
    const result = await perform(request, { data, write, ask, closed });
    await write({ result });
    process.exit(0);
  } catch (error) {
    await write({ error: humanMessage(error) });
    process.exit(1);
  }
}

async function perform(request, { data, write, ask, closed }) {
  if (request.action === 'update-sdk') return updateSDK(data);
  if (request.action === 'probe-local-server') return probeLocalServer(request.url, request.key);
  // Only the catalog needs credentials and model servers; the server passes them in with the request.
  const credentials = new ServerCredentials({ fetch: async () => ({ credentials: request.credentials ?? {} }), report: async () => {} });
  const models = await createModels({ dataDirectory: data, credentials });
  const { runtime } = models;
  registerLocalServers(runtime, request.localServers);
  // With the providers, whether Claude Code is signed in here (null when it gave no answer), so
  // the server's Claude sign-in follows Claude Code's own.
  if (request.action === 'providers') return { providers: providerList(runtime), claudeSignedIn: (await claudeStatus()).signedIn ?? null };
  if (request.action === 'models') return { models: await catalog(models, { refresh: request.refresh === true }) };
  if (request.action !== 'login') throw new Error(`Unknown action ${request.action}.`);
  if (!subscriptions.some(provider => provider.id === request.provider)) throw new Error('That provider does not sign in with a subscription.');
  if (request.provider === claudeProvider) return { credential: await claudeLogin({ write, ask, closed }) };
  const deviceID = await installationID(data);
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 10 * 60 * 1000);
  void closed.then(() => controller.abort());
  try {
    const credential = await runtime.login(request.provider, 'oauth', {
      signal: controller.signal,
      prompt: prompt => prompt.type === 'select' ? Promise.resolve(prompt.options[0].id) : ask(prompt.message),
      notify: event => {
        if (event.type === 'auth_url') void write({ event: { url: event.url, instructions: event.instructions ?? 'Open this link to sign in.' } });
        else if (event.type === 'device_code') void write({ event: { url: event.verificationUri, code: event.userCode, instructions: 'Open this link and enter the code.' } });
        else if (event.message) void write({ event: { instructions: event.message } });
      },
    }, { getDeviceId: () => deviceID, agentName: 'Woven Matter' });
    return { credential: toWire(credential) };
  } finally { clearTimeout(timer); }
}

// A stable identifier for this installation, which some sign-ins send.
async function installationID(data) {
  const file = join(data, 'device-id');
  const saved = (await readFile(file, 'utf8').catch(() => '')).trim();
  if (saved) return saved;
  const id = randomUUID();
  await writeFile(file, id, { mode: 0o600 });
  return id;
}

// Claude keeps its own sign-in. When Claude Code is not signed in, run its own
// login, passing the link out and the code the person copies back in.
async function claudeLogin({ write, ask, closed }) {
  if ((await claudeStatus()).signedIn) return { type: 'native' };
  const child = spawn(claudeExecutable(), ['auth', 'login', '--claudeai'], { env: { ...process.env, BROWSER: '/usr/bin/true' }, stdio: ['pipe', 'pipe', 'pipe'] });
  const seen = new Set();
  const consume = line => {
    for (const match of line.matchAll(/https:\/\/[^\s<>"]+/g)) {
      let url;
      try { url = new URL(match[0]); } catch { continue; }
      if (!/(^|\.)(claude\.ai|claude\.com|anthropic\.com)$/.test(url.hostname) || !url.pathname.includes('oauth') || seen.has(url.href)) continue;
      seen.add(url.href);
      void write({ event: { url: url.href, instructions: 'Open this link to sign in to Claude, then paste the code it shows.' } });
      void ask('Paste the code from the Claude sign-in page.').then(code => child.stdin.write(code.trim() + '\n'));
    }
  };
  for (const stream of [child.stdout, child.stderr]) createInterface({ input: stream, crlfDelay: Infinity }).on('line', consume);
  const timer = setTimeout(() => child.kill('SIGTERM'), 10 * 60 * 1000);
  void closed.then(() => child.kill('SIGTERM'));
  const code = await new Promise(resolve => { child.once('close', resolve); child.once('error', () => resolve(-1)); });
  clearTimeout(timer);
  if (code !== 0 || !(await claudeStatus()).signedIn) throw new Error('Claude sign-in did not complete. Try again.');
  return { type: 'native' };
}
