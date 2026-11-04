import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';

export function assistantMessage(model, content, overrides = {}) {
  return { role: 'assistant', content, api: model.api, provider: model.provider, model: model.id, timestamp: Date.now(),
    stopReason: content.some(block => block.type === 'toolCall') ? 'toolUse' : 'stop',
    usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, ...overrides };
}
export function emitAssistant(stream, message) {
  stream.push({ type: 'start', partial: message });
  stream.push(message.stopReason === 'error' ? { type: 'error', reason: 'error', error: message } : { type: 'done', reason: message.stopReason, message });
  stream.end(message);
  return stream;
}
export const assistantStream = message => emitAssistant(createAssistantMessageEventStream(), message);
