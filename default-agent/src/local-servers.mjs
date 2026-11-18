export function serverURL(value) {
  if (typeof value !== 'string' || value.length > 2048) throw new Error('Enter a valid HTTP or HTTPS server URL.');
  let url;
  try { url = new URL(value.trim()); } catch { throw new Error('Enter a full server URL, such as http://localhost:32100/v1.'); }
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) {
    throw new Error('Use an HTTP or HTTPS URL without embedded credentials, query parameters, or fragments.');
  }
  url.pathname = url.pathname.replace(/\/+$/, '') || '/v1';
  return url.href.replace(/\/$/, '');
}

export function localServers(input) {
  if (input == null) return [];
  if (!Array.isArray(input) || input.length > 12) throw new Error('You can connect up to 12 local model servers.');
  const ids = new Set();
  return input.map(server => {
    if (!server || !/^local-server-[a-f0-9-]{36}$/.test(server.id) || ids.has(server.id)) throw new Error('Invalid local model server identity.');
    ids.add(server.id);
    if (!Array.isArray(server.models) || server.models.length > 1000 || server.models.some(id => typeof id !== 'string' || !id || id.length > 256)) throw new Error('The model catalog is invalid.');
    return { id: server.id, url: serverURL(server.url), models: [...new Set(server.models)] };
  });
}

export async function probeServer(url, key, fetcher = fetch) {
  const base = serverURL(url);
  if (typeof key !== 'string' || !key.trim() || /[\r\n]/.test(key)) throw new Error('Enter the server API key.');
  async function request(path, body) {
    let response;
    try {
      response = await fetcher(base + path, { method: body ? 'POST' : 'GET', redirect: 'error', signal: AbortSignal.timeout(20000),
        headers: { Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' }, ...(body ? { body: JSON.stringify(body) } : {}) });
    } catch { throw new Error('The server could not be reached. Check the URL, server, and Tailscale connection. Redirects are not followed.'); }
    if (!response.ok) {
      if ([401, 403].includes(response.status)) throw new Error('The server rejected this API key. Check the key and its permissions.');
      if (response.status === 404) throw new Error(`The server does not expose ${path}. Use an OpenAI Responses-compatible server URL ending in /v1.`);
      throw new Error(`The server returned HTTP ${response.status} for ${path}. Check that its model is loaded and the Responses API is enabled.`);
    }
    const reader = response.body.getReader(); let chunks = [], length = 0;
    while (true) {
      const { done, value } = await reader.read(); if (done) break;
      length += value.length;
      if (length > 1048576) { await reader.cancel(); throw new Error('The server response was too large.'); }
      chunks.push(value);
    }
    try { return JSON.parse(Buffer.concat(chunks).toString('utf8')); }
    catch { throw new Error('The server did not return an OpenAI-compatible JSON response.'); }
  }
  const catalog = await request('/models');
  const models = Array.isArray(catalog?.data) ? [...new Set(catalog.data.map(m => m?.id).filter(id => typeof id === 'string' && id.length > 0 && id.length <= 256))] : [];
  if (!models.length || models.length > 1000) throw new Error('The server did not return a usable model catalog. Load a model and reconnect.');
  // An explicit Connect checks the actual protocol with a tiny, non-stored turn.
  // Merely accepting GET /models does not establish Responses API support.
  const response = await request('/responses', { model: models[0], input: 'Reply OK.', max_output_tokens: 1, store: false, stream: false });
  if (response?.object !== 'response' || !Array.isArray(response.output) || !['completed', 'incomplete'].includes(response.status)) {
    throw new Error('The server listed models but did not complete a compatible Responses API check.');
  }
  return { url: base, models };
}

export function registerLocalServers(runtime, servers) {
  for (const server of servers) {
    runtime.registerProvider(server.id, {
      name: new URL(server.url).host, baseUrl: server.url, api: 'openai-responses', authHeader: true,
      models: server.models.map(id => ({ id, name: id, reasoning: false, input: ['text'],
        cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 16384, maxTokens: 4096 })),
    });
  }
}
