import { convertResponsesMessages, convertResponsesTools } from '@earendil-works/pi-ai/api/openai-responses-shared';
import { createGrammarToolInputProperties } from '@earendil-works/pi-ai/api/constrained-sampling';
import { getDeclaredTools, getInitialSystemMessage, resolveTranscript, resolveTranscriptTools } from '@earendil-works/pi-ai/utils/transcript';
import { getSystemMessageText } from '@earendil-works/pi-ai/utils/text';
import { sanitizeNativeTransportBytes } from './native-journal.mjs';

// Native compact output is a new context window, not a summary. Keep every
// returned item (including unknown types) outside Pi's Message parser.
// https://developers.openai.com/api/docs/guides/compaction
// https://docs.x.ai/developers/advanced-api-usage/context-compaction
// Codex uses its current Responses trigger protocol on the ChatGPT route.
const TOOL_CALL_PROVIDERS = new Set(['openai', 'openai-codex', 'opencode']);
const NATIVE_PROVIDERS = new Set(['openai', 'openai-codex', 'xai', 'xai-api']);
const UNSUPPORTED_CODES = new Set(['unsupported_model', 'model_not_supported', 'unsupported_compaction', 'compaction_not_supported', 'unsupported_endpoint', 'not_implemented']);
const clone = value => structuredClone(value);
const nativeAccountHeader = values => (values instanceof Headers ? values : new Headers(Object.entries(values ?? {}).filter(([, value]) => value !== null && value !== undefined))).get('chatgpt-account-id');

function tokenAccount(token) {
  try {
    const account = JSON.parse(Buffer.from(token.split('.')[1], 'base64url').toString('utf8'))?.['https://api.openai.com/auth']?.chatgpt_account_id;
    return typeof account === 'string' && account ? account : undefined;
  } catch { return undefined; }
}

export class ProviderCompactionError extends Error {
  constructor(code, message, { status, cause } = {}) {
    super(message, cause ? { cause } : undefined);
    this.name = 'ProviderCompactionError';
    this.code = code;
    if (status !== undefined) this.status = status;
  }
}

function validateRoute(model, route) {
  if (!model || typeof model.id !== 'string' || !model.id || !route || route.provider !== model.provider || typeof route.accountID !== 'string' || !route.accountID || (route.authIdentity !== undefined && (typeof route.authIdentity !== 'string' || !route.authIdentity))) {
    throw new ProviderCompactionError('route-mismatch', 'Native compaction requires the selected model and account route.');
  }
}

function responseEndpoint(model, auth) {
  if (!NATIVE_PROVIDERS.has(model.provider) || !['openai-responses', 'openai-codex-responses'].includes(model.api)) return undefined;
  if ((model.api === 'openai-codex-responses') !== (model.provider === 'openai-codex')) {
    throw new ProviderCompactionError('route-mismatch', 'The native Responses transport does not match its provider.');
  }
  const raw = auth?.baseUrl ?? model.baseUrl;
  let base;
  try { base = new URL(raw); } catch { throw new ProviderCompactionError('route-mismatch', 'Native compaction requires an explicit provider endpoint.'); }
  if (base.protocol !== 'https:' || base.username || base.password || base.search || base.hash) {
    throw new ProviderCompactionError('route-mismatch', 'Native compaction requires a secure provider endpoint without credentials or query parameters.');
  }
  const path = base.pathname.replace(/\/+$/, '');
  if (model.provider === 'openai-codex') {
    // Match Pi 1.0.3 resolveCodexUrl. A Codex token never goes to api.openai.com.
    if (base.origin !== 'https://chatgpt.com' || !['/backend-api', '/backend-api/codex', '/backend-api/codex/responses'].includes(path)) {
      throw new ProviderCompactionError('route-mismatch', 'The Codex compaction endpoint must stay on its authenticated ChatGPT route.');
    }
    return 'https://chatgpt.com/backend-api/codex/responses';
  }
  if (model.provider === 'openai') {
    // ModelRuntime owns the credential's routing. OpenAI's direct subscription
    // auth and Codex subscription auth are different products; do not guess
    // their type from a token prefix or replace auth.baseUrl with a default.
    if (base.origin === 'https://api.openai.com' && ['/v1', '/v1/responses'].includes(path)) return 'https://api.openai.com/v1/responses';
    if (base.origin === 'https://chatgpt.com' && ['/backend-api/codex', '/backend-api/codex/responses'].includes(path)) return 'https://chatgpt.com/backend-api/codex/responses';
  } else if (base.origin === 'https://api.x.ai' && ['/v1', '/v1/responses'].includes(path)) {
    return 'https://api.x.ai/v1/responses';
  }
  if (['https://api.openai.com', 'https://chatgpt.com', 'https://api.x.ai'].includes(base.origin) && ((model.provider === 'openai' && base.origin === 'https://api.x.ai') || (model.provider.startsWith('xai') && base.origin !== 'https://api.x.ai'))) {
    throw new ProviderCompactionError('route-mismatch', 'Native compaction cannot move the selected credential to a different provider product.');
  }
  // A custom Responses-compatible provider is not evidence that it offers this
  // native endpoint. Its existing Pi compaction remains available.
  return undefined;
}

