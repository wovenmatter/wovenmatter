// A stdio MCP server that stands in for Woven's: the 28 tools of Woven's catalog with their real names, descriptions
// and input schemas (`woven-catalog.json`, taken from the server's catalog), and canned behavior. It touches nothing.
//
// - `list_sessions` returns text.
// - `preview_html` returns text and a PNG, as a screenshot does.
// - `read_session` fails (`isError`) for the session `gone`.
// - `search_library` with the query `slow` takes `WOVEN_FIXTURE_SLOW_MS` (default 1500) to answer.
// - `render_html` answers as Woven's does.
// - Every other tool answers `<name> done`.
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

async function call(name, args) {
  if (process.env.WOVEN_FIXTURE_LOG) appendFileSync(process.env.WOVEN_FIXTURE_LOG, JSON.stringify({ name, arguments: args }) + '\n');
  if (name === 'list_sessions') return text('session-1 | Notes | pi-durable | idle');
  if (name === 'preview_html') return { content: [{ type: 'text', text: 'Content height 120.' }, { type: 'image', data: png, mimeType: 'image/png' }] };
  if (name === 'read_session' && args.sessionID === 'gone') return { ...text('There is no session gone.'), isError: true };
  if (name === 'search_library' && args.query === 'slow') {
    await new Promise(resolve => setTimeout(resolve, Number(process.env.WOVEN_FIXTURE_SLOW_MS ?? 1500)));
    return text('Found after a while.');
  }
  if (name === 'render_html') return text(`Shown in the chat (${String(args.html ?? '').length} characters).`);
  return text(`${name} done`);
}

createInterface({ input: process.stdin }).on('line', async line => {
  const message = JSON.parse(line);
  if (message.id === undefined) return;
  if (message.method === 'initialize') {
    send({ id: message.id, result: { protocolVersion: message.params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: 'woven', version: 'current' }, instructions } });
  } else if (message.method === 'tools/list') {
    send({ id: message.id, result: { tools: catalog.map(tool => ({ name: tool.name, description: tool.description, inputSchema: tool.inputSchema,
      ...(tool.readOnly ? { annotations: { readOnlyHint: true } } : {}) })) } });
  } else if (message.method === 'tools/call') {
    send({ id: message.id, result: await call(message.params.name, message.params.arguments ?? {}) });
  } else if (message.method === 'ping') {
    send({ id: message.id, result: {} });
  } else {
    send({ id: message.id, error: { code: -32601, message: `Unknown method ${message.method}.` } });
  }
});
