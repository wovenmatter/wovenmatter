import { createServer } from 'node:http';
import { randomBytes, timingSafeEqual } from 'node:crypto';
import { validateConnection } from './binding.mjs';

const maximumBody = 4 * 1024 * 1024;
const equal = (left, right) => {
  const a = Buffer.from(left ?? ''), b = Buffer.from(right ?? '');
  return a.length === b.length && timingSafeEqual(a, b);
};
// A private HTTP bridge adds native-consumed input metadata. App operations still
// execute at the one authenticated Woven endpoint; this has no app dispatcher.
export async function createMCPProxy({ getConnection, contextFor = () => undefined, fetchImpl = fetch }) {
  const bearerToken = randomBytes(32).toString('base64url');
  const server = createServer(async (request, response) => {
    const controller = new AbortController();
    response.on('close', () => { if (!response.writableFinished) controller.abort(); });
    const fail = (status, message) => { if (!response.headersSent) { response.writeHead(status, { 'content-type': 'application/json', 'cache-control': 'no-store' }); response.end(JSON.stringify({ error: message })); } else response.destroy(); };
    try {
      if (request.url !== '/mcp') return fail(404, 'Not found.');
      if (request.headers.origin && !/^https?:\/\/(localhost|127\.0\.0\.1)(:\d+)?$/.test(request.headers.origin)) return fail(403, 'Origin is not allowed.');
      if (!equal(request.headers.authorization, 'Bearer ' + bearerToken)) return fail(401, 'A Woven MCP credential is required.');
      if (!['POST', 'GET', 'DELETE'].includes(request.method)) return fail(405, 'Unsupported MCP method.');
      let body;
      if (request.method === 'POST') {
        let count = 0; const chunks = [];
        for await (const chunk of request) { count += chunk.length; if (count > maximumBody) return fail(413, 'MCP request is too large.'); chunks.push(chunk); }
        const message = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        if (message.method === 'tools/call' && message.params && typeof message.params === 'object' && !Array.isArray(message.params)) {
          const params = message.params;
          // Only the hook/plugin's exact UUID association may supply capture.
          // Ignore any model-authored or stale context metadata.
          const capture = params.name === 'woven_context' ? await contextFor(params.arguments?.requestID) : undefined;
          params._meta = { ...params._meta };
          delete params._meta.wovenContextID;
          if (capture) params._meta.wovenContextID = capture;
          message.params = params;
        }
        body = JSON.stringify(message);
      }
      const source = validateConnection(await getConnection());
      const headers = { Authorization: 'Bearer ' + source.bearerToken, Accept: 'application/json, text/event-stream' };
      if (body !== undefined) headers['Content-Type'] = 'application/json';
      for (const key of ['mcp-protocol-version', 'mcp-session-id', 'last-event-id']) if (typeof request.headers[key] === 'string') headers[key] = request.headers[key];
      const result = await fetchImpl(source.endpointURL, { method: request.method, headers, body, signal: controller.signal, redirect: 'error' });
      const outgoing = { 'cache-control': 'no-store' };
      for (const key of ['content-type', 'mcp-session-id', 'mcp-protocol-version', 'allow']) if (result.headers.get(key)) outgoing[key] = result.headers.get(key);
      response.writeHead(result.status, outgoing);
      if (result.body) for await (const bytes of result.body) {
        if (!response.write(bytes)) await new Promise((resolve, reject) => {
          const done = () => { response.off('close', closed); resolve(); };
          const closed = () => { response.off('drain', done); reject(new Error('MCP client disconnected.')); };
          response.once('drain', done); response.once('close', closed);
        });
      }
      response.end();
    } catch (error) { fail(error instanceof SyntaxError ? 400 : 502, 'The Woven MCP connection is unavailable.'); }
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  return { connection: { endpointURL: `http://127.0.0.1:${server.address().port}/mcp`, bearerToken }, close: () => { server.closeAllConnections(); server.close(); } };
}