function identity(model, route, endpoint) {
  const codex = endpoint.startsWith('https://chatgpt.com/backend-api/codex/');
  return { provider: model.provider, accountID: route.accountID, modelID: model.id, api: model.api, endpoint, compactEndpoint: codex ? endpoint : `${endpoint}/compact`, nativeTransport: codex ? 'codex-compaction-trigger' : 'responses-compact', authIdentity: route.authIdentity };
}

function validateContinuation(continuation, expected) {
  if (!continuation || typeof continuation.windowJSON !== 'string' || !Array.isArray(continuation.output) || !continuation.output.length || Object.entries(expected).some(([key, value]) => continuation[key] !== value)) {
    throw new ProviderCompactionError('route-mismatch', 'Native compacted context belongs to a different model, account, or endpoint.');
  }
}

function continuationWindow(continuation) {
  // Node 24's parse source and rawJSON preserve provider-owned numeric values
  // that cannot round-trip through a JavaScript Number. The raw native response
  // remains the authoritative checkpoint; parsed output is a useful projection.
  // Do this after parsing, at the request layer, so opaque/unknown items never
  // pass through Pi's Message parser or a summary string.
  try {
    const native = parseLosslessJSON(continuation.windowJSON);
    if (!Array.isArray(native?.output) || !native.output.length || native.output.some(item => !item || typeof item !== 'object' || Array.isArray(item))) throw new Error('Missing native window');
    return native.output;
  } catch { throw new ProviderCompactionError('invalid-response', 'The saved native compaction window is unavailable.'); }
}

function parseLosslessJSON(raw) {
  return JSON.parse(raw, (_key, value, context) => typeof value === 'number' && context?.source && JSON.stringify(value) !== context.source ? JSON.rawJSON(context.source) : value);
}

// The SSE data frame is retained exactly. Extract the original response/item
// JSON fragment rather than re-encoding provider-owned future numeric fields.
function rawJSONProperty(raw, name) {
  const space = index => { while (/\s/.test(raw[index] ?? '') && index < raw.length) index++; return index; };
  const end = start => {
    let quoted = false, escaped = false, depth = 0;
    for (let index = start; index < raw.length; index++) {
      const character = raw[index];
      if (quoted) { if (escaped) escaped = false; else if (character === '\\') escaped = true; else if (character === '"') { quoted = false; if (!depth) return index + 1; } }
      else if (character === '"') quoted = true;
      else if (character === '{' || character === '[') depth++;
      else if (character === '}' || character === ']') { if (!depth) return index; if (!--depth) return index + 1; }
      else if (!depth && (character === ',' || /\s/.test(character))) return index;
    }
    return raw.length;
  };
  let index = space(0) + 1, found;
  while (index < raw.length) {
    index = space(index); if (raw[index] === '}') break;
    const keyEnd = end(index), key = JSON.parse(raw.slice(index, keyEnd));
    index = space(keyEnd) + 1; index = space(index);
    const valueEnd = end(index);
    if (key === name) found = raw.slice(index, valueEnd);
    index = space(valueEnd); if (raw[index] === ',') index++; else break;
  }
  return found;
}

