@testable import WovenMatterAppFacade
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore

@MainActor
struct RemoteWorkspaceSettingsTests {
    @Test func legacyDisabledPreferenceDoesNotGateWorkspaceManagement() throws {
        let suite = "remote-settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "wovenmatter.remote-workspaces.credential-access-enabled")
        let workspace = RemoteWorkspaceConfiguration(name: "Fixture", workspaceID: "fixture", hostName: "fixture.invalid")
        defaults.set(try JSONEncoder().encode([workspace]), forKey: "wovenmatter.remote-workspaces.v1")
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false)
        #expect(model.workspaces == [workspace])

        // Invalid input must reach form validation, without accessing credentials,
        // starting SSH, or requiring an unrelated global enable action.
        model.create(name: "", workspaceID: "", hostName: "", userName: "", port: 7337,
                     memoryLimit: "", swapLimit: "")
        #expect(model.errorMessage == "Enter a name, workspace ID, and SSH hostname.")
        #expect(!model.isCreating)

        let projection = RemoteWorkspacesModel(defaults: defaults, backendProjection: true)
        let snapshot = try JSONDecoder().decode(RemoteWorkspacesModel.BackendSnapshot.self,
            from: JSONEncoder().encode(model.backendSnapshot()))
        projection.applyBackendSnapshot(snapshot)
        #expect(projection.workspaces == [workspace])
    }
}
