import { mkdir, readdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createAgentSession, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } from '@earendil-works/pi-coding-agent';
import { Credentials } from './credentials.mjs';
import { accessFailure, emptyConfig, modelRef, providerNames, providers, readJSON, validateConfig, writePrivateJSON } from './config.mjs';
import { searchTools } from './search.mjs';
import { providerFetch } from './transport.mjs';

export class DefaultAgentEngine {
  constructor({ cwd, directory, config = {}, credentials = {}, discover = true }) {
    this.cwd = cwd; this.directory = directory; this.config = validateConfig({ ...emptyConfig, ...config }); this.supplied = credentials; this.discover = discover; this.sessions = new Map();
  }
  async initialize() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    this.credentials = await new Credentials(join(this.directory, 'oauth.json'), this.supplied, this.discover).initialize();
    this.runtime = await ModelRuntime.create({ credentials: this.credentials, modelsPath: null, modelsStorePath: join(this.directory, 'models.json'), refreshOnCreate: false });
    return this;
  }
  catalog() {
    return this.runtime.getModels().filter(m => this.config.providers.includes(m.provider)).map(m => ({ id: modelRef(m), name: m.name, provider: m.provider, providerName: providerNames[m.provider] }));
  }
  async status() {
    const stored = await this.credentials.list();
    return { providers: providers.map(id => ({ id, name: providerNames[id], connected: stored.some(c => c.providerId === id) })), models: this.catalog(), searchConfigured: Boolean(this.supplied.exa?.key) };
  }
  modelOptions() {
    const all = this.catalog();
    return this.config.models.length ? this.config.models.flatMap(id => all.filter(m => m.id === id)) : all;
  }
  configuration(record, reason) {
    return { configOptions: [{ id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: record.selected,
      options: this.modelOptions().map(m => ({ value: m.id, name: `${m.name} · ${m.providerName}` })) }], ...(reason ? { _meta: { fallbackReason: reason, fallbackID: crypto.randomUUID() } } : {}) };
  }
  async create(id) {
    if (id && this.sessions.has(id)) return this.sessions.get(id);
    let manager;
    const sessionDir = join(this.directory, 'sessions');
    await mkdir(sessionDir, { recursive: true, mode: 0o700 });
    if (id) {
      if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error('Invalid Default Agent session.');
      const files = await readdir(sessionDir);
      const file = files.find(f => f.endsWith(`_${id}.jsonl`));
      if (!file) throw new Error('Default Agent session could not be found.');
      manager = SessionManager.open(join(sessionDir, file), sessionDir, this.cwd);
    } else {
      manager = SessionManager.create(this.cwd, sessionDir);
      // SDK defers persistence until the first assistant response. Woven Matter
      // needs even a configuration-only draft to have a durable identity.
      await writeFile(manager.getSessionFile(), JSON.stringify(manager.getHeader()) + '\n', { mode: 0o600, flag: 'wx' });
      manager = SessionManager.open(manager.getSessionFile(), sessionDir, this.cwd);
    }
    const saved = manager.buildSessionContext?.().model;
    const connected = new Set((await this.credentials.list()).map(c => c.providerId));
    const selected = (saved ? `${saved.provider}/${saved.modelId}` : null) ?? this.config.defaultModel ?? this.modelOptions().find(m => connected.has(m.provider))?.id ?? this.modelOptions()[0]?.id;
    const model = this.resolveModel(selected);
    const settingsManager = SettingsManager.inMemory({ retry: { enabled: false }, compaction: { enabled: true } });
    const loader = new DefaultResourceLoader({ cwd: this.cwd, agentDir: this.directory, settingsManager,
      noExtensions: true, noThemes: true,
      appendSystemPrompt: ['You are Default Agent in Woven Matter. Work in the supplied agent workspace. Use the Woven Matter CLI and workspace instructions for notes and databases. Use web_search and web_read for current information and cite source URLs. If search is not configured, direct the user to Settings → Default Agent. Never claim a tool succeeded when it failed.'] });
    await loader.reload();
    const { session } = await createAgentSession({ cwd: this.cwd, agentDir: this.directory, modelRuntime: this.runtime, model, sessionManager: manager, settingsManager, resourceLoader: loader,
      tools: ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls', 'web_search', 'web_read'], customTools: searchTools(this.supplied.exa?.key) });
    const record = { session, manager, selected: model ? modelRef(model) : selected, busy: false };
    const stream = session.agent.streamFunction;
    session.agent.streamFunction = (model, context, options) => stream(model, context, {
      ...options, transport: 'sse', maxRetries: 0, fetch: providerFetch(record),
    });
    this.sessions.set(session.sessionId, record);
    return record;
  }
  resolveModel(reference) { const slash = reference?.indexOf('/') ?? -1; return slash < 0 ? undefined : this.runtime.getModel(reference.slice(0, slash), reference.slice(slash + 1)); }
  async select(record, reference) {
    if (record.busy) throw new Error('Wait for the current response before changing models.');
    const model = this.resolveModel(reference);
    if (!model || !this.modelOptions().some(m => m.id === reference)) throw new Error('This model is not enabled in Settings → Default Agent.');
    await record.session.setModel(model); record.selected = reference;
    return this.configuration(record);
  }
  async prompt(record, text, emit) {
    if (record.busy) throw new Error('This Default Agent session already has an active turn.');
    record.busy = true;
    const beforeMessages = [...record.session.messages];
    const beforeLeaf = record.manager.getLeafId();
    let visible = false;
    const unsubscribe = record.session.subscribe(event => {
      if (event.type === 'message_update') {
        const update = event.assistantMessageEvent;
        if (update.type === 'text_delta' || update.type === 'thinking_delta') { visible = true; emit({ sessionUpdate: update.type === 'text_delta' ? 'agent_message_chunk' : 'agent_thought_chunk', content: { type: 'text', text: update.delta } }); }
      } else if (event.type === 'tool_execution_start') { visible = true; emit({ sessionUpdate: 'tool_call', toolCallId: event.toolCallId, title: event.toolName, kind: event.toolName === 'bash' ? 'execute' : 'other', status: 'in_progress', rawInput: event.args }); }
      else if (event.type === 'tool_execution_end') emit({ sessionUpdate: 'tool_call_update', toolCallId: event.toolCallId, status: event.isError ? 'failed' : 'completed', content: (event.result?.content ?? []).filter(c => c.type === 'text').map(c => ({ type: 'content', content: c })) });
    });
    try {
      const attempts = [...new Set([record.selected, ...this.config.fallbackModels].filter(Boolean))];
      let reason;
      for (let index = 0; index < attempts.length; index++) {
        const reference = attempts[index];
        if (!this.config.providers.includes(reference.split('/')[0])) { reason = 'The previous connection is disabled in Settings → Default Agent.'; continue; }
        record.httpAccessFailure = undefined;
        try {
          const model = this.resolveModel(reference);
          if (!model) throw new Error('Model is no longer available. Select a model in Settings → Default Agent.');
          if (!await this.credentials.read(model.provider)) throw new Error('Authentication required.');
          // Explicit auth deadlines also cover refresh; no provider requests happen during discovery.
          if (!await this.runtime.getAuth(model, { signal: AbortSignal.timeout(30000) })) throw new Error('Authentication required.');
          await record.session.setModel(model);
          if (record.selected !== reference) {
            record.selected = reference;
            emit({ sessionUpdate: 'config_option_update', ...this.configuration(record, `Switched to ${model.name} · ${providerNames[model.provider]}. ${reason}`) });
          }
          await record.session.prompt(text);
          const last = record.session.messages.at(-1);
          if (last?.role === 'assistant' && last.stopReason === 'error') throw new Error(last.errorMessage ?? 'The model request failed.');
          return { stopReason: last?.stopReason === 'aborted' ? 'cancelled' : 'end_turn' };
        } catch (error) {
          reason = record.httpAccessFailure !== undefined ? record.httpAccessFailure : accessFailure(error);
          if (!reason || visible) throw new Error(reason ?? 'The model request failed. Retry or check Settings → Default Agent.');
          if (beforeLeaf) record.manager.branch(beforeLeaf); else record.manager.resetLeaf();
          record.session.agent.state.messages = beforeMessages;
        }
      }
      throw new Error('No configured connection has access. Open Settings → Default Agent to sign in or update an API key.');
    } finally { unsubscribe(); record.busy = false; }
  }
  async handle(method, params = {}, emit = () => {}) {
    if (method === 'initialize') return { protocolVersion: 1, agentInfo: { name: 'wovenmatter-default-agent', version: '0.1.0' }, agentCapabilities: { loadSession: true, promptCapabilities: { image: false } }, authMethods: [] };
    if (method === 'woven/status') return this.status();
    if (method === 'session/new' || method === 'session/load') {
      const record = await this.create(method === 'session/load' ? params.sessionId : undefined);
      return { sessionId: record.session.sessionId, ...this.configuration(record) };
    }
    const record = this.sessions.get(params.sessionId) ?? await this.create(params.sessionId);
    if (method === 'session/set_config_option') return this.select(record, params.value);
    if (method === 'session/cancel') { await record.session.abort(); return {}; }
    if (method === 'session/prompt') return this.prompt(record, (params.prompt ?? []).filter(p => p.type === 'text').map(p => p.text).join('\n'), emit);
    throw new Error('Unsupported Default Agent operation.');
  }
}