async function resolveRoute({ model, route, runtime, signal }) {
  validateRoute(model, route);
  // Avoid resolving auth at all for a transport without this native API.
  if (!NATIVE_PROVIDERS.has(model.provider) || !['openai-responses', 'openai-codex-responses'].includes(model.api)) return undefined;
  if (!runtime || typeof runtime.getAuth !== 'function') throw new ProviderCompactionError('auth', 'Native compaction requires the model runtime authentication route.');
  const result = await runtime.getAuth(model, { signal, allowWait: false });
  if (!result?.auth) throw new ProviderCompactionError('auth', 'The selected account is unavailable for native compaction.');
  const endpoint = responseEndpoint(model, result.auth);
  if (!endpoint) return undefined;
  const headers = requestHeaders(model, result.auth);
  const selected = identity(model, route, endpoint);
  if (endpoint.startsWith('https://chatgpt.com/backend-api/codex/')) {
    const account = headers.get('chatgpt-account-id') || tokenAccount(headers.get('Authorization').replace(/^Bearer\s+/i, ''));
    if (!account) throw new ProviderCompactionError('auth', 'The selected ChatGPT compaction route has no authenticated account identity.');
    selected.nativeAccountID = account;
    if (route.nativeAccountID !== undefined && route.nativeAccountID !== account) throw new ProviderCompactionError('route-mismatch', 'The authenticated ChatGPT account changed before native compaction.');
  }
  return { identity: selected, headers };
}

/** Resolve sanitized native route provenance without returning credentials. */
export async function resolveProviderCompactionRoute(options) {
  const resolved = await resolveRoute(options);
  return resolved ? clone(resolved.identity) : undefined;
}

function requestHeaders(model, auth) {
  const headers = new Headers();
  if (auth.apiKey) headers.set('Authorization', `Bearer ${auth.apiKey}`);
  for (const values of [model.headers, auth.headers]) {
    for (const [key, value] of Object.entries(values ?? {})) {
      if (value === null) headers.delete(key); else if (value !== undefined) headers.set(key, value);
    }
  }
  if (!headers.has('Authorization')) throw new ProviderCompactionError('auth', 'The selected native compaction route has no authorization.');
  if (model.provider === 'openai-codex') {
    // Pi's Codex transport uses the account claim in its token in addition to
    // Woven's account selection. Only the non-secret identity is persisted.
    const account = tokenAccount(auth.apiKey);
    if (!account) throw new ProviderCompactionError('auth', 'The selected Codex credential has no authenticated account identity.');
    headers.set('Authorization', `Bearer ${auth.apiKey}`);
    headers.set('chatgpt-account-id', account);
    if (!headers.has('originator')) headers.set('originator', 'pi');
    headers.set('OpenAI-Beta', 'responses=experimental');
  }
  headers.set('Content-Type', 'application/json');
  headers.set('Accept', 'application/json');
  return headers;
}

