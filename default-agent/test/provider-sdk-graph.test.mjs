import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { createRequire } from 'node:module';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { crc32 } from 'node:zlib';
import { streamSimple as anthropic } from '@earendil-works/pi-ai/api/anthropic-messages';
import { streamSimple as responses } from '@earendil-works/pi-ai/api/openai-responses';
import { streamSimple as completions } from '@earendil-works/pi-ai/api/openai-completions';
import { streamSimple as google } from '@earendil-works/pi-ai/api/google-generative-ai';
import { streamSimple as bedrock } from '@earendil-works/pi-ai/api/bedrock-converse-stream';
import { normalizeContext } from '@earendil-works/pi-ai/utils/transcript';
import { satisfiesRange } from '../src/package-versions.mjs';

const fromPi = createRequire(import.meta.resolve('@earendil-works/pi-ai'));
const tool = { name: 'lookup', description: 'Offline fixture', parameters: {
  type: 'object', properties: { key: { type: 'string' } }, required: ['key'],
} };
const context = normalizeContext({ messages: [{ role: 'user', content: 'Look up the fixture', timestamp: 0 }], tools: [tool] });
const sse = events => events.map(([event, data]) => `${event ? `event: ${event}\n` : ''}data: ${JSON.stringify(data)}\n\n`).join('');

async function fixture(t, respond) {
  const requests = [];
  const server = createServer(async (request, response) => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    requests.push({ url: request.url, headers: request.headers, body: JSON.parse(Buffer.concat(chunks)) });
    respond(response);
  });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  return { baseUrl: `http://127.0.0.1:${server.address().port}`, requests };
}

function model(api, provider, baseUrl) {
  return { id: 'fixture-model', name: 'Fixture', api, provider, baseUrl, reasoning: false,
    input: ['text'], contextWindow: 128000, maxTokens: 2048,
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
}

function checkResult(result) {
  assert.equal(result.stopReason, 'toolUse', result.errorMessage);
  assert.equal(result.content.find(block => block.type === 'text')?.text, 'Offline text');
  const call = result.content.find(block => block.type === 'toolCall');
  assert.equal(call?.name, 'lookup');
  assert.deepEqual(call.arguments, { key: 'fixture' });
  assert.equal(result.usage.input, 11);
  assert.equal(result.usage.output, 7);
}

test('Pi resolves the tested provider SDK floors through its effective consumer graph', () => {
  const manifest = JSON.parse(readFileSync(new URL('../package.json', import.meta.url)));
  for (const [name, range] of Object.entries(manifest.overrides['@earendil-works/pi-ai'])) {
    let directory = dirname(fromPi.resolve(name));
    for (;;) {
      try {
        const selected = JSON.parse(readFileSync(join(directory, 'package.json')));
        if (selected.name === name) {
          assert.ok(satisfiesRange(selected.version, range), `${name}: ${selected.version} does not meet ${range}`);
          break;
        }
      } catch (error) { if (error.code !== 'ENOENT') throw error; }
      const parent = dirname(directory);
      assert.notEqual(parent, directory, `Cannot locate Pi's ${name}`);
      directory = parent;
    }
  }
});

const anthropicEvents = [
  ['message_start', { type: 'message_start', message: { id: 'msg_fixture', type: 'message', role: 'assistant', content: [], model: 'fixture-model', usage: { input_tokens: 11, output_tokens: 0 } } }],
  ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'text', text: '' } }],
  ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'text_delta', text: 'Offline text' } }],
  ['content_block_stop', { type: 'content_block_stop', index: 0 }],
  ['content_block_start', { type: 'content_block_start', index: 1, content_block: { type: 'tool_use', id: 'call_fixture', name: 'lookup', input: {} } }],
  ['content_block_delta', { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '{"key":"fixture"}' } }],
  ['content_block_stop', { type: 'content_block_stop', index: 1 }],
  ['message_delta', { type: 'message_delta', delta: { stop_reason: 'tool_use' }, usage: { output_tokens: 7 } }],
  ['message_stop', { type: 'message_stop' }],
];

