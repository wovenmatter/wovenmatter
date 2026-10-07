import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
let service;
const send = message => { if (process.connected) process.send?.(message, () => {}); };
process.on('error', () => {});
const allowed = new Set(['configure', 'invoke', 'poll', 'status', 'cancelActive', 'cancelSession', 'prepareRetirement']);
process.on('message', async message => {
  try {
    if (message.method === 'initialize') {
      const { createDefaultAgentService } = await import(pathToFileURL(join(message.root, 'src/service.mjs')).href);
      service = createDefaultAgentService({ cwd: message.cwd, directory: message.directory, attachmentState: message.attachmentState });
      send({ id: message.id, result: true }); return;
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
