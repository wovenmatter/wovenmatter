import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { createHash, randomUUID } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { join } from 'node:path';
import { AsyncLocalStorage } from 'node:async_hooks';
import { SessionCLIContext } from './cli-context.mjs';
import { ownNativeStore } from './native-owner.mjs';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { getSupportedThinkingLevels } from '@earendil-works/pi-ai/models';
import { createCodingTools, createBashTool, createGrepTool, createFindTool, createLsTool, createCodemodeExtension, DefaultResourceLoader, SettingsManager } from '@earendil-works/pi-coding-agent';
import { AgentDoc, CompactionTask, Harness, LiveDoc, ProviderDoc, ToolTask, defineDoc, defineExtension, section, watchEvents } from '@earendil-works/pi-durable';
import { openNodeJsonlStorage } from '@earendil-works/pi-durable/storage/jsonl/node';
import { DefaultAgentError, accessFailure, operationErrorMessage, readJSON, writePrivateJSON } from './config.mjs';
import { ProviderCompactionError } from './provider-compaction.mjs';
import { providerFetch } from './transport.mjs';
import { searchTools } from './search.mjs';
import { checklistTool } from './checklist.mjs';
import { openNativeArchive, nativePresentationUpdates } from './native-journal.mjs';
import { NativeContext, contextOverflowDiagnostic, credentialRouteIdentity, nativeContextBridge, safeAssistantDiagnostic } from './native-context.mjs';
import { createNativeCompactionRegistry } from './native-compaction-registry.mjs';
import { createSubagentContext } from './subagent-context.mjs';
import { ChildContext, Subagents, createSubagents } from './subagents.mjs';
import { reportProgramStatus } from './program-status.mjs';

