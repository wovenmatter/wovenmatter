import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { binding, connect, consume, enqueue, callContext } from '../../harnesses/mcp/binding.mjs';
import { handleHook } from '../../harnesses/mcp/hook.mjs';
import { promptCandidates, configure, nativeSessionInstructions } from '../../harnesses/mcp/adapter.mjs';
import { wovenInstructions } from '../../harnesses/mcp/instructions.mjs';
import { createMCPProxy } from '../../harnesses/mcp/proxy.mjs';
import openCode from '../../harnesses/mcp/opencode.mjs';

const context = captureID => ({ endpointURL: 'http://127.0.0.1:34567/mcp', bearerToken: 'fixture-private-token', captureID });
function fixture(t) {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), 'woven-mcp-binding-test-')));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

test('native consumption retains each input capture across queueing, rejection and reconnect', t => {
  const directory = fixture(t);
  enqueue(directory, context('a'), ['first']);
  consume(directory, 'turn-a', 'first');
  const reject = enqueue(directory, context('rejected'), ['second']); reject();
  enqueue(directory, context('b'), ['second']);
  assert.equal(binding(directory, 'turn-a').captureID, 'a');
  consume(directory, 'turn-b', 'second');
  connect(directory, { ...context(''), endpointURL: 'http://127.0.0.1:34568/mcp' });
  assert.equal(binding(directory, 'turn-a').captureID, 'a');
  assert.equal(binding(directory, 'turn-b').captureID, 'b');
  assert.equal(binding(directory, 'turn-a').endpointURL, 'http://127.0.0.1:34568/mcp');
  consume(directory, 'internal-wakeup', 'unbound input');
  assert.equal(binding(directory, 'internal-wakeup').captureID, '');
  assert.throws(() => connect(directory, { ...context(''), endpointURL: 'http://example.com/mcp' }), /Invalid/);
});

test('native hooks correlate only context calls without shell rewriting or approval decisions', t => {
  for (const runtime of ['codex', 'claude_code', 'grok_build']) {
    const directory = fixture(t);
    enqueue(directory, context(runtime), ['hello']);
    const identity = runtime === 'codex' ? { session_id: 'native', turn_id: 'turn' }
      : runtime === 'claude_code' ? { session_id: 'native', prompt_id: 'turn' }
      : { sessionId: 'native', promptId: 'turn' };
    assert.deepEqual(handleHook(runtime, directory, { ...identity, hook_event_name: 'UserPromptSubmit', prompt: 'hello' }), {});
    const output = handleHook(runtime, directory, { ...identity, hook_event_name: 'PreToolUse', tool_name: 'mcp__woven__woven_context', tool_input: {} });
    const updated = output.hookSpecificOutput.updatedInput;
    assert.match(updated.requestID, /^[0-9a-f-]{36}$/);
    assert.equal(callContext(directory, updated.requestID), runtime);
    assert.equal(JSON.stringify(output).includes('permissionDecision'), false);
    assert.equal(JSON.stringify(output).includes('additionalContext'), false);
    assert.deepEqual(handleHook(runtime, directory, { ...identity, hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'pwd' } }), {});
    const mutation = { requestID: '10000000-0000-4000-8000-000000000001', noteID: 'note' };
    assert.deepEqual(handleHook(runtime, directory, { ...identity, hook_event_name: 'PreToolUse', tool_name: 'mcp__woven__woven_notes_append', tool_input: mutation }), {});
  }
  const prompt = [{ type: 'text', text: 'unchanged text' }, { type: 'image', data: 'image' }];
  assert.ok(promptCandidates('codex', { prompt }).includes('unchanged text'));
  assert.deepEqual(prompt[0], { type: 'text', text: 'unchanged text' });
});

test('bundled context hooks work through symlinked app paths containing spaces', t => {
  const directory = fixture(t), actual = join(directory, 'Woven Matter Dev.app', 'mcp');
  const bundled = join(directory, 'Launch alias');
  cpSync(new URL('../../harnesses/mcp/', import.meta.url), actual, { recursive: true });
  symlinkSync(actual, bundled, 'dir');
  enqueue(directory, context('captured'), ['hello']);
  const identity = { session_id: 'native', turn_id: 'turn' };
  const invoke = event => {
    const result = spawnSync(process.execPath, [join(bundled, 'hook.mjs'), 'codex'], {
      env: { ...process.env, WOVEN_MCP_BINDING_DIRECTORY: directory },
      input: JSON.stringify({ ...identity, ...event }), encoding: 'utf8', timeout: 5000,
    });
    assert.equal(result.status, 0, result.stderr); return JSON.parse(result.stdout);
  };
  assert.deepEqual(invoke({ hook_event_name: 'UserPromptSubmit', prompt: 'hello' }), {});
  const result = invoke({ hook_event_name: 'PreToolUse', tool_name: 'mcp__woven__woven_context', tool_input: {} });
  assert.equal(callContext(directory, result.hookSpecificOutput.updatedInput.requestID), 'captured');
});

