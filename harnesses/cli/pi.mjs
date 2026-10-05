import { randomUUID } from 'node:crypto';
import { Socket } from 'node:net';
import { createInterface } from 'node:readline';
import { binding, shellInput } from './binding.mjs';

export default function (pi) {
  const directory = process.env.WOVENMATTER_BINDING_DIRECTORY;
  if (!directory) return;
  const channel = new Socket({ fd: 3, readable: true, writable: true });
  const replies = createInterface({ input: channel });
  const waiting = new Map();
  replies.on('line', line => {
    const { generation } = JSON.parse(line);
    waiting.get(generation)?.();
    waiting.delete(generation);
  });
  const notify = payload => process.stdout.write(JSON.stringify({ type: 'wovenmatter_cli', ...payload }) + '\n');
  let generation;
  pi.on('input', event => { notify({ event: 'input', source: event.source }); });
  pi.on('before_agent_start', () => { notify({ event: 'start' }); });
  pi.on('message_start', async event => {
    if (event.message.role !== 'user') return;
    generation = randomUUID();
    const content = event.message.content;
    const text = typeof content === 'string' ? content : content.filter(p => p.type === 'text').map(p => p.text).join('');
    await new Promise(resolve => {
      waiting.set(generation, resolve);
      notify({ event: 'consume', generation, text });
    });
  });
  pi.on('tool_call', event => {
    if (event.toolName !== 'bash') return;
    Object.assign(event.input, shellInput(event.input, binding(directory, generation ?? '')));
  });
  pi.on('session_shutdown', () => { replies.close(); channel.destroy(); });
}
