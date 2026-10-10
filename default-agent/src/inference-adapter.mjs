import { createHash } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { DefaultAgentError, accessFailure, operationErrorMessage, readJSON, writePrivateJSON } from './config.mjs';
import { credentialRouteIdentity } from './native-context.mjs';

const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object'
  ? Object.fromEntries(Object.keys(value).sort().map(key => [key, canonical(value[key])])) : value;
const hash = value => createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
const validID = value => typeof value === 'string' && value.length > 0 && value.length <= 512;
const allowedOptions = ['maxTokens', 'temperature', 'reasoning', 'cacheRetention'];
const events = new Set(['start', 'text_start', 'text_delta', 'text_end', 'thinking_start', 'thinking_delta', 'thinking_end', 'toolcall_start', 'toolcall_delta', 'toolcall_end', 'done', 'error']);
const cleanMessage = message => {
  if (!message || typeof message !== 'object') return message;
  const result = Object.fromEntries(Object.entries(message).filter(([key]) => !key.startsWith('wovenNative')));
  if (['error', 'aborted'].includes(result.stopReason)) result.errorMessage = result.stopReason === 'aborted' ? 'Cancelled.' : accessFailure(result.errorMessage) ?? operationErrorMessage(undefined);
  return result;
};
function cleanEvent(event) {
  if (!events.has(event?.type)) throw new DefaultAgentError('The inference provider returned an unsupported event.');
  const value = { ...event };
  for (const key of ['partial', 'message', 'error']) if (value[key]) value[key] = cleanMessage(value[key]);
  return value;
}

