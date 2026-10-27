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

    @Test(arguments: [AgentRuntimeKind.codex, .claudeCode, .grokBuild, .defaultAgent])
    func hostLaunchUsesNativeExecutionAndWorkspacePermission(kind: AgentRuntimeKind) throws {
        let resolved = try RemoteHarnessLaunchResolver.resolve(configuration: host(), runtimeKind: kind,
            processWorkingDirectory: URL(fileURLWithPath: "/private/tmp"), tailnetSSHOptions: { _ in ["TAILNET-FIXTURE"] })
        let wrapped = try #require(resolved.launch.wrappedCommand)
        #expect(wrapped.command.first == "/home/alice/.local/share/wovenmatter/current/bin/wm-exec")
        #expect(!wrapped.command.contains("docker"))
        #expect(!wrapped.command.contains(where: { $0.contains("/opt/wovenmatter") || $0.contains("HOME=/home") }))
        #expect(resolved.workspace.rootURL.path == "/home/alice/projects")
        #expect(resolved.workspace.databasesURL.path == "/home/alice/woven-databases")
        #expect(resolved.launch.arguments.first == "TAILNET-FIXTURE")
        if kind == .codex { #expect(resolved.launch.requestedPermission == "agent-full-access") }
        if kind == .claudeCode || kind == .grokBuild { #expect(resolved.launch.requestedPermission == "bypassPermissions") }
        let regular = try RemoteHarnessLaunchResolver.resolve(configuration: host(mode: .user), runtimeKind: kind,
            processWorkingDirectory: URL(fileURLWithPath: "/private/tmp"), tailnetSSHOptions: { _ in [] })
        #expect(regular.launch.requestedPermission == nil)
    }

    @Test func durableGrokPermissionRemainsAfterHostRelaySubcommand() throws {
        let resolved = try RemoteHarnessLaunchResolver.resolve(configuration: host(), runtimeKind: .grokBuild,
            processWorkingDirectory: URL(fileURLWithPath: "/private/tmp"), durableChannelID: UUID().uuidString,
            tailnetSSHOptions: { _ in [] }).launch
        let wrapped = try #require(resolved.wrappedCommand)
        #expect(wrapped.command[wrapped.harnessArgumentsStartIndex - 1] == "durable-acp")
        let prepared = try LocalACPSessionPermissions.prepareLaunch(resolved)
        #expect(prepared.arguments.last?.contains("'durable-acp' '--permission-mode' 'bypassPermissions'") == true)
    }


    @Test func hostProgressNeverDisplaysInstallerOutput() {
        #expect(RemoteWorkspaceBuildProgress.message("WM_PROGRESS selftest", kind: .host) == "Verifying the Chromium sandbox…")
        #expect(RemoteWorkspaceBuildProgress.message("private output token=secret", kind: .host) == nil)
    }
}
