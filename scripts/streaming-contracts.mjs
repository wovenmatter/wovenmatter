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
    'remote/test/client-execution.test.mjs', 'remote/test/client-retained-history.test.mjs', 'remote/test/reasoning-details.test.mjs'],
    coverage: 'Background OpenCode progress before idle, final history reconciliation, native tool order, atomic snapshot framing, complete coalesced reasoning and retained execution recovery.' },
  { id: 'native-projection', runtime: 'swift', files: ['app/Tests/WovenMatterClientTests/ACPHarnessStreamingReviewTests.swift', 'app/Tests/WovenMatterClientTests/OpenCodeLiveProjectionTests.swift',
    'app/Tests/WovenMatterCoreTests/ACPAssistantStreamWriterTests.swift', 'app/Tests/WovenMatterCoreTests/AssistantStreamingTextTests.swift', 'app/Tests/WovenMatterCoreTests/OpenCodeIntegrationTests.swift',
    'app/Tests/WovenMatterClientTests/OpenCodeWireCaptureTests.swift', 'app/Tests/WovenMatterCoreTests/ConversationWorkTimelineTests.swift',
    'app/Tests/WovenMatterAppFacadeTests/StreamingPresentationTests.swift', 'app/Tests/WovenMatterCoreTests/CompanionPublisherTests.swift'],
    coverage: 'Actual Woven Swift adapter/projection code driven by offline wire fixtures; identities, snapshots, live OpenCode events and durable refresh.' },
  { id: 'shared-detail-chain', runtime: 'swift', packagePath: 'shared', buildSystem: 'native', scratchDirectory: 'SharedSwiftPM',
    files: ['shared/Tests/WovenMatterCompanionTests/CompanionActivityDetailsTests.swift'],
    coverage: 'Shared v1/v2 reconstruction preserves Unicode and head metadata and rejects malformed or cyclic detail chains.' },
  { id: 'mobile-detail-chain', runtime: 'swift', packagePath: 'ios', buildSystem: 'native', scratchDirectory: 'IOS/package', moduleDirectory: 'IOS/modules', disableSandbox: true,
    files: ['ios/Tests/CompanionClientTests/TranscriptDetailTests.swift'],
    coverage: 'Actual mobile journal resolves complete linked reasoning after pending chunks, restart and replication; legacy tool/HTML details remain intact.' },
  { id: 'federated-detail-chain', runtime: 'swift', packagePath: 'integration', buildSystem: 'native', scratchDirectory: 'Integration/SwiftPM', moduleDirectory: 'Integration/ModuleCache', disableSandbox: true,
    files: ['integration/Tests/CompanionIntegrationTests/CompanionFederationTests.swift'],
    coverage: 'Federated source archive and legacy v1 remain searchable while derived v2 revisions retain verified retrieval without duplicate search hits.' },
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
      : ['test', '--build-system', contract.buildSystem ?? process.env.WOVENMATTER_SWIFT_BUILD_SYSTEM ?? 'swiftbuild', '--force-resolved-versions',
        ...(contract.disableSandbox ? ['--disable-sandbox'] : []), '--package-path', contract.packagePath ?? 'app',
        '--scratch-path', join(cache, contract.scratchDirectory ?? 'SwiftPM'), ...(args.includes('--skip-build') ? ['--skip-build'] : []), '--filter', filters];
    console.log(`Streaming contract: ${contract.id}`);
    const status = await new Promise(resolve => {
      const child = spawn(command, argv, { cwd: root, stdio: 'inherit', env: { ...process.env,
        CLANG_MODULE_CACHE_PATH: join(cache, contract.moduleDirectory ?? 'ModuleCache'),
        SWIFTPM_MODULECACHE_OVERRIDE: join(cache, contract.moduleDirectory ?? 'ModuleCache') } });
      child.on('error', () => resolve(-1)); child.on('exit', code => resolve(code ?? -1));
    });
    results.push({ id: contract.id, status, elapsedMS: Math.round(performance.now() - start), coverage: contract.coverage });
  }
  const report = { schemaVersion: 1, at: new Date().toISOString(), providerRequests: false, results };
  if (args.includes('--output')) await writeFile(args[args.indexOf('--output') + 1], JSON.stringify(report, null, 2) + '\n');
  console.log(JSON.stringify(report, null, 2));
  process.exitCode = results.every(value => value.status === 0) ? 0 : 1;
}
