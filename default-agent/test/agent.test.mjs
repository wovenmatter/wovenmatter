import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { chmod, mkdir, mkdtemp, readdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { delimiter, join } from 'node:path';
import { claudeExecutable, claudeRequest, claudeStatus } from '../src/claude.mjs';
import { newestFirst } from '../src/models.mjs';
import { startAgent } from './fixtures/client.mjs';

async function folders(t) {
  const root = await mkdtemp(join(tmpdir(), 'pi-durable-test-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  return { data: join(root, 'data'), cwd: root };
}
// The synthetic provider's two models. A new chat takes its provider's newest.
const newest = 'synthetic/echo-2', older = 'synthetic/echo';
const text = (updates, kind = 'agent_message_chunk') => updates.filter(item => item.update.sessionUpdate === kind).map(item => item.update.content.text).join('');

test('a conversation survives a process restart', async t => {
  const { data, cwd } = await folders(t);
  const first = startAgent(t, { data, cwd });
  const { result: { sessionId } } = await first.request('session/new', { cwd, mcpServers: [] });
  assert.equal((await first.request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'one' }] })).result.stopReason, 'end_turn');
  await first.stop();

  const second = startAgent(t, { data, cwd });
  const loaded = await second.request('session/load', { sessionId, cwd, mcpServers: [] });
  assert.equal(loaded.result.configOptions.find(option => option.id === 'model').currentValue, newest);
  await second.request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'two' }] });
  assert.equal(text(second.updates), 'echo: two (turn 2)');
  await second.stop();
  assert.deepEqual(await readdir(data), ['pi-durable.sqlite']);
});

test('loading an unknown session fails with -32002 and creates nothing', async t => {
  const { data, cwd } = await folders(t);
  const agent = startAgent(t, { data, cwd });
  const reply = await agent.request('session/load', { sessionId: '0190a000-0000-7000-8000-000000000000', cwd, mcpServers: [] });
  assert.equal(reply.error.code, -32002);
  await agent.stop();
  assert.equal(existsSync(join(data, 'pi-durable.sqlite')), false);
});

test('a prompt streams its answer, then reports how it stopped and what it used', async t => {
  const { data, cwd } = await folders(t);
  const agent = startAgent(t, { data, cwd });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: [] });
  const reply = await agent.request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hello' }] });
  assert.equal(text(agent.updates), 'echo: hello (turn 1)');
  assert.deepEqual(reply.result, { stopReason: 'end_turn', usage: { inputTokens: 3, outputTokens: 2, cachedReadTokens: 1, cachedWriteTokens: 0 }, _meta: { model: newest } });
  await agent.stop();
});

test('credentials come from the server, renewals go back to it, and none reach the disk', async t => {
  const { data, cwd } = await folders(t);
  const expired = { type: 'oauth', access: 'expired-access', refresh: 'old-refresh', expires: Date.now() - 1000 };
  const agent = startAgent(t, { data, cwd, credentials: { synthetic: expired } });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: [] });
  const reply = await agent.request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'hi' }] });
  assert.equal(reply.result.stopReason, 'end_turn');
  assert.ok(agent.credentialRequests >= 1);
  const renewal = agent.notifications.find(message => message.method === 'woven/credentials/update');
  assert.equal(renewal.params.provider, 'synthetic');
  assert.equal(renewal.params.credential.refresh, 'renewed');
  await agent.stop();
  for (const name of await readdir(data, { recursive: true })) {
    const contents = await readFile(join(data, name)).catch(() => Buffer.alloc(0));
    for (const secret of ['expired-access', 'old-refresh', 'renewed', 'test-key']) assert.equal(contents.includes(secret), false, `${secret} in ${name}`);
  }
});

test('a subagent shows as a task tool call carrying its answer', async t => {
  const { data, cwd } = await folders(t);
  const agent = startAgent(t, { data, cwd });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: [] });
  await agent.request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'delegate this' }] });
  const call = agent.updates.find(item => item.update.sessionUpdate === 'tool_call')?.update;
  assert.equal(call.title, 'Count');
  assert.equal(call._meta.wovenKind, 'task');
  const done = agent.updates.find(item => item.update.sessionUpdate === 'tool_call_update' && item.update.status === 'completed')?.update;
  assert.equal(done.toolCallId, call.toolCallId);
  assert.equal(done.content[0].content.text, 'echo: child work (turn 1)');
  await agent.stop();
});

test('a message sent during a turn steers it, and the turn answers once', async t => {
  const { data, cwd } = await folders(t);
  const agent = startAgent(t, { data, cwd });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: [] });
  const turn = agent.request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'work slowly' }] });
  while (!agent.updates.some(item => item.update.sessionUpdate === 'tool_call')) await new Promise(resolve => setTimeout(resolve, 10));
  const steered = await agent.request('_session/steering', { sessionId, prompt: [{ type: 'text', text: 'and this' }] });
  assert.deepEqual(steered.result, { outcome: 'injected' });
  assert.equal((await turn).result.stopReason, 'end_turn');
  assert.equal(text(agent.updates), 'echo: and this (turn 2)');
  const idle = await agent.request('_session/steering', { sessionId, prompt: [{ type: 'text', text: 'late' }] });
  assert.equal(idle.result.outcome, 'promptRequired');
  await agent.stop();
});

