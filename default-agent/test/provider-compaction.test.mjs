import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { ModelRuntime } from '@earendil-works/pi-coding-agent';
import { compactProviderContext, providerContinuationOptions, resolveProviderCompactionRoute, ProviderCompactionError } from '../src/provider-compaction.mjs';
import { sanitizeNativeTransportBytes } from '../src/native-journal.mjs';

const modelFor = (provider = 'openai') => ({ id: provider.startsWith('xai') ? 'grok-4.7' : 'gpt-5.3-codex', provider, api: provider === 'openai-codex' ? 'openai-codex-responses' : 'openai-responses', baseUrl: provider === 'openai-codex' ? 'https://chatgpt.com/backend-api' : provider.startsWith('xai') ? 'https://api.x.ai/v1' : 'https://api.openai.com/v1', reasoning: true, input: ['text', 'image'], compat: { supportsDeveloperRole: true }, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } });
const routeFor = model => ({ provider: model.provider, accountID: 'woven-account-a' });
const jwt = account => `fixture.${Buffer.from(JSON.stringify({ 'https://api.openai.com/auth': { chatgpt_account_id: account } })).toString('base64url')}.signature`;
const runtimeFor = (auth = { apiKey: 'fixture-api-key' }) => ({ getAuth: async () => ({ auth }) });
const contextFor = model => ({ messages: [
  { role: 'system', content: 'Keep the original instructions. 漢字', toolsAdded: [{ name: 'read', description: 'Read an image or file', parameters: { type: 'object', properties: { path: { type: 'string' } }, required: ['path'] } }] },
  { role: 'user', content: [{ type: 'text', text: 'Inspect the attachment' }, { type: 'image', mimeType: 'image/png', data: 'AA==' }], timestamp: 1 },
  { role: 'assistant', provider: model.provider, api: model.api, model: model.id, content: [
    { type: 'thinking', thinking: 'Exposed summary', thinkingSignature: JSON.stringify({ type: 'reasoning', id: 'rs_original', summary: [{ type: 'summary_text', text: 'Exposed summary' }], encrypted_content: 'opaque-prior-reasoning' }) },
    { type: 'toolCall', id: 'call_original|fc_original', name: 'read', arguments: { path: 'image.png' } },
  ], stopReason: 'toolUse', timestamp: 2 },
  { role: 'toolResult', toolCallId: 'call_original|fc_original', toolName: 'read', content: [{ type: 'text', text: 'Available file result with no truncation marker' }, { type: 'image', mimeType: 'image/png', data: 'AA==' }], isError: false, timestamp: 3 },
] });
const nativeFor = model => ({ id: 'cmp_native', object: 'response.compaction', model: model.id, created_at: 123,
  output: [
    { type: 'message', id: 'msg_retained', role: 'user', content: [{ type: 'input_text', text: 'Retained user content' }], provider_extension: { nested: ['keep', null, true] } },
    { type: 'function_call_output', call_id: 'call_native|unmodified', output: 'complete retained tool result', future_metadata: { revision: '2' } },
    { type: 'compaction', id: 'cmp_opaque', encrypted_content: 'opaque/+/🙂==\nunaltered', unknown_field: { ordered: ['b', 'a'], custom: 'unchanged' } },
    { type: 'future_context_item', id: 'future_native', unknown: { data: [1, 2, 3], attachment: 'provider-file-reference' } },
  ], usage: { input_tokens: 67890, input_tokens_details: { cached_tokens: 20, future_usage: 'preserve' }, output_tokens: 34, output_tokens_details: { reasoning_tokens: 12 }, total_tokens: 67924, dropped_message_count: 10 }, future_response_field: { keep: 'raw' },
});
const codexReply = native => new Response(`event: response.output_item.done\ndata: ${JSON.stringify({ type: 'response.output_item.done', item: native.output.find(item => item.type === 'compaction') })}\n\nevent: response.completed\ndata: ${JSON.stringify({ type: 'response.completed', response: { ...native, status: 'completed' } })}\n\n`, { headers: { 'Content-Type': 'text/event-stream' } });
const eventFrame = (type, body, ending = '\n') => `event: ${type}${ending}data: ${JSON.stringify({ type, ...body })}${ending}${ending}`;
const codexArgs = () => {
  const model = modelFor('openai-codex');
  return { model, route: routeFor(model), context: contextFor(model), runtime: runtimeFor({ apiKey: jwt('native-account-a') }) };
};
function fragmentedResponse(value, sizes = [1, 2, 7, 13]) {
  const bytes = Buffer.from(value); let offset = 0, index = 0;
  return new Response(new ReadableStream({ pull(controller) {
    if (offset === bytes.length) { controller.close(); return; }
    const count = sizes[index++ % sizes.length], end = Math.min(bytes.length, offset + count);
    controller.enqueue(bytes.subarray(offset, end)); offset = end;
  } }), { headers: { 'Content-Type': 'text/event-stream' } });
}

