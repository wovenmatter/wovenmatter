#!/usr/bin/env node
// Provider-free contract suites. Live probes are separate, explicitly invoked scripts.
import { spawn } from 'node:child_process';
import { access, mkdir, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { performance } from 'node:perf_hooks';

export const contracts = [
  { id: 'probe-infrastructure', runtime: 'node', files: ['scripts/test-support/live-streaming-smoke.test.mjs'],
    coverage: 'Fake local adapter verifies explicit live opt-in, permission denial, event timing and response-text sanitization without any provider service.' },
  { id: 'pi-native', runtime: 'node', files: ['default-agent/test/native-message-stream.test.mjs', 'default-agent/test/native-tool-stream.test.mjs', 'default-agent/test/durable-engine.test.mjs'],
    coverage: 'Native incremental text/reasoning/tool arguments, snapshots, boundaries, provider failure and abort; shared Pi Durable contract, not provider-wire family coverage.' },
  { id: 'claude-native', runtime: 'node', files: ['default-agent/test/claude-native-session.test.mjs'],
    coverage: 'Synthetic Anthropic SSE and native continuation/signature translation; no provider requests.' },
  { id: 'ios-inference', runtime: 'node', files: ['default-agent/test/ios-inference-stream.test.mjs'],
    coverage: 'Actual mobile inference bridge preserves partial text/thinking/usage on disconnect, cancel and missing terminal; terminal frames win over duplicates.' },
  { id: 'remote-recovery', runtime: 'node', files: ['remote/test/durable-acp.test.mjs', 'remote/test/task-gateway.test.mjs', 'remote/test/client-execution-publisher.test.mjs'],
    coverage: 'Durable relay snapshots, recovery, lost receipts, retries, ordering and approval reconnect.' },
  { id: 'background-streaming', runtime: 'node', files: ['remote/test/opencode-task-stream.test.mjs', 'remote/test/task-gateway-native.test.mjs',
    'remote/test/client-execution.test.mjs', 'remote/test/client-retained-history.test.mjs'],
    coverage: 'Background OpenCode progress before idle, final history reconciliation, native tool order, atomic snapshot framing and retained execution recovery.' },
  { id: 'native-projection', runtime: 'swift', files: ['app/Tests/WovenMatterClientTests/ACPHarnessStreamingReviewTests.swift', 'app/Tests/WovenMatterClientTests/OpenCodeLiveProjectionTests.swift',
    'app/Tests/WovenMatterCoreTests/ACPAssistantStreamWriterTests.swift', 'app/Tests/WovenMatterCoreTests/AssistantStreamingTextTests.swift', 'app/Tests/WovenMatterCoreTests/OpenCodeIntegrationTests.swift',
    'app/Tests/WovenMatterClientTests/OpenCodeWireCaptureTests.swift', 'app/Tests/WovenMatterCoreTests/ConversationWorkTimelineTests.swift',
    'app/Tests/WovenMatterAppFacadeTests/StreamingPresentationTests.swift'],
    coverage: 'Actual Woven Swift adapter/projection code driven by offline wire fixtures; identities, snapshots, live OpenCode events and durable refresh.' },
];

const args = process.argv.slice(2);
if (!args.some(value => ['--portable', '--native', '--all'].includes(value))) {
  console.log('Usage: node scripts/streaming-contracts.mjs --portable|--native|--all [--skip-build] [--output /absolute/report.json]');
  console.log(JSON.stringify(contracts, null, 2));
} else {
  const root = fileURLToPath(new URL('../', import.meta.url));
  const selected = contracts.filter(value => args.includes('--all') || args.includes(value.runtime === 'node' ? '--portable' : '--native'));
  const results = [], cache = process.env.WOVENMATTER_TEST_CACHE_DIR ?? join(tmpdir(), 'wovenmatter-validation');
  await mkdir(cache, { recursive: true });
  for (const contract of selected) {
    for (const file of contract.files) await access(join(root, file));
    const start = performance.now();
    const filters = contract.files.map(path => path.split('/').at(-1).replace('.swift', '')).join('|');
    const command = contract.runtime === 'node' ? process.execPath : 'swift';
    const argv = contract.runtime === 'node' ? ['--test', '--test-concurrency=1', ...contract.files]
      : ['test', '--build-system', process.env.WOVENMATTER_SWIFT_BUILD_SYSTEM ?? 'swiftbuild', '--force-resolved-versions', '--package-path', 'app',
        '--scratch-path', join(cache, 'SwiftPM'), ...(args.includes('--skip-build') ? ['--skip-build'] : []), '--filter', filters];
    console.log(`Streaming contract: ${contract.id}`);
    const status = await new Promise(resolve => {
      const child = spawn(command, argv, { cwd: root, stdio: 'inherit', env: { ...process.env,
        CLANG_MODULE_CACHE_PATH: join(cache, 'ModuleCache'), SWIFTPM_MODULECACHE_OVERRIDE: join(cache, 'ModuleCache') } });
      child.on('error', () => resolve(-1)); child.on('exit', code => resolve(code ?? -1));
    });
    results.push({ id: contract.id, status, elapsedMS: Math.round(performance.now() - start), coverage: contract.coverage });
  }
  const report = { schemaVersion: 1, at: new Date().toISOString(), providerRequests: false, results };
  if (args.includes('--output')) await writeFile(args[args.indexOf('--output') + 1], JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
  process.exitCode = results.every(value => value.status === 0) ? 0 : 1;
}