for (const runtime of ['codex', 'claude_code', 'grok_build']) test(`${runtime} MCP wrapper starts its fixture through a symlink`, t => {
  const directory = fixture(t), alias = join(directory, 'Woven Dev.app');
  symlinkSync(realpathSync(new URL('../../harnesses/mcp/', import.meta.url)), alias, 'dir');
  const fake = join(directory, 'fixture.mjs');
  writeFileSync(fake, `import {readFileSync} from 'node:fs'; for(const line of readFileSync(0,'utf8').trim().split('\\n')) {const message=JSON.parse(line); console.log(JSON.stringify({id:message.id,result:{fixture:true}}));}`);
  const result = spawnSync(process.execPath, [join(alias, 'adapter.mjs'), runtime, process.execPath, fake], {
    env: { PATH: process.env.PATH, HOME: directory, GROK_HOME: join(directory, 'grok') },
    input: JSON.stringify({id:1,method:'initialize',params:{}}) + '\n', encoding: 'utf8', timeout: 5000,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), {id:1,result:{fixture:true}});
});

test('OpenCode MCP installer starts through a symlink without touching real user settings', t => {
  const directory = fixture(t), alias = join(directory, 'Woven Dev.app');
  symlinkSync(realpathSync(new URL('../../harnesses/mcp/', import.meta.url)), alias, 'dir');
  const result = spawnSync(process.execPath, [join(alias, 'install.mjs'), 'opencode'], {
    env: {PATH:process.env.PATH, XDG_CONFIG_HOME:join(directory,'config')}, encoding:'utf8',timeout:5000,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(readFileSync(join(directory,'config/opencode/plugins/woven-mcp.js'),'utf8'), /opencode\.mjs/);
});

test('HTTP proxy authenticates locally and forwards only native-bound context with unchanged images', async t => {
  const forwarded = [], image = { type: 'image', mimeType: 'image/png', data: 'ZmFrZQ==' };
  const proxy = await createMCPProxy({ getConnection: () => context(''), contextFor: id => id === 'native-request' ? 'input-a' : undefined,
    fetchImpl: async (url, options) => {
      forwarded.push({ url, ...options, body: JSON.parse(options.body) });
      return new Response(JSON.stringify({ jsonrpc: '2.0', id: 1, result: { content: [image] } }), { headers: { 'content-type': 'application/json' } });
    } });
  t.after(() => proxy.close());
  const invoke = (message, bearer = proxy.connection.bearerToken) => fetch(proxy.connection.endpointURL, { method: 'POST', headers: { Authorization: 'Bearer ' + bearer, 'Content-Type': 'application/json' }, body: JSON.stringify(message) });
  const message = { jsonrpc: '2.0', id: 1, method: 'tools/call', params: { name: 'woven_context', arguments: { requestID: 'native-request' }, _meta: { wovenContextID: 'forged' } } };
  assert.equal((await invoke(message, 'wrong')).status, 401);
  assert.equal(forwarded.length, 0);
  assert.deepEqual((await (await invoke(message)).json()).result.content, [image]);
  assert.equal(forwarded[0].headers.Authorization, 'Bearer fixture-private-token');
  assert.equal(forwarded[0].body.params._meta.wovenContextID, 'input-a');
  message.params.arguments.requestID = 'unbound';
  await invoke(message);
  assert.equal(forwarded[1].body.params._meta.wovenContextID, undefined);
  message.params.name = 'woven_notes_read';
  message.params.arguments = { noteID: 'note' };
  await invoke(message);
  assert.equal(forwarded[2].body.params._meta.wovenContextID, undefined);
});

test('native instructions preserve supplied settings, authored messages and resumed rules', t => {
  const env = { CODEX_CONFIG: JSON.stringify({ developer_instructions: 'Existing instructions', model: 'native-model' }) };
  configure('codex', fixture(t), [], env);
  const config = JSON.parse(env.CODEX_CONFIG);
  assert.equal(config.model, 'native-model');
  assert.equal(config.developer_instructions, 'Existing instructions\n\n' + wovenInstructions);
  assert.equal(config.base_instructions, undefined);
  const persona = { CODEX_CONFIG: JSON.stringify({ developer_instructions: 'Existing instructions' }), WOVENMATTER_ADDITIONAL_INSTRUCTIONS: 'Selected persona' };
  configure('codex', fixture(t), [], persona);
  assert.equal(JSON.parse(persona.CODEX_CONFIG).developer_instructions, 'Existing instructions\n\nSelected persona\n\n' + wovenInstructions);
  assert.equal(persona.WOVENMATTER_ADDITIONAL_INSTRUCTIONS, undefined);
  for (const runtime of ['pi', 'hermes', 'openclaw', 'cursor']) assert.throws(() => configure(runtime, fixture(t), [], {}), /Unsupported/);
  const prompt = { method: 'session/prompt', params: { prompt: [{ type: 'text', text: 'User text' }] } };
  const before = structuredClone(prompt);
  nativeSessionInstructions('claude_code', prompt, '/fixture/plugin');
  assert.deepEqual(prompt, before);
  const claude = { method: 'session/new', params: { _meta: { systemPrompt: { append: 'Project additions', excludeDynamicSections: ['date'] } } } };
  nativeSessionInstructions('claude_code', claude, '/fixture/plugin'); nativeSessionInstructions('claude_code', claude, '/fixture/plugin');
  assert.equal(claude.params._meta.systemPrompt.append, 'Project additions\n\n' + wovenInstructions);
  assert.deepEqual(claude.params._meta.systemPrompt.excludeDynamicSections, ['date']);
  assert.equal(claude.params._meta.claudeCode.options.plugins.length, 1);
  const grok = { method: 'session/new', params: { _meta: { rules: 'Project rules' } } };
  nativeSessionInstructions('grok_build', grok);
  assert.equal(grok.params._meta.rules, 'Project rules\n\n' + wovenInstructions);
  assert.equal(grok.params._meta.systemPromptOverride, undefined);
  const resume = { method: 'session/load', params: { _meta: { rules: 'Original rules' } } };
  nativeSessionInstructions('grok_build', resume);
  assert.equal(resume.params._meta.rules, 'Original rules');
});

test('OpenCode isolates MCP tools to their session and captures the preceding native input', async t => {
  const hooks = new Map(), registrations = { dispose() {} }; let methods;
  const toolID = 'woven_' + createHash('sha256').update('woven').digest('hex').slice(0, 16) + '_woven_context';
  const tools = [{ id: toolID, execute: async input => input }];
  const teardown = await openCode.setup({
    rpc: { register: async (_schema, handlers) => { methods = handlers; return registrations; } },
    session: { get: async () => ({}), hook: async (name, fn) => { hooks.set(name, fn); return registrations; }, messages: async () => ({ data: [
      { id: 'user-b', type: 'user', metadata: { wovenMCP: { captureID: 'b' } } },
      { id: 'assistant-a', type: 'assistant' },
      { id: 'user-a', type: 'user', metadata: { wovenMCP: { captureID: 'a' } } },
    ] }) },
    tool: { transform: async fn => { fn({ list: () => tools, update: (_, update) => update(tools[0]) }); return registrations; } },
  });
  t.after(teardown);
  const native = { type: 'text', text: 'Native and project instructions' };
  const unrelated = { sessionID: 'other', system: [native] };
  await hooks.get('context')(unrelated); assert.deepEqual(unrelated.system, [native]);
  const connection = await methods.connect({ sessionID: 'woven', context: context('') });
  const event = { sessionID: 'woven', system: [native, { type: 'text', text: wovenInstructions }] };
  await hooks.get('context')(event); await hooks.get('context')(event);
  assert.deepEqual(event.system, [native, { type: 'text', text: wovenInstructions }]);
  await assert.rejects(tools[0].execute({}, { sessionID: 'other', messageID: 'assistant-a' }), /another session/);
  const input = await tools[0].execute({}, { sessionID: 'woven', messageID: 'assistant-a' });
  assert.match(input.requestID, /^[0-9a-f-]{36}$/);
  assert.match(connection.endpointURL, /^http:\/\/127\.0\.0\.1:\d+\/mcp$/);
  // Capture remains inside the proxy; no credential or capture is added to input.
  assert.deepEqual(Object.keys(input), ['requestID']);
});