test('native compact preserves every output item, unknown field, raw response, tool ID and usage for continuation', async () => {
  const model = modelFor(), route = routeFor(model), native = nativeFor(model);
  const raw = JSON.stringify(native, null, 2) + '\n';
  let request;
  const result = await compactProviderContext({ model, route, runtime: runtimeFor(), context: contextFor(model), fetchRequest: async (url, init) => {
    request = { url, init, body: JSON.parse(init.body) }; return new Response(raw, { status: 200 });
  } });
  assert.equal(request.url, 'https://api.openai.com/v1/responses/compact');
  assert.equal(request.init.redirect, 'error');
  assert.equal(request.init.headers.get('authorization'), 'Bearer fixture-api-key');
  assert.equal(request.body.model, model.id);
  assert.ok(request.body.input.some(item => item.role === 'developer' && item.content.includes('original instructions')));
  assert.ok(request.body.input.some(item => item.content?.some?.(block => block.type === 'input_image' && block.image_url === 'data:image/png;base64,AA==')));
  assert.ok(request.body.input.some(item => item.type === 'reasoning' && item.encrypted_content === 'opaque-prior-reasoning'));
  assert.ok(request.body.input.some(item => item.type === 'function_call' && item.id === 'fc_original' && item.call_id === 'call_original'));
  assert.ok(request.body.input.some(item => item.type === 'function_call_output' && item.call_id === 'call_original'));
  assert.deepEqual(result.response, native);
  assert.equal(result.responseJSON, raw);
  assert.equal(result.continuation.windowJSON, raw);
  assert.deepEqual(result.continuation.output, native.output);
  assert.deepEqual(result.usage, native.usage);
  assert.deepEqual(result.continuation.usage, native.usage);
  assert.equal(result.continuation.accountID, 'woven-account-a');
  assert.ok(!JSON.stringify(result.continuation).includes('fixture-api-key'));
  const original = structuredClone(result.continuation);
  const options = await providerContinuationOptions({ model, route, runtime: runtimeFor(), continuation: result.continuation });
  const kept = [{ role: 'user', content: 'New input only' }], payload = { model: model.id, input: kept, instructions: 'Current instruction', tools: [{ type: 'function', name: 'read' }], store: false };
  const continued = options.onPayload(payload, model);
  assert.deepEqual(continued.input, [...native.output, ...kept]);
  assert.deepEqual(continued.tools, payload.tools);
  assert.equal(continued.instructions, payload.instructions);
  assert.deepEqual(payload.input, kept);
  continued.input[2].encrypted_content = 'mutated caller copy';
  assert.deepEqual(result.continuation, original);
  assert.deepEqual(options.onPayload(payload, model).input, [...native.output, ...kept]);
});

test('Codex subscription uses the exact ChatGPT compact endpoint and native account headers', async () => {
  const model = modelFor('openai-codex'), route = routeFor(model), native = nativeFor(model), token = jwt('native-chatgpt-account');
  for (const baseUrl of ['https://chatgpt.com/backend-api', 'https://chatgpt.com/backend-api/codex/', 'https://chatgpt.com/backend-api/codex/responses']) {
    let sent;
    const result = await compactProviderContext({ model, route, context: contextFor(model), runtime: runtimeFor({ apiKey: token, baseUrl, headers: { 'x-routing-fixture': 'preserve', 'Authorization': 'Bearer overridden-header', 'chatgpt-account-id': 'overridden-account' } }), fetchRequest: async (url, init) => {
      sent = { url, init, body: JSON.parse(init.body) }; return codexReply(native);
    } });
    assert.equal(sent.url, 'https://chatgpt.com/backend-api/codex/responses');
    assert.equal(sent.body.stream, true); assert.equal(sent.body.store, false);
    assert.deepEqual(sent.body.input.at(-1), { type: 'compaction_trigger' });
    assert.equal(sent.init.headers.get('authorization'), `Bearer ${token}`);
    assert.equal(sent.init.headers.get('chatgpt-account-id'), 'native-chatgpt-account');
    assert.equal(sent.init.headers.get('x-routing-fixture'), 'preserve');
    assert.equal(sent.body.instructions, 'Keep the original instructions. 漢字');
    assert.ok(!sent.body.input.some(item => item.role === 'system' || item.role === 'developer'));
    assert.equal(result.continuation.endpoint, 'https://chatgpt.com/backend-api/codex/responses');
    assert.equal(result.continuation.nativeAccountID, 'native-chatgpt-account');
    assert.ok(!JSON.stringify(result.continuation).includes(token));
  }
});

test('xAI API and subscription aliases keep native route identity distinct and use native Responses', async () => {
  for (const provider of ['xai', 'xai-api']) {
    const model = modelFor(provider), route = routeFor(model); let calls = 0;
    const result = await compactProviderContext({ model, route, runtime: runtimeFor(), context: contextFor(model), fetchRequest: async (url, init) => {
      calls++; assert.equal(url, 'https://api.x.ai/v1/responses/compact'); assert.equal(JSON.parse(init.body).model, 'grok-4.7'); return new Response(JSON.stringify(nativeFor(model)));
    } });
    assert.equal(calls, 1); assert.equal(result.continuation.provider, provider);
    const other = modelFor(provider === 'xai' ? 'xai-api' : 'xai');
    await assert.rejects(providerContinuationOptions({ model: other, route: routeFor(other), runtime: runtimeFor(), continuation: result.continuation }), error => error.code === 'route-mismatch');
  }
});

