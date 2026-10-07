import { writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash, randomUUID } from 'node:crypto';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { getCurrentSystemPrompt, getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { claudeExecutable, claudeProviders } from './claude-runtime.mjs';
import { createClaudeAdmission } from './claude-admission.mjs';
import { accessFailure, DefaultAgentError, operationErrorMessage } from './config.mjs';
import { claudeModelName } from './model-presentation.mjs';
import { canUseClaudeNativeCompaction, openClaudeSession } from './claude-session.mjs';
import { contextOverflowDiagnostic } from './native-context.mjs';
export { canUseClaudeNativeCompaction } from './claude-session.mjs';

// Pi owns the agent loop and tools. Claude's official SDK owns its native
// context, compaction and persistence; its supported transcript callback copies
// exposed native records to the central archive. Replay/admission follows
// Hermes DirectSDK; see claude-hermes-LICENSE.txt for source and attribution.
const api = 'woven-claude-native';
const prefix = 'mcp__woven__';
const inventoryProgram = fileURLToPath(new URL('./claude-inventory.mjs', import.meta.url));
const zeroCost = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 });

function principalMetadata(info) {
  if (info?.apiProvider !== 'firstParty' || typeof info.email !== 'string' || !info.email.trim()) {
    throw new DefaultAgentError('Claude could not establish the signed-in account for native context. Refresh its connection before continuing.');
  }
  return { email: info.email.trim().toLowerCase(), organization: typeof info.organization === 'string' ? info.organization : null, apiProvider: info.apiProvider };
}

export function claudePrincipalIdentity(principal, scope) {
  return createHash('sha256').update(JSON.stringify({ sessionID: scope.sessionID, accountID: scope.accountID,
    credentialIdentity: scope.authIdentity ?? null, principal: principalMetadata(principal) })).digest('hex');
}

export async function getClaudeNativePrincipal(claude, { signal, environment, cwd, executable } = {}) {
  signal?.throwIfAborted();
  const controller = new AbortController(), abort = () => controller.abort(signal?.reason);
  signal?.addEventListener('abort', abort, { once: true });
  const timer = setTimeout(() => controller.abort(), 15000); timer.unref?.();
  let session;
  try {
    async function* input() { if (!controller.signal.aborted) await new Promise(resolve => controller.signal.addEventListener('abort', resolve, { once: true })); }
    session = await claude.sdkQuery({ prompt: input(), options: {
      cwd: cwd ?? claude.directory, pathToClaudeCodeExecutable: executable ?? claudeExecutable(),
      env: { ...environment ?? await claude.environment(undefined), CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1' },
      tools: [], skills: [], settingSources: [], strictMcpConfig: true, mcpServers: {}, persistSession: false, abortController: controller,
    } });
    if (typeof session.accountInfo !== 'function') throw new DefaultAgentError('Claude native account identity is unavailable. Update or refresh its connection before continuing.');
    let cancel;
    const info = await Promise.race([session.accountInfo(), new Promise((_, reject) => {
      cancel = () => reject(controller.signal.reason); controller.signal.addEventListener('abort', cancel, { once: true });
      if (controller.signal.aborted) cancel();
    })]).finally(() => controller.signal.removeEventListener('abort', cancel));
    controller.signal.throwIfAborted();
    return principalMetadata(info);
  } finally {
    signal?.removeEventListener('abort', abort); clearTimeout(timer); controller.abort(); session?.close();
  }
}

function combinedUsage(responses) {
  const usage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: zeroCost() };
  for (const response of responses) {
    const native = response?.usage;
    if (!native || ![native.input_tokens, native.output_tokens, native.cache_read_input_tokens ?? 0, native.cache_creation_input_tokens ?? 0]
      .every(value => Number.isFinite(value) && value >= 0)) throw new DefaultAgentError('Claude did not report complete response usage.');
    usage.input += native.input_tokens; usage.output += native.output_tokens;
    usage.cacheRead += native.cache_read_input_tokens ?? 0; usage.cacheWrite += native.cache_creation_input_tokens ?? 0;
  }
  usage.totalTokens = usage.input + usage.output + usage.cacheRead + usage.cacheWrite;
  return usage;
}

