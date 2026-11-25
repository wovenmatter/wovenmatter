// A stdio MCP server that stands in for Woven's: the 28 tools of Woven's catalog with their real names, descriptions,
// input and output schemas (`woven-catalog.json`, taken from the server's catalog), and canned behavior. It touches
// nothing. Each success is a value, as Woven's are: `structuredContent`, and the same JSON as its text.
//
// - `list_sessions` returns one session.
// - `preview_html` returns its measurements and a PNG, as a screenshot does.
// - `read_session` fails (`isError`, text alone) for the session `gone`.
// - `search_library` with the query `slow` takes `WOVEN_FIXTURE_SLOW_MS` (default 1500) to answer.
// - `render_html` answers as Woven's does.
// - Every other tool answers `{}`.
//
// Each call is appended to `WOVEN_FIXTURE_LOG` as a JSON line, `{ name, arguments }`, when it is set.
import { appendFileSync, readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const catalog = JSON.parse(readFileSync(new URL('./woven-catalog.json', import.meta.url), 'utf8'));
const png = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
const instructions = 'You are running inside Woven Matter, which the person runs on their Macs and Linux machines.\n\n'
  + '- To show a chart, table, diagram or anything interactive in the chat, call `render_html`.';

const send = message => process.stdout.write(JSON.stringify({ jsonrpc: '2.0', ...message }) + '\n');
const text = value => ({ content: [{ type: 'text', text: value }] });
const value = (structuredContent, images = []) => ({ content: [{ type: 'text', text: JSON.stringify(structuredContent) }, ...images], structuredContent });

async function call(name, args) {
  if (process.env.WOVEN_FIXTURE_LOG) appendFileSync(process.env.WOVEN_FIXTURE_LOG, JSON.stringify({ name, arguments: args }) + '\n');
  if (name === 'list_sessions') return value({ sessions: [{ id: 'session-1', title: 'Notes', runtime: 'piDurable', state: 'idle' }] });
  if (name === 'preview_html') return value({ width: 728, contentHeight: 120, missingImages: [] }, [{ type: 'image', data: png, mimeType: 'image/png' }]);
  if (name === 'read_session' && args.sessionID === 'gone') return { ...text('There is no session gone.'), isError: true };
  if (name === 'search_library' && args.query === 'slow') {
    await new Promise(resolve => setTimeout(resolve, Number(process.env.WOVEN_FIXTURE_SLOW_MS ?? 1500)));
    return value({ items: [{ kind: 'link', title: 'Found after a while.' }] });
  }
  if (name === 'render_html') return value({ shownIn: 'chat', title: String(args.title ?? '') });
  return value({});
}

createInterface({ input: process.stdin }).on('line', async line => {
  const message = JSON.parse(line);
  if (message.id === undefined) return;
  if (message.method === 'initialize') {
    send({ id: message.id, result: { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: 'woven', version: 'current' }, instructions } });
  } else if (message.method === 'tools/list') {
    send({ id: message.id, result: { tools: catalog.map(tool => ({ name: tool.name, description: tool.description, inputSchema: tool.inputSchema,
      outputSchema: tool.outputSchema, ...(tool.readOnly ? { annotations: { readOnlyHint: true } } : {}),
      ...(tool.images ? { _meta: { wovenImages: true } } : {}) })) } });
  } else if (message.method === 'tools/call') {
    send({ id: message.id, result: await call(message.params.name, message.params.arguments ?? {}) });
  } else if (message.method === 'ping') {
    send({ id: message.id, result: {} });
  } else {
    send({ id: message.id, error: { code: -32601, message: `Unknown method ${message.method}.` } });
  }
});