test('ModelRuntime auth endpoint and headers govern requests without replacing the selected route', async () => {
  const model = modelFor(); model.headers = { Authorization: 'Bearer model-fixture', 'x-header': 'model', 'x-remove': 'remove' };
  let sent;
  const runtime = runtimeFor({ baseUrl: 'https://chatgpt.com/backend-api/codex', headers: { Authorization: 'Bearer routed-fixture', 'chatgpt-account-id': 'selected-account', 'x-header': 'auth', 'x-remove': null } });
  const result = await compactProviderContext({ model, route: routeFor(model), runtime, context: contextFor(model), fetchRequest: async (url, init) => { sent = { url, init }; return codexReply(nativeFor(model)); } });
  assert.equal(sent.url, 'https://chatgpt.com/backend-api/codex/responses');
  assert.equal(sent.init.headers.get('authorization'), 'Bearer routed-fixture');
  assert.equal(sent.init.headers.get('x-header'), 'auth'); assert.equal(sent.init.headers.get('x-remove'), null);
  assert.equal(result.continuation.endpoint, 'https://chatgpt.com/backend-api/codex/responses');
  assert.equal(result.continuation.nativeAccountID, 'selected-account');
  const options = await providerContinuationOptions({ model, route: routeFor(model), runtime, continuation: result.continuation });
  // The model may retain its catalog base; runtime auth owns the request base.
  assert.equal(model.baseUrl, 'https://api.openai.com/v1');
  // Exercise the pinned production method: prepareRequest applies auth.baseUrl
  // before the SDK invokes onPayload. No provider request is made by this test.
  const requestRuntime = { models: { getProvider: () => ({ id: model.provider }) }, getAuth: runtime.getAuth };
  const prepared = await ModelRuntime.prototype.prepareRequest.call(requestRuntime, model, options);
  assert.equal(prepared.model.baseUrl, 'https://chatgpt.com/backend-api/codex');
  assert.deepEqual(prepared.options.onPayload({ model: model.id, input: [{ role: 'user', content: 'Kept delta' }] }, prepared.model).input, [...result.continuation.output, { role: 'user', content: 'Kept delta' }]);
  assert.throws(() => prepared.options.onPayload({ model: model.id, input: [] }, { ...prepared.model, baseUrl: 'https://api.openai.com/v1' }), error => error.code === 'route-mismatch');
  assert.throws(() => prepared.options.onPayload({ model: model.id, input: [] }, { ...prepared.model, headers: { 'chatgpt-account-id': 'other-native-account' } }), error => error.code === 'route-mismatch');
  await assert.rejects(ModelRuntime.prototype.prepareRequest.call({ ...requestRuntime, getAuth: async () => ({ auth: { baseUrl: prepared.model.baseUrl, headers: { Authorization: 'Bearer other-auth', 'chatgpt-account-id': 'other-native-account' } } }) }, model, options), error => error.code === 'route-mismatch');
  // A refreshed auth route must be checked again before opaque continuation.
  await assert.rejects(providerContinuationOptions({ model, route: routeFor(model), runtime: runtimeFor(), continuation: result.continuation }), error => error.code === 'route-mismatch');
  await assert.rejects(providerContinuationOptions({ model, route: routeFor(model), runtime: runtimeFor({ baseUrl: 'https://chatgpt.com/backend-api/codex', headers: { Authorization: 'Bearer replaced-auth', 'chatgpt-account-id': 'other-native-account' } }), continuation: result.continuation }), error => error.code === 'route-mismatch');
});

test('an OpenAI model routed through ChatGPT binds its actual native token account when no account header is supplied', async () => {
  const model = modelFor(), route = routeFor(model), auth = { apiKey: jwt('chatgpt-account-a'), baseUrl: 'https://chatgpt.com/backend-api/codex' };
  const result = await compactProviderContext({ model, route, runtime: runtimeFor(auth), context: contextFor(model), fetchRequest: async () => codexReply(nativeFor(model)) });
  assert.equal(result.continuation.nativeAccountID, 'chatgpt-account-a');
  await assert.rejects(providerContinuationOptions({ model, route, runtime: runtimeFor({ ...auth, apiKey: jwt('chatgpt-account-b') }), continuation: result.continuation }), error => error.code === 'route-mismatch');
  await assert.rejects(compactProviderContext({ model, route, runtime: runtimeFor({ ...auth, apiKey: 'unknown-opaque-auth' }), context: contextFor(model), fetchRequest: async () => assert.fail('Unknown native account route must not receive context') }), error => error.code === 'auth');
});

