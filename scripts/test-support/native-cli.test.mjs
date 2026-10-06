import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, realpathSync, rmSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { binding, connect, consume, enqueue, shellInput } from '../../harnesses/cli/binding.mjs';
import { handleHook } from '../../harnesses/cli/hook.mjs';
import { promptCandidates } from '../../harnesses/cli/adapter.mjs';
import { PiBindings } from '../../harnesses/cli/pi-bindings.mjs';
import openCode from '../../harnesses/cli/opencode.mjs';
import { registerCLI } from '../../remote/src/openclaw-results/cli.mjs';

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
  for (const runtime of ['codex', 'claude_code', 'cursor', 'grok_build']) {
    const directory = fixture(t);
    enqueue(directory, context(runtime), ['hello']);
    const identity = runtime === 'codex' ? { session_id: 'native', turn_id: 'turn' }
      : runtime === 'claude_code' ? { session_id: 'native', prompt_id: 'turn' }
      : runtime === 'cursor' ? { conversation_id: 'native', generation_id: 'turn' }
      : { sessionId: 'native', promptId: 'turn' };
    assert.deepEqual(handleHook(runtime, directory, { ...identity, hook_event_name: 'UserPromptSubmit', prompt: 'hello' }), {});
    const tool = runtime === 'grok_build' ? 'run_terminal_cmd' : runtime === 'codex' ? 'exec_command' : 'Bash';
    const field = runtime === 'codex' ? 'cmd' : 'command';
    const output = handleHook(runtime, directory, { ...identity, hook_event_name: 'PreToolUse', tool_name: tool, tool_input: { [field]: 'wovenmatter help' } });
    const updated = runtime === 'cursor' ? output.updated_input : output.hookSpecificOutput.updatedInput;
    assert.match(updated[field], new RegExp(`WOVENMATTER_CONTEXT_ID='${runtime}'`));
    assert.equal(JSON.stringify(output).includes('permissionDecision'), false);
    assert.equal(JSON.stringify(output).includes('additionalContext'), false);
  }
  const prompt = [{ type: 'text', text: 'unchanged text' }, { type: 'image', data: 'image' }];
  assert.ok(promptCandidates('codex', { prompt }).includes('unchanged text'));
  assert.deepEqual(prompt[0], { type: 'text', text: 'unchanged text' });
  assert.deepEqual(promptCandidates('grok_build', { text: 'steer' }), ['steer']);
});

test('bundled hooks run from application paths containing spaces', t => {
  const directory = fixture(t);
  const bundled = join(directory, 'Woven Matter Dev.app', 'cli');
  cpSync(new URL('../../harnesses/cli/', import.meta.url), bundled, { recursive: true });
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

test('OpenClaw observes input admission without changing its prompt and binds each tool', t => {
  const hooks = new Map(), methods = new Map();
  registerCLI({ on: (name, fn) => hooks.set(name, fn), registerGatewayMethod: (name, fn) => methods.set(name, fn) }, fixture(t));
  const stage = id => methods.get('wovenmatter.cli.bind')({
    params: { sessionKey: 'native-session', context: context(id), inputID: id }, respond: ok => assert.equal(ok, true),
  });
  const native = { sessionKey: 'native-session', runId: 'native-run' };
  stage('a');
  assert.equal(hooks.get('before_prompt_build')({ currentUserMessageId: 'a:user', currentUserMessage: 'first' }, native), undefined);
  stage('b');
  const first = hooks.get('before_tool_call')({ toolName: 'exec', params: { command: 'wovenmatter context' } }, native);
  hooks.get('before_prompt_build')({ currentUserMessageId: 'b:user', currentUserMessage: 'second' }, native);
  const second = hooks.get('before_tool_call')({ toolName: 'exec', params: { command: 'wovenmatter context' } }, native);
  assert.match(first.params.command, /WOVENMATTER_CONTEXT_ID='a'/);
  assert.match(second.params.command, /WOVENMATTER_CONTEXT_ID='b'/);
});


test('Pi binds expanded prompts at consumption and discards canceled queue entries', t => {
  const directory = fixture(t);
  connect(directory, context(''));
  const replies = [];
  const pi = new PiBindings(directory, value => replies.push(value));
  const event = (event, extra = {}) => pi.observe({ type: 'wovenmatter_cli', event, ...extra });
  pi.submit(context('a'));
  event('input', { source: 'rpc' }); event('start');
  event('consume', { generation: 'first', text: 'expanded template and image hints' });
  pi.submit(context('b'));
  event('input', { source: 'rpc' });
  pi.observe({ type: 'queue_update', steering: ['expanded skill'], followUp: [] });
  assert.equal(binding(directory, 'first').captureID, 'a');
  pi.observe({ type: 'queue_update', steering: [], followUp: [] });
  event('consume', { generation: 'second', text: 'expanded skill' });
  assert.equal(binding(directory, 'second').captureID, 'b');
  pi.submit(context('canceled'));
  event('input', { source: 'rpc' });
  pi.observe({ type: 'queue_update', steering: ['same text'], followUp: [] });
  pi.observe({ type: 'queue_update', steering: [], followUp: [] });
  pi.observe({ type: 'response', command: 'clear_queue', success: true });
  event('input', { source: 'extension' }); event('start');
  event('consume', { generation: 'automatic', text: 'same text' });
  assert.equal(binding(directory, 'automatic').captureID, '');
  assert.equal(replies.length, 3);
});
