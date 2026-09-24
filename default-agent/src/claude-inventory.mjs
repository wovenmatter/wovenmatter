// Inventory only. Executable tool implementations remain in the Pi host.
import { readFile } from 'node:fs/promises';
import { createInterface } from 'node:readline';

const tools = JSON.parse(await readFile(process.argv[2], 'utf8'));
for await (const line of createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (message.id === undefined) continue;
  let result = {};
  if (message.method === 'initialize') result = { protocolVersion: '2024-11-05', capabilities: { tools: {} }, serverInfo: { name: 'woven-inventory', version: '1' } };
  else if (message.method === 'tools/list') result = { tools };
  else if (message.method === 'tools/call') result = { isError: true, content: [{ type: 'text', text: 'Only Woven Matter executes this tool.' }] };
  process.stdout.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, result }) + '\n');
}
