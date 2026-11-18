import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterAppFacade

/// Harness installs and updates hold only their own harness; workspace-wide changes and
/// account changes to that harness wait for them, and a refused start is reported.
@MainActor struct RemoteHarnessActivityTests {
    private func configured(_ fixture: FacadeFixture) throws -> (RemoteWorkspacesModel, RemoteWorkspaceConfiguration) {
        let remote = fixture.model.remoteWorkspaces
        let workspace = fixture.remote
        let status = try #require(remote.statuses[workspace.id])
        let harnesses = try #require(remote.harnesses[workspace.id])
        let maintenance = try #require(remote.runtimeMaintenance[workspace.id])
        remote.configureFacadeFixture(workspace, status: status, harnesses: harnesses, maintenance: maintenance)
        return (remote, workspace)
    }

    @Test func workspaceWideChangesWaitForHarnessMaintenance() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (remote, workspace) = try configured(fixture)
        remote.setFacadeHarnessActivity(workspace.id, maintaining: [.codex])

        remote.lifecycle(.stop, configuration: workspace)
        #expect(remote.errorMessage == "Wait for harness installs and updates to finish.")
        #expect(!remote.busyWorkspaceIDs.contains(workspace.id))
        remote.delete(workspace, removePersistentData: false)
        #expect(!remote.busyWorkspaceIDs.contains(workspace.id))
        #expect(remote.configuration(id: workspace.id) != nil)
        await #expect(throws: (any Error).self) { try await remote.updateHost(workspace) { _ in } }

        // Removing the account of the harness being updated waits; another harness's doesn't.
        remote.signOutHarness(.codex, configuration: workspace)
        #expect(remote.actionErrors[workspace.id]?[.codex] == "Wait for its install or update to finish.")
        #expect(!remote.busyWorkspaceIDs.contains(workspace.id))
    }

    @Test func aSignInBlocksOnlyItsOwnHarness() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (remote, workspace) = try configured(fixture)
        remote.setFacadeHarnessActivity(workspace.id, maintaining: [], signingIn: .claudeCode, busy: true)
        #expect(remote.harnessMaintenanceBlocker(.claudeCode, in: workspace.id) == "Finish signing in first.")
        #expect(remote.harnessMaintenanceBlocker(.codex, in: workspace.id) == nil)

        // Another change holding the workspace blocks every harness, with a reason.
        remote.setFacadeHarnessActivity(workspace.id, maintaining: [], busy: true)
        #expect(remote.harnessMaintenanceBlocker(.codex, in: workspace.id) != nil)
        remote.setFacadeHarnessActivity(workspace.id, maintaining: [])
        #expect(remote.harnessMaintenanceBlocker(.codex, in: workspace.id) == nil)
    }

    @Test func aRefusedUpdateIsReportedInsteadOfLookingFinished() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let (remote, workspace) = try configured(fixture)
        let claude = try #require(remote.currentHarnesses(for: workspace).first { $0.id == .claudeCode })
        remote.setFacadeHarnessActivity(workspace.id, maintaining: [], signingIn: .claudeCode, busy: true)

        let refused = await remote.startHarnessMaintenance("update", harness: claude, configuration: workspace)
        #expect(refused == "Finish signing in first.")
        #expect(!remote.isMaintaining(.claudeCode, in: workspace.id))
        #expect(remote.actionErrors[workspace.id]?[.claudeCode] == "Finish signing in first.")

        // An update already running is followed, not refused.
        remote.setFacadeHarnessActivity(workspace.id, maintaining: [.claudeCode])
        #expect(await remote.startHarnessMaintenance("update", harness: claude, configuration: workspace) == nil)
    }
}
