import { mkdtemp, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { getCurrentSystemPrompt, getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { claudeExecutable, claudeProviders } from './claude-runtime.mjs';
import { createClaudeAdmission } from './claude-admission.mjs';
import { accessFailure, DefaultAgentError } from './config.mjs';

// Pi owns history, compaction, tools and approvals. The official SDK starts an
// unmodified Claude runtime solely as a model client. Replay/admission follows
// Hermes DirectSDK; see claude-hermes-LICENSE.txt for source and attribution.
const api = 'woven-claude-native';
const prefix = 'mcp__woven__';
const inventoryProgram = fileURLToPath(new URL('./claude-inventory.mjs', import.meta.url));
const zeroCost = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 });

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

export function claudeRequest(context, model) {
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
        if (block.type === 'thinking' && message.api === api && message.provider === model.provider && message.model === model.id && block.thinkingSignature) {
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
  if (frames.at(-1)?.type !== 'user') throw new DefaultAgentError('Claude needs a user message or tool result to continue.');
  return { frames, inventory, names, system: getCurrentSystemPrompt(context.messages) };
}

function safeFailure(error) {
  const reason = accessFailure(error);
  if (reason?.includes('exhausted') || error?.message === 'The connection has exhausted its available usage.') return 'Usage limit reached (usage_limit_reached). Check the Claude account in Settings → Connections.';
  if (reason || error?.message === 'The connection needs sign-in or a valid API key.') return 'Authentication required. Check the Claude connection in Settings → Connections.';
  return error instanceof DefaultAgentError ? error.message : 'Claude could not complete this request. Check Settings → Connections or retry.';
}

function modelDefinitions(claude, provider) {
  return claude.models.map(model => ({
    id: model.value, name: model.displayName, provider, api, baseUrl: 'process://claude-native',
    reasoning: Boolean(model.supportedEffortLevels?.length), input: ['text', 'image'],
    thinkingLevelMap: { off: null, ...Object.fromEntries((model.supportedEffortLevels ?? []).map(level => [level, level])) },
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
      message.errorMessage = options.signal?.aborted ? 'Cancelled.' : safeFailure(error);
      stream.push({ type: 'error', reason: message.stopReason, error: message });
      stream.end(message);
    });
    return stream;

    async function run(model, context, options, message, stream) {
      const request = claudeRequest(context, model);
      const controller = new AbortController();
      const abort = () => controller.abort();
      options.signal?.addEventListener('abort', abort, { once: true });
      if (options.signal?.aborted) controller.abort();
      let directory, gate, query, timer, acknowledge;
      let timedOut = false, started = false, nativeFailure;
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
        controller.signal.throwIfAborted();
        gate = await createClaudeAdmission({ signal: controller.signal, onEvent, ...dependencies.admission });
        directory = await mkdtemp(join(tmpdir(), 'woven-claude-request-'));
        const body = { tools: request.inventory.map(tool => ({ name: prefix + tool.name, description: tool.description, input_schema: tool.inputSchema })) };
        if (options.maxTokens) body.max_tokens = options.maxTokens;
        if (options.reasoning) {
          if (model.reasoning) body.thinking = { type: 'adaptive' };
          body.output_config = { effort: options.reasoning };
        } else { body.thinking = { type: 'disabled' }; body.context_management = { edits: [] }; }
        await Promise.all([
          writeFile(join(directory, 'tools.json'), JSON.stringify(request.inventory), { mode: 0o600 }),
          writeFile(join(directory, 'system.md'), request.system, { mode: 0o600 }),
          writeFile(join(directory, 'settings.json'), JSON.stringify({ env: { CLAUDE_CODE_EXTRA_BODY: JSON.stringify(body) } }), { mode: 0o600 }),
        ]);
        async function* input() {
          for (let index = 0; index < request.frames.length; index++) {
            controller.signal.throwIfAborted();
            const frame = request.frames[index];
            const replay = frame.type === 'user' && index < request.frames.length - 1;
            let waiting;
            if (replay) waiting = new Promise(resolve => { acknowledge = resolve; });
            yield replay ? { ...frame, shouldQuery: false } : frame;
            // SDK 0.3.278 passes native assistant frames unchanged. Historical
            // users require their zero-turn ack before the next replay frame.
            if (waiting) {
              let cancel;
              try {
                await Promise.race([waiting, new Promise(resolve => { cancel = resolve; controller.signal.addEventListener('abort', cancel, { once: true }); })]);
              } finally { controller.signal.removeEventListener('abort', cancel); }
            }
          }
        }
        resetTimeout();
        query = await claude.sdkQuery({ prompt: input(), options: {
          cwd: directory, pathToClaudeCodeExecutable: dependencies.executable ?? claudeExecutable(),
          env: { ...env, ANTHROPIC_BASE_URL: gate.url, ENABLE_TOOL_SEARCH: 'false', CLAUDE_CODE_MAX_RETRIES: '0',
            CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1',
            DISABLE_AUTO_COMPACT: '1', DISABLE_COMPACT: '1', CLAUDE_CODE_TOTAL_TOKENS_REMINDER: 'off',
            ...(options.maxTokens ? { CLAUDE_CODE_MAX_OUTPUT_TOKENS: String(options.maxTokens) } : {}) },
          model: model.id, tools: [], skills: [], settingSources: [], strictMcpConfig: true,
          settings: join(directory, 'settings.json'), extraArgs: { 'system-prompt-file': join(directory, 'system.md'), 'disable-slash-commands': null },
          persistSession: false, maxTurns: 1, permissionMode: 'dontAsk', includePartialMessages: true,
          abortController: controller, stderr: () => {},
          mcpServers: { woven: { command: process.execPath, args: [inventoryProgram, join(directory, 'tools.json')] } },
        } });
        try {
          for await (const event of query) {
            resetTimeout();
            options.signal?.throwIfAborted();
            if (event.type === 'result' && acknowledge) {
              if (event.num_turns !== 0 || event.is_error) throw new DefaultAgentError('The Claude runtime could not restore this conversation.');
              const resolve = acknowledge; acknowledge = undefined; resolve();
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
        if (!gate.state.complete || gate.state.status !== 200 || gate.state.error) {
          if (timedOut) throw new DefaultAgentError('The Claude request timed out. Retry or check Settings → Connections.');
          throw gate.state.error ?? new DefaultAgentError(nativeFailure ? safeFailure(nativeFailure) : 'The Claude runtime stopped before completing its response.');
        }
        const response = gate.state.message;
        const calls = response.content.filter(block => block.type === 'tool_use');
        const usage = response.usage;
        if (!usage || ![usage.input_tokens, usage.output_tokens, usage.cache_read_input_tokens ?? 0, usage.cache_creation_input_tokens ?? 0].every(value => Number.isFinite(value) && value >= 0)) throw new DefaultAgentError('Claude did not report complete response usage.');
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
        message.usage = { input: usage.input_tokens, output: usage.output_tokens, cacheRead: usage.cache_read_input_tokens ?? 0,
          cacheWrite: usage.cache_creation_input_tokens ?? 0, totalTokens: usage.input_tokens + usage.output_tokens + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0), cost: zeroCost() };
        message.rawStopReason = response.stop_reason;
        message.stopReason = calls.length ? 'toolUse' : ['max_tokens', 'model_context_window_exceeded'].includes(response.stop_reason) ? 'length' : 'stop';
      } finally {
        clearTimeout(timer);
        controller.abort(); acknowledge?.(); query?.close();
        options.signal?.removeEventListener('abort', abort);
        await gate?.close();
        if (directory) await rm(directory, { recursive: true, force: true });
      }
    }
  };
}
