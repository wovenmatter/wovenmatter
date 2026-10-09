import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { normalizeContext } from '@earendil-works/pi-ai/utils/transcript';
import { createClaudeStream, claudeRequest, registerClaudeProviders, claudePrincipalIdentity } from '../src/claude-provider.mjs';

const model = { provider: 'claude-subscription', id: 'sonnet', reasoning: true };
const tool = { name: 'read', description: 'Read a file', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } };
const context = () => normalizeContext({ systemPrompt: 'Host instructions', tools: [tool], messages: [{ role: 'user', content: 'Read my note.', timestamp: 1 }] });
const frame = value => `event: ${value.type}\ndata: ${JSON.stringify(value)}\n\n`;

function responseEvents({ blocks = [{ type: 'text', text: 'Hello' }], stop = 'end_turn', complete = true } = {}) {
  const events = [{ type: 'message_start', message: { id: 'msg-fixture', model: 'sonnet-fixture', role: 'assistant', content: [], usage: { input_tokens: 0, output_tokens: 0, cache_read_input_tokens: 0 } } }];
  for (const [index, block] of blocks.entries()) {
    const initial = structuredClone(block);
    if (block.type === 'text') initial.text = '';
    if (block.type === 'thinking') { initial.thinking = ''; delete initial.signature; }
    if (block.type === 'tool_use') initial.input = {};
    events.push({ type: 'content_block_start', index, content_block: initial });
    if (block.type === 'text') events.push({ type: 'content_block_delta', index, delta: { type: 'text_delta', text: block.text } });
    if (block.type === 'thinking') {
      events.push({ type: 'content_block_delta', index, delta: { type: 'thinking_delta', thinking: block.thinking } });
      events.push({ type: 'content_block_delta', index, delta: { type: 'signature_delta', signature: block.signature } });
    }
    if (block.type === 'tool_use') events.push({ type: 'content_block_delta', index, delta: { type: 'input_json_delta', partial_json: JSON.stringify(block.input) } });
    events.push({ type: 'content_block_stop', index });
  }
  events.push({ type: 'message_delta', delta: { stop_reason: stop }, usage: { output_tokens: 7, cache_creation_input_tokens: 3 } });
  if (complete) events.push({ type: 'message_stop' });
  return events.map(frame).join('');
}

async function fixture(t, { body = responseEvents(), status = 200, extraTurn = false, badAck = false, fetcher } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'woven-claude-protocol-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const calls = { requests: 0, credentials: [], environment: [], frames: [], options: undefined };
  const principal = { email: 'fixture@example.invalid', apiProvider: 'firstParty' };
  const credentials = { read: async id => { calls.credentials.push(id); return { type: 'api_key', key: 'fixture-api-key' }; } };
  const claude = {
    environment: async key => { calls.environment.push(key); return key ? { ANTHROPIC_API_KEY: key } : {}; },
    sdkQuery: async ({ prompt, options }) => {
      calls.options = options;
      const native = (async function* () {
        for await (const row of prompt) {
          calls.frames.push(row);
          if (row.shouldQuery === false) yield { type: 'result', num_turns: badAck ? 1 : 0, is_error: false };
        }
        const send = async () => {
          const result = await fetch(options.env.ANTHROPIC_BASE_URL + '/v1/messages', { method: 'POST', signal: options.abortController.signal,
            headers: { authorization: 'Bearer fixture-native-token', 'content-type': 'application/json' }, body: '{}' });
          calls.lastStatus = result.status;
          await result.text();
        };
        await send();
        if (extraTurn) await send();
        yield { type: 'result', num_turns: 1, is_error: extraTurn, subtype: extraTurn ? 'error_max_turns' : 'success', usage: { input_tokens: 999 } };
      })();
      native.close = () => {}; native.accountInfo = async () => principal;
      return native;
    },
  };
  const admission = { fetcher: async (url, options) => {
    calls.requests++;
    assert.equal(url, 'https://api.anthropic.com/v1/messages');
    assert.equal(options.headers.authorization, 'Bearer fixture-native-token');
    return fetcher ? fetcher(url, options) : new Response(body, { status, headers: { 'content-type': 'text/event-stream' } });
  } };
  const stream = createClaudeStream(claude, credentials, { admission, executable: '/fixture/claude', timeoutMs: 3000 });
  const sessionID = randomUUID(); let taskID = 0;
  return { calls, stream: (selected, transcript, options = {}) => {
    const scope = { directory: root, sessionID, provider: selected.provider, modelID: selected.id, accountID: 'fixture', taskID: ++taskID };
    return stream(selected, transcript, { ...options, wovenNativeContext: { ...scope, nativePrincipalIdentity: selected.provider === 'claude-subscription' ? claudePrincipalIdentity(principal, scope) : undefined } });
  } };
}

