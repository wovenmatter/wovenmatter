import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { startAgent } from './fixtures/client.mjs';

const server = fileURLToPath(new URL('./fixtures/woven-mcp.mjs', import.meta.url));
const catalog = JSON.parse(readFileSync(new URL('./fixtures/woven-catalog.json', import.meta.url), 'utf8'));

// Starts the agent; a test that fails still stops it.
function start(t, options) {
  const agent = startAgent(options);
  t.after(() => agent.stop());
  return agent;
}
async function folders(t) {
  const root = await mkdtemp(join(tmpdir(), 'pi-durable-codemode-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  return { data: join(root, 'data'), cwd: root, log: join(root, 'calls.jsonl') };
}
// Woven's MCP server as the fixture plays it.
const woven = (log, slowMs = 1500) => [{ name: 'woven', command: process.execPath, args: [server],
  env: [{ name: 'WOVEN_FIXTURE_LOG', value: log }, { name: 'WOVEN_FIXTURE_SLOW_MS', value: String(slowMs) }] }];
const replies = updates => updates.filter(item => item.update.sessionUpdate === 'agent_message_chunk').map(item => item.update.content.text).join('');
async function ask(agent, sessionId, text) {
  const start = agent.updates.length;
  const reply = await agent.request('session/prompt', { sessionId, prompt: [{ type: 'text', text }] });
  assert.equal(reply.result?.stopReason, 'end_turn', JSON.stringify(reply.error));
  return replies(agent.updates.slice(start));
}
const offered = async (agent, sessionId) => (await ask(agent, sessionId, 'tools?')).replace(/^tools: /, '').split(',').filter(Boolean);
const frames = (agent, id) => agent.updates.map(item => item.update).filter(update => update.toolCallId === id);
const calls = async log => (await readFile(log, 'utf8').catch(() => '')).split('\n').filter(Boolean).map(line => JSON.parse(line));
async function until(condition, timeoutMs = 20000) {
  const end = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > end) throw new Error('Timed out waiting.');
    await new Promise(resolve => setTimeout(resolve, 10));
  }
}

test('code mode is offered beside the other tools, alone, or not at all, as Settings say', async t => {
  const { data, cwd, log } = await folders(t);
  for (const [codeMode, check] of [
    ['on', tools => { assert.ok(tools.includes('codemode')); assert.ok(tools.includes('mcp__woven__list_sessions')); assert.ok(tools.includes('bash')); assert.ok(tools.includes('subagent')); }],
    [undefined, tools => { assert.ok(tools.includes('codemode')); assert.ok(tools.includes('mcp__woven__goal_met')); }],
    ['sideways', tools => { assert.ok(tools.includes('codemode')); assert.ok(tools.includes('read')); }],
    ['only', tools => assert.deepEqual(tools, ['codemode'])],
    ['off', tools => { assert.ok(!tools.includes('codemode')); assert.ok(tools.includes('mcp__woven__render_html')); assert.ok(tools.includes('bash')); }],
  ]) {
    const agent = start(t, { data, cwd, settings: codeMode === undefined ? {} : { codeMode } });
    const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: woven(log) });
    const tools = await offered(agent, sessionId);
    assert.ok(!tools.some(name => name.startsWith('pi.codemode.')), `${codeMode}: ${tools}`);
    check(tools);
    await agent.stop();
  }
});

test('the codemode section declares every Woven tool, so scripts need no search, and Off leaves it out', async t => {
  const { data, cwd, log } = await folders(t);
  const settings = { codeMode: 'on' };
  const agent = start(t, { data, cwd, settings });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: woven(log) });
  const prompt = await ask(agent, sessionId, 'prompt?');
  assert.ok(prompt.includes('Tools scripts can call'));
  assert.ok(!prompt.includes('Some tools are not listed'));
  assert.ok(prompt.includes('## mcp__woven\nYou are running inside Woven Matter'));
  assert.equal(catalog.length, 28);
  for (const tool of catalog) assert.ok(prompt.includes(`### \`mcp__woven__${tool.name}\``), tool.name);
  assert.ok(prompt.includes('`await tools.mcp__woven__list_sessions({})`'));
  // A Woven tool's declaration returns its value's shape, and one that can return images has them.
  assert.ok(prompt.includes('Promise<{ sessions: Array<{'), prompt);
  assert.ok(/mcp__woven__preview_html\(args: \{[\s\S]*?\}\): Promise<\{[\s\S]*?images\?: Array</.test(prompt));
  assert.ok(prompt.includes('image(result.images[0])'));

  settings.codeMode = 'only';
  const only = await ask(agent, sessionId, 'prompt?');
  for (const tool of catalog) assert.ok(only.includes(`### \`mcp__woven__${tool.name}\``), tool.name);

  settings.codeMode = 'off';
  const off = await ask(agent, sessionId, 'prompt?');
  assert.ok(!off.includes('Tools scripts can call'));
  assert.ok(!off.includes('image(result.images[0])'));
  await agent.stop();
});

