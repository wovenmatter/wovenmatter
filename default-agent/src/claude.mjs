import { execFile } from 'node:child_process';
import { createHash } from 'node:crypto';
import { accessSync, constants, statSync } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { delimiter, join } from 'node:path';
import { promisify } from 'node:util';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { getCurrentSystemPrompt, getCurrentTools } from '@earendil-works/pi-ai/utils/transcript';
import { humanMessage } from './rpc.mjs';

// The Claude subscription is the Claude Code sign-in on this machine, used
// through the Claude Agent SDK with its default configuration and the Claude
// Code installed here. Claude keeps its own tokens. Pi keeps the agent loop
// and runs the tools: each model request replays the transcript into a fresh
// SDK query that may make exactly one model request. The request declares
// Pi's tools under Pi's own names, so the model sees exactly the names Pi's
// prompt uses; Claude Code has no tools of its own and runs none.

export const claudeProvider = 'claude-subscription';
// The most of a request body sent in CLAUDE_CODE_EXTRA_BODY, under Linux's
// 128 KiB limit for one environment string. A chat's tools are about 31 KB.
export const maxExtraBody = 120 * 1024;
const api = 'claude-agent-sdk';
const execute = promisify(execFile);
const zeroCost = () => ({ input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 });
// Claude Code's own failure when it has no sign-in ("Not logged in · Please run /login").
const notSignedIn = /not logged in|please run \/login|authentication_failed/i;
const notSignedInMessage = 'Claude Code is not signed in on this machine. Sign in with Claude in Settings → Subscriptions & API Keys.';

// The installed Claude Code: the first executable `claude` on PATH, looked up at each use.
export function claudeExecutable(path = process.env.PATH ?? '') {
  for (const folder of path.split(delimiter)) {
    if (!folder) continue;
    const candidate = join(folder, 'claude');
    try { if (statSync(candidate).isFile()) { accessSync(candidate, constants.X_OK); return candidate; } } catch {}
  }
  throw new Error('Claude Code is not installed on this machine.');
}

// The caller's environment, without anything that would switch Claude away from its own sign-in.
function claudeEnvironment(extra = {}) {
  const env = Object.fromEntries(Object.entries(process.env).filter(([key]) => !/^(ANTHROPIC_|CLAUDECODE$|CLAUDE_CODE_ENTRYPOINT$|CLAUDE_CODE_OAUTH_TOKEN$)/.test(key)));
  return { ...env, CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC: '1', DISABLE_TELEMETRY: '1', DISABLE_ERROR_REPORTING: '1', ...extra };
}

async function sdkQuery(options) {
  const pathToClaudeCodeExecutable = claudeExecutable();
  const { query } = await import('@anthropic-ai/claude-agent-sdk');
  return query({ ...options, options: { ...options.options, pathToClaudeCodeExecutable, mcpServersDelivery: 'argv' } });
}

// Whether Claude Code on this machine is signed in with a Claude subscription. `signedIn` is
// undefined when Claude Code gave no answer (it timed out or printed something unreadable),
// which says nothing either way.
export async function claudeStatus() {
  let executable, stdout;
  try { executable = claudeExecutable(); } catch { return { signedIn: false }; }
  try {
    ({ stdout } = await execute(executable, ['auth', 'status', '--json'], { env: claudeEnvironment(), timeout: 10000, maxBuffer: 65536 }));
  } catch (error) {
    // Signed out, it exits 1 and still prints its status.
    if (!error.stdout) return {};
    stdout = error.stdout;
  }
  try {
    const value = JSON.parse(stdout);
    return { signedIn: value.loggedIn === true && value.authMethod === 'claude.ai', account: typeof value.email === 'string' ? value.email : undefined };
  } catch { return {}; }
}

function modelName(model) {
  const base = model.value.replace(/\[1m\]$/, '').replace(/^claude-/, '');
  const family = base.match(/^[a-z]+/i)?.[0];
  if (!family || base === 'default') return model.displayName;
  const title = family[0].toUpperCase() + family.slice(1).toLowerCase();
  const resolved = typeof model.resolvedModel === 'string' ? model.resolvedModel : model.value;
  const number = resolved.match(new RegExp(`^claude-${family}-(\\d+(?:[-.]\\d{1,2})?)(?:-\\d{8})?(?:\\[1m\\])?$`, 'i'))?.[1];
  return number ? `${title} ${number.replace('-', '.')}` : model.displayName;
}

