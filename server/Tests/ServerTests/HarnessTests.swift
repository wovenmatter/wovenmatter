import Foundation
import Testing
import WovenProtocol
@testable import WovenServerKit

/// A stand-in npm: `view` names version 1.0.0, `install` writes the adapter
/// package with a command that, like codex-acp, runs the CLI it drives on
/// ACP's initialize and answers as that version only when the CLI ran.
private let fakeNPM = """
import { mkdirSync, readFileSync, writeFileSync, chmodSync } from 'node:fs';
import { join } from 'node:path';
const args = process.argv.slice(2);
if (args[0] === 'view') { console.log('1.0.0'); process.exit(0); }
const prefix = args[args.indexOf('--prefix') + 1];
const [name] = Object.keys(JSON.parse(readFileSync(join(prefix, 'package.json'), 'utf8')).dependencies);
const folder = join(prefix, 'node_modules', name);
mkdirSync(folder, { recursive: true });
writeFileSync(join(folder, 'package.json'), JSON.stringify({ name, version: '1.0.0' }));
mkdirSync(join(prefix, 'node_modules', '.bin'), { recursive: true });
const bin = join(prefix, 'node_modules', '.bin', 'codex-acp');
writeFileSync(bin, `const { spawnSync } = require('node:child_process');
process.stdin.once('data', () => {
  const cli = spawnSync(process.env.CODEX_PATH, ['--version'], { encoding: 'utf8' });
  if (cli.status !== 0) process.stderr.write(cli.stderr);
  process.stdout.write(JSON.stringify(cli.status === 0
    ? { jsonrpc: '2.0', id: 1, result: { protocolVersion: 1, agentInfo: { version: '1.0.0' } } }
    : { jsonrpc: '2.0', id: 1, error: { code: -32603, message: 'Internal error' } }) + '\\\\n');
});`);
chmodSync(bin, 0o755);
"""

@Test(.enabled(if: Resources.node != nil))
func aFreshDataFolderInstallsTheAdapterForAPresentCLIWithoutTouchingTheCLI() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-harness-\(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: folder) }
  let bin = folder.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  let calls = folder.appendingPathComponent("calls")
  // Like a version manager's wrapper (mise), the CLI refuses to run without the
  // person's own HOME, and while `untrusted` is there.
  let home = try #require(ProcessInfo.processInfo.environment["HOME"])
  let untrusted = folder.appendingPathComponent("untrusted")
  try Data().write(to: untrusted)
  let codex = bin.appendingPathComponent("codex")
  try """
    #!/bin/sh
    echo "$*" >> '\(calls.path)'
    if [ "$HOME" != '\(home)' ] || [ -e '\(untrusted.path)' ]; then echo "mise ERROR Config files are not trusted." >&2; exit 1; fi
    echo codex-cli 1.2.3

    """.write(to: codex, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codex.path)
  let npm = folder.appendingPathComponent("npm.mjs")
  try fakeNPM.write(to: npm, atomically: true, encoding: .utf8)

  let runtime = acpHarness(.codex, dataFolder: folder.appendingPathComponent("data"), cliVariable: "CODEX_PATH",
                           npm: [Resources.node!, npm.path], findCLI: { $0 == "codex" ? codex.path : nil }) { _ in false }
  // Listed at once because the CLI is here; the adapter install starts on its own,
  // and its refusal says why, in the CLI's own words.
  let first = await runtime.status()
  #expect(first.installed)
  var status = first
  var deadline = ContinuousClock.now + .seconds(60)
  while status.detail == nil && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(200))
    status = await runtime.status()
  }
  #expect(!status.isReady && status.detail?.contains("mise ERROR Config files are not trusted.") == true, "\(status.detail ?? "")")

  // Once the CLI runs, installing again (the agent page's Retry) clears the refusal.
  try FileManager.default.removeItem(at: untrusted)
  try await runtime.install()
  status = await runtime.status()
  deadline = ContinuousClock.now + .seconds(60)
  while status.adapterInstalled != true && ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(200))
    status = await runtime.status()
  }
  #expect(status.version == "1.2.3")
  #expect(status.isReady && !status.installingAdapter && status.detail == nil, "\(status.detail ?? "")")
  #expect(status.adapterVersion == "1.0.0")
  let ran = (try? String(contentsOf: calls, encoding: .utf8)) ?? ""
  #expect(!ran.contains("update"))
}

@Test func storageIsTheDataFoldersVolume() throws {
  let storage = try machineStorage(FileManager.default.temporaryDirectory)
  #expect(storage.capacityBytes > 0 && storage.availableBytes >= 0 && storage.availableBytes <= storage.capacityBytes)
}

@Test func harnessModelListsAreNewestFirstWithDefaultOnTop() {
  let listed = [("default", "Default (recommended)"), ("claude-opus-4-5-20251101", "Opus 4.5"), ("gpt-6", "GPT-6"),
                ("opus", "Opus 5.5"), ("claude-fable-5-2[1m]", "Fable 5.2"), ("gpt-6.2-sol", "GPT-6.2 Sol"), ("gpt-6.1", "GPT-6.1")]
  let ordered = ModelOrder.newestFirst(listed.map { SessionOption(id: $0.0, name: $0.1) })
  #expect(ordered.map(\.id) == ["default", "gpt-6.2-sol", "gpt-6.1", "gpt-6", "opus", "claude-fable-5-2[1m]", "claude-opus-4-5-20251101"])
}
