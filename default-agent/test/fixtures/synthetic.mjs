import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';

// A provider-free model. It needs the key `test-key` (an API key, or an OAuth
// access token after a refresh), so a reply proves the credential reached it.
// It answers `echo: <text> (turn N)`, N counting the user messages it sees,
// followed by ` [images: N]` when the last message carried images;
// "delegate" makes it hand the work to a subagent first, and "slowly" makes it
// run `sleep 1` first. A message starting `script:` runs the rest as a code
// mode script, and `call: <tool> <JSON arguments>` calls that tool; `tools?`
// answers with the names of the tools it is offered, and `prompt?` with its
// system prompt.
export const model = { id: 'echo', name: 'Echo', provider: 'synthetic', api: 'synthetic', baseUrl: 'synthetic://local', reasoning: false,
  input: ['text', 'image'], contextWindow: 100000, maxTokens: 1000, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } };
// A second, newer model: a new chat starts on it, so tests switch from it to `echo`.
export const other = { ...model, id: 'echo-2', name: 'Echo 2' };

// The tools and system prompt in effect at the end of the transcript, from its system messages.
function effective(context) {
  const tools = new Map((context.tools ?? []).map(tool => [tool.name, tool])), sections = new Map(), prompt = [context.systemPrompt ?? ''];
  for (const message of context.messages) {
    if (message.role !== 'system') continue;
    prompt.push(typeof message.content === 'string' ? message.content : message.content.map(block => block.text ?? '').join(''));
    for (const [name, text] of Object.entries(message.sections ?? {})) text === null ? sections.delete(name) : sections.set(name, text);
    for (const tool of message.toolsAdded ?? []) tools.set(tool.name, tool);
    for (const tool of message.toolsRemoved ?? []) tools.delete(tool.name);
  }
  return { tools: [...tools.values()], prompt: [...prompt, ...sections.values()].filter(Boolean).join('\n\n') };
}

function stream(model, context, options = {}) {
  const out = createAssistantMessageEventStream();
  const message = { role: 'assistant', api: model.api, provider: model.provider, model: model.id, content: [], timestamp: Date.now(), stopReason: 'stop',
    usage: { input: 3, output: 2, cacheRead: 1, cacheWrite: 0, totalTokens: 6, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
  queueMicrotask(() => {
    if (options.apiKey !== 'test-key') {
      Object.assign(message, { stopReason: 'error', errorMessage: 'No synthetic key.' });
      out.push({ type: 'error', reason: 'error', error: message }); out.end(message); return;
    }
    const last = context.messages.findLast(item => item.role !== 'system');
    const text = (Array.isArray(last.content) ? last.content : [{ type: 'text', text: last.content }]).filter(block => block.type === 'text').map(block => block.text).join(' ');
    out.push({ type: 'start', partial: message });
    const turn = context.messages.filter(item => item.role === 'user').length;
    if (last.role === 'user' && text.startsWith('script:')) {
      const call = { type: 'toolCall', id: `call-script-${turn}`, name: 'codemode', arguments: { code: text.slice('script:'.length).trim() } };
      message.content.push(call); message.stopReason = 'toolUse';
      out.push({ type: 'toolcall_start', contentIndex: 0, partial: message });
      out.push({ type: 'toolcall_end', contentIndex: 0, toolCall: call, partial: message });
    } else if (last.role === 'user' && text.startsWith('call:')) {
      const [, name, args] = text.match(/^call:\s*(\S+)\s*(.*)$/s);
      const call = { type: 'toolCall', id: `call-direct-${turn}`, name, arguments: JSON.parse(args || '{}') };
      message.content.push(call); message.stopReason = 'toolUse';
      out.push({ type: 'toolcall_start', contentIndex: 0, partial: message });
      out.push({ type: 'toolcall_end', contentIndex: 0, toolCall: call, partial: message });
    } else if (last.role === 'user' && text.includes('delegate')) {
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
      const images = Array.isArray(last.content) ? last.content.filter(block => block.type === 'image').length : 0;
      const reply = last.role === 'user' && text === 'tools?' ? `tools: ${effective(context).tools.map(tool => tool.name).join(',')}`
        : last.role === 'user' && text === 'prompt?' ? `prompt: ${effective(context).prompt}`
        : `echo: ${text} (turn ${turn})${images ? ` [images: ${images}]` : ''}`;
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
  getModels: () => [model, other], getAllModels: () => [model, other], stream, streamSimple: stream,
};
