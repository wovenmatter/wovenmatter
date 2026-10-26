@testable import WovenMatterAppFacade
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore

@MainActor
struct RemoteWorkspaceSettingsTests {
    @Test func remoteToolBridgeUsesTheTailnetTransport() throws {
        let arguments = try WovenMCPRemoteBridge.sshArguments(
            destination: "woven@worker",
            command: "docker exec fixture",
            tailnetOptions: { destination in
                #expect(destination == "woven@worker")
                return ["-o", "ProxyCommand=fixture-tailnet-transport"]
            }
        )
        #expect(arguments.starts(with: ["-o", "ProxyCommand=fixture-tailnet-transport", "-T"]))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("ServerAliveInterval=15"))
        #expect(arguments.suffix(2) == ["woven@worker", "docker exec fixture"])
    }

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

    @Test func remoteSetupDefaultsToOnlyPiDurable() {
        var selection = RemoteHarnessSetupSelection()
        #expect(selection.ordered == [.defaultAgent])
        selection.select(.defaultAgent, enabled: false)
        #expect(selection.ordered == [.defaultAgent])
        selection.select(.codex, enabled: true)
        #expect(selection.selected == [.defaultAgent, .codex])
        selection.select(.codex, enabled: false)
        #expect(selection.ordered == [.defaultAgent])
    }

    @Test func remoteAccountLabelsRequireVerifiedAuthentication() throws {
        for (status, label) in [("configured", "Credentials present"), ("verified", "Signed in"),
                                ("required", "Sign-in required"), ("unknown", "Not checked")] {
            let data = try JSONSerialization.data(withJSONObject: [
                "id": AgentRuntimeKind.codex.rawValue, "displayName": "Codex", "transport": "acp",
                "capabilities": [], "state": "ready", "installationStatus": "installed",
                "authenticationStatus": status, "setupMethods": [], "detectedProviders": []
            ])
            let harness = try JSONDecoder().decode(RemoteHarnessStatus.self, from: data)
            #expect(HarnessAccountPresentation.remoteLabel(harness) == label)
        }
    }

}
