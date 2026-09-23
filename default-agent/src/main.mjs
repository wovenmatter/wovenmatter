import { unlink } from 'node:fs/promises';
import { createInterface } from 'node:readline';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { DefaultAgentError, operationErrorMessage } from './config.mjs';
import { DefaultAgentEngine } from './engine.mjs';
import { CredentialVault, sharedCredentials } from './vault.mjs';
import { signInStatuses } from './sign-in-status.mjs';
import { probeServer } from './local-servers.mjs';
import { preferredSignInAnswer } from './sign-in-interaction.mjs';
import { grokAccountProfile } from './account-profile.mjs';
import { nativeClaudeLogin, inlineClaudeLogin } from './claude-runtime.mjs';
import { PermissionRequests, RemotePermissionRequests } from './permissions.mjs';

const send = (value, flushed) => process.stdout.write(JSON.stringify(value) + '\n', flushed);
const remote = process.argv.includes('--remote');
const control = process.argv.includes('--control');
const directory = process.env.WOVEN_DEFAULT_AGENT_DIRECTORY ?? join(homedir(), '.wovenmatter', 'default-agent');
if (process.argv.includes('--claude-login')) process.exit(await nativeClaudeLogin(directory));
const permissions = new PermissionRequests();
const requestPermission = (params, signal) => permissions.request(params, signal,
  (id, value) => send({ jsonrpc: '2.0', id, method: 'session/request_permission', params: value }),
  id => send({ jsonrpc: '2.0', method: 'woven/permission_cancel', params: { requestID: id } }));