export function registerClaude(runtime, { dataDirectory, credentials }) {
  const cacheFile = join(dataDirectory, 'claude-models.json');
  const workspace = join(dataDirectory, 'claude-workspace');
  const state = { models: [], loading: undefined };
  const definitions = () => state.models.map(model => ({
    id: model.value, name: modelName(model), provider: claudeProvider, api, baseUrl: 'claude-agent-sdk://local',
    reasoning: Boolean(model.supportedEffortLevels?.length), input: ['text', 'image'],
    thinkingLevelMap: Object.fromEntries(['off', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max'].map(level => [level,
      level === 'off' || model.supportedEffortLevels?.includes(level) ? level : null])),
    contextWindow: 200000, maxTokens: 32000, cost: zeroCost(),
  }));
  const signedIn = async () => Boolean(await credentials.current(claudeProvider));
  const stream = (model, context, options = {}) => claudeStream(model, context, options, workspace);
  runtime.registerNativeProvider({
    id: claudeProvider, name: 'Claude subscription',
    auth: { apiKey: {
      name: 'Claude Code sign-in',
      check: async () => await signedIn() ? { type: 'oauth', source: 'Claude Code' } : undefined,
      resolve: async () => await signedIn() ? { auth: {}, source: 'Claude Code' } : undefined,
    } },
    getModels: definitions, getAllModels: definitions, stream, streamSimple: stream,
  });
  return {
    // The models Claude Code offers this sign-in, cached in the data folder. `refresh` asks
    // Claude Code again; a list it could not give keeps the one there was.
    async loadModels({ refresh = false } = {}) {
      // A refresh asks Claude Code itself, after any load already on its way.
      if (refresh) await state.loading;
      if (state.models.length && !refresh) return;
      state.loading ??= (async () => {
        if (!refresh) {
          try {
            const saved = JSON.parse(await readFile(cacheFile, 'utf8'));
            if (Array.isArray(saved) && saved.length) { state.models = saved; return; }
          } catch {}
        }
        try {
          state.models = await discoverModels(workspace);
          await writeFile(cacheFile, JSON.stringify(state.models), { mode: 0o600 });
        } catch {}
      })().finally(() => { state.loading = undefined; });
      return state.loading;
    },
  };
}

// An empty streaming input starts the runtime without sending a model request.
async function discoverModels(workspace) {
  await mkdir(workspace, { recursive: true, mode: 0o700 });
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 15000);
  async function* input() { await new Promise(resolve => controller.signal.addEventListener('abort', resolve, { once: true })); }
  const session = await sdkQuery({ prompt: input(), options: {
    cwd: workspace, env: claudeEnvironment(), tools: [], settingSources: [], strictMcpConfig: true, mcpServers: {},
    persistSession: false, abortController: controller, stderr: () => {} } });
  try {
    const models = await session.supportedModels();
    if (!Array.isArray(models) || !models.every(model => typeof model?.value === 'string' && typeof model.displayName === 'string')) throw new Error('Claude did not list its models.');
    return models;
  } finally { clearTimeout(timer); controller.abort(); session.close?.(); }
}

const toolID = value => /^[A-Za-z0-9_-]{1,64}$/.test(value) ? value
  : value.replace(/[^A-Za-z0-9_-]/g, '_').slice(0, 47) + '_' + createHash('sha256').update(value).digest('hex').slice(0, 16);

function contentBlocks(content) {
  if (typeof content === 'string') return content ? [{ type: 'text', text: content }] : [];
  return (content ?? []).flatMap(block => block.type === 'text' ? (block.text ? [{ type: 'text', text: block.text }] : [])
    : block.type === 'image' ? [{ type: 'image', source: { type: 'base64', media_type: block.mimeType, data: block.data } }] : []);
}

// Pi's transcript as Claude Agent SDK input frames, plus the tool inventory and system prompt.
export function claudeRequest(context, model) {
  const inventory = getCurrentTools(context.messages).map(tool => ({ name: tool.name, description: tool.description, inputSchema: JSON.parse(JSON.stringify(tool.parameters)) }));
  const frames = [];
  for (const message of context.messages) {
    let role = message.role, content;
    if (role === 'system') continue;
    if (role === 'assistant') {
      content = message.content.flatMap(block => {
        if (block.type === 'text') return block.text ? [{ type: 'text', text: block.text }] : [];
        if (block.type === 'toolCall') return [{ type: 'tool_use', id: toolID(block.id), name: block.name, input: block.arguments }];
        // Signed thinking is valid only for the model that produced it.
        if (block.type === 'thinking' && block.thinkingSignature && message.api === api && message.model === model.id) {
          return [block.redacted ? { type: 'redacted_thinking', data: block.thinkingSignature } : { type: 'thinking', thinking: block.thinking, signature: block.thinkingSignature }];
        }
        return [];
      });
    } else if (role === 'toolResult') {
      role = 'user';
      content = [{ type: 'tool_result', tool_use_id: toolID(message.toolCallId), content: contentBlocks(message.content), is_error: message.isError === true }];
    } else content = contentBlocks(message.content);
    if (!content.length) continue;
    if (role === 'user' && frames.at(-1)?.type === 'user') frames.at(-1).message.content.push(...content);
    else frames.push({ type: role, message: { role, content }, parent_tool_use_id: null, session_id: '' });
  }
  if (frames.at(-1)?.type !== 'user') throw new Error('Claude needs a user message or tool result to answer.');
  return { frames, inventory, system: getCurrentSystemPrompt(context.messages) };
}

