import { createHash } from 'node:crypto';
import { CredentialVault, sharedCredentials, sharedAccounts } from './vault.mjs';
import { join } from 'node:path';
import { appendFile, open, readFile, readdir } from 'node:fs/promises';
import { DefaultAgentError, operationErrorMessage, readJSON, validateConfig, writePrivateJSON } from './config.mjs';
import { PermissionRequests } from './permissions.mjs';

// Object-key order does not change a retry's identity. Store only the digest,
// not a second copy of the prompt or configuration.
function requestFingerprint(message) {
  const ordered = value => Array.isArray(value) ? value.map(ordered)
    : value && typeof value === 'object'
      ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
  return createHash('sha256').update(JSON.stringify(ordered({ method: message.method, params: message.params ?? {} }))).digest('hex');
}
function verifyRetry(stored, fingerprint) {
  if (stored.fingerprint !== fingerprint) throw new DefaultAgentError('This run identifier belongs to a different request. Reconnect to the original run or send a new message.');
}

// Owned by the workspace service. Requests only attach to runs; disconnecting a
// reader never cancels the SDK session. Journals support replay after reconnect.
export function createDefaultAgentService({ cwd, directory }) {
  let enginePromise;
  const vault = new CredentialVault(directory);
  const epoch = crypto.randomUUID();
  let configurationQueue = Promise.resolve();
  let generation = 0;
  const operations = new Map();
  const admissions = new Map();
  const permissions = new PermissionRequests();
  async function engine() {
    if (!enginePromise) enginePromise = (async () => {
      await vault.read();
      const { DefaultAgentEngine } = await import('./engine.mjs');
      const value = await readJSON(join(directory, 'configuration.json'));
      return new DefaultAgentEngine({ cwd, directory, config: value.config, vault }).initialize();
    })().catch(error => { enginePromise = undefined; throw error; });
    return enginePromise;
  }
  function configure(value) {
    const pending = configurationQueue.then(async () => {
      await vault.unlock(value.workspace, value.unlockKey);
      await vault.modify(async stored => ({ ...stored, shared: sharedCredentials(value.credentials), accounts: sharedAccounts(value.credentialAccounts), revision: value.revision }));
      const config = validateConfig(value.config);
      await writePrivateJSON(join(directory, 'configuration.json'), { config });
      const current = enginePromise ? await enginePromise : null;
      if (current) await current.apply({ config });
      generation++;
      return { saved: true, revision: value.revision, epoch, generation };
    });
    configurationQueue = pending.catch(() => {});
    return pending;
  }
  async function status() {
    if (!vault.unlocked) return { locked: true, providers: [], models: [], searchConfigured: false };
    return { ...(await (await engine()).status()), locked: false, epoch };
  }
  async function invoke(message) {
    const id = message.operationID;
    if (message.method !== 'session/prompt' || !id) return invokeOperation(message);
    const fingerprint = requestFingerprint(message);
    const existing = admissions.get(id);
    if (existing) {
      verifyRetry(existing, fingerprint);
      return existing.pending;
    }
    const pending = invokeOperation(message, fingerprint).finally(() => admissions.delete(id));
    admissions.set(id, { fingerprint, pending });
    return pending;
  }
  async function invokeOperation(message, fingerprint = requestFingerprint(message)) {
    if (message.method === 'woven/permission') {
      permissions.resolve(message.params?.id, message.params?.result);
      return { result: {} };
    }
    const e = await engine();
    if (message.method !== 'session/prompt') {
      const result = await e.handle(message.method, message.params);
      if (message.method === 'session/load') {
        // Reattach to work still running in this workspace; never submit it again.
        for (const [id, operation] of operations) {
          if (operation.sessionID === message.params.sessionId && !operation.done) return { operationID: id, loadingSessionID: operation.sessionID };
        }
        const recoveredRuns = [];
        for (const file of (await readdir(directory)).filter(f => /^run-[0-9a-f-]+\.json$/.test(f))) {
          const saved = await readJSON(join(directory, file));
          if (saved.sessionID === message.params.sessionId && saved.snapshot) recoveredRuns.push(saved.snapshot);
        }
        const record = await e.create(message.params.sessionId);
        Object.assign(result, e.configuration(record));
        result._meta = { ...result._meta, recoveredRuns };
      }
      return { result };
    }
    const id = message.operationID ?? crypto.randomUUID();
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error('Invalid operation identifier.');
    const existing = operations.get(id) ?? await readJSON(join(directory, `run-${id}.json`), null);
    if (existing) { verifyRetry(existing, fingerprint); return { operationID: id }; }
    if (await readJSON(join(directory, `accepted-${id}.json`), null)) throw new Error('This run was interrupted by a workspace restart. Submit a new message to retry.');
    const operation = { fingerprint, updates: [], done: false, result: null, error: null, sessionID: message.params.sessionId };
    await writePrivateJSON(join(directory, `accepted-${id}.json`), { sessionID: operation.sessionID, fingerprint });
    operations.set(id, operation);
    const path = join(directory, `run-${id}.jsonl`);
    let journal = Promise.resolve();
    let journalError;
    const publish = update => { operation.updates.push(update); journal = journal.then(() => appendFile(path, JSON.stringify(update) + '\n', { mode: 0o600 })).catch(error => { journalError = error; }); };
    // Intentionally not awaited by the HTTP request.
    operation.completion = e.handle(message.method, message.params, publish, (params, signal) => permissions.request(params, signal,
      (id, value) => publish({ sessionUpdate: 'woven_permission', id, params: value }))).then(result => { operation.result = result; }, error => { operation.error = operationErrorMessage(error); }).finally(async () => {
      try {
        await journal;
        if (journalError) throw journalError;
        // Persist streamed output before publishing its completion receipt.
        const file = await open(path, 'a', 0o600);
        try { await file.sync(); } finally { await file.close(); }
        const record = e.sessions.get(operation.sessionID);
        const snapshot = { runID: message.params?._meta?.wovenRunID ?? id, content: operation.updates.filter(u => u.sessionUpdate === 'agent_message_chunk').map(u => u.content.text).join(''), error: operation.error, model: record?.selected };
        await writePrivateJSON(join(directory, `run-${id}.json`), { sessionID: operation.sessionID, fingerprint, snapshot, result: operation.result, error: operation.error });
        operations.delete(id);
      }
      catch { operation.error = 'The workspace could not save the completed run.'; }
      operation.done = true;
    });
    return { operationID: id };
  }
  async function poll(id, after = 0) {
    if (!/^[0-9a-f-]{36}$/i.test(id) || !Number.isSafeInteger(after) || after < 0) throw new Error('Invalid operation cursor.');
    const operation = operations.get(id);
    if (operation) return { updates: operation.updates.slice(after, after + 200), pendingPermissions: [...permissions.pending.keys()], cursor: Math.min(operation.updates.length, after + 200), done: operation.done && after + 200 >= operation.updates.length, result: operation.result, error: operation.error };
    const completion = await readJSON(join(directory, `run-${id}.json`), null);
    if (!completion) throw new Error('This run was interrupted when the workspace service stopped.');
    let updates = []; try { updates = (await readFile(join(directory, `run-${id}.jsonl`), 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse); } catch (error) { if (error.code !== 'ENOENT') throw error; }
    return { updates: updates.slice(after, after + 200), pendingPermissions: [], cursor: Math.min(updates.length, after + 200), done: after + 200 >= updates.length, ...completion };
  }
  async function cancelActive() {
    const running = [...operations.values()].filter(operation => !operation.done);
    if (!running.length) return;
    const e = await engine();
    await Promise.all(running.map(operation => e.handle('session/cancel', { sessionId: operation.sessionID })));
    await Promise.allSettled(running.map(operation => operation.completion));
  }
  return { engine, configure, invoke, poll, status, cancelActive };
}
