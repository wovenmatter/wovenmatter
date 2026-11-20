import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';

// A provider-free model. It needs the key `test-key` (an API key, or an OAuth
// access token after a refresh), so a reply proves the credential reached it.
// It answers `echo: <text> (turn N)`, N counting the user messages it sees;
// "delegate" makes it hand the work to a subagent first, and "slowly" makes it
// run `sleep 1` first.
export const model = { id: 'echo', name: 'Echo', provider: 'synthetic', api: 'synthetic', baseUrl: 'synthetic://local', reasoning: false,
  input: ['text', 'image'], contextWindow: 100000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };

function stream(model, context, options = {}) {
  const out = createAssistantMessageEventStream();
  const message = { role: 'assistant', api: model.api, provider: model.provider, model: model.id, content: [], timestamp: Date.now(), stopReason: 'stop',
    usage: { input: 3, output: 2, cacheRead: 1, cacheWrite: 0, totalTokens: 6, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
  queueMicrotask(() => {
    if (options.apiKey !== 'test-key') {
      Object.assign(message, { stopReason: 'error', errorMessage: 'No synthetic key.' });
      out.push({ type: 'error', reason: 'error', error: message }); out.end(message); return;
    }
    const last = context.messages.at(-1);
    const text = (Array.isArray(last.content) ? last.content : [{ type: 'text', text: last.content }]).filter(block => block.type === 'text').map(block => block.text).join(' ');
    out.push({ type: 'start', partial: message });
    if (last.role === 'user' && text.includes('delegate')) {
      const call = { type: 'toolCall', id: 'call-1', name: 'subagent', arguments: { description: 'Count', prompt: 'child work' } };
      message.content.push(call); message.stopReason = 'toolUse';
      out.push({ type: 'toolcall_start', contentIndex: 0, partial: message });
      out.push({ type: 'toolcall_end', contentIndex: 0, toolCall: call, partial: message });
    } else if (last.role === 'user' && text.includes('slowly')) {
      const call = { type: 'toolCall', id: 'call-slow', name: 'bash', arguments: { command: 'sleep 1' } };
      message.content.push(call); message.stopReason = 'toolUse';
      out.push({ type: 'toolcall_start', contentIndex: 0, partial: message });
      out.push({ type: 'toolcall_end', contentIndex: 0, toolCall: call, partial: message });
    } else {
      const reply = `echo: ${text} (turn ${context.messages.filter(item => item.role === 'user').length})`;
      message.content.push({ type: 'text', text: '' });
      out.push({ type: 'text_start', contentIndex: 0, partial: message });
      for (const piece of [reply.slice(0, 5), reply.slice(5)]) {
        message.content[0].text += piece;
        out.push({ type: 'text_delta', contentIndex: 0, delta: piece, partial: message });
      }
      out.push({ type: 'text_end', contentIndex: 0, content: reply, partial: message });
    }
    out.push({ type: 'done', reason: message.stopReason, message }); out.end(message);
  });
  return out;
}

export const synthetic = {
  id: 'synthetic', name: 'Synthetic',
  auth: {
    apiKey: { name: 'Synthetic key', resolve: async ({ credential }) => credential?.key ? { auth: { apiKey: credential.key } } : undefined },
    oauth: { name: 'Synthetic sign-in', login: async () => { throw new Error('No sign-in in tests.'); },
      refresh: async credential => ({ ...credential, access: 'test-key', refresh: 'renewed', expires: Date.now() + 3600000 }),
      toAuth: async credential => ({ apiKey: credential.access }) },
  },
  getModels: () => [model], getAllModels: () => [model], stream, streamSimple: stream,
};