test('Pi and Anthropic SDK v1 preserve Messages streaming, tools and usage on the new API version', { timeout: 10000 }, async t => {
  const f = await fixture(t, response => { response.writeHead(200, { 'content-type': 'text/event-stream' }); response.end(sse(anthropicEvents)); });
  for (const auth of [{ apiKey: 'fixture-key' }, { headers: { authorization: 'Bearer fixture-header-owned' } }]) {
    checkResult(await anthropic(model('anthropic-messages', 'anthropic', f.baseUrl), context, { ...auth, maxRetries: 0 }).result());
  }
  assert.equal(f.requests.length, 2);
  assert.equal(f.requests[0].headers.authorization, 'Bearer fixture-key');
  assert.equal(f.requests[1].headers.authorization, 'Bearer fixture-header-owned');
  assert.equal(f.requests[1].headers['x-api-key'], undefined, 'header-owned auth must not resolve an ambient API key');
  for (const request of f.requests) {
    assert.equal(request.headers['anthropic-version'], '2026-10-21');
    assert.match(request.url, /^\/v1\/messages(?:\?|$)/);
    assert.equal(request.body.tools[0].name, 'lookup');
    assert.deepEqual(request.body.tools[0].input_schema.required, ['key']);
  }
});

test('Pi and current OpenAI SDK preserve Responses text, tool deltas and usage', { timeout: 10000 }, async t => {
  const text = { id: 'msg_fixture', type: 'message', role: 'assistant', content: [{ type: 'output_text', text: 'Offline text', annotations: [] }], status: 'completed' };
  const call = { id: 'fc_fixture', type: 'function_call', call_id: 'call_fixture', name: 'lookup', arguments: '{"key":"fixture"}', status: 'completed' };
  const events = [
    { type: 'response.created', response: { id: 'resp_fixture', status: 'in_progress' } },
    { type: 'response.output_item.added', output_index: 0, item: { ...text, content: [] } },
    { type: 'response.content_part.added', output_index: 0, content_index: 0, part: { type: 'output_text', text: '', annotations: [] } },
    { type: 'response.output_text.delta', output_index: 0, content_index: 0, delta: 'Offline text' },
    { type: 'response.output_item.done', output_index: 0, item: text },
    { type: 'response.output_item.added', output_index: 1, item: { ...call, arguments: '' } },
    { type: 'response.function_call_arguments.delta', output_index: 1, delta: '{"key":"fixture"}' },
    { type: 'response.output_item.done', output_index: 1, item: call },
    { type: 'response.completed', response: { id: 'resp_fixture', status: 'completed', output: [text, call], usage: { input_tokens: 11, output_tokens: 7, total_tokens: 18 } } },
  ];
  const f = await fixture(t, response => { response.writeHead(200, { 'content-type': 'text/event-stream' }); response.end(sse(events.map(e => [e.type, e]))); });
  checkResult(await responses(model('openai-responses', 'openai', f.baseUrl), context, { apiKey: 'fixture-key', maxRetries: 0 }).result());
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].body.tools[0].name, 'lookup');
});

test('Pi and current OpenAI SDK preserve compatible Chat Completions tool streaming', { timeout: 10000 }, async t => {
  const chunk = (delta, finish_reason = null) => ({ id: 'chat_fixture', choices: [{ index: 0, delta, finish_reason }] });
  const events = [chunk({ role: 'assistant', content: 'Offline text' }), chunk({ tool_calls: [{ index: 0, id: 'call_fixture', type: 'function', function: { name: 'lookup', arguments: '{"key":"fixture"}' } }] }),
    { ...chunk({}, 'tool_calls'), usage: { prompt_tokens: 11, completion_tokens: 7, total_tokens: 18 } }];
  const f = await fixture(t, response => { response.writeHead(200, { 'content-type': 'text/event-stream' }); response.end(sse(events.map(e => ['', e])) + 'data: [DONE]\n\n'); });
  checkResult(await completions(model('openai-completions', 'openai', f.baseUrl), context, { apiKey: 'fixture-key', maxRetries: 0 }).result());
  assert.equal(f.requests.length, 1);
  assert.equal(f.requests[0].body.tools[0].function.name, 'lookup');
});