test('prior exact-route native window is compacted again intact, ahead of only new canonical messages', async () => {
  const model = modelFor(), route = routeFor(model), runtime = runtimeFor();
  const first = await compactProviderContext({ model, route, runtime, context: contextFor(model), fetchRequest: async () => new Response(JSON.stringify(nativeFor(model))) });
  let sent;
  const second = await compactProviderContext({ model, route, runtime, context: { messages: [{ role: 'user', content: 'New canonical delta', timestamp: 4 }] }, continuation: first.continuation, fetchRequest: async (_, init) => { sent = JSON.parse(init.body); return new Response(JSON.stringify(nativeFor(model))); } });
  assert.deepEqual(sent.input.slice(0, 4), first.continuation.output);
  assert.equal(sent.input.length, 5); assert.equal(sent.input.at(-1).content[0].text, 'New canonical delta');
  assert.deepEqual(second.continuation.output, first.continuation.output);
});

test('unsupported native transports and unverified custom endpoints make no compact request', async () => {
  let authCalls = 0, fetchCalls = 0;
  const runtime = { getAuth: async () => { authCalls++; return { auth: { apiKey: 'fixture' } }; } }, fetchRequest = async () => { fetchCalls++; throw new Error('Must not send'); };
  const claude = { ...modelFor(), provider: 'claude-subscription', api: 'woven-claude-native' };
  assert.deepEqual(await compactProviderContext({ model: claude, route: routeFor(claude), runtime, context: contextFor(claude), fetchRequest }), { unsupported: true });
  const unsupported = { ...modelFor('xai-api'), api: 'openai-completions' };
  assert.deepEqual(await compactProviderContext({ model: unsupported, route: routeFor(unsupported), runtime, context: contextFor(unsupported), fetchRequest }), { unsupported: true });
  assert.equal(authCalls, 0);
  const custom = { ...modelFor(), baseUrl: 'https://configured-proxy.example/v1' };
  assert.deepEqual(await compactProviderContext({ model: custom, route: routeFor(custom), runtime, context: contextFor(custom), fetchRequest }), { unsupported: true });
  assert.equal(authCalls, 1); assert.equal(fetchCalls, 0);
});

test('HTTP responses retain raw failures and only explicit capability absence permits fallback', async () => {
  const cases = [
    [404, { detail: 'Not Found' }, 'endpoint'], [405, {}, 'endpoint'], [501, {}, 'endpoint'],
    [400, { error: { code: 'unsupported_endpoint' } }, 'endpoint'],
    [400, { error: { code: 'unsupported_compaction' } }, 'capability'],
    [422, { error: { code: 'model_not_supported' } }, 'capability'],
    [400, { error: { code: 'invalid_request_error', message: 'This model does not support compaction.' } }, 'capability'],
    [401, { error: { code: 'invalid_api_key' }, usage: { total_tokens: 4 } }], [403, { error: { code: 'unsupported_compaction' } }],
    [400, { error: { code: 'invalid_request_error' } }], [404, { error: { code: 'model_not_found' } }],
    [408, { error: { code: 'timeout' } }], [429, { error: { code: 'rate_limit_exceeded' } }],
    [500, { error: { code: 'internal_error', message: 'Private provider diagnostic' } }], [503, { error: { code: 'not_implemented' } }],
    [500, 'available failure bytes'], [200, 'native malformed body\n'], [404, 'actual endpoint absence', 'endpoint'],
  ];
  for (const provider of ['openai', 'openai-codex']) {
    const model = modelFor(provider), args = { model, route: routeFor(model), context: contextFor(model), runtime: runtimeFor({ apiKey: provider === 'openai-codex' ? jwt('native-account-a') : 'fixture-api-key' }) };
    for (const [status, body, absence] of cases) {
      if (status === 200 && provider === 'openai-codex') continue; // Successful Codex replies use the SSE fixtures below.
      const raw = typeof body === 'string' ? body : JSON.stringify(body);
      const promise = compactProviderContext({ ...args, fetchRequest: async () => new Response(raw, { status }) });
      const checkRaw = record => { assert.equal(record.responseJSON, raw); assert.equal(record.status, status); assert.ok(!JSON.stringify(record).includes('fixture-api-key')); };
      if (absence === 'capability' || absence === 'endpoint' && provider === 'openai') {
        const result = await promise; assert.equal(result.unsupported, true); checkRaw(result.nativeResponse);
      } else await assert.rejects(promise, error => {
        assert.ok(error instanceof ProviderCompactionError); assert.equal(error.code, [401, 403].includes(status) ? 'auth' : status === 200 ? 'invalid-response' : 'provider');
        assert.ok(!error.message.includes('Private provider diagnostic')); checkRaw(error.nativeResponse); return true;
      });
    }
    let attempts = 0;
    await assert.rejects(compactProviderContext({ ...args, fetchRequest: async () => { attempts++; throw new Error('Lost native response'); } }), error => error.code === 'transport');
    assert.equal(attempts, 1);
    await assert.rejects(compactProviderContext({ ...args, runtime: { getAuth: async () => { throw new Error('Native auth resolution failure'); } }, fetchRequest: async () => assert.fail('Must not send') }), /Native auth resolution failure/);
  }
});