/** Model inference only: this service never instantiates an agent/session or invokes a tool. */
export function createInferenceAdapter(engine) {
  const active = new Map();
  const root = join(engine.directory, 'client-inference');
  async function catalog({ provider, signal } = {}) {
    if (provider && engine.browse) await engine.browse(provider, { signal });
    const models = engine.runtime.getModels().filter(model => engine.config.providers.includes(model.provider) && (!provider || model.provider === provider));
    const accounts = [];
    for (const provider of new Set(models.map(model => model.provider))) {
      for (const account of await engine.credentials.candidates(provider)) {
        const credential = account.credential;
        accounts.push({ provider, id: account.id, label: account.label ?? account.id,
          connected: Boolean(credential) && (credential.type !== 'oauth' || credential.expires > Date.now()) });
      }
    }
    // Descriptors contain static model routing/capabilities only; credentials remain in their owner store.
    return { models: models.map(model => ({ ...model })), accounts };
  }
  async function stream(request, { signal, onEvent, principalID } = {}) {
    signal?.throwIfAborted();
    if (!validID(principalID) || !validID(request?.scope?.conversationID) || !validID(request?.scope?.requestID)
      || !validID(request?.accountID) || !Array.isArray(request?.context?.messages)
      || Buffer.byteLength(JSON.stringify(request)) > 8 * 1024 * 1024) throw new DefaultAgentError('Invalid client inference request.');
    const conversationKey = hash({ principalID, conversation: request.scope.conversationID });
    const reference = `${request.model?.provider}/${request.model?.id}`;
    // An explicit model switch is allowed between turns. Retain each selection
    // independently so returning to it or replaying a receipt needs no catalog.
    const modelPath = join(root, conversationKey, `selected-model-${hash(reference)}.json`);
    let savedModel = await readJSON(modelPath, null);
    if (!savedModel) {
      const previous = await readJSON(join(root, conversationKey, 'selected-model.json'), null);
      if (previous && `${previous.provider}/${previous.id}` === reference) savedModel = previous;
    }
    const model = engine.ensureModel ? await engine.ensureModel(reference, savedModel) : engine.runtime.getModels().find(model => model.id === request.model?.id && model.provider === request.model?.provider);
    if (!model || !engine.config.providers.includes(model.provider)) throw new DefaultAgentError('The selected model is unavailable. No model fallback was attempted.');
    if (!savedModel) await writePrivateJSON(modelPath, model);
    const account = (await engine.credentials.candidates(model.provider)).find(account => account.id === request.accountID);
    if (!account?.credential) throw new DefaultAgentError('The selected account is unavailable. No account fallback was attempted.');
    if (account.credential.type === 'oauth' && account.credential.borrowed && account.credential.expires <= Date.now()) throw new DefaultAgentError('The selected subscription access has expired. Reconnect its credential owner or sign in on this inference host. No account fallback was attempted.');
    const requestKey = hash({ principalID, requestID: request.scope.requestID });
    const credentialIdentity = credentialRouteIdentity({ manifest: { storeID: conversationKey } }, account);
    const fingerprint = hash({ provider: model.provider, model: model.id, account: account.id, credentialIdentity,
      context: request.context, options: request.options, conversation: conversationKey });
    const directory = join(root, conversationKey), receiptPath = join(directory, requestKey + '.json');
    const existing = active.get(requestKey);
    if (existing) {
      if (existing.fingerprint !== fingerprint) throw new DefaultAgentError('This inference request identifier belongs to different input.');
      await existing.completion;
      return replay(await readJSON(receiptPath, null), fingerprint, onEvent, signal);
    }
    let resolve, reject;
    const completion = new Promise((yes, no) => { resolve = yes; reject = no; });
    completion.catch(() => {});
    const controller = new AbortController(), abort = () => controller.abort();
    signal?.addEventListener('abort', abort, { once: true });
    if (signal?.aborted) controller.abort();
    active.set(requestKey, { fingerprint, completion, controller });
    try {
      const saved = await readJSON(receiptPath, null);
      if (saved) { await replay(saved, fingerprint, onEvent, signal); resolve(); return; }
      await mkdir(directory, { recursive: true, mode: 0o700 });
      await writePrivateJSON(receiptPath, { fingerprint, state: 'accepted' });
      const context = structuredClone(request.context);
      const options = Object.fromEntries(allowedOptions.filter(key => request.options?.[key] !== undefined).map(key => [key, request.options[key]]));
      if (options.maxTokens !== undefined && (!Number.isSafeInteger(options.maxTokens) || options.maxTokens < 1 || options.maxTokens > model.maxTokens)) throw new DefaultAgentError('Invalid inference token limit.');
      if (options.temperature !== undefined && (!Number.isFinite(options.temperature) || options.temperature < 0 || options.temperature > 2)) throw new DefaultAgentError('Invalid inference temperature.');
      if (options.reasoning !== undefined && !['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].includes(options.reasoning)) throw new DefaultAgentError('Invalid inference reasoning level.');
      // Native Claude requires UUID scope; derive a stable UUID from the authenticated client and conversation.
      const uuid = `${conversationKey.slice(0, 8)}-${conversationKey.slice(8, 12)}-4${conversationKey.slice(13, 16)}-a${conversationKey.slice(17, 20)}-${conversationKey.slice(20, 32)}`;
      Object.assign(options, { signal: controller.signal, transport: 'sse', maxRetries: 0, sessionId: uuid,
        wovenNativeContext: { directory, sessionID: uuid, provider: model.provider, modelID: model.id,
          accountID: account.id, authIdentity: credentialIdentity, taskID: requestKey, canonicalMessages: context.messages } });
      let outputBytes = 0, terminal = false;
      const output = [];
      const run = async () => {
        const response = engine.runtime.streamSimple(model, context, options);
        for await (const raw of response) {
          controller.signal.throwIfAborted();
          const event = cleanEvent(raw);
          outputBytes += Buffer.byteLength(JSON.stringify(event));
          if (outputBytes > 32 * 1024 * 1024) throw new DefaultAgentError('The inference result exceeded the client response limit.');
          if (terminal) throw new DefaultAgentError('The inference provider returned activity after completion.');
          terminal = event.type === 'done' || event.type === 'error'; output.push(event);
          // Save completion before acknowledging it, so a lost response can be replayed without new inference.
          if (terminal) await writePrivateJSON(receiptPath, { fingerprint, state: 'complete', events: output });
          await onEvent?.(event);
        }
        if (!terminal) throw new DefaultAgentError('Inference ended before a complete response was received. It was not replayed.');
      };
      await engine.credentials.runWithAccount(model.provider, account, () => model.provider === 'claude-subscription' && engine.claude.withProfile
        ? engine.claude.withProfile(account.credential.accountId, run) : run());
      resolve();
    } catch (error) {
      const safe = new DefaultAgentError(signal?.aborted ? 'Cancelled.' : error instanceof DefaultAgentError ? error.message : accessFailure(error) ?? operationErrorMessage(undefined));
      reject(safe); throw safe;
    } finally { active.delete(requestKey); signal?.removeEventListener('abort', abort); }
  }
  async function replay(saved, fingerprint, onEvent, signal) {
    if (saved?.fingerprint !== fingerprint) throw new DefaultAgentError('This inference request identifier belongs to different input or credentials.');
    if (saved.state !== 'complete' || !Array.isArray(saved.events)) throw new DefaultAgentError('This inference request was accepted before an interruption. Its outcome is uncertain; it was not replayed. Start a new inference attempt explicitly.');
    for (const event of saved.events) { signal?.throwIfAborted(); await onEvent?.(event); }
  }
  async function cancelAll() {
    const pending = [...active.values()];
    for (const request of pending) request.controller.abort();
    await Promise.allSettled(pending.map(request => request.completion));
  }
  return { catalog, stream, cancelAll, get activeCount() { return active.size; } };
}
