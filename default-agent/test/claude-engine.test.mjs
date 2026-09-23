import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, realpath, rm, readFile, access } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { ClaudeRuntime } from '../src/claude-runtime.mjs';
import { createDefaultAgentService } from '../src/service.mjs';
import { PermissionRequests, RemotePermissionRequests } from '../src/permissions.mjs';

async function fixture(t, { credentials = {}, config = {}, requestPermission } = {}) {
  const root = await mkdtemp(join(tmpdir(), 'woven-claude-engine-'));
  const claude = {
    checks: 0,
    models: [{ value: 'sonnet', displayName: 'Claude Sonnet', supportedEffortLevels: ['low', 'medium', 'high'] }],
    loadModels: async () => {},
    async status() { this.checks++; return { connected: true }; },
    sdkQuery: async () => { throw new Error('A fixture must never call the Claude runtime.'); },
  };
  const options = { cwd: root, directory: root, claude, credentials, requestPermission,
    config: { providers: ['claude-subscription'], defaultModel: 'claude-subscription/sonnet', ...config } };
  const engine = await new DefaultAgentEngine(options).initialize();
  t.after(async () => {
    for (const record of engine.sessions.values()) record.session.dispose();
    await rm(root, { recursive: true, force: true });
  });
  await engine.runtime.refresh({ allowNetwork: false });
  return { root, engine, claude, options };
}

function syntheticAssistant(content) {
  return model => {
    const stream = createAssistantMessageEventStream();
    const value = typeof content === 'function' ? content() : content;
    const result = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
      content: value, timestamp: Date.now(), stopReason: value.some(block => block.type === 'toolCall') ? 'toolUse' : 'stop',
      usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
    stream.push({ type: 'start', partial: result });
    stream.push({ type: 'done', reason: result.stopReason, message: result });
    stream.end(result);
    return stream;
  };
}

async function pollUntil(service, id, predicate) {
  const deadline = Date.now() + 5000;
  while (true) {
    const page = await service.poll(id);
    if (predicate(page)) return page;
    if (Date.now() >= deadline) assert.fail('Timed out waiting for the synthetic remote run.');
    await new Promise(resolve => setTimeout(resolve, 5));
  }
}

test('ordinary Claude submissions reuse the selected model without spawning native status checks', async t => {
  const { engine, claude } = await fixture(t);
  const record = await engine.create();
  record.session.agent.streamFunction = syntheticAssistant([{ type: 'text', text: 'Fixture reply' }]);
  const beforeChecks = claude.checks;
  const beforeChanges = record.manager.getEntries().filter(entry => entry.type === 'model_change').length;
  await engine.prompt(record, 'First', () => {});
  await engine.prompt(record, 'Second', () => {});
  assert.equal(claude.checks, beforeChecks);
  assert.equal(record.manager.getEntries().filter(entry => entry.type === 'model_change').length, beforeChanges);
});

test('an Exa key and disabled model credentials do not hide the native Claude default', async t => {
  const { engine } = await fixture(t, {
    config: { providers: ['openai', 'claude-subscription'], defaultModel: null },
    credentials: { exa: { type: 'api_key', key: 'fixture-search' }, openrouter: { type: 'api_key', key: 'fixture-disabled' } },
  });
  assert.equal((await engine.create()).selected, 'claude-subscription/sonnet');
});

