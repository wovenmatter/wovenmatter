import { randomUUID } from 'node:crypto';
import { readFile, realpath, stat } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { DatabaseSync } from 'node:sqlite';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { AgentDoc, AssistantEntry, Harness, UsageDoc, createRegistry, defineExtension, section } from '@earendil-works/pi-durable';
import { NodeExecutionEnv } from '@earendil-works/pi-durable/env/node';
import { createNodePhotonImages } from '@earendil-works/pi-durable/images/node';
import { openNodeSqliteStorage } from '@earendil-works/pi-durable/storage/sqlite/node';
import { createCodingTools } from '@earendil-works/pi-durable/tools';
import { AgentError, humanMessage } from './rpc.mjs';
import { availableModels, modelReference, offeredModels, refreshCatalogs, thinkingLevels } from './models.mjs';
import { Projection } from './projection.mjs';
import { Subagents, Workflow, connectMcp, createSearch } from './tools.mjs';

const context = BACKGROUND_CONTEXT;
export const SESSION_NOT_FOUND = -32002;
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Every session keeps the SDK's stock SQLite tables in the one shared file, under
// its own table prefix: the SDK allows only one writer per storage, and each
// session runs in its own process.
const tablePrefix = sessionId => `s${sessionId.replaceAll('-', '').toLowerCase()}_`;
export const databasePath = dataDirectory => join(dataDirectory, 'pi-durable.sqlite');

function sessionExists(path, sessionId) {
  let database;
  try { database = new DatabaseSync(path, { readOnly: true }); }
  catch { return false; }
  try { return Boolean(database.prepare("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?").get(`${tablePrefix(sessionId)}conversations`)); }
  finally { database.close(); }
}

async function directory(value) {
  if (typeof value !== 'string' || !value.startsWith('/')) throw new AgentError('Give the session an absolute working directory.', -32602);
  try {
    const path = await realpath(value);
    if ((await stat(path)).isDirectory()) return path;
  } catch {}
  throw new AgentError(`The working directory ${value} is unavailable.`, -32602);
}

// AGENTS.md (or CLAUDE.md) from the working directory up to the file system root.
async function projectInstructions(cwd) {
  const found = [];
  for (let path = cwd; ; path = dirname(path)) {
    for (const name of ['AGENTS.md', 'CLAUDE.md']) {
      const text = await readFile(join(path, name), 'utf8').catch(() => undefined);
      if (text?.trim()) { found.unshift(text.trim()); break; }
    }
    if (dirname(path) === path) return found.join('\n\n');
  }
}

function promptContent(blocks = []) {
  const content = [];
  for (const block of blocks) {
    if (block.type === 'text') content.push({ type: 'text', text: block.text });
    else if (block.type === 'image' && block.data) content.push({ type: 'image', data: block.data, mimeType: block.mimeType });
    else if (block.type === 'resource' && typeof block.resource?.text === 'string') content.push({ type: 'text', text: `<file uri="${block.resource.uri}">\n${block.resource.text}\n</file>` });
    else if (block.type === 'resource_link') {
      const path = block.uri?.startsWith('file:') ? fileURLToPath(block.uri) : block.uri;
      content.push({ type: 'text', text: `Attached file: ${path}` });
    }
  }
  if (!content.length) throw new AgentError('The prompt is empty.', -32602);
  return content;
}

const usageTotals = state => {
  const total = { inputTokens: 0, outputTokens: 0, cachedReadTokens: 0, cachedWriteTokens: 0 };
  for (const usage of [...Object.values(state?.models ?? {}), ...Object.values(state?.tools ?? {})]) {
    total.inputTokens += usage.input ?? 0; total.outputTokens += usage.output ?? 0;
    total.cachedReadTokens += usage.cacheRead ?? 0; total.cachedWriteTokens += usage.cacheWrite ?? 0;
  }
  return total;
};