test('a model chosen during a turn is taken at once, and the turn goes on with it', async t => {
  const { data, cwd } = await folders(t);
  const agent = startAgent(t, { data, cwd });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: [] });
  const turn = agent.request('session/prompt', { sessionId, prompt: [{ type: 'text', text: 'work slowly' }] });
  while (!agent.updates.some(item => item.update.sessionUpdate === 'tool_call')) await new Promise(resolve => setTimeout(resolve, 10));
  const changed = await agent.request('session/set_config_option', { sessionId, configId: 'model', value: older });
  assert.equal(changed.result.configOptions.find(option => option.id === 'model').currentValue, older);
  const reply = (await turn).result;
  assert.equal(reply.stopReason, 'end_turn');
  assert.equal(reply._meta.model, older);
  await agent.stop();
});

test('Claude runs the first executable claude on PATH, or says it is not installed', async t => {
  const { cwd } = await folders(t);
  const [none, plain, installed] = ['none', 'plain', 'installed'].map(name => join(cwd, name));
  for (const folder of [none, plain, installed]) await mkdir(folder);
  await writeFile(join(plain, 'claude'), '');
  await writeFile(join(installed, 'claude'), '#!/bin/sh\n');
  await chmod(join(installed, 'claude'), 0o755);
  assert.equal(claudeExecutable([none, plain, installed].join(delimiter)), join(installed, 'claude'));
  assert.throws(() => claudeExecutable([none, plain].join(delimiter)), { message: 'Claude Code is not installed on this machine.' });
});

test("Claude's sign-in is what Claude Code reports: signed in, signed out, or no answer", async t => {
  const { cwd } = await folders(t);
  const path = process.env.PATH;
  t.after(() => { process.env.PATH = path; });
  const status = async script => {
    await writeFile(join(cwd, 'claude'), `#!/bin/sh\n${script}\n`);
    await chmod(join(cwd, 'claude'), 0o755);
    process.env.PATH = cwd;
    return claudeStatus();
  };
  assert.deepEqual(await status(`echo '{"loggedIn":true,"authMethod":"claude.ai","email":"person@example.com"}'`), { signedIn: true, account: 'person@example.com' });
  // Signed out, Claude Code exits 1 and still prints its status.
  assert.deepEqual(await status(`echo '{"loggedIn":false,"authMethod":"none"}'; exit 1`), { signedIn: false, account: undefined });
  assert.deepEqual(await status(`echo '{"loggedIn":true,"authMethod":"api_key"}'`), { signedIn: false, account: undefined });
  assert.deepEqual(await status('echo starting; exit 2'), {});
  process.env.PATH = join(cwd, 'none');
  assert.deepEqual(await claudeStatus(), { signedIn: false });
});

test('Claude sees each tool under the name Pi gives it, and calls come back under it', () => {
  const tool = (name) => ({ name, description: name, parameters: { type: 'object', properties: {} } });
  const messages = [
    { role: 'system', content: 'Use mcp__woven__list_sessions.', toolsAdded: [tool('mcp__woven__list_sessions'), tool('read'), tool('codemode')] },
    { role: 'user', content: 'Which chats?' },
    { role: 'assistant', api: 'claude-agent-sdk', model: 'sonnet', content: [{ type: 'toolCall', id: 'call_1', name: 'mcp__woven__list_sessions', arguments: {} }] },
    { role: 'toolResult', toolCallId: 'call_1', content: [{ type: 'text', text: '{"sessions":[]}' }] },
  ];
  const request = claudeRequest({ messages }, { id: 'sonnet' });
  assert.deepEqual(request.inventory.map(entry => entry.name), ['mcp__woven__list_sessions', 'read', 'codemode']);
  assert.equal(request.frames[1].message.content[0].name, 'mcp__woven__list_sessions');
});

test('the catalog lists each provider newest first, Default on top', () => {
  const listed = [['default', 'Default (recommended)'], ['claude-opus-4-5-20251101', 'Opus 4.5'], ['gpt-6', 'GPT-6'],
    ['opus', 'Opus 5.5'], ['claude-fable-5-2[1m]', 'Fable 5.2'], ['gpt-6.2-sol', 'GPT-6.2 Sol'], ['gpt-6.1', 'GPT-6.1']];
  assert.deepEqual(newestFirst(listed.map(([id, name]) => ({ id, name }))).map(model => model.id),
    ['default', 'gpt-6.2-sol', 'gpt-6.1', 'gpt-6', 'opus', 'claude-fable-5-2[1m]', 'claude-opus-4-5-20251101']);
});