function compactInput(model, context, isCodex = model.api === 'openai-codex-responses') {
  if (!context || !Array.isArray(context.messages)) throw new ProviderCompactionError('invalid-context', 'Native compaction requires a canonical transcript.');
  const transcript = resolveTranscript(context, model.compat?.supportsMidConvoSystemMessages ?? false);
  const input = convertResponsesMessages(model, transcript, TOOL_CALL_PROVIDERS, {
    grammarToolInputProperties: createGrammarToolInputProperties(getDeclaredTools(transcript.messages), model.compat?.supportsOpenAIGrammarTools ?? false),
    includeSystemPrompt: !isCodex,
    supportsMidConvoSystemMessages: model.compat?.supportsMidConvoSystemMessages ?? false,
    supportsAdditionalTools: model.compat?.supportsAdditionalTools ?? false,
    supportsToolSearch: model.compat?.supportsToolSearch ?? false,
    toolOptions: { strict: isCodex ? null : undefined, supportsStrictMode: model.compat?.supportsStrictMode ?? isCodex, supportsOpenAIGrammarTools: model.compat?.supportsOpenAIGrammarTools ?? false },
  });
  const body = { model: model.id, input };
  if (isCodex) {
    const system = getInitialSystemMessage(transcript.messages);
    if (system) body.instructions = getSystemMessageText(system);
    const tools = resolveTranscriptTools(transcript.messages, model.compat?.supportsAdditionalTools || model.compat?.supportsToolSearch).requestTools;
    if (tools.length) body.tools = convertResponsesTools(tools, { strict: null, supportsStrictMode: model.compat?.supportsStrictMode ?? true, supportsOpenAIGrammarTools: model.compat?.supportsOpenAIGrammarTools ?? false });
  }
  return body;
}

