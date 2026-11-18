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
    /// connector and the native CLI, never a Codex bundled in the connector or the connector's
    /// own libraries. Any runnable CLI counts as installed; a newer one is only an update.
    @Test func codexInventoryUsesTheNativeCLI() async throws {
        let adapterVersion = "2.7.0", cliVersion = "0.100.0"
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
        #expect(inventory.components.map(\.name) == ["codex-acp", "codex CLI"])
        #expect(inventory.isInstalled)
        #expect(inventory.components[0].installed == adapterVersion && inventory.components[0].latest == "99.0.0")
        let native = try #require(inventory.components.first { $0.name == RuntimeMaintenance.cliComponentName("codex") })
        #expect(native.installed == cliVersion && native.latest == "99.0.0" && native.outdated && native.verified)
        #expect(native.executable?.lastPathComponent == "codex")
        // Offline, nothing reads as behind: there is no version to compare with.
        let offline = await RuntimeMaintenance.inspect(.codex, checkLatest: false, resolver: resolver)
        #expect(offline.isInstalled && !offline.updateAvailable)
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

    /// A newer ACP SDK or Claude Agent SDK on npm is the connector's business: with the
    /// connector and the CLI current, nothing is offered.
    @Test(arguments: [AgentRuntimeKind.codex, .claudeCode])
    func connectorLibrariesAreNotTrackedSeparately(kind: AgentRuntimeKind) async throws {
        let definition = try #require(LocalACPRuntimeCatalog.definition(for: kind))
        let cliName = try #require(definition.underlyingCLIName)
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = root.appending(path: "node_modules/" + (definition.adapterPackage ?? ""))
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        for (name, version) in [("@agentclientprotocol/sdk", "2.6.0"), ("@anthropic-ai/claude-agent-sdk", "0.3.1")] {
            let directory = adapter.appending(path: "node_modules/" + name)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["name": name, "version": version]).write(to: directory.appending(path: "package.json"))
        }
        try JSONSerialization.data(withJSONObject: ["name": definition.adapterPackage ?? "", "version": "1.0.0"])
            .write(to: adapter.appending(path: "package.json"))
        let script = adapter.appending(path: "index.js")
        try Data("fixture".utf8).write(to: script)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/" + definition.commandName), withDestinationURL: script)
        try Data("fixture".utf8).write(to: root.appending(path: "bin/" + cliName))
        for executable in [script, root.appending(path: "bin/" + cliName)] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let inventory = await RuntimeMaintenance.inspect(kind, checkLatest: true,
            resolver: LocalACPRuntimeResolver(executableSearchDirectories: [root.appending(path: "bin").path]),
            fetch: { url in
                if url == RuntimeMaintenance.codexNativeChannel { return Data(#"{"tag_name":"rust-v2.0.0"}"#.utf8) }
                if url == RuntimeMaintenance.claudeCodeNativeChannel { return Data("2.0.0\n".utf8) }
                let version = url.absoluteString.contains("acp") ? "1.0.0" : "9.0.0"
                return try JSONSerialization.data(withJSONObject: ["versions": [version: ["bin": ["cli": "index.js"]]]])
            }, probe: { url in url.lastPathComponent == definition.commandName ? "1.0.0" : "2.0.0" })
        #expect(inventory.components.map(\.name) == [definition.commandName, RuntimeMaintenance.cliComponentName(cliName)])
        #expect(inventory.isInstalled)
        #expect(!inventory.updateAvailable)
    }

    /// The catalog names no connector, CLI or SDK minimums, and nothing needs them.
    @Test func theCatalogCarriesNoVersionGates() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "../../../harnesses/catalog.json").standardizedFileURL
        let document = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let harnesses = try #require(document["harnesses"] as? [[String: Any]])
        for harness in harnesses {
            #expect(harness.keys.filter { $0.lowercased().contains("minimum") }.isEmpty, "\(harness["id"] ?? "")")
        }
        let catalog = try HarnessCatalog.load(from: url)
        #expect(catalog.harnesses.filter { $0.adapterPackage != nil }.map(\.id) == [.codex, .claudeCode])
    }

    @Test func releaseSelectionDoesNotHideNewerStableCLIOrSDKBehindAnOldTag() async throws {
        let metadata = Data(#"{"dist-tags":{"latest":"0.165.0"},"versions":{"0.165.0":{"bin":{"codex":"index.js"}},"0.166.0":{"bin":{"codex":"index.js"}},"0.167.0":{"deprecated":"withdrawn","bin":{"codex":"index.js"}},"1.0.0-beta.1":{"bin":{"codex":"index.js"}}}}"#.utf8)
        let cli = try await RuntimeMaintenance.registryVersion("@openai/codex", fetch: { _ in metadata })
        #expect(cli == "0.166.0")
        let sdk = try await RuntimeMaintenance.registryVersion("@anthropic-ai/claude-agent-sdk", executableRequired: false,
            fetch: { _ in Data(#"{"versions":{"0.3.312":{},"0.3.314":{}}}"#.utf8) })
        #expect(sdk == "0.3.314")
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
