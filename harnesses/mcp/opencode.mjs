import { wovenInstructions } from './instructions.mjs';
import { AsyncLocalStorage } from 'node:async_hooks';
import { randomUUID, createHash } from 'node:crypto';
import { createMCPProxy } from './proxy.mjs';
import { validateConnection } from './binding.mjs';

const contextSchema = { type: 'object', required: ['endpointURL', 'bearerToken'], properties: {
  endpointURL: { type: 'string' }, bearerToken: { type: 'string' }, captureID: { type: ['string', 'null'] }, sessionID: { type: ['string', 'null'] },
}, additionalProperties: false };
const captureSchema = { type: 'object', properties: { captureID: { type: ['string', 'null'] } }, additionalProperties: false };
const definition = { id: 'woven-mcp', events: {}, methods: {
  connect: { input: { type: 'object', required: ['sessionID', 'context'], properties: {
    sessionID: { type: 'string' }, context: contextSchema,
  } }, output: contextSchema },
  command: { input: { type: 'object', required: ['sessionID', 'name', 'context'], properties: {
    sessionID: { type: 'string' }, name: { type: 'string' }, text: { type: 'string' }, files: { type: 'array' },
    delivery: { type: 'string' }, context: captureSchema,
  } }, output: { type: 'null' } },
} };
const serverName = sessionID => 'woven_' + createHash('sha256').update(sessionID).digest('hex').slice(0, 16);

export default {
  id: 'woven-mcp',
  async setup(api) {
    const command = new AsyncLocalStorage(), sessions = new Map(), registrations = [];
    registrations.push(await api.rpc.register(definition, {
      async connect({ sessionID, context }) {
        await api.session.get({ sessionID });
        validateConnection(context);
        let entry = sessions.get(sessionID);
        if (!entry) {
          entry = { context, calls: new Map(), name: serverName(sessionID) };
          entry.proxy = await createMCPProxy({ getConnection: () => entry.context,
            contextFor: id => entry.calls.get(id)?.captureID });
          sessions.set(sessionID, entry);
        } else entry.context = context;
        // Credentials live only in memory and the native MCP runtime override.
        // They are never persisted as session/message metadata or plugin storage.
        return entry.proxy.connection;
      },
      async command({ context, ...input }) {
        await command.run({ sessionID: input.sessionID, context }, () => api.session.command(input));
        return null;
      },
    }));
    registrations.push(await api.session.hook('context', async event => {
      if (!sessions.has(event.sessionID)) return;
      event.system = event.system.filter(part => part.text !== wovenInstructions);
      event.system.push({ type: 'text', text: wovenInstructions });
    }));
    registrations.push(await api.session.hook('prompt', event => {
      const active = command.getStore();
      if (active?.sessionID === event.sessionID) event.metadata = { ...event.metadata, wovenMCP: active.context };
    }));
    registrations.push(await api.tool.transform(editor => {
      for (const tool of editor.list()) editor.update(tool.id, current => {
        const execute = current.execute;
        current.execute = async (input, toolContext) => {
          const owner = [...sessions.entries()].find(([, entry]) => tool.id.startsWith(entry.name + '_'));
          if (!owner) return execute(input, toolContext);
          const [sessionID, entry] = owner;
          // Runtime MCP overrides are Location-scoped in OpenCode. A session
          // must never borrow another chat's registered Woven credential.
          if (toolContext.sessionID !== sessionID) throw new Error('This Woven MCP tool belongs to another session.');
          if (tool.id !== entry.name + '_woven_context') return execute(input, toolContext);
          const captured = await inputContext(api, toolContext);
          const requestID = randomUUID();
          entry.calls.set(requestID, { captureID: captured?.captureID ?? '', at: Date.now() });
          for (const [id, value] of entry.calls) if (entry.calls.size > 2048 || value.at < Date.now() - 86400000) entry.calls.delete(id);
          return execute({ ...input, requestID }, toolContext);
        };
      });
    }));
    return async () => {
      for (const entry of sessions.values()) entry.proxy.close();
      for (const registration of registrations.reverse()) await registration.dispose();
    };
  },
};

// Anchor to the executing assistant; queued or later steering cannot retarget it.
async function inputContext(api, { sessionID, messageID }) {
  let cursor, found = false;
  do {
    const page = await api.session.messages({ sessionID, limit: 100, ...(cursor ? { cursor } : { order: 'desc' }) });
    for (const message of page.data) {
      if (message.id === messageID) found = true;
      else if (found && message.type === 'user') return message.metadata?.wovenMCP;
    }
    cursor = page.cursor?.next;
  } while (cursor);
}
