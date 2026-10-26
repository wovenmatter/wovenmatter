import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

private final class HostInspectionFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var ready = false
    private var changedPlan = false
    private var fail = false
    private var commands: [String] = []

    func setReady(_ value: Bool) { lock.withLock { ready = value } }
    func changePlan() { lock.withLock { changedPlan = true } }
    func failInspection() { lock.withLock { fail = true } }
    var calls: [String] { lock.withLock { commands } }

    func run(destination: String, command: String) throws -> Data {
        try lock.withLock {
            commands.append(command)
            if fail { throw URLError(.cannotConnectToHost) }
            if command.contains("'status'") {
                return Data(#"{"id":"fixture","name":"Fixture","state":"exited","running":false,"startedAt":"","image":"fixture","memoryBytes":0,"swapBytes":0,"hostPort":7337,"persistentVolume":"fixture","capabilities":{"memory":false,"swap":false},"storageKind":"fixture","hostStorageLow":false,"legacyStorage":false}"#.utf8)
            }
            if command.contains("'prepare'") { ready = true }
            let value: [String: Any] = [
                "ready": ready, "runtime": "docker", "version": ready ? "29.9.2" : "",
                "architecture": "x86_64", "capabilities": ["memory": ready, "swap": ready],
                "limitations": [], "hostStorageLow": false,
                "canPrepare": !ready, "preparationRequired": !ready,
                "preparationActions": ready ? [] : [changedPlan ? "Install Docker." : "Start Docker."],
                "blockingIssues": []
            ]
            return try JSONSerialization.data(withJSONObject: value)
        }
    }
    var client: RemoteWorkspaceSSHClient {
        RemoteWorkspaceSSHClient(runner: { [self] destination, command, _ in
            try run(destination: destination, command: command)
        }, scriptLoader: { Data("fixture".utf8) })
    }
}

@MainActor struct RemoteWorkspaceHostTests {
    @Test func fullRootWorkspaceOverridesOldChatDefaultsAndCalendarPermissionsForEveryFolder() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        var host = fixture.remote
        host.kind = .host; host.accessMode = .fullRoot
        host.dataRoot = "/home/trey/.local/share/wovenmatter"
        host.workspaceRoot = "/home/trey/.local/share/wovenmatter/workspace"
        let status = try #require(fixture.model.remoteWorkspaces.statuses[host.id])
        let harnesses = try #require(fixture.model.remoteWorkspaces.harnesses[host.id])
        let maintenance = try #require(fixture.model.remoteWorkspaces.runtimeMaintenance[host.id])
        fixture.model.remoteWorkspaces.configureCompanionFixture(host, status: status, harnesses: harnesses, maintenance: maintenance)
        let scope = "remote:" + host.id.uuidString.lowercased()
        fixture.model.sessionSelectionPreferences.saveDefaults(.init(permission: "read-only"), harness: "codex", workspace: scope)
        let target = RemoteHarnessChatTarget(configuration: host, harness: try #require(harnesses.first { $0.id == .codex }))
        let folderless = try #require(await fixture.model.createRemoteACPSession(target: target))
        #expect(try await fixture.database.localACPSession(conversationID: folderless).permission == "agent-full-access")
        #expect(await fixture.recorder.configurations.last?.selections.permission == "agent-full-access")
        #expect(try fixture.model.defaultToolWorkingDirectory(workspaceID: host.id) == host.workspaceRoot)
        let calendar = fixture.model.calendarTaskDefaults(runtime: .codex, workspaceID: host.id)
        #expect(calendar.configuration.permission == "agent-full-access")
        #expect(calendar.configuration.usesProductPermissionDefault == false)

        // A previously captured restrictive selection also yields to the
        // workspace policy when an existing chat is recovered.
        fixture.model.sessionSelectionPreferences.stageCalendarSelections(id: folderless, harness: "codex", workspace: scope,
            selections: .init(permission: "read-only"), usesProductPermissionDefault: true)
        try await fixture.model.applyPendingSessionSelections(conversationID: folderless)
        #expect(await fixture.recorder.configurations.last?.selections.permission == "agent-full-access")

        let external = "/home/trey/projects/existing-repository"
        let folderID = try await fixture.store.createFolder(name: "Linked repository", location: .init(workspaceID: scope, rootPath: external, managed: false))
        let linked = try #require(await fixture.model.createRemoteACPSession(target: target, folderID: folderID))
        #expect(try await fixture.database.localACPSession(conversationID: linked).permission == "agent-full-access")
        #expect(await fixture.recorder.configurations.last?.directory == external)
        #expect(try await fixture.model.folderWorkingDirectory(folderID: folderID, workspaceID: host.id).path == external)

        host.accessMode = .user
        fixture.model.remoteWorkspaces.configureCompanionFixture(host, status: status, harnesses: harnesses, maintenance: maintenance)
        #expect(fixture.model.calendarTaskDefaults(runtime: .codex, workspaceID: host.id).configuration.permission == "read-only")
    }

