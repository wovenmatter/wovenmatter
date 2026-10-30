import CompanionClient
import Foundation
import Testing
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite("Library transfer execution ownership", .serialized)
struct LibraryTransferFacadeTests {
    @Test func retiredCentralKeepsNativeExecutionAndPublishesOnlyItsOwnHistory() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let identity = try await f.database.companionLibraryIdentity()
        let descriptor = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: identity.libraryID,
            ownerDeviceID: identity.hostDeviceID, kind: .mac, name: "Former central", executionDeviceID: identity.hostDeviceID)
        let local = try await f.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Local", ownerDeviceID: UUID())
        let foreign = try await f.createConversation()
        _ = try await f.database.registerCompanionExecutionWorkspace(.init(workspace: descriptor), deviceID: identity.hostDeviceID)
        let sourceNote = try await f.database.createNote(folderID: nil, title: "Native note", content: NoteDocument(blocks: [.richText(.init(text: "Keep this"))]).encoded())
        let replica = try MobileStore(file: f.directory.appending(path: "replica/library.json"), deviceID: identity.hostDeviceID)
        try await replica.apply(f.database.companionSnapshot())
        let bad = CompanionMutation(deviceID: identity.hostDeviceID, kind: .createNote, resourceID: UUID().uuidString.lowercased(), title: "Wrong context", content: "{}")
        await #expect(throws: CompanionAPIError.self) { _ = try await f.database.applyExecutionReplicaProjection(bad, libraryID: identity.libraryID, workspaceID: descriptor.id) }
        try await f.database.retireLibraryAuthority(workspace: descriptor)
        let workspace = try await SecondaryMacExecutionWorkspace(descriptor: descriptor, model: f.model, replica: replica,
            directory: f.directory.appending(path: "projection"), originFile: f.directory.appending(path: "own-journal.json"))
        try await workspace.capture()
        let journal = await workspace.origin.snapshot()
        #expect(journal.conversations[local] != nil)
        #expect(journal.conversations[foreign] == nil)
        #expect(journal.entries.values.allSatisfy { $0.workspaceID == descriptor.id && $0.conversationID != foreign })
        #expect(try await f.database.companionNote(id: sourceNote) != nil)
        #expect(try await f.database.workspaceOverview().conversations.contains { $0.id == local })
    }

    @Test func destinationImportsPendingWritingAndOwnHistoryWithoutAcknowledgingOrRelayingObservers() async throws {
        let f = try await FacadeFixture(); defer { f.remove() }
        let file = f.directory.appending(path: "node/library.json"), replica = try MobileStore(file: file)
        let library = UUID().uuidString.lowercased(), owner = await replica.snapshot().deviceID
        try await replica.bindWorkspace(library); try await replica.journal.bind(libraryID: library)
        try await replica.journal.upsertWorkspace(.init(id: owner, libraryID: library, ownerDeviceID: owner, kind: .mac, name: "Node"))
        let other = UUID().uuidString.lowercased()
        try await replica.journal.upsertWorkspace(.init(id: other, libraryID: library, ownerDeviceID: other, kind: .mac, name: "Observer cache"), pending: false)
        let note = try await replica.createNote(folderID: nil, title: "Offline writing", content: NoteDocument(blocks: [.richText(.init(text: "Saved before transfer"))]).encoded())
        _ = try await replica.journal.append(workspaceID: owner, conversation: .init(id: UUID().uuidString.lowercased(), title: "Own history"))
        let cachedConversation = UUID().uuidString.lowercased()
        let cached = CompanionJournalEntry(eventID: UUID().uuidString.lowercased(), workspaceID: other, originSequence: 1,
            conversationID: cachedConversation, kind: .conversation, conversation: .init(id: cachedConversation, title: "Cached"))
        try await replica.journal.receiveWorkspace(.init(libraryID: library, cursor: 1, entries: [cached]), workspaceID: other)
        let before = await replica.snapshot(), journalBefore = await replica.journal.snapshot()
        let id = UUID().uuidString.lowercased()
        try await LibraryTransferWritingImporter.merge(store: replica, database: f.database, transferID: id)
        try await LibraryTransferWritingImporter.merge(store: replica, database: f.database, transferID: id)
        #expect(try await f.database.companionNote(id: note.id)?.content == note.content)
        let imported = try await f.database.companionJournal(after: 0)
        #expect(!imported.entries.isEmpty && imported.entries.allSatisfy { $0.workspaceID == owner })
        let after = await replica.snapshot(), journalAfter = await replica.journal.snapshot()
        #expect(after == before); #expect(journalAfter == journalBefore)
        let reopened = try MobileStore(file: file)
        #expect(await reopened.snapshot().outbox == before.outbox)
    }
}
