import test from 'node:test';
import assert from 'node:assert/strict';
import { cpSync, mkdtempSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { spawn, spawnSync } from 'node:child_process';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createInterface } from 'node:readline';
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

for (const takeover of ['before-extension', 'after-extension', 'none']) {
  test(`Pi adapter completes the binding handshake with stdout takeover ${takeover}`, async t => {
    const directory = fixture(t);
    const runtime = join(directory, 'pi-fixture.mjs');
    writeFileSync(runtime, `
      import { createInterface } from 'node:readline';
      import { pathToFileURL } from 'node:url';
      const rawWrite = process.stdout.write.bind(process.stdout);
      const output = value => rawWrite(JSON.stringify(value) + '\\n');
      const takeOver = () => { process.stdout.write = process.stderr.write.bind(process.stderr); };
      if (process.env.TAKEOVER === 'before-extension') takeOver();
      const { default: extension } = await import(pathToFileURL(process.argv[process.argv.indexOf('--extension') + 1]));
      const hooks = new Map();
      extension({ on: (name, fn) => hooks.set(name, fn) });
      if (process.env.TAKEOVER === 'after-extension') takeOver();
      process.stdout.write('extension diagnostic\\n');
      let pending = Promise.resolve();
      const input = createInterface({ input: process.stdin });
      input.on('line', line => {
        pending = pending.then(async () => {
          const message = JSON.parse(line);
          await hooks.get('input')({ source: 'rpc' });
          await hooks.get('before_agent_start')();
          output({ id: message.id, type: 'response', command: 'prompt', success: true, data: { disposition: 'started' } });
          output({ type: 'agent_start' });
          const user = { role: 'user', content: [{ type: 'text', text: message.message }] };
          await hooks.get('message_start')({ message: { role: 'system' } });
          await hooks.get('message_start')({ message: user });
          output({ type: 'message_start', message: user });
          const tool = { toolName: 'bash', input: { command: 'wovenmatter context' } };
          await hooks.get('tool_call')(tool);
          output({ type: 'fixture_tool', input: tool.input });
          output({ type: 'agent_end' });
        });
      });
      input.on('close', async () => {
        await pending;
        hooks.get('session_shutdown')();
      });
    `);
    const prompts = ['first input', 'large input ' + 'x'.repeat(128 * 1024)];
    const child = spawn(process.execPath, [
      fileURLToPath(new URL('../../harnesses/cli/adapter.mjs', import.meta.url)), 'pi', process.execPath, runtime,
    ], {
      env: { ...process.env, TAKEOVER: takeover }, stdio: ['pipe', 'pipe', 'pipe'],
    });
    const result = { stdout: '', stderr: '', status: undefined };
    child.stderr.setEncoding('utf8').on('data', chunk => { result.stderr += chunk; });
    let completed = 0;
    const output = createInterface({ input: child.stdout });
    output.on('line', line => {
      result.stdout += line + '\n';
      if (line === '{"type":"agent_end"}' && ++completed === prompts.length) child.stdin.end();
    });
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        child.kill();
        reject(new Error('Pi binding handshake timed out: ' + result.stderr));
      }, 5000);
      child.on('error', error => { clearTimeout(timeout); reject(error); });
      child.on('close', status => { clearTimeout(timeout); result.status = status; resolve(); });
      child.stdin.write(prompts.map((message, index) => JSON.stringify({
        type: 'prompt', id: index, message, _meta: { wovenTools: context(`capture-${index}`) },
      })).join('\n') + '\n');
    });
    assert.equal(result.status, 0, result.stderr);
    const lines = result.stdout.trim().split('\n');
    if (takeover === 'none') assert.equal(lines.shift(), 'extension diagnostic');
    else assert.equal(result.stderr, 'extension diagnostic\n');
    const events = lines.map(line => JSON.parse(line));
    assert.equal(events.some(event => event.type === 'wovenmatter_cli'), false);
    assert.equal(events.filter(event => event.type === 'agent_end').length, 2);
    assert.deepEqual(events.filter(event => event.type === 'message_start').map(event => event.message.content[0].text), prompts);
    const tools = events.filter(event => event.type === 'fixture_tool');
    for (const [index, tool] of tools.entries()) {
      assert.match(tool.input.command, new RegExp(`WOVENMATTER_CONTEXT_ID='capture-${index}'`));
      assert.match(tool.input.command, /session.sock/);
    }
    assert.equal(tools.length, 2);
  });
}
