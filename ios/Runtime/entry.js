// Install JavaScriptCore's host primitives before SDK module initialization.
import { nativeSync } from './platform.js';
import { forwardInferenceStream } from './inference-stream.js';
import { Turns } from './turns.js';
import { Projection } from '../../default-agent/src/projection.mjs';
import { BACKGROUND_CONTEXT as context } from '@earendil-works/chord/context';
import { AssistantEntry, ConversationIdle, Harness, UsageDoc, createRegistry, defineExtension, defineTool } from '@earendil-works/pi-durable';
import { JsonlStorage } from '@earendil-works/pi-durable/storage/jsonl';
import { createModels, createProvider } from '@earendil-works/pi-ai/models';
import { AssistantMessageEventStream } from '@earendil-works/pi-ai/utils/event-stream';

// One conversation per JavaScript context. Everything the host sees goes out as one ordered
// stream of plain events (`__wmEvent`); the SDK's own log stays in the conversation directory.
let configuration, harness, root, models, turns, projection;
let turn;
let nextCall = 0;
const calls = new Map();
const emit = event => globalThis.__wmEvent(JSON.stringify(event));
// default-agent's `humanMessage` (rpc.mjs), whose module needs Node's readline: the first line, bounded.
const humanMessage = error => (String(error?.message ?? error ?? '').split('\n').find(line => line.trim()) ?? '').trim().slice(0, 500) || 'Pi Durable could not complete this request.';

function hostCall(kind, value, signal, onEvent) {
  const id = String(++nextCall);
  return new Promise((resolve, reject) => {
    const abort = () => {
      calls.delete(id); globalThis.__wmCancel(id);
      reject(signal.reason ?? new DOMException('The operation was aborted', 'AbortError'));
    };
    if (signal?.aborted) { abort(); return; }
    calls.set(id, { resolve, reject, onEvent, cleanup: () => signal?.removeEventListener('abort', abort) });
    signal?.addEventListener('abort', abort, { once: true });
    globalThis.__wmAsync(kind, id, JSON.stringify(value));
  });
}
globalThis.__wmComplete = (id, json) => {
  const pending = calls.get(id); if (!pending) return;
  calls.delete(id); pending.cleanup();
  const result = JSON.parse(json);
  if (result.ok) pending.resolve(result.value); else pending.reject(new Error(result.error));
};
globalThis.__wmStreamEvent = (id, json) => calls.get(id)?.onEvent?.(JSON.parse(json));

function filesystem() {
  const fs = { id: 'wovenmatter-ios-durable', cwd: '/' };
  for (const operation of ['absolutePath', 'joinPath', 'createDir', 'appendFile', 'writeFile', 'flushFile', 'remove', 'renameFile', 'truncateFile', 'listDir', 'readBinaryFile']) {
    fs[operation] = async (...args) => {
      args.pop(); // Chord Context stays in JavaScript; only data crosses the bridge.
      try {
        let value = nativeSync('filesystem', { operation, args });
        if (operation === 'readBinaryFile') value = new Uint8Array(value);
        return { ok: true, value };
      } catch (error) { return { ok: false, error: { code: error.code ?? 'unknown', message: error.message } }; }
    };
  }
  return fs;
}

// The model's provider streams through the native inference closure. Credentials never enter
// the JavaScript heap, the transcript or the conversation directory.
function installModel(model) {
  const stream = (model, transcript, options = {}) => {
    const output = new AssistantMessageEventStream();
    const { signal, ...serializable } = options;
    delete serializable.apiKey; delete serializable.auth;
    void forwardInferenceStream(output, model, signal, onEvent => hostCall('inference', { model, context: transcript, options: serializable,
      scope: { conversationID: `${configuration.conversationID}:${options.sessionId ?? 'root'}`, externalConversationID: configuration.conversationID } }, signal, onEvent));
    return output;
  };
  models.setProvider(createProvider({ id: model.provider, models: [model],
    auth: { apiKey: { name: 'Native credentials', resolve: async () => ({ auth: { apiKey: 'native-managed' } }) } }, api: { stream, streamSimple: stream } }));
  return { provider: model.provider, modelId: model.id };
}

function tool(descriptor) {
  return defineTool({
    name: descriptor.name, description: descriptor.description, parameters: descriptor.parameters,
    ...(descriptor.replaySafe ? { replay: 'safe' } : {}),
    execute: async (args, api, toolContext) => {
      if (descriptor.question) {
        const answer = await hostCall('question', { id: api.callId, question: String(args.question ?? '') }, toolContext.abortSignal);
        return { output: [{ type: 'text', text: answer ?? 'The person declined to answer.' }], isError: answer == null };
      }
      const result = await hostCall('tool', { name: descriptor.name, arguments: args, callID: api.callId }, toolContext.abortSignal);
      return { output: [{ type: 'text', text: result.output }], isError: result.isError };
    },
  });
}

