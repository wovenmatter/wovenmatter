import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { runInNewContext } from 'node:vm';

test('remote live ACP and readiness use the same Codex checklist launch override', async () => {
  // Evaluate the production environment function without booting the service,
  // probing credentials, or starting any harness process.
  const source = await readFile(new URL('../src/server.mjs', import.meta.url), 'utf8');
  const definition = source.match(/function harnessRuntimeEnvironment\(harness\) \{[\s\S]*?\n\}/)?.[0];
  assert.ok(definition);
  const environment = runInNewContext(`(${definition})`, { harnessEnvironment: () => ({ PATH: '/fixture' }) });
  assert.deepEqual(JSON.parse(environment({ id: 'codex' }).CODEX_CONFIG), {
    approvals_reviewer: 'auto_review', 'tools.update_plan.enabled': true,
  });
  assert.equal(environment({ id: 'grok_build' }).CODEX_CONFIG, undefined);
  const composed = runInNewContext(`(${definition})`, { harnessEnvironment: () => ({ CODEX_CONFIG: JSON.stringify({ developer_instructions: 'Existing additions', model: 'native-model' }) }) });
  assert.equal(JSON.parse(composed({ id: 'codex' }).CODEX_CONFIG).developer_instructions, 'Existing additions');
  assert.equal(JSON.parse(composed({ id: 'codex' }).CODEX_CONFIG).model, 'native-model');
  assert.match(source, /createDurableACP\(\{ catalog, workspaceRoot,\s+environment: harness => harness.id === 'codex' \? harnessRuntimeEnvironment\(harness\) : harnessEnvironment\(\),/);
  // Scheduled launches use the same harness-specific environment.
  assert.match(source, /createTaskExecutor\(\{catalog,workspaceRoot,\s+environment: harness => harness\?\.id === 'codex' \? harnessRuntimeEnvironment\(harness\) : harnessEnvironment\(\),/);
  assert.match(source, /env: harnessRuntimeEnvironment\(harness\)/);
  const relay = await readFile(new URL('../src/durable-acp.mjs', import.meta.url), 'utf8');
  assert.match(relay, /environment\(harness\)/);
});