test('a change of code mode applies from the next prompt', async t => {
  const { data, cwd, log } = await folders(t);
  const settings = { codeMode: 'on' };
  const agent = start(t, { data, cwd, settings });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: woven(log) });
  const on = await offered(agent, sessionId);
  assert.ok(on.includes('codemode') && on.includes('mcp__woven__list_sessions'));
  settings.codeMode = 'only';
  assert.deepEqual(await offered(agent, sessionId), ['codemode']);
  settings.codeMode = 'off';
  const off = await offered(agent, sessionId);
  assert.ok(!off.includes('codemode') && off.includes('mcp__woven__list_sessions'));
  settings.codeMode = 'on';
  assert.deepEqual(await offered(agent, sessionId), on);
  await agent.stop();

  // The conversation keeps the last mode it was given; a new process applies the current one when it opens.
  settings.codeMode = 'only';
  const again = start(t, { data, cwd, settings });
  await again.request('session/load', { sessionId, cwd, mcpServers: woven(log) });
  assert.deepEqual(await offered(again, sessionId), ['codemode']);
  await again.stop();
});

test('a script calls Woven tools, gets their values, images and errors, and shows as one code call with the calls it made', async t => {
  const { data, cwd, log } = await folders(t);
  const agent = start(t, { data, cwd, settings: { codeMode: 'only' } });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: woven(log) });
  const script = [
    'const sessions = await tools.mcp__woven__list_sessions({});',
    "const shot = await tools.mcp__woven__preview_html({ html: '<p>hi</p>' });",
    'image(shot.images[0]);',
    "let caught = '';",
    "try { await tools.mcp__woven__read_session({ sessionID: 'gone' }); } catch (error) { caught = error.message; }",
    "await tools.update_checklist({ todos: [{ id: 'one', content: 'Look', status: 'completed' }] });",
    "const slow = await tools.mcp__woven__search_library({ query: 'slow' });",
    "const page = '<!doctype html><html><body>' + 'Quarterly sales '.repeat(400) + '</body></html>';",
    "await tools.mcp__woven__render_html({ html: page, title: 'Sales' });",
    "text([sessions.sessions[0].id, sessions.sessions[0].title, shot.contentHeight, typeof shot, shot.images.length, caught, slow.items[0].title].join(' / '));",
  ].join('\n');
  const answer = await ask(agent, sessionId, `script: ${script}`);

  // The model gets the script's output and the image it showed.
  assert.ok(answer.includes('session-1 / Notes / 120 / object / 1 / There is no session gone. / Found after a while.'), answer);
  assert.ok(answer.includes('[images: 1]'), answer);

  const [announced, ...rest] = frames(agent, 'call-script-1');
  assert.equal(announced.sessionUpdate, 'tool_call');
  assert.equal(announced.kind, 'execute');
  assert.deepEqual(announced.rawInput, { code: script });
  assert.deepEqual(announced._meta, { wovenKind: 'code', wovenCalls: [] });
  const done = rest.at(-1);
  assert.equal(done.status, 'completed');
  assert.ok(done.content.some(item => item.content.type === 'image'));
  assert.equal(done.rawOutput, undefined);
  const made = done._meta.wovenCalls;
  assert.equal(done._meta.wovenKind, 'code');
  assert.deepEqual(made.map(call => [call.name, call.status]), [
    ['mcp__woven__list_sessions', 'ok'], ['mcp__woven__preview_html', 'ok'], ['mcp__woven__read_session', 'error'],
    ['update_checklist', 'ok'], ['mcp__woven__search_library', 'ok'], ['mcp__woven__render_html', 'ok']]);
  assert.deepEqual(made[0].input, {});
  assert.deepEqual(made[2].input, { sessionID: 'gone' });
  assert.ok(made[2].error.includes('There is no session gone.'), made[2].error);
  assert.deepEqual(made[5].input, { html: `(${'<!doctype html><html><body>'.length + 16 * 400 + '</body></html>'.length} characters, shown in the chat)`, title: 'Sales' });

  // While it ran: the slow call showed as running, after the ones before it.
  const running = rest.filter(update => update.status === 'in_progress' && update._meta?.wovenCalls?.some(call => call.status === 'running'));
  assert.ok(running.some(update => update._meta.wovenCalls.at(-1).name === 'mcp__woven__search_library'
    && update._meta.wovenCalls.slice(0, -1).every(call => call.status !== 'running')));
  // The checklist it updated is the plan too.
  const plan = agent.updates.find(item => item.update.sessionUpdate === 'plan')?.update;
  assert.deepEqual(plan.entries, [{ content: 'Look', status: 'completed', priority: 'medium' }]);

  // The page itself never crossed ACP; only the script that built it did.
  for (const item of agent.updates) assert.ok(!JSON.stringify(item).includes('Quarterly sales Quarterly sales'));
  assert.equal((await calls(log)).find(call => call.name === 'render_html').arguments.html.length, 27 + 16 * 400 + 14);
  await agent.stop();
});

