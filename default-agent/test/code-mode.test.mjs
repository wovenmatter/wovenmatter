import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { DefaultAgentEngine } from '../src/engine.mjs';
import { validateConfig } from '../src/config.mjs';

test('code mode defaults on, supports only/off and retains guards on nested tools', async t => {
  const directory = await mkdtemp(join(tmpdir(), 'woven-code-mode-'));
  t.after(() => rm(directory, { recursive: true, force: true }));
  assert.equal(validateConfig({}).codeMode, 'on');
  for (const mode of ['on', 'only', 'off']) assert.equal(validateConfig({ codeMode: mode }).codeMode, mode);
  const engine = await new DefaultAgentEngine({ cwd: directory, directory, config: { providers: ['openai'], codeMode: 'only' } }).initialize();
  const record = await engine.create();
  t.after(() => record.session.dispose());
  assert.ok(record.session.getActiveToolNames().includes('codemode'));
  assert.ok(record.session.getCallableToolNames().includes('write'));
  const mode = record.session.agent.state.tools.find(tool => tool.name === 'codemode');
  assert.ok(mode);
  record.session.agent.state.messages.push({ role: "assistant", content: [{ type: "toolCall", id: "test-code", name: "codemode", arguments: {} }], timestamp: Date.now(), stopReason: "toolUse" });
  // SDK nested execution goes through the guarded custom tool, including Only.
  let approvals = 0;
  record.requestPermission = async () => { approvals++; return false; };
  const rejected = await mode.execute('test-code', { code: 'return await tools.write({path: "blocked.txt", content: "no"});' }, new AbortController().signal);
  assert.equal(approvals, 1, JSON.stringify(rejected));
  assert.match(JSON.stringify(rejected), /declined|reject|error/i);
  await assert.rejects(readFile(join(directory, 'blocked.txt')), { code: 'ENOENT' });
  record.permission = 'full';
  await mode.execute('test-full', { code: 'return await tools.write({path: "allowed.txt", content: "yes"});' }, new AbortController().signal);
  assert.equal(await readFile(join(directory, 'allowed.txt'), 'utf8'), 'yes');
  assert.equal(approvals, 1);
  await engine.apply({ config: { providers: ['openai'], codeMode: 'off' } });
  assert.ok(!record.session.getActiveToolNames().includes('codemode'));
  await assert.rejects(async () => mode.execute('test-off', { code: 'return 1;' }, new AbortController().signal), /disabled/);
  await engine.apply({ config: { providers: ['openai'], codeMode: 'on' } });
  assert.ok(record.session.getActiveToolNames().includes('codemode'));
});
