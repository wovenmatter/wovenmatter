import { createHash } from 'node:crypto';
import { estimateMessageTokens } from '@earendil-works/pi-ai/utils/estimate';
import { calculateCost } from '@earendil-works/pi-ai/models';
import { defineDoc, UsageDoc } from '@earendil-works/pi-durable';
import { getCurrentSystemMessage } from '@earendil-works/pi-ai/utils/transcript';
import { DefaultAgentError, accessFailure, operationErrorMessage } from './config.mjs';
import { providerFetch } from './transport.mjs';

export const NativeContext = defineDoc({ kind: 'woven.native-context', version: 1, scope: 'conversation', history: 'rewindable', fork: 'current', initial: () => ({ covered: [] }) });
const hash = value => createHash('sha256').update(JSON.stringify(value)).digest('hex');
const sameRoute = (left, right) => left?.provider === right.provider && left.accountID === right.accountID && left.modelID === right.modelID && left.authIdentity === right.authIdentity && left.nativeAccountID === right.nativeAccountID && left.api === right.api && left.endpoint === right.endpoint;
const usable = message => message.role !== 'assistant' || !['aborted', 'error', 'deferred'].includes(message.stopReason);

// SDKs also return transport exceptions as assistant diagnostics instead of
// throwing. Preserve exposed content and usage, and normalize only that error
// diagnostic before it can become a native task/transcript/archive record.
export function safeAssistantDiagnostic(message) {
  return message && ['error', 'aborted'].includes(message.stopReason) && typeof message.errorMessage === 'string'
    ? { ...message, errorMessage: accessFailure(message.errorMessage) ?? operationErrorMessage(undefined) } : message;
}

// A salted credential identity fences an in-place credential replacement without
// persisting tokens. Native profiles have an explicit account identity; unknown
// OAuth products conservatively invalidate on replacement rather than guessing.
export function credentialRouteIdentity(record, account) {
  const credential = account?.credential;
  if (credential?.type === 'native' && credential.accountId) return hash({ store: record.manifest.storeID, nativeAccount: credential.accountId });
  const value = credential?.key ?? credential?.refresh ?? credential?.access;
  return value ? hash({ store: record.manifest.storeID, type: credential.type, value }) : undefined;
}

export function compatibleCanonicalMessages(messages, route) {
  const calls = new Map();
  for (const message of messages) if (message.role === 'assistant' && !sameRoute(message.wovenNativeRoute, route)) for (const block of message.content) if (block.type === 'toolCall' && block.id.includes('|')) calls.set(block.id, block.id.split('|')[0]);
  return messages.map(message => {
    if (message.role === 'toolResult' && calls.has(message.toolCallId)) return { ...message, toolCallId: calls.get(message.toolCallId) };
    if (message.role !== 'assistant') return message;
    const origin = message.wovenNativeRoute;
    if (sameRoute(origin, route)) return message;
    // Readable exposed thinking remains canonical. Provider signatures/item IDs
    // can only be replayed to their proven original route and account.
    return { ...message, content: message.content.map(block => {
      const { thinkingSignature, textSignature, thoughtSignature, ...content } = block;
      return block.type === 'toolCall' && calls.has(block.id) ? { ...content, id: calls.get(block.id) } : content;
    }) };
  });
}