function unsupportedResponse(status, body, allowEndpointAbsence = true) {
  const error = body?.error;
  const code = typeof error?.code === 'string' ? error.code : typeof error?.type === 'string' ? error.type : undefined;
  if ([401, 403, 408, 429].includes(status) || (code && /auth|permission|rate_limit|quota/.test(code))) return false;
  if (UNSUPPORTED_CODES.has(code)) return (allowEndpointAbsence || !['unsupported_endpoint', 'not_implemented'].includes(code)) && [400, 404, 405, 422, 501].includes(status);
  if ([400, 422].includes(status) && typeof error?.message === 'string' && /\b(?:compaction|compact(?:ion)? endpoint)\b.*\b(?:not supported|unsupported)\b|\b(?:does not|doesn't) support\b.*\bcompaction\b|\bmodel\b.*\b(?:not supported|unsupported)\b.*\b(?:compaction|compact)\b/i.test(error.message)) return true;
  // Endpoint absence/method absence, not a failed or inaccessible model lookup.
  return allowEndpointAbsence && [404, 405, 501].includes(status) && (!code || ['not_found', 'method_not_allowed', 'endpoint_not_found'].includes(code));
}

function retainedCodexUsers(input, model) {
  // Match the native V2 replacement's user-context + compaction-item structure.
  // Retain whole recent frames within a conservative budget; complete original
  // messages, images and file references remain in the covered native lineage.
  // https://github.com/openai/codex/blob/7c2ce90716335c889a5076ded9a630459f9c9899/codex-rs/core/src/compact_remote_v2.rs#L493
  let remaining = Math.min(64000, Math.max(1024, Math.floor((model.contextWindow ?? 256000) / 4))), retained = [];
  for (const item of input.toReversed()) {
    if (item.role !== 'user' || (item.type !== undefined && item.type !== 'message')) continue;
    const size = Math.max(1, Math.ceil(JSON.stringify(item).length / 3));
    if (size > remaining) break;
    retained.push(item); remaining -= size;
  }
  return retained.reverse();
}

async function collectCodexCompaction(response, selected, model, input, signal) {
  // Current official Codex appends compaction_trigger to a Responses turn,
  // collects exactly one compaction item, then requires response.completed.
  // https://github.com/openai/codex/blob/7c2ce90716335c889a5076ded9a630459f9c9899/codex-rs/core/src/compact_remote_v2_attempt.rs#L91
  // https://github.com/openai/codex/blob/7c2ce90716335c889a5076ded9a630459f9c9899/codex-rs/core/src/compact_remote_v2.rs#L427
  if (!response.body) throw new ProviderCompactionError('invalid-response', 'Native Codex compaction did not expose a response stream.');
  const reader = response.body.getReader(), decoder = new TextDecoder('utf-8', { fatal: true }), chunks = [], nativeEvents = [];
  let buffered = '', frame = '', lines = [], completed, responseJSON, compactJSON, compactCount = 0, emittedOutput = false, observedUsage;
  const rawState = async () => {
    const source = Buffer.concat(chunks), safe = await sanitizeNativeTransportBytes(source);
    return { route: clone(selected), rawSSE: source.toString('utf8'), rawSSEBase64: safe.bytes.toString('base64'), rawSSEBytes: { sourceSHA256: safe.sourceSHA256, sourceBytes: safe.sourceBytes, sha256: safe.sha256, totalBytes: safe.totalBytes, byteFidelity: safe.byteFidelity }, nativeEvents: clone(nativeEvents), ...(responseJSON ? { responseJSON } : {}), ...(observedUsage !== undefined ? { usage: clone(observedUsage) } : {}) };
  };
  const dispatch = () => {
    const record = { raw: frame }, data = []; let event;
    for (const line of lines) {
      if (line.startsWith(':')) continue;
      const colon = line.indexOf(':'), name = colon < 0 ? line : line.slice(0, colon), value = colon < 0 ? '' : line.slice(colon + 1).replace(/^ /, '');
      if (name === 'data') data.push(value);
      else if (name === 'event') event = value;
      else if (name === 'id') record.id = value;
      else if (name === 'retry') record.retry = value;
    }
    if (event) record.event = event;
    frame = ''; lines = [];
    if (!data.length) { nativeEvents.push(record); return; }
    record.data = data.join('\n'); nativeEvents.push(record);
    if (record.data === '[DONE]') return;
    let value;
    try { value = JSON.parse(record.data); } catch {
      if (event?.startsWith('response.') || event === 'error') throw new ProviderCompactionError('invalid-response', 'Native Codex compaction returned an invalid event.');
      return;
    }
    if (!value || typeof value !== 'object' || Array.isArray(value) || (value.type !== undefined && typeof value.type !== 'string')) throw new ProviderCompactionError('invalid-response', 'Native Codex compaction returned an invalid event.');
    record.type = value.type ?? event;
    if (value.response?.usage !== undefined) observedUsage = value.response.usage;
    if (['error', 'response.failed', 'response.incomplete', 'response.cancelled'].includes(record.type)) {
      const failure = value.response ?? value, unsupported = !emittedOutput && unsupportedResponse(400, failure.error ? failure : { error: failure }, false);
      throw new ProviderCompactionError(unsupported ? 'unsupported' : 'provider', 'Native Codex context compaction did not complete successfully.');
    }
    if (record.type?.startsWith('response.output') || record.type?.startsWith('response.function_call')) emittedOutput = true;
    if (record.type === 'response.output_item.done') {
      if (!value.item || typeof value.item !== 'object' || Array.isArray(value.item)) throw new ProviderCompactionError('invalid-response', 'Native Codex compaction returned an invalid output item.');
      if (['compaction', 'compaction_summary'].includes(value.item.type)) {
        compactCount++;
        if (compactCount !== 1 || typeof value.item.encrypted_content !== 'string' || !value.item.encrypted_content) throw new ProviderCompactionError('invalid-response', 'Native Codex compaction must return exactly one opaque compaction item.');
        compactJSON = rawJSONProperty(record.data, 'item');
      }
    } else if (record.type === 'response.completed') {
      if (completed || !value.response || typeof value.response.id !== 'string' || !value.response.id || (value.response.status !== undefined && value.response.status !== 'completed') || (value.response.model !== undefined && value.response.model !== model.id) || value.response.error || value.response.incomplete_details) throw new ProviderCompactionError('invalid-response', 'Native Codex compaction did not return a successful completion.');
      completed = value.response; responseJSON = rawJSONProperty(record.data, 'response');
    }
  };
  const consume = eof => {
    while (true) {
      const index = buffered.search(/[\r\n]/); if (index < 0 || (!eof && buffered[index] === '\r' && index === buffered.length - 1)) break;
      const length = buffered[index] === '\r' && buffered[index + 1] === '\n' ? 2 : 1, line = buffered.slice(0, index);
      frame += buffered.slice(0, index + length); buffered = buffered.slice(index + length);
      if (line === '') dispatch(); else lines.push(line);
    }
  };
  const read = async () => {
    signal?.throwIfAborted();
    if (!signal) return reader.read();
    let abort;
    try {
      return await Promise.race([reader.read(), new Promise((_, reject) => { abort = () => { void reader.cancel(signal.reason).catch(() => {}); reject(signal.reason ?? new DOMException('Aborted', 'AbortError')); }; signal.addEventListener('abort', abort, { once: true }); })]);
    } finally { if (abort) signal.removeEventListener('abort', abort); }
  };
  try {
    while (!completed) {
      const { value, done } = await read();
      if (done) { buffered += decoder.decode(); consume(true); break; }
      chunks.push(Buffer.from(value)); buffered += decoder.decode(value, { stream: true }); consume(false);
    }
    // A successful terminal frame does not make an unfinished UTF-8 scalar in
    // the same received chunk valid. Keep its exact bytes in the failure copy.
    decoder.decode();
    if (!completed || compactCount !== 1 || !compactJSON || !responseJSON) throw new ProviderCompactionError('invalid-response', 'Native Codex compaction stream ended before its complete opaque result.');
    const exposed = await rawState(), window = [...retainedCodexUsers(input, model), parseLosslessJSON(compactJSON)], windowJSON = JSON.stringify({ output: window });
    const continuation = { ...selected, output: JSON.parse(windowJSON).output, windowJSON };
    if (completed.usage !== undefined) continuation.usage = clone(completed.usage);
    return { ...exposed, continuation, response: completed };
  } catch (cause) {
    const error = cause instanceof ProviderCompactionError || (signal?.aborted && cause instanceof Error) ? cause : new ProviderCompactionError('transport', 'Native Codex compaction stream was interrupted.', { cause });
    error.nativeResponse = await rawState(); throw error;
  } finally { void reader.cancel().catch(() => {}); reader.releaseLock(); }
}

/**
 * Explicit native compaction. The caller executes this inside the selected
 * account's route and commits the result before replacing canonical context.
 * There are no retries, model changes, or credential fallbacks here.
 */
export async function compactProviderContext({ model, context, route, runtime, signal, fetchRequest = globalThis.fetch, continuation, instructions }) {
  if (instructions !== undefined && typeof instructions !== 'string') throw new ProviderCompactionError('invalid-context', 'Native compaction instructions must be text.');
  const resolved = await resolveRoute({ model, route, runtime, signal });
  if (!resolved) return { unsupported: true };
  if (continuation) validateContinuation(continuation, resolved.identity);
  const codex = resolved.identity.nativeTransport === 'codex-compaction-trigger';
  const body = compactInput(model, context, codex || model.api === 'openai-codex-responses');
  if (continuation) body.input = [...continuationWindow(continuation), ...body.input];
  if (instructions?.trim()) {
    if (codex) body.instructions = [body.instructions, `Compaction instructions:\n${instructions}`].filter(Boolean).join('\n\n');
    else if (model.provider === 'openai') body.instructions = instructions;
    else body.input = [...body.input, { role: 'user', content: [{ type: 'input_text', text: `Compaction instructions:\n${instructions}` }] }];
  }
  const originalInput = body.input;
  if (codex) {
    Object.assign(body, { instructions: body.instructions || 'You are a helpful assistant.', stream: true, store: false, include: ['reasoning.encrypted_content'], parallel_tool_calls: true, input: [...originalInput, { type: 'compaction_trigger' }] });
    resolved.headers.set('Accept', 'text/event-stream');
    resolved.headers.set('OpenAI-Beta', 'responses=experimental');
  }
  let response;
  try {
    response = await fetchRequest(resolved.identity.compactEndpoint, { method: 'POST', headers: resolved.headers, body: JSON.stringify(body), signal, redirect: 'error' });
  } catch (cause) {
    if (cause instanceof ProviderCompactionError || signal?.aborted) throw cause;
    throw new ProviderCompactionError('transport', 'Native context compaction could not reach the selected provider.', { cause });
  }
  if (codex && response.ok) {
    try { return await collectCodexCompaction(response, resolved.identity, model, originalInput, signal); }
    catch (error) { if (error.code === 'unsupported') return { unsupported: true, nativeResponse: error.nativeResponse }; throw error; }
  }
  let responseJSON;
  try { responseJSON = await response.text(); } catch (cause) {
    if (signal?.aborted) throw cause;
    throw new ProviderCompactionError('transport', 'Native context compaction did not finish receiving its response.', { cause });
  }
  const failure = (code, message) => {
    const error = new ProviderCompactionError(code, message, { status: response.status });
    error.nativeResponse = exposed();
    return error;
  };
  let native;
  const exposed = () => ({ route: clone(resolved.identity), responseJSON, status: response.status, ...(native?.usage !== undefined ? { usage: clone(native.usage) } : {}) });
  try { native = JSON.parse(responseJSON); } catch {
    if (!response.ok && unsupportedResponse(response.status, undefined, !codex)) return { unsupported: true, nativeResponse: exposed() };
    throw failure(response.ok ? 'invalid-response' : 'provider', 'Native context compaction returned an invalid response.');
  }
  if (!response.ok) {
    if (unsupportedResponse(response.status, native, !codex)) return { unsupported: true, nativeResponse: exposed() };
    throw failure([401, 403].includes(response.status) ? 'auth' : 'provider', 'Native context compaction failed on the selected provider.');
  }
  if (!native || !Array.isArray(native.output) || !native.output.length || native.output.some(item => !item || typeof item !== 'object' || Array.isArray(item)) || (native.model !== undefined && native.model !== model.id)) {
    throw failure('invalid-response', 'Native context compaction did not return a complete window for the selected model.');
  }
  const saved = { ...resolved.identity, output: clone(native.output), windowJSON: responseJSON };
  if (native.usage !== undefined) saved.usage = clone(native.usage);
  return { continuation: saved, response: native, responseJSON, ...(native.usage !== undefined ? { usage: clone(native.usage) } : {}) };
}

/**
 * Revalidate the live authentication endpoint before any opaque state is sent.
 * Pass only kept/new canonical messages to the SDK; its serialized payload is
 * extended here, after conversion, without teaching Pi's parser opaque types.
 */
export async function providerContinuationOptions({ model, route, runtime, signal, continuation }) {
  const resolved = await resolveRoute({ model, route, runtime, signal });
  if (!resolved) throw new ProviderCompactionError('route-mismatch', 'This transport cannot resume native compacted context.');
  validateContinuation(continuation, resolved.identity);
  // Validate the authoritative raw checkpoint before constructing the callback.
  const checkpoint = { windowJSON: continuation.windowJSON };
  continuationWindow(checkpoint);
  return {
    transformHeaders(headers) {
      const account = nativeAccountHeader(headers);
      if (account && resolved.identity.nativeAccountID && account !== resolved.identity.nativeAccountID) {
        throw new ProviderCompactionError('route-mismatch', 'Native compacted context cannot be sent to a different authenticated account.');
      }
      return headers;
    },
    onPayload(payload, requestedModel) {
      if (!payload || payload.model !== model.id || !Array.isArray(payload.input) || (requestedModel && (requestedModel.id !== model.id || requestedModel.provider !== model.provider || requestedModel.api !== model.api || responseEndpoint(requestedModel, {}) !== resolved.identity.endpoint))) {
        throw new ProviderCompactionError('route-mismatch', 'Native compacted context cannot be injected into a different request.');
      }
      if (requestedModel?.headers && resolved.identity.nativeAccountID) {
        const account = nativeAccountHeader(requestedModel.headers);
        if (account && account !== resolved.identity.nativeAccountID) throw new ProviderCompactionError('route-mismatch', 'Native compacted context cannot be injected into a different authenticated account.');
      }
      return { ...payload, input: [...continuationWindow(checkpoint), ...payload.input] };
    },
  };
}
