import Foundation
import Testing
import WovenMatterClient
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