// The rewindable document pairs a lossless native window with its original
// entries, so switching routes can rebuild the visible context.
export function nativeContextBridge(record, engine, background) {
  const filterTools = messages => record.codeModeState.value === 'only' ? messages.map(message => message.role === 'system' ? { ...message, ...(message.toolsAdded ? { toolsAdded: message.toolsAdded.filter(tool => tool.name === 'codemode') } : {}), ...(message.toolsRemoved ? { toolsRemoved: message.toolsRemoved.filter(tool => tool.name === 'codemode') } : {}) } : message) : messages;
  const scope = (route, taskID, canonicalMessages, continuation) => ({
    directory: record.nativeRoot, sessionID: record.session.sessionId,
    provider: route.provider, accountID: route.accountID, modelID: route.modelID,
    authIdentity: route.authIdentity, ...(route.credentialIdentity ? { credentialIdentity: route.credentialIdentity } : {}), ...(route.nativePrincipalIdentity ? { nativePrincipalIdentity: route.nativePrincipalIdentity } : {}), taskID,
    ...(record.busy && record.runID ? { runID: record.runID } : {}),
    canonicalMessages: filterTools(canonicalMessages), ...(continuation ? { continuation } : {}),
    archive: async records => { record.appendArchive(records); await record.archiveQueue; if (record.archiveError) throw record.archiveError; },
  });
  const snapshot = async () => await record.harness.snapshot(NativeContext, record.conversation.id, background) ?? { covered: [] };
  const originalPrefix = async state => {
    const entries = [];
    for (const id of state.covered) {
      const saved = await record.storage.entry(id, background);
      if (!saved) throw new DefaultAgentError('The original native context is unavailable. Its available history remains archived.');
      entries.push(saved.entry);
    }
    // Later active edits (for example an interrupted nested tool) remain
    // authoritative when rebuilding the earlier canonical prefix.
    const active = (await record.conversation.context(background)).entries;
    const edits = new Map([...entries, ...active].flatMap(entry => (entry.edits ?? []).map(edit => [edit.target, edit])));
    return entries.flatMap(entry => {
      if (entry.kind === 'woven.native-compaction') return [];
      const edit = edits.get(entry.id);
      return edit?.action === 'omit' ? [] : (edit?.action === 'replace' ? edit.messages : entry.model ?? []).filter(usable);
    });
  };
  const withoutSummaries = (state, messages) => messages.filter(message => state.summaryHash !== hash(message));
  const canonical = async (state, messages, route) => {
    const active = withoutSummaries(state, messages), system = getCurrentSystemMessage(active);
    const prefix = state.covered.length ? await originalPrefix(state) : [];
    return compatibleCanonicalMessages([...(system ? [system] : []), ...prefix.filter(m => m.role !== 'system'), ...active.filter(m => m.role !== 'system')], route);
  };
  const archiveAttempt = async (kind, response, taskID, model, charge = false) => {
    if (!response) return;
    const identity = hash(response);
    record.appendArchive([{ id: `native-compaction-${kind}:${taskID}:${identity}`, kind: `provider.compaction.${kind}`, payload: JSON.stringify(response), contentMode: 'event', ...(record.busy && record.runID ? { runID: record.runID } : {}) }]);
    await record.archiveQueue;
    if (record.archiveError) throw record.archiveError;
    let parsed; try { parsed = JSON.parse(response.responseJSON ?? response.completedResponseJSON ?? '{}'); } catch { /* Retain malformed native bytes without inventing a result. */ }
    const reported = response.usage ?? parsed?.usage;
    if (charge && reported) await record.conversation.commit(tx => recordUsage(tx, model, reported), background);
  };
  const compact = async (model, delta, full, route, taskID, signal, continuation, instructions) => {
    delta = filterTools(delta); full = filterTools(full);
    const nativeScope = scope(route, taskID, full, continuation);
    const claude = await import('./claude-provider.mjs');
    const operation = async () => {
      const liveRoute = await resolveRoute(route, model, signal);
      if (!sameRoute(liveRoute, route)) throw new DefaultAgentError('The selected native account changed before compaction. Its original context remains available; retry compaction with the current account.');
      if (claude.canUseClaudeNativeCompaction(model)) return await claude.compactClaudeContext(engine.claude, engine.credentials, model, full, { signal, wovenNativeContext: nativeScope, ...(instructions ? { compactionInstructions: instructions } : {}) }) ?? { unsupported: true };
      const provider = await import('./provider-compaction.mjs');
      if (!await provider.resolveProviderCompactionRoute({ model, route, runtime: engine.runtime, signal })) return { unsupported: true };
      const reserve = Math.max(4096, Math.floor((model.contextWindow ?? 200000) * 0.25));
      const budget = (model.contextWindow ?? 200000) - reserve;
      const system = getCurrentSystemMessage(delta), groups = []; let current = [];
      for (const message of delta.filter(message => message.role !== 'system')) {
        if (message.role === 'user' && current.length) { groups.push(current); current = []; }
        current.push(message);
      }
      if (current.length) groups.push(current);
      let window = continuation, active = [], tokens = (system ? estimateMessageTokens(system) : 0) + (continuation ? Math.ceil(JSON.stringify(continuation.output).length / 3) : 0);
      const base = () => (system ? estimateMessageTokens(system) : 0) + (window ? Math.ceil(JSON.stringify(window.output).length / 3) : 0);
      const results = [];
      const send = async messages => {
        let result;
        try { result = await provider.compactProviderContext({ model, context: { messages: [...(system ? [system] : []), ...messages] }, route, runtime: engine.runtime, signal, continuation: window, ...(instructions ? { instructions } : {}), fetchRequest: providerFetch(record, engine.compactionFetch ?? globalThis.fetch) }); }
        catch (error) { await archiveAttempt('interrupted', error.nativeResponse, taskID, model, true); throw error; }
        if (result.unsupported) {
          await archiveAttempt('unsupported', result.nativeResponse, taskID, model, true);
          return result;
        }
        await archiveAttempt('response', result, taskID, model);
        window = result.continuation; results.push(result); return result;
      };
      for (const group of groups) {
        const size = group.reduce((sum, message) => sum + estimateMessageTokens(message), 0);
        if (active.length && tokens + size > budget) { const result = await send(active); if (result.unsupported) return result; active = []; tokens = base(); }
        if (tokens + size > budget) throw new DefaultAgentError('A complete conversation turn exceeds the selected model context window. Select a model with a larger context to preserve the complete tool exchange.');
        active.push(...group); tokens += size;
      }
      if (active.length || !results.length) { const result = await send(active); if (result.unsupported) return result; }
      const last = results.at(-1);
      if (results.length === 1) return last;
      const usages = results.flatMap(result => result.usage ? [result.usage] : []), combined = { input_tokens: 0, output_tokens: 0, total_tokens: 0, input_tokens_details: { cached_tokens: 0, cache_write_tokens: 0 }, output_tokens_details: { reasoning_tokens: 0 } };
      for (const usage of usages) { combined.input_tokens += usage.input_tokens ?? 0; combined.output_tokens += usage.output_tokens ?? 0; combined.total_tokens += usage.total_tokens ?? 0; combined.input_tokens_details.cached_tokens += usage.input_tokens_details?.cached_tokens ?? 0; combined.input_tokens_details.cache_write_tokens += usage.input_tokens_details?.cache_write_tokens ?? 0; combined.output_tokens_details.reasoning_tokens += usage.output_tokens_details?.reasoning_tokens ?? 0; }
      return { ...last, usage: combined };
    };
    const account = (await engine.credentials.candidates(route.provider)).find(candidate => candidate.id === route.accountID);
    return route.provider === 'claude-subscription' && engine.claude.withProfile ? engine.claude.withProfile(account?.credential?.accountId, operation) : operation();
  };
  const portable = async (model, full, signal, taskID, instructions) => {
    const readable = full.map(message => message.role === 'toolResult' ? { role: message.role, toolCallId: message.toolCallId, toolName: message.toolName, content: message.content, isError: message.isError } : message.role === 'assistant' ? { role: message.role, content: message.content.map(block => { const { thinkingSignature, textSignature, thoughtSignature, ...content } = block; return content; }) } : message);
    const result = safeAssistantDiagnostic(await engine.runtime.completeSimple(model, { messages: [
      { role: 'system', content: 'Summarize the supplied conversation for continuing its work. Preserve goals, decisions, tool outcomes, exact identifiers, unresolved work and relevant constraints. Do not invent unavailable content.', timestamp: Date.now() },
      { role: 'user', content: [{ type: 'text', text: JSON.stringify(readable) + (instructions ? `\nAdditional compaction focus: ${instructions}` : '') }], timestamp: Date.now() },
    ] }, { signal, transport: 'sse', maxRetries: 0, fetch: providerFetch(record) }));
    record.appendArchive([{ id: `portable-result:${taskID}:${hash(result)}`, kind: 'pi.compaction.response', payload: JSON.stringify(result), contentMode: 'event', text: result.content.flatMap(block => block.type === 'text' ? [block.text] : block.type === 'thinking' ? [block.thinking] : []).join('\n'), projectionJSON: JSON.stringify([result]), ...(record.busy && record.runID ? { runID: record.runID } : {}) }]);
    await record.archiveQueue; if (record.archiveError) throw record.archiveError;
    if (result.stopReason !== 'stop' || result.content.some(block => block.type === 'toolCall')) throw new DefaultAgentError(result.errorMessage ?? 'Context summarization did not complete.');
    const text = result.content.filter(b => b.type === 'text').map(b => b.text).join('\n');
    if (!text) throw new DefaultAgentError('Context summarization did not return a summary.');
    return { portableMessage: { role: 'user', content: [{ type: 'text', text }], timestamp: Date.now() }, usage: result.usage, portableResponse: result };
  };
  const resolveRoute = async (route, model, signal) => {
    const account = (await engine.credentials.candidates(route.provider)).find(candidate => candidate.id === route.accountID);
    if (!account) throw new DefaultAgentError('The selected account is unavailable. Check Settings → Connections.');
    const authIdentity = credentialRouteIdentity(record, account), next = { ...route };
    if (authIdentity) next.authIdentity = authIdentity; else delete next.authIdentity;
    if (model.api === 'woven-claude-native') {
      next.endpoint = 'claude-agent-sdk';
      if (route.provider === 'claude-subscription') {
        const provider = await import('./claude-provider.mjs');
        const identity = async () => provider.claudePrincipalIdentity(await provider.getClaudeNativePrincipal(engine.claude, { signal, cwd: record.nativeRoot }), { sessionID: record.session.sessionId, accountID: route.accountID, authIdentity });
        const principal = engine.claude.withProfile ? await engine.claude.withProfile(account.credential?.accountId, identity) : await identity();
        if (authIdentity) next.credentialIdentity = authIdentity; next.authIdentity = principal; next.nativePrincipalIdentity = principal;
      }
    }
    else {
      const resolved = await engine.runtime.getAuth(model, { signal, allowWait: false });
      // ModelRuntime owns endpoint routing; the native provider helper performs
      // the additional supported endpoint/native account validation.
      next.endpoint = resolved?.auth?.baseUrl ?? model.baseUrl;
      const identity = await (await import('./provider-compaction.mjs')).resolveProviderCompactionRoute({ model, route: next, runtime: engine.runtime, signal });
      if (identity) Object.assign(next, identity);
    }
    return next;
  };
  const recordUsage = async (tx, model, reported) => {
    if (!reported) return;
    const cached = reported.input_tokens_details?.cached_tokens ?? 0, write = reported.input_tokens_details?.cache_write_tokens ?? 0;
    const usage = reported.input !== undefined ? structuredClone(reported) : { input: Math.max(0, (reported.input_tokens ?? 0) - cached - write), output: reported.output_tokens ?? 0, cacheRead: cached, cacheWrite: write, totalTokens: reported.total_tokens ?? (reported.input_tokens ?? 0) + (reported.output_tokens ?? 0), ...(reported.output_tokens_details?.reasoning_tokens === undefined ? {} : { reasoning: reported.output_tokens_details.reasoning_tokens }), cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };
    if (reported.input === undefined) calculateCost(model, usage);
    const totals = (await tx.doc(UsageDoc, record.conversation.id)).models, modelKey = `${model.provider}/${model.id}`;
    if (!Object.hasOwn(totals, modelKey)) totals[modelKey] = usage;
    else { const total = totals[modelKey]; for (const field of ['input', 'output', 'cacheRead', 'cacheWrite', 'totalTokens', 'reasoning', 'cacheWrite1h']) if (usage[field] !== undefined) total[field] = (total[field] ?? 0) + usage[field]; for (const field of ['input', 'output', 'cacheRead', 'cacheWrite', 'total']) total.cost[field] += usage.cost[field] ?? 0; }
    record.reportUsage?.(usage);
  };
  return {
    resolveRoute, filterTools,
    async beforeCompact(compaction, originalRoute, api, ctx) {
      const model = engine.resolveModel(`${originalRoute.provider}/${originalRoute.modelID}`);
      const route = await resolveRoute(originalRoute, model, ctx.abortSignal), saved = await snapshot();
      const full = await canonical(saved, compaction.messages, route);
      const prior = sameRoute(saved.active?.route, route) ? saved.active.continuation : undefined;
      const delta = prior ? compatibleCanonicalMessages(withoutSummaries(saved, compaction.messages), route) : full;
      let result = await compact(model, delta, full, route, api.taskId, ctx.abortSignal, prior, compaction.instructions);
      if (result.unsupported) result = await portable(model, full, ctx.abortSignal, api.taskId, compaction.instructions);
      const state = { covered: [...new Set([...saved.covered, ...compaction.entries.map(entry => entry.id)])],
        active: { route, ...(result.continuation ? { continuation: result.continuation } : {}), ...(result.portableMessage ? { portableMessage: result.portableMessage } : {}) },
        ...(result.portableMessage ? { summaryHash: hash(result.portableMessage) } : {}) };
      await record.conversation.commit(async tx => {
        await tx.appendEntry(record.conversation.id, { kind: 'woven.native-compaction', head: compaction.firstKept,
          model: [...(getCurrentSystemMessage(compaction.messages) ? [getCurrentSystemMessage(compaction.messages)] : []), ...(result.portableMessage ? [result.portableMessage] : [])],
          data: { ...(record.busy && record.runID ? { wovenRunID: record.runID } : {}), ...(result.usage ? { usage: result.usage } : {}), ...(result.portableResponse ? { portableResponse: result.portableResponse } : {}) } });
        const current = await tx.doc(NativeContext, record.conversation.id);
        delete current.summaryHash;
        Object.assign(current, state);
        await recordUsage(tx, model, result.usage);
      }, ctx);
      return { decline: true };
    },
    async prepare(messages, originalRoute, taskID, ctx) {
      const model = engine.resolveModel(`${originalRoute.provider}/${originalRoute.modelID}`);
      const route = await resolveRoute(originalRoute, model, ctx.abortSignal), state = await snapshot();
      const canonicalMessages = await canonical(state, messages, route);
      let continuation = sameRoute(state.active?.route, route) ? state.active.continuation : undefined;
      let portableMessage = sameRoute(state.active?.route, route) ? state.active.portableMessage : undefined;
      if (continuation && continuation.kind !== 'claude-sdk') {
        try { await (await import('./provider-compaction.mjs')).providerContinuationOptions({ model, route, runtime: engine.runtime, signal: ctx.abortSignal, continuation }); }
        catch (error) { if (error.code !== 'route-mismatch') throw error; continuation = undefined; }
      }
      if (state.covered.length && !continuation && !portableMessage) {
        const prefix = await originalPrefix(state), system = getCurrentSystemMessage(messages);
        const full = compatibleCanonicalMessages([...(system ? [system] : []), ...prefix.filter(m => m.role !== 'system')], route);
        let result = await compact(model, full, full, route, taskID, ctx.abortSignal);
        if (result.unsupported) result = await portable(model, full, ctx.abortSignal, taskID);
        continuation = result.continuation; portableMessage = result.portableMessage;
        await record.conversation.commit(async tx => {
          const current = await tx.doc(NativeContext, record.conversation.id);
          current.active = { route, ...(continuation ? { continuation } : {}), ...(portableMessage ? { portableMessage } : {}) };
          if (portableMessage) current.summaryHash = hash(portableMessage);
          else delete current.summaryHash;
          if (result.portableResponse) await tx.appendEntry(record.conversation.id, { kind: 'woven.portable-context-response', data: { response: result.portableResponse }, model: [] });
          await recordUsage(tx, model, result.usage);
        }, ctx);
      }
      const active = compatibleCanonicalMessages(withoutSummaries(state, messages), route);
      const system = getCurrentSystemMessage(active);
      const projected = portableMessage ? [...(system ? [system] : []), portableMessage, ...active.filter(m => m.role !== 'system')] : continuation ? active : canonicalMessages;
      const transportOptions = continuation && continuation.kind !== 'claude-sdk' ? await (await import('./provider-compaction.mjs')).providerContinuationOptions({ model, route, runtime: engine.runtime, signal: ctx.abortSignal, continuation }) : {};
      return { messages: projected, route, options: { ...transportOptions, wovenNativeContext: scope(route, taskID, canonicalMessages, continuation) }, continuation };
    },
    async requestOptions(model, prepared, signal) {
      if (!prepared?.continuation || prepared.continuation.kind === 'claude-sdk') return prepared?.options ?? {};
      const provider = await import('./provider-compaction.mjs');
      return { ...prepared.options, ...await provider.providerContinuationOptions({ model, route: await resolveRoute(prepared.route, model, signal), runtime: engine.runtime, signal, continuation: prepared.continuation }) };
    },
  };
}