const context = BACKGROUND_CONTEXT;
const Requests = defineDoc({ kind: 'woven.requests', version: 1, scope: 'conversation', history: 'latest', fork: 'initial', initial: () => ({ requests: {} }) });
const Options = defineDoc({ kind: 'woven.options', version: 1, scope: 'conversation', history: 'latest', fork: 'current', initial: () => ({ permission: 'full' }) });
const canonical = value => Array.isArray(value) ? value.map(canonical) : value && typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])])) : value;
const digest = value => createHash('sha256').update(JSON.stringify(canonical(value))).digest('hex');
const textOf = messages => (messages ?? []).flatMap(m => typeof m.content === 'string' ? [m.content] : (m.content ?? []).flatMap(b => b.type === 'text' ? [b.text] : b.type === 'thinking' ? [b.thinking] : [])).join('\n');
const safeNativeFailure = error => ({ message: error instanceof DefaultAgentError || error instanceof ProviderCompactionError ? error.message : accessFailure(error) ?? contextOverflowDiagnostic(error) ?? operationErrorMessage(error), ...(error instanceof ProviderCompactionError ? { code: error.code } : {}) });
// AgentSession is deliberately absent: the coding package supplies the existing
// image-capable tools, resource instructions and sandbox, not the execution loop.
export async function openDurableSession(engine, id, requested) {
  const sessionID = id ?? randomUUID();
  if (!/^[0-9a-f-]{36}$/i.test(sessionID)) throw new DefaultAgentError('Invalid Pi Durable session.');
  const root = join(engine.directory, 'durable', sessionID);
  await mkdir(root, { recursive: true, mode: 0o700 });
  let release, record, ownerError, eventStream;
  try { release = await ownNativeStore(root, error => { ownerError = error; void record?.session?.abort()?.catch(() => {}); if (record) record.lockError = error; }); }
  catch { throw new DefaultAgentError('This Pi Durable session is already owned by another runtime. Reconnect to its current execution owner.'); }
  try {
    let manifest = await readJSON(join(root, 'woven-session.json'), null);
    if (id && !manifest) throw new DefaultAgentError('This Pi Durable session could not be found. Create a new conversation.');
    const cwd = manifest?.cwd ?? requested ?? await engine.sessionDirectory(engine.cwd);
    if (requested !== undefined && requested !== cwd) throw new DefaultAgentError('This Pi Durable session belongs to a different working directory. Create a new session for this location.');
    await engine.sessionDirectory(cwd);
    manifest ??= { schemaVersion: 1, sessionID, storeID: randomUUID(), cwd };
    if (!/^[0-9a-f-]{36}$/i.test(manifest.storeID ?? '') || manifest.sessionID !== sessionID) throw new DefaultAgentError('Pi Durable native identity is invalid.');
    await writePrivateJSON(join(root, 'woven-session.json'), manifest);
    const archivePath = join(root, `woven-native-records-${randomUUID()}.jsonl`);
    const archiveStore = await openNativeArchive(archivePath);
    const archiveIDs = archiveStore.identities;
    const pendingArchiveIDs = new Set();
    record = { cli: new SessionCLIContext(), cwd, busy: false, permission: 'full', ordinaryTools: ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls', 'web_search', 'web_read', checklistTool.name], codeModeState: { value: engine.config.codeMode }, archivePath, manifest, lockError: ownerError, archiveQueue: Promise.resolve(), emit: undefined };
    const batch = records => ({ schemaVersion: 1, sourceID: `builtin-pi-durable:${manifest.storeID}`, nativeSessionID: sessionID, records });
    record.nativeRoot = root;
    record.nativeContext = context;
    const scopes = new Map(), childMetadata = new Map(), childModels = new Map(), modelScopes = new Map(), toolScopes = new AsyncLocalStorage();
    const scopedArchive = (scope, records) => records.map(item => {
      if (scope === record) return item;
      const group = JSON.stringify({ nativeConversationID: scope.conversation.id, parentNativeConversationID: record.conversation.id, childID: String(scope.conversation.id) });
      return { ...item, ...(scope.runID ? { runID: scope.runID } : {}), projectionJSON: item.projectionJSON === undefined ? group : `${group.slice(0, -1)},"content":${item.projectionJSON}}` };
    });
    const scopeFor = async conversationID => {
      if (conversationID === record.conversation.id) return record;
      if (!scopes.has(conversationID)) scopes.set(conversationID, (async () => {
        const metadata = childMetadata.get(conversationID) ?? await record.harness.snapshot(ChildContext, conversationID, context);
        if (!metadata || metadata.parentConversationID !== record.conversation.id) throw new DefaultAgentError('This child does not belong to the current Pi Durable conversation.');
        const child = await record.harness.conversation(conversationID, context);
        if (!child) throw new DefaultAgentError('This native child conversation is unavailable.');
        const scope = createSubagentContext(record, engine, { conversation: child, sessionID: metadata.sessionID, model: await engine.ensureModel(`${metadata.provider}/${metadata.modelId}`, metadata.selectedModel), accountID: metadata.accountID, thinkingLevel: metadata.thinking, runID: metadata.runID, cli: childBindings.get(conversationID) ?? new SessionCLIContext().fork(), appendArchive: items => record.appendArchive(scopedArchive({ conversation: child, runID: metadata.runID }, items)), reportUsage: usage => record.reportUsage?.(usage) }, context);
        scope.connectionPin = metadata;
        return scope;
      })());
      return scopes.get(conversationID);
    };
    const childBindings = new Map();
    const prepareScope = async (api, ctx) => {
      const scope = await scopeFor(api.conversationId);
      let provider = await api.snapshot(ProviderDoc, api.conversationId, ctx);
      if (!provider) await api.commit(async tx => { provider = await tx.doc(ProviderDoc, api.conversationId); }, ctx);
      scope.providerSessionID = provider.sessionId;
      modelScopes.set(provider.sessionId, scope);
      return scope;
    };
    const modelScope = options => {
      const scope = modelScopes.get(options?.sessionId);
      if (!scope) throw new DefaultAgentError('The native model request has no authorized conversation context.');
      return scope;
    };
    record.appendArchive = records => {
      if (record.archiveError) return;
      const fresh = records.filter(r => { const key = r.id + ':' + (r.revision ?? ''); if (archiveIDs.has(key) || pendingArchiveIDs.has(key)) return false; pendingArchiveIDs.add(key); return true; });
      if (!fresh.length) return;
      record.archiveQueue = record.archiveQueue.then(async () => {
        if (record.archiveError) throw record.archiveError;
        const start = archiveStore.index.length;
        await archiveStore.append(fresh);
        // The disk pager is also the live transport. Oversized originals yield
        // bounded content-addressed chunks/manifests rather than a giant IPC
        // batch or another whole-record JSON string in memory.
        if (record.emit) {
          let cursor = start;
          while ((typeof cursor === 'number' ? cursor : cursor.record) < archiveStore.index.length) {
            const page = await archiveStore.page(cursor, 200);
            await record.emit({ sessionUpdate: 'woven_native_record', recordBatch: batch(page.records) });
            cursor = page.nextAfter;
          }
        }
      }).catch(error => { record.archiveError = error; }).finally(() => { for (const item of fresh) pendingArchiveIDs.delete(item.id + ':' + (item.revision ?? '')); });
    };
    const currentAccount = async (model, scope = record) => {
      if (!model) throw new DefaultAgentError('The selected model is unavailable. Choose a model in Settings.');
      if ((scope !== record || record.resuming) && !engine.isModelEnabled(model)) throw new DefaultAgentError('The pinned native model or connection is no longer enabled. No fallback was attempted.');
      const accounts = await engine.credentials.candidates(model.provider);
      if (scope === record && record.resuming && !record.accountID) throw new DefaultAgentError('The interrupted native run has no pinned connection. Stop it before starting a new input.');
      const scoped = engine.credentials.context.getStore();
      const accountID = scope === record && scoped?.provider === model.provider ? scoped.id : scope.accountID;
      const account = accountID ? accounts.find(value => value.id === accountID) : accounts[0];
      if (!account) throw new DefaultAgentError('The selected account is unavailable. Check Settings → Connections.');
      if (scope === record && record.resuming && ((account.owned === true) !== record.accountOwned || credentialRouteIdentity(record, account) !== record.credentialIdentity)) throw new DefaultAgentError('The interrupted native run connection changed. No account fallback was attempted.');
      if (scope !== record && ((account.owned === true) !== scope.connectionPin.accountOwned || credentialRouteIdentity(record, account) !== scope.connectionPin.credentialIdentity)) throw new DefaultAgentError('The child connection changed or became unavailable. Choose an available connection explicitly; no account fallback was attempted.');
      return account;
    };
    const withAccount = (model, account, operation, scope = record) => engine.programStatusContext.run({ record, scope }, () =>
      engine.credentials.runWithAccount(model.provider, account, () => model.provider === 'claude-subscription' && engine.claude.withProfile ? engine.claude.withProfile(account.credential?.accountId, operation) : operation()));
    const currentRoute = async (api, ctx) => {
      const scope = await prepareScope(api, ctx);
      const reference = (await api.snapshot(AgentDoc, api.conversationId, ctx)).model;
      const model = scope.session.model ?? await engine.ensureModel(`${reference.provider}/${reference.modelId}`);
      if (model?.provider !== reference.provider || model?.id !== reference.modelId) throw new DefaultAgentError('The saved model does not match this native run. No model fallback was attempted.');
      const account = await currentAccount(model, scope);
      return { scope, model, account, route: { provider: model.provider, modelID: model.id, accountID: account.id } };
    };
    const models = new Proxy(engine.runtime, { get(target, key) {
      if (key === 'getModel') return (provider, id) => record.selectedModel?.provider === provider && record.selectedModel?.id === id ? record.selectedModel : childModels.get(`${provider}/${id}`) ?? target.getModel(provider, id);
      if (key === 'completeSimple') return async (model, input, options) => {
        const scope = modelScope(options);
        model = scope.session.model ?? model;
        if (scope.nativeContextFailure) throw new DefaultAgentError(scope.nativeContextFailure.message);
        try {
          const message = safeAssistantDiagnostic(await withAccount(model, await currentAccount(model, scope), () => target[key](model, input, { ...options, transport: 'sse', maxRetries: 0, fetch: providerFetch(scope) }), scope));
          if (message.usage) scope.reportUsage?.(message.usage);
          return message;
        }
        catch (error) { throw new DefaultAgentError(safeNativeFailure(error).message); }
      };
      if (key === 'streamSimple') return (model, input, options) => {
        const scope = modelScope(options);
        model = scope.session.model ?? model;
        if (scope.nativeContextFailure) throw new DefaultAgentError(scope.nativeContextFailure.message);
        const result = createAssistantMessageEventStream(), prepared = scope.nativePrepared;
        const tag = message => ({ ...safeAssistantDiagnostic(message), ...(prepared?.route ? { wovenNativeRoute: prepared.route } : {}) });
        void (async () => {
          try {
            const account = await currentAccount(model, scope);
            await withAccount(model, account, async () => {
              const nativeOptions = await scope.nativeBridge.requestOptions(model, prepared, options?.signal);
              const resolved = { ...options, ...nativeOptions, transport: 'sse', maxRetries: 0, fetch: providerFetch(scope) };
              const native = (scope.streamFunction ?? target.streamSimple.bind(target))(model, { ...input, messages: scope.nativeBridge.filterTools(input.messages) }, resolved);
              for await (const event of native) result.push({ ...event, ...(event.partial ? { partial: tag(event.partial) } : {}), ...(event.message ? { message: tag(event.message) } : {}), ...(event.error ? { error: tag(event.error) } : {}) });
              result.end(tag(await native.result()));
            }, scope);
          } catch (error) {
            const message = { role: 'assistant', ...(prepared?.route ? { wovenNativeRoute: prepared.route } : {}), provider: model.provider, api: model.api, model: model.id, timestamp: Date.now(), content: [], stopReason: options?.signal?.aborted ? 'aborted' : 'error', errorMessage: safeNativeFailure(error).message, usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
            result.push({ type: 'error', reason: message.stopReason, error: message }); result.end(message);
          }
        })();
        return result;
      };
      return typeof target[key] === 'function' ? target[key].bind(target) : target[key];
    } });
    const registry = createNativeCompactionRegistry();
    const storage = await openNodeJsonlStorage(join(root, 'native'), context, { fsync: true });
    if (record.lockError) throw new DefaultAgentError('The native session owner lock was lost. Reconnect before continuing.');
    const harness = await Harness.open(storage, { models, registry, settings: { retry: { enabled: false, maxRetries: 0 }, stream: { transport: 'sse', maxRetries: 0 }, toolExecution: 'sequential', compaction: { backgroundTokens: 0 } } }, context);
    record.harness = harness; record.storage = storage; record.registry = registry;
    record.unsubscribeCommits = harness.subscribeCommits(publication => {
      const records = [];
      const changedGroup = publication.changes.find(change => change.type === 'document' && change.record.kind === Subagents.definition.kind && change.conversationId === record.conversation?.id);
      const reportEntries = new Set(publication.changes.filter(change => change.type === 'submission' && change.value.requestId?.startsWith('woven-subagent-report:')).map(change => change.value.entry));
      for (const change of publication.changes) if (change.type === 'document' && change.record.kind === ChildContext.definition.kind && change.value) {
        childMetadata.set(change.conversationId, change.value);
        if (change.value.selectedModel) childModels.set(`${change.value.provider}/${change.value.modelId}`, change.value.selectedModel);
      }
      publication.changes.forEach((change, index) => {
        const nativeConversationID = change.conversationId ?? (change.type === 'conversation' ? change.value.id : change.value?.conversationId);
        const child = childMetadata.get(nativeConversationID) ?? record.subagents?.metadata(nativeConversationID);
        const isRoot = nativeConversationID === record.conversation?.id;
        const messages = change.type === 'entry' ? change.value.model : undefined;
        // Binding advances on native input placement, before any dependent tool
        // task can start. Queued steering has no pi.user entry until consumed.
        if (isRoot && change.type === 'entry' && change.value.kind === 'pi.user' && !reportEntries.has(change.value.id)) record.cli.consumed();
        if (isRoot) for (const message of messages ?? []) if (message.role === 'assistant') { if (message.stopReason === 'error') record.lastError = message.errorMessage; if (message.content?.some(b => b.type === 'toolCall' || b.text || b.thinking)) record.nativeVisible = true; }
        if (child) for (const message of messages ?? []) if (message.role === 'assistant' && message.usage) record.reportUsage?.(message.usage);
        if (isRoot && change.type === 'document' && change.record.kind === 'pi.live' && change.value?.generation?.message?.content?.some(b => b.text || b.thinking)) record.nativeVisible = true;
        const runID = child?.runID ?? (changedGroup ? changedGroup.value?.runID : record.subagents?.currentRunID()) ?? (record.busy ? record.runID : undefined);
        const projection = { ...(nativeConversationID === undefined ? {} : { nativeConversationID }), ...(child ? { parentNativeConversationID: child.parentConversationID, childID: String(nativeConversationID) } : {}), ...(messages ? { content: messages.map(({ details, ...message }) => message) } : {}) };
        records.push({ id: `commit:${publication.seq}:${index}`, revision: String(publication.seq),
          kind: change.type === 'entry' ? change.value.kind : change.type.startsWith('document') ? change.record.kind : change.value?.kind ?? `native.${change.type}`,
          payload: JSON.stringify(change), contentMode: change.type === 'entry' ? 'event' : 'snapshot', ...(runID ? { runID } : {}), projectionJSON: JSON.stringify(projection),
          ...(messages ? { text: textOf(messages) } : {}) });
      });
      record.appendArchive(records);
    });
    const conversation = await harness.root(context, { init: async tx => { await tx.doc(Requests, 1); await tx.doc(Options, 1); await tx.doc(NativeContext, 1); } });
    record.conversation = conversation;
    record.nativeBridge = nativeContextBridge(record, engine, context);
    const options = await harness.snapshot(Options, conversation.id, context) ?? {};
    record.selected = options.selected; record.options = options;
    record.selectedModel = await engine.ensureModel(options.selected ?? engine.config.defaultModel, options.selectedModel);
    // Restore alternate child selections before the native scheduler resolves their models.
    const group = await harness.snapshot(Subagents, conversation.id, context);
    for (const child of Object.values(group?.children ?? {})) {
      const saved = await harness.snapshot(ChildContext, child.conversationId, context);
      if (saved?.selectedModel) childModels.set(`${saved.provider}/${saved.modelId}`, await engine.ensureModel(`${saved.provider}/${saved.modelId}`, saved.selectedModel));
    }
    record.subagentConcurrency = options.subagentConcurrency ?? engine.config.subagentConcurrency;
    const listeners = new Set();
    const send = update => {
      let offset = 0;
      for (const presentation of nativePresentationUpdates(update)) {
        // Reassemble a snapshot before projecting it. A partial replacement
        // cannot pass the coordinator's cumulative steering-prefix fence.
        if (update._meta?.wovenAssistantSnapshot || update._meta?.wovenThoughtSnapshot) {
          const start = offset === 0;
          offset += presentation.content.text.length;
          presentation._meta = { ...presentation._meta, wovenSnapshotStart: start, wovenSnapshotEnd: offset === update.content.text.length };
        }
        for (const listener of listeners) listener({ update: presentation });
      }
    };
    const settingsManager = SettingsManager.inMemory({ retry: { enabled: false }, compaction: { enabled: true } });
    const loader = new DefaultResourceLoader({ cwd, agentDir: engine.directory, settingsManager, noExtensions: true, noThemes: true });
    await loader.reload();
    let codemode;
    const tools = [...createCodingTools(cwd), createGrepTool(cwd), createFindTool(cwd), createLsTool(cwd), ...searchTools(async () => (await engine.credentials.read('exa'))?.key), checklistTool];
    createCodemodeExtension({ models: false })( { registerTool: tool => { codemode = tool; }, getSettings: () => ({ codemode: { mode: (toolScopes.getStore() ?? record).codeModeState.value } }), getAllTools: () => tools, appendEntry: (customType, data) => { toolScopes.getStore().pendingStoreWrites.push({ customType, data }); } });
    const adapted = tools.map(tool => ({ ...tool, replay: ['read', 'grep', 'find', 'ls', 'web_search', 'web_read', checklistTool.name].includes(tool.name) ? 'safe' : 'unsafe', execute: async (args, api, ctx) => {
      const scope = await scopeFor(api.conversationId);
      const env = scope.cli.environment(process.env);
      for (const key of ['PI_SESSION_FILE', 'PI_SESSION_ID', 'PI_PROVIDER', 'PI_MODEL', 'PI_REASONING_LEVEL']) delete env[key];
      const boundTool = tool.name === 'bash' ? createBashTool(cwd, { spawnHook: context => {
        const nativeEnv = { ...context.env };
        for (const key of ['WOVENMATTER_CONTEXT_ID', 'WOVENMATTER_NOTE_ID', 'WOVENMATTER_SOCKET', 'WOVENMATTER_CLI']) delete nativeEnv[key];
        return { ...context, env: { ...nativeEnv, ...env } };
      } }) : tool;
      let output = '', detailsError, detailsQueue = Promise.resolve();
      const result = await boundTool.execute(api.callId, args, ctx.abortSignal, update => {
        const snapshot = textOf([{ content: update.content }]);
        if (snapshot.startsWith(output)) api.output(snapshot.slice(output.length));
        output = snapshot;
        // Coding-tool updates are snapshots, not append-only chunks. Retain the
        // exact exposed snapshot alongside truncation/full-output references;
        // only a verified suffix enters the native output accumulator.
        const details = { ...update.details, ...(update.content ? { wovenOutputSnapshot: update.content } : {}) };
        detailsQueue = detailsQueue.then(() => api.details(details, ctx)).catch(error => { if (!ctx.abortSignal.aborted) detailsError = error; });
      });
      await detailsQueue;
      if (detailsError) throw detailsError;
      return { ...result, ...(result.structuredContent === undefined ? {} : { details: { ...result.details, structuredContent: result.structuredContent } }) };
    } }));
    const codeTool = { ...codemode, description: 'Run sandboxed JavaScript using tools, ALL_TOOLS, text(), image(), store() and load(). Available tools: ' + tools.map(t => t.name + ': ' + t.description).join('\n'), replay: 'unsafe', execute: async (args, api, ctx) => {
      const scope = await scopeFor(api.conversationId), conversation = scope.conversation;
      if (scope.codeModeState.value === 'off') throw new DefaultAgentError('Code mode is disabled.');
      let nested = 0;
      const nestedWork = new Set();
      let detailsQueue = Promise.resolve(), detailsError;
      const invocation = { ...scope, pendingStoreWrites: [] };
      const prior = (await conversation.context(context)).entries.filter(e => e.kind === 'woven.codemode-store').map(e => ({ type: 'custom', customType: 'codemode-store', data: e.data }));
      const nestedTools = [...adapted, ...(api.conversationId === record.conversation.id ? [record.subagents.tool] : [])];
      const executeNested = async (name, input, { signal }) => {
          signal?.throwIfAborted(); ctx.abortSignal.throwIfAborted();
          const tool = nestedTools.find(t => t.name === name); if (!tool) throw new Error('Unknown nested tool.');
          const call = { id: `${api.callId}/nested/${++nested}`, name, arguments: input };
          const nestedTask = await api.commit(async tx => {
            signal?.throwIfAborted(); ctx.abortSignal.throwIfAborted();
            const assistant = await tx.appendEntry(conversation.id, { kind: 'pi.assistant', data: { wovenNestedCall: true }, model: [{ role: 'assistant', content: [{ type: 'toolCall', ...call }], timestamp: Date.now(), api: scope.session.model?.api, provider: scope.session.model?.provider, model: scope.session.model?.id, stopReason: 'toolUse', usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } }], edits: [] });
            const taskID = await tx.createTask(ToolTask, { assistant: assistant.id, callId: call.id }, { conversationId: conversation.id, ownership: { kind: 'task', taskId: api.taskId } });
            await tx.appendEntry(conversation.id, { kind: 'woven.codemode-context', edits: [{ target: assistant.id, action: 'omit' }] });
            return { taskID, assistantID: assistant.id };
          }, ctx);
          let cancellation;
          const cancel = () => { cancellation ??= harness.abortTask(nestedTask.taskID, context); cancellation.catch(() => {}); };
          signal?.addEventListener('abort', cancel, { once: true });
          if (signal?.aborted) cancel();
          try {
            const settled = await api.waitForTask(nestedTask.taskID, ctx);
            signal?.throwIfAborted();
            const outcome = settled.state.outcome;
            if (outcome.status !== 'completed') throw new Error('Nested tool interrupted.');
            const entry = (await storage.entry(outcome.result.entryId, ctx))?.entry;
            await api.commit(tx => tx.appendEntry(conversation.id, { kind: 'woven.codemode-context', edits: [{ target: nestedTask.assistantID, action: 'omit' }, { target: outcome.result.entryId, action: 'omit' }] }), ctx);
            const message = entry?.model?.[0];
            return { toolCall: call, result: { content: message?.content ?? [], details: message?.details, structuredContent: message?.details?.structuredContent }, isError: Boolean(message?.isError) };
          } finally {
            signal?.removeEventListener('abort', cancel);
            if (cancellation) { await cancellation; await harness.waitForTask(nestedTask.taskID, context); }
          }
      };
      let result;
      try {
        result = await toolScopes.run(invocation, () => codemode.execute(api.callId, args, ctx.abortSignal, update => {
          if (update.details !== undefined) detailsQueue = detailsQueue.then(() => api.details(update.details, ctx)).catch(error => { if (!ctx.abortSignal.aborted) detailsError = error; });
        }, {
          tools: nestedTools, sessionManager: { getBranch: () => prior }, executeTool: (...arguments_) => {
            const work = executeNested(...arguments_); nestedWork.add(work);
            work.then(() => nestedWork.delete(work), () => nestedWork.delete(work));
            return work;
          },
        }));
      } finally {
        // Sandbox teardown cancels unawaited calls. Keep the native tool scope
        // attached until their abort receipts settle, including unsafe effects.
        await Promise.allSettled([...nestedWork]); await detailsQueue;
      }
      if (detailsError) throw detailsError;
      for (const write of invocation.pendingStoreWrites) await api.commit(tx => tx.appendEntry(conversation.id, { kind: 'woven.codemode-store', data: write.data }), ctx);
      return result;
    } };
    record.subagents = createSubagents({ record, engine, context, allTools: () => [...adapted, codeTool], send,
      getTrustedInstructions: () => [...(record.userInstructions ?? []), ...loader.getAgentsFiles().agentsFiles.map(file => file.content)],
      onSpawn: (metadata, conversationID) => { childBindings.set(conversationID, record.cli.fork()); childMetadata.set(conversationID, metadata); scopes.delete(conversationID); },
    });
    record.ordinaryTools.push(record.subagents.tool.name);
    codeTool.description += '\nFor parent conversations only, ' + record.subagents.tool.name + ': ' + record.subagents.tool.description;
    // Durable reports hook exceptions and continues. The Models boundary must
    // reject the same current request before a fallback provider call can start.
    registry.install(defineExtension({ name: 'woven-builtin', tasks: record.subagents.tasks, tools: [...adapted, codeTool, record.subagents.tool], hooks: [
      { task: 'pi.generation', handlers: { beforeRequest: async (request, api, ctx) => {
        const scope = await prepareScope(api, ctx);
        reportProgramStatus(record, { state: 'working', ...(scope !== record ? { id: `children/${scope.conversation.id}` } : {}) }, scope.runID);
        scope.nativePrepared = undefined;
        try {
          const { model, account, route } = await currentRoute(api, ctx);
          scope.nativePrepared = await withAccount(model, account, () => scope.nativeBridge.prepare(request.messages, route, api.taskId, ctx), scope);
          return { messages: scope.nativePrepared.messages };
        } catch (error) { if (ctx.abortSignal.aborted) throw error; scope.nativeContextFailure = safeNativeFailure(error); return undefined; }
      } } },
      { task: 'pi.compaction', handlers: { beforeCompact: async (compaction, api, ctx) => {
        const scope = await prepareScope(api, ctx);
        reportProgramStatus(record, { state: 'working', ...(scope !== record ? { id: `children/${scope.conversation.id}` } : {}), msg: 'Compacting context' }, scope.runID);
        try {
          const { model, account, route } = await currentRoute(api, ctx);
          return await withAccount(model, account, () => scope.nativeBridge.beforeCompact(compaction, route, api, ctx), scope);
        } catch (error) { if (ctx.abortSignal.aborted) throw error; scope.nativeContextFailure = safeNativeFailure(error); return undefined; }
      } } },
    ], sections: [section('workspace', () => loader.getAgentsFiles().agentsFiles.map(f => f.content).join('\n\n'), { tag: false })] }));
    record.subscribe = listener => { listeners.add(listener); return () => listeners.delete(listener); };
    record.reportUsage = usage => { for (const listener of listeners) listener({ usage }); };
    const session = { sessionId: sessionID, thinkingLevel: options.thinking ?? 'medium', messages: [],
      get model() { return record.selectedModel ?? engine.resolveModel(record.selected); }, getAvailableThinkingLevels: () => session.model ? getSupportedThinkingLevels(session.model) : [],
      setModel: async model => { record.selectedModel = structuredClone(model); record.selected = `${model.provider}/${model.id}`; const levels = getSupportedThinkingLevels(model); if (!levels.includes(session.thinkingLevel)) session.thinkingLevel = levels[0]; await conversation.configure({ model: { provider: model.provider, modelId: model.id }, thinkingLevel: session.thinkingLevel, cwd }, context); },
      setThinkingLevel: level => { session.thinkingLevel = level; record.configurationQueue = (record.configurationQueue ?? Promise.resolve()).then(() => conversation.configure({ thinkingLevel: level }, context)); },
      setActiveToolsByName: names => { record.configurationQueue = (record.configurationQueue ?? Promise.resolve()).then(() => conversation.configure({ tools: names.map(n => [...adapted, codeTool, record.subagents.tool].find(t => t.name === n)).filter(Boolean) }, context)); },
      abort: async () => { await record.subagents.stopGroup(); await conversation.abort(context, { background: true }); }, refreshContext: async () => { session.messages = [...(await conversation.context(context)).messages]; },
      dispose: async () => {
        let failure;
        // A failed configuration/archive write must not strand the native owner
        // lock or prevent the remaining resources from shutting down.
        for (const close of [
          () => record.configurationQueue,
          () => record.subagents.dispose(),
          () => eventStream?.stop(),
          () => harness.close(context),
          () => record.unsubscribeCommits(),
          () => record.archiveQueue,
          () => release(),
        ]) {
          try { await close(); } catch (error) { failure ??= error; }
        }
        engine.sessions.delete(sessionID);
        if (failure) throw failure;
      },
      prompt: async (content, opts = {}) => {
        if (record.lockError) throw new DefaultAgentError('The native session owner lock was lost. Reconnect before continuing.');
        await record.configurationQueue;
        if (!record.accountID) record.accountID = engine.credentials.context.getStore()?.id ?? (await engine.credentials.candidates(record.selected?.split('/')[0]))[0]?.id;
        engine.sessions.get(sessionID)?.promptController?.signal.throwIfAborted();
        // Steering stays in the same cumulative stream. The coordinator's
        // existing admission fence owns which reply receives its suffix.
        if (opts.streamingBehavior !== 'steer') { completedAssistantText = ''; blocks = new Map(); messageOpen = false; }
        const logicalID = opts.requestId ?? record.inputID ?? randomUUID();
        record.userInstructions = [typeof content === 'string' ? content : textOf([{ content }])];
        if (opts.streamingBehavior !== 'steer') await record.subagents.beginGroup(record.runID);
        const manual = typeof content === 'string' && content.match(/^\/compact(?:\s+([\s\S]*))?$/);
        if (manual) {
          const fingerprint = digest({ content });
          const taskID = await conversation.commit(async tx => {
            const state = await tx.doc(Requests, conversation.id), prior = state.requests[logicalID];
            if (prior && prior.fingerprint !== fingerprint) throw new DefaultAgentError('This run identifier belongs to a different request.');
            if (prior?.compactionTaskID !== undefined) return prior.compactionTaskID;
            engine.sessions.get(sessionID)?.promptController?.signal.throwIfAborted();
            const taskID = await tx.createTask(CompactionTask, { reason: 'manual', ...(manual[1] ? { instructions: manual[1] } : {}) }, { ownership: { kind: 'conversation' }, conversationId: conversation.id, background: false });
            const live = await tx.doc(LiveDoc, conversation.id); live.compactions ??= []; live.compactions.push({ taskId: taskID, reason: 'manual', blocking: false, attempt: 1 });
            state.requests[logicalID] = { fingerprint, compactionTaskID: taskID };
            return taskID;
          }, context);
          opts.preflightResult?.('started'); harness.resume();
          const task = await harness.waitForTask(taskID, context);
          await conversation.waitForIdle(context); await session.refreshContext(); await record.archiveQueue;
          if (record.archiveError) throw new DefaultAgentError('The native compaction completed but its archive copy could not be saved. Check runtime storage before continuing.');
          const status = task.state.outcome.status;
          record.lastCommandOutcome = status === 'completed' ? 'end_turn' : status === 'aborted' ? 'cancelled' : 'failed';
          if (!['completed', 'aborted'].includes(status)) throw new DefaultAgentError(task.state.outcome.error?.message ?? 'Native compaction did not complete.');
          return;
        }
        let requestId;
        const priorReceipt = (await harness.snapshot(Requests, conversation.id, context))?.requests?.[logicalID];
        if (priorReceipt?.nativeRequestIDs?.length && !record.allowFallback) requestId = priorReceipt.nativeRequestIDs.at(-1);
        else requestId = `${logicalID}:attempt:${priorReceipt?.nativeRequestIDs?.length ?? 0}`;
        const fingerprint = digest({ content });
        engine.sessions.get(sessionID)?.promptController?.signal.throwIfAborted();
        const settled = await conversation.commit(async tx => { const receipts = await tx.doc(Requests, conversation.id); const existing = receipts.requests[logicalID]; if (existing && existing.fingerprint !== fingerprint) throw new DefaultAgentError('This run identifier belongs to a different request.'); receipts.requests[logicalID] ??= { fingerprint };
          const receipt = receipts.requests[logicalID]; receipt.nativeRequestIDs ??= []; if (!receipt.nativeRequestIDs.includes(requestId)) receipt.nativeRequestIDs.push(requestId);
          const native = await tx.submissionByRequest(conversation.id, requestId); return native?.status === 'done' || native?.status === 'unanswered'; }, context);
        const submission = await conversation.submit({ type: 'input', content: typeof content === 'string' ? [{ type: 'text', text: content }] : content, requestId, whenBusy: opts.streamingBehavior === 'steer' ? 'steer' : 'reject' }, context);
        opts.preflightResult?.('started');
        const receipt = await submission.wait(context);
        if (!settled && receipt.answer !== undefined) while (!knownEntries.has(receipt.answer)) { if (record.eventClosed) throw new DefaultAgentError('The native event stream closed before its final answer. Check runtime storage before continuing.'); await new Promise(resolve => setImmediate(resolve)); }
        // Native background ownership lets the parent keep working while its
        // children run. ACP/remote completion stays attached until their native
        // reporters and any parent reaction have settled too.
        if (opts.streamingBehavior !== 'steer') await record.subagents.waitAttached();
        await session.refreshContext(); await record.archiveQueue;
        if (record.archiveError) throw new DefaultAgentError('The native run completed but its archive copy could not be saved. Check runtime storage before continuing.');
        if (receipt.status === 'unanswered' && receipt.reason !== 'aborted') throw new DefaultAgentError(record.lastError ?? receipt.detail?.message ?? 'The model request failed.');
      },
    };
    record.session = session;
    await session.refreshContext();
    eventStream = await watchEvents(harness, conversation.id, context);
    void eventStream.closed.then(() => { record.eventClosed = true; });
    const knownEntries = new Set(eventStream.snapshot.entries.map(e => e.id));
    let blocks = new Map(), completedAssistantText = '', messageOpen = false, messageSequence = 0;
    const visibleText = value => [...value].sort(([a], [b]) => a - b).map(([, block]) => block.type === 'text' ? block.text : '').join('');
    const reconcileBlocks = next => {
      const previousText = visibleText(blocks), text = visibleText(next);
      for (const index of new Set([...blocks.keys(), ...next.keys()])) {
        const previous = blocks.get(index)?.type === 'thinking' ? blocks.get(index).thinking : '';
        const value = next.get(index)?.type === 'thinking' ? next.get(index).thinking : '';
        if (value === previous) continue;
        const replaces = !value.startsWith(previous);
        send({ sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: replaces ? value : value.slice(previous.length) },
          _meta: { wovenThoughtID: `built-in-${messageSequence}-${index}`, ...(replaces ? { wovenThoughtSnapshot: true } : {}) } });
      }
      blocks = next;
      if (text === previousText) return;
      const replaces = !text.startsWith(previousText);
      send({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: replaces ? completedAssistantText + text : text.slice(previousText.length) },
        ...(replaces ? { _meta: { wovenAssistantSnapshot: true } } : {}) });
    };
    const reconcileBlock = (block, index) => { const next = new Map(blocks); next.set(index, block); reconcileBlocks(next); };
    const beginMessage = () => { blocks = new Map(); messageOpen = true; messageSequence++; };
    const reconcileMessage = message => {
      if (message.role !== 'assistant') return;
      if (!messageOpen) beginMessage();
      reconcileBlocks(new Map(message.content.map((block, index) => [index, block])));
    };
    const endEntry = entry => {
      knownEntries.add(entry.id);
      for (const message of entry.model ?? []) {
        reconcileMessage(message);
        if (message.role === 'assistant') {
          if (message.stopReason === 'error') record.lastError = message.errorMessage;
          if (message.usage) for (const listener of listeners) listener({ usage: message.usage });
          completedAssistantText += visibleText(blocks);
          send({ sessionUpdate: 'woven_assistant_boundary' });
          messageOpen = false;
        }
        // watchEvents is scoped to the root conversation. Child results remain
        // in their native archive/subagent activity and cannot update this plan.
        if (message.role === 'toolResult' && message.toolName === checklistTool.name && message.isError === false && Array.isArray(message.details?.wovenChecklist)) {
          const entries = message.details.wovenChecklist;
          send({ sessionUpdate: 'plan', entries, _meta: { wovenPlanKind: 'checklist', wovenPlanOperation: entries.length ? 'replace' : 'clear' } });
        }
      }
    };
    eventStream.start(async events => {
      for (const event of events) {
        if (event.type === 'message_start') { if (event.message.role === 'assistant') beginMessage(); reconcileMessage(event.message); }
        else if (event.type === 'message_update') for (const change of event.changes) {
          if (change.type === 'message') reconcileMessage(change.message);
          else if (change.block) reconcileBlock(change.block, change.contentIndex);
          else if (change.type === 'text_delta' || change.type === 'thinking_delta') {
            const type = change.type === 'text_delta' ? 'text' : 'thinking';
            reconcileBlock({ type, [type]: (blocks.get(change.contentIndex)?.[type] ?? '') + change.delta }, change.contentIndex);
          }
        }
        else if (event.type === 'message_end') endEntry(event.entry);
        else if (event.type === 'snapshot') { for (const entry of event.entries) if (!knownEntries.has(entry.id)) endEntry(entry); if (event.generation?.message) reconcileMessage(event.generation.message); }
        else if (event.type === 'tool_execution_start') send({ sessionUpdate: 'tool_call', toolCallId: event.toolCallId, title: event.toolName, kind: event.toolName === 'bash' ? 'execute' : 'other', status: 'in_progress', rawInput: event.args });
        else if (event.type === 'tool_execution_update') send({ sessionUpdate: 'tool_call_update', toolCallId: event.toolCallId, status: 'in_progress', rawOutput: event });
        else if (event.type === 'tool_execution_end') { const message = event.entry?.model?.[0]; send({ sessionUpdate: 'tool_call_update', toolCallId: event.toolCallId, status: !message || message.isError ? 'failed' : 'completed', content: (message?.content ?? []).map(content => ({ type: 'content', content })) }); }
      }
    });
    record.contextLeaf = async () => (await conversation.context(context)).entries.at(-1)?.id;
    record.saveOptions = data => { record.configurationQueue = (record.configurationQueue ?? Promise.resolve()).then(() => conversation.commit(async tx => Object.assign(await tx.doc(Options, conversation.id), data), context)); };
    record.rewind = async leaf => { const entries = (await conversation.context(context)).entries.filter(e => leaf === undefined || e.id > leaf); await conversation.commit(tx => tx.appendEntry(conversation.id, { kind: 'woven.fallback', edits: entries.map(e => ({ target: e.id, action: 'omit' })) }), context); };
    record.history = async (after = 0, limit = 200) => {
      const validOrdinal = value => Number.isSafeInteger(value) && value >= 0;
      const validCursor = validOrdinal(after) || after && typeof after === 'object' && Object.keys(after).length === 2 && validOrdinal(after.record) && validOrdinal(after.byteOffset);
      if (!validCursor || !Number.isSafeInteger(limit) || limit < 1 || limit > 200) throw new DefaultAgentError('Invalid native history cursor.');
      await record.archiveQueue;
      if (record.archiveError) throw new DefaultAgentError('The native archive copy could not be saved. Check runtime storage before continuing.');
      const page = await archiveStore.page(after, limit); return { recordBatch: batch(page.records), nextAfter: page.nextAfter, hasMore: page.hasMore };
    };
    record.waitIdle = async () => {
      await record.configurationQueue;
      harness.resume();
      while (true) {
        const inspection = await harness.inspect(context);
        if (!inspection.tasks.length && !inspection.submissions.length) break;
        await new Promise(resolve => setTimeout(resolve, 25));
      }
      await session.refreshContext(); await record.archiveQueue;
      if (record.archiveError) throw new DefaultAgentError('The native archive copy could not be saved. Check runtime storage before continuing.');
      return { idle: true };
    };
    record.resumeNative = () => harness.resume();
    await record.subagents.start();
    await record.archiveQueue;
    if (record.lockError) throw new DefaultAgentError('The native session owner lock was lost. Reconnect before continuing.');
    return record;
  } catch (error) {
    if (record?.session) await record.session.dispose().catch(() => {});
    else { await record?.harness?.close(context).catch(() => {}); await release(); }
    throw error;
  }
}
