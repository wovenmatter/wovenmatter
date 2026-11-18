#if os(macOS)
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RuntimeMaintenanceTests {

    /// Another Mac reads this Mac's harnesses in the shape a Linux host serves.
    @Test func aMacsInventoryReadsLikeALinuxHosts() {
        let inventory = RuntimeInventory(kind: .claudeCode, components: [
            RuntimeComponent(name: "claude-agent-acp", executable: URL(fileURLWithPath: "/private/bin/claude-agent-acp"),
                             installed: "0.9.0", latest: "0.10.0", package: "@agentclientprotocol/claude-agent-acp", required: true, present: true),
            RuntimeComponent(name: "claude CLI", executable: nil, installed: "2.1.0", latest: "2.1.0", package: nil,
                             required: false, present: true),
        ], limitation: nil)
        let row = inventory.maintenance()
        #expect(row.id == .claudeCode && row.displayName == "Claude Code" && row.installed && row.updateAvailable)
        #expect(row.components.map(\.id) == ["runtime", "cli"])
        #expect(row.components[0].availableUpdateVersion == "0.10.0" && row.components[1].availableUpdateVersion == nil)
        // Paths stay on the Mac that has them.
        #expect(row.components.allSatisfy { $0.path == nil })
        let decoded = try? JSONDecoder().decode(RemoteRuntimeMaintenance.self, from: JSONEncoder().encode(row))
        #expect(decoded == row)
    }

    /// Codex chats run the person's own `codex` through codex-acp, so the inventory lists the
    /// adapter, its ACP library and the native CLI, never a Codex bundled in the adapter, and
    /// the CLI has to be at least the engine version the adapter speaks to.
    @Test(arguments: [false, true])
    func codexInventoryUsesTheNativeCLI(cliTooOld: Bool) async throws {
        let definition = try #require(LocalACPRuntimeCatalog.definition(for: .codex))
        let adapterVersion = try #require(definition.minimumAdapterVersion)
        let cliVersion = cliTooOld ? "0.154.0" : try #require(definition.minimumEngineVersion)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = root.appending(path: "lib/node_modules/@agentclientprotocol/codex-acp")
        let sdk = adapter.appending(path: "node_modules/@agentclientprotocol/sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: adapter.appending(path: "dist"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        try Data(#"{"name":"@agentclientprotocol/sdk","version":"2.1.0"}"#.utf8).write(to: sdk.appending(path: "package.json"))
        try JSONSerialization.data(withJSONObject: ["name": "@agentclientprotocol/codex-acp", "version": adapterVersion])
            .write(to: adapter.appending(path: "package.json"))
        let script = adapter.appending(path: "dist/index.js")
        try Data("#!/bin/sh\necho \(adapterVersion)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/codex-acp"), withDestinationURL: script)
        let cli = root.appending(path: "bin/codex")
        try Data("#!/bin/sh\necho \(cliVersion)\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let resolver = LocalACPRuntimeResolver(executableSearchDirectories: [root.appending(path: "bin").path])
        let inventory = await RuntimeMaintenance.inspect(.codex, checkLatest: true, resolver: resolver,
            fetch: { url in
                url == RuntimeMaintenance.codexNativeChannel
                    ? Data(#"{"tag_name":"rust-v99.0.0"}"#.utf8)
                    : Data(#"{"version":"99.0.0","bin":{"cli":"bin.js"}}"#.utf8)
            })
        #expect(inventory.components.map(\.name) == ["codex-acp", "Bundled ACP SDK", "codex CLI"])
        #expect(inventory.isInstalled == !cliTooOld)
        #expect(inventory.components[0].installed == adapterVersion)
        let native = try #require(inventory.components.first { $0.name == RuntimeMaintenance.cliComponentName("codex") })
        #expect(native.installed == cliVersion && native.latest == "99.0.0" && native.outdated)
        #expect(native.executable?.lastPathComponent == "codex")
        #expect(inventory.components.first { $0.package == "@agentclientprotocol/sdk" }?.outdated == true)
        // Offline, a CLI too old for the adapter still reads as needing its update.
        let offline = await RuntimeMaintenance.inspect(.codex, checkLatest: false, resolver: resolver)
        let offlineCLI = try #require(offline.components.last)
        #expect(offlineCLI.outdated == cliTooOld)
        let diagnostic = RuntimeMaintenance.diagnostic(inventory: offline, kind: .codex, attempts: 2, failure: "Verification failed")
        #expect(diagnostic.contains(cliVersion))
        #expect(!diagnostic.contains(root.path))
    }

    /// `claude update` follows Claude Code's native channel, which can trail npm, so its CLI
    /// is compared with that channel and doesn't show an update it can't install.
    @Test func claudeCLIComparesWithItsNativeChannel() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        for name in ["claude-agent-acp", "claude"] {
            let file = root.appending(path: "bin/" + name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let inventory = await RuntimeMaintenance.inspect(.claudeCode, checkLatest: true,
            resolver: LocalACPRuntimeResolver(executableSearchDirectories: [root.appending(path: "bin").path]),
            fetch: { url in
                if url == RuntimeMaintenance.claudeCodeNativeChannel { return Data("2.1.326\n".utf8) }
                return try JSONSerialization.data(withJSONObject: ["versions": ["2.1.327": ["bin": ["claude": "cli.js"]]]])
            }, probe: { _ in "2.1.326 (Claude Code)" })
        let cli = try #require(inventory.components.first { $0.name == RuntimeMaintenance.cliComponentName("claude") })
        #expect(cli.installed == "2.1.326" && cli.latest == "2.1.326" && !cli.outdated)
    }

    @Test func sdkOnlyUpdateIsVisibleWhenConnectorAndEngineAreCurrent() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = root.appending(path: "node_modules/@agentclientprotocol/codex-acp")
        let engine = root.appending(path: "node_modules/@openai/codex")
        let sdk = root.appending(path: "node_modules/@agentclientprotocol/sdk")
        for directory in [adapter, engine.appending(path: "bin"), sdk, root.appending(path: "bin")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for (directory, name, version) in [(adapter, "@agentclientprotocol/codex-acp", "2.7.0"),
            (engine, "@openai/codex", "0.169.1"), (sdk, "@agentclientprotocol/sdk", "2.6.0")] {
            try JSONSerialization.data(withJSONObject: ["name": name, "version": version]).write(to: directory.appending(path: "package.json"))
        }
        let script = adapter.appending(path: "index.js")
        try Data("fixture".utf8).write(to: script)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/codex-acp"), withDestinationURL: script)
        try Data("fixture".utf8).write(to: root.appending(path: "bin/codex"))
        for executable in [script, root.appending(path: "bin/codex")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let binary = engine.appending(path: "bin/codex.js")
        try Data("fixture".utf8).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        let inventory = await RuntimeMaintenance.inspect(.codex, checkLatest: true,
            resolver: LocalACPRuntimeResolver(executableSearchDirectories: [root.appending(path: "bin").path]),
            fetch: { url in
                let version = url.absoluteString.hasSuffix("%2fsdk") ? "2.7.0" : url.absoluteString.contains("codex-acp") ? "2.7.0" : "0.169.1"
                return try JSONSerialization.data(withJSONObject: ["versions": [version: ["bin": ["cli": "index.js"]]]])
            }, probe: { url in url.path.contains("codex-acp") ? "2.7.0" : "0.169.1" })
        #expect(inventory.isInstalled)
        #expect(inventory.components.filter(\.outdated).map(\.name) == ["Bundled ACP SDK"])
        #expect(inventory.updateAvailable)
    }

    @Test func releaseSelectionDoesNotHideNewerStableCLIOrSDKBehindAnOldTag() async throws {
        let metadata = Data(#"{"dist-tags":{"latest":"0.165.0"},"versions":{"0.165.0":{"bin":{"codex":"index.js"}},"0.166.0":{"bin":{"codex":"index.js"}},"0.167.0":{"deprecated":"withdrawn","bin":{"codex":"index.js"}},"1.0.0-beta.1":{"bin":{"codex":"index.js"}}}}"#.utf8)
        let cli = try await RuntimeMaintenance.registryVersion("@openai/codex", fetch: { _ in metadata })
        #expect(cli == "0.166.0")
        let sdk = try await RuntimeMaintenance.registryVersion("@anthropic-ai/claude-agent-sdk", executableRequired: false,
            fetch: { _ in Data(#"{"versions":{"0.3.312":{},"0.3.314":{}}}"#.utf8) })
        #expect(sdk == "0.3.314")
        #expect(LocalACPRuntimeCatalog.definition(for: .codex)?.minimumAdapterVersion == "2.7.0")
        #expect(LocalACPRuntimeCatalog.definition(for: .codex)?.minimumEngineVersion == "0.169.1")
        #expect(LocalACPRuntimeCatalog.definition(for: .claudeCode)?.minimumAdapterVersion == "0.108.0")
        #expect(LocalACPRuntimeCatalog.definition(for: .claudeCode)?.minimumEngineVersion == "0.3.327")
        #expect(LocalACPRuntimeCatalog.definition(for: .codex)?.minimumProtocolSDKVersion == "2.7.0")
        #expect(LocalACPRuntimeCatalog.definition(for: .claudeCode)?.minimumProtocolSDKVersion == "2.7.0")
        #expect(LocalACPRuntimeCatalog.definition(for: .claudeCode)?.cliInstallerArguments == ["latest"])
    }

    @Test func openCodeInventorySeparatesV2CLIFromRegisteredServiceWithoutCopyingCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appending(path: "opencode2")
        try Data("#!/bin/sh\necho 2.0.22\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let registration = root.appending(path: "service.json")
        try JSONSerialization.data(withJSONObject: ["url": "http://127.0.0.1:12345", "pid": 12345, "password": "fixture-secret", "version": "0.0.0-beta-19000"]).write(to: registration)
        let inventory = await RuntimeMaintenance.inspect(.opencode, checkLatest: false,
            resolver: LocalACPRuntimeResolver(executableSearchDirectories: [root.path]),
            selectedOpenCode: cli, openCodeRegistration: registration)
        #expect(inventory.isInstalled)
        #expect(inventory.components[0].installed == "2.0.22")
        #expect(inventory.components[1].installed == "0.0.0-beta-19000")
        #expect(!inventory.components[1].required)
        let prompt = RuntimeMaintenance.diagnostic(inventory: inventory, kind: .opencode, attempts: 2, failure: "Verification failed")
        #expect(!prompt.contains("fixture-secret"))
        #expect(!prompt.contains("12345"))
        #expect(!prompt.contains(root.path))
    }

}
#endif