export class Session {
  static async open({ models, settings = {}, dataDirectory, sessionId, cwd, mcpServers, notify, create }) {
    const path = databasePath(dataDirectory);
    if (!create && (!uuid.test(sessionId ?? '') || !sessionExists(path, sessionId))) throw new AgentError('There is no Pi Durable session with that ID.', SESSION_NOT_FOUND);
    const root = await directory(cwd);
    const session = new Session(models, settings, sessionId, root, notify);
    await session.start(path, mcpServers ?? []);
    return session;
  }
  constructor(models, settings, sessionId, cwd, notify) {
    this.models = models; this.settings = settings; this.sessionId = sessionId; this.cwd = cwd;
    this.send = update => notify('session/update', { sessionId, update });
    this.busy = false;
  }
  async start(path, mcpServers) {
    this.mcp = await connectMcp(mcpServers, this.cwd);
    const instructions = await projectInstructions(this.cwd);
    const registry = createRegistry();
    registry.install(createCodingTools({ images: await createNodePhotonImages() }));
    registry.install(Workflow);
    registry.install(createSearch(this.models.credentials, this.settings.searchProvider));
    registry.install(Subagents);
    registry.install(this.mcp.extension);
    registry.install(defineExtension({ name: 'woven-context', sections: [
      section('environment', () => `Working directory: ${this.cwd}`, { tag: false }),
      section('woven', () => this.mcp.instructions.join('\n\n') || undefined, { tag: false }),
      section('project', () => instructions || undefined, { tag: false }),
    ] }));
    this.storage = await openNodeSqliteStorage(path, { prefix: tablePrefix(this.sessionId) });
    this.harness = await Harness.open(this.storage, {
      models: this.models.runtime, registry,
      env: target => new NodeExecutionEnv({ cwd: target.cwd ?? this.cwd }),
      settings: { toolExecution: 'parallel', compaction: { enabled: true } },
    }, context);
    this.conversation = await this.harness.root(context, { agent: { cwd: this.cwd } });
    const agent = await this.harness.snapshot(AgentDoc, this.conversation.id, context);
    if (agent?.cwd && agent.cwd !== this.cwd) await this.conversation.configure({ cwd: this.cwd }, context);
    this.projection = new Projection(this.send);
    this.projection.attach(await this.conversation.watch(context));
    // Work a crash or restart left unfinished continues now.
    this.harness.resume();
    void refreshCatalogs(this.models).then(async changed => {
      if (changed) await this.send({ sessionUpdate: 'config_option_update', configOptions: await this.configOptions() });
    }).catch(() => {});
  }
  async agentState() { return await this.harness.snapshot(AgentDoc, this.conversation.id, context) ?? {}; }
  async currentModel() {
    const { model } = await this.agentState();
    return model ? this.models.runtime.getModel(model.provider, model.modelId) : undefined;
  }
  async offered() { return offeredModels(await availableModels(this.models), this.settings); }
  // A new conversation starts on the settings' default model, else the first offered.
  async ensureModel() {
    if (await this.currentModel()) return;
    const [model] = await this.offered();
    if (model) await this.conversation.configure({ model: { provider: model.provider, modelId: model.id }, thinkingLevel: thinkingLevels(model).includes('medium') ? 'medium' : undefined }, context);
  }
  async configOptions() {
    await this.ensureModel();
    const available = await this.offered();
    const current = await this.currentModel();
    const { thinkingLevel } = await this.agentState();
    const options = available.map(model => ({ value: modelReference(model), name: model.name, description: this.models.runtime.getProvider(model.provider)?.name }));
    if (current && !options.some(option => option.value === modelReference(current))) options.unshift({ value: modelReference(current), name: current.name });
    const levels = thinkingLevels(current);
    return [
      { id: 'model', name: 'Model', category: 'model', type: 'select', currentValue: current ? modelReference(current) : null, options },
      ...(levels.length > 1 ? [{ id: 'thinking', name: 'Thinking', category: 'thought_level', type: 'select', currentValue: levels.includes(thinkingLevel) ? thinkingLevel : levels[0],
        options: levels.map(value => ({ value, name: value[0].toUpperCase() + value.slice(1) })) }] : []),
    ];
  }
  async setConfigOption(configId, value) {
    if (this.busy) throw new AgentError('Wait for the current response before changing options.');
    if (configId === 'model') {
      const slash = String(value).indexOf('/');
      const model = slash > 0 ? this.models.runtime.getModel(value.slice(0, slash), value.slice(slash + 1)) : undefined;
      if (!model) throw new AgentError('That model is not available.', -32602);
      const { thinkingLevel } = await this.agentState();
      const levels = thinkingLevels(model);
      await this.conversation.configure({ model: { provider: model.provider, modelId: model.id }, thinkingLevel: levels.includes(thinkingLevel) ? thinkingLevel : (levels.includes('medium') ? 'medium' : null) }, context);
    } else if (configId === 'thinking') {
      if (!thinkingLevels(await this.currentModel()).includes(value)) throw new AgentError('That thinking level is not available for this model.', -32602);
      await this.conversation.configure({ thinkingLevel: value }, context);
    } else throw new AgentError('Unknown option.', -32602);
    return this.configOptions();
  }
  async prompt(blocks) {
    if (this.busy) throw new AgentError('This session is already answering. Wait or cancel it first.');
    this.busy = true;
    try {
      const content = promptContent(blocks);
      await this.ensureModel();
      if (!await this.currentModel()) throw new AgentError('No model is available. Sign in to a provider or add an API key in Settings.');
      const before = usageTotals(await this.harness.snapshot(UsageDoc, this.conversation.id, context));
      const submission = await this.conversation.submit({ type: 'input', content, requestId: randomUUID(), whenBusy: 'reject' }, context);
      const settled = await submission.wait(context);
      if (settled.status === 'done') await this.projection.through(settled.answer);
      else await this.projection.through(-1, 0);
      const after = usageTotals(await this.harness.snapshot(UsageDoc, this.conversation.id, context));
      const usage = Object.fromEntries(Object.entries(after).map(([key, value]) => [key, value - before[key]]));
      if (settled.status === 'done') {
        const answer = (await this.conversation.commit(tx => tx.entry(AssistantEntry, settled.answer), context))?.model?.[0];
        const stopReason = answer?.stopReason === 'length' ? 'max_tokens' : answer?.rawStopReason === 'refusal' ? 'refusal' : 'end_turn';
        return { stopReason, usage, _meta: { model: answer ? `${answer.provider}/${answer.model}` : modelReference(await this.currentModel()) } };
      }
      if (settled.reason === 'aborted') return { stopReason: 'cancelled', usage, _meta: { model: modelReference(await this.currentModel()) } };
      const detail = typeof settled.detail === 'string' ? settled.detail : settled.detail?.message;
      throw new AgentError(humanMessage(detail ?? `The model did not answer (${settled.reason}).`));
    } finally { this.busy = false; }
  }
  async cancel() { await this.conversation.abort(context); }
  async close() {
    await this.harness?.close(context).catch(() => {});
    await this.mcp?.close();
  }
}
