import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct HermesIntegrationTests {
    @Test func importsKeepDistinctProfilesAndAreAtomicAndIdempotent() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let owner = UUID()
        let firstHome = "/tmp/hermes-profile"
        let secondHome = "/tmp/hermes-profile/profiles/work"
        let identity = HermesGatewayClient.identity(home: firstHome, storedID: "shared-id", imported: true)
        let rows: [HermesValue] = [
            ["id": .number(1), "role": "user", "content": "Question", "timestamp": .number(100)],
            ["id": .number(2), "role": "assistant", "content": "Answer", "timestamp": .number(101)],
            ["id": .number(3), "role": "tool", "content": "Full tool output", "timestamp": .number(102)]
        ]
        let imported = HermesSessionImport(identity: identity, title: "Imported", createdAt: Date(timeIntervalSince1970: 100), messages: rows)
        let id = try database.createLocalACPSession(runtimeKind: .hermes, title: imported.title, ownerDeviceID: owner, createdAt: imported.createdAt, hermesImport: imported)
        let repeated = try database.createLocalACPSession(runtimeKind: .hermes, title: "Repeated", ownerDeviceID: owner, hermesImport: imported)
        #expect(id == repeated)
        #expect(try database.conversationContent(id: id).messages.map(\.content) == ["Question", "Answer", "Full tool output"])
        #expect(try database.localACPSession(conversationID: id).acpSessionID == identity)
        #expect(try database.knownHermesSessionIDs(home: firstHome) == ["shared-id"])
        #expect(try database.knownHermesSessionIDs(home: secondHome).isEmpty)
        let other = HermesSessionImport(identity: HermesGatewayClient.identity(home: secondHome, storedID: "shared-id", imported: true), title: "Other profile", createdAt: imported.createdAt, messages: rows)
        let otherID = try database.createLocalACPSession(runtimeKind: .hermes, title: other.title, ownerDeviceID: owner, hermesImport: other)
        #expect(otherID != id)
        let broken = HermesSessionImport(identity: HermesGatewayClient.identity(home: firstHome, storedID: "invalid", imported: true), title: "Broken", createdAt: imported.createdAt, messages: [rows[0], rows[0]])
        #expect(throws: WorkspaceDatabaseError.corruptRow) {
            try database.createLocalACPSession(runtimeKind: .hermes, title: broken.title, ownerDeviceID: owner, hermesImport: broken)
        }
        #expect(try !database.knownHermesSessionIDs(home: firstHome).contains("invalid"))
        #expect(try database.conversationContent(id: id).messages.count == 3)
        let record = try #require(database.workspaceOverview().conversations.first { $0.id == id })
        let importedAt = try #require(record.importedAt)
        #expect(record.lastMessageAt == importedAt)
        let reopened = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        #expect(try reopened.workspaceOverview().conversations.first { $0.id == id }?.importedAt == importedAt)
        // Old transcript/turn timestamps must not move an imported conversation back down the sidebar.
        let run = try reopened.beginLocalACPRun(conversationID: id, content: "Continue", createdAt: Date(timeIntervalSince1970: 200))
        try reopened.appendLocalACPAssistantChunk(runID: run.runID, chunk: "Reply", updatedAt: Date(timeIntervalSince1970: 201))
        #expect(try reopened.workspaceOverview().conversations.first { $0.id == id }?.lastMessageAt == importedAt)
        // A genuinely newer turn still advances recency without changing import provenance.
        try reopened.replaceLocalACPAssistantMessage(runID: run.runID, content: "Later reply", updatedAt: Date().addingTimeInterval(60))
        let later = try #require(reopened.workspaceOverview().conversations.first { $0.id == id })
        #expect(later.importedAt == importedAt)
        #expect(try #require(later.lastMessageAt) > importedAt)
    }

    @Test func hermesDisplayNameSurvivesCatalogRefresh() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let owner = UUID()
        _ = try database.createLocalACPSession(runtimeKind: .hermes, title: "Chat", ownerDeviceID: owner)
        let agent = try #require(database.dashboardAgents().first { $0.runtimeKind == .hermes })
        try database.renameHermesAgent(id: agent.id, displayName: "  My Hermes  ")
        try database.reconcileLocalCLIAgentCatalog(ownerDeviceID: owner)
        #expect(try database.dashboardAgents().first { $0.id == agent.id }?.displayName == "My Hermes")
        #expect(throws: (any Error).self) { try database.renameHermesAgent(id: UUID(), displayName: "Other") }
    }

    @Test func importingAnAlreadyLinkedNativeConversationDoesNotDuplicateIt() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let owner = UUID(), home = "/tmp/hermes-profile"
        let id = try database.createLocalACPSession(runtimeKind: .hermes, title: "Existing", ownerDeviceID: owner)
        try database.updateLocalACPSessionID(conversationID: id, sessionID: HermesGatewayClient.identity(home: home, storedID: "native"))
        let imported = HermesSessionImport(identity: HermesGatewayClient.identity(home: home, storedID: "native", imported: true), title: "Import", createdAt: Date(), messages: [])
        #expect(try database.createLocalACPSession(runtimeKind: .hermes, title: imported.title, ownerDeviceID: owner, hermesImport: imported) == id)
        #expect(HermesGatewayClient.parseIdentity("legacy-acp-session").storedID == "legacy-acp-session")
        #expect(HermesGatewayClient.parseIdentity("hermes-gateway:invalid:session").storedID.isEmpty)
    }
    @Test func authoritativeFinalTextDoesNotDuplicateOutputBeforeSteering() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let id = try database.createLocalACPSession(runtimeKind: .hermes, title: "Streaming", ownerDeviceID: UUID())
        let run = try database.beginLocalACPRun(conversationID: id, content: "Start")
        let writer = LocalACPAssistantStreamWriter(database: database, runID: run.runID, conversationID: id, onChange: nil)
        try await writer.append("Before steering. ")
        try await writer.finishSegmentAndPause()
        _ = try database.beginLocalACPSteeringTurn(runID: run.runID, content: "Continue")
        await writer.resumeAfterSegmentBoundary()
        try await writer.append("Draft")
        try await writer.replace("Before steering. Final answer")
        try await writer.finish()
        let assistants = try database.conversationContent(id: id).messages.filter { $0.role == "assistant" }.map(\.content)
        #expect(assistants == ["Before steering. ", "Final answer"])
        await #expect(throws: (any Error).self) { try await writer.replace("Changed earlier text") }
        #expect(try database.conversationContent(id: id).messages.filter { $0.role == "assistant" }.map(\.content) == assistants)
    }

}
