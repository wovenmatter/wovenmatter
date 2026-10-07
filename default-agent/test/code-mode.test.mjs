import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createAssistantMessageEventStream } from '@earendil-works/pi-ai';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { validateConfig } from '../src/config.mjs';

function response(model, content) {
  const stream = createAssistantMessageEventStream();
  const message = { role: 'assistant', api: model.api, provider: model.provider, model: model.id,
    content, timestamp: Date.now(), stopReason: content.some(c => c.type === 'toolCall') ? 'toolUse' : 'stop',
    usage: { input: 1, output: 1, cacheRead: 0, cacheWrite: 0, totalTokens: 2, cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } } };
  stream.push({ type: 'start', partial: message }); stream.push({ type: 'done', reason: message.stopReason, message }); stream.end(message); return stream;
}

test('Durable code mode retains sandbox tools, persisted store, and nested unsafe task receipts', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'woven-code-mode-'));
  assert.equal(validateConfig({}).codeMode, 'on');
  for (const mode of ['on', 'only', 'off']) assert.equal(validateConfig({ codeMode: mode }).codeMode, mode);
  const claude = { models: [{ value: 'sonnet', displayName: 'Fixture' }], loadModels: async () => {}, environment: async () => ({}), status: async () => ({ connected: true }), sdkQuery: async () => ({ accountInfo: async () => ({ email: 'fixture@example.invalid', organization: 'fixture-org', apiProvider: 'firstParty' }), close() {} }) };
  const engine = await new DefaultAgentEngine({ cwd: directory, directory, claude, config: { providers: ['claude-subscription'], defaultModel: 'claude-subscription/sonnet', codeMode: 'only' } }).initialize();
  const record = await engine.create();
  t.after(async () => { await record.session.dispose(); await rm(directory, { recursive: true, force: true }); });
  assert.ok(record.registry.snapshot().tools().some(({ tool }) => tool.name === 'write'));
  let calls = 0;
  record.streamFunction = (model, input) => {
    const nativeTools = input.messages.filter(m => m.role === 'system').flatMap(m => m.toolsAdded ?? []);
    assert.deepEqual([...new Set(nativeTools.map(t => t.name))], ['codemode']);
    return response(model, ++calls === 1 ? [{ type: 'toolCall', id: 'code-write', name: 'codemode', arguments: { code: 'store("fixture", "remembered"); return await tools.write({path: "allowed.txt", content: "yes"});' } }] : [{ type: 'text', text: 'Finished' }]);
  };
  assert.equal((await engine.prompt(record, 'Write', () => {})).stopReason, 'end_turn');
  assert.equal(await readFile(join(directory, 'allowed.txt'), 'utf8'), 'yes');
  const context = (await import('@earendil-works/chord/context')).BACKGROUND_CONTEXT;
  const records = (await record.storage.scanTasks({ conversationId: record.conversation.id, kind: 'pi.tool' }, 200, undefined, context)).items;
  assert.equal(records.length, 2);
  assert.ok(records.some(task => task.owner));
  assert.ok((await record.conversation.context(context)).entries.some(entry => entry.kind === 'woven.codemode-store'));
  await engine.apply({ config: { providers: ['claude-subscription'], defaultModel: 'claude-subscription/sonnet', codeMode: 'off' } });
  await record.configurationQueue;
  assert.ok((await record.conversation.agent(context)).tools.every(tool => tool.name !== 'codemode'));
});