test('route changes fail closed before sending an old opaque window; original canonical input can start a fresh route', async () => {
  const model = modelFor(), route = routeFor(model), runtime = runtimeFor(), context = contextFor(model);
  const saved = (await compactProviderContext({ model, route, runtime, context, fetchRequest: async () => new Response(JSON.stringify(nativeFor(model))) })).continuation;
  let requests = 0;
  for (const [otherModel, otherRoute] of [[{ ...model, id: 'different-model' }, route], [model, { ...route, accountID: 'other-account' }], [modelFor('xai'), routeFor(modelFor('xai'))]]) {
    await assert.rejects(compactProviderContext({ model: otherModel, route: otherRoute, runtime, context, continuation: saved, fetchRequest: async () => { requests++; assert.fail('Old opaque state must not be sent'); } }), error => error.code === 'route-mismatch');
    await assert.rejects(providerContinuationOptions({ model: otherModel, route: otherRoute, runtime, continuation: saved }), error => error.code === 'route-mismatch');
  }
  assert.equal(requests, 0);
  const switched = { ...model, id: 'different-model' };
  await compactProviderContext({ model: switched, route, runtime, context, fetchRequest: async (_, init) => {
    const input = JSON.parse(init.body).input;
    assert.ok(!input.some(item => item.type === 'compaction'));
    assert.ok(input.some(item => item.role === 'user'));
    return new Response(JSON.stringify(nativeFor(switched)));
  } });
});

test('Codex token routing, missing authorization and redirects cannot fall back to another credential product', async () => {
  const model = modelFor('openai-codex'), route = routeFor(model), context = contextFor(model); let requests = 0;
  for (const baseUrl of ['https://api.openai.com/v1', 'https://api.x.ai/v1', 'https://chatgpt.com.evil.example/backend-api', 'https://chatgpt.com/backend-api?route=other', 'http://chatgpt.com/backend-api', 'https://user:secret@chatgpt.com/backend-api']) {
    await assert.rejects(compactProviderContext({ model, route, context, runtime: runtimeFor({ apiKey: jwt('fixture'), baseUrl }), fetchRequest: async () => { requests++; assert.fail('Credential route must not be sent'); } }), error => error.code === 'route-mismatch');
  }
  await assert.rejects(compactProviderContext({ model, route, context, runtime: runtimeFor({ apiKey: 'not-a-codex-account-token' }), fetchRequest: async () => { requests++; assert.fail('No native account identity'); } }), error => error.code === 'auth');
  await assert.rejects(compactProviderContext({ model: modelFor(), route: routeFor(modelFor()), context, runtime: runtimeFor({}), fetchRequest: async () => { requests++; assert.fail('No authorization'); } }), error => error.code === 'auth');
  assert.equal(requests, 0);
  await assert.rejects(compactProviderContext({ model, route, context, runtime: runtimeFor({ apiKey: jwt('fixture') }), fetchRequest: async (_, init) => { assert.equal(init.redirect, 'error'); throw new TypeError('Redirect rejected'); } }), error => error.code === 'transport');
});

test('malformed or empty native snapshots do not replace the existing window', async () => {
  const model = modelFor(), args = { model, route: routeFor(model), context: contextFor(model), runtime: runtimeFor() };
  for (const body of ['not-json', '{}', '{"output":[]}', '{"output":[null]}', '{"output":[[]]}', JSON.stringify({ ...nativeFor(model), model: 'unexpected-model' })]) {
    await assert.rejects(compactProviderContext({ ...args, fetchRequest: async () => new Response(body) }), error => error.code === 'invalid-response');
  }
  const saved = (await compactProviderContext({ ...args, fetchRequest: async () => new Response(JSON.stringify(nativeFor(model))) })).continuation;
  const options = await providerContinuationOptions({ ...args, continuation: saved });
  for (const payload of [{ model: 'other', input: [] }, { model: model.id, input: 'flattened text' }]) assert.throws(() => options.onPayload(payload, model), error => error.code === 'route-mismatch');
  assert.throws(() => options.onPayload({ model: model.id, input: [] }, { ...model, api: 'openai-completions' }), error => error.code === 'route-mismatch');
});

test('future native numeric fields preserve exact JSON values across durable checkpoint and subsequent requests', async () => {
  const model = modelFor(), route = routeFor(model), runtime = runtimeFor();
  const raw = '{"output":[{"type":"compaction","id":"cmp_large","encrypted_content":"opaque","future_integer":9007199254740993,"future_decimal":0.123456789123456789123456789,"future_tiny":1e-999,"future_large":1e999,"negative_zero":-0}]}';
  const result = await compactProviderContext({ model, route, runtime, context: contextFor(model), fetchRequest: async () => new Response(raw) });
  const restored = JSON.parse(JSON.stringify(result.continuation));
  assert.equal(restored.windowJSON, raw);
  const options = await providerContinuationOptions({ model, route, runtime, continuation: restored });
  const payload = JSON.stringify(options.onPayload({ model: model.id, input: [{ role: 'user', content: 'New' }] }, model));
  for (const value of ['"future_integer":9007199254740993', '"future_decimal":0.123456789123456789123456789', '"future_tiny":1e-999', '"future_large":1e999', '"negative_zero":-0']) assert.ok(payload.includes(value));
  await compactProviderContext({ model, route, runtime, context: { messages: [{ role: 'user', content: 'Next prefix', timestamp: 4 }] }, continuation: restored, fetchRequest: async (_url, init) => {
    assert.ok(init.body.includes('"future_integer":9007199254740993'));
    assert.ok(init.body.includes('"future_decimal":0.123456789123456789123456789'));
    assert.ok(init.body.includes('"future_tiny":1e-999'));
    return new Response(raw);
  } });
});

