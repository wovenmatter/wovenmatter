import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { createServer } from 'node:http';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { defineExtension, defineTask } from '@earendil-works/pi-durable';
import { Type } from 'typebox';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { ChildContext, Subagents } from '../src/subagents.mjs';
import { checklistTool } from '../src/checklist.mjs';
















function stream(model, content, overrides = {}) {
  const result = { role: 'assistant', content, api: model.api, provider: model.provider, model: model.id, timestamp: Date.now(), stopReason: content.some(c => c.type === 'toolCall') ? 'toolUse' : 'stop', usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } }, ...overrides };
  const value = createAssistantMessageEventStream(); value.push({ type: 'start', partial: result }); value.push(result.stopReason === 'error' ? { type: 'error', reason: 'error', error: result } : { type: 'done', reason: result.stopReason, message: result }); value.end(result); return value;
}
async function fixture(t, options = {}) {
  const root = await mkdtemp(join(tmpdir(), 'woven-durable-engine-'));
  const claude = { models: [{ value: 'sonnet', displayName: 'Fixture', supportedEffortLevels: ['low', 'medium', 'high'] }], loadModels: async () => {}, status: async () => ({ connected: true }), sdkQuery: async () => { throw Error('Provider use forbidden.'); } };
  const config = { providers: ['claude-subscription'], defaultModel: 'claude-subscription/sonnet' };
  const engines = [];
  const open = async () => {
    const engine = await new DefaultAgentEngine({ cwd: root, directory: root, claude, config, ...options }).initialize(), create = engine.create.bind(engine);
    engine.create = async (...args) => { const record = await create(...args); record.nativeBridge.prepare = async messages => ({ messages }); record.nativeBridge.beforeCompact = async () => undefined; return record; };
    engines.push(engine); return engine;
  };
  t.after(async () => { for (const engine of engines) for (const record of [...engine.sessions.values()]) await record.session.dispose(); await rm(root, { recursive: true, force: true }); });
  return { root, open, engine: await open() };
}

test('an existing Durable conversation uses the current search provider and rotated key between turns', async t => {
  const requests = [];
  t.mock.method(globalThis, 'fetch', async (url, options) => {
    requests.push({ url, ...options });
    const source = { title: 'Fixture source', url: 'https://example.com/source' };
    return { ok: true, json: async () => ({ results: [{ ...source, text: 'Exa fixture' }],
      grounding: { generic: [{ ...source, snippets: ['Brave fixture'] }] },
      success: true, data: { web: [{ ...source, markdown: 'Firecrawl fixture' }] } }) };
  });
  const { engine } = await fixture(t);
  const record = await engine.create();
  for (const [index, provider] of ['exa', 'brave', 'firecrawl', 'brave'].entries()) {
    await engine.apply({ config: { ...engine.config, searchProvider: provider },
      credentials: { [provider]: { type: 'api_key', key: `${provider}-fixture-${index}` } } });
    let calls = 0;
    record.streamFunction = model => stream(model, ++calls === 1
      ? [{ type: 'toolCall', id: `search-${index}`, name: 'web_search', arguments: { query: 'Fixture question' } }]
      : [{ type: 'text', text: 'Searched' }]);
    assert.equal((await engine.prompt(record, 'Search the fixture', () => {})).stopReason, 'end_turn');
    const result = record.session.messages.find(message => message.role === 'toolResult' && message.toolCallId === `search-${index}`);
    assert.equal(result?.isError, false);
    assert.equal(JSON.parse(result.content[0].text).results[0].url, 'https://example.com/source');
    const request = requests.at(-1);
    assert.equal(request.headers[provider === 'exa' ? 'x-api-key' : provider === 'brave' ? 'X-Subscription-Token' : 'Authorization'],
      `${provider === 'firecrawl' ? 'Bearer ' : ''}${provider}-fixture-${index}`);
  }
  assert.equal(requests.length, 4);
});

test('native owner lock excludes a second runtime and released identities can reopen', async t => {
  const { engine, open } = await fixture(t);
  const record = await engine.create(), other = await open();
  await engine.select(record, 'high', 'thinking');
  await engine.select(record, 'full', 'permission_mode');
  await assert.rejects(other.create(record.session.sessionId), /already owned/);
  await record.session.dispose();
  const reopened = await other.create(record.session.sessionId);
  assert.equal(reopened.manifest.storeID, record.manifest.storeID);
  assert.equal(reopened.conversation.id, record.conversation.id);
  assert.equal(reopened.selected, 'claude-subscription/sonnet');
  assert.equal(reopened.session.thinkingLevel, 'high');
  assert.equal(reopened.permission, 'full');
});

