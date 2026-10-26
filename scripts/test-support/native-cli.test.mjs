import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, realpathSync, rmSync, symlinkSync, writeFileSync, readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { binding, connect, consume, enqueue, shellInput } from '../../harnesses/cli/binding.mjs';
import { handleHook } from '../../harnesses/cli/hook.mjs';
import { promptCandidates, configure, nativeSessionInstructions } from '../../harnesses/cli/adapter.mjs';
import { wovenInstructions } from '../../harnesses/cli/instructions.mjs';
import openCode from '../../harnesses/cli/opencode.mjs';

const context = captureID => ({ executablePath: '/app/bin/wovenmatter', socketPath: '/tmp/session.sock', captureID });
function fixture(t) {
  const directory = realpathSync(mkdtempSync(join(tmpdir(), 'wovenmatter-binding-test-')));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  return directory;
}

test('native consumption binds queued inputs and reconnect changes only the connection', t => {
  const directory = fixture(t);
  enqueue(directory, context('a'), ['first']);
  consume(directory, 'turn-a', 'first');
  const first = shellInput({ cmd: 'wovenmatter context' }, binding(directory, 'turn-a'));
  const reject = enqueue(directory, context('rejected'), ['second']); reject();
  enqueue(directory, context('b'), ['second']);
  assert.equal(binding(directory, 'turn-a').captureID, 'a');
  consume(directory, 'turn-b', 'second');
  connect(directory, { ...context(''), socketPath: '/tmp/reconnected.sock' });
  assert.equal(binding(directory, 'turn-a').captureID, 'a');
  assert.equal(binding(directory, 'turn-b').captureID, 'b');
  assert.equal(binding(directory, 'turn-a').socketPath, '/tmp/reconnected.sock');
  assert.match(first.cmd, /session.sock/);
  assert.match(first.cmd, /WOVENMATTER_CONTEXT_ID='a'/);
  consume(directory, 'internal-wakeup', 'unbound input');
  assert.equal(binding(directory, 'internal-wakeup').captureID, '');
});

test('native hook outputs update only shell arguments and never permissions or model context', t => {
  for (const runtime of ['codex', 'claude_code', 'grok_build']) {
    const directory = fixture(t);
    enqueue(directory, context(runtime), ['hello']);
    const identity = runtime === 'codex' ? { session_id: 'native', turn_id: 'turn' }
      : runtime === 'claude_code' ? { session_id: 'native', prompt_id: 'turn' }
      : { sessionId: 'native', promptId: 'turn' };
    assert.deepEqual(handleHook(runtime, directory, { ...identity, hook_event_name: 'UserPromptSubmit', prompt: 'hello' }), {});
    const tool = runtime === 'grok_build' ? 'run_terminal_cmd' : runtime === 'codex' ? 'exec_command' : 'Bash';
    const field = runtime === 'codex' ? 'cmd' : 'command';
    const output = handleHook(runtime, directory, { ...identity, hook_event_name: 'PreToolUse', tool_name: tool, tool_input: { [field]: 'wovenmatter help' } });
    const updated = output.hookSpecificOutput.updatedInput;
    assert.match(updated[field], new RegExp(`WOVENMATTER_CONTEXT_ID='${runtime}'`));
    assert.equal(JSON.stringify(output).includes('permissionDecision'), false);
    assert.equal(JSON.stringify(output).includes('additionalContext'), false);
  }
  const prompt = [{ type: 'text', text: 'unchanged text' }, { type: 'image', data: 'image' }];
  assert.ok(promptCandidates('codex', { prompt }).includes('unchanged text'));
  assert.deepEqual(prompt[0], { type: 'text', text: 'unchanged text' });
  assert.deepEqual(promptCandidates('grok_build', { text: 'steer' }), ['steer']);
});

test('bundled hooks run through symlinked application paths containing spaces', t => {
  const directory = fixture(t);
  const actual = join(directory, 'Woven Matter Dev.app', 'cli');
  const bundled = join(directory, 'Launch alias');
  cpSync(new URL('../../harnesses/cli/', import.meta.url), actual, { recursive: true });
  symlinkSync(actual, bundled, 'dir');
  enqueue(directory, context('captured'), ['hello']);
  const identity = { session_id: 'native', turn_id: 'turn' };
  const invoke = event => {
    const result = spawnSync(process.execPath, [join(bundled, 'hook.mjs'), 'codex'], {
      env: { ...process.env, WOVENMATTER_BINDING_DIRECTORY: directory },
      input: JSON.stringify({ ...identity, ...event }), encoding: 'utf8', timeout: 5000,
    });
    assert.equal(result.status, 0, result.stderr);
    return JSON.parse(result.stdout);
  };
  assert.deepEqual(invoke({ hook_event_name: 'UserPromptSubmit', prompt: 'hello' }), {});
  const result = invoke({ hook_event_name: 'PreToolUse', tool_name: 'exec_command', tool_input: { cmd: 'wovenmatter context' } });
  assert.match(result.hookSpecificOutput.updatedInput.cmd, /WOVENMATTER_CONTEXT_ID='captured'/);
});