export async function compactClaudeContext(claude, credentials, model, messages, options = {}, dependencies = {}) {
  if (!canUseClaudeNativeCompaction(model)) return undefined;
  if (!options.wovenNativeContext) throw new DefaultAgentError('Claude native compaction requires its durable execution scope.');
  const result = await createClaudeStream(claude, credentials, dependencies)(model, { messages }, { ...options, wovenCompact: true }).result();
  if (result.stopReason === 'error' || result.stopReason === 'aborted') throw new DefaultAgentError(result.errorMessage ?? 'Claude native compaction failed.');
  if (!result.wovenNativeCompaction) throw new DefaultAgentError('Claude native compaction did not retain its native context.');
  return result.wovenNativeCompaction;
}

function nativeToolID(value) {
  if (typeof value !== 'string' || !value) throw new DefaultAgentError('This conversation has an invalid tool call identity.');
  if (/^[A-Za-z0-9_-]{1,64}$/.test(value)) return value;
  return value.replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 47) + '_' + createHash('sha256').update(value).digest('hex').slice(0, 16);
}

function contentBlocks(content) {
  if (typeof content === 'string') return content ? [{ type: 'text', text: content }] : [];
  return (content ?? []).flatMap(block => {
    if (block.type === 'text') return [{ type: 'text', text: block.text }];
    if (block.type === 'image') return [{ type: 'image', source: { type: 'base64', media_type: block.mimeType, data: block.data } }];
    throw new DefaultAgentError('This conversation contains content the Claude runtime cannot replay.');
  });
}

export function claudeRequest(context, model, { accountID, authIdentity, compact = false } = {}) {
  const tools = getCurrentTools(context.messages);
  const names = new Set();
  const inventory = tools.map(tool => {
    if (!/^[A-Za-z0-9_-]{1,50}$/.test(tool.name) || names.has(tool.name)) throw new DefaultAgentError('A tool has an unsupported Claude tool name.');
    names.add(tool.name);
    return { name: tool.name, description: tool.description, inputSchema: JSON.parse(JSON.stringify(tool.parameters)) };
  });
  const frames = [];
  for (const message of context.messages) {
    if (message.role === 'system') continue;
    let role = message.role, content;
    if (role === 'assistant') {
      content = message.content.flatMap(block => {
        if (block.type === 'text') return block.text ? [{ type: 'text', text: block.text }] : [];
        if (block.type === 'toolCall') return [{ type: 'tool_use', id: nativeToolID(block.id), name: prefix + block.name, input: block.arguments }];
        // Signed thinking is only valid for unchanged native Claude history on
        // the same route. Cross-engine/model history replays visible content.
        if (block.type === 'thinking' && message.api === api && message.provider === model.provider && message.model === model.id &&
            (accountID === undefined || (message.wovenNativeAccountID ?? message.wovenNativeRoute?.accountID) === accountID) && block.thinkingSignature) {
          if (authIdentity !== undefined && (message.wovenNativeAuthIdentity ?? message.wovenNativeRoute?.authIdentity) !== authIdentity) return [];
          return [block.redacted ? { type: 'redacted_thinking', data: block.thinkingSignature } : { type: 'thinking', thinking: block.thinking, signature: block.thinkingSignature }];
        }
        return [];
      });
    } else if (role === 'toolResult') {
      role = 'user';
      content = [{ type: 'tool_result', tool_use_id: nativeToolID(message.toolCallId), content: contentBlocks(message.content), is_error: message.isError === true }];
    } else if (role === 'user') content = contentBlocks(message.content);
    else throw new DefaultAgentError('This conversation contains a message the Claude runtime cannot replay.');
    if (!content.length) continue;
    if (role === 'user' && frames.at(-1)?.type === role) frames.at(-1).message.content.push(...content);
    else frames.push({ type: role, message: { role, content }, parent_tool_use_id: null, session_id: '' });
  }
  if (!compact && frames.at(-1)?.type !== 'user') throw new DefaultAgentError('Claude needs a user message or tool result to continue.');
  return { frames, inventory, names, system: getCurrentSystemPrompt(context.messages) };
}

function modelDefinitions(claude, provider) {
  return claude.models.map(model => ({
    id: model.value, name: claudeModelName(model), provider, api, baseUrl: 'process://claude-native',
    reasoning: Boolean(model.supportedEffortLevels?.length), input: ['text', 'image'],
    thinkingLevelMap: Object.fromEntries(['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].map(level => [level,
      level === 'off' || model.supportedEffortLevels?.includes(level) ? level : null])),
    // Discovery does not currently report context length. Use a conservative
    // host compaction budget instead of inventing a 1M entitlement for aliases.
    contextWindow: 200000, maxTokens: 32000, cost: zeroCost(),
  }));
}