for (const scope of ['root', 'child']) test(`a sleeping ${scope} task keeps its execution group owned until it is aborted`, { timeout: 10000 }, async t => {
  const { engine } = await fixture(t), record = await engine.create();
  const conversation = scope === 'root' ? record.conversation
    : await record.harness.createConversation({ ownership: { kind: 'ownerless' } }, BACKGROUND_CONTEXT);
  // No live anchor or reporter can mask a missing sleeping-task scan.
  if (scope === 'child') await record.harness.commit(async tx => {
    const group = await tx.doc(Subagents, record.conversation.id);
    group.children.sleeper = { conversationId: conversation.id, anchorID: randomUUID(), reporterIDs: [], stopEpoch: 0 };
  }, BACKGROUND_CONTEXT);
  const sleeper = defineTask({ name: 'fixture.sleeping', version: 1, initial: () => ({ phase: 'wait' }), phases: {
    wait: (_task, runtime, context) => runtime.sleepUntil(runtime.now() + 60000, { phase: 'done' }, context),
    done: (_task, runtime, context) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'completed', result: null } }), context),
  }, abort: (_task, runtime, context) => runtime.commit(() => ({ status: 'terminal', outcome: { status: 'aborted' } }), context) });
  record.registry.install(defineExtension({ name: 'sleeping-fixture', tasks: [sleeper] }));
  const id = await record.harness.commit(tx => tx.createTask(sleeper, null, {
    conversationId: conversation.id, ownership: { kind: 'conversation' },
  }), BACKGROUND_CONTEXT);
  const deadline = Date.now() + 3000;
  let task;
  do {
    task = await record.harness.commit(tx => tx.task(id), BACKGROUND_CONTEXT);
    if (task.state.status === 'sleeping') break;
    await new Promise(resolve => setTimeout(resolve, 10));
  } while (Date.now() < deadline);
  assert.equal(task.state.status, 'sleeping');
  await assert.rejects(record.subagents.beginGroup(randomUUID()), scope === 'root' ? /previous native run is still active/ : /previous attached run is still active/);
  await conversation.abort(BACKGROUND_CONTEXT);
  await record.subagents.beginGroup(randomUUID());
});

