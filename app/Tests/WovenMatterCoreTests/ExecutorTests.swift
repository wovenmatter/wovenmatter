import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

struct ExecutorTests {
    @Test func appSelectionPreservesToolRevocationDuringScopeSynchronization() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let session = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Scope edit", ownerDeviceID: UUID())
        // The selection request captures its policy, then waits for the server.
        let before = try await database.sessionTools(session)
        #expect(before.enabled.contains(.library))
        _ = try await database.setSessionToolEnabled(.library, enabled: false, sessionID: session)
        try await database.setSessionExecutorProfiles(["app:profile"], sessionID: session)
        let after = try await database.sessionTools(session)
        #expect(!after.enabled.contains(.library))
        #expect(after.executorProfiles == ["app:profile"])
    }
}