function claudeStream(model, context, options, workspace) {
  const stream = createAssistantMessageEventStream();
  const message = { role: 'assistant', api, provider: model.provider, model: model.id, content: [], timestamp: Date.now(), stopReason: 'stop',
    usage: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0, cost: zeroCost() } };
  run().then(() => {
    stream.push({ type: 'done', reason: message.stopReason, message });
    stream.end(message);
  }, error => {
    message.stopReason = options.signal?.aborted ? 'aborted' : 'error';
    message.errorMessage = options.signal?.aborted ? 'Cancelled.' : humanMessage(error);
    stream.push({ type: 'error', reason: message.stopReason, error: message });
    stream.end(message);
  });
  return stream;

  async function run() {
    const request = claudeRequest(context, model);
    const controller = new AbortController();
    const abort = () => controller.abort();
    options.signal?.addEventListener('abort', abort, { once: true });
    if (options.signal?.aborted) controller.abort();
    await mkdir(workspace, { recursive: true, mode: 0o700 });
    let query, timer, acknowledge, started = false, failure;
    const response = { message: undefined, complete: false, json: new Map() }, indices = new Map();
    const resetTimer = () => { clearTimeout(timer); timer = setTimeout(() => controller.abort(), 180000); timer.unref?.(); };
    try {
      const body = { tools: request.inventory.map(tool => ({ name: tool.name, description: tool.description, input_schema: tool.inputSchema })) };
      if (options.maxTokens) body.max_tokens = options.maxTokens;
      if (options.reasoning) {
        if (model.reasoning) body.thinking = { type: 'adaptive' };
        body.output_config = { effort: options.reasoning };
      } else body.thinking = { type: 'disabled' };
      const extraBody = JSON.stringify(body);
      // Claude Code takes the tools in one environment variable, which Linux caps at 128 KiB.
      if (Buffer.byteLength(extraBody) > maxExtraBody) {
        throw new Error(`This chat's tools are too large to send through Claude Code (${Math.round(Buffer.byteLength(extraBody) / 1024)} KB). Turn code mode to Only, or turn some tools off.`);
      }
      // Earlier user frames are appended without a model request; each waits for its zero-turn result.
      async function* input() {
        for (const [index, frame] of request.frames.entries()) {
          controller.signal.throwIfAborted();
          const replay = frame.type === 'user' && index < request.frames.length - 1;
          const waiting = replay ? new Promise(resolve => { acknowledge = resolve; }) : undefined;
          yield { ...frame, client_composed: true, ...(replay ? { shouldQuery: false } : {}) };
          if (waiting) await Promise.race([waiting, new Promise(resolve => controller.signal.addEventListener('abort', resolve, { once: true }))]);
        }
      }
      resetTimer();
      query = await sdkQuery({ prompt: input(), options: {
        cwd: workspace, model: model.id, tools: [], settingSources: [], strictMcpConfig: true, persistSession: false,
        systemPrompt: { type: 'custom', prompt: request.system, snapshot: false },
        maxTurns: 1, permissionMode: 'dontAsk', includePartialMessages: true, abortController: controller, stderr: () => {},
        mcpServers: {},
        env: claudeEnvironment({ CLAUDE_CODE_EXTRA_BODY: extraBody, ENABLE_TOOL_SEARCH: 'false', CLAUDE_CODE_MAX_RETRIES: '0',
          CLAUDE_CODE_TOTAL_TOKENS_REMINDER: 'off', DISABLE_AUTO_COMPACT: '1',
          ...(options.maxTokens ? { CLAUDE_CODE_MAX_OUTPUT_TOKENS: String(options.maxTokens) } : {}) }),
      } });
      for await (const event of query) {
        resetTimer();
        if (event.type === 'result' && acknowledge) {
          if (event.is_error || event.num_turns !== 0) throw new Error('Claude could not restore this conversation.');
          const resolve = acknowledge; acknowledge = undefined; resolve();
        } else if (event.type === 'result' && event.is_error) {
          failure = [event.result, ...(event.errors ?? [])].filter(Boolean).join(' ');
          break;
        } else if (event.type === 'assistant' && event.error) {
          failure = (event.message?.content ?? []).filter(block => block.type === 'text').map(block => block.text).join(' ') || String(event.error);
        } else if (event.type === 'stream_event' && event.parent_tool_use_id === null) {
          receive(event.event);
          if (response.complete) break;
        }
      }
      controller.signal.throwIfAborted();
      if (!response.complete && failure && notSignedIn.test(failure)) throw new Error(notSignedInMessage);
      if (!response.complete) throw new Error(failure || 'Claude stopped before completing its response.');
      finish();
    } finally {
      clearTimeout(timer);
      acknowledge?.();
      controller.abort();
      query?.close?.();
      options.signal?.removeEventListener('abort', abort);
    }

    // One Messages API streaming event of the first response.
    function receive(event) {
      if (event.type === 'error') throw new Error(event.error?.message ?? 'Claude could not complete its response.');
      if (event.type === 'message_start') {
        response.message = structuredClone(event.message);
        if (!started) { started = true; stream.push({ type: 'start', partial: message }); }
      } else if (event.type === 'content_block_start') {
        const block = structuredClone(event.content_block);
        response.message.content[event.index] = block;
        if (['text', 'thinking', 'redacted_thinking'].includes(block.type)) {
          const index = message.content.length; indices.set(event.index, index);
          message.content.push(block.type === 'text' ? { type: 'text', text: block.text ?? '' } : { type: 'thinking', thinking: block.thinking ?? '', ...(block.type === 'redacted_thinking' ? { redacted: true, thinkingSignature: block.data } : {}) });
          stream.push({ type: block.type === 'text' ? 'text_start' : 'thinking_start', contentIndex: index, partial: message });
        }
      } else if (event.type === 'content_block_delta') {
        const block = response.message.content[event.index], delta = event.delta;
        if (delta.type === 'input_json_delta') { response.json.set(event.index, (response.json.get(event.index) ?? '') + delta.partial_json); return; }
        const field = { text_delta: 'text', thinking_delta: 'thinking', signature_delta: 'signature' }[delta.type];
        if (!field) return;
        block[field] = (block[field] ?? '') + delta[field];
        if (field !== 'signature' && indices.has(event.index)) {
          const index = indices.get(event.index);
          message.content[index][field] += delta[field];
          stream.push({ type: field === 'text' ? 'text_delta' : 'thinking_delta', contentIndex: index, delta: delta[field], partial: message });
        }
      } else if (event.type === 'content_block_stop') {
        if (response.json.has(event.index)) {
          const text = response.json.get(event.index);
          response.message.content[event.index].input = text.trim() ? JSON.parse(text) : {};
          response.json.delete(event.index);
        }
        if (indices.has(event.index)) {
          const index = indices.get(event.index), block = message.content[index];
          stream.push({ type: block.type === 'text' ? 'text_end' : 'thinking_end', contentIndex: index, content: block.text ?? block.thinking, partial: message });
        }
      } else if (event.type === 'message_delta') {
        Object.assign(response.message, event.delta);
        Object.assign(response.message.usage, event.usage);
      } else if (event.type === 'message_stop') response.complete = true;
    }

    function finish() {
      const native = response.message;
      const names = new Set(request.inventory.map(tool => tool.name));
      message.content = native.content.map(block => {
        if (block.type === 'text') return { type: 'text', text: block.text };
        if (block.type === 'thinking') return { type: 'thinking', thinking: block.thinking, thinkingSignature: block.signature };
        if (block.type === 'redacted_thinking') return { type: 'thinking', thinking: '', redacted: true, thinkingSignature: block.data };
        if (block.type === 'tool_use' && names.has(block.name)) {
          return { type: 'toolCall', id: block.id, name: block.name, arguments: block.input ?? {} };
        }
        throw new Error('Claude returned a tool or block outside this conversation.');
      });
      for (const [index, block] of message.content.entries()) if (block.type === 'toolCall') {
        stream.push({ type: 'toolcall_start', contentIndex: index, partial: message });
        stream.push({ type: 'toolcall_end', contentIndex: index, toolCall: block, partial: message });
      }
      const usage = native.usage ?? {};
      message.usage.input = usage.input_tokens ?? 0; message.usage.output = usage.output_tokens ?? 0;
      message.usage.cacheRead = usage.cache_read_input_tokens ?? 0; message.usage.cacheWrite = usage.cache_creation_input_tokens ?? 0;
      message.usage.totalTokens = message.usage.input + message.usage.output + message.usage.cacheRead + message.usage.cacheWrite;
      message.responseId = native.id;
      message.rawStopReason = native.stop_reason;
      message.stopReason = message.content.some(block => block.type === 'toolCall') ? 'toolUse'
        : ['max_tokens', 'model_context_window_exceeded'].includes(native.stop_reason) ? 'length' : 'stop';
    }
  }
}
