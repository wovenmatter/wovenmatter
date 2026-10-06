import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, rm } from 'node:fs/promises';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomUUID } from 'node:crypto';
import { query } from '@anthropic-ai/claude-agent-sdk';
import { normalizeContext } from '@earendil-works/pi-ai/utils/transcript';
import { createClaudeStream, compactClaudeContext, canUseClaudeNativeCompaction, getClaudeNativePrincipal, claudePrincipalIdentity } from '../src/claude-provider.mjs';

const model = { provider: 'anthropic', api: 'woven-claude-native', id: 'sonnet', reasoning: false };
const tool = { name: 'read', description: 'Read a file', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } };
const frame = event => `event: ${event.type}\ndata: ${JSON.stringify(event)}\n\n`;
function response(content) {
  const events = [{ type: 'message_start', message: { id: 'msg-' + randomUUID(), model: 'claude-sonnet-4-6', role: 'assistant', content: [], usage: { input_tokens: 13, output_tokens: 0, cache_read_input_tokens: 2 } } }];
  for (const [index, block] of content.entries()) {
    const initial = block.type === 'tool_use' ? { ...block, input: {} } : block.type === 'thinking' ? { type: 'thinking', thinking: '' } : { ...block, text: '' };
    events.push({ type: 'content_block_start', index, content_block: initial });
    events.push({ type: 'content_block_delta', index, delta: block.type === 'tool_use' ? { type: 'input_json_delta', partial_json: JSON.stringify(block.input) }
      : block.type === 'thinking' ? { type: 'thinking_delta', thinking: block.thinking } : { type: 'text_delta', text: block.text } });
    if (block.type === 'thinking') events.push({ type: 'content_block_delta', index, delta: { type: 'signature_delta', signature: block.signature } });
    events.push({ type: 'content_block_stop', index });
  }
  events.push({ type: 'message_delta', delta: { stop_reason: content.some(block => block.type === 'tool_use') ? 'tool_use' : 'end_turn' }, usage: { output_tokens: 7, cache_creation_input_tokens: 3 } }, { type: 'message_stop' });
  return events.map(frame).join('');
}
async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'woven-claude-native-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const config = join(root, 'config'), storage = join(root, 'storage');
  await mkdir(config, { mode: 0o700 }); await mkdir(storage, { mode: 0o700 });
  const requests = [], records = [];
  let blocks = [{ type: 'text', text: 'Native reply.' }];
  const native = { environment: async key => ({ PATH: process.env.PATH, HOME: root, CLAUDE_CONFIG_DIR: config,
    CLAUDE_SECURESTORAGE_CONFIG_DIR: storage, ANTHROPIC_API_KEY: key }), sdkQuery: async args => query(args) };
  const credentials = { read: async () => ({ key: 'fixture-only-anthropic-key' }) };
  const dependencies = { timeoutMs: 20000, admission: { fetcher: async (_url, options) => {
    assert.equal(options.redirect, 'error');
    requests.push(JSON.parse(options.body));
    return new Response(response(blocks), { headers: { 'content-type': 'text/event-stream' } });
  } } };
  const sessionID = randomUUID();
  const scope = (taskID, extra = {}) => ({ directory: root, sessionID, provider: model.provider, modelID: model.id,
    accountID: 'fixture-account-a', taskID, archive: async batch => records.push(...batch), ...extra });
  return { native, credentials, requests, records, dependencies, scope,
    stream: createClaudeStream(native, credentials, dependencies), setResponse: value => { blocks = value; } };
}

test('native compaction capability applies only to the official Claude SDK routes', () => {
  assert.equal(canUseClaudeNativeCompaction(model), true);
  assert.equal(canUseClaudeNativeCompaction({ ...model, provider: 'claude-subscription' }), true);
  assert.equal(canUseClaudeNativeCompaction({ ...model, api: 'anthropic-messages' }), false);
  assert.equal(canUseClaudeNativeCompaction({ ...model, provider: 'openai' }), false);
});