test('native account and credential replacement fail closed without persisting transport secrets', async () => {
  const args = codexArgs();
  args.route.authIdentity = 'credential-identity-a';
  args.runtime = runtimeFor({ apiKey: jwt('native-account-a'), headers: { 'x-auth-private': 'private-header' } });
  const selected = await resolveProviderCompactionRoute(args);
  assert.equal(selected.authIdentity, args.route.authIdentity);
  assert.equal(selected.nativeAccountID, 'native-account-a');
  assert.equal(selected.endpoint, 'https://chatgpt.com/backend-api/codex/responses');
  assert.ok(!JSON.stringify(selected).includes('private-header')); assert.ok(!JSON.stringify(selected).includes(jwt('native-account-a')));
  const saved = (await compactProviderContext({ ...args, fetchRequest: async () => codexReply(nativeFor(args.model)) })).continuation;
  assert.equal(saved.authIdentity, args.route.authIdentity);
  for (const changed of [
    { runtime: runtimeFor({ apiKey: jwt('native-account-b') }) },
    { route: { ...args.route, authIdentity: 'credential-identity-b' } },
    { route: routeFor(args.model) },
  ]) {
    await assert.rejects(providerContinuationOptions({ ...args, ...changed, continuation: saved }), error => error.code === 'route-mismatch');
    await assert.rejects(compactProviderContext({ ...args, ...changed, continuation: saved, fetchRequest: async () => assert.fail('Changed identity must not receive opaque context') }), error => error.code === 'route-mismatch');
  }
  const options = await providerContinuationOptions({ ...args, continuation: saved });
  assert.deepEqual(options.onPayload({ model: args.model.id, input: [] }, { ...args.model, headers: { 'chatgpt-account-id': null } }).input, saved.output);
  assert.deepEqual(options.transformHeaders({ 'chatgpt-account-id': null }), { 'chatgpt-account-id': null });
  await assert.rejects(compactProviderContext({ ...args, route: { ...args.route, nativeAccountID: 'native-account-a' }, runtime: runtimeFor({ apiKey: jwt('native-account-b') }), fetchRequest: async () => assert.fail('Fresh auth must be fenced before the first fetch') }), error => error.code === 'route-mismatch');
});

test('Codex trigger SSE survives fragmented UTF-8 and preserves exposed records separately from the native replacement window', async () => {
  const args = codexArgs();
  const itemJSON = '{"type":"compaction","id":"cmp_opaque","encrypted_content":"opaque🙂漢字","future_integer":9007199254740993,"future_decimal":0.123456789123456789,"unknown":{"attachment":"file-reference"}}';
  const responseJSON = `{"id":"resp_compact","model":"${args.model.id}","status":"completed","output":[${itemJSON},{"type":"future_record","tool_call_id":"call_keep|native_item"}],"usage":{"input_tokens":70,"output_tokens":8,"total_tokens":78,"future":9007199254740993}}`;
  const stream = ': native keepalive\r\nid: native-1\r\nretry: 500\r\n\r\n' + 'event: provider.future\r\ndata: opaque future text 漢字\r\n\r\n' + `event: response.output_item.done\r\ndata: {"type":"response.output_item.done",\r\ndata: "item":${itemJSON}}\r\n\r\n` + `event: response.completed\ndata: {"type":"response.completed","response":${responseJSON}}\n\n`;
  let request;
  const result = await compactProviderContext({ ...args, fetchRequest: async (url, init) => { request = { url, init, body: JSON.parse(init.body) }; return fragmentedResponse(stream); } });
  assert.equal(request.url, 'https://chatgpt.com/backend-api/codex/responses');
  assert.equal(request.init.headers.get('accept'), 'text/event-stream');
  assert.deepEqual(request.body.input.at(-1), { type: 'compaction_trigger' });
  assert.equal(request.body.tools[0].name, 'read'); assert.equal(request.body.tools[0].strict, null);
  assert.equal(result.responseJSON, responseJSON); assert.equal(result.rawSSE, stream);
  assert.deepEqual(Buffer.from(result.rawSSEBase64, 'base64'), Buffer.from(stream));
  assert.equal(result.rawSSEBytes.byteFidelity, 'exact-native-bytes');
  assert.equal(result.nativeEvents.length, 4); assert.equal(result.nativeEvents[0].id, 'native-1'); assert.equal(result.nativeEvents[0].retry, '500');
  assert.equal(result.nativeEvents[1].data, 'opaque future text 漢字');
  assert.equal(result.response.output[1].tool_call_id, 'call_keep|native_item');
  assert.equal(result.continuation.nativeTransport, 'codex-compaction-trigger');
  assert.equal(result.continuation.output.length, 2);
  assert.equal(result.continuation.output[0].role, 'user');
  assert.equal(result.continuation.output[1].type, 'compaction');
  assert.ok(!result.continuation.output.some(item => item.type === 'function_call_output' || item.type === 'future_record'));
  assert.ok(result.continuation.windowJSON.includes('"future_integer":9007199254740993'));
  const restored = JSON.parse(JSON.stringify(result.continuation));
  const options = await providerContinuationOptions({ ...args, continuation: restored });
  const next = JSON.stringify(options.onPayload({ model: args.model.id, input: [{ role: 'user', content: 'Only new delta' }] }, args.model));
  assert.ok(next.includes('"future_decimal":0.123456789123456789')); assert.ok(next.includes('"future_integer":9007199254740993'));
  await compactProviderContext({ ...args, continuation: restored, context: { messages: [{ role: 'user', content: 'Only new prefix', timestamp: 4 }] }, fetchRequest: async (_, init) => {
    assert.ok(init.body.includes('"future_integer":9007199254740993'));
    const input = JSON.parse(init.body).input;
    assert.deepEqual(input.slice(0, 2), restored.output); assert.equal(input.at(-2).content[0].text, 'Only new prefix');
    assert.equal(input.filter(item => item.type === 'compaction_trigger').length, 1);
    return fragmentedResponse(stream, [31, 2, 41]);
  } });
});

