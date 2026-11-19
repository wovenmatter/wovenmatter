import { SignInStore } from './sign-in-store.mjs';
import { deviceConfig } from './device-sign-ins.mjs';
import { join } from 'node:path';
import { DefaultAgentError, canonicalHash, operationErrorMessage, providers as botProviders, readJSON, validateConfig, writePrivateJSON } from './config.mjs';
import { openNativeJournal } from './native-journal.mjs';
import { createInferenceAdapter } from './inference-adapter.mjs';

function requestFingerprint(message) {
  return canonicalHash({ method: message.method, params: message.params ?? {} });
}
function verifyRetry(stored, fingerprint) {
  if (stored.fingerprint !== fingerprint) throw new DefaultAgentError('This run identifier belongs to a different request. Send a new message.');
}

// Readers poll current process-owned operations. Durable owns native execution
// persistence; an accepted transport ID is never redispatched after restart.
export function createDefaultAgentService({ cwd, directory, engineFactory, writeState = writePrivateJSON, attachmentState }) {
  let enginePromise, inferenceAdapter;
  const vault = new SignInStore(directory), epoch = crypto.randomUUID();
  // This host's own sign-ins: its folder is always made private first.
  let deviceOpening;
  const openDevice = () => deviceOpening ??= vault.open().catch(error => { deviceOpening = undefined; throw error; });
  let configurationQueue = Promise.resolve(), generation = 0;
  const operations = new Map(), admissions = new Map(), admissionQueues = new Map();
  const attachmentTokens = new Map(attachmentState?.tokens);
  const cancellationRevisions = new Map(attachmentState?.cancellations);
  function admit(message, fingerprint) {
    if (!['session/load', 'woven/adopt', 'session/prompt', '_session/steering', 'session/set_config_option', 'woven/history', 'woven/recover'].includes(message.method)) return invokeOperation(message, fingerprint);
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
      await openDevice();
      const stored = await vault.read();
      const { DefaultAgentEngine } = await import('./engine.mjs');
      const value = await readJSON(join(directory, 'configuration.json'));
      return new DefaultAgentEngine({ cwd, directory, config: deviceConfig(value.config, stored), vault }).initialize();
    })().catch(error => { enginePromise = undefined; throw error; });
    return enginePromise;
  }
  function configure(value) {
    const pending = configurationQueue.then(async () => {
      // Only chat settings arrive from another device; this host keeps its own sign-ins.
      await openDevice();
      const config = validateConfig(value.config);
      await writePrivateJSON(join(directory, 'configuration.json'), { config });
      if (enginePromise) await (await enginePromise).apply({ config: deviceConfig(config, await vault.read()) });
      generation++;
      return { saved: true, revision: value.revision, epoch, generation };
    });
    configurationQueue = pending.catch(() => {});
    return pending;
  }
  // After another device changed this host's sign-ins (`sign-ins`): the
  // sign-ins file is read on use; local model servers are registered again.
  function reloadSignIns() {
    const pending = configurationQueue.then(async () => {
      if (!enginePromise) return { reloaded: false };
      const value = await readJSON(join(directory, 'configuration.json'));
      const current = await enginePromise;
      await current.apply({ config: deviceConfig(value.config ?? current.config, await vault.read()) });
      generation++;
      return { reloaded: true };
    });
    configurationQueue = pending.catch(() => {});
    return pending;
  }
  // This host renews its own subscriptions, used or not, before they expire.
  async function renewSignIns({ window = 5 * 60_000 } = {}) {
    await openDevice();
    const owned = (await vault.read()).owned ?? {};
    const due = ['openai-codex', 'xai'].filter(id => owned[id]?.type === 'oauth' && !owned[id].borrowed && !(owned[id].expires > Date.now() + window));
    if (!due.length) return { renewed: [] };
    const current = await engine(), renewed = [];
    for (const provider of due) {
      try { await current.runtime.getAuth(provider, { signal: AbortSignal.timeout(30_000), allowWait: false }); renewed.push(provider); }
      catch { /* Renewal retries on the next check; an expired sign-in is reported as such. */ }
    }
    return { renewed };
  }
  async function inferenceCatalog(options) {
    inferenceAdapter ??= createInferenceAdapter(await engine());
    return inferenceAdapter.catalog(options);
  }
  async function inferenceStream(request, options) {
    inferenceAdapter ??= createInferenceAdapter(await engine());
    return inferenceAdapter.stream(request, options);
  }
  // Bots' agent loops run in the host's bots runtime, never in containers.
  // Like local SDK helpers they receive access-only credentials: refresh
  // tokens stay in this store. A Claude subscription is the machine's native
  // Claude runtime directories, never token material. `null`: not connected.
  async function botCredentials({ provider } = {}) {
    const search = ['exa', 'brave', 'firecrawl'];
    if (typeof provider !== 'string' || ![...botProviders, ...search, 'web-search'].includes(provider)) throw Object.assign(new DefaultAgentError('Choose a Woven provider connection.'), { statusCode: 400 });
    const current = await engine();
    if (provider === 'web-search' || search.includes(provider)) {
      const selected = provider === 'web-search' ? current.config.searchProvider ?? 'exa' : provider;
      const key = (await current.credentials.read(selected))?.key;
      return { credential: typeof key === 'string' && key ? { type: 'api_key', key } : null, ...(provider === 'web-search' ? { searchProvider: selected } : {}) };
    }
    if (provider === 'claude-subscription') {
      const profile = (await current.credentials.read('claude-subscription'))?.accountId;
      if (!(await current.claude.status(profile)).connected) return { credential: null };
      const environment = await current.claude.environment(undefined, profile);
      return { credential: { type: 'native', configDir: environment.CLAUDE_CONFIG_DIR, secureStorageDir: environment.CLAUDE_SECURESTORAGE_CONFIG_DIR } };
    }
    let credential = (await current.credentials.candidates(provider)).find(value => value.credential)?.credential;
    // A device's own subscription is renewed here before bots are refused it.
    if (credential?.type === 'oauth' && !credential.borrowed && !(credential.expires > Date.now() + 60_000)) {
      try { await current.runtime.getAuth(provider, { signal: AbortSignal.timeout(30_000), allowWait: false }); } catch { /* Answer with what is stored. */ }
      credential = (await current.credentials.candidates(provider)).find(value => value.credential)?.credential;
    }
    if (credential?.type === 'api_key' && typeof credential.key === 'string') return { credential: { type: 'api_key', key: credential.key } };
    if (credential?.type === 'oauth' && typeof credential.access === 'string' && credential.expires > Date.now()) {
      return { credential: { type: 'oauth', access: credential.access, expires: credential.expires, ...(typeof credential.accountId === 'string' ? { accountId: credential.accountId } : {}) } };
    }
    return { credential: null };
  }
  async function status() {
    return { ...(await (await engine()).status()), epoch };
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
    if (['session/prompt', '_session/steering', 'session/load', 'woven/adopt', 'session/cancel', 'session/set_config_option', 'woven/history', 'woven/idle', 'woven/recover'].includes(message.method)
      && (attachmentTokens.has(sessionID) || message.attachmentToken)) {
      const freshLoad = ['session/load','woven/adopt'].includes(message.method) && message.attachmentTokens === true && !message.attachmentToken;
      if (!freshLoad && message.attachmentToken !== attachmentTokens.get(sessionID)) throw new DefaultAgentError('This session attachment was replaced. Reconnect before sending another message.');
    }
    if (message.method === 'session/cancel') cancellationRevisions.set(sessionID, (cancellationRevisions.get(sessionID) ?? 0) + 1);
    if (message.method !== 'session/prompt') {
      const result = await e.handle(message.method, message.params);
      if (['session/new', 'session/load', 'woven/adopt'].includes(message.method) && message.attachmentTokens === true) {
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
    await inferenceAdapter?.cancelAll();
    const running = [...operations.values()].filter(operation => !operation.done), current = enginePromise ? await enginePromise : null;
    const sessions = new Set([...running.map(operation => operation.sessionID), ...admissionQueues.keys(), ...(current?.sessions?.keys() ?? [])]);
    await Promise.all([...sessions].map(cancelSession));
    await Promise.allSettled(running.map(operation => operation.completion));
  }
  let inFlight = 0, retiring = false;
  const tracked = fn => async (...args) => {
    if (retiring) throw new DefaultAgentError('The Pi Durable runtime is updating. Retry after it finishes.');
    inFlight++;
    try { return await fn(...args); } finally { inFlight--; }
  };
  async function prepareRetirement() {
    if (inFlight || inferenceAdapter?.activeCount || admissions.size || admissionQueues.size || [...operations.values()].some(operation => !operation.done)) return false;
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
  async function inspection() {
    if (!enginePromise) return [];
    const current = await enginePromise;
    const { BACKGROUND_CONTEXT } = await import('@earendil-works/chord/context');
    const items = [];
    for (const record of current.sessions.values()) {
      if (items.length >= 1000) break;
      const nativeSessionID = record.session.sessionId;
      const id = `native:${nativeSessionID}`;
      items.push({id, parentID:'pi-worker', nativeSessionID, kind:'conversation', title:'Pi Durable session',
        state:record.busy?'working':'idle', detail:record.selected});
      if (!record.harness) continue;
      const view = await record.harness.inspect(BACKGROUND_CONTEXT);
      for (const task of view.tasks.slice(0,200)) items.push({id:`${id}:task:${task.record.id}`,parentID:id,nativeSessionID,
        kind:task.record.kind.includes('subagent')?'subagent':'task',title:task.record.kind.includes('subagent')?'Subagent':'Agent task',state:task.state.kind});
    }
    return items.slice(0,1000);
  }
  return { engine, inspection, reloadSignIns: tracked(reloadSignIns), renewSignIns: tracked(renewSignIns), inferenceCatalog: tracked(inferenceCatalog), inferenceStream: tracked(inferenceStream), botCredentials: tracked(botCredentials), configure: tracked(configure), invoke: tracked(invoke), poll: tracked(poll), status: tracked(status), cancelActive: tracked(cancelActive), cancelSession: tracked(cancelSession), prepareRetirement };
}
