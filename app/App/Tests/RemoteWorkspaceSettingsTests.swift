@testable import WovenMatterAppFacade
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore

@MainActor
struct RemoteWorkspaceSettingsTests {

    @Test func remoteSetupPersistsUntilDismissedAndDoesNotEnrollExistingWorkspaces() throws {
        let suite = "remote-setup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = RemoteWorkspaceConfiguration(name: "Fixture", workspaceID: "fixture", hostName: "fixture.invalid")
        defaults.set(try JSONEncoder().encode([workspace]), forKey: "wovenmatter.remote-workspaces.v1")
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false)
        #expect(model.pendingHarnessSetupIDs.isEmpty)
        model.requestHarnessSetup(UUID())
        #expect(model.pendingHarnessSetupIDs.isEmpty)
        model.requestHarnessSetup(workspace.id)
        let restored = RemoteWorkspacesModel(defaults: defaults, backendProjection: false)
        #expect(restored.pendingHarnessSetupIDs == [workspace.id])
        let projection = RemoteWorkspacesModel(defaults: defaults, backendProjection: true)
        projection.applyBackendSnapshot(try JSONDecoder().decode(RemoteWorkspacesModel.BackendSnapshot.self,
            from: JSONEncoder().encode(restored.backendSnapshot())))
        #expect(projection.pendingHarnessSetupIDs == [workspace.id])
        restored.dismissHarnessSetup(workspace.id)
        #expect(RemoteWorkspacesModel(defaults: defaults, backendProjection: false).pendingHarnessSetupIDs.isEmpty)
    }

}
