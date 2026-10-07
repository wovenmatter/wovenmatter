import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createHash, randomUUID } from 'node:crypto';
import { BACKGROUND_CONTEXT } from '@earendil-works/chord/context';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { defineExtension } from '@earendil-works/pi-durable';
import { Type } from 'typebox';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { Subagents } from '../src/subagents.mjs';

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

test('native owner lock excludes a second runtime and released identities can reopen', async t => {
  const { engine, open } = await fixture(t);
  const record = await engine.create(), other = await open();
  await assert.rejects(other.create(record.session.sessionId), /already owned/);
  await record.session.dispose();
  const reopened = await other.create(record.session.sessionId);
  assert.equal(reopened.manifest.storeID, record.manifest.storeID);
  assert.equal(reopened.conversation.id, record.conversation.id);
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
  const result = await engine.handle('session/prompt', {
    sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Complete the attached work.' }],
    _meta: { wovenRunID: randomUUID(), wovenInputID: randomUUID() },
  });
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

test('failed native input receipts do not silently re-admit the same logical request', async t => {
  const { engine } = await fixture(t), record = await engine.create(); let calls = 0;
  record.streamFunction = model => { calls++; return stream(model, [], { stopReason: 'error', errorMessage: 'Fixture failure' }); };
  const params = { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Fail once' }], _meta: { wovenInputID: randomUUID() } };
  await assert.rejects(engine.handle('session/prompt', params));
  await assert.rejects(engine.handle('session/prompt', params));
  assert.equal(calls, 1);
  assert.equal(record.session.messages.filter(message => message.role === 'user').length, 1);
});

test('manual compaction task admission and its duplicate receipt are one native commit', async t => {
  const { engine } = await fixture(t), record = await engine.create();
  const params = { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: '/compact preserve paths' }], _meta: { wovenInputID: randomUUID() } };
  assert.equal((await engine.handle('session/prompt', params)).stopReason, 'end_turn');
  await engine.handle('session/prompt', params);
  const tasks = (await record.storage.scanTasks({}, 200, undefined, BACKGROUND_CONTEXT)).items.filter(task => task.kind === 'pi.compaction');
  assert.equal(tasks.length, 1);
  assert.equal(tasks[0].state.outcome.status, 'completed');
  const records = (await record.history()).recordBatch.records;
  const receipt = records.find(r => r.kind === 'woven.requests' && JSON.parse(r.payload).value.requests[params._meta.wovenInputID]?.compactionTaskID === tasks[0].id);
  const admission = records.find(r => r.kind === 'pi.compaction' && JSON.parse(r.payload).value.id === tasks[0].id);
  assert.equal(receipt.revision, admission.revision);
  await assert.rejects(engine.handle('session/prompt', { ...params, prompt: [{ type: 'text', text: '/compact changed' }] }), /different request/);
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
  const run = engine.prompt(record, 'Stop this command', update => { events.push(update); if (update.sessionUpdate === 'tool_call') started(); });
  await ready;
  const time = Date.now();
  await engine.handle('session/cancel', { sessionId: record.session.sessionId });
  assert.equal((await run).stopReason, 'cancelled');
  assert.ok(Date.now() - time < 2000);
  await assert.rejects(readFile(join(root, 'cancelled-marker')), { code: 'ENOENT' });
});

test('native CLI bindings advance when steering is consumed and preserve running shell snapshots', async t => {
  const { engine, root } = await fixture(t), record = await engine.create();
  const binding = captureID => ({ captureID, executablePath: join(root, 'bin', 'wovenmatter'), socketPath: join(root, 'woven.sock') });
  const environment = 'printf "%s|%s|%s|%s" "$WOVENMATTER_CONTEXT_ID" "$WOVENMATTER_CLI" "$WOVENMATTER_SOCKET" "$WOVENMATTER_NOTE_ID"';
  const params = (text, captureID) => ({ sessionId: record.session.sessionId, prompt: [{ type: 'text', text }], _meta: { wovenInputID: randomUUID(), ...(captureID ? { wovenTools: binding(captureID) } : {}) } });
  let calls = 0;
  record.streamFunction = model => stream(model, ++calls === 1
    ? [{ type: 'toolCall', id: 'first-shell', name: 'bash', arguments: { command: `${environment} > first-env; for ((i=0;i<500;i++)); do [ -f release-shell ] && break; sleep 0.01; done; ${environment} > first-finished-env` } }]
    : calls === 2 ? [{ type: 'toolCall', id: 'second-shell', name: 'codemode', arguments: { code: `return await tools.bash({command: ${JSON.stringify(`${environment} > second-env`)}});` } }]
      : [{ type: 'text', text: 'Done' }]);
  const first = engine.handle('session/prompt', params('First input', 'first'));
  const deadline = Date.now() + 5000;
  while (true) {
    try { await readFile(join(root, 'first-env')); break; }
    catch (error) { if (error.code !== 'ENOENT' || Date.now() >= deadline) throw error; await new Promise(resolve => setTimeout(resolve, 10)); }
  }
  assert.deepEqual(await engine.handle('_session/steering', params('Second input', 'second')), { outcome: 'injected' });
  assert.equal(record.cli.environment({}).WOVENMATTER_CONTEXT_ID, 'first');
  await writeFile(join(root, 'release-shell'), '');
  await first;
  const expected = captureID => `${captureID}|${binding(captureID).executablePath}|${binding(captureID).socketPath}|`;
  assert.equal(await readFile(join(root, 'first-env'), 'utf8'), expected('first'));
  assert.equal(await readFile(join(root, 'first-finished-env'), 'utf8'), expected('first'));
  assert.equal(await readFile(join(root, 'second-env'), 'utf8'), expected('second'));
  let next = 0;
  record.streamFunction = model => stream(model, ++next === 1 ? [{ type: 'toolCall', id: 'unbound-shell', name: 'bash', arguments: { command: `${environment} > unbound-env` } }] : [{ type: 'text', text: 'Done' }]);
  await engine.handle('session/prompt', params('An unbound input'));
  assert.equal(await readFile(join(root, 'unbound-env'), 'utf8'), '|||');
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
