import { CODEMODE_TOOL_NAME } from '@earendil-works/pi-durable/codemode';
import { checklistName, subagentName } from './tools.mjs';

const kinds = { read: 'read', write: 'edit', edit: 'edit', bash: 'execute', web_search: 'search', web_read: 'fetch', [checklistName]: 'think', [CODEMODE_TOOL_NAME]: 'execute' };
const outputLimit = 16384;
// Code mode's own internal tools, which scripts reach through globals such as `models.classify()`.
const internal = 'pi.codemode.';

// A script's tool call's arguments as they cross ACP: every `html` string only its length (a page a script passes
// never travels, and Woven keeps only that length of a visual reply), other long strings cut, and the whole kept to
// a few KB. The script's own source travels whole; Woven leaves its long literals out (`CodeCalls`).
const stringLimit = 1024, inputLimit = 4096;
// Woven's `render_html`, as Pi Durable names an MCP server's tool.
const publishes = name => name === 'mcp__woven__render_html';
function nestedInput(name, args) {
  const shrink = (value, key) => {
    if (typeof value === 'string') {
      if (key === 'html') return publishes(name) ? `(${value.length} characters, shown in the chat)` : `(${value.length} characters)`;
      return value.length > stringLimit ? `${value.slice(0, stringLimit)}…` : value;
    }
    if (Array.isArray(value)) return value.map(item => shrink(item));
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([field, item]) => [field, shrink(item, field)]));
    return value;
  };
  const input = shrink(args ?? {});
  const text = JSON.stringify(input);
  return text.length > inputLimit ? `${text.slice(0, inputLimit)}…` : input;
}

function toolCall(id, name, args = {}) {
  const base = { toolCallId: id, kind: kinds[name] ?? 'other', rawInput: args };
  if (name === CODEMODE_TOOL_NAME) {
    const { rawInput: _, ...rest } = base;
    return { ...rest, ...(typeof args.code === 'string' ? { rawInput: { code: args.code } } : {}), title: name, _meta: { wovenKind: 'code', wovenCalls: [] } };
  }
  if (name === subagentName) return { ...base, title: args.description || args.prompt?.slice(0, 80) || 'Subagent', _meta: { wovenKind: 'task' } };
  if (name === 'bash') return { ...base, title: args.command ? String(args.command).slice(0, 200) : 'bash' };
  if (['read', 'write', 'edit'].includes(name) && args.path) return { ...base, title: `${name[0].toUpperCase()}${name.slice(1)} ${args.path}`, locations: [{ path: args.path }] };
  return { ...base, title: name };
}
const content = blocks => (blocks ?? []).filter(block => block.type === 'text' || block.type === 'image').map(block => ({ type: 'content', content: block }));

