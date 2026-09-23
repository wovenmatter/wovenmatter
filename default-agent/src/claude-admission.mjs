import { createServer } from 'node:http';
import { randomBytes } from 'node:crypto';
import { once } from 'node:events';
import { DefaultAgentError, accessFailure } from './config.mjs';

// The single-generation boundary follows the MIT-licensed Hermes DirectSDK
// design. Native maxTurns also permits recovery generations; this gate keeps
// the first response authoritative while the host retains its agent loop.
// https://github.com/NousResearch/hermes-plugin-claude-subscription-directsdk/blob/f1c1220/admission.py
// Attribution and license: claude-hermes-LICENSE.txt.
const maximumBody = 32 * 1024 * 1024;
const maximumEvent = 8 * 1024 * 1024;

export async function createClaudeAdmission({ signal, onEvent, fetcher = fetch, upstream = 'https://api.anthropic.com' }) {
  const target = new URL(upstream);
  if (!(target.protocol === 'https:' || target.protocol === 'http:' && ['127.0.0.1', '[::1]', 'localhost'].includes(target.hostname)) ||
      target.username || target.password || target.search || target.hash) throw new Error('Invalid Claude upstream.');
  const path = `/request/${randomBytes(32).toString('hex')}/v1/messages`;
  const controller = new AbortController();
  const abort = () => { controller.abort(); server.closeAllConnections(); };
  const state = { used: false, denied: 0, status: undefined, complete: false, message: undefined, error: undefined };
  const sockets = new Set();
  const server = createServer(async (request, response) => {
    if (request.method !== 'POST' || request.url?.split('?')[0] !== path || request.headers.origin) {
      response.writeHead(404).end(); return;
    }
    if (state.used || controller.signal.aborted) {
      state.denied++;
      response.writeHead(400, { 'content-type': 'application/json' }).end(JSON.stringify({ type: 'error', error: { type: 'invalid_request_error', message: 'Host model request already completed.' } }));
      return;
    }
    state.used = true;
    try {
      const chunks = []; let length = 0;
      for await (const chunk of request) {
        length += chunk.length;
        if (length > maximumBody) throw new DefaultAgentError('The Claude request is too large. Start a new conversation.');
        chunks.push(chunk);
      }
      // Authentication and identity remain native. Headers exist only for this
      // in-memory forwarding operation; never persist or include them in errors.
      const excluded = new Set(['host', 'connection', 'content-length', 'transfer-encoding', 'proxy-authorization', 'proxy-connection', 'accept-encoding']);
      const headers = Object.fromEntries(Object.entries(request.headers).filter(([key]) => !excluded.has(key)));
      headers['accept-encoding'] = 'identity';
      const result = await fetcher(`${upstream.replace(/\/$/, '')}/v1/messages${request.url.includes('?') ? '?' + request.url.split('?').slice(1).join('?') : ''}`, {
        method: 'POST', headers, body: Buffer.concat(chunks), signal: controller.signal, redirect: 'error',
      });
      state.status = result.status;
      const responseHeaders = Object.fromEntries([...result.headers].filter(([key]) => !['connection', 'transfer-encoding', 'content-length', 'content-encoding'].includes(key)));
      response.writeHead(result.status, { ...responseHeaders, connection: 'close' });
      const decoder = new TextDecoder(); let pending = ''; let errorBody = ''; let responseLength = 0;
      const argumentsByIndex = new Map();
      for await (const chunk of result.body ?? []) {
        responseLength += chunk.length;
        if (responseLength > maximumBody) throw new DefaultAgentError('The Claude response exceeded the supported size.');
        if (result.ok) {
          pending += decoder.decode(chunk, { stream: true });
          if (pending.length > maximumEvent) throw new DefaultAgentError('The Claude response exceeded the supported size.');
          let boundary;
          while ((boundary = /\r?\n\r?\n/.exec(pending))) {
            const frame = pending.slice(0, boundary.index); pending = pending.slice(boundary.index + boundary[0].length);
            const data = frame.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).trimStart()).join('\n');
            if (!data) continue;
            const event = JSON.parse(data);
            if (event.type === 'error') throw new DefaultAgentError(accessFailure(event.error?.message ?? '') ?? 'Claude could not complete its response.');
            if (state.complete) throw new Error('Unexpected Claude event after completion.');
            if (event.type === 'message_start') state.message = structuredClone(event.message);
            else if (event.type === 'content_block_start') {
              if (!state.message || !Number.isInteger(event.index) || event.index !== state.message.content.length) throw new Error('Invalid Claude content order.');
              state.message.content.push(structuredClone(event.content_block));
            } else if (event.type === 'content_block_delta') {
              const block = state.message?.content[event.index], delta = event.delta;
              if (!block) throw new Error('Missing Claude content block.');
              const field = { text_delta: 'text', thinking_delta: 'thinking', signature_delta: 'signature' }[delta.type];
              if (field) block[field] = (block[field] ?? '') + delta[field];
              else if (delta.type === 'input_json_delta') argumentsByIndex.set(event.index, (argumentsByIndex.get(event.index) ?? '') + delta.partial_json);
            } else if (event.type === 'content_block_stop' && argumentsByIndex.has(event.index)) {
              const input = argumentsByIndex.get(event.index);
              state.message.content[event.index].input = input.trim() ? JSON.parse(input) : {};
              argumentsByIndex.delete(event.index);
            } else if (event.type === 'message_delta') {
              if (!state.message) throw new Error('Missing Claude response.');
              Object.assign(state.message, event.delta);
              Object.assign(state.message.usage, event.usage);
            } else if (event.type === 'message_stop') {
              if (!state.message?.stop_reason || argumentsByIndex.size) throw new Error('Incomplete Claude response.');
              state.complete = true;
            }
            onEvent?.(event);
          }
        } else if (errorBody.length < 65536) errorBody += decoder.decode(chunk).slice(0, 65536 - errorBody.length);
        if (!response.write(chunk)) await Promise.race([once(response, 'drain'), once(response, 'close')]);
      }
      if (result.ok && (pending + decoder.decode()).trim()) throw new DefaultAgentError('The Claude response ended with an incomplete event.');
      if (!result.ok) state.error = new DefaultAgentError(accessFailure(`${result.status} ${errorBody}`) ?? `Claude returned HTTP ${result.status}. Check Settings → Connections or retry.`);
      response.end();
    } catch (error) {
      state.error = error instanceof DefaultAgentError ? error : new DefaultAgentError('The Claude response was interrupted. Retry or check Settings → Connections.');
      response.destroy();
    }
  });
  server.on('connection', socket => { sockets.add(socket); socket.once('close', () => sockets.delete(socket)); });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  signal?.addEventListener('abort', abort, { once: true });
  if (signal?.aborted) abort();
  return {
    get state() { return state; },
    url: `http://127.0.0.1:${server.address().port}${path.slice(0, -'/v1/messages'.length)}`,
    async close() {
      signal?.removeEventListener('abort', abort);
      controller.abort();
      for (const socket of sockets) socket.destroy();
      await new Promise(resolve => server.close(resolve));
    },
  };
}
