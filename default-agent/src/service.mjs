import { createHash } from 'node:crypto';
import { CredentialVault, sharedCredentials, sharedAccounts } from './vault.mjs';
import { join } from 'node:path';
import { DefaultAgentError, operationErrorMessage, readJSON, validateConfig, writePrivateJSON } from './config.mjs';
import { openNativeJournal } from './native-journal.mjs';

function requestFingerprint(message) {
  const ordered = value => Array.isArray(value) ? value.map(ordered)
    : value && typeof value === 'object'
      ? Object.fromEntries(Object.keys(value).sort().map(key => [key, ordered(value[key])])) : value;
  return createHash('sha256').update(JSON.stringify(ordered({ method: message.method, params: message.params ?? {} }))).digest('hex');
}
function verifyRetry(stored, fingerprint) {
  if (stored.fingerprint !== fingerprint) throw new DefaultAgentError('This run identifier belongs to a different request. Send a new message.');
}

// Readers poll current process-owned operations. Durable owns native execution
// persistence; an accepted transport ID is never redispatched after restart.
export function createDefaultAgentService({ cwd, directory, engineFactory, writeState = writePrivateJSON, attachmentState }) {
  let enginePromise;
  const vault = new CredentialVault(directory), epoch = crypto.randomUUID();
  let configurationQueue = Promise.resolve(), generation = 0;
  const operations = new Map(), admissions = new Map(), admissionQueues = new Map();
  const attachmentTokens = new Map(attachmentState?.tokens);
  const cancellationRevisions = new Map(attachmentState?.cancellations);
  function admit(message, fingerprint) {
    if (!['session/load', 'session/prompt', '_session/steering', 'session/set_config_option', 'woven/history'].includes(message.method)) return invokeOperation(message, fingerprint);
    const sessionID = message.params?.sessionId, cancellationRevision = cancellationRevisions.get(sessionID) ?? 0;
    const pending = (admissionQueues.get(sessionID) ?? Promise.resolve()).then(() => invokeOperation(message, fingerprint, cancellationRevision));
    const tail = pending.catch(() => {});
    admissionQueues.set(sessionID, tail);
    void tail.then(() => { if (admissionQueues.get(sessionID) === tail) admissionQueues.delete(sessionID); });
    return pending;
  }
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
      if (enginePromise) await (await enginePromise).apply({ config });
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
    const fingerprint = requestFingerprint(message), existing = admissions.get(id);
    if (existing) { verifyRetry(existing, fingerprint); return existing.pending; }
    const pending = admit(message, fingerprint).finally(() => admissions.delete(id));
    admissions.set(id, { fingerprint, pending });
    return pending;
  }
  async function invokeOperation(message, fingerprint = requestFingerprint(message), cancellationRevision) {
    const e = await engine(), sessionID = message.params?.sessionId;
    if (['session/prompt', '_session/steering', 'session/load', 'session/cancel', 'session/set_config_option', 'woven/history', 'woven/idle'].includes(message.method)
      && (attachmentTokens.has(sessionID) || message.attachmentToken)) {
      const freshLoad = message.method === 'session/load' && message.attachmentProtocol === 1 && !message.attachmentToken;
      if (!freshLoad && message.attachmentToken !== attachmentTokens.get(sessionID)) throw new DefaultAgentError('This session attachment was replaced. Reconnect before sending another message.');
    }
    if (message.method === 'session/cancel') cancellationRevisions.set(sessionID, (cancellationRevisions.get(sessionID) ?? 0) + 1);
    if (message.method !== 'session/prompt') {
      const result = await e.handle(message.method, message.params);
      if (['session/new', 'session/load'].includes(message.method) && message.attachmentProtocol === 1) {
        const token = crypto.randomUUID();
        attachmentTokens.set(result.sessionId, token);
        result._meta = { ...result._meta, attachmentToken: token };
      }
      return { result };
    }
    const id = message.operationID ?? crypto.randomUUID();
    if (!/^[0-9a-f-]{36}$/i.test(id)) throw new DefaultAgentError('Invalid operation identifier.');
    const existing = operations.get(id);
    if (existing) { verifyRetry(existing, fingerprint); return { operationID: id }; }
    const accepted = await readJSON(join(directory, `accepted-${id}.json`), null);
    if (accepted) {
      verifyRetry(accepted, fingerprint);
      throw new DefaultAgentError('This request was already accepted by a prior workspace process. Its delivery outcome is uncertain; it will not be replayed.');
    }
    const journalStore = await openNativeJournal(join(directory, `run-${epoch}-${id}.jsonl`));
    const operation = { fingerprint, journalStore, journalQueue: Promise.resolve(), done: false, result: null, error: null, sessionID };
    // A fingerprint-only tombstone fences uncertain external effects. It holds
    // no prompt, credential, copied configuration or custom recovery payload.
    await writeState(join(directory, `accepted-${id}.json`), { fingerprint });
    if (cancellationRevision !== (cancellationRevisions.get(sessionID) ?? 0)) throw new DefaultAgentError('The run was stopped before native dispatch. Send a new message to retry.');
    operations.set(id, operation);
    const params = { ...message.params, _meta: { ...message.params?._meta, wovenInputID: message.params?._meta?.wovenInputID ?? id, wovenRunID: message.params?._meta?.wovenRunID ?? id } };
    let journalError;
    const publish = update => {
      operation.journalQueue = operation.journalQueue.then(() => journalStore.append([update])).catch(error => { journalError = error; });
      return operation.journalQueue;
    };
    operation.completion = e.handle(message.method, params, publish).then(result => { operation.result = result; }, error => { operation.error = operationErrorMessage(error); }).finally(async () => {
      await operation.journalQueue;
      if (journalError) operation.error = 'The workspace could not save the run updates.';
      operation.done = true;
    });
    return { operationID: id };
  }
  async function poll(id, after = 0) {
    if (!/^[0-9a-f-]{36}$/i.test(id) || !Number.isSafeInteger(after) || after < 0) throw new DefaultAgentError('Invalid operation cursor.');
    const operation = operations.get(id);
    if (!operation) throw new DefaultAgentError('This operation is no longer available in the workspace process. It will not be replayed.');
    await operation.journalQueue;
    const page = await operation.journalStore.page(after, 200);
    return { ...page, done: operation.done && !page.hasMore, result: operation.result, error: operation.error };
  }
  async function cancelSession(sessionID) {
    cancellationRevisions.set(sessionID, (cancellationRevisions.get(sessionID) ?? 0) + 1);
    return (await engine()).handle('session/cancel', { sessionId: sessionID });
  }
  async function cancelActive() {
    const running = [...operations.values()].filter(operation => !operation.done), current = enginePromise ? await enginePromise : null;
    const sessions = new Set([...running.map(operation => operation.sessionID), ...admissionQueues.keys(), ...(current?.sessions?.keys() ?? [])]);
    await Promise.all([...sessions].map(cancelSession));
    await Promise.allSettled(running.map(operation => operation.completion));
  }
  let inFlight = 0, retiring = false;
  const tracked = fn => async (...args) => {
    if (retiring) throw new DefaultAgentError('The Built-in runtime is updating. Retry after it finishes.');
    inFlight++;
    try { return await fn(...args); } finally { inFlight--; }
  };
  async function prepareRetirement() {
    if (inFlight || admissions.size || admissionQueues.size || [...operations.values()].some(operation => !operation.done)) return false;
    retiring = true;
    try {
      if (enginePromise) {
        const current = await enginePromise;
        for (const record of current.sessions?.values() ?? []) {
          await record.configurationQueue;
          if (record.harness) {
            const native = await record.harness.inspect((await import('@earendil-works/chord/context')).BACKGROUND_CONTEXT);
            if (native.tasks.length || native.submissions.length) { retiring = false; return false; }
          }
        }
        for (const record of [...(current.sessions?.values() ?? [])]) await record.session.dispose?.();
      }
      return { attachmentState: { tokens: [...attachmentTokens], cancellations: [...cancellationRevisions] } };
    } catch (error) {
      retiring = false;
      throw error;
    }
  }
  return { engine, configure: tracked(configure), invoke: tracked(invoke), poll: tracked(poll), status: tracked(status), cancelActive: tracked(cancelActive), cancelSession: tracked(cancelSession), prepareRetirement };
}
