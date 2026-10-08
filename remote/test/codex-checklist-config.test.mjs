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
  assert.equal(environment({ id: 'pi' }).CODEX_CONFIG, undefined);
  assert.equal(environment({ id: 'hermes' }).HERMES_ACP_SKIP_CONFIGURED_MCP, '0');
  assert.match(source, /createDurableACP\(\{ catalog, workspaceRoot,\s+environment: harness => harness.id === 'codex' \? harnessRuntimeEnvironment\(harness\) : harnessEnvironment\(\),/);
  // Scheduled launches must pass their selected harness to this callback; the
  // runner currently omits it and is a separate integration-owner change.
  assert.match(source, /createTaskExecutor\(\{catalog,workspaceRoot,\s+environment: harness => harness\?\.id === 'codex' \? harnessRuntimeEnvironment\(harness\) : harnessEnvironment\(\),/);
  assert.match(source, /env: harnessRuntimeEnvironment\(harness\)/);
  const relay = await readFile(new URL('../src/durable-acp.mjs', import.meta.url), 'utf8');
  assert.match(relay, /environment\(harness\)/);
});