test('stable logical input receipts survive account reorder and conflicting payloads are rejected', async t => {
  const accounts = ['first', 'second'].map(id => ({ id, label: id, credential: { type: 'native', accountId: id } }));
  const { engine } = await fixture(t, { credentials: { 'claude-subscription': accounts[0].credential }, credentialAccounts: { 'claude-subscription': accounts } });
  const record = await engine.create(); let calls = 0;
  record.streamFunction = model => { calls++; return stream(model, [{ type: 'text', text: 'Once' }]); };
  const params = { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Original' }], _meta: { wovenInputID: randomUUID(), wovenRunID: randomUUID() } };
  const completed = await engine.handle('session/prompt', params);
  assert.equal(completed.stopReason, 'end_turn');
  await engine.apply({ credentials: { 'claude-subscription': accounts[1].credential }, credentialAccounts: { 'claude-subscription': accounts.toReversed() } });
  await engine.handle('session/prompt', params);
  assert.equal(calls, 1);
  assert.equal(record.session.messages.filter(m => m.role === 'user').length, 1);
  await record.conversation.reset(undefined, BACKGROUND_CONTEXT);
  await engine.handle('session/prompt', params); // The answer is outside the current context; its native receipt still deduplicates.
  assert.equal(calls, 1);
  await assert.rejects(engine.handle('session/prompt', { ...params, prompt: [{ type: 'text', text: 'Changed' }] }), /different request/);
});

test('native messages and exposed thinking reach display and the live archive without credential transport', async t => {
  const { engine, open } = await fixture(t, { credentials: { openai: { type: 'api_key', key: 'credential-sentinel-not-history' } } });
  const record = await engine.create(), events = [], runID = randomUUID();
  record.streamFunction = model => stream(model, [{ type: 'thinking', thinking: 'Exposed summary' }, { type: 'text', text: 'Visible reply' }]);
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Hello' }], _meta: { wovenInputID: randomUUID(), wovenRunID: runID } }, value => events.push(value));
  assert.equal(events.filter(e => e.sessionUpdate === 'agent_message_chunk').map(e => e.content.text).join(''), 'Visible reply');
  assert.equal(events.filter(e => e.sessionUpdate === 'agent_thought_chunk').map(e => e.content.text).join(''), 'Exposed summary');
  const page = await record.history(0, 200);
  assert.equal(page.recordBatch.schemaVersion, 1);
  assert.ok(page.recordBatch.records.some(r => r.runID === runID && r.text?.includes('Visible reply')));
  assert.ok(!JSON.stringify(page).includes('credential-sentinel-not-history'));
  const source = page.recordBatch.sourceID;
  const captured = page.recordBatch.records.find(r => r.projectionJSON?.includes('Visible reply'));
  assert.equal(JSON.parse(captured.payload).type, 'entry');
  assert.equal(JSON.parse(captured.projectionJSON).content[0].content[0].thinking, 'Exposed summary');
  await record.session.dispose();
  const second = await open(), reopened = await second.create(record.session.sessionId);
  const again = await reopened.history(0, 200);
  assert.equal(again.recordBatch.sourceID, source);
  assert.notEqual(reopened.archivePath, record.archivePath);
  assert.ok(!again.recordBatch.records.some(r => r.text?.includes('Visible reply')));
  assert.ok(reopened.session.messages.some(m => Array.isArray(m.content) && m.content.some(b => b.text === 'Visible reply')));
  let generation = 0; const interleaved = [];
  reopened.streamFunction = model => {
    const content = [{ type: 'thinking', thinking: '' }, { type: 'text', text: '' }], first = ++generation === 1;
    if (first) content.push({ type: 'toolCall', id: 'thought-step', name: 'ls', arguments: { path: reopened.cwd } });
    const value = createAssistantMessageEventStream();
    void (async () => {
      const message = await stream(model, content).result(); value.push({ type: 'start', partial: structuredClone(message) });
      for (const [index, text] of first ? [[0, 'Reason'], [1, 'Prefix'], [0, ' more']] : [[0, 'Next tool step'], [1, 'Final']]) {
        const field = index === 0 ? 'thinking' : 'text'; message.content[index][field] += text;
        value.push({ type: `${field}_delta`, contentIndex: index, delta: text, partial: structuredClone(message) });
        await new Promise(resolve => setTimeout(resolve, 150)); // Durable publishes partials every 100 ms.
      }
      value.push({ type: 'done', reason: message.stopReason, message }); value.end(message);
    })();
    return value;
  };
  await second.prompt(reopened, 'Keep thinking identity through a tool step', update => interleaved.push(update));
  const thoughts = interleaved.filter(update => update.sessionUpdate === 'agent_thought_chunk');
  assert.equal(thoughts.map(update => update.content.text).join(''), 'Reason moreNext tool step');
  assert.equal(thoughts[0]._meta.wovenThoughtID, thoughts[1]._meta.wovenThoughtID);
  assert.notEqual(thoughts[0]._meta.wovenThoughtID, thoughts.at(-1)._meta.wovenThoughtID);
});

test('Stop cancels native bash children before uncertain effects can run', async t => {
  const { engine, root } = await fixture(t);
  const record = await engine.create(), events = [];
  let started; const ready = new Promise(resolve => { started = resolve; });
  record.streamFunction = model => stream(model, [{ type: 'toolCall', id: 'slow-bash', name: 'bash', arguments: { command: 'sleep 3; touch cancelled-marker' } }]);
  const run = engine.prompt(record, 'Stop this command', update => { events.push(update); if (update.sessionUpdate === 'tool_call') started(); }, undefined, { runID: randomUUID(), inputID: randomUUID() });
  await ready;
  const time = Date.now();
  await engine.handle('session/cancel', { sessionId: record.session.sessionId });
  assert.equal((await run).stopReason, 'cancelled');
  assert.ok(Date.now() - time < 2000);
  await assert.rejects(readFile(join(root, 'cancelled-marker')), { code: 'ENOENT' });
  const statuses = events.filter(update => update.sessionUpdate === 'woven_program_status' && !update.status.id);
  assert.equal(statuses.at(-1).status.state, 'idle');
  assert.ok(!statuses.some(update => update.status.state === 'done'));
});

test('native snapshots preserve Unicode, block removal, thoughts and prior assistant boundaries', { timeout: 10000 }, async t => {
  const { engine } = await fixture(t), record = await engine.create();
  const updates = [], replacement = '🧵'.repeat(20000), prefix = 'Before tool.'.repeat(4000);
  let calls = 0, releasePartial;
  const partialSeen = new Promise(resolve => { releasePartial = resolve; });
  record.streamFunction = model => {
    if (++calls === 1) return stream(model, [{ type: 'text', text: prefix }, { type: 'toolCall', id: 'list', name: 'ls', arguments: {} }]);
    const events = createAssistantMessageEventStream();
    void (async () => {
      const partial = await stream(model, [{ type: 'thinking', thinking: 'old thought' }, { type: 'text', text: 'old ' }, { type: 'text', text: 'removed' }]).result();
      events.push({ type: 'start', partial });
      await partialSeen;
      const message = { ...partial, content: [{ type: 'thinking', thinking: replacement }, { type: 'text', text: replacement }] };
      events.push({ type: 'done', reason: 'stop', message }); events.end(message);
    })();
    return events;
  };
  await engine.prompt(record, 'Fixture block replacement', update => {
    updates.push(update);
    if (update.sessionUpdate === 'agent_message_chunk' && update.content.text === 'old removed') releasePartial();
  });
  let displayed = '';
  const thoughts = new Map(), boundaries = [];
  const pending = new Map();
  for (const update of updates) {
    let content = update.content?.text;
    if (update._meta?.wovenAssistantSnapshot || update._meta?.wovenThoughtSnapshot) {
      const id = update._meta.wovenThoughtID ?? 'assistant';
      if (update._meta.wovenSnapshotStart) pending.set(id, '');
      assert.ok(pending.has(id));
      pending.set(id, pending.get(id) + content);
      if (!update._meta.wovenSnapshotEnd) continue;
      content = pending.get(id); pending.delete(id);
    }
    if (update.sessionUpdate === 'agent_message_chunk') {
      if (update._meta?.wovenAssistantSnapshot) {
        assert.ok(content.startsWith(prefix)); // The full steering prefix survives chunking.
        displayed = content;
      } else displayed += content;
    }
    if (update.sessionUpdate === 'agent_thought_chunk') {
      const id = update._meta.wovenThoughtID;
      thoughts.set(id, update._meta.wovenThoughtSnapshot ? content : (thoughts.get(id) ?? '') + content);
    }
    if (update.sessionUpdate === 'woven_assistant_boundary') boundaries.push(displayed);
  }
  assert.equal(pending.size, 0);
  assert.deepEqual(boundaries, [prefix, prefix + replacement]);
  assert.deepEqual([...thoughts.values()], [replacement]);
  assert.equal(updates.filter(update => update._meta?.wovenAssistantSnapshot && update._meta.wovenSnapshotEnd).length, 1);
  assert.equal(updates.filter(update => update._meta?.wovenThoughtSnapshot && update._meta.wovenSnapshotEnd).length, 1);
  record.streamFunction = model => stream(model, [{ type: 'text', text: '' }]);
  const next = [];
  await engine.prompt(record, 'New prompt', update => next.push(update));
  assert.equal(next.filter(update => update.sessionUpdate === 'agent_message_chunk').length, 0);
});

test('native tool output is persisted and copied in byte-bounded exact chunks', async t => {
  const { engine, open } = await fixture(t);
  const record = await engine.create(), content = 'r'.repeat(67108880);
  let calls = 0, executions = 0;
  const tool = { name: 'giant_fixture', description: 'Provider-free large native tool result fixture', parameters: Type.Object({}), replay: 'unsafe', execute: async () => { executions++; return { content: [], details: { runContent: content } }; } };
  record.registry.install(defineExtension({ name: 'giant-fixture', tools: [tool] }));
  await record.conversation.configure({ tools: [tool] }, BACKGROUND_CONTEXT);
  // Keep this temporary fixture tool selected when Woven normalizes its normal
  // tool catalog; execution, persistence and reopening still use real SDK APIs.
  record.session.setActiveToolsByName = () => {};
  record.streamFunction = model => stream(model, ++calls === 1 ? [{ type: 'toolCall', id: 'giant-native-output', name: tool.name, arguments: {} }] : [{ type: 'text', text: 'Large output saved' }]);
  await engine.handle('session/prompt', { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Create a giant output' }], _meta: { wovenInputID: randomUUID(), wovenRunID: randomUUID() } });
  const native = (await record.storage.scanEntries({ conversationId: record.conversation.id }, 200, undefined, BACKGROUND_CONTEXT)).items.find(entry => entry.model?.some(message => message.role === 'toolResult' && message.toolName === tool.name));
  assert.equal(executions, 1); assert.equal(native.model[0].details.runContent.length, content.length);
  await record.archiveQueue;
  const identities = new Set(), chunks = new Map(), copies = new Map(); let cursor = 0, page, sawOpaque = false, manifests = 0;
  do {
    page = await record.history(cursor, 200);
    assert.ok(Buffer.byteLength(JSON.stringify(page.recordBatch)) <= 1.1 * 1024 * 1024);
    for (const item of page.recordBatch.records) {
      if (item.kind === 'native-file.chunk') { identities.add(item.id); chunks.set(item.id, Buffer.from(JSON.parse(item.payload).dataBase64, 'base64')); }
      else if (item.kind === 'native-file.manifest') {
        manifests++; const manifest = JSON.parse(item.payload);
        if (!copies.has(manifest.sha256)) copies.set(manifest.sha256, { totalBytes: manifest.totalBytes, parts: [] });
        copies.get(manifest.sha256).parts.push(...manifest.parts);
      }
    }
    cursor = page.nextAfter; sawOpaque ||= typeof cursor === 'object';
  } while (page.hasMore);
  assert.equal(sawOpaque, true); assert.ok(manifests >= 1); assert.ok(identities.size > 2);
  for (const [checksum, copy] of copies) {
    const hash = createHash('sha256'); let offset = 0;
    for (const part of copy.parts.sort((a, b) => a.byteOffset - b.byteOffset)) { assert.equal(part.byteOffset, offset); const bytes = chunks.get(part.chunkID); assert.equal(bytes.length, part.byteCount); hash.update(bytes); offset += part.byteCount; }
    assert.equal(offset, copy.totalBytes); assert.equal(hash.digest('hex'), checksum);
  }
  const id = record.session.sessionId; await record.session.dispose();
  const second = await open(), restored = await second.create(id);
  assert.equal((await restored.storage.entry(native.id, BACKGROUND_CONTEXT)).entry.model[0].details.runContent.length, content.length);
  restored.streamFunction = model => stream(model, [{ type: 'text', text: 'Continued safely' }]);
  const result = await second.handle('session/prompt', { sessionId: id, prompt: [{ type: 'text', text: 'Continue' }], _meta: { wovenInputID: randomUUID(), wovenRunID: randomUUID() } });
  assert.equal(result.stopReason, 'end_turn');
  assert.ok(restored.session.messages.some(m => Array.isArray(m.content) && m.content.some(b => b.text === 'Continued safely')));
});

test('attached completion includes child reports and children spawned during parent follow-up', { timeout: 15000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-attached-engine-'));
  const engine = await new DefaultAgentEngine({ cwd: root, directory: root,
    config: { providers: ['openai'], defaultModel: 'openai/gpt-4.1' },
    credentials: { openai: { type: 'api_key', key: 'fixture-only' } },
  }).initialize();
  t.after(async () => {
    for (const record of [...engine.sessions.values()]) await record.session.dispose();
    await rm(root, { recursive: true, force: true });
  });
  engine.publishProviderModels('openai', [{ id: 'gpt-4.1', name: 'Offline fixture', provider: 'openai', api: 'openai-responses', baseUrl: 'https://api.openai.com/v1', contextWindow: 16384, maxTokens: 4096, reasoning: false, input: ['text'], cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 } }]);
  const record = await engine.create();
  let parentCalls = 0, childCalls = 0;
  engine.runtime.streamSimple = (model, _input, options) => {
    if (options.wovenNativeContext.sessionID !== record.session.sessionId) {
      childCalls++;
      return stream(model, [{ type: 'text', text: `Child result ${childCalls}` }]);
    }
    parentCalls++;
    const name = parentCalls === 1 ? 'first' : parentCalls === 3 ? 'followup' : undefined;
    return stream(model, name
      ? [{ type: 'toolCall', id: name, name: 'subagent', arguments: { action: 'spawn', name, task: 'Return a short result.' } }]
      : [{ type: 'text', text: `Parent response ${parentCalls}` }]);
  };
  const updates = [], runID = randomUUID();
  const result = await engine.handle('session/prompt', {
    sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Complete the attached work.' }],
    _meta: { wovenRunID: runID, wovenInputID: randomUUID() },
  }, update => updates.push(update));
  assert.equal(result.stopReason, 'end_turn');
  assert.equal(childCalls, 2);
  assert.equal(parentCalls, 5);
  assert.equal(record.session.messages.at(-1).content[0].text, 'Parent response 5');
  const group = await record.harness.snapshot(Subagents, record.conversation.id, BACKGROUND_CONTEXT);
  for (const child of Object.values(group.children)) {
    assert.equal(child.reporterIDs.length, 1);
    const conversation = await record.harness.conversation(child.conversationId, BACKGROUND_CONTEXT);
    assert.ok(!(await conversation.agent(BACKGROUND_CONTEXT)).tools.some(tool => tool.name === 'subagent'));
  }
  const inspection = await record.harness.inspect(BACKGROUND_CONTEXT);
  assert.equal(inspection.tasks.length, 0);
  assert.equal(inspection.submissions.length, 0);
  const statuses = updates.filter(update => update.sessionUpdate === 'woven_program_status');
  assert.ok(statuses.every(update => update._meta.wovenRunID === runID));
  assert.deepEqual(statuses.filter(update => !update.status.id).slice(0, 2).map(update => update.status.state), ['clear', 'working']);
  assert.equal(statuses.at(-1).status.state, 'done');
  assert.equal(statuses.at(-1).status.id, undefined);
  assert.ok(statuses.some(update => /^children\/\d+$/.test(update.status.id) && update.status.state === 'working'));
  assert.equal(statuses.filter(update => !update.status.id && update.status.state === 'done').length, 1);
});

test('native child checklist records stay in native capture without becoming root progress', async t => {
  const { engine } = await fixture(t), record = await engine.create(), updates = [];
  const unsubscribe = record.subscribe(value => { if (value.update) updates.push(value.update); });
  t.after(unsubscribe);
  // An inert native child transcript, with no input, worker or provider call.
  const child = await record.harness.createConversation({ ownership: { kind: 'ownerless' }, init: async (tx, id) => {
    Object.assign(await tx.doc(ChildContext, id), { parentConversationID: record.conversation.id, sessionID: randomUUID(), runID: randomUUID() });
  } }, BACKGROUND_CONTEXT);
  await child.commit(tx => tx.appendEntry(child.id, { kind: 'pi.tool', model: [{
    role: 'toolResult', toolCallId: 'child-checklist', toolName: checklistTool.name, isError: false,
    content: [{ type: 'text', text: 'child-only-checklist' }], details: { wovenChecklist: [{ id: 'child', content: 'Child work', status: 'completed' }] }, timestamp: Date.now(),
  }], edits: [] }), BACKGROUND_CONTEXT);
  await record.archiveQueue;
  assert.equal(updates.filter(update => update.sessionUpdate === 'plan').length, 0);
  const archived = (await record.history()).recordBatch.records.find(item => item.text === 'child-only-checklist');
  assert.ok(archived);
  assert.equal(JSON.parse(archived.projectionJSON).parentNativeConversationID, record.conversation.id);
  assert.equal(JSON.parse(archived.projectionJSON).childID, String(child.id));
});

test('Durable invokes discovered Woven MCP tools without shell access and pins consumed input through steering', async t => {
  let releaseFirst;
  const released = new Promise(resolve => { releaseFirst = resolve; });
  const observed = [];
  const server = createServer(async (request, response) => {
    assert.equal(request.headers.authorization, 'Bearer native-fixture-token');
    if (request.method !== 'POST') { response.writeHead(405).end(); return; }
    let text = ''; for await (const bytes of request) text += bytes;
    const packet = JSON.parse(text);
    if (packet.id === undefined) { response.writeHead(202).end(); return; }
    let result;
    if (packet.method === 'initialize') result = { protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'Fixture', version: '1' } };
    else if (packet.method === 'tools/list') result = { tools: [{ name: 'woven_notes_read', description: 'Read a note.', inputSchema: { type: 'object', properties: { noteID: { type: 'string' }, requestID: { type: 'string' } }, required: ['noteID'] }, annotations: { readOnlyHint: true } }] };
    else if (packet.method === 'tools/call') {
      observed.push({ captureID: packet.params._meta.wovenContextID, noteID: packet.params.arguments.noteID });
      if (observed.length === 1) await released;
      result = { content: [{ type: 'text', text: packet.params._meta.wovenContextID }], structuredContent: { captureID: packet.params._meta.wovenContextID } };
    } else { response.writeHead(405).end(); return; }
    response.writeHead(200, { 'content-type': 'application/json' }); response.end(JSON.stringify({ jsonrpc: '2.0', id: packet.id, result }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { releaseFirst(); server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const { engine } = await fixture(t), record = await engine.create();
  const binding = captureID => ({ endpointURL: `http://127.0.0.1:${server.address().port}/mcp`, bearerToken: 'native-fixture-token', captureID });
  const params = (text, captureID) => ({ sessionId: record.session.sessionId, prompt: [{ type: 'text', text }], _meta: { wovenInputID: randomUUID(), wovenMCP: binding(captureID) } });
  let calls = 0;
  record.streamFunction = model => stream(model, ++calls <= 2
    ? [{ type: 'toolCall', id: `mcp-${calls}`, name: calls === 1 ? 'woven_notes_read' : 'codemode', arguments: calls === 1 ? { noteID: 'first-note' } : { code: 'return await tools.woven_notes_read({noteID:"second-note"});' } }]
    : [{ type: 'text', text: 'Done' }]);
  const first = engine.handle('session/prompt', params('First', 'first-input'));
  const deadline = Date.now() + 5000;
  while (!observed.length) { assert.ok(Date.now() < deadline); await new Promise(resolve => setTimeout(resolve, 10)); }
  assert.deepEqual(await engine.handle('_session/steering', params('Second', 'second-input')), { outcome: 'injected' });
  assert.equal(record.mcp.connection().captureID, 'first-input');
  releaseFirst(); await first;
  assert.deepEqual(observed, [{ captureID: 'first-input', noteID: 'first-note' }, { captureID: 'second-input', noteID: 'second-note' }]);
  assert.equal(record.session.messages.find(message => message.role === 'toolResult' && message.toolCallId === 'mcp-1').isError, false);
  const archive = JSON.stringify((await record.history()).recordBatch);
  assert.ok(!archive.includes('native-fixture-token'));
  await engine.apply({ config: { ...engine.config, codeMode: 'off' } });
  calls = 0;
  record.streamFunction = model => stream(model, ++calls === 1
    ? [{ type: 'toolCall', id: 'subagent-after-discovery', name: 'subagent', arguments: { action: 'status' } }]
    : [{ type: 'text', text: 'Subagents available' }]);
  await engine.handle('session/prompt', params('Inspect child work', 'third-input'));
  assert.equal(record.session.messages.find(message => message.role === 'toolResult' && message.toolCallId === 'subagent-after-discovery').isError, false);
  const active = (await record.conversation.agent(BACKGROUND_CONTEXT)).tools.map(tool => tool.name);
  assert.ok(active.includes('subagent') && active.includes('woven_notes_read'));
  assert.ok(!active.includes('codemode'));
  assert.ok(record.registry.snapshot().tools().find(entry => entry.tool.name === 'codemode').tool.description.includes('For parent conversations only, subagent:'));
});

test('client adoption inspects native idle state without resuming unfinished work',async t=>{
  const {engine}=await fixture(t),record=await engine.create(),sessionId=record.session.sessionId
  record.busy=true
  await assert.rejects(engine.handle('woven/adopt',{sessionId}),/still executing/)
  record.busy=false
  const inspect=record.harness.inspect.bind(record.harness)
  record.harness.inspect=async()=>({tasks:[{id:'unfinished'}],submissions:[]})
  await assert.rejects(engine.handle('woven/adopt',{sessionId}),/unfinished native work/)
  record.harness.inspect=inspect
  const adopted=await engine.handle('woven/adopt',{sessionId})
  assert.equal(adopted.sessionId,sessionId)
  assert.equal(record.session.messages.length,0)
})

for (const codeMode of ['off', 'only']) test(`native checklist is registered and successful (${codeMode})`, { timeout: 15000 }, async t => {
  const { engine } = await fixture(t, { config: { providers: ['claude-subscription'], defaultModel: 'claude-subscription/sonnet', codeMode } });
  const record = await engine.create(), updates = [];
  const todos = [{ id: 'a', content: 'Same label', status: 'in_progress' }, { id: 'b', content: 'Same label', status: 'cancelled' }];
  const writes = [todos, [todos[0], todos[0]], [{ ...todos[0], status: 'completed' }], []];
  let calls = 0;
  record.streamFunction = model => {
    const index = calls++;
    if (index === writes.length) return stream(model, [{ type: 'text', text: 'Done' }]);
    const args = { todos: writes[index] };
    return stream(model, [{ type: 'toolCall', id: `write-${index}`,
      name: codeMode === 'only' ? 'codemode' : checklistTool.name,
      arguments: codeMode === 'only' ? { code: `return await tools.update_checklist(${JSON.stringify(args)});` } : args }]);
  };
  await engine.prompt(record, 'Track work', update => updates.push(update));
  const plans = updates.filter(update => update.sessionUpdate === 'plan');
  assert.equal(plans.length, 3); // The failed duplicate-ID tool cannot mutate progress.
  assert.deepEqual(plans[0].entries, todos);
  assert.deepEqual(plans[1].entries, [{ ...todos[0], status: 'completed' }]);
  assert.deepEqual(plans[2].entries, []);
  assert.equal(plans[2]._meta.wovenPlanOperation, 'clear');
  const results = updates.filter(update => update.sessionUpdate === 'tool_call_update' && ['completed', 'failed'].includes(update.status));
  assert.ok(results.some(update => update.status === 'failed'));
  assert.ok(results.length >= 4);
  for (const plan of plans) assert.ok(updates.slice(0, updates.indexOf(plan)).some(update => update.sessionUpdate === 'tool_call_update'));
  let cursor = 0, archived = [];
  while (true) { const page = await record.history(cursor); archived.push(...page.recordBatch.records); if (!page.hasMore) break; cursor = page.nextAfter; }
  // Codemode hides nested entries from model context; their complete native
  // tool results must still be retained in the archive.
  const messages = archived.map(item => JSON.parse(item.payload)).filter(item => item.type === 'entry')
    .flatMap(item => item.value.model ?? []).filter(message => message.role === 'toolResult' && message.toolName === checklistTool.name);
  assert.equal(messages.filter(message => !message.isError).length, 3);
  const next = [];
  record.streamFunction = model => stream(model, [{ type: 'text', text: 'New task' }]);
  await engine.prompt(record, 'Fresh task', update => next.push(update));
  assert.equal(next.filter(update => update.sessionUpdate === 'plan').length, 0);
});

test('a restored native child uses refreshed MCP credentials with its durable original capture', async t => {
  const calls = [];
  const server = createServer(async (request, response) => {
    if (request.method !== 'POST') { response.writeHead(405).end(); return; }
    let body = ''; for await (const bytes of request) body += bytes;
    const packet = JSON.parse(body);
    if (packet.id === undefined) { response.writeHead(202).end(); return; }
    let result;
    if (packet.method === 'initialize') result = { protocolVersion: '2025-11-25', capabilities: { tools: {} }, serverInfo: { name: 'Fixture', version: '1' } };
    else if (packet.method === 'tools/list') result = { tools: [{ name: 'woven_context', inputSchema: { type: 'object', properties: { requestID: { type: 'string' } } }, annotations: { readOnlyHint: true } }] };
    else if (packet.method === 'tools/call') {
      calls.push({ authorization: request.headers.authorization, captureID: packet.params._meta.wovenContextID });
      result = { content: [{ type: 'text', text: packet.params._meta.wovenContextID }] };
    } else { response.writeHead(405).end(); return; }
    response.writeHead(200, { 'content-type': 'application/json' }); response.end(JSON.stringify({ jsonrpc: '2.0', id: packet.id, result }));
  });
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const { engine, open } = await fixture(t);
  const record = await engine.create();
  const connection = { endpointURL: `http://127.0.0.1:${server.address().port}/mcp`, bearerToken: 'original-token', sessionID: 'original-app-session' };
  record.mcp.reconnect(connection);
  record.mcp.enqueue({ ...connection, captureID: 'original-input-capture' }); record.mcp.consumed();
  const child = await record.harness.createConversation({ ownership: { kind: 'ownerless' }, init: async (tx, id) => {
    Object.assign(await tx.doc(ChildContext, id), { parentConversationID: record.conversation.id, sessionID: randomUUID(),
      provider: record.session.model.provider, modelId: record.session.model.id, selectedModel: record.session.model,
      accountID: 'fixture-account', mcpOrigin: record.mcp.origin() });
  } }, BACKGROUND_CONTEXT);
  const id = record.session.sessionId;
  await record.session.dispose();
  const restoredEngine = await open();
  const restored = await restoredEngine.create(id, undefined, { ...connection, bearerToken: 'renewed-token' });
  restored.mcp.enqueue({ ...connection, bearerToken: 'renewed-token', captureID: 'later-parent-input' }); restored.mcp.consumed();
  const tool = restored.registry.snapshot().tools().find(entry => entry.tool.name === 'woven_context').tool;
  const api = { conversationId: child.id, callId: 'restored-child-tool', output() {}, details: async () => {} };
  const result = await tool.execute({}, api, { abortSignal: new AbortController().signal });
  assert.equal(result.isError, false);
  assert.deepEqual(calls, [{ authorization: 'Bearer renewed-token', captureID: 'original-input-capture' }]);
  const saved = await restored.harness.snapshot(ChildContext, child.id, BACKGROUND_CONTEXT);
  assert.deepEqual(saved.mcpOrigin, { captureID: 'original-input-capture', sessionID: 'original-app-session' });
  assert.ok(!JSON.stringify(saved).includes('original-token'));
  assert.ok(!JSON.stringify(saved).includes('renewed-token'));
  restored.mcp.reconnect({ ...connection, sessionID: 'foreign-app-session', bearerToken: 'foreign-token' });
  await assert.rejects(tool.execute({}, api, { abortSignal: new AbortController().signal }), /originating Woven session is unavailable/);
  assert.equal(calls.length, 1);
});
