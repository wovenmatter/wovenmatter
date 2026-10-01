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
export function createDefaultAgentService({ cwd, directory, engineFactory, writeState = writePrivateJSON, attachmentState }) {
  let enginePromise;
  const vault = new CredentialVault(directory);
  const epoch = crypto.randomUUID();
  let configurationQueue = Promise.resolve();
  let generation = 0;
  let lastPromptStartedAt = 0;
  const operations = new Map();
  const admissions = new Map();
  const attachmentTokens = new Map(attachmentState?.tokens);
  const admissionQueues = new Map();
  const cancellationRevisions = new Map(attachmentState?.cancellations);
  function admit(message, fingerprint) {
    if (!['session/load', 'session/prompt', '_session/steering', 'session/set_config_option'].includes(message.method)) return invokeOperation(message, fingerprint);
    const sessionID = message.params?.sessionId;
    const cancellationRevision = cancellationRevisions.get(sessionID) ?? 0;
    // Only setup is serialized, separately for each native session. Prompt
    // execution is operation.completion below and is never awaited here.
    const pending = (admissionQueues.get(sessionID) ?? Promise.resolve()).then(() => invokeOperation(message, fingerprint, cancellationRevision));
    const tail = pending.catch(() => {});
    admissionQueues.set(sessionID, tail);
    void tail.then(() => { if (admissionQueues.get(sessionID) === tail) admissionQueues.delete(sessionID); });
    return pending;
  }
  const permissions = new PermissionRequests();
  async function engine() {
    if (!enginePromise) enginePromise = (async () => {
      if (engineFactory) return engineFactory();
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
    if (message.method !== 'session/prompt' || !id) return admit(message);
    const fingerprint = requestFingerprint(message);
    const existing = admissions.get(id);
    if (existing) {
      verifyRetry(existing, fingerprint);
      return existing.pending;
    }
    const pending = admit(message, fingerprint).finally(() => admissions.delete(id));
    admissions.set(id, { fingerprint, pending });
    return pending;
  }
  async function invokeOperation(message, fingerprint = requestFingerprint(message), cancellationRevision) {
    if (message.method === 'woven/permission') {
      const request = permissions.pending.get(message.params?.id);
      if (!request) return { result: {} };
      const sessionID = request.params.sessionId;
      if (message.params?.sessionId !== undefined && message.params.sessionId !== sessionID) {
        throw new DefaultAgentError('This approval belongs to another session.');
      }
      if ((attachmentTokens.has(sessionID) || message.attachmentToken)
        && message.attachmentToken !== attachmentTokens.get(sessionID)) {
        throw new DefaultAgentError('This session attachment was replaced. Reconnect before answering its approval.');
      }
      if (!sessionID && attachmentTokens.size > 0) throw new DefaultAgentError('Reconnect before answering this approval.');
      permissions.resolve(message.params?.id, message.params?.result);
      return { result: {} };
    }
    const e = await engine();
    const sessionID = message.params?.sessionId;
    if (['session/prompt', '_session/steering', 'session/load', 'session/cancel', 'session/set_config_option'].includes(message.method)
      && (attachmentTokens.has(sessionID) || message.attachmentToken)) {
      const freshLoad = message.method === 'session/load' && message.attachmentProtocol === 1 && !message.attachmentToken;
      if (!freshLoad && message.attachmentToken !== attachmentTokens.get(sessionID)) {
        throw new DefaultAgentError('This session attachment was replaced. Reconnect before sending another message.');
      }
    }
    if (message.method === 'session/load' && message.attachmentProtocol === 1 && !message.attachmentToken) {
      attachmentTokens.set(sessionID, crypto.randomUUID());
    }
    if (message.method === 'session/cancel') {
      cancellationRevisions.set(sessionID, (cancellationRevisions.get(sessionID) ?? 0) + 1);
    }
    if (message.method !== 'session/prompt') {
      const result = await e.handle(message.method, message.params);
      if (message.method === 'session/new' && message.attachmentProtocol === 1) {
        attachmentTokens.set(result.sessionId, crypto.randomUUID());
        result._meta = { ...result._meta, attachmentToken: attachmentTokens.get(result.sessionId) };
      }
      if (message.method === 'session/load') {
        // Reattach to work still running in this workspace; never submit it again.
        for (const [id, operation] of operations) {
          if (operation.sessionID === message.params.sessionId && !operation.done) return { operationID: id, loadingSessionID: operation.sessionID, attachmentToken: attachmentTokens.get(sessionID) };
        }
        const savedRuns = [];
        for (const file of (await readdir(directory)).filter(f => /^run-[0-9a-f-]+\.json$/.test(f))) {
          const saved = await readJSON(join(directory, file));
          if (saved.sessionID === message.params.sessionId && saved.snapshot) savedRuns.push(saved);
        }
        const byRun = new Map();
        for (const saved of savedRuns.sort((a, b) => (a.startedAt ?? 0) - (b.startedAt ?? 0))) {
          const snapshot = saved.snapshot, previous = byRun.get(snapshot.runID);
          byRun.set(snapshot.runID, { ...snapshot, content: (previous?.content ?? '') + snapshot.content });
        }
        const recoveredRuns = [...byRun.values()];
        const record = await e.create(message.params.sessionId);
        Object.assign(result, e.configuration(record));
        result._meta = { ...result._meta, recoveredRuns,
          ...(message.attachmentProtocol === 1 ? { attachmentToken: attachmentTokens.get(sessionID), recoveryComplete: true, recoverySessionID: sessionID } : {}) };
      }
      return { result };
    }
    const id = message.operationID ?? crypto.randomUUID();
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error('Invalid operation identifier.');
    const existing = operations.get(id) ?? await readJSON(join(directory, `run-${id}.json`), null);
    if (existing) { verifyRetry(existing, fingerprint); return { operationID: id }; }
    if (await readJSON(join(directory, `accepted-${id}.json`), null)) throw new Error('This run was interrupted by a workspace restart. Submit a new message to retry.');
    lastPromptStartedAt = Math.max(Date.now(), lastPromptStartedAt + 1);
    const operation = { fingerprint, startedAt: lastPromptStartedAt, updates: [], done: false, result: null, error: null, sessionID: message.params.sessionId };
    await writeState(join(directory, `accepted-${id}.json`), { sessionID: operation.sessionID, fingerprint });
    if (cancellationRevision !== (cancellationRevisions.get(sessionID) ?? 0)) {
      throw new DefaultAgentError('The run was stopped before native dispatch. Send a new message to retry.');
    }
    operations.set(id, operation);
    const path = join(directory, `run-${id}.jsonl`);
    let journal = Promise.resolve();
    let journalError;
    const publish = update => { operation.updates.push(update); journal = journal.then(() => appendFile(path, JSON.stringify(update) + '\n', { mode: 0o600 })).catch(error => { journalError = error; }); };
    // Intentionally not awaited by the HTTP request.
    operation.completion = e.handle(message.method, message.params, publish, (params, signal) => permissions.request({ ...params, sessionId: operation.sessionID }, signal,
      (id, value) => publish({ sessionUpdate: 'woven_permission', id, params: value }))).then(result => { operation.result = result; }, error => { operation.error = operationErrorMessage(error); }).finally(async () => {
      try {
        await journal;
        if (journalError) throw journalError;
        // Persist streamed output before publishing its completion receipt.
        const file = await open(path, 'a', 0o600);
        try { await file.sync(); } finally { await file.close(); }
        const record = e.sessions.get(operation.sessionID);
        const snapshot = { runID: message.params?._meta?.wovenRunID ?? id, content: operation.updates.filter(u => u.sessionUpdate === 'agent_message_chunk').map(u => u.content.text).join(''), error: operation.error, model: record?.selected };
        await writePrivateJSON(join(directory, `run-${id}.json`), { sessionID: operation.sessionID, startedAt: operation.startedAt, fingerprint, snapshot, result: operation.result, error: operation.error });
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
    const sessions = new Set([...running.map(operation => operation.sessionID), ...admissionQueues.keys()]);
    await Promise.all([...sessions].map(cancelSession));
    await Promise.allSettled(running.map(operation => operation.completion));
  }
  // Trusted service lifecycle calls are separate from attachment-owned RPCs.
  async function cancelSession(sessionID) {
    cancellationRevisions.set(sessionID, (cancellationRevisions.get(sessionID) ?? 0) + 1);
    return (await engine()).handle('session/cancel', { sessionId: sessionID });
  }
  let inFlight = 0, retiring = false;
  const tracked = fn => async (...args) => {
    if (retiring) throw new DefaultAgentError('The Built-in runtime is updating. Retry after it finishes.');
    inFlight++;
    try { return await fn(...args); } finally { inFlight--; }
  };
  // The proxy serializes admission while asking this question. Once retired,
  // this generation cannot admit another prompt while the replacement starts.
  function prepareRetirement() {
    if (inFlight || admissions.size || admissionQueues.size || permissions.pending.size || [...operations.values()].some(operation => !operation.done)) return false;
    retiring = true;
    // Transfer ownership only after all calls and admissions have settled. The
    // private worker channel preserves replaced-attachment fences across an SDK
    // switch without writing bearer tokens into workspace files.
    return { attachmentState: { tokens: [...attachmentTokens], cancellations: [...cancellationRevisions] } };
  }
  return { engine, configure: tracked(configure), invoke: tracked(invoke), poll: tracked(poll), status: tracked(status), cancelActive: tracked(cancelActive), cancelSession: tracked(cancelSession), prepareRetirement };


}