test('Pi and current Google SDK preserve streaming function calls and token accounting', { timeout: 10000 }, async t => {
  const f = await fixture(t, response => {
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.end(sse([['', { responseId: 'google_fixture', candidates: [{ content: { role: 'model', parts: [{ text: 'Offline text' }, { functionCall: { name: 'lookup', args: { key: 'fixture' } } }] }, finishReason: 'STOP' }], usageMetadata: { promptTokenCount: 11, candidatesTokenCount: 7, totalTokenCount: 18 } }]]));
  });
  checkResult(await google(model('google-generative-ai', 'google', f.baseUrl), context, { apiKey: 'fixture-key', maxRetries: 0 }).result());
  assert.equal(f.requests.length, 1);
  assert.match(f.requests[0].url, /streamGenerateContent/);
  assert.equal(f.requests[0].body.tools[0].functionDeclarations[0].name, 'lookup');
});

// AWS EventStream wire encoding, including both CRCs; the real Smithy transport
// and Bedrock decoder consume these bytes from a loopback HTTP response.
function awsEvent(type, payload) {
  const headers = Buffer.concat(Object.entries({ ':message-type': 'event', ':event-type': type, ':content-type': 'application/json' }).map(([name, value]) => {
    const key = Buffer.from(name), text = Buffer.from(value), sizes = Buffer.alloc(4);
    sizes[0] = key.length; sizes[1] = 7; sizes.writeUInt16BE(text.length, 2);
    return Buffer.concat([sizes.subarray(0, 1), key, sizes.subarray(1), text]);
  }));
  const body = Buffer.from(JSON.stringify(payload)), prelude = Buffer.alloc(12), checksum = Buffer.alloc(4);
  prelude.writeUInt32BE(16 + headers.length + body.length); prelude.writeUInt32BE(headers.length, 4);
  prelude.writeUInt32BE(crc32(prelude.subarray(0, 8)), 8);
  const message = Buffer.concat([prelude, headers, body]); checksum.writeUInt32BE(crc32(message));
  return Buffer.concat([message, checksum]);
}

test('Pi and current Bedrock/Smithy SDKs decode actual event-stream text, tools and usage', { timeout: 10000 }, async t => {
  const events = [['messageStart', { role: 'assistant' }], ['contentBlockDelta', { contentBlockIndex: 0, delta: { text: 'Offline text' } }], ['contentBlockStop', { contentBlockIndex: 0 }],
    ['contentBlockStart', { contentBlockIndex: 1, start: { toolUse: { toolUseId: 'call_fixture', name: 'lookup' } } }],
    ['contentBlockDelta', { contentBlockIndex: 1, delta: { toolUse: { input: '{"key":"fixture"}' } } }], ['contentBlockStop', { contentBlockIndex: 1 }],
    ['messageStop', { stopReason: 'tool_use' }], ['metadata', { usage: { inputTokens: 11, outputTokens: 7, totalTokens: 18 }, metrics: { latencyMs: 1 } }]];
  const f = await fixture(t, response => { response.writeHead(200, { 'content-type': 'application/vnd.amazon.eventstream' }); response.end(Buffer.concat(events.map(([type, body]) => awsEvent(type, body)))); });
  checkResult(await bedrock(model('bedrock-converse-stream', 'amazon-bedrock', f.baseUrl), context, {
    maxRetries: 0, env: { AWS_BEDROCK_SKIP_AUTH: '1', AWS_BEDROCK_FORCE_HTTP1: '1', AWS_REGION: 'us-east-1' },
  }).result());
  assert.equal(f.requests.length, 1);
  assert.match(f.requests[0].url, /converse-stream/);
  assert.equal(f.requests[0].body.toolConfig.tools[0].toolSpec.name, 'lookup');
});

test('Anthropic SDK v1 still aborts an in-flight Pi stream without completing its message', { timeout: 10000 }, async t => {
  const controller = new AbortController();
  const f = await fixture(t, response => {
    response.writeHead(200, { 'content-type': 'text/event-stream' });
    response.write(sse(anthropicEvents.slice(0, 3)));
  });
  const stream = anthropic(model('anthropic-messages', 'anthropic', f.baseUrl), context, { apiKey: 'fixture-key', signal: controller.signal, maxRetries: 0 });
  for await (const event of stream) if (event.type === 'text_delta') { controller.abort(); break; }
  assert.equal((await stream.result()).stopReason, 'aborted');
  assert.equal(f.requests.length, 1);
});
