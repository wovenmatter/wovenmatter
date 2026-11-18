#if os(macOS)
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

/// Each CLI is compared with the channel its vendor's own installer and update command read,
/// never with npm, which can be a release ahead.
struct VendorChannelTests {
    @Test func eachCLIReadsItsVendorsChannel() async {
        let fetch: RuntimeMaintenance.Fetch = { url in
            switch url {
            case RuntimeMaintenance.codexNativeChannel: Data(#"{"tag_name":"rust-v0.169.1","assets":[]}"#.utf8)
            case RuntimeMaintenance.openCodeNativeChannel: Data(#"{"channel":"latest","version":"2.3.1","metadata":{"package":"@opencode/cli"}}"#.utf8)
            case RuntimeMaintenance.claudeCodeNativeChannel: Data("2.1.326\n".utf8)
            case RuntimeMaintenance.grokNativeChannel: Data("1.0.88\n".utf8)
            default: throw RuntimeMaintenanceError.unavailable
            }
        }
        #expect(await RuntimeMaintenance.vendorChannelVersion(.codex, fetch: fetch) == "0.169.1")
        #expect(await RuntimeMaintenance.vendorChannelVersion(.opencode, fetch: fetch) == "2.3.1")
        #expect(await RuntimeMaintenance.vendorChannelVersion(.claudeCode, fetch: fetch) == "2.1.326")
        #expect(await RuntimeMaintenance.vendorChannelVersion(.grokBuild, fetch: fetch) == "1.0.88")
        #expect(await RuntimeMaintenance.latestVersion(kind: .grokBuild, package: nil, fetch: fetch) == "1.0.88")
    }

    @Test func aChannelOutsideWhatWovenSupportsReadsAsUnknown() async {
        let fetch: RuntimeMaintenance.Fetch = { url in
            url == RuntimeMaintenance.openCodeNativeChannel
                ? Data(#"{"version":"1.14.2"}"#.utf8) : Data(#"{"tag_name":"v9"}"#.utf8)
        }
        #expect(await RuntimeMaintenance.vendorChannelVersion(.opencode, fetch: fetch) == nil)
        #expect(await RuntimeMaintenance.vendorChannelVersion(.codex, fetch: fetch) == nil)
    }

    @Test func codexIsComparedWithItsChannelNotNpm() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
        for name in ["codex-acp", "codex"] {
            let file = root.appending(path: "bin/" + name)
            try Data("#!/bin/sh\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        let inventory = await RuntimeMaintenance.inspect(.codex, checkLatest: true,
            resolver: LocalACPRuntimeResolver(executableSearchDirectories: [root.appending(path: "bin").path]),
            fetch: { url in
                if url == RuntimeMaintenance.codexNativeChannel { return Data(#"{"tag_name":"rust-v0.169.0"}"#.utf8) }
                #expect(!url.absoluteString.contains("@openai%2fcodex"), "Codex's CLI is never compared with npm")
                return try JSONSerialization.data(withJSONObject: ["versions": ["9.9.9": ["bin": ["x": "x.js"]]]])
            }, probe: { url in url.lastPathComponent == "codex" ? "codex-cli 0.169.0" : "9.9.9" })
        let cli = try #require(inventory.components.first { $0.name == RuntimeMaintenance.cliComponentName("codex") })
        #expect(cli.installed == "0.169.0" && cli.latest == "0.169.0" && !cli.outdated)
    }

    /// A current adapter can still need a library-only update, independently of its native CLI.
    @Test func claudesPinnedSDKCanUpdateWithoutANewAdapter() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let adapter = root.appending(path: "node_modules/@agentclientprotocol/claude-agent-acp")
        let sdk = root.appending(path: "node_modules/@anthropic-ai/claude-agent-sdk")
        let protocolSDK = root.appending(path: "node_modules/@agentclientprotocol/sdk")
        for directory in [adapter, sdk, protocolSDK, root.appending(path: "bin")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let definition = try #require(LocalACPRuntimeCatalog.definition(for: .claudeCode))
        let minimum = try #require(definition.minimumEngineVersion)
        for (directory, name, version) in [(adapter, "@agentclientprotocol/claude-agent-acp", "0.108.0"),
            (sdk, "@anthropic-ai/claude-agent-sdk", minimum), (protocolSDK, "@agentclientprotocol/sdk", "2.7.0")] {
            try JSONSerialization.data(withJSONObject: ["name": name, "version": version]).write(to: directory.appending(path: "package.json"))
        }
        let script = adapter.appending(path: "index.js")
        try Data("fixture".utf8).write(to: script)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "bin/claude-agent-acp"), withDestinationURL: script)
        try Data("fixture".utf8).write(to: root.appending(path: "bin/claude"))
        for executable in [script, root.appending(path: "bin/claude")] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        let inventory = await RuntimeMaintenance.inspect(.claudeCode, checkLatest: true,
            resolver: LocalACPRuntimeResolver(executableSearchDirectories: [root.appending(path: "bin").path]),
            fetch: { url in
                if url == RuntimeMaintenance.claudeCodeNativeChannel { return Data("2.1.326\n".utf8) }
                let newest = url.absoluteString.contains("claude-agent-acp") ? "0.108.0"
                    : url.absoluteString.contains("%2fsdk") ? "2.7.0" : "0.9.999"
                return try JSONSerialization.data(withJSONObject: ["versions": [newest: ["bin": ["x": "x.js"]]]])
            }, probe: { url in url.lastPathComponent == "claude" ? "2.1.326 (Claude Code)" : "0.108.0" })
        let row = try #require(inventory.components.first { $0.name == "Bundled @anthropic-ai/claude-agent-sdk" })
        #expect(row.installed == minimum && row.latest == "0.9.999" && row.verified && row.outdated)
        #expect(inventory.updateAvailable)
        #expect(!inventory.latestUnavailable)
        #expect(inventory.isInstalled)
    }
}
#endif