test('Codex trigger requires exactly one finished opaque item and a valid successful completion', async () => {
  const args = codexArgs(), item = { type: 'compaction', id: 'cmp', encrypted_content: 'opaque' };
  const compact = eventFrame('response.output_item.done', { item }), complete = eventFrame('response.completed', { response: { id: 'response', status: 'completed' } });
  for (const stream of [complete, compact, compact + compact + complete, eventFrame('response.output_item.done', { item: { ...item, encrypted_content: '' } }) + complete, compact + eventFrame('response.completed', { response: { id: 'response', status: 'incomplete' } }), compact + eventFrame('response.completed', { response: { id: 'response', model: 'other-model' } }), compact + complete + complete, 'event: response.output_item.done\ndata: malformed-json\n\n']) {
    await assert.rejects(compactProviderContext({ ...args, fetchRequest: async () => fragmentedResponse(stream, [Buffer.byteLength(stream)]) }), error => {
      assert.equal(error.code, 'invalid-response'); assert.equal(error.nativeResponse.rawSSE, stream);
      assert.deepEqual(Buffer.from(error.nativeResponse.rawSSEBase64, 'base64'), Buffer.from(stream));
      assert.ok(!error.nativeResponse.continuation); return true;
    });
  }
});

test('failed and genuinely unsupported native streams retain exposed records and usage without installing context', async () => {
  const args = codexArgs();
  const failure = eventFrame('response.failed', { response: { id: 'failed-native', status: 'failed', usage: { input_tokens: 20, output_tokens: 2, total_tokens: 22 }, error: { code: 'internal_error', message: 'Available provider failure record' } } });
  await assert.rejects(compactProviderContext({ ...args, fetchRequest: async () => fragmentedResponse(failure) }), error => {
    assert.equal(error.code, 'provider'); assert.equal(error.nativeResponse.rawSSE, failure); assert.equal(error.nativeResponse.usage.total_tokens, 22);
    assert.equal(error.nativeResponse.nativeEvents[0].type, 'response.failed'); assert.ok(!error.nativeResponse.continuation); return true;
  });
  const unsupported = eventFrame('error', { error: { code: 'unsupported_compaction', message: 'Compaction unsupported on this model' } });
  const result = await compactProviderContext({ ...args, fetchRequest: async () => fragmentedResponse(unsupported) });
  assert.equal(result.unsupported, true); assert.equal(result.nativeResponse.rawSSE, unsupported); assert.equal(result.nativeResponse.nativeEvents[0].type, 'error');
  const started = eventFrame('response.output_item.added', { item: { type: 'compaction', id: 'started' } }) + unsupported;
  await assert.rejects(compactProviderContext({ ...args, fetchRequest: async () => fragmentedResponse(started) }), error => error.code === 'provider' && error.nativeResponse.rawSSE === started);
});

