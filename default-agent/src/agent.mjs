import { randomUUID } from 'node:crypto';
import { mkdir } from 'node:fs/promises';
import { AgentError, connect } from './rpc.mjs';
import { ServerCredentials } from './credentials.mjs';
import { createModels, registerLocalServers } from './models.mjs';
import { Session } from './session.mjs';
import { dataDirectory } from './data.mjs';

// Pi Durable as an ACP agent over newline-delimited JSON-RPC on stdio.
// `extraProviders` lets tests add a synthetic model provider.
export async function runAgent({ input = process.stdin, output = process.stdout, extraProviders = [] } = {}) {
  const data = dataDirectory();
  await mkdir(data, { recursive: true, mode: 0o700 });
  const sessions = new Map();
  let models;
  const rpc = connect({ input, output, handle });
  const credentials = new ServerCredentials({
    fetch: () => rpc.request('woven/credentials', {}),
    report: (provider, credential) => rpc.notify('woven/credentials/update', { provider, credential }),
  });
  const ready = createModels({ dataDirectory: data, credentials, extraProviders }).then(value => { models = value; });

  async function handle(method, params) {
    await ready;
    if (method === 'initialize') return {
      protocolVersion: 1,
      agentCapabilities: { loadSession: true, promptCapabilities: { image: true, embeddedContext: true }, sessionCapabilities: { systemPrompt: {} } },
      agentInfo: { name: 'pi-durable', title: 'Pi Durable', version: 'current' },
      authMethods: [],
      _meta: { steering: { supported: true } },
    };
    if (method === 'session/new' || method === 'session/load') {
      const create = method === 'session/new';
      const sessionId = create ? randomUUID() : params.sessionId;
      if (sessions.has(sessionId)) throw new AgentError('This session is already open.');
      // Pi Durable's settings for this machine, read once when the session opens.
      const settings = await rpc.request('woven/settings', {}).then(reply => reply?.settings ?? {}, () => ({}));
      registerLocalServers(models.runtime, settings.localServers);
      const session = await Session.open({ models, settings, dataDirectory: data, sessionId, cwd: params.cwd, mcpServers: params.mcpServers, systemPrompt: appended(params.systemPrompt), notify: rpc.notify, create });
      sessions.set(sessionId, session);
      const configOptions = await session.configOptions();
      return create ? { sessionId, configOptions } : { configOptions };
    }
    if (!['session/prompt', '_session/steering', 'session/cancel', 'session/set_config_option'].includes(method)) throw new AgentError(`Unknown method ${method}.`, -32601);
    const session = sessions.get(params.sessionId);
    if (!session) throw new AgentError('That session is not open in this process. Load it first.', -32602);
    if (method === 'session/prompt') return session.prompt(params.prompt);
    if (method === '_session/steering') return session.steer(params.prompt);
    if (method === 'session/cancel') { await session.cancel(); return {}; }
    return { configOptions: await session.setConfigOption(params.configId, params.value) };
  }

  // ACP's system prompt addition: only `append`, only text.
  function appended(prompt) {
    if (prompt == null) return undefined;
    if (prompt.mode !== 'append' || !Array.isArray(prompt.content) || prompt.content.some(block => block?.type !== 'text')) {
      throw new AgentError('Pi Durable takes a system prompt addition in append mode, as text.', -32602);
    }
    return prompt.content.map(block => block.text).join('\n\n');
  }

  const shutdown = async () => {
    await Promise.allSettled([...sessions.values()].map(session => session.close()));
    await models?.runtime.settleCredentialWrites().catch(() => {});
    process.exit(0);
  };
  rpc.closed.then(shutdown);
  process.once('SIGTERM', shutdown);
}