for (const runtime of ['codex', 'claude_code', 'grok_build']) test(`${runtime} wrapper starts its fixture through a symlink`, t => {
  const directory = fixture(t), alias = join(directory, 'Woven Dev.app');
  symlinkSync(realpathSync(new URL('../../harnesses/cli/', import.meta.url)), alias, 'dir');
  const fake = join(directory, 'fixture.mjs');
  writeFileSync(fake, `import {readFileSync} from 'node:fs'; for(const line of readFileSync(0,'utf8').trim().split('\\n')) {const message=JSON.parse(line); console.log(JSON.stringify({id:message.id,result:{fixture:true}}));}`);
  const result = spawnSync(process.execPath, [join(alias, 'adapter.mjs'), runtime, process.execPath, fake], {
    env: { PATH: process.env.PATH, HOME: directory, GROK_HOME: join(directory, 'grok') },
    input: JSON.stringify({id:1,method:'initialize',params:{}}) + '\n', encoding: 'utf8', timeout: 5000,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), {id:1,result:{fixture:true}});
});

test('OpenCode installer starts through a symlink without touching real user settings', t => {
  const directory = fixture(t), alias = join(directory, 'Woven Dev.app');
  symlinkSync(realpathSync(new URL('../../harnesses/cli/', import.meta.url)), alias, 'dir');
  const result = spawnSync(process.execPath, [join(alias, 'install.mjs'), 'opencode'], {
    env: {PATH:process.env.PATH, XDG_CONFIG_HOME:join(directory,'config')}, encoding:'utf8',timeout:5000,
  });
  assert.equal(result.status, 0, result.stderr);
  assert.match(readFileSync(join(directory,'config/opencode/plugins/wovenmatter-cli.js'),'utf8'), /opencode\.mjs/);
});

test('OpenCode resolves the user before the executing assistant, not a later admitted input', async () => {
  const hooks = new Map(), storage = new Map();
  const tools = [{ id: 'bash', execute: async () => {
    const event = { env: { PATH: '/usr/bin', NATIVE: 'kept' } };
    await hooks.get('shell:create.before')(event);
    return event.env;
  } }];
  const api = {
    rpc: { register: async () => ({ dispose() {} }) },
    storage: { get: async key => storage.get(key), set: async (key, value) => storage.set(key, value) },
    session: { messages: async () => ({ data: [
      { id: 'user-a', type: 'user', metadata: { wovenTools: context('a') } },
      { id: 'assistant-a', type: 'assistant' },
      { id: 'user-b', type: 'user', metadata: { wovenTools: context('b') } },
    ].reverse(), cursor: {} }), hook: async (name, fn) => { hooks.set(name, fn); return { dispose() {} }; } },
    tool: { transform: async fn => { fn({ list: () => tools, update: (_, fn) => fn(tools[0]) }); return { dispose() {} }; } },
    shell: { hook: async (name, fn) => { hooks.set('shell:' + name, fn); return { dispose() {} }; } },
  };
  await openCode.setup(api);
  const env = await tools[0].execute({}, { sessionID: 'session-a', messageID: 'assistant-a' });
  assert.equal(env.WOVENMATTER_CONTEXT_ID, 'a');
  assert.equal(env.NATIVE, 'kept');
});

test('native instructions compose existing settings and do not alter user messages or resumed rules', t => {
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
  for (const runtime of ['pi', 'hermes', 'openclaw', 'cursor']) {
    assert.throws(() => configure(runtime, fixture(t), [], {}), /Unsupported/);
  }
  const prompt = { method: 'session/prompt', params: { prompt: [{ type: 'text', text: 'User text' }] } };
  const before = structuredClone(prompt);
  nativeSessionInstructions('claude_code', prompt, '/fixture/plugin');
  assert.deepEqual(prompt, before);
  const claude = { method: 'session/new', params: { _meta: { systemPrompt: { append: 'Project additions', excludeDynamicSections: ['date'] } } } };
  nativeSessionInstructions('claude_code', claude, '/fixture/plugin');
  nativeSessionInstructions('claude_code', claude, '/fixture/plugin');
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

test('OpenCode appends exactly one supported system part only to Woven-connected sessions', async () => {
  const hooks = new Map(), storage = new Map();
  let methods;
  const registration = { dispose() {} };
  await openCode.setup({
    rpc: { register: async (_schema, handlers) => { methods = handlers; return registration; } },
    storage: { get: async key => storage.get(key), set: async (key, value) => storage.set(key, value) },
    session: { get: async () => ({}), hook: async (name, fn) => { hooks.set(name, fn); return registration; } },
    tool: { transform: async () => registration },
    shell: { hook: async () => registration },
  });
  const native = { type: 'text', text: 'Native and project instructions' };
  const unrelated = { sessionID: 'other', system: [native] };
  await hooks.get('context')(unrelated);
  assert.deepEqual(unrelated.system, [native]);
  await methods.connect({ sessionID: 'woven', context: context('') });
  const event = { sessionID: 'woven', system: [native, { type: 'text', text: wovenInstructions }] };
  await hooks.get('context')(event);
  await hooks.get('context')(event);
  assert.deepEqual(event.system, [native, { type: 'text', text: wovenInstructions }]);
  assert.equal(storage.size, 1, 'instructions do not accumulate in session history or storage');
});