test('automatic SDK compaction has a separate admission budget and contributes usage without publishing its summary', { timeout: 15000 }, async t => {
  const f = await fixture(t);
  let index = 0;
  const dependencies = { ...f.dependencies, admission: { fetcher: async () => new Response(response(index++ === 0
    ? [{ type: 'text', text: 'NATIVE_COMPACT_SUMMARY_NOT_USER_REPLY' }] : [{ type: 'text', text: 'Final answer only.' }]),
  { headers: { 'content-type': 'text/event-stream' } }) } };
  f.native.sdkQuery = async ({ prompt, options }) => {
    const native = (async function* () {
      for await (const input of prompt) if (input.shouldQuery === false) yield { type: 'result', num_turns: 0, is_error: false };
      const send = async () => {
        const result = await fetch(options.env.ANTHROPIC_BASE_URL + '/v1/messages', { method: 'POST', headers: { 'content-type': 'application/json' }, body: '{}', signal: options.abortController.signal });
        await result.text();
      };
      await options.hooks.PreCompact[0].hooks[0]({ trigger: 'auto' }); await send();
      await options.hooks.PostCompact[0].hooks[0]({ compact_summary: 'NATIVE_COMPACT_SUMMARY_NOT_USER_REPLY' });
      yield { type: 'system', subtype: 'compact_boundary', uuid: randomUUID(), compact_metadata: { trigger: 'auto', pre_tokens: 100 } };
      await send(); yield { type: 'result', num_turns: 1, is_error: false };
    })(); native.close = () => {}; return native;
  };
  const stream = createClaudeStream(f.native, f.credentials, dependencies)(model,
    normalizeContext({ messages: [{ role: 'user', content: 'Fixture', timestamp: 1 }] }), { wovenNativeContext: f.scope(1) });
  const events = []; for await (const event of stream) events.push(event);
  const result = await stream.result();
  assert.equal(result.stopReason, 'stop', result.errorMessage); assert.equal(index, 2);
  assert.equal(result.usage.totalTokens, 50);
  assert.equal(result.content[0].text, 'Final answer only.');
  assert.ok(!JSON.stringify(events).includes('NATIVE_COMPACT_SUMMARY_NOT_USER_REPLY'));
});

test('a host tool-result boundary preserves exact native identity and sends the actual result once', { timeout: 50000 }, async t => {
  const f = await fixture(t);
  const firstContext = normalizeContext({ systemPrompt: 'Fixture host instructions', tools: [tool], messages: [{ role: 'user', content: 'Read note.', timestamp: 1 }] });
  f.setResponse([{ type: 'tool_use', id: 'toolu_exact_fixture', name: 'mcp__woven__read', input: { path: 'note.md' } }]);
  const first = await f.stream(model, firstContext, { wovenNativeContext: f.scope(1) }).result();
  assert.equal(first.stopReason, 'toolUse', first.errorMessage);
  assert.ok(first.wovenNativeContinuation);
  f.setResponse([{ type: 'text', text: 'Actual host result received.' }]);
  const nextContext = normalizeContext({ messages: [...firstContext.messages, first, { role: 'toolResult', toolCallId: first.content[0].id, toolName: 'read', content: [{ type: 'text', text: 'EXACT_HOST_CONTENT' }], timestamp: 2 }] });
  const second = await f.stream(model, nextContext, { wovenNativeContext: f.scope(2) }).result();
  assert.equal(second.stopReason, 'stop', second.errorMessage);
  assert.notEqual(second.wovenNativeContinuation.nativeSessionID, first.wovenNativeContinuation.nativeSessionID);
  assert.equal(f.requests.length, 2);
  const blocks = f.requests[1].messages.flatMap(message => typeof message.content === 'string' ? [] : message.content);
  assert.equal(blocks.filter(block => block.type === 'tool_use' && block.id === 'toolu_exact_fixture').length, 1);
  assert.equal(blocks.filter(block => block.type === 'tool_result' && block.tool_use_id === 'toolu_exact_fixture').length, 1);
  assert.ok(JSON.stringify(blocks).includes('EXACT_HOST_CONTENT'));
  assert.ok(!JSON.stringify(blocks).includes('Only Woven Matter executes this tool'));
  assert.ok(f.records.some(record => record.kind.startsWith('claude.sdk.transcript.')));
  assert.ok(!JSON.stringify(f.records).includes('fixture-only-anthropic-key'));
  assert.deepEqual(f.requests[0].tools.map(tool => tool.name), ['mcp__woven__read']);
  assert.equal(second.content[0].text, 'Actual host result received.');
});