// Turns the root conversation's watch into ACP `session/update`s: streamed text and
// thinking from the live generation, tool calls from the live tool round and the
// committed entries, and the checklist as a plan. A code mode script is one call of
// kind `code` that lists, in `_meta.wovenCalls`, the tool calls it made: live from
// `pi.live.nestedTools`, and at its end from its result's details. Only what is new
// since the watch attached is sent; the server already holds what came before.
export class Projection {
  constructor(send) {
    this.send = send;
    this.lastEntry = undefined;
    this.streamed = [];
    this.tools = new Map();
    // The model's tool calls still waiting for their results, with their arguments, so one announced from the live
    // round (after a restart, say) is described as it was made.
    this.issued = new Map();
    // Code mode calls: their nested calls by nested call ID, and the list last sent.
    this.scripts = new Map();
    this.pending = Promise.resolve();
  }
  attach(watch) {
    this.lastEntry = watch.value.entries.at(-1)?.id ?? -1;
    for (const entry of watch.value.entries) for (const message of entry.model ?? []) this.track(message);
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
    await this.nested(live?.nestedTools ?? []);
  }
  script(id) {
    if (!this.scripts.has(id)) this.scripts.set(id, { calls: new Map(), sent: '[]', planned: new Set() });
    return this.scripts.get(id);
  }
  // The running scripts' calls, each update sent only when a script's list changed.
  async nested(slots) {
    const changed = new Set();
    for (const slot of slots) {
      const script = this.scripts.get(slot.parentCallId);
      if (!script || slot.name.startsWith(internal)) continue;
      const done = slot.status === 'done';
      const call = { name: slot.name, input: nestedInput(slot.name, slot.arguments), status: done ? (slot.summary?.isError ? 'error' : 'ok') : 'running',
        ...(done && slot.summary?.error ? { error: slot.summary.error } : {}) };
      script.calls.set(slot.callId, call);
      changed.add(slot.parentCallId);
      // A checklist a script updates is the plan as well.
      if (done && call.status === 'ok' && slot.name === checklistName && !script.planned.has(slot.callId) && Array.isArray(slot.arguments?.todos)) {
        script.planned.add(slot.callId);
        await this.plan(slot.arguments.todos);
      }
    }
    for (const id of changed) {
      if (!this.tools.has(id)) continue;
      await this.sendCalls(id, [...this.scripts.get(id).calls.values()], 'in_progress');
    }
  }
  async sendCalls(id, calls, status, rest = {}) {
    const script = this.script(id), text = JSON.stringify(calls);
    if (text === script.sent && status === 'in_progress') return;
    script.sent = text;
    await this.send({ sessionUpdate: 'tool_call_update', toolCallId: id, status, ...rest, _meta: { wovenKind: 'code', wovenCalls: calls } });
  }
  // A finished script's calls, from its result's details, with the arguments seen while it ran.
  finalCalls(id, details) {
    const seen = this.scripts.get(id)?.calls ?? new Map();
    const rows = Array.isArray(details?.calls) ? details.calls : [...seen.values()];
    return rows.filter(row => !row.name?.startsWith(internal)).map(row => {
      if (!('id' in row)) return row;
      const live = seen.get(`${id}/c${row.id}`);
      const input = live?.input ?? (publishes(row.name) ? { html: '(the visual reply, shown in the chat)' } : row.args);
      return { name: row.name, input, status: row.status, ...(row.error ? { error: row.error } : {}) };
    });
  }
  async plan(todos) {
    await this.send({ sessionUpdate: 'plan', entries: todos.map(item => ({ content: item.content, status: item.status, priority: 'medium' })) });
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
  track(message) {
    if (message.role === 'assistant') {
      for (const block of message.content ?? []) if (block.type === 'toolCall') this.issued.set(block.id, block.arguments ?? {});
    } else if (message.role === 'toolResult') this.issued.delete(message.toolCallId);
  }
  async message(message) {
    if (message.role === 'assistant') {
      await this.stream(message.content);
      this.streamed = [];
      for (const block of message.content ?? []) if (block.type === 'toolCall') await this.announce(block.id, block.name, block.arguments, 'pending');
    } else if (message.role === 'toolResult') {
      const tool = this.tools.get(message.toolCallId);
      if (!tool) await this.announce(message.toolCallId, message.toolName, this.issued.get(message.toolCallId) ?? {}, 'pending');
      this.tools.delete(message.toolCallId);
      const status = message.isError ? 'failed' : 'completed';
      if (message.toolName === CODEMODE_TOOL_NAME) {
        await this.sendCalls(message.toolCallId, this.finalCalls(message.toolCallId, message.details), status, { content: content(message.content) });
        this.scripts.delete(message.toolCallId);
      } else {
        await this.send({ sessionUpdate: 'tool_call_update', toolCallId: message.toolCallId, status, content: content(message.content), rawOutput: message.details ?? null });
      }
      if (message.toolName === checklistName && !message.isError && Array.isArray(message.details?.checklist)) await this.plan(message.details.checklist);
    }
    this.track(message);
  }
  async announce(id, name, args, status) {
    if (this.tools.has(id)) return;
    this.tools.set(id, { output: '' });
    if (name === CODEMODE_TOOL_NAME) this.script(id);
    await this.send({ sessionUpdate: 'tool_call', ...toolCall(id, name, args), status });
  }
  async slot(slot) {
    if (slot.status === 'done' || slot.status === 'pending') return;
    if (!this.tools.has(slot.callId)) await this.announce(slot.callId, slot.name, this.issued.get(slot.callId) ?? {}, 'in_progress');
    const tool = this.tools.get(slot.callId);
    const output = (slot.output ?? '').slice(-outputLimit);
    if (tool.running && output === tool.output) return;
    tool.running = true; tool.output = output;
    await this.send({ sessionUpdate: 'tool_call_update', toolCallId: slot.callId, status: 'in_progress', ...(output ? { content: [{ type: 'content', content: { type: 'text', text: output } }] } : {}) });
  }
}
