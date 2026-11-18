#if os(macOS)
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

/// Claude Code, Codex and Grok Build run the person's one native CLI over ACP; OpenCode is
/// OpenCode 2 on its shared service. Installs use each vendor's official installer and
/// updates each vendor's own command.
struct NativeHarnessTests {
    @Test func eachHarnessUpdatesWithItsVendorsOwnCommand() async throws {
        #expect(RuntimeMaintenance.vendorUpdateArguments(.claudeCode) == ["update"])
        #expect(RuntimeMaintenance.vendorUpdateArguments(.codex) == ["update"])
        #expect(RuntimeMaintenance.vendorUpdateArguments(.grokBuild) == ["update"])
        #expect(RuntimeMaintenance.vendorUpdateArguments(.opencode) == ["upgrade"])
        #expect(RuntimeMaintenance.vendorUpdateArguments(.defaultAgent) == nil)

        let calls = Calls()
        let grok = URL(fileURLWithPath: "/home/someone/.grok/bin/grok")
        try await RuntimeMaintenance.runVendorUpdate(.grokBuild, executable: grok) { executable, arguments, timeout in
            calls.record(executable.path + " " + arguments.joined(separator: " ") + " \(Int(timeout))")
            return LocalACPProcessResult(terminationStatus: 0, stdout: "")
        }
        #expect(calls.values == ["/home/someone/.grok/bin/grok update 600"])
        await #expect(throws: LocalACPRuntimeInstallError.self) {
            try await RuntimeMaintenance.runVendorUpdate(.claudeCode, executable: grok) { _, _, _ in
                LocalACPProcessResult(terminationStatus: 1, stdout: "network down")
            }
        }
    }

    @Test func theLoginShellRunsTheCommandWithoutSplicingIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let tool = root.appending(path: "tool with space")
        try Data("#!/bin/sh\nprintf '%s|' \"$@\"\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        let result = try RuntimeMaintenance.runInLoginShell(tool, ["update", "; touch nope"], timeout: 30)
        #expect(result.succeeded)
        #expect(result.stdout.hasSuffix("update|; touch nope|"))
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "nope").path))
    }

    @Test func nativeCLIsAreFoundWhereTheirOfficialInstallersPutThem() {
        let home = URL(fileURLWithPath: "/home/someone")
        #expect(LocalACPRuntimeResolver.nativeLocation(named: "claude", home: home)?.path == "/home/someone/.local/bin/claude")
        #expect(LocalACPRuntimeResolver.nativeLocation(named: "codex", home: home)?.path == "/home/someone/.local/bin/codex")
        #expect(LocalACPRuntimeResolver.nativeLocation(named: "grok", home: home)?.path == "/home/someone/.grok/bin/grok")
        #expect(LocalACPRuntimeResolver.nativeLocation(named: "opencode", home: home)?.path == "/home/someone/.opencode/bin/opencode")
        #expect(LocalACPRuntimeResolver.nativeLocation(named: "codex-acp", home: home) == nil)
    }

    /// The adapters drive the person's CLI, never a copy bundled inside them.
    @Test(arguments: [AgentRuntimeKind.codex, .claudeCode])
    func adaptersArePointedAtTheNativeCLI(kind: AgentRuntimeKind) throws {
        let definition = try #require(LocalACPRuntimeCatalog.definition(for: kind))
        let cliName = try #require(definition.underlyingCLIName)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for (name, version) in [(definition.commandName, "0.0.1"), (cliName, "9.9.9")] {
            let file = root.appending(path: name)
            try Data("#!/bin/sh\necho \(version)\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let native = root.appending(path: cliName)
        let resolver = LocalACPRuntimeResolver(executableSearchDirectories: [root.path]) { $0 == cliName ? native : nil }
        let resolution = resolver.resolve(runtimeKind: kind)
        let key = try #require(LocalACPRuntimeResolver.adapterCLIEnvironmentKey(kind))
        #expect(key == (kind == .codex ? "CODEX_PATH" : "CLAUDE_CODE_EXECUTABLE"))
        // Any runnable connector is ready; there is no minimum release.
        #expect(resolution.availability.state == .ready)
        #expect(resolution.launchConfiguration?.environment[key] == native.path)
        #expect(LocalACPRuntimeResolver.adapterCLIEnvironmentKey(.grokBuild) == nil)
    }

    /// OpenCode 2 replaces OpenCode 1's `opencode` command, so installing it asks first, and
    /// only when no OpenCode 2 is already there.
    @Test func openCodeOneIsAskedAboutOnlyWithoutOpenCodeTwo() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = root.appending(path: "opencode")
        try Data("#!/bin/sh\necho 1.19.5\n".utf8).write(to: one)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: one.path)
        let resolver = LocalACPRuntimeResolver(executableSearchDirectories: [root.path])
        #expect(OpenCodeServiceLauncher.versionOneToReplace(resolver: resolver, native: nil) == "1.19.5")
        let two = root.appending(path: "opencode2")
        try Data("#!/bin/sh\necho opencode v2.3.0\n".utf8).write(to: two)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: two.path)
        #expect(OpenCodeServiceLauncher.versionOneToReplace(resolver: resolver, native: nil) == nil)
        let empty = LocalACPRuntimeResolver(executableSearchDirectories: [root.appending(path: "none").path])
        #expect(OpenCodeServiceLauncher.versionOneToReplace(resolver: empty, native: nil) == nil)
        #expect(OpenCodeServiceLauncher.replacementNotice(replacing: "1.19.5", on: "Work box").contains("OpenCode 1.19.5 on Work box"))
    }

    /// OpenCode's own `opencode service` command starts the shared service, so OpenCode owns
    /// it and it outlives Woven Matter.
    @Test func openCodeIsInstalledOfficiallyAndItsServiceStartedByOpenCode() throws {
        #expect(OpenCodeServiceLauncher.serviceArguments("start") == ["service", "start"])
        #expect(OpenCodeServiceLauncher.serviceArguments("restart") == ["service", "restart"])
        let definition = OpenCodeServiceLauncher.installDefinition
        #expect(definition.cliInstallerSource == URL(string: "https://opencode.ai/v2/install"))
        #expect(definition.cliInstallerInterpreter == "bash")
        #expect(definition.updateArguments == ["upgrade"])
    }

    @Test func theCatalogNamesOfficialInstallersAndUpdateCommands() throws {
        let catalog = try HarnessCatalog.loadBundled()
        for harness in catalog.harnesses {
            #expect(harness.install.kind == "official-script", "\(harness.id) installs with its vendor's script")
            #expect(harness.install.source.scheme == "https")
            #expect(harness.update?.command.hasPrefix(harness.cliCommand + " ") == true)
        }
    }

    @Test func hostFailureCodesReadPlainly() {
        #expect(RemoteRuntimeFailure.describe("update_timed_out") == "Its update command took too long and was stopped.")
        #expect(RemoteRuntimeFailure.describe("opencode_service_restart_failed").contains("didn't restart"))
        #expect(RemoteRuntimeFailure.describe("Something an older host said.") == "Something an older host said.")
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    func record(_ value: String) { lock.withLock { recorded.append(value) } }
    var values: [String] { lock.withLock { recorded } }
}
#endif