test('native replay preserves structured host history and isolates signed thinking by route', () => {
  const transcript = normalizeContext({ systemPrompt: 'Host', tools: [tool], messages: [
    { role: 'user', content: 'First', timestamp: 1 },
    { role: 'assistant', api: 'woven-claude-native', provider: model.provider, model: model.id,
      wovenNativeAccountID: 'fixture-a', wovenNativeAuthIdentity: 'original-credential', content: [
      { type: 'thinking', thinking: 'Thought', thinkingSignature: 'fixture-signature' },
      { type: 'toolCall', id: 'call-1', name: 'read', arguments: { path: 'note.md' } },
      { type: 'text', text: 'Visible original answer' },
    ] },
    { role: 'toolResult', toolCallId: 'call-1', toolName: 'read', content: [{ type: 'text', text: 'Note text' }], isError: false },
    { role: 'user', content: 'Explain', timestamp: 2 },
  ] });
  const scope = { accountID: 'fixture-a', authIdentity: 'original-credential' };
  const request = claudeRequest(transcript, model, scope);
  assert.equal(request.system, 'Host');
  assert.deepEqual(request.inventory[0].inputSchema, tool.parameters);
  assert.equal(request.frames.length, 3);
  assert.equal(request.frames[1].message.content[0].signature, 'fixture-signature');
  assert.equal(request.frames[1].message.content[1].name, 'mcp__woven__read');
  assert.equal(request.frames[2].message.content[0].tool_use_id, 'call-1');
  assert.equal(request.frames[2].message.content[1].text, 'Explain');
  for (const [target, origin] of [[{ ...model, id: 'opus' }, scope], [model, { ...scope, accountID: 'fixture-b' }], [model, { ...scope, authIdentity: 'replacement-credential' }]]) {
    const content = claudeRequest(transcript, target, origin).frames[1].message.content;
    assert.equal(content[0].type, 'tool_use');
    assert.equal(content.at(-1).text, 'Visible original answer');
  }
});

test('cross-engine tool identifiers normalize identically in calls and results without collisions', () => {
  const ids = ['call.with:punctuation|item', 'x'.repeat(90), 'call/one', 'call:one'];
  const transcript = normalizeContext({ messages: [
    { role: 'user', content: 'Read', timestamp: 1 },
    { role: 'assistant', content: ids.map(id => ({ type: 'toolCall', id, name: 'read', arguments: {} })) },
    ...ids.map(id => ({ role: 'toolResult', toolCallId: id, content: [{ type: 'text', text: 'ok' }] })),
  ] });
  const frames = claudeRequest(transcript, model).frames;
  const calls = frames[1].message.content.map(block => block.id);
  assert.equal(new Set(calls).size, ids.length);
  assert.ok(calls.every(id => /^[A-Za-z0-9_-]{1,64}$/.test(id)));
  assert.deepEqual(frames[2].message.content.map(block => block.tool_use_id), calls);
});

test('Pi owns tools; native extraTurny is denied and first response owns content and usage', async t => {
  const blocks = [{ type: 'thinking', thinking: 'Check note', signature: 'signed' },
    { type: 'tool_use', id: 'call-1', name: 'mcp__woven__read', input: { path: 'note.md' } }, { type: 'text', text: 'Reading.' }];
  const f = await fixture(t, { body: responseEvents({ blocks, stop: 'tool_use' }), extraTurn: true });
  const stream = f.stream(model, context(), { reasoning: 'high' });
  const events = [];
  for await (const event of stream) events.push(event);
  const result = await stream.result();
  assert.equal(result.stopReason, 'toolUse');
  assert.equal(f.calls.requests, 1);
  assert.equal(f.calls.lastStatus, 400);
  assert.deepEqual(f.calls.credentials, []);
  assert.deepEqual(f.calls.environment, [undefined]);
  assert.deepEqual(result.content.map(block => block.type), ['thinking', 'toolCall', 'text']);
  assert.equal(result.content[0].thinkingSignature, 'signed');
  assert.equal(result.content[1].name, 'read');
  assert.equal(result.usage.input, 0);
  assert.equal(result.usage.output, 7);
  assert.equal(result.usage.totalTokens, 10);
  assert.deepEqual(f.calls.options.tools, []);
  assert.deepEqual(f.calls.options.skills, []);
  assert.deepEqual(f.calls.options.settingSources, []);
  assert.equal(f.calls.options.permissionMode, 'dontAsk');
  assert.equal(f.calls.options.persistSession, true);
  assert.equal(f.calls.options.env.DISABLE_AUTO_COMPACT, undefined);
  assert.equal(f.calls.options.env.DISABLE_COMPACT, undefined);
  assert.equal(f.calls.options.env.ANTHROPIC_API_KEY, undefined);
  assert.equal(JSON.parse(f.calls.options.env.CLAUDE_CODE_EXTRA_BODY).tools[0].name, 'mcp__woven__read');
  assert.equal(events.filter(event => event.type === 'toolcall_end').length, 1);
  assert.equal(events.filter(event => event.type === 'text_delta').map(event => event.delta).join(''), 'Reading.');
});