export function registerClaudeProviders(modelRuntime, claude, credentials) {
  for (const provider of claudeProviders) {
    const subscription = provider === 'claude-subscription';
    const stream = createClaudeStream(claude, credentials);
    modelRuntime.registerNativeProvider({
      id: provider, name: subscription ? 'Claude subscription' : 'Claude API key',
      auth: { apiKey: {
        name: subscription ? 'Native Claude sign-in' : 'Claude API key',
        // Pi's ambient-auth interface does not require an exported secret.
        // This declares the ambient auth route, not a verified connection.
        // Account status is checked explicitly by Connections/new-session setup;
        // catalog refreshes and request-time resolution never spawn auth checks.
        check: async () => subscription ? { type: 'oauth', source: 'Claude runtime' } :
          (await credentials.read(provider))?.key ? { type: 'api_key', source: 'Woven Matter' } : undefined,
        resolve: async () => subscription ? { auth: {}, source: 'Claude runtime' } :
          (await credentials.read(provider))?.key ? { auth: {}, source: 'Woven Matter' } : undefined,
      } },
      getModels: () => modelDefinitions(claude, provider),
      stream, streamSimple: stream,
    });
  }
}

// `dependencies` is solely for provider-free protocol fixtures. Production
// always connects the local admission gate to Anthropic's HTTPS endpoint.
export function createClaudeStream(claude, credentials, dependencies = {}) {
  return (model, context, options = {}) => {
    const stream = createAssistantMessageEventStream();
    const message = { role: 'assistant', api, provider: model.provider, model: model.id, content: [],
      timestamp: Date.now(), stopReason: 'stop', usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: zeroCost() } };
    void run(model, context, options, message, stream).then(() => {
      stream.push({ type: 'done', reason: message.stopReason, message });
      stream.end(message);
    }).catch(error => {
      message.stopReason = options.signal?.aborted ? 'aborted' : 'error';
      message.errorMessage = options.signal?.aborted ? 'Cancelled.' : (accessFailure(error) ?? contextOverflowDiagnostic(error, model.provider) ?? operationErrorMessage(error));
      stream.push({ type: 'error', reason: message.stopReason, error: message });
      stream.end(message);
    });
    return stream;

    async function run(model, context, options, message, stream) {
      const compact = options.wovenCompact === true;
      let nativeContext = options.wovenNativeContext;
      if (!nativeContext) throw new DefaultAgentError('Claude inference requires its durable execution scope.');
      if (model.provider === 'claude-subscription') {
        const credentialIdentity = nativeContext.credentialIdentity ?? nativeContext.authIdentity;
        const principal = nativeContext.nativePrincipalIdentity ?? claudePrincipalIdentity(await getClaudeNativePrincipal(claude,
          { signal: options.signal, cwd: nativeContext.directory, executable: dependencies.executable }), { ...nativeContext, authIdentity: credentialIdentity });
        nativeContext = { ...nativeContext, credentialIdentity, nativePrincipalIdentity: principal, authIdentity: principal };
        options = { ...options, wovenNativeContext: nativeContext };
      }
      const request = claudeRequest(nativeContext?.canonicalMessages ? { messages: nativeContext.canonicalMessages } : context, model,
        { accountID: nativeContext?.accountID, authIdentity: nativeContext?.authIdentity, compact });
      message.wovenNativeAccountID = nativeContext.accountID;
      if (nativeContext?.authIdentity) message.wovenNativeAuthIdentity = nativeContext.authIdentity;
      const controller = new AbortController();
      const abort = () => controller.abort();
      options.signal?.addEventListener('abort', abort, { once: true });
      if (options.signal?.aborted) controller.abort();
      let directory, gate, query, timer, acknowledge, acknowledgementKind, native;
      let compactSummary, compactBoundary, captureFailure, requestOrdinal = 0, compactionCount = 0, replayCompactCount;
      const requestID = randomUUID();
      let timedOut = false, started = false, nativeFailure;
      const nativeInputReady = Promise.withResolvers();
      const verifyQueryPrincipal = async () => {
        if (!nativeContext?.nativePrincipalIdentity) return;
        if (!query || typeof query.accountInfo !== 'function') throw new DefaultAgentError('Claude native account identity is unavailable for this request.');
        const actual = claudePrincipalIdentity(await query.accountInfo(), { ...nativeContext, authIdentity: nativeContext.credentialIdentity });
        if (actual !== nativeContext.nativePrincipalIdentity) throw new DefaultAgentError('The signed-in Claude account changed. Its original native context remains archived; refresh the connection before continuing.');
      };
      const indices = new Map();
      const resetTimeout = () => {
        clearTimeout(timer);
        timer = setTimeout(() => { timedOut = true; controller.abort(); }, dependencies.timeoutMs ?? 180000);
        timer.unref?.();
      };
      const onEvent = event => {
        resetTimeout();
        if (!started && event.type === 'message_start') {
          started = true; message.responseId = event.message.id; message.responseModel = event.message.model;
          stream.push({ type: 'start', partial: message });
        }
        if (event.type === 'content_block_start') {
          const block = event.content_block;
          if (block.type === 'text' || block.type === 'thinking' || block.type === 'redacted_thinking') {
            const index = message.content.length; indices.set(event.index, index);
            message.content.push(block.type === 'text' ? { type: 'text', text: block.text ?? '' } :
              { type: 'thinking', thinking: block.thinking ?? '', ...(block.type === 'redacted_thinking' ? { redacted: true, thinkingSignature: block.data } : {}) });
            stream.push({ type: block.type === 'text' ? 'text_start' : 'thinking_start', contentIndex: index, partial: message });
          }
        } else if (event.type === 'content_block_delta' && indices.has(event.index)) {
          const index = indices.get(event.index), block = message.content[index], delta = event.delta;
          if (delta.type === 'text_delta' || delta.type === 'thinking_delta') {
            const field = delta.type === 'text_delta' ? 'text' : 'thinking'; block[field] += delta[field];
            stream.push({ type: field === 'text' ? 'text_delta' : 'thinking_delta', contentIndex: index, delta: delta[field], partial: message });
          } else if (delta.type === 'signature_delta') block.thinkingSignature = (block.thinkingSignature ?? '') + delta.signature;
        } else if (event.type === 'content_block_stop' && indices.has(event.index)) {
          const index = indices.get(event.index), block = message.content[index];
          stream.push({ type: block.type === 'text' ? 'text_end' : 'thinking_end', contentIndex: index, content: block.text ?? block.thinking, partial: message });
        }
      };
      try {
        controller.signal.throwIfAborted();
        const credential = model.provider === 'anthropic' ? await credentials.read('anthropic') : undefined;
        if (model.provider === 'anthropic' && !credential?.key) throw new DefaultAgentError('Authentication required. Add a Claude API key in Settings → Connections.');
        const env = await claude.environment(credential?.key);
        // The host owns compaction policy. An inherited flag from the former
        // ephemeral bridge must not disable native SDK context maintenance.
        delete env.DISABLE_AUTO_COMPACT; delete env.DISABLE_COMPACT;
        controller.signal.throwIfAborted();
        native = await openClaudeSession(model, request, options);
        gate = await createClaudeAdmission({ signal: controller.signal, onEvent, compactOnly: compact,
          onRequest: async (body, purpose) => {
            await verifyQueryPrincipal();
            if (nativeContext.archive) await nativeContext.archive([{ id: `claude-sdk:request:${requestID}:${requestOrdinal++}`,
              kind: `claude.sdk.${purpose}.request`, payload: body.toString('utf8'), contentMode: 'event', ...(nativeContext.runID ? { runID: nativeContext.runID } : {}) }]);
          },
          onResponse: async (response, purpose) => {
            if (nativeContext.archive) await nativeContext.archive([{ id: `claude-sdk:response:${response.id}`, kind: `claude.sdk.${purpose}.response`,
              payload: JSON.stringify(response), contentMode: 'event', ...(nativeContext.runID ? { runID: nativeContext.runID } : {}),
              text: response.content.filter(block => ['text', 'thinking'].includes(block.type)).map(block => block.text ?? block.thinking).join('\n'),
              projectionJSON: JSON.stringify(response) }]);
          }, ...dependencies.admission });
        directory = native.workspace;
        const body = { tools: request.inventory.map(tool => ({ name: prefix + tool.name, description: tool.description, input_schema: tool.inputSchema })) };
        if (options.maxTokens) body.max_tokens = options.maxTokens;
        if (options.reasoning) {
          if (model.reasoning) body.thinking = { type: 'adaptive' };
          body.output_config = { effort: options.reasoning };
        } else body.thinking = { type: 'disabled' };
        await writeFile(join(directory, 'tools.json'), JSON.stringify(request.inventory), { mode: 0o600 });
        async function* input() {
          // Resume options may already identify an old native transcript. Hold
          // every canonical replay frame and the new prompt until this exact
          // SDK process confirms the live account, before any model request.
          if (nativeContext?.nativePrincipalIdentity) await nativeInputReady.promise;
          controller.signal.throwIfAborted();
          const frames = native.frames;
          let replayBytes = 0, replayFrames = 0;
          const pendingTools = new Set();
          const nativeWindowBytes = dependencies.replayCompactionBytes ?? Math.max(32768, Math.min(256 * 1024, model.contextWindow ?? 200000));
          async function* compactReplay() {
            replayCompactCount = compactionCount + 1;
            const waiting = new Promise(resolve => { acknowledge = resolve; acknowledgementKind = 'compact'; });
            yield { type: 'user', message: { role: 'user', content: [{ type: 'text', text: '/compact' }] }, parent_tool_use_id: null, session_id: '' };
            let cancel;
            try { await Promise.race([waiting, new Promise(resolve => { cancel = resolve; controller.signal.addEventListener('abort', cancel, { once: true }); })]); }
            finally { controller.signal.removeEventListener('abort', cancel); }
          }
          for (let index = 0; index < frames.length; index++) {
            controller.signal.throwIfAborted();
            const frame = frames[index];
            const replay = frame.type === 'user' && (compact || index < frames.length - 1);
            let waiting;
            if (replay) waiting = new Promise(resolve => { acknowledge = resolve; acknowledgementKind = 'replay'; });
            yield { ...frame, client_composed: true, ...(replay ? { shouldQuery: false } : {}) };
            // SDK 0.3.278 passes native assistant frames unchanged. Historical
            // users require their zero-turn ack before the next replay frame.
            if (waiting) {
              let cancel;
              try {
                await Promise.race([waiting, new Promise(resolve => { cancel = resolve; controller.signal.addEventListener('abort', cancel, { once: true }); })]);
              } finally { controller.signal.removeEventListener('abort', cancel); }
            }
            replayBytes += Buffer.byteLength(JSON.stringify(frame.message)); replayFrames++;
            for (const block of frame.message.content) {
              if (block.type === 'tool_use') pendingTools.add(block.id);
              else if (block.type === 'tool_result') pendingTools.delete(block.tool_use_id);
            }
            const completeBoundary = !pendingTools.size && (frame.type === 'assistant' || frame.message.content.some(block => block.type === 'tool_result'));
            if (index < frames.length - 1 && replayBytes >= nativeWindowBytes && replayFrames >= 4 && completeBoundary) {
              yield* compactReplay(); replayBytes = 0; replayFrames = 0;
            }
          }
          if (compact) yield { type: 'user', message: { role: 'user', content: [{ type: 'text', text: '/compact' + (options.compactionInstructions ? ' ' + options.compactionInstructions : '') }] }, parent_tool_use_id: null, session_id: '' };
        }
        resetTimeout();
        query = await claude.sdkQuery({ prompt: input(), options: {
          cwd: directory, pathToClaudeCodeExecutable: dependencies.executable ?? claudeExecutable(),
          env: { ...env, ANTHROPIC_BASE_URL: gate.url, CLAUDE_CODE_EXTRA_BODY: JSON.stringify(body), ENABLE_TOOL_SEARCH: 'false', CLAUDE_CODE_MAX_RETRIES: '0',
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1',
            CLAUDE_CODE_TOTAL_TOKENS_REMINDER: 'off',
            ...(options.maxTokens ? { CLAUDE_CODE_MAX_OUTPUT_TOKENS: String(options.maxTokens) } : {}) },
          model: model.id, tools: [], skills: [], settingSources: [], strictMcpConfig: true,
          systemPrompt: { type: 'custom', prompt: request.system, snapshot: false },
          ...native.sdkOptions, maxTurns: 1, permissionMode: 'dontAsk', includePartialMessages: true,
          hooks: {
            PreCompact: [{ hooks: [async () => { gate.beginCompaction(); return {}; }] }],
            PostCompact: [{ hooks: [async event => { compactSummary = event.compact_summary; gate.endCompaction(); return {}; }] }],
          },
          abortController: controller, stderr: () => {},
          mcpServers: { woven: { command: process.execPath, args: [inventoryProgram, join(directory, 'tools.json')] } },
          } });
          await verifyQueryPrincipal();
          nativeInputReady.resolve();
        try {
          for await (const event of query ?? []) {
            resetTimeout();
            options.signal?.throwIfAborted();
            if (event.type === 'system' && event.subtype === 'mirror_error') captureFailure = new DefaultAgentError('Claude transcript archive failed. Its native local transcript remains intact.');
            if (event.type === 'system' && event.subtype === 'compact_boundary') { compactBoundary = event; compactionCount++; }
            if (nativeContext.archive && event.type !== 'auth_status') await nativeContext.archive([{ id: `claude-sdk:event:${event.uuid ?? createHash('sha256').update(JSON.stringify(event)).digest('hex')}`,
              kind: `claude.sdk.event.${event.subtype ?? event.type}`, payload: JSON.stringify(event), contentMode: 'event', ...(nativeContext.runID ? { runID: nativeContext.runID } : {}) }]);
            if (event.type === 'result' && acknowledge) {
              if (event.is_error || acknowledgementKind === 'replay' && event.num_turns !== 0 || acknowledgementKind === 'compact' && compactionCount < replayCompactCount) {
                throw new DefaultAgentError('The Claude runtime could not restore this conversation.');
              }
              const resolve = acknowledge; acknowledge = undefined; acknowledgementKind = undefined; resolve();
            } else if (event.type === 'result' && event.is_error) {
              nativeFailure = [event.api_error_status, event.result, ...(event.errors ?? [])].join(' ');
            } else if (event.type === 'assistant' && event.error) {
              nativeFailure = (event.message?.content ?? []).filter(block => block.type === 'text').map(block => block.text).join(' ');
            }
          }
        } catch (error) {
          if (!gate.state.complete) throw error;
        }
        options.signal?.throwIfAborted();
        if (captureFailure) throw captureFailure;
        if (compact) {
          if (!compactBoundary || !compactSummary || gate.state.error || !gate.state.compactions.length ||
              gate.state.compactions.some(generation => !generation.complete || generation.status !== 200 || generation.error)) {
            throw gate.state.error ?? new DefaultAgentError('Claude native compaction did not commit a resumable context. Its original history remains available.');
          }
          const usage = combinedUsage(gate.state.compactions.map(generation => generation.message));
          const continuation = await native.commit();
          message.wovenNativeCompaction = { continuation, usage };
          return;
        }
        if (!gate.state.complete || gate.state.status !== 200 || gate.state.error) {
          if (timedOut) throw new DefaultAgentError('The Claude request timed out. Retry or check Settings → Connections.');
          throw gate.state.error ?? new DefaultAgentError(nativeFailure ? (accessFailure(nativeFailure) ?? contextOverflowDiagnostic(nativeFailure, model.provider) ?? operationErrorMessage(nativeFailure)) : 'The Claude runtime stopped before completing its response.');
        }
        const response = gate.state.message;
        const calls = response.content.filter(block => block.type === 'tool_use');
        const usage = combinedUsage([...gate.state.compactions.map(generation => generation.message), response]);
        const callIDs = new Set();
        for (const call of calls) {
          if (!call.name.startsWith(prefix) || !request.names.has(call.name.slice(prefix.length)) || !call.id || callIDs.has(call.id) || !call.input || typeof call.input !== 'object' || Array.isArray(call.input)) {
            throw new DefaultAgentError('Claude returned a tool outside the active tool inventory.');
          }
          callIDs.add(call.id);
        }
        message.content = response.content.map(block => {
          if (block.type === 'text') return { type: 'text', text: block.text };
          if (block.type === 'thinking') return { type: 'thinking', thinking: block.thinking, thinkingSignature: block.signature };
          if (block.type === 'redacted_thinking') return { type: 'thinking', thinking: '', redacted: true, thinkingSignature: block.data };
          if (block.type === 'tool_use') return { type: 'toolCall', id: block.id, name: block.name.slice(prefix.length), arguments: block.input };
          throw new DefaultAgentError('Claude returned an unsupported response block.');
        });
        // Publish tool calls only after complete response validation. Native
        // never executes them; Pi applies the host approvals and tool handlers.
        for (const [index, toolCall] of message.content.entries()) {
          if (toolCall.type !== 'toolCall') continue;
          stream.push({ type: 'toolcall_start', contentIndex: index, partial: message });
          stream.push({ type: 'toolcall_end', contentIndex: index, toolCall, partial: message });
        }
        message.usage = usage;
        message.rawStopReason = response.stop_reason;
        message.stopReason = calls.length ? 'toolUse' : ['max_tokens', 'model_context_window_exceeded'].includes(response.stop_reason) ? 'length' : 'stop';
        message.wovenNativeContinuation = await native.commit(response);
      } finally {
        clearTimeout(timer);
        controller.abort(); nativeInputReady.resolve(); acknowledge?.(); query?.close();
        options.signal?.removeEventListener('abort', abort);
        await gate?.close();
      }
    }
  };
}
