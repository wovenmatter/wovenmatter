import Foundation
import WorkspaceFixtures
import Testing
import WovenMatterClient
@testable import WovenMatterAppFacade

struct WindowPreferenceUpgradeTests {
    /// The Linux hosts saved under the earlier key are still there after the
    /// move, and the model reads them.
    @MainActor @Test func linuxHostsSavedUnderTheEarlierNameMove() throws {
        let suite = TestDefaults.suiteName("window-preferences")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = RemoteWorkspaceConfiguration(name: "Fixture host", workspaceID: "fixture", hostName: "fixture.example.ts.net")
        let saved = try JSONEncoder().encode([host])
        defaults.set(saved, forKey: "wovenmatter.remote-workspaces.v1")
        defaults.set([UUID().uuidString], forKey: "wovenmatter.remote-workspaces.removed.v1")
        let removed = defaults.stringArray(forKey: "wovenmatter.remote-workspaces.removed.v1")

        WindowPreferenceUpgrade.moveRenamedKeys(in: defaults)

        #expect(defaults.data(forKey: RemoteWorkspacesModel.storageKey) == saved)
        #expect(defaults.stringArray(forKey: RemoteWorkspacesModel.removedKey) == removed)
        #expect(defaults.object(forKey: "wovenmatter.remote-workspaces.v1") == nil)
        #expect(defaults.object(forKey: "wovenmatter.remote-workspaces.removed.v1") == nil)
        let model = RemoteWorkspacesModel(defaults: defaults, backendProjection: false)
        #expect(model.workspaces.map(\.id) == [host.id])

        // Moving again changes nothing.
        WindowPreferenceUpgrade.moveRenamedKeys(in: defaults)
        #expect(defaults.data(forKey: RemoteWorkspacesModel.storageKey) == saved)
    }

    @Test func aValueUnderTheCurrentNameWinsAndTheEarlierOneIsRemoved() throws {
        let suite = TestDefaults.suiteName("window-preferences")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let earlier = Data("[\"earlier\"]".utf8), current = Data("[\"current\"]".utf8)
        defaults.set(earlier, forKey: "wovenmatter.remote-workspaces.v1")
        defaults.set(current, forKey: RemoteWorkspacesModel.storageKey)

        WindowPreferenceUpgrade.moveRenamedKeys(in: defaults)

        #expect(defaults.data(forKey: RemoteWorkspacesModel.storageKey) == current)
        #expect(defaults.object(forKey: "wovenmatter.remote-workspaces.v1") == nil)
    }

    @Test func nothingSavedMovesNothing() throws {
        let suite = TestDefaults.suiteName("window-preferences")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        WindowPreferenceUpgrade.moveRenamedKeys(in: defaults)

        #expect(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        for (earlier, current) in WindowPreferenceUpgrade.renamedKeys {
            #expect(defaults.object(forKey: earlier) == nil && defaults.object(forKey: current) == nil)
        }
    }

    /// Every setting that was saved under a name ending in a number moves,
    /// and the cache saved under one is deleted, not moved.
    @Test func everyNumberedNameMovesAndTheNumberedCacheIsDeleted() throws {
        let suite = TestDefaults.suiteName("window-preferences")
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let numbered = [
            "wovenmatter.remote-workspaces.v1": "wovenmatter.remote-workspaces",
            "wovenmatter.remote-workspaces.removed.v1": "wovenmatter.remote-workspaces.removed",
            "wovenmatter.mac-access.v1": "wovenmatter.mac-access",
            "wovenmatter.session-selections.v1": "wovenmatter.session-selections",
            "wovenmatter.analytics.pending-update.v1": "wovenmatter.analytics.pending-update",
            "wovenmatter.default-agent.settings.v1": "wovenmatter.default-agent.settings",
            "wovenmatter.connections.local-servers.v1": "wovenmatter.connections.local-servers",
        ]
        for earlier in numbered.keys { defaults.set(Data(earlier.utf8), forKey: earlier) }
        defaults.set(Data("cached".utf8), forKey: "wovenmatter.built-in.enabled-metadata.v2.WyJsb2NhbCJd")
        defaults.set(["WyJsb2NhbCJd"], forKey: "wovenmatter.built-in.enabled-metadata.v2.index")
        defaults.set(Data("current".utf8), forKey: "wovenmatter.built-in.enabled-metadata.WyJsb2NhbCJd")

        WindowPreferenceUpgrade.moveRenamedKeys(in: defaults)

        for (earlier, current) in numbered {
            #expect(WindowPreferenceUpgrade.renamedKeys[earlier] == current)
            #expect(defaults.data(forKey: current) == Data(earlier.utf8))
            #expect(defaults.object(forKey: earlier) == nil)
        }
        let kept = Set(try #require(defaults.persistentDomain(forName: suite)).keys)
        #expect(kept == Set(numbered.values).union(["wovenmatter.built-in.enabled-metadata.WyJsb2NhbCJd"]))
    }
}
