import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct RemoteHostWorkspaceTests {
    private func host(mode: RemoteWorkspaceAccessMode = .fullRoot) -> RemoteWorkspaceConfiguration {
        .init(name: "Native", workspaceID: "native-fixture", hostName: "host.invalid", userName: "alice",
              kind: .host, accessMode: mode, dataRoot: "/home/alice/.local/share/wovenmatter",
              workspaceRoot: "/home/alice/projects", databasesDirectory: "/home/alice/woven-databases",
              attachmentsDirectory: "/home/alice/woven-attachments")
    }


    @Test func hostCommandsUseDiscoveredPathsAndQuoteEveryArgument() throws {
        let target = RemoteWorkspaceExecTarget(configuration: host())
        #expect(try target.workspaceRoot == "/home/alice/projects")
        #expect(try target.databasesDirectory == "/home/alice/woven-databases")
        #expect(try target.attachmentsDirectory == "/home/alice/woven-attachments")
        let tokens = try target.command(["node", "-e", "console.log('quoted')"],
            workingDirectory: "/home/alice/a project", interactive: true)
        #expect(tokens == ["/home/alice/.local/share/wovenmatter/current/bin/wm-exec",
            "--cwd", "/home/alice/a project", "exec", "node", "-e", "console.log('quoted')"])
        #expect(try target.shellCommand(["printf", "$(not-a-command)"]).contains("'$(not-a-command)'"))
        var invalid = host(); invalid.dataRoot = "/home/alice/../root"
        #expect(throws: RemoteWorkspaceClientError.self) {
            try RemoteWorkspaceExecTarget(configuration: invalid).command(["true"])
        }
        invalid.dataRoot = nil
        #expect(throws: RemoteWorkspaceClientError.self) {
            try RemoteWorkspaceExecTarget(configuration: invalid).command(["true"])
        }
    }

    /// A Full-root host's sessions take its workspace permission; the Mac
    /// names it in `createSession` instead of launching the harness itself.
    @Test(arguments: [AgentRuntimeKind.codex, .claudeCode, .grokBuild])
    func fullRootHostNamesItsWorkspacePermission(kind: AgentRuntimeKind) {
        let expected = kind == .codex ? "agent-full-access" : "bypassPermissions"
        #expect(host().fullRootPermission(for: kind) == expected)
        #expect(host(mode: .user).fullRootPermission(for: kind) == nil)
    }


    @Test func hostProgressNeverDisplaysInstallerOutput() {
        #expect(RemoteWorkspaceBuildProgress.message("WM_PROGRESS selftest") == "Verifying the Chromium sandbox…")
        #expect(RemoteWorkspaceBuildProgress.message("private output token=secret") == nil)
    }
}