const usageTotals = state => {
  const total = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 };
  for (const usage of [...Object.values(state?.models ?? {}), ...Object.values(state?.tools ?? {})]) {
    for (const key of Object.keys(total)) total[key] += usage[key] ?? 0;
  }
  return total;
};
const usageNow = async () => usageTotals(await harness.snapshot(UsageDoc, root.id, context));

// Ends the turn once its run has settled: whatever is still open is finished first.
async function settle(running, settled) {
  if (settled?.status === 'done') await projection.through(settled.answer); else await projection.through(-1, 0);
  if (turn !== running) return;
  turn = undefined;
  const after = await usageNow();
  const usage = Object.fromEntries(Object.entries(after).map(([key, value]) => [key, value - running.before[key]]));
  let failure = running.failure ?? null, model = `${configuration.model.provider}/${configuration.model.modelId}`;
  if (settled?.status === 'done') {
    const answer = (await root.commit(tx => tx.entry(AssistantEntry, settled.answer), context))?.model?.[0];
    if (answer) model = `${answer.provider}/${answer.model}`;
    if (answer?.stopReason === 'length') failure = 'The reply reached its length limit.';
    else if (answer?.rawStopReason === 'refusal') failure = 'The model declined to answer.';
  } else if (settled && settled.reason !== 'aborted') {
    const detail = typeof settled.detail === 'string' ? settled.detail : settled.detail?.message;
    failure = humanMessage(detail ?? `The model did not answer (${settled.reason}).`);
  }
  turns.end(failure, { model, ...usage });
}

function track(running, waiting) {
  turn = running;
  waiting.then(settled => settle(running, settled), error => { running.failure = humanMessage(error); return settle(running); });
}

const methods = {
  async open(config) {
    if (harness) throw new Error('This conversation is already open.');
    configuration = config;
    models = createModels({ authContext: { env: async () => undefined, fileExists: async () => false } });
    configuration.model = installModel(JSON.parse(config.modelJSON));
    const registry = createRegistry();
    registry.install(defineExtension({ name: 'wovenmatter-ios', tools: config.tools.map(tool) }));
    const storage = await JsonlStorage.open('/', filesystem(), context, { fsync: true });
    harness = await Harness.open(storage, { models, registry,
      onReport: error => globalThis.__wmLog(String(error?.message ?? error)) }, context);
    root = await harness.root(context, { agent: { model: configuration.model } });
    // Model, thinking and instructions are this device's choice, applied before anything runs.
    await root.configure({ model: configuration.model, instructions: config.instructions, thinkingLevel: config.thinkingLevel }, context);
    turns = new Turns(emit);
    projection = turns.projection(Projection);
    // A run that a close or a relaunch cut short is not continued: the host has
    // already saved that turn as stopped, so it is settled as aborted here, before
    // anything is watched, and the next message starts a turn of its own.
    const before = await root.watch(context);
    const cutShort = Boolean(before.value.docs?.['pi.live']?.run);
    await before.stop();
    if (cutShort) await root.abort(context);
    projection.attach(await root.watch(context));
    harness.resume();
  },
  async send({ text }) {
    if (turn) throw new Error('A turn is already running. Steer it or interrupt it first.');
    const running = { before: await usageNow() };
    turns.user(text);
    try {
      const submission = await root.submit({ type: 'input', content: text, requestId: crypto.randomUUID(), whenBusy: 'reject' }, context);
      track(running, submission.wait(context));
    } catch (error) {
      turn = running; running.failure = humanMessage(error);
      await settle(running);
    }
  },
  // The message joins the running turn through the SDK's own mid-turn input; nothing is queued.
  async steer({ text }) {
    if (!turn) return false;
    try {
      await root.submit({ type: 'input', content: text, requestId: crypto.randomUUID(), whenBusy: 'steer', whenIdle: 'reject' }, context);
    } catch (error) {
      if (error instanceof ConversationIdle) return false;
      throw error;
    }
    turns.user(text);
    return true;
  },
  async interrupt() { if (turn) await root.abort(context); },
  async configure({ modelJSON, thinkingLevel }) {
    if (turn) throw new Error('Wait for the current response before changing the model or thinking.');
    const change = {};
    if (modelJSON !== undefined) change.model = configuration.model = installModel(JSON.parse(modelJSON));
    if (thinkingLevel !== undefined) change.thinkingLevel = thinkingLevel;
    await root.configure(change, context);
  },
  // Suspends pending work; the next open continues it.
  async close() {
    const running = turn; turn = undefined;
    if (running) turns.end('The conversation was closed during the turn.');
    await harness?.close(context); harness = undefined; root = undefined;
  },
};

globalThis.__wmDispatch = (id, method, json) => {
  Promise.resolve().then(() => {
    if (!Object.hasOwn(methods, method)) throw new Error('Unknown runtime operation');
    return methods[method](JSON.parse(json));
  }).then(value => globalThis.__wmReply(id, JSON.stringify({ ok: true, value: value ?? null })),
    error => globalThis.__wmReply(id, JSON.stringify({ ok: false, error: humanMessage(error) })));
};
