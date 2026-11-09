#if os(macOS)
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RuntimeMaintenanceTests {

    @Test(arguments: [false, true])
    func codexInventoryFindsTheEngineBesideTheLaunchedAdapter(legacyAdapter: Bool) async throws {
        let minimum = try #require(LocalACPRuntimeCatalog.definition(for: .codex)?.minimumAdapterVersion)
        let adapterVersion = legacyAdapter ? "1.13.1" : minimum
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = root.appending(path: "lib/node_modules/@agentclientprotocol/codex-acp")
        let sdk = adapter.appending(path: "node_modules/@agentclientprotocol/sdk")
        try FileManager.default.createDirectory(at: sdk, withIntermediateDirectories: true)
        try Data(#"{"name":"@agentclientprotocol/sdk","version":"2.1.0"}"#.utf8).write(to: sdk.appending(path: "package.json"))
        let engine = adapter.appending(path: "node_modules/@openai/codex")
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: adapter.appending(path: "dist"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: engine.appending(path: "bin"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["name": "@agentclientprotocol/codex-acp", "version": adapterVersion])
            .write(to: adapter.appending(path: "package.json"))
        try Data(#"{"name":"@openai/codex","version":"0.148.0"}"#.utf8).write(to: engine.appending(path: "package.json"))
        try Data("#!/bin/sh\necho 0.148.0\n".utf8).write(to: engine.appending(path: "bin/codex.js"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: engine.appending(path: "bin/codex.js").path)
        let script = adapter.appending(path: "dist/index.js")
        try Data("#!/bin/sh\necho \(adapterVersion)\n".utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/codex-acp"), withDestinationURL: script)
        let cli = root.appending(path: "bin/codex")
        try Data("#!/bin/sh\necho 0.154.0\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let resolver = LocalACPRuntimeResolver(executableSearchDirectories: [root.appending(path: "bin").path])
        let inventory = await RuntimeMaintenance.inspect(.codex, checkLatest: true, resolver: resolver,
            fetch: { _ in Data(#"{"version":"99.0.0","bin":{"cli":"bin.js"}}"#.utf8) })
        #expect(inventory.isInstalled == !legacyAdapter)
        #expect(inventory.components[0].installed == adapterVersion)
        #expect(inventory.components[1].installed == "0.148.0")
        #expect(inventory.components[1].latest == "99.0.0")
        #expect(inventory.components[1].outdated)
        #expect(inventory.components.first { $0.name == "codex (sign-in CLI)" }?.installed == "0.154.0")
        let protocolSDK = try #require(inventory.components.first { $0.package == "@agentclientprotocol/sdk" })
        #expect(protocolSDK.installed == "2.1.0")
        #expect(protocolSDK.outdated)
        #expect(inventory.outdated)
        try FileManager.default.removeItem(at: engine.appending(path: "bin/codex.js"))
        let broken = await RuntimeMaintenance.inspect(.codex, checkLatest: false, resolver: resolver)
        #expect(!broken.isInstalled)
        #expect(broken.components[1].present == false)
        let diagnostic = RuntimeMaintenance.diagnostic(inventory: broken, kind: .codex, attempts: 2, failure: "Verification failed")
        #expect(diagnostic.contains("0.148.0"))
        #expect(diagnostic.contains("0.154.0"))
        #expect(!diagnostic.contains(root.path))
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
        for (directory, name, version) in [(adapter, "@agentclientprotocol/codex-acp", "2.5.0"),
            (engine, "@openai/codex", "0.166.0"), (sdk, "@agentclientprotocol/sdk", "2.1.0")] {
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
                let version = url.absoluteString.hasSuffix("%2fsdk") ? "2.4.0" : url.absoluteString.contains("codex-acp") ? "2.5.0" : "0.166.0"
                return try JSONSerialization.data(withJSONObject: ["versions": [version: ["bin": ["cli": "index.js"]]]])
            }, probe: { url in url.path.contains("codex-acp") ? "2.5.0" : "0.166.0" })
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
        #expect(LocalACPRuntimeCatalog.definition(for: .codex)?.minimumEngineVersion == "0.167.0")
        #expect(LocalACPRuntimeCatalog.definition(for: .claudeCode)?.minimumEngineVersion == "0.3.319")
        #expect(LocalACPRuntimeCatalog.definition(for: .codex)?.minimumProtocolSDKVersion == "2.4.0")
        #expect(LocalACPRuntimeCatalog.definition(for: .claudeCode)?.minimumProtocolSDKVersion == "2.4.0")
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
