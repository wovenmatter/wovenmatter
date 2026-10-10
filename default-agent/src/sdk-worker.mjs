import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
let service;
const inferenceRequests = new Map();
const send = message => { if (process.connected) process.send?.(message, () => {}); };
process.on('error', () => {});
const allowed = new Set(['configure', 'invoke', 'poll', 'status', 'cancelActive', 'cancelSession', 'prepareRetirement', 'inferenceCatalog', 'unlockForClient']);
process.on('message', async message => {
  try {
    if (message.method === 'initialize') {
      const { createDefaultAgentService } = await import(pathToFileURL(join(message.root, 'src/service.mjs')).href);
      service = createDefaultAgentService({ cwd: message.cwd, directory: message.directory, attachmentState: message.attachmentState });
      send({ id: message.id, result: true }); return;
    }
    if (message.method === 'inferenceCancel') {
      inferenceRequests.get(message.requestID)?.abort();
      return;
    }
    if (message.method === 'inferenceStream' && service) {
      const controller = new AbortController(); inferenceRequests.set(message.id, controller);
      try {
        await service.inferenceStream(message.args[0], { ...message.args[1], signal: controller.signal,
          onEvent: event => send({ id: message.id, event }) });
        send({ id: message.id, result: true });
      } finally { inferenceRequests.delete(message.id); }
      return;
    }
    if (!service || !allowed.has(message.method)) throw new Error('Unknown runtime operation.');
    const result = await service[message.method](...(message.args ?? []));
    send({ id: message.id, result });
  } catch (error) {
    // Preserve existing service error semantics without serializing stack or
    // arbitrary thrown objects into the remote response.
    send({ id: message.id, error: { message: String(error.message ?? 'Pi Durable runtime operation failed.'), statusCode: error.statusCode } });
  }
});
process.on('disconnect', async () => {
  try { await service?.cancelActive(); } finally { process.exit(0); }
});
