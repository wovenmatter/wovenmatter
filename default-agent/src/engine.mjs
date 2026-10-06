import { mkdir, realpath, stat } from 'node:fs/promises';
import { isAbsolute, join } from 'node:path';
import { ModelRuntime } from '@earendil-works/pi-coding-agent';
import { openDurableSession } from './durable-session.mjs';
import { Credentials } from './credentials.mjs';
import { accessFailure, DefaultAgentError, emptyConfig, modelRef, providerNames, providers, validateConfig } from './config.mjs';
import { registerLocalServers } from './local-servers.mjs';
import { ClaudeRuntime, isClaude } from './claude-runtime.mjs';
import { registerClaudeProviders } from './claude-provider.mjs';
import { modelOption } from './model-presentation.mjs';
import { SessionCLIContext } from './cli-context.mjs';

export class DefaultAgentEngine {
  constructor({ cwd, directory, config = {}, credentials = {}, credentialAccounts = {}, vault, requestCredentials, claude }) {
    this.cwd = cwd; this.directory = directory; this.config = validateConfig({ ...emptyConfig, ...config }); this.supplied = credentials; this.credentialAccounts = credentialAccounts; this.vault = vault; this.requestCredentials = requestCredentials; this.sessions = new Map();
    this.claude = claude ?? new ClaudeRuntime(directory);
  }
  async initialize() {
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    await this.claude.loadModels();
    this.credentials = await new Credentials(this.supplied, this.vault, this.credentialAccounts).initialize();
    this.runtime = await ModelRuntime.create({ credentials: this.credentials.forModelRuntime(), modelsPath: null, modelsStorePath: join(this.directory, 'models.json'), refreshOnCreate: false });
    registerLocalServers(this.runtime, this.config.customServers);
    const xaiModels = this.runtime.getModels().filter(model => model.provider === 'xai');
    if (xaiModels.length) this.runtime.registerProvider('xai-api', {
      name: 'xAI API key', baseUrl: 'https://api.x.ai/v1', api: 'openai-responses', authHeader: true,
      models: xaiModels.map(({ provider, api, baseUrl, ...model }) => model),
    });
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
    if (payload.credentials) { this.supplied = payload.credentials; await this.credentials.replace(payload.credentials, payload.credentialAccounts); }
    for (const record of this.sessions.values()) if (!record.busy) this.normalizeSelection(record);
  }
  catalog() {
    return this.runtime.getModels().filter(m => this.config.providers.includes(m.provider)).map(m => ({ id: modelRef(m), name: m.name, provider: m.provider, providerName: this.providerName(m.provider) }));
  }
  providerName(id) { return providerNames[id] ?? this.config.customServers.find(s => s.id === id)?.url ?? id; }
  async status({ signal } = {}) {
    signal?.throwIfAborted();
    const subscription = await this.claude.status((await this.credentials.read('claude-subscription'))?.accountId, { signal });
    signal?.throwIfAborted();
    if (subscription.connected || await this.credentials.read('anthropic')) {
      try {
        const discover = async () => this.claude.discover(subscription.connected ? undefined : (await this.credentials.read('anthropic'))?.key, { signal });
        if (this.claude.withProfile) await this.claude.withProfile((await this.credentials.read('claude-subscription'))?.accountId, discover);
        else await discover();
        registerClaudeProviders(this.runtime, this.claude, this.credentials);
      } catch {
        signal?.throwIfAborted(); // Cancellation is not an offline inventory fallback.
        // Keep the bundled aliases available when discovery is offline.
      }
    }
    signal?.throwIfAborted();
    return { providers: await Promise.all([...providers, ...this.config.customServers.map(s => s.id)].map(async id => { if (id === 'claude-subscription') return { id, name: this.providerName(id), ...subscription }; const c = await this.credentials.read(id); const expired = c?.type === 'oauth' && c.expires <= Date.now(); return { id, name: this.providerName(id), connected: Boolean(c) && !expired, state: !c || expired ? 'sign_in_required' : 'credentials_present', detail: expired ? 'Access expired. Reconnect Woven Matter or sign in.' : c ? 'Credentials stored; provider access has not been verified.' : 'No credentials stored.' }; })), models: this.catalog(), searchConfigured: Boolean((await this.credentials.read('exa'))?.key) };
  }