    private func makeModel(_ fixture: HostInspectionFixture) -> RemoteWorkspacesModel {
        let defaults = UserDefaults(suiteName: "host-setup-test-" + UUID().uuidString)!
        return RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: fixture.client)
    }

    private func settled(_ model: RemoteWorkspacesModel) async throws {
        for _ in 0..<300 {
            if !model.isCheckingHost && !model.isCreating { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Host operation did not settle")
    }

    @Test func readinessRequiresTheSameNonemptyHostAndUser() async throws {
        let fixture = HostInspectionFixture(); fixture.setReady(true)
        let model = makeModel(fixture)
        #expect(model.preflight(hostName: "", userName: "") == nil)
        model.checkHost(hostName: "first.invalid", userName: "trey")
        model.checkHost(hostName: "second.invalid", userName: "trey")
        #expect(model.preflight(hostName: "second.invalid", userName: "trey") == nil)
        try await settled(model)
        #expect(model.preflight(hostName: "second.invalid", userName: "trey")?.ready == true)
        #expect(model.preflight(hostName: "first.invalid", userName: "trey") == nil)
        #expect(model.preflight(hostName: "second.invalid", userName: "another") == nil)
        #expect(model.preflight(hostName: "", userName: "") == nil)
        fixture.failInspection()
        model.checkHost(hostName: "second.invalid", userName: "trey")
        #expect(model.preflight(hostName: "second.invalid", userName: "trey") == nil)
        try await settled(model)
        #expect(model.preflight(hostName: "second.invalid", userName: "trey") == nil)
    }

    @Test func nativeReadinessIsBoundToWorkspaceKindAndAccessLevel() async throws {
        let fixture = HostInspectionFixture(); fixture.setReady(true)
        let model = makeModel(fixture)
        model.checkHost(hostName: "native.invalid", userName: "trey", kind: .host, accessMode: .fullRoot)
        try await settled(model)
        #expect(model.preflight(hostName: "native.invalid", userName: "trey", kind: .host, accessMode: .fullRoot)?.ready == true)
        #expect(model.preflight(hostName: "native.invalid", userName: "trey", kind: .host, accessMode: .user) == nil)
        #expect(model.preflight(hostName: "native.invalid", userName: "trey", kind: .container, accessMode: .fullRoot) == nil)
        #expect(fixture.calls.count == 1)
        #expect(fixture.calls.first?.contains("'fullRoot'") == true)
    }

    @Test func nativeWorkspaceCannotBeConfiguredTwiceForTheSameHostAndUser() async throws {
        let fixture = HostInspectionFixture(); fixture.setReady(true)
        let suite = "native-host-duplicate-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let existing = RemoteWorkspaceConfiguration(name: "Native", workspaceID: "native", hostName: "native.invalid", userName: "trey", kind: .host, accessMode: .fullRoot)
        defaults.set(try JSONEncoder().encode([existing]), forKey: "wovenmatter.remote-workspaces.v1")
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: fixture.client)
        model.checkHost(hostName: existing.hostName, userName: "trey", kind: .host, accessMode: .fullRoot)
        try await settled(model)
        model.create(name: "Another", workspaceID: "another", hostName: existing.hostName, userName: "trey",
            port: 7448, memoryLimit: "", swapLimit: "", kind: .host, accessMode: .fullRoot)
        #expect(model.errorMessage?.contains("already configured for this host and user") == true)
        #expect(!model.isCreating && model.workspaces == [existing])
        #expect(fixture.calls.count == 1)
    }

    @Test func hostPreparationRequiresReviewAndNeverCreatesAWorkspace() async throws {
        let fixture = HostInspectionFixture()
        let model = makeModel(fixture)
        let originalWorkspaces = model.workspaces
        model.create(name: "Fixture", workspaceID: "fixture", hostName: "fixture.invalid",
                     userName: "", port: 7337, memoryLimit: "", swapLimit: "")
        #expect(model.errorMessage?.contains("inspect a ready host") == true)
        model.prepareHost(hostName: "fixture.invalid", userName: "")
        #expect(model.pendingHostPreparation == nil)
        #expect(fixture.calls.isEmpty)
        model.checkHost(hostName: "fixture.invalid", userName: "")
        try await settled(model)
        let service = BackendRemoteWorkspaceService(model: model)
        let command = BackendRemoteWorkspaceCommand.prepareHost(hostName: "fixture.invalid", userName: "")
        let decoded = try JSONDecoder().decode(BackendRemoteWorkspaceCommand.self, from: JSONEncoder().encode(command))
        _ = try await service.execute(decoded)
        #expect(model.pendingHostPreparation?.hostName == "fixture.invalid")
        #expect(fixture.calls.count == 1)
        model.authorizeHostPreparation()
        try await settled(model)
        #expect(model.preflight(hostName: "fixture.invalid", userName: "")?.ready == true)
        #expect(fixture.calls.count == 4)
        #expect(fixture.calls.filter { $0.contains("'prepare'") }.count == 1)
        #expect(!fixture.calls.contains { $0.contains("'create'") })
        #expect(model.workspaces == originalWorkspaces)
        #expect(model.pendingHostPreparation == nil)
    }

    @Test func startupChecksConnectionWithoutStartingStoppedWorkspace() async throws {
        let fixture = HostInspectionFixture()
        let suite = "remote-startup-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = RemoteWorkspaceConfiguration(name: "Fixture", workspaceID: "fixture", hostName: "fixture.invalid")
        defaults.set(try JSONEncoder().encode([workspace]), forKey: "wovenmatter.remote-workspaces.v1")
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false, sshClient: fixture.client)
        model.refreshRuntimeMaintenanceAtStartup()
        for _ in 0..<300 {
            if !model.busyWorkspaceIDs.contains(workspace.id) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.statuses[workspace.id]?.running == false)
        #expect(model.errorMessage == nil)
        #expect(fixture.calls.count == 1)
        #expect(fixture.calls.first?.contains("'status'") == true)
        #expect(model.harnesses.isEmpty)
    }

    @Test func changedPreparationPlanRequiresFreshReview() async throws {
        let fixture = HostInspectionFixture()
        let model = makeModel(fixture)
        model.checkHost(hostName: "fixture.invalid", userName: "")
        try await settled(model)
        model.prepareHost(hostName: "fixture.invalid", userName: "")
        fixture.changePlan()
        model.authorizeHostPreparation()
        try await settled(model)
        #expect(!fixture.calls.contains { $0.contains("'prepare'") })
        #expect(model.errorMessage?.contains("requirements changed") == true)
        #expect(model.preflight(hostName: "fixture.invalid", userName: "") == nil)
    }
}
