import Foundation
import WovenMatterCore

/// The app-owned stdio adapter provisions native hooks; it never changes prompt text.
public enum NativeCLIAdapter {
    public static func installOpenCode() async throws {
        guard let resources = Bundle.main.resourceURL else { return }
        let node = resources.appending(path: "default-agent/bin/node")
        let installer = resources.appending(path: "harnesses/cli/install.mjs")
        guard FileManager.default.isExecutableFile(atPath: node.path), FileManager.default.fileExists(atPath: installer.path) else { return }
        let result = try await Task.detached {
            try LocalACPProcessRunner.run(executableURL: node, arguments: [installer.path, "opencode"])
        }.value
        guard result.succeeded else { throw OpenCodeError.message("Could not prepare the Woven Matter CLI integration for OpenCode.") }
    }

    public static func command(launch: LocalACPRuntimeLaunchConfiguration, arguments: [String]) -> [String] {
        let native = [launch.executableURL.path] + arguments
        guard launch.wrappedCommand == nil,
              [.codex, .claudeCode, .cursor, .grokBuild, .pi].contains(launch.runtimeKind),
              let resources = Bundle.main.resourceURL else { return native }
        let node = resources.appending(path: "default-agent/bin/node")
        let adapter = resources.appending(path: "harnesses/cli/adapter.mjs")
        guard FileManager.default.isExecutableFile(atPath: node.path),
              FileManager.default.fileExists(atPath: adapter.path) else { return native }
        return [node.path, adapter.path, launch.runtimeKind.rawValue] + native
    }
}