test('historical users receive acknowledgments and assistant roles are transmitted unchanged', async t => {
  const f = await fixture(t);
  const transcript = normalizeContext({ messages: [
    { role: 'user', content: 'Earlier', timestamp: 1 },
    { role: 'assistant', content: [{ type: 'text', text: 'Reply' }], provider: 'other', model: 'other', api: 'other' },
    { role: 'user', content: 'Next', timestamp: 2 },
  ] });
  assert.equal((await f.stream(model, transcript).result()).stopReason, 'stop');
  assert.equal(f.calls.frames[0].shouldQuery, false);
  assert.equal(f.calls.frames[1].type, 'assistant');
  assert.equal(f.calls.frames[2].shouldQuery, undefined);
  const bad = await fixture(t, { badAck: true });
  const result = await bad.stream(model, transcript).result();
  assert.equal(result.stopReason, 'error');
  assert.match(result.errorMessage, /restore this conversation/);
  assert.equal(bad.calls.requests, 0);
});

test('API-key mode reads only its explicit key and subscription mode never reads the shared vault', async t => {
  const f = await fixture(t);
  assert.equal((await f.stream({ ...model, provider: 'anthropic' }, context()).result()).stopReason, 'stop');
  assert.deepEqual(f.calls.credentials, ['anthropic']);
  assert.deepEqual(f.calls.environment, ['fixture-api-key']);
  assert.equal(f.calls.options.env.ANTHROPIC_API_KEY, 'fixture-api-key');
});

test('auth and quota failures have safe fallback markers without reflecting provider data', async t => {
  for (const [status, type, expected] of [[401, 'authentication_error', /sign-in or a valid API key/], [402, 'insufficient_quota', /exhausted its available usage/], [429, 'rate_limit_error', /HTTP 429/]]) {
    const f = await fixture(t, { status, body: JSON.stringify({ error: { type, message: 'fixture-secret-must-not-appear' } }) });
    const result = await f.stream(model, context()).result();
    assert.equal(result.stopReason, 'error');
    assert.match(result.errorMessage, expected);
    assert.ok(!JSON.stringify(result).includes('fixture-secret'));
  }
});

test('incomplete streams and unknown tool names never publish executable calls', async t => {
  for (const body of [responseEvents({ complete: false, blocks: [{ type: 'tool_use', id: 'call-1', name: 'mcp__woven__read', input: {} }] }),
    responseEvents({ blocks: [{ type: 'tool_use', id: 'call-2', name: 'mcp__other__Bash', input: {} }], stop: 'tool_use' })]) {
    const f = await fixture(t, { body });
    const stream = f.stream(model, context());
    const events = [];
    for await (const event of stream) events.push(event);
    assert.equal((await stream.result()).stopReason, 'error');
    assert.equal(events.filter(event => event.type === 'toolcall_end').length, 0);
  }
});

test('malformed trailing events and unsupported response blocks fail even after message_stop', async t => {
  for (const body of [responseEvents() + frame({ type: 'message_delta', delta: { stop_reason: 'end_turn' } }),
    responseEvents() + 'data: {"malformed":',
    responseEvents({ blocks: [{ type: 'unknown_vendor_block', content: 'unsupported' }] })]) {
    const f = await fixture(t, { body });
    assert.equal((await f.stream(model, context()).result()).stopReason, 'error');
  }
});

test('cancellation closes the active upstream and produces no completed tool batch', async t => {
  let admitted;
  const started = new Promise(resolve => { admitted = resolve; });
  let cancelled = false;
  const f = await fixture(t, { fetcher: async (_url, { signal }) => {
    admitted();
    return new Promise((_, reject) => signal.addEventListener('abort', () => { cancelled = true; reject(signal.reason); }, { once: true }));
  } });
  const controller = new AbortController();
  const stream = f.stream(model, context(), { signal: controller.signal });
  await started;
  controller.abort();
  assert.equal((await stream.result()).stopReason, 'aborted');
  assert.equal(cancelled, true);
});

test('registered subscription provider resolves ambient native auth without credentials or a status process per request', async () => {
  const registered = new Map(); let checks = 0;
  registerClaudeProviders({ registerNativeProvider: provider => registered.set(provider.id, provider) }, {
    models: [{ value: 'sonnet', displayName: 'Claude Sonnet', supportedEffortLevels: ['low', 'high'] }],
    status: async () => { checks++; return { connected: true }; },
  }, { read: async () => ({ key: 'fixture' }) });
  const subscription = registered.get('claude-subscription');
  assert.deepEqual(await subscription.auth.apiKey.resolve(), { auth: {}, source: 'Claude runtime' });
  assert.equal(checks, 0);
  assert.equal((await subscription.auth.apiKey.check()).type, 'oauth');
  assert.equal(checks, 0);
  assert.equal(subscription.getModels()[0].api, 'woven-claude-native');
  assert.equal(registered.get('anthropic').getModels()[0].provider, 'anthropic');
});