test('native stream loss and cancellation retain exact received bytes, cancel the reader, and never retry', async () => {
  const args = codexArgs(), frame = eventFrame('response.created', { response: { id: 'partial', usage: { input_tokens: 30 } } });
  const partial = frame + 'event: response.output_item.done\ndata: {"item":'; let attempts = 0;
  await assert.rejects(compactProviderContext({ ...args, fetchRequest: async () => {
    attempts++; let read = 0;
    return new Response(new ReadableStream({ pull(controller) { if (!read++) controller.enqueue(Buffer.from(partial)); else controller.error(new Error('Fixture connection loss')); } }));
  } }), error => {
    assert.equal(error.code, 'transport'); assert.equal(error.nativeResponse.rawSSE, partial); assert.equal(error.nativeResponse.nativeEvents.length, 1);
    assert.equal(error.nativeResponse.usage.input_tokens, 30); return true;
  });
  assert.equal(attempts, 1);
  const abort = new AbortController(); let cancelled = false;
  await assert.rejects(compactProviderContext({ ...args, signal: abort.signal, fetchRequest: async () => {
    setTimeout(() => abort.abort('Fixture primitive abort reason'), 10);
    return new Response(new ReadableStream({ start(controller) { controller.enqueue(Buffer.from(partial)); }, cancel() { cancelled = true; } }));
  } }), error => error.nativeResponse.rawSSE === partial && !error.nativeResponse.continuation);
  assert.equal(cancelled, true);
});

test('a terminal SSE event with unfinished UTF-8 is rejected while preserving its exact received byte representation', async () => {
  const args = codexArgs(), native = nativeFor(args.model);
  const bytes = Buffer.concat([Buffer.from(await codexReply(native).text()), Buffer.from([0xf0, 0x9f])]);
  await assert.rejects(compactProviderContext({ ...args, fetchRequest: async () => fragmentedResponse(bytes, [bytes.length]) }), error => {
    assert.equal(error.code, 'transport'); assert.deepEqual(Buffer.from(error.nativeResponse.rawSSEBase64, 'base64'), bytes);
    assert.equal(error.nativeResponse.rawSSEBytes.byteFidelity, 'exact-native-bytes'); return true;
  });
});

test('base64 native transport copies sanitize known Woven capabilities before encoding and preserve arbitrary user base64', async () => {
  const args = codexArgs(), capability = '/private/tmp/wmtools-' + 'a'.repeat(32) + '/' + 'b'.repeat(32) + '.sock', arbitraryUserBase64 = Buffer.from(capability).toString('base64');
  const native = nativeFor(args.model); native.provider_echo = capability;
  native.output.find(item => item.type === 'compaction').future_metadata = { capability, arbitraryUserBase64 };
  const stream = await codexReply(native).text();
  const result = await compactProviderContext({ ...args, fetchRequest: async () => fragmentedResponse(stream) });
  const encodedCopy = Buffer.from(result.rawSSEBase64, 'base64');
  assert.ok(!encodedCopy.toString().includes(capability)); assert.ok(!encodedCopy.toString().includes('wmtools-'));
  assert.ok(encodedCopy.toString().includes(arbitraryUserBase64));
  assert.equal(result.rawSSEBytes.byteFidelity, 'tool-endpoint-redacted');
  assert.equal(result.rawSSEBytes.sourceSHA256, createHash('sha256').update(stream).digest('hex'));
  assert.equal(result.rawSSEBytes.sha256, createHash('sha256').update(encodedCopy).digest('hex'));
  assert.equal(result.rawSSEBytes.totalBytes, encodedCopy.length); assert.equal(result.rawSSEBytes.sourceBytes, Buffer.byteLength(stream));
  // The central copy also sanitizes the ordinary plaintext/native JSON fields.
  // Its already encoded duplicate must not bypass that same privacy boundary.
  const central = await sanitizeNativeTransportBytes(Buffer.from(JSON.stringify(result))), stored = JSON.parse(central.bytes);
  assert.ok(!central.bytes.toString().includes('wmtools-')); assert.ok(!Buffer.from(stored.rawSSEBase64, 'base64').toString().includes('wmtools-'));
  assert.equal(stored.continuation.output[1].future_metadata.arbitraryUserBase64, arbitraryUserBase64);
  assert.ok(result.responseJSON.includes(capability)); // Execution-host native content remains authoritative.
});

test('manual compaction instructions reach each actual native protocol without replacing the system prompt', async () => {
  const instructions = 'Keep unresolved bug IDs and the acceptance checklist. 漢字';
  for (const provider of ['openai', 'xai-api', 'openai-codex']) {
    const model = modelFor(provider), args = { model, route: routeFor(model), runtime: runtimeFor({ apiKey: provider === 'openai-codex' ? jwt('native-account-a') : 'fixture' }), context: contextFor(model), instructions };
    await compactProviderContext({ ...args, fetchRequest: async (_, init) => {
      const body = JSON.parse(init.body);
      if (provider === 'openai') assert.equal(body.instructions, instructions);
      else if (provider === 'openai-codex') { assert.ok(body.instructions.startsWith('Keep the original instructions. 漢字')); assert.ok(body.instructions.endsWith(instructions)); }
      else { assert.equal(body.instructions, undefined); assert.equal(body.input.at(-1).role, 'user'); assert.ok(body.input.at(-1).content[0].text.endsWith(instructions)); }
      return provider === 'openai-codex' ? codexReply(nativeFor(model)) : new Response(JSON.stringify(nativeFor(model)));
    } });
  }
});