test('a failure the script does not catch fails it, with the error text', async t => {
  const { data, cwd, log } = await folders(t);
  const agent = start(t, { data, cwd });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: woven(log) });
  const answer = await ask(agent, sessionId, "script: await tools.mcp__woven__read_session({ sessionID: 'gone' });");
  assert.ok(answer.includes('Script failed') && answer.includes('There is no session gone.'), answer);
  const done = frames(agent, 'call-script-1').at(-1);
  assert.equal(done.status, 'failed');
  assert.equal(done._meta.wovenCalls.length, 1);
  assert.equal(done._meta.wovenCalls[0].status, 'error');
  assert.ok(done._meta.wovenCalls[0].error.includes('There is no session gone.'));
  await agent.stop();
});

test('a direct MCP call still gives the model and Woven its content as it was', async t => {
  const { data, cwd, log } = await folders(t);
  const agent = start(t, { data, cwd });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: woven(log) });
  const answer = await ask(agent, sessionId, 'call: mcp__woven__preview_html {"html":"<p>hi</p>"}');
  assert.ok(answer.includes('{"width":728,"contentHeight":120,"missingImages":[]}') && answer.includes('[images: 1]'), answer);
  const [announced, ...rest] = frames(agent, 'call-direct-1');
  assert.deepEqual(announced, { sessionUpdate: 'tool_call', toolCallId: 'call-direct-1', kind: 'other', rawInput: { html: '<p>hi</p>' }, title: 'mcp__woven__preview_html', status: 'pending' });
  const done = rest.at(-1);
  assert.equal(done.status, 'completed');
  assert.deepEqual(done.content.map(item => item.content.type), ['text', 'image']);
  assert.equal(done.rawOutput, null);
  assert.equal(done._meta, undefined);

  const failed = await ask(agent, sessionId, 'call: mcp__woven__read_session {"sessionID":"gone"}');
  assert.ok(failed.includes('There is no session gone.'), failed);
  const error = frames(agent, 'call-direct-2').at(-1);
  assert.equal(error.status, 'failed');
  assert.deepEqual(error.content, [{ type: 'content', content: { type: 'text', text: 'There is no session gone.' } }]);
  await agent.stop();
});

test('a script a restart interrupts resumes without repeating the calls it finished', async t => {
  const { data, cwd, log } = await folders(t);
  const first = start(t, { data, cwd });
  const { result: { sessionId } } = await first.request('session/new', { cwd, mcpServers: woven(log, 60000) });
  const script = "const a = await tools.mcp__woven__list_sessions({}); const b = await tools.mcp__woven__search_library({ query: 'slow' }); text(a.sessions[0].title + ' + ' + b.items[0].title);";
  void first.request('session/prompt', { sessionId, prompt: [{ type: 'text', text: `script: ${script}` }] });
  await until(() => frames(first, 'call-script-1').some(update => update._meta?.wovenCalls?.some(call => call.name === 'mcp__woven__search_library')));
  await first.stop();

  const second = start(t, { data, cwd });
  await second.request('session/load', { sessionId, cwd, mcpServers: woven(log, 10) });
  await until(() => frames(second, 'call-script-1').some(update => update.status === 'completed'));
  const done = frames(second, 'call-script-1').at(-1);
  assert.ok(done.content.some(item => item.content.text?.includes('Notes + Found after a while.')), JSON.stringify(done.content));
  assert.deepEqual(done._meta.wovenCalls.map(call => [call.name, call.status]), [['mcp__woven__list_sessions', 'ok'], ['mcp__woven__search_library', 'ok']]);
  // Announced again from the live round, it keeps its source.
  const announced = frames(second, 'call-script-1')[0];
  assert.deepEqual(announced.rawInput, { code: script });
  const names = (await calls(log)).map(call => call.name);
  assert.deepEqual(names, ['list_sessions', 'search_library', 'search_library']);
  await until(() => replies(second.updates).includes('Found after a while.'));
  await second.stop();
});

test('a subagent keeps its parent code mode, without subagents of its own', async t => {
  const { data, cwd, log } = await folders(t);
  const settings = { codeMode: 'only' };
  const agent = start(t, { data, cwd, settings });
  const { result: { sessionId } } = await agent.request('session/new', { cwd, mcpServers: woven(log) });
  const only = await ask(agent, sessionId, "script: text(await tools.subagent({ description: 'Tools', prompt: 'tools?' }));");
  assert.match(only, /tools: codemode \(turn 1\)/);
  const child = async id => frames(agent, id).at(-1).content[0].content.text.replace(/^tools: /, '').split(',');
  settings.codeMode = 'off';
  await ask(agent, sessionId, 'call: subagent {"description":"Tools","prompt":"tools?"}');
  const off = await child('call-direct-2');
  assert.ok(!off.includes('codemode') && off.includes('mcp__woven__list_sessions') && !off.includes('subagent'), off.join(','));
  settings.codeMode = 'on';
  await ask(agent, sessionId, 'call: subagent {"description":"Tools","prompt":"tools?"}');
  const on = await child('call-direct-3');
  assert.ok(on.includes('codemode') && on.includes('mcp__woven__list_sessions') && !on.includes('subagent'), on.join(','));
  await agent.stop();
});
