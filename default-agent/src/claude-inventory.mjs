// A stdio MCP server that only lists Pi's tools to Claude. Pi runs them itself.
import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';

const tools = JSON.parse(await readFile(process.argv[2], 'utf8'));
for await (const line of createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (message.id === undefined) continue;
  let result = {};
  if (message.method === 'initialize') result = { protocolVersion: message.params?.protocolVersion ?? '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'woven-inventory', version: 'current' } };
  else if (message.method === 'tools/list') result = { tools };
  else if (message.method === 'tools/call') result = { isError: true, content: [{ type: 'text', text: 'Pi Durable runs this tool itself.' }] };
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, result }) + '\n');
}