test('real Pi tool wrappers deny mutations and allow them only after host approval', async t => {
  const requests = [];
  let allowed = false;
  const { engine, root } = await fixture(t, { requestPermission: async params => { requests.push(params); return allowed; } });
  const record = await engine.create();
  const tools = new Map(record.session.agent.state.tools.map(tool => [tool.name, tool]));
  const signal = new AbortController().signal;
  await assert.rejects(tools.get('write').execute('write-denied', { path: 'note.txt', content: 'denied' }, signal), /declined/);
  await assert.rejects(access(join(root, 'note.txt')));
  await assert.rejects(tools.get('bash').execute('bash-denied', { command: 'touch denied.txt' }, signal), /declined/);
  await assert.rejects(access(join(root, 'denied.txt')));
  allowed = true;
  await tools.get('write').execute('write-allowed', { path: 'note.txt', content: 'original' }, signal);
  assert.equal(await readFile(join(root, 'note.txt'), 'utf8'), 'original');
  allowed = false;
  await assert.rejects(tools.get('edit').execute('edit-denied', { path: 'note.txt', edits: [{ oldText: 'original', newText: 'changed' }] }, signal), /declined/);
  assert.equal(await readFile(join(root, 'note.txt'), 'utf8'), 'original');
  assert.deepEqual(requests.map(request => request.toolCall.title), ['write', 'bash', 'write', 'edit']);
  assert.deepEqual(requests.map(request => request.toolCall.toolCallId), ['write-denied', 'bash-denied', 'write-allowed', 'edit-denied']);
  assert.ok(requests.every(request => request.sessionId === record.session.sessionId));
  await engine.select(record, 'full', 'permission_mode');
  await tools.get('edit').execute('edit-full', { path: 'note.txt', edits: [{ oldText: 'original', newText: 'changed' }] }, signal);
  assert.equal(await readFile(join(root, 'note.txt'), 'utf8'), 'changed');
  assert.equal(requests.length, 4);
});

test('model, thinking, and permission choices survive an empty draft restart', async t => {
  const { engine, options } = await fixture(t);
  const record = await engine.create();
  await engine.select(record, 'high', 'thinking');
  await engine.select(record, 'full', 'permission_mode');
  const restarted = await new DefaultAgentEngine(options).initialize();
  t.after(() => { for (const record of restarted.sessions.values()) record.session.dispose(); });
  const restored = await restarted.create(record.session.sessionId);
  assert.equal(restored.selected, 'claude-subscription/sonnet');
  assert.equal(restored.session.thinkingLevel, 'high');
  assert.equal(restored.permission, 'full');
});

test('session working directories stay isolated and survive a service restart', async t => {
  const { engine, root, options } = await fixture(t);
  const first = join(root, 'first-project'), second = join(root, 'second-project');
  await Promise.all([mkdir(first), mkdir(second)]);
  const opened = await engine.handle('session/new', { cwd: first });
  const record = engine.sessions.get(opened.sessionId);
  assert.equal(record.cwd, await realpath(first));
  assert.equal(record.manager.getHeader().cwd, record.cwd);
  await engine.select(record, 'full', 'permission_mode');
  const write = record.session.agent.state.tools.find(tool => tool.name === 'write');
  await write.execute('write-first', { path: 'location.txt', content: 'first project' }, new AbortController().signal);
  assert.equal(await readFile(join(first, 'location.txt'), 'utf8'), 'first project');
  await assert.rejects(access(join(root, 'location.txt')));
  await assert.rejects(engine.handle('session/load', { sessionId: opened.sessionId, cwd: second }), /different working directory/);
  assert.equal(engine.sessions.get(opened.sessionId), record);

  const restarted = await new DefaultAgentEngine({ ...options, cwd: second }).initialize();
  t.after(() => { for (const value of restarted.sessions.values()) value.session.dispose(); });
  await assert.rejects(restarted.handle('session/load', { sessionId: opened.sessionId, cwd: second }), /different working directory/);
  assert.equal(restarted.sessions.size, 0);
  const loaded = await restarted.handle('session/load', { sessionId: opened.sessionId });
  const restored = restarted.sessions.get(loaded.sessionId);
  assert.equal(restored.cwd, await realpath(first));
  const restoredWrite = restored.session.agent.state.tools.find(tool => tool.name === 'write');
  await restoredWrite.execute('write-restored', { path: 'restored.txt', content: 'same project' }, new AbortController().signal);
  assert.equal(await readFile(join(first, 'restored.txt'), 'utf8'), 'same project');
  await assert.rejects(access(join(second, 'restored.txt')));
  assert.equal((await restarted.handle('session/load', { sessionId: opened.sessionId, cwd: first })).sessionId, opened.sessionId);
});

test('invalid or unavailable working directories fail before a Built-in session is created', async t => {
  const { engine, root } = await fixture(t);
  for (const cwd of ['relative/project', '', 'invalid\0directory', join(root, 'missing')]) {
    await assert.rejects(engine.handle('session/new', { cwd }), /working directory/);
  }
  assert.equal(engine.sessions.size, 0);
});

