// What a turn says, as the host saves it: the server's Pi Durable projection (ACP updates)
// folded into finished items. Text and thinking stream as deltas; a message, a thinking block
// and a tool call each finish once, in order, before whatever comes after them.
export class Turns {
  constructor(emit) {
    this.emit = emit;
    this.text = '';
    this.thinking = undefined;
    this.thinkingCount = 0;
    this.tools = new Map();
    this.calls = new Map();
  }

  // The projection, told the name and input of each call it announces.
  projection(Projection) {
    const calls = this.calls;
    const send = update => this.update(update);
    return new class extends Projection {
      async announce(id, name, args, status) {
        if (!calls.has(id) || Object.keys(args ?? {}).length) calls.set(id, { name, input: JSON.stringify(args ?? {}) });
        return super.announce(id, name, args, status);
      }
    }(send);
  }

  user(text) {
    this.finishActivity();
    this.finishMessage();
    this.emit({ type: 'userMessage', text });
  }

  update(update) {
    switch (update.sessionUpdate) {
      case 'agent_message_chunk':
        this.finishActivity();
        this.text += update.content.text;
        this.emit({ type: 'text', delta: update.content.text });
        break;
      case 'agent_thought_chunk':
        this.finishMessage();
        if (!this.thinking) this.thinking = { id: `thinking-${++this.thinkingCount}`, text: '' };
        this.thinking.text += update.content.text;
        this.emit({ type: 'thinking', id: this.thinking.id, delta: update.content.text });
        break;
      case 'tool_call': {
        this.finishActivity();
        this.finishMessage();
        const call = this.calls.get(update.toolCallId) ?? { name: update.title, input: '{}' };
        this.tools.set(update.toolCallId, call);
        this.emit({ type: 'toolStarted', callID: update.toolCallId, name: call.name, input: call.input });
        break;
      }
      case 'tool_call_update': {
        if (update.status !== 'completed' && update.status !== 'failed') break;
        const call = this.tools.get(update.toolCallId);
        if (!call) break;
        this.tools.delete(update.toolCallId);
        this.calls.delete(update.toolCallId);
        const output = (update.content ?? []).map(item => item.content?.text).filter(text => typeof text === 'string').join('\n\n');
        this.emit({ type: 'toolFinished', callID: update.toolCallId, name: call.name, input: call.input, output, failed: update.status === 'failed' });
        break;
      }
    }
  }

  // The turn ended: what is still open finishes, a call without a result as failed.
  end(failure, usage) {
    this.finishActivity();
    this.finishMessage();
    for (const [callID, call] of this.tools) this.emit({ type: 'toolFinished', callID, name: call.name, input: call.input, output: '', failed: true });
    this.tools.clear();
    this.calls.clear();
    this.emit({ type: 'turnFinished', failure: failure ?? null, usage: usage ?? null });
  }

  finishMessage() {
    if (!this.text) return;
    this.emit({ type: 'messageFinished', text: this.text });
    this.text = '';
  }

  finishActivity() {
    if (!this.thinking) return;
    this.emit({ type: 'thinkingFinished', id: this.thinking.id, text: this.thinking.text });
    this.thinking = undefined;
  }
}
