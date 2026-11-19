import { checklistName, subagentName } from './tools.mjs';

const kinds = { read: 'read', write: 'edit', edit: 'edit', bash: 'execute', web_search: 'search', web_read: 'fetch', [checklistName]: 'think' };
const outputLimit = 16384;

function toolCall(id, name, args = {}) {
  const base = { toolCallId: id, kind: kinds[name] ?? 'other', rawInput: args };
  if (name === subagentName) return { ...base, title: args.description || args.prompt?.slice(0, 80) || 'Subagent', _meta: { wovenKind: 'task' } };
  if (name === 'bash') return { ...base, title: args.command ? String(args.command).slice(0, 200) : 'bash' };
  if (['read', 'write', 'edit'].includes(name) && args.path) return { ...base, title: `${name[0].toUpperCase()}${name.slice(1)} ${args.path}`, locations: [{ path: args.path }] };
  return { ...base, title: name };
}
const content = blocks => (blocks ?? []).filter(block => block.type === 'text' || block.type === 'image').map(block => ({ type: 'content', content: block }));

// Turns the root conversation's watch into ACP `session/update`s: streamed text and
// thinking from the live generation, tool calls from the live tool round and the
// committed entries, and the checklist as a plan. Only what is new since the watch
// attached is sent; the server already holds what came before.
export class Projection {
  constructor(send) {
    this.send = send;
    this.lastEntry = undefined;
    this.streamed = [];
    this.tools = new Map();
    this.pending = Promise.resolve();
  }
  attach(watch) {
    this.lastEntry = watch.value.entries.at(-1)?.id ?? -1;
    watch.start(call => {
      if (call.kind !== 'value') return;
      this.pending = this.pending.then(() => this.apply(call.value)).catch(() => {});
      return this.pending;
    });
  }
  // Waits until the entry `id` has been projected.
  async through(id, timeoutMs = 5000) {
    const until = Date.now() + timeoutMs;
    while ((this.lastEntry ?? -1) < id && Date.now() < until) { await this.pending; await new Promise(resolve => setTimeout(resolve, 5)); }
    await this.pending;
  }
  async apply(value) {
    for (const entry of value.entries) {
      if (entry.id <= this.lastEntry) continue;
      this.lastEntry = entry.id;
      for (const message of entry.model ?? []) await this.message(message);
    }
    const live = value.docs?.['pi.live'];
    const partial = live?.generation?.message;
    if (partial) await this.stream(partial.content);
    for (const slot of live?.tools ?? []) await this.slot(slot);
  }
  async stream(blocks = []) {
    for (const [index, block] of blocks.entries()) {
      const field = block.type === 'text' ? 'text' : block.type === 'thinking' ? 'thinking' : undefined;
      if (!field) continue;
      const text = block[field] ?? '', sent = this.streamed[index];
      if (sent && (sent.field !== field || !text.startsWith(sent.text))) continue;
      const delta = text.slice(sent?.text.length ?? 0);
      this.streamed[index] = { field, text };
      if (delta) await this.send({ sessionUpdate: field === 'text' ? 'agent_message_chunk' : 'agent_thought_chunk', content: { type: 'text', text: delta } });
    }
  }
  async message(message) {
    if (message.role === 'assistant') {
      await this.stream(message.content);
      this.streamed = [];
      for (const block of message.content ?? []) if (block.type === 'toolCall') await this.announce(block.id, block.name, block.arguments, 'pending');
    } else if (message.role === 'toolResult') {
      const tool = this.tools.get(message.toolCallId);
      if (!tool) await this.announce(message.toolCallId, message.toolName, {}, 'pending');
      this.tools.delete(message.toolCallId);
      await this.send({ sessionUpdate: 'tool_call_update', toolCallId: message.toolCallId, status: message.isError ? 'failed' : 'completed',
        content: content(message.content), rawOutput: message.details ?? null });
      if (message.toolName === checklistName && !message.isError && Array.isArray(message.details?.checklist)) {
        await this.send({ sessionUpdate: 'plan', entries: message.details.checklist.map(item => ({ content: item.content, status: item.status, priority: 'medium' })) });
      }
    }
  }
  async announce(id, name, args, status) {
    if (this.tools.has(id)) return;
    this.tools.set(id, { output: '' });
    await this.send({ sessionUpdate: 'tool_call', ...toolCall(id, name, args), status });
  }
  async slot(slot) {
    if (slot.status === 'done' || slot.status === 'pending') return;
    if (!this.tools.has(slot.callId)) await this.announce(slot.callId, slot.name, {}, 'in_progress');
    const tool = this.tools.get(slot.callId);
    const output = (slot.output ?? '').slice(-outputLimit);
    if (tool.running && output === tool.output) return;
    tool.running = true; tool.output = output;
    await this.send({ sessionUpdate: 'tool_call_update', toolCallId: slot.callId, status: 'in_progress', ...(output ? { content: [{ type: 'content', content: { type: 'text', text: output } }] } : {}) });
  }
}
