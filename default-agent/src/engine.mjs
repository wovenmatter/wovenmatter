import { mkdir, readdir, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { createAgentSession, createCodingTools, DefaultResourceLoader, ModelRuntime, SessionManager, SettingsManager } from '@earendil-works/pi-coding-agent';
import { Credentials } from './credentials.mjs';
import { accessFailure, DefaultAgentError, emptyConfig, modelRef, providerNames, providers, validateConfig } from './config.mjs';
import { searchTools } from './search.mjs';
import { providerFetch } from './transport.mjs';
import { registerLocalServers } from './local-servers.mjs';
import { ClaudeRuntime, isClaude } from './claude-runtime.mjs';
import { registerClaudeProviders } from './claude-provider.mjs';

const builtInInstructions = 'You are Built-in in Woven Matter. Work in the supplied agent workspace. Use the wovenmatter CLI and workspace instructions for notes and databases. Use web_search and web_read for current information and cite source URLs. If search is not configured, direct the user to Settings → Connections. Never claim a tool succeeded when it failed.';

export class DefaultAgentEngine {
  constructor({ cwd, directory, config = {}, credentials = {}, vault, requestCredentials, claude, requestPermission }) {
    this.cwd = cwd; this.directory = directory; this.config = validateConfig({ ...emptyConfig, ...config }); this.supplied = credentials; this.vault = vault; this.requestCredentials = requestCredentials; this.sessions = new Map();
    this.claude = claude ?? new ClaudeRuntime(directory); this.requestPermission = requestPermission;
  }
  async initialize() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    await this.claude.loadModels();
    this.credentials = await new Credentials(this.supplied, this.vault).initialize();
    this.runtime = await ModelRuntime.create({ credentials: this.credentials, modelsPath: null, modelsStorePath: join(this.directory, 'models.json'), refreshOnCreate: false });
    registerLocalServers(this.runtime, this.config.customServers);
    registerClaudeProviders(this.runtime, this.claude, this.credentials);
    const resolveAuth = this.runtime.getAuth.bind(this.runtime);
    this.runtime.getAuth = async (model, options = {}) => {
      const provider = typeof model === 'string' ? model : model.provider;
      if (isClaude(provider + '/')) return resolveAuth(model, options);
      let credential = await this.credentials.read(provider);
      if (credential?.borrowed) {
        if (credential.expires <= Date.now() + 60000 && this.requestCredentials) {
          try { await this.apply(await this.requestCredentials()); }
          catch (error) {
            // An early renewal failure must not discard access that still works.
            if (credential.expires <= Date.now()) throw error;
          }
          credential = await this.credentials.read(provider);
        }
        // Borrowers do not call refresh. Keep valid access usable during a
        // transient renewal failure. Expired access pauses between requests.
        while (credential?.borrowed && credential.expires <= Date.now()) {
          if (options.allowWait === false) throw new Error('Authentication required.');
          options.signal?.throwIfAborted();
          await new Promise((resolve, reject) => {
            const done = () => { clearTimeout(timer); options.signal?.removeEventListener('abort', abort); resolve(); };
            const abort = () => { clearTimeout(timer); reject(options.signal.reason); };
            const timer = setTimeout(done, 1000);
            options.signal?.addEventListener('abort', abort, { once: true });
          });
          if (this.requestCredentials) await this.apply(await this.requestCredentials());
          credential = await this.credentials.read(provider);
        }
        if (!credential) throw new Error('Authentication required.');
        if (credential.borrowed) return { auth: await this.runtime.getProvider(provider).auth.oauth.toAuth(credential), source: 'OAuth' };
      }
      if (!credential) throw new Error('Authentication required.');
      return resolveAuth(model, options);
    };
    return this;
  }
  async apply(payload) {
    if (payload.config) {
      const config = validateConfig(payload.config);
      for (const server of this.config.customServers) if (!config.customServers.some(s => s.id === server.id)) this.runtime.unregisterProvider(server.id);
      this.config = config;
      registerLocalServers(this.runtime, config.customServers);
    }
    if (payload.credentials) { this.supplied = payload.credentials; await this.credentials.replace(payload.credentials); }
  }
  catalog() {
    return this.runtime.getModels().filter(m => this.config.providers.includes(m.provider)).map(m => ({ id: modelRef(m), name: m.name, provider: m.provider, providerName: this.providerName(m.provider) }));
  }
  providerName(id) { return providerNames[id] ?? this.config.customServers.find(s => s.id === id)?.url ?? id; }
  async status() {
    const subscription = await this.claude.status();
    if (subscription.connected || await this.credentials.read('anthropic')) {
      try { await this.claude.discover(subscription.connected ? undefined : (await this.credentials.read('anthropic'))?.key); registerClaudeProviders(this.runtime, this.claude, this.credentials); } catch { /* Keep the bundled aliases available when discovery is offline. */ }
    }
    return { providers: await Promise.all([...providers, ...this.config.customServers.map(s => s.id)].map(async id => { if (id === 'claude-subscription') return { id, name: this.providerName(id), ...subscription }; const c = await this.credentials.read(id); const expired = c?.type === 'oauth' && c.expires <= Date.now(); return { id, name: this.providerName(id), connected: Boolean(c) && !expired, state: !c || expired ? 'sign_in_required' : 'credentials_present', detail: expired ? 'Access expired. Reconnect Woven Matter or sign in.' : c ? 'Credentials stored; provider access has not been verified.' : 'No credentials stored.' }; })), models: this.catalog(), searchConfigured: Boolean((await this.credentials.read('exa'))?.key) };
  }
  modelOptions() {
    const all = this.catalog();
    return this.config.models.length ? this.config.models.flatMap(id => all.filter(m => m.id === id)) : all;
  }
  thinkingLevels(record) {
    return record.session.getAvailableThinkingLevels?.() ?? [];
  }
  configuration(record, reason) {
    const levels = this.thinkingLevels(record);
    const thinking = record.session.thinkingLevel;
    return { configOptions: [{ id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: record.selected,
      options: this.modelOptions().map(m => ({ value: m.id, name: `${m.name} · ${m.providerName}` })) },
      ...(levels.length > 1 ? [{ id: 'thinking', name: 'Thinking Level', category: 'thought_level', type: 'select', currentValue: thinking,
        options: levels.map(value => ({ value, name: value[0].toUpperCase() + value.slice(1) })) }] : []),
      { id: 'permission_mode', name: 'Permissions', type: 'select', currentValue: record.permission ?? 'normal', options: [
        { value: 'normal', name: 'Ask Before Changes', description: 'Ask before running commands or changing files.' },
        { value: 'full', name: 'Full Access', description: 'Allow workspace tools to run without approval prompts.' },
      ] }], _meta: { engine: isClaude(record.selected) ? 'claude' : 'pi', ...(reason ? { fallbackReason: reason, fallbackID: crypto.randomUUID() } : {}) } };
  }
  persistOptions(record) {
    record.manager.appendCustomEntry('woven-built-in-options', { selected: record.selected, permission: record.permission, thinking: record.session.thinkingLevel });
  }
  async approve(record, name, input, signal, toolCallId) {
    signal?.throwIfAborted();
    if (record.permission === 'full') return true;
    if (!record.requestPermission && !this.requestPermission) return false;
    return (record.requestPermission ?? this.requestPermission)({ sessionId: record.session.sessionId,
      toolCall: { toolCallId, title: name, kind: name.toLowerCase() === 'bash' ? 'execute' : 'other', rawInput: input },
      options: [{ optionId: 'allow', name: 'Allow once', kind: 'allow_once' }, { optionId: 'deny', name: 'Deny', kind: 'reject_once' }] }, signal);
  }
  async create(id) {
    if (id && this.sessions.has(id)) return this.sessions.get(id);
    let manager;
    const sessionDir = join(this.directory, 'sessions');
    await mkdir(sessionDir, { recursive: true, mode: 0o700 });
    if (id) {
      if (!/^[0-9a-f-]{36}$/i.test(id)) throw new Error('Invalid Built-in session.');
      const files = await readdir(sessionDir);
      const file = files.find(f => f.endsWith(`_${id}.jsonl`));
      if (!file) throw new Error('Built-in session could not be found.');
      manager = SessionManager.open(join(sessionDir, file), sessionDir, this.cwd);
    } else {
      manager = SessionManager.create(this.cwd, sessionDir);
      // SDK defers persistence until the first assistant response. Woven Matter
      // needs even a configuration-only draft to have a durable identity.
      await writeFile(manager.getSessionFile(), JSON.stringify(manager.getHeader()) + '\n', { mode: 0o600, flag: 'wx' });
      manager = SessionManager.open(manager.getSessionFile(), sessionDir, this.cwd);
    }
    const saved = manager.buildSessionContext?.().model;
    const options = manager.getEntries().filter(e => e.type === 'custom' && e.customType === 'woven-built-in-options').at(-1)?.data ?? {};
    const connected = new Set((await this.credentials.list()).map(c => c.providerId));
    if (!options.selected && !saved && !this.config.defaultModel && this.config.providers.includes('claude-subscription') && !this.modelOptions().some(m => connected.has(m.provider))) {
      if ((await this.claude.status()).connected) connected.add('claude-subscription');
    }
    const selected = options.selected ?? (saved ? `${saved.provider}/${saved.modelId}` : null) ?? this.config.defaultModel ?? this.modelOptions().find(m => connected.has(m.provider))?.id ?? this.modelOptions()[0]?.id;
    const model = this.resolveModel(selected);
    const settingsManager = SettingsManager.inMemory({ retry: { enabled: false }, compaction: { enabled: true } });
    const loader = new DefaultResourceLoader({ cwd: this.cwd, agentDir: this.directory, settingsManager,
      noExtensions: true, noThemes: true,
      appendSystemPrompt: [builtInInstructions] });
    await loader.reload();
    const record = { manager, selected, busy: false, permission: options.permission ?? 'normal' };
    const guardedTools = createCodingTools(this.cwd).map(tool => ({ ...tool, label: tool.label ?? tool.name,
      execute: async (id, input, signal, onUpdate) => {
        if (['bash', 'write', 'edit'].includes(tool.name) && !await this.approve(record, tool.name, input, signal, id)) throw new Error('The user declined this tool.');
        return tool.execute(id, input, signal, onUpdate);
      } }));
    const { session } = await createAgentSession({ cwd: this.cwd, agentDir: this.directory, modelRuntime: this.runtime, model, thinkingLevel: options.thinking, sessionManager: manager, settingsManager, resourceLoader: loader,
      tools: ['read', 'bash', 'edit', 'write', 'grep', 'find', 'ls', 'web_search', 'web_read'], customTools: [...guardedTools, ...searchTools(async () => (await this.credentials.read('exa'))?.key)] });
    record.session = session;
    record.selected = model ? modelRef(model) : selected;
    const stream = session.agent.streamFunction;
    session.agent.streamFunction = (model, context, options) => stream(model, context, {
      ...options, transport: 'sse', maxRetries: 0, fetch: providerFetch(record),
    });
    this.sessions.set(session.sessionId, record);
    return record;
  }
  resolveModel(reference) { const slash = reference?.indexOf('/') ?? -1; return slash < 0 ? undefined : this.runtime.getModel(reference.slice(0, slash), reference.slice(slash + 1)); }
  async select(record, reference, option = 'model') {
    if (record.busy) throw new Error('Wait for the current response before changing models.');
    if (option === 'thinking') {
      if (!this.thinkingLevels(record).includes(reference)) throw new DefaultAgentError('This thinking level is unavailable for the selected model.');
      record.session.setThinkingLevel(reference);
      this.persistOptions(record);
      return this.configuration(record);
    }
    if (option === 'permission_mode') {
      if (!['normal', 'full'].includes(reference)) throw new DefaultAgentError('Unknown permission mode.');
      record.permission = reference; this.persistOptions(record); return this.configuration(record);
    }
    if (option !== 'model') throw new DefaultAgentError('Unknown session option.');
    const model = this.resolveModel(reference);
    if (!model || !this.modelOptions().some(m => m.id === reference)) throw new Error('This model is not enabled in Settings → Built-in Agent.');
    await record.session.setModel(model);
    record.selected = reference;
    this.persistOptions(record);
    return this.configuration(record);
  }
  async prompt(record, text, emit, requestPermission) {
    if (record.busy) throw new DefaultAgentError('This Built-in session already has an active turn.');
    record.busy = true;
    const controller = new AbortController();
    record.promptController = controller;
    record.requestPermission = requestPermission;
    const beforeMessages = [...record.session.messages];
    const beforeLeaf = record.manager.getLeafId();
    let visible = false;
    const usage = { inputTokens: 0, outputTokens: 0, cachedReadTokens: 0, cachedWriteTokens: 0 };
    let messageSequence = 0;
    const unsubscribe = record.session.subscribe(event => {
      if (event.type === 'message_start') messageSequence += 1;
      if (event.type === 'message_end' && event.message?.role === 'assistant' && event.message.usage) {
        const value = event.message.usage;
        usage.inputTokens += value.input ?? 0; usage.outputTokens += value.output ?? 0;
        usage.cachedReadTokens += value.cacheRead ?? 0; usage.cachedWriteTokens += value.cacheWrite ?? 0;
      }
      if (event.type === 'message_update') {
        const update = event.assistantMessageEvent;
        if (update.type === 'text_delta' || update.type === 'thinking_delta') { visible = true; emit({ sessionUpdate: update.type === 'text_delta' ? 'agent_message_chunk' : 'agent_thought_chunk', content: { type: 'text', text: update.delta }, ...(update.type === 'thinking_delta' ? { _meta: { wovenThoughtID: `built-in-${messageSequence}-${update.contentIndex ?? 0}` } } : {}) }); }
      } else if (event.type === 'tool_execution_start') { visible = true; emit({ sessionUpdate: 'tool_call', toolCallId: event.toolCallId, title: event.toolName, kind: event.toolName === 'bash' ? 'execute' : 'other', status: 'in_progress', rawInput: event.args }); }
      else if (event.type === 'tool_execution_end') emit({ sessionUpdate: 'tool_call_update', toolCallId: event.toolCallId, status: event.isError ? 'failed' : 'completed', content: (event.result?.content ?? []).filter(c => c.type === 'text').map(c => ({ type: 'content', content: c })) });
    });
    try {
      const attempts = [...new Set([record.selected, ...this.config.fallbackModels].filter(Boolean))];
      let reason;
      for (let index = 0; index < attempts.length; index++) {
        controller.signal.throwIfAborted();
        const reference = attempts[index];
        if (!this.config.providers.includes(reference.split('/')[0])) { reason = 'The previous connection is disabled in Settings → Built-in Agent.'; continue; }
        record.httpAccessFailure = undefined;
        try {
          const model = this.resolveModel(reference);
          if (!model) throw new Error('Model is no longer available. Select a model in Settings → Built-in Agent.');
          if (isClaude(reference)) {
            if (model.provider === 'anthropic' && !await this.credentials.read('anthropic')) throw new Error('Authentication required.');
          } else {
            if (!await this.credentials.read(model.provider)) throw new Error('Authentication required.');
            const signal = AbortSignal.any([controller.signal, AbortSignal.timeout(30000)]);
            if (!await this.runtime.getAuth(model, { signal, allowWait: false })) throw new Error('Authentication required.');
            controller.signal.throwIfAborted();
          }
          controller.signal.throwIfAborted();
          if (record.session.model?.provider !== model.provider || record.session.model?.id !== model.id) await record.session.setModel(model);
          controller.signal.throwIfAborted();
          let fallbackReason;
          if (record.selected !== reference) {
            record.selected = reference;
            fallbackReason = `Switched to ${model.name} · ${this.providerName(model.provider)}. ${reason}`;
          }
          this.persistOptions(record);
          const configuration = this.configuration(record, fallbackReason);
          emit({ sessionUpdate: 'config_option_update', ...configuration, _meta: { ...configuration._meta, engineUsed: true } });
          await record.session.prompt(text);
          if (controller.signal.aborted) return { stopReason: 'cancelled', usage };
          const last = record.session.messages.at(-1);
          if (last?.role === 'assistant' && last.stopReason === 'error') throw new Error(last.errorMessage ?? 'The model request failed.');
          return { stopReason: last?.stopReason === 'aborted' ? 'cancelled' : 'end_turn', usage };
        } catch (error) {
          if (controller.signal.aborted) return { stopReason: 'cancelled' };
          reason = record.httpAccessFailure !== undefined ? record.httpAccessFailure : (error.accessReason ?? accessFailure(error));
          if (!reason || visible) throw new DefaultAgentError(reason ?? (error instanceof DefaultAgentError ? error.message : 'The model request failed. Retry or check Settings → Connections.'));
          if (beforeLeaf) record.manager.branch(beforeLeaf); else record.manager.resetLeaf();
          record.session.agent.state.messages = beforeMessages;
        }
      }
      throw new DefaultAgentError('No configured connection has access. Open Settings → Connections to sign in or update an API key.');
    } catch (error) {
      if (controller.signal.aborted) return { stopReason: 'cancelled' };
      throw error;
    } finally {
      unsubscribe();
      record.busy = false;
      record.promptController = undefined;
      record.requestPermission = undefined;
    }
  }
  async handle(method, params = {}, emit = () => {}, requestPermission) {
    if (method === 'initialize') return { protocolVersion: 1, agentInfo: { name: 'wovenmatter-default-agent', version: '0.1.0' }, agentCapabilities: { loadSession: true, promptCapabilities: { image: false } }, authMethods: [] };
    if (method === 'woven/status') return this.status();
    if (method === 'session/new' || method === 'session/load') {
      const record = await this.create(method === 'session/load' ? params.sessionId : undefined);
      return { sessionId: record.session.sessionId, ...this.configuration(record) };
    }
    const record = this.sessions.get(params.sessionId) ?? await this.create(params.sessionId);
    if (method === 'session/set_config_option') return this.select(record, params.value, params.configId ?? params.id ?? 'model');
    if (method === 'session/cancel') {
      record.promptController?.abort();
      await record.session.abort();
      return {};
    }
    if (method === 'session/prompt') return this.prompt(record, (params.prompt ?? []).filter(p => p.type === 'text').map(p => p.text).join('\n'), emit, requestPermission);
    throw new Error('Unsupported Built-in operation.');
  }
}
