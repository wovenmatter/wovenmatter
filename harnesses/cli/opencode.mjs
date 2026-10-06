import { AsyncLocalStorage } from 'node:async_hooks';
import { environment } from './binding.mjs';

const contextSchema = { type: 'object', required: ['executablePath', 'captureID'], properties: {
  executablePath: { type: 'string' }, socketPath: { type: ['string', 'null'] }, captureID: { type: 'string' },
}, additionalProperties: false };
const definition = { id: 'wovenmatter-cli', events: {}, methods: {
  connect: { input: { type: 'object', required: ['sessionID', 'context'], properties: {
    sessionID: { type: 'string' }, context: contextSchema,
  } }, output: { type: 'null' } },
  command: { input: { type: 'object', required: ['sessionID', 'name', 'context'], properties: {
    sessionID: { type: 'string' }, name: { type: 'string' }, text: { type: 'string' }, files: { type: 'array' },
    delivery: { type: 'string' }, context: contextSchema,
  } }, output: { type: 'null' } },
} };

export default {
  id: 'wovenmatter-cli',
  async setup(api) {
    const execution = new AsyncLocalStorage();
    const command = new AsyncLocalStorage();
    const registrations = [];
    registrations.push(await api.rpc.register(definition, {
      async connect({ sessionID, context }) {
        await api.session.get({ sessionID });
        await api.storage.set('connection:' + sessionID, { executablePath: context.executablePath, socketPath: context.socketPath ?? null });
        return null;
      },
      async command({ context, ...input }) {
        await command.run({ sessionID: input.sessionID, context }, () => api.session.command(input));
        return null;
      },
    }));
    registrations.push(await api.session.hook('prompt', event => {
      const active = command.getStore();
      if (active?.sessionID === event.sessionID) event.metadata = { ...event.metadata, wovenTools: active.context };
    }));
    registrations.push(await api.tool.transform(editor => {
      for (const tool of editor.list()) editor.update(tool.id, current => {
        const execute = current.execute;
        current.execute = async (input, toolContext) => {
          const captured = await inputContext(api, toolContext);
          const connection = await api.storage.get('connection:' + toolContext.sessionID) ?? captured;
          if (!connection) return execute(input, toolContext);
          const context = { ...connection, captureID: captured?.captureID ?? '' };
          return execution.run(context, () => execute(input, toolContext));
        };
      });
    }));
    registrations.push(await api.shell.hook('create.before', event => {
      const active = execution.getStore();
      if (active) event.env = environment(active, event.env);
    }));
    return async () => { for (const registration of registrations.reverse()) await registration.dispose(); };
  },
};

// The projected timeline retains the original user metadata through compaction.
// Anchor at the executing assistant so a later admitted input cannot retarget it.
async function inputContext(api, { sessionID, messageID }) {
  let cursor, found = false;
  do {
    const page = await api.session.messages({ sessionID, limit: 100, ...(cursor ? { cursor } : { order: 'desc' }) });
    for (const message of page.data) {
      if (message.id === messageID) found = true;
      else if (found && message.type === 'user') return message.metadata?.wovenTools;
    }
    cursor = page.cursor?.next;
  } while (cursor);
}