let payload = {};
let instance;
let vault;
const pendingCredentials = new Map();
async function requestCredentials() {
  const id = 'credentials-' + crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => { pendingCredentials.delete(id); reject(new Error('Built-in credential connection timed out.')); }, 30000);
    pendingCredentials.set(id, { resolve: value => { clearTimeout(timeout); resolve(value); }, reject });
    send({ jsonrpc: '2.0', id, method: 'woven/credentials', params: {} });
  });
}
async function engine() {
  return instance ??= new DefaultAgentEngine({ cwd: process.cwd(), directory, config: payload.config, credentials: payload.credentials, credentialAccounts: payload.credentialAccounts, vault,
    requestCredentials: !remote && !control ? requestCredentials : undefined }).initialize();
}
async function remoteRequest(path, body, canUnlock = true) {
  const response = await fetch(`http://127.0.0.1:7337/v1/default-agent/${path}`, { method: body ? 'POST' : 'GET', headers: { Authorization: `Bearer ${process.env.WOVENMATTER_API_TOKEN}`, 'Content-Type': 'application/json' }, body: body ? JSON.stringify(body) : undefined, signal: AbortSignal.timeout(path === 'rpc' ? 24 * 60 * 60 * 1000 : 30000) });
  if (response.status === 423 && canUnlock && path !== 'configuration') {
    await remoteRequest('configuration', await requestCredentials(), false);
    return remoteRequest(path, body, false);
  }
  if (!response.ok) throw new Error(`Built-in workspace service failed (HTTP ${response.status}).`);
  return response.json();
}
async function invoke(message) {
  if (message.method === 'session/cancel') permissions.cancelSession(message.params?.sessionId);
  const update = value => send({ jsonrpc: '2.0', method: 'session/update', params: { sessionId: message.params?.sessionId, update: value } });
  if (control) {
    if (message.action === 'probe-server') {
      try { return await probeServer(message.url, message.key); }
      catch (error) { return { url: '', models: [], error: error.message }; }
    }
    payload = message;
    if (payload.unlockKey) {
      vault = new CredentialVault(directory);
      if (message.action === 'reset') await unlink(vault.path).catch(e => { if (e.code !== 'ENOENT') throw e; });
      await vault.unlock(payload.workspace, payload.unlockKey);
    }
    const e = await engine();
    if (message.action === 'claude-status') return e.claude.status(message.profile ?? (await e.credentials.read('claude-subscription'))?.accountId);
    if (message.action === 'reset') {
      await vault.modify(async stored => ({ ...stored, shared: sharedCredentials(payload.credentials) }));
      return { reset: true };
    }
    if (message.action === 'logout') {
      if (message.provider === 'claude-subscription') await e.claude.signOut(message.profile);
      else await e.credentials.delete(message.provider);
      return { disconnected: true };
    }
    if (message.action === 'login') {
      const controller = new AbortController();
      const abortLogin = () => controller.abort();
      process.stdin.once('end', abortLogin);
      process.once('SIGTERM', abortLogin);
      const loginTimeout = setTimeout(abortLogin, 10 * 60 * 1000);
      try {
      if (message.provider === 'claude-subscription') {
        const status = await inlineClaudeLogin(e.claude, message.profile, { signal: controller.signal, notify: notification => send({ notification }) });
        return { ...status, provider: message.provider, nativeProfile: message.profile };
      }
      e.credentials.signingIn = true;
      let credential = await e.runtime.login(message.provider, 'oauth', { signal: controller.signal,
        notify: notification => send({ notification }),
        prompt: prompt => {
          const preferred = preferredSignInAnswer(message.provider, prompt);
          if (preferred) return Promise.resolve(preferred);
          return new Promise((resolve, reject) => { const id = crypto.randomUUID(); pendingPrompts.set(id, resolve); send({ prompt: { ...prompt, signal: undefined }, id }); controller.signal.addEventListener('abort', () => reject(new Error('Sign-in cancelled.')), { once: true }); }); } }).finally(() => { e.credentials.signingIn = false; });
      // SDK login persists through the app-owned credential store.
      if (message.provider === 'xai' && credential) {
        const profile = await grokAccountProfile(credential);
        if (profile.displayName) credential = await e.credentials.modify(message.provider, current => ({ ...current, ...profile }));
      }
      return { ...(await e.status()), connected: Boolean(credential), ...(!vault ? { credential, provider: message.provider } : {}) };
      } finally { clearTimeout(loginTimeout); process.stdin.removeListener('end', abortLogin); process.removeListener('SIGTERM', abortLogin); }
    }
    if (message.action === 'sign-in-status') return { statuses: [...(await e.status()).providers.map(p => ({ ...p, name: 'Built-in · ' + p.name })), ...await signInStatuses(message.harnesses ?? [])] };
    if (message.action === 'refresh') {
      const errors = {};
      for (const provider of ['openai-codex', 'xai']) {
        const credential = await e.credentials.read(provider);
        if (credential?.type !== 'oauth' || credential.borrowed || credential.expires > Date.now() + 300000) continue;
        try { await e.runtime.getAuth(provider, { signal: AbortSignal.timeout(30000), allowWait: false }); }
        catch (error) { errors[provider] = /invalid_grant|revoked|\b401\b/.test(String(error)) ? 'sign_in_required' : 'check_failed'; }
      }
      return { credentials: { ...e.credentials.supplied, ...e.credentials.owned }, errors };
    }
    return e.status();
  }
  if (!remote) {
    if (message.method === 'woven/configure') {
      payload = message.params;
      const current = await engine();
      await current.apply(payload);
      const record = [...current.sessions.values()][0];
      return record ? current.configuration(record) : {};
    }
    return (await engine()).handle(message.method, message.params, update, requestPermission);
  }
  const response = await remoteRequest('rpc', { ...message, operationID: message.method === 'session/prompt' ? (message.params?._meta?.wovenRunID ?? crypto.randomUUID()) : undefined });
  if (!response.operationID) return response.result;
  let cursor = 0;
  const remotePermissions = new RemotePermissionRequests(requestPermission, (id, allowed) =>
    remoteRequest('rpc', { method: 'woven/permission', params: { id, result: { outcome: { outcome: 'selected', optionId: allowed ? 'allow' : 'deny' } } } }));
  try {
    while (true) {
      const page = await remoteRequest(`runs/${response.operationID}?after=${cursor}`);
      remotePermissions.update(page);
      for (const event of page.updates) {
        if (event.sessionUpdate !== 'woven_permission') update(event);
      }
      cursor = page.cursor;
      if (page.done) {
        if (response.loadingSessionID) return (await remoteRequest('rpc', { method: 'session/load', params: { sessionId: response.loadingSessionID } })).result;
        if (page.error) throw new DefaultAgentError(page.error);
        return page.result;
      }
      await new Promise(resolve => setTimeout(resolve, 150));
    }
  } finally { remotePermissions.close(); }
}
const pendingPrompts = new Map();
const lines = createInterface({ input: process.stdin });
lines.on('line', line => {
  let message;
  try { message = JSON.parse(line); } catch { return; }
  if (permissions.pending.has(message.id)) { permissions.resolve(message.id, message.result); return; }
  if (pendingCredentials.has(message.id)) {
    const pending = pendingCredentials.get(message.id); pendingCredentials.delete(message.id);
    if (message.error) pending.reject(new Error('Built-in credentials are unavailable.'));
    else pending.resolve(message.result);
    return;
  }
  if (message.answerTo) { pendingPrompts.get(message.answerTo)?.(message.answer); pendingPrompts.delete(message.answerTo); return; }
  invoke(message).then(result => {
    if (control) send({ result }, () => process.exit(0));
    else if (message.id !== undefined) send({ jsonrpc: '2.0', id: message.id, result });
  }, error => {
    const messageText = operationErrorMessage(error);
    if (control) send({ error: messageText }, () => process.exit(1));
    else if (message.id !== undefined) send({ jsonrpc: '2.0', id: message.id, error: { code: -32000, message: messageText } });
  });
});
lines.on('close', () => { if (!control) process.exit(0); });
