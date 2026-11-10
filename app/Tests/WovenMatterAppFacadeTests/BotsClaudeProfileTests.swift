import Foundation
import Testing
@testable import WovenMatterAppFacade

/// Bots on a Mac use the selected Claude subscription account's own native
/// directories, as the default agent does (claude-runtime.mjs profileDirectory).
struct BotsClaudeProfileTests {
    @Test func aSelectedProfileUsesItsOwnDirectoriesAndLegacyKeepsTheOriginal() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "bots-claude-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: home) }
        let root = home.appending(path: ".wovenmatter/default-agent")
        let profile = root.appending(path: "claude-accounts/acct-1")
        for directory in [root.appending(path: "claude-runtime"), profile.appending(path: "claude-runtime"), profile.appending(path: "claude-keychain")] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        #expect(BotsHostAPI.nativeClaude(home: home, profile: "acct-1")
                == .native(configDir: profile.appending(path: "claude-runtime").path, secureStorageDir: profile.appending(path: "claude-keychain").path))
        #expect(BotsHostAPI.nativeClaude(home: home, profile: "legacy") == .native(configDir: root.appending(path: "claude-runtime").path, secureStorageDir: nil))
        #expect(BotsHostAPI.nativeClaude(home: home, profile: nil) == .native(configDir: root.appending(path: "claude-runtime").path, secureStorageDir: nil))
        #expect(BotsHostAPI.nativeClaude(home: home, profile: "../escape") == nil)
        #expect(BotsHostAPI.nativeClaude(home: home, profile: "missing") == nil)
    }
}