  modelOptions() {
    const all = this.catalog();
    const ids = [...this.config.models];
    const defaultModel = [this.config.defaultModel, this.implicitDefaultModel, all[0]?.id].find(id => all.some(m => m.id === id));
    if (defaultModel && !ids.includes(defaultModel)) ids.unshift(defaultModel);
    return ids.flatMap(id => all.filter(m => m.id === id));
  }
  normalizeSelection(record) {
    if (record.codeModeState) {
      record.codeModeState.value = this.config.codeMode;
      record.session.setActiveToolsByName([...record.ordinaryTools, ...(this.config.codeMode === 'off' ? [] : ['codemode'])]);
    }
    const visible = this.modelOptions();
    if (!visible.some(m => m.id === record.selected)) {
      record.selected = visible[0]?.id;
      this.persistOptions(record);
    }
  }
  thinkingLevels(record) {
    return record.session.getAvailableThinkingLevels?.() ?? [];
  }
  configuration(record, reason) {
    const levels = this.thinkingLevels(record);
    const thinking = record.session.thinkingLevel;
    return { availableCommands: [{ name: 'compact', description: 'Compact the conversation using the selected native provider, with Pi fallback for unsupported routes.', input: { hint: 'Optional compaction instructions' } }], configOptions: [{ id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: record.selected,
      options: this.modelOptions().map(modelOption) },
      ...(levels.length > 1 ? [{ id: 'thinking', name: 'Thinking Level', category: 'thought_level', type: 'select', currentValue: thinking,
        options: levels.map(value => ({ value, name: value[0].toUpperCase() + value.slice(1) })) }] : []),
      { id: 'permission_mode', name: 'Permissions', type: 'select', currentValue: 'full', options: [{ value: 'full', name: 'Full Access', description: 'Native Durable workspace tools run without approval prompts.' }] }], _meta: { engine: isClaude(record.selected) ? 'claude' : 'pi', ...(reason ? { fallbackReason: reason, fallbackID: crypto.randomUUID() } : {}) } };
  }
  persistOptions(record) {
    record.saveOptions({ selected: record.selected, permission: record.permission, thinking: record.session.thinkingLevel });
  }
  async sessionDirectory(value) {
    if (typeof value !== 'string' || !isAbsolute(value) || value.includes('\0') || Buffer.byteLength(value) > 4096) {
      throw new DefaultAgentError('Choose an absolute working directory for this Built-in session.');
    }
    try {
      const directory = await realpath(value);
      if (!(await stat(directory)).isDirectory()) throw new Error('Not a directory.');
      return directory;
    } catch {
      throw new DefaultAgentError('The Built-in session working directory is unavailable.');
    }
  }
  async create(id, requestedCwd) {
    const requested = requestedCwd === undefined ? undefined : await this.sessionDirectory(requestedCwd);
    if (id && this.sessions.has(id)) {
      const record = this.sessions.get(id);
      if (requested !== undefined && requested !== record.cwd) {
        throw new DefaultAgentError('This Built-in session belongs to a different working directory. Create a new session for this location.');
      }
      if (record.archiveError) throw new DefaultAgentError('The native archive is unavailable. Start a new conversation.');
      return record;
    }
    const record = await openDurableSession(this, id, requested);
    const options = record.options;
    const connected = new Set((await this.credentials.list()).map(c => c.providerId));
    const hasDefault = this.catalog().some(m => m.id === this.config.defaultModel);
    if (!options.selected && !hasDefault && this.config.providers.includes('claude-subscription') && !this.catalog().some(m => connected.has(m.provider))) {
      if ((await this.claude.status()).connected) connected.add('claude-subscription');
    }
    if (!hasDefault) this.implicitDefaultModel = this.catalog().find(m => connected.has(m.provider))?.id ?? this.catalog()[0]?.id;
    const visible = this.modelOptions();
    const selected = [options.selected, this.config.defaultModel].find(id => visible.some(m => m.id === id)) ?? visible[0]?.id;
    const model = this.resolveModel(selected);
    record.selected = model ? modelRef(model) : selected;
    if (model) await record.session.setModel(model);
    this.normalizeSelection(record);
    this.persistOptions(record);
    this.sessions.set(record.session.sessionId, record);
    await record.configurationQueue;
    await record.archiveQueue;
    return record;
  }
  resolveModel(reference) { const slash = reference?.indexOf('/') ?? -1; return slash < 0 ? undefined : this.runtime.getModel(reference.slice(0, slash), reference.slice(slash + 1)); }
  async select(record, reference, option = 'model') {
    if (record.busy) throw new Error('Wait for the current response before changing models.');
    if (option === 'thinking') {
      if (!this.thinkingLevels(record).includes(reference)) throw new DefaultAgentError('This thinking level is unavailable for the selected model.');
      await record.session.setThinkingLevel(reference);
      this.persistOptions(record);
      return this.configuration(record);
    }
    if (option === 'permission_mode') {
      if (reference !== 'full') throw new DefaultAgentError('Unknown permission mode.');
      record.permission = 'full'; this.persistOptions(record); return this.configuration(record);
    }
    if (option !== 'model') throw new DefaultAgentError('Unknown session option.');
    const model = this.resolveModel(reference);
    if (!model || !this.modelOptions().some(m => m.id === reference)) throw new DefaultAgentError('This model is not enabled in Settings → Built-in Agent.');
    const accounts = await this.credentials.candidates(model.provider);
    const account = accounts.find(a => a.credential && (a.credential.type !== 'oauth' || a.credential.expires > Date.now()));
    if (!account && model.provider !== 'claude-subscription') throw new DefaultAgentError(`Connect ${this.providerName(model.provider)} in Settings → Connections before choosing this model.`);
    try {
      const select = () => record.session.setModel(model);
      await this.credentials.runWithAccount(model.provider, account ?? accounts[0], () => model.provider === 'claude-subscription' && this.claude.withProfile
        ? this.claude.withProfile(account?.credential?.accountId, select) : select());
    } catch { throw new DefaultAgentError(`This ${this.providerName(model.provider)} connection is unavailable. Check its account in Settings → Connections.`); }
    record.selected = reference;
    this.persistOptions(record);
    await record.configurationQueue;
    return this.configuration(record);
  }
  async prompt(record, text, emit, cliContext) {
    record.emit = emit;
    record.allowFallback = false;
    record.lastError = undefined; record.lastCommandOutcome = undefined; record.nativeContextFailure = undefined;
    record.nativeVisible = false;
    if (record.busy) throw new DefaultAgentError('This Built-in session already has an active turn.');
    this.normalizeSelection(record);
    record.busy = true;
    record.cli ??= new SessionCLIContext();
    let ready;
    record.steeringReady = new Promise(resolve => { ready = resolve; });
    let finished;
    record.promptFinished = new Promise(resolve => { finished = resolve; });
    const controller = new AbortController();
    record.promptController = controller;
    let beforeLeaf;
    let visible = false;
    let steered = false;
    const usage = { inputTokens: 0, outputTokens: 0, cachedReadTokens: 0, cachedWriteTokens: 0 };
    const unsubscribe = record.subscribe(({ update, usage: value }) => {
      if (value) {
        usage.inputTokens += value.input ?? 0; usage.outputTokens += value.output ?? 0;
        usage.cachedReadTokens += value.cacheRead ?? 0; usage.cachedWriteTokens += value.cacheWrite ?? 0;
      }
      if (update) {
        if (['agent_message_chunk', 'agent_thought_chunk', 'tool_call'].includes(update.sessionUpdate)) visible = true;
        emit(update);
      }
    });
    try {
      beforeLeaf = await record.contextLeaf();
      controller.signal.throwIfAborted();
      const enabled = new Set(this.modelOptions().map(model => model.id));
      const references = [...new Set([record.selected, ...this.config.fallbackModels].filter(id => enabled.has(id)))];
      const attempts = [];
      for (const reference of references) {
        const provider = reference.split('/')[0];
        for (const account of await this.credentials.candidates(provider)) attempts.push({ reference, account, provider });
      }
      let reason;
      for (let index = 0; index < attempts.length; index++) {
        controller.signal.throwIfAborted();
        const { reference, account, provider } = attempts[index];
        record.accountID = account.id;
        if (!this.config.providers.includes(reference.split('/')[0])) { reason = 'The previous connection is disabled in Settings → Built-in Agent.'; continue; }
        record.httpAccessFailure = undefined;
        try {
          const withAccount = action => this.credentials.runWithAccount(provider, account, () =>
            provider === 'claude-subscription' && this.claude.withProfile
              ? this.claude.withProfile(account.credential?.accountId, action) : action());
          const run = async () => {
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
          const previousReference = record.selected;
          if (record.session.model?.provider !== model.provider || record.session.model?.id !== model.id) await record.session.setModel(model);
          controller.signal.throwIfAborted();
          let fallbackReason = reason ? `Switched to ${account.label} · ${this.providerName(model.provider)}. ${reason}` : undefined;
          if (previousReference !== reference) {
            record.selected = reference;
            fallbackReason = `Switched to ${model.name} · ${this.providerName(model.provider)}. ${reason}`;
          }
          this.persistOptions(record);
          const configuration = this.configuration(record, fallbackReason);
          emit({ sessionUpdate: 'config_option_update', ...configuration, _meta: { ...configuration._meta, engineUsed: true } });
          const continuations = [];
          const acceptSteer = (input, requestId, binding) => new Promise((resolve, reject) => {
            controller.signal.throwIfAborted();
            let accepted = false;
            const removeBinding = record.cli.enqueue(binding);
            const task = withAccount(() => record.session.prompt(input, {
              streamingBehavior: 'steer', requestId,
              preflightResult: disposition => {
                if (disposition === 'started' || disposition === 'queued') {
                  // Stop can arrive while extension preflight is suspended.
                  // Prevent its late completion from starting a fresh loop.
                  controller.signal.throwIfAborted();
                  accepted = true; steered = true; resolve({ outcome: 'injected' });
                } else {
                  reject(new DefaultAgentError('The input was handled without entering the model conversation.'));
                }
              },
            }));
            // Native preflight either injects into the current loop or starts
            // a continuation if that loop just ended. Keep the same credentials,
            // event subscription and ACP prompt alive until both have settled.
            continuations.push(task.finally(removeBinding).catch(error => {
              reject(error);
              if (accepted) return error;
            }));
          });
          try {
            let initialError;
            const removeInputBinding = record.cli.enqueue(cliContext);
            try {
              await record.session.prompt(text, { preflightResult: disposition => {
                if (disposition === 'started' || disposition === 'queued') { controller.signal.throwIfAborted(); record.acceptSteer = acceptSteer; ready(); }
                else { throw new DefaultAgentError('The input was handled without entering the model conversation.'); }
              } });
            } catch (error) { initialError = error; }
            finally { removeInputBinding(); }
            let continuationError;
            while (continuations.length) {
              const errors = await Promise.all(continuations.splice(0));
              continuationError ??= errors.find(Boolean);
            }
            if (continuationError) throw continuationError;
            if (initialError) throw initialError;
          } finally { record.acceptSteer = undefined; }
          if (controller.signal.aborted) return { stopReason: 'cancelled', usage };
          if (record.lastCommandOutcome) return { stopReason: record.lastCommandOutcome, usage };
          const last = record.session.messages.at(-1);
          if (last?.role === 'assistant' && last.stopReason === 'error') throw new Error(last.errorMessage ?? 'The model request failed.');
          return { stopReason: last?.stopReason === 'aborted' ? 'cancelled' : 'end_turn', usage };
          };
          return await withAccount(run);
        } catch (error) {
          if (controller.signal.aborted) return { stopReason: 'cancelled' };
          if (record.nativeContextFailure) throw new DefaultAgentError(record.nativeContextFailure.message);
          reason = record.httpAccessFailure !== undefined ? record.httpAccessFailure : (error.accessReason ?? accessFailure(error));
          if (!reason || visible || steered || record.nativeVisible) throw new DefaultAgentError(reason ?? (error instanceof DefaultAgentError ? error.message : 'The model request failed. Retry or check Settings → Connections.'));
          record.allowFallback = true;
          await record.rewind(beforeLeaf);
          await record.session.refreshContext();

        }
      }
      throw new DefaultAgentError('No configured connection has access. Open Settings → Connections to sign in or update an API key.');
    } catch (error) {
      if (controller.signal.aborted) return { stopReason: 'cancelled' };
      throw error;
    } finally {
      unsubscribe();
      record.cli.finish();
      record.busy = false;
      ready();
      record.steeringReady = undefined;
      finished();
      record.promptFinished = undefined;
      record.promptController = undefined;
    }
  }
  async steer(record, text, inputID, cliContext) {
    if (!text.trim()) throw new DefaultAgentError('A message is required.');
    if (!record.busy) return { outcome: 'promptRequired' };
    await record.steeringReady;
    if (record.promptController?.signal.aborted) throw new DefaultAgentError('The run is stopping. Send this message after it stops.');
    if (!record.acceptSteer) { await record.promptFinished; return { outcome: 'promptRequired' }; }
    return record.acceptSteer(text, inputID ?? crypto.randomUUID(), cliContext);
  }
  async handle(method, params = {}, emit = () => {}) {
    if (method === 'initialize') return { protocolVersion: 1, agentInfo: { name: 'wovenmatter-default-agent', version: '0.1.0' }, agentCapabilities: { loadSession: true, promptCapabilities: { image: false } }, authMethods: [], _meta: { steering: { supported: true } } };
    if (method === 'woven/status') return this.status();
    if (method === 'session/new' || method === 'session/load') {
      const record = await this.create(method === 'session/load' ? params.sessionId : undefined, params.cwd);
      if (params._meta?.wovenToolsConnection) record.cli.reconnect(params._meta.wovenToolsConnection);
      record.emit = emit;
      return { sessionId: record.session.sessionId, ...this.configuration(record) };
    }
    const record = this.sessions.get(params.sessionId) ?? await this.create(params.sessionId);
    if (method === 'session/set_config_option') return this.select(record, params.value, params.configId ?? params.id ?? 'model');
    if (method === 'woven/history') return record.history(params.after ?? 0, params.limit ?? 200);
    if (method === 'woven/idle') return record.waitIdle();
    if (method === 'session/cancel') {
      record.promptController?.abort();
      await record.session.abort();
      return {};
    }
    if (method === '_session/steering') return this.steer(record, (params.prompt ?? []).filter(p => p.type === 'text').map(p => p.text).join('\n'), params._meta?.wovenInputID, params._meta?.wovenTools);
    if (method === 'session/prompt') {
      if (record.busy) throw new DefaultAgentError('This Built-in session is still responding. Wait or stop it first.');
      const runID = params._meta?.wovenRunID;
      record.inputID = params._meta?.wovenInputID ?? runID; record.runID = runID; record.emit = emit;
      const result = await this.prompt(record, (params.prompt ?? []).filter(p => p.type === 'text').map(p => p.text).join('\n'), emit, params._meta?.wovenTools);
      return result;
    }
    throw new Error('Unsupported Built-in operation.');
  }
}
