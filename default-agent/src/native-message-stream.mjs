// Pi Durable snapshots and edits share one accumulator. Presentation changes
// follow native block order, while assistant replacements retain prior turns.
export class NativeMessageStream {
  constructor(send, toolStream) {
    this.send = send; this.toolStream = toolStream; this.sequence = 0; this.reset();
  }
  reset() { this.blocks = new Map(); this.completed = ''; this.open = false; }
  begin() { this.blocks = new Map(); this.open = true; this.sequence++; }
  text(blocks = this.blocks) {
    return [...blocks].sort(([a], [b]) => a - b).map(([, block]) => block?.type === 'text' ? block.text ?? '' : '').join('');
  }
  assistant(before, after) {
    if (before === after) return;
    const replaces = !after.startsWith(before);
    this.send({ sessionUpdate: 'agent_message_chunk', content: { type: 'text', text: replaces ? this.completed + after : after.slice(before.length) },
      ...(replaces ? { _meta: { wovenAssistantSnapshot: true } } : {}) });
  }
  block(block, index, publishText = true) {
    const before = this.text(), previous = this.blocks.get(index);
    if (block === undefined) this.blocks.delete(index); else this.blocks.set(index, structuredClone(block));
    const thought = block?.type === 'thinking' ? block.thinking ?? '' : '';
    const priorThought = previous?.type === 'thinking' ? previous.thinking ?? '' : '';
    if (thought !== priorThought) {
      const replaces = !thought.startsWith(priorThought);
      this.send({ sessionUpdate: 'agent_thought_chunk', content: { type: 'text', text: replaces ? thought : thought.slice(priorThought.length) },
        _meta: { wovenThoughtID: `built-in-${this.sequence}-${index}`, ...(replaces ? { wovenThoughtSnapshot: true } : {}) } });
    }
    if (publishText) this.assistant(before, this.text());
    if (block?.type === 'toolCall') {
      const update = this.toolStream?.input(block);
      if (update) this.send(update);
    }
  }
  message(message) {
    if (message.role !== 'assistant') return;
    if (!this.open) this.begin();
    const content = Array.isArray(message.content) ? message.content : [];
    const before = this.text(), final = this.text(new Map(content.map((block, index) => [index, block])));
    const replacement = !final.startsWith(before) || [...this.blocks].some(([index, block]) =>
      block?.type === 'text' && (content[index]?.type !== 'text' || !(content[index].text ?? '').startsWith(block.text ?? '')));
    // A corrected snapshot may introduce a thought/tool between text blocks.
    // Rebuild its text prefix in source order; publishing the entire final text
    // first would place that new activity after text which follows it natively.
    const indices = [...new Set([...this.blocks.keys(), ...content.keys()])].sort((a, b) => a - b);
    if (replacement) for (const [index, block] of this.blocks) if (block?.type === 'text') this.blocks.delete(index);
    let published = before;
    const flush = () => { const text = this.text(); this.assistant(published, text); published = text; };
    for (const index of indices) {
      const block = content[index];
      if (block?.type !== 'text') flush();
      this.block(block, index, false);
      if (block?.type !== 'text') flush();
    }
    flush();
  }
  change(change) {
    if (change.type === 'message') { this.message(change.message); return; }
    if (!this.open) this.begin();
    if (change.block) { this.block(change.block, change.contentIndex); return; }
    const block = structuredClone(this.blocks.get(change.contentIndex));
    if (change.type === 'text_delta' || change.type === 'thinking_delta') {
      const field = change.type === 'text_delta' ? 'text' : 'thinking';
      this.block({ ...block, type: field, [field]: (block?.[field] ?? '') + change.delta }, change.contentIndex);
    } else if (change.type === 'toolcall_delta' && block?.type === 'toolCall') {
      // Durable paths are relative to arguments. Never traverse inherited keys.
      let value = block, key = 'arguments';
      for (const part of change.path) {
        if (!Object.hasOwn(value, key) || value[key] === null || typeof value[key] !== 'object' || ['__proto__', 'constructor', 'prototype'].includes(String(part))) return;
        value = value[key]; key = part;
      }
      if (!Object.hasOwn(value, key) || typeof value[key] !== 'string') return;
      value[key] += change.delta;
      this.block(block, change.contentIndex);
    }
  }
  end(message) {
    this.message(message);
    if (message.role !== 'assistant') return;
    this.completed += this.text(); this.open = false;
    this.send({ sessionUpdate: 'woven_assistant_boundary' });
  }
}