for (const provider of ['anthropic', 'claude-subscription']) test(`${provider} native SDK persistence resumes compaction and rebuilds changed accounts`, { timeout: 60000 }, async t => {
  const f = await fixture(t), selected = { ...model, provider };
  const firstPrincipal = { email: 'fixture-a@example.invalid', organization: 'Fixture A', apiProvider: 'firstParty' };
  let principal = firstPrincipal;
  if (provider === 'claude-subscription') {
    const environment = f.native.environment;
    f.native.environment = async () => environment('fixture-only-native-key');
    f.native.sdkQuery = async args => { const native = query(args); native.accountInfo = async () => principal; return native; };
  }
  const scope = (taskID, extra = {}) => f.scope(taskID, { provider, credentialIdentity: 'stable-profile-marker', authIdentity: 'stable-profile-marker', ...extra });
  const originalIdentity = provider === 'claude-subscription' ? claudePrincipalIdentity(principal, scope(1)) : scope(1).authIdentity;
  const messages = [];
  for (let index = 0; index < 10; index++) messages.push({ role: 'user', content: `ORIGINAL_FACT_${index}: iridescent octopus. ` + 'Detailed history '.repeat(100), timestamp: index },
    { role: 'assistant', api: selected.api, provider, model: selected.id, wovenNativeAccountID: scope(1).accountID, wovenNativeAuthIdentity: originalIdentity,
      content: [{ type: 'thinking', thinking: 'Exposed original thought', thinkingSignature: 'ORIGINAL_ACCOUNT_SIGNATURE' }, { type: 'text', text: `Prior conclusion ${index}. ` + 'Conclusion '.repeat(100) }] });
  const endpoint = letter => '/private/tmp/wmtools-' + letter.repeat(32) + '/' + letter.repeat(32) + '.sock';
  const canonical = normalizeContext({ systemPrompt: 'Fixture instructions. Current tool endpoint: ' + endpoint('a'), tools: [tool], messages });
  f.setResponse([{ type: 'text', text: 'NATIVE_OPAQUE_SUMMARY_FACT: iridescent octopus.' }]);
  const compacted = await compactClaudeContext(f.native, f.credentials, selected, canonical.messages, { wovenNativeContext: scope(10) }, f.dependencies);
  assert.equal(compacted.continuation.kind, 'claude-sdk'); assert.equal(compacted.usage.totalTokens, 25); assert.equal(f.requests.length, 1);
  assert.ok(f.records.some(record => record.kind === 'claude.sdk.event.compact_boundary'));
  assert.ok(f.records.some(record => record.payload.includes('isCompactSummary') && record.payload.includes('NATIVE_OPAQUE_SUMMARY_FACT')));
  assert.ok(f.records.some(record => record.payload.includes('ORIGINAL_ACCOUNT_SIGNATURE')));
  for (let index = 0; index < 10; index++) assert.ok(f.records.some(record => record.payload.includes(`ORIGINAL_FACT_${index}`)));

  // The supported capture-only SessionStore must leave native on-disk resume authoritative.
  const continued = normalizeContext({ systemPrompt: 'Fixture instructions. Current tool endpoint: ' + endpoint('b'), tools: [tool],
    messages: [...canonical.messages.filter(message => message.role !== 'system'), { role: 'user', content: 'Continue with the fact.', timestamp: 99 }] });
  f.setResponse([{ type: 'text', text: 'Fact preserved after native restore.' }]);
  const options = { wovenNativeContext: scope(11, { continuation: compacted.continuation }) };
  const result = await f.stream(selected, continued, options).result();
  assert.equal(result.stopReason, 'stop', result.errorMessage); assert.equal(f.requests.length, 2);
  const body = JSON.stringify(f.requests[1].messages);
  assert.ok(body.includes('NATIVE_OPAQUE_SUMMARY_FACT')); assert.ok(!body.includes('ORIGINAL_FACT_0'));
  assert.equal(body.match(/Continue with the fact\./g)?.length, 1);
  assert.equal(result.wovenNativeContinuation.routeKey, compacted.continuation.routeKey);
  const system = JSON.stringify(f.requests[1].system);
  assert.ok(system.includes(endpoint('b'))); assert.ok(!system.includes(endpoint('a')));

  // A Woven account change and a live principal change both rebuild original facts.
  principal = { ...firstPrincipal, email: 'fixture-b@example.invalid', organization: 'Fixture B' };
  const changedScope = scope(12, { ...(provider === 'anthropic' ? { accountID: 'fixture-account-b' } : {}), continuation: compacted.continuation, canonicalMessages: continued.messages });
  const switched = await createClaudeStream(f.native, f.credentials, { ...f.dependencies, replayCompactionBytes: 4096 })(selected, continued, { wovenNativeContext: changedScope }).result();
  assert.equal(switched.stopReason, 'stop', switched.errorMessage);
  assert.notEqual(switched.wovenNativeContinuation.routeKey, compacted.continuation.routeKey);
  const rebuilt = f.requests.slice(2), rebuiltText = JSON.stringify(rebuilt);
  assert.ok(rebuilt.length > 2); assert.equal(switched.usage.totalTokens, rebuilt.length * 25);
  for (let index = 0; index < 10; index++) assert.ok(rebuiltText.includes(`ORIGINAL_FACT_${index}`));
  assert.ok(!rebuiltText.includes('NATIVE_OPAQUE_SUMMARY_FACT')); assert.ok(!rebuiltText.includes('ORIGINAL_ACCOUNT_SIGNATURE'));
  const final = JSON.stringify(rebuilt.at(-1).messages);
  assert.equal(final.match(/Continue with the fact\./g)?.length, 1); assert.ok(!final.includes('ORIGINAL_FACT_0'));
});

