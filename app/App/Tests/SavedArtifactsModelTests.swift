import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor
struct SavedArtifactsModelTests {
    @Test func frontendUsesBackendArtifactIdentityAndRevision() async throws {
        let model = SavedArtifactsModel()
        var commands = [BackendLibraryCommand]()
        let expected = URL(fileURLWithPath: "/tmp/prepared-artifact.txt")
        model.configure(service: nil, backendExecutor: { command in
            commands.append(command)
            return .init(url: expected)
        })
        let manifest = CompanionArtifactManifest(id: UUID().uuidString, workspaceID: UUID().uuidString,
            title: "Saved.txt", mediaType: "text/plain", byteCount: 4, sha256: String(repeating: "0", count: 64), revision: 7)
        let item = SavedArtifactLibraryItem(manifest: manifest, workspaceName: "iPhone")
        #expect(await model.prepare(item) == expected)
        #expect(model.preparing.isEmpty)
        let command = try #require(commands.first)
        let decoded = try JSONDecoder().decode(BackendLibraryCommand.self, from: JSONEncoder().encode(command))
        guard case let .openSavedArtifact(id, revision) = decoded else { Issue.record("Expected artifact command"); return }
        #expect(id == manifest.id)
        #expect(revision == 7)
    }
}
