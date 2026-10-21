import test from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, rmSync, existsSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

function directory(t) {
  const root = mkdtempSync(join(tmpdir(), 'woven-entrypoint-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  return root;
}
function invoke(name, args, input, root) {
  const guard = 'globalThis.fetch=()=>{throw Error("Provider/network access forbidden in this fixture")};';
  const result = spawnSync(process.execPath,
    ['--import', 'data:text/javascript,' + encodeURIComponent(guard),
      fileURLToPath(new URL('../src/' + name, import.meta.url)), ...args], {
      input: input.map(value => JSON.stringify(value)).join('\n') + '\n', encoding: 'utf8',
      timeout: 5000, killSignal: 'SIGKILL', maxBuffer: 65536,
      env: { PATH: process.env.PATH, HOME: root, WOVEN_DEFAULT_AGENT_DIRECTORY: root,
        ...(process.env.NODE_V8_COVERAGE ? { NODE_V8_COVERAGE: process.env.NODE_V8_COVERAGE } : {}) },
    });
  assert.equal(result.error, undefined, result.error?.message);
  return { ...result, replies: result.stdout.trim().split('\n').filter(Boolean).map(line => JSON.parse(line)) };
}

test('inventory entrypoint negotiates metadata and refuses executable tools through the real stdio protocol', t => {
  const root = directory(t), path = join(root, 'tools.json'), effect = join(root, 'must-not-exist');
  const tools = [{ name: 'synthetic-tool', description: 'Inventory metadata', inputSchema: { type: 'object' } }];
  writeFileSync(path, JSON.stringify(tools));
  const result = invoke('claude-inventory.mjs', [path], [
    { method: 'notifications/initialized' },
    { id: 0, method: 'initialize' },
    { id: 1, method: 'tools/list' },
    { id: 2, method: 'tools/call', params: { name: 'synthetic-tool', arguments: { command: `touch ${effect}` } } },
  ], root);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(result.replies.map(value => value.id), [0, 1, 2]);
  assert.equal(result.replies[0].result.serverInfo.name, 'woven-inventory');
  assert.deepEqual(result.replies[1].result.tools, tools);
  assert.equal(result.replies[2].result.isError, true);
  assert.match(result.replies[2].result.content[0].text, /Only Woven Matter executes/);
  assert.equal(existsSync(effect), false);
});

test('SDK control entrypoint handles only its first request and reports metadata without installation or network', t => {
  const root = directory(t);
  const result = invoke('sdk-control.mjs', [], [
    { action: 'status' }, { action: 'update', id: 'pi', version: '999.0.0' },
  ], root);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.replies.length, 1);
  assert.deepEqual(result.replies[0].result.sdks.map(sdk => sdk.id).sort(), ['claude', 'pi']);
  assert.equal(existsSync(join(root, 'sdk-runtime/generations')), false);
  const invalid = invoke('sdk-control.mjs', [], [{ action: 'unsupported', apiKey: 'synthetic-secret' }], root);
  assert.equal(invalid.status, 1);
  assert.deepEqual(invalid.replies, [{ error: 'Choose an SDK maintenance action.' }]);
  assert.equal(JSON.stringify(invalid.replies).includes('synthetic-secret'), false);
});