test('unknown native principal fails closed and supported account lookup cancellation closes its process', async () => {
  let closed = false;
  const unknown = { environment: async () => ({}), sdkQuery: async ({ options }) => {
    assert.equal(options.persistSession, false); assert.deepEqual(options.tools, []);
    return { accountInfo: async () => ({ apiProvider: 'firstParty' }), close: () => { closed = true; } };
  } };
  await assert.rejects(getClaudeNativePrincipal(unknown), /establish.*account/); assert.equal(closed, true);
  const controller = new AbortController(); closed = false;
  const waiting = getClaudeNativePrincipal({ ...unknown, sdkQuery: async () => ({ accountInfo: async () => new Promise(() => {}), close: () => { closed = true; } }) }, { signal: controller.signal });
  await new Promise(resolve => setImmediate(resolve)); controller.abort();
  await assert.rejects(waiting, /abort/i); assert.equal(closed, true);
});

test('an account change between metadata probe and native query admits no replay frames or provider request', async t => {
  const f = await fixture(t), selected = { ...model, provider: 'claude-subscription' };
  const principal = { email: 'fixture-a@example.invalid', organization: 'Fixture A', apiProvider: 'firstParty' };
  let replayed = 0;
  f.native.environment = async () => ({});
  f.native.sdkQuery = async args => {
    const actualQuery = args.options.persistSession;
    // The actual process may begin requesting input during initialization.
    // It must receive no history before the live account check succeeds.
    if (actualQuery) void (async () => { for await (const _ of args.prompt) replayed++; })().catch(() => {});
    return {
      accountInfo: async () => actualQuery ? { ...principal, email: 'fixture-b@example.invalid' } : principal,
      close() {}, async *[Symbol.asyncIterator]() {},
    };
  };
  const context = normalizeContext({ systemPrompt: 'Fixture', tools: [tool], messages: [
    { role: 'user', content: 'Visible original account history', timestamp: 1 },
    { role: 'assistant', content: [{ type: 'text', text: 'Original answer' }] },
    { role: 'user', content: 'New prompt', timestamp: 2 },
  ] });
  const result = await f.stream(selected, context, { wovenNativeContext: f.scope(1, { provider: selected.provider }) }).result();
  assert.equal(result.stopReason, 'error'); assert.match(result.errorMessage, /account changed/);
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(replayed, 0); assert.equal(f.requests.length, 0);
});