test('remote approvals replay on reconnect, cancel safely, and reject stale decisions', { timeout: 15000 }, async t => {
  const root = await mkdtemp(join(tmpdir(), 'woven-claude-remote-'));
  // Service constructs its runtime internally. Mock only the native status
  // boundary; the real Pi loop, tools, encrypted vault and journals remain.
  const originalStatus = ClaudeRuntime.prototype.status;
  ClaudeRuntime.prototype.status = async () => ({ connected: true });
  t.after(() => { ClaudeRuntime.prototype.status = originalStatus; });
  const service = createDefaultAgentService({ cwd: root, directory: root });
  await service.configure({ workspace: 'fixture', unlockKey: randomBytes(32).toString('base64'), credentials: {},
    config: { providers: ['claude-subscription'], defaultModel: 'claude-subscription/sonnet' } });
  const engine = await service.engine(), record = await engine.create();
  t.after(async () => { record.session.dispose(); await rm(root, { recursive: true, force: true }); });
  let generation = 0;
  record.session.agent.streamFunction = syntheticAssistant(() => {
    generation++;
    return generation % 2 ? [{ type: 'toolCall', id: `call-${generation}`, name: 'write', arguments: { path: `file-${generation}.txt`, content: 'approved' } }] : [{ type: 'text', text: 'Done' }];
  });
  const submit = async () => {
    const id = crypto.randomUUID();
    await service.invoke({ method: 'session/prompt', operationID: id, params: { sessionId: record.session.sessionId, prompt: [{ type: 'text', text: 'Write fixture' }] } });
    return { id, page: await pollUntil(service, id, page => page.pendingPermissions?.length > 0) };
  };
  const first = await submit();
  const pending = first.page.updates.find(update => update.sessionUpdate === 'woven_permission');
  assert.ok(first.page.pendingPermissions.includes(pending.id));
  const reattached = await service.invoke({ method: 'session/load', params: { sessionId: record.session.sessionId } });
  assert.equal(reattached.operationID, first.id);
  assert.ok((await service.poll(first.id, 0)).pendingPermissions.includes(pending.id));
  await service.invoke({ method: 'woven/permission', params: { id: pending.id, result: { outcome: { outcome: 'selected', optionId: 'allow' } } } });
  assert.equal((await pollUntil(service, first.id, page => page.done)).error, null);
  assert.equal(await readFile(join(root, 'file-1.txt'), 'utf8'), 'approved');
  const loaded = await service.invoke({ method: 'session/load', params: { sessionId: record.session.sessionId } });
  assert.equal(loaded.result._meta.engine, 'claude');
  assert.equal(loaded.result._meta.recoveredRuns.length, 1);
  assert.equal(loaded.result._meta.recoveredRuns[0].runID, first.id);

  const second = await submit();
  const cancelled = second.page.pendingPermissions[0];
  await service.invoke({ method: 'session/cancel', params: { sessionId: record.session.sessionId } });
  const stopped = await pollUntil(service, second.id, page => page.done);
  assert.equal(stopped.result.stopReason, 'cancelled');
  assert.equal(stopped.pendingPermissions.length, 0);
  await assert.rejects(access(join(root, 'file-3.txt')));

  // The cancelled turn did not advance to a new generation. Make the next
  // prompt ask for a fresh tool approval before delivering an old decision.
  generation = 4;
  const third = await submit();
  const current = third.page.pendingPermissions[0];
  await service.invoke({ method: 'woven/permission', params: { id: cancelled, result: { outcome: { outcome: 'selected', optionId: 'allow' } } } });
  assert.ok((await service.poll(third.id)).pendingPermissions.includes(current));
  await service.invoke({ method: 'woven/permission', params: { id: current, result: { outcome: { outcome: 'selected', optionId: 'deny' } } } });
  await pollUntil(service, third.id, page => page.done);
  await assert.rejects(access(join(root, 'file-5.txt')));
});

