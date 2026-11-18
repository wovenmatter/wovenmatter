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
}
#endif