test('remote polling continues during approvals and removed requests cannot send stale decisions', async () => {
  const local = new Map(), replies = [];
  const approvals = new RemotePermissionRequests((params, signal) => new Promise(resolve => {
    local.set(params.sessionId, { signal, resolve });
  }), async (id, allowed) => { replies.push({ id, allowed }); });
  const request = (id, sessionId) => ({ sessionUpdate: 'woven_permission', id, params: { sessionId } });
  const first = { updates: [request('one', 'session-a')], pendingPermissions: ['one'], done: false };
  assert.equal(approvals.update(first), undefined);
  assert.equal(local.size, 1);
  // Replayed pages neither wait on the open dialog nor create duplicates.
  approvals.update(first);
  approvals.update({ updates: [{ sessionUpdate: 'agent_message_chunk', content: { text: 'Still polling' } }], pendingPermissions: ['one'], done: false });
  assert.equal(local.size, 1);
  approvals.update({ updates: [], pendingPermissions: [], done: false });
  assert.equal(local.get('session-a').signal.aborted, true);
  local.get('session-a').resolve(true);
  await new Promise(setImmediate);
  assert.deepEqual(replies, []);
  assert.equal(approvals.pending.size, 0);

  approvals.update({ updates: [request('two', 'session-b')], pendingPermissions: ['two'], done: false });
  local.get('session-b').resolve(true);
  await new Promise(setImmediate);
  assert.deepEqual(replies, [{ id: 'two', allowed: true }]);

  approvals.update({ updates: [request('three', 'session-c')], pendingPermissions: ['three'], done: false });
  approvals.update({ updates: [], pendingPermissions: ['three'], done: true });
  assert.equal(local.get('session-c').signal.aborted, true);
  local.get('session-c').resolve(true);
  await new Promise(setImmediate);
  assert.equal(replies.length, 1);

  approvals.update({ updates: [request('four', 'session-d')], pendingPermissions: ['four'], done: false });
  approvals.close();
  assert.equal(local.get('session-d').signal.aborted, true);
  local.get('session-d').resolve(false);
  await new Promise(setImmediate);
  assert.equal(replies.length, 1);
});

test('local approval cancellation tells the Mac to dismiss exactly that stale dialog', async () => {
  const requests = new PermissionRequests(), controller = new AbortController(), dismissed = [];
  let id;
  const outcome = requests.request({ sessionId: 'session-a' }, controller.signal, value => { id = value; }, value => dismissed.push(value));
  controller.abort();
  assert.equal(await outcome, false);
  assert.deepEqual(dismissed, [id]);
  requests.resolve(id, { outcome: { outcome: 'selected', optionId: 'allow' } });
  requests.cancelSession('session-a');
  assert.deepEqual(dismissed, [id]);
  assert.equal(requests.pending.size, 0);
});

test('composer offers only the default and explicitly enabled models', async t => {
  const { engine } = await fixture(t, { config: { providers: ['claude-subscription', 'openai'] } });
  const catalog = engine.catalog();
  const other = catalog.find(model => model.id !== engine.config.defaultModel);
  assert.deepEqual(engine.modelOptions().map(model => model.id), [engine.config.defaultModel]);
  assert.ok(other, 'Fixture must include another catalog model');
  engine.config.models = [other.id];
  assert.deepEqual(engine.modelOptions().map(model => model.id), [engine.config.defaultModel, other.id]);
  engine.config.models = [];
  assert.deepEqual(engine.modelOptions().map(model => model.id), [engine.config.defaultModel]);
});


test('removed models normalize idle and restored selections to the visible default', async t => {
  const { engine } = await fixture(t);
  const record = await engine.create();
  const expected = record.selected;
  record.selected = 'openrouter/disabled';
  engine.persistOptions(record);
  await engine.apply({ config: engine.config });
  assert.equal(record.selected, expected);
  record.selected = 'openrouter/disabled';
  engine.persistOptions(record);
  engine.sessions.delete(record.session.sessionId);
  record.session.dispose();
  const restored = await engine.create(record.session.sessionId);
  assert.equal(restored.selected, expected);
  engine.config.defaultModel = 'disabled/model';
  assert.equal(engine.modelOptions()[0].id, expected);
});
