import CompanionClient
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@MainActor @Suite(.serialized)
struct SecondaryMacExecutionWorkspaceTests {
    @Test func toolChangesProjectThroughReplicaWithoutOverwritingOfflineEdits() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let libraryID = UUID().uuidString.lowercased()
        let content = try NoteDocument(blocks: [.richText(.init(text: "Original"))]).encoded()
        let note = CompanionNote(id: UUID().uuidString.lowercased(), title: "Shared", content: content, revision: 1)
        try await replica.apply(.init(workspaceID: libraryID, cursor: 0, notes: [note]))
        let owner = await replica.snapshot().deviceID
        let workspace = try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: libraryID,
            ownerDeviceID: owner, kind: .mac, name: "Fixture"), model: fixture.model, replica: replica, directory: fixture.directory)
        #expect(try await fixture.database.companionNote(id: note.id)?.content == content)
        let offlineContent = try NoteDocument(blocks: [.richText(.init(text: "Offline editor"))]).encoded()
        try await replica.editNote(id: note.id, title: note.title, content: offlineContent, folderID: nil, base: note)
        let toolContent = try NoteDocument(blocks: [.richText(.init(text: "Agent writing"))]).encoded()
        let current = try #require(try await fixture.database.companionNote(id: note.id))
        let changed = try await fixture.database.applyCompanionMutation(.init(deviceID: owner, kind: .updateNote,
            resourceID: note.id, expectedRevision: current.revision, title: note.title, content: toolContent))
        #expect(changed.status == .accepted)
        try await workspace.capture()
        let conflict = try #require(await replica.snapshot().conflicts[note.id])
        #expect(conflict.local.content == toolContent)
        #expect(conflict.remote?.content == offlineContent)
        #expect(try await fixture.database.companionNote(id: note.id)?.content == toolContent)
        _ = try await replica.preserveConflictAsCopy(id: note.id)
        try await workspace.capture()
        #expect(await replica.snapshot().conflicts[note.id] == nil)
        #expect(try await fixture.database.companionNote(id: note.id)?.content == offlineContent)
    }

    @Test func toolCreatedFoldersAndNotesUseStableIDsAndDeletionReturnsToReplica() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let libraryID = UUID().uuidString.lowercased()
        try await replica.verifyWorkspace(libraryID)
        let owner = await replica.snapshot().deviceID
        let workspace = try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: libraryID,
            ownerDeviceID: owner, kind: .mac, name: "Fixture"), model: fixture.model, replica: replica, directory: fixture.directory)
        let folder = try await fixture.database.createFolder(name: "Tool folder")
        let content = try NoteDocument(blocks: [.richText(.init(text: "Tool note"))]).encoded()
        let note = try await fixture.database.createNote(folderID: folder, title: "Tool note", content: content)
        try await workspace.capture()
        let projected = await replica.snapshot()
        #expect(projected.folders[folder]?.name == "Tool folder")
        #expect(projected.notes[note]?.folderID == folder)
        #expect(projected.outbox.map(\.mutation.kind) == [.createFolder, .createNote])
        let saved = try #require(try await fixture.database.companionNote(id: note))
        #expect(try await fixture.database.applyCompanionMutation(.init(deviceID: owner, kind: .deleteNote,
            resourceID: note, expectedRevision: saved.revision)).status == .accepted)
        try await workspace.capture()
        #expect(await replica.snapshot().notes[note] == nil)
        #expect(!(await replica.snapshot().outbox.contains { $0.mutation.resourceID == note }))
    }

    @Test func linkedDocumentsProjectWithoutWeakeningNetworkMutationAndStaleDeletionRecovers() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let libraryID = UUID().uuidString.lowercased()
        let content = try NoteDocument(kind: .html, html: "<p>Linked</p>", databaseLink: .init(
            sourceID: "workspace", databaseID: "fixture", relativePath: "data.sqlite")).encoded()
        let note = CompanionNote(id: UUID().uuidString.lowercased(), title: "Linked", content: content, revision: 1)
        try await replica.apply(.init(workspaceID: libraryID, cursor: 0, notes: [note]))
        let owner = await replica.snapshot().deviceID
        let rejected = try await fixture.database.applyCompanionMutation(.init(deviceID: owner, kind: .createNote,
            resourceID: UUID().uuidString.lowercased(), title: note.title, content: content))
        #expect(rejected.status == .invalid)
        let workspace = try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: libraryID,
            ownerDeviceID: owner, kind: .mac, name: "Fixture"), model: fixture.model, replica: replica, directory: fixture.directory)
        let projected = try #require(try await fixture.database.companionNote(id: note.id))
        #expect(projected.content == content)
        _ = try await fixture.database.applyCompanionMutation(.init(deviceID: owner, kind: .deleteNote,
            resourceID: note.id, expectedRevision: projected.revision))
        try await replica.editNote(id: note.id, title: "Newer title", content: content, folderID: nil, base: note)
        try await workspace.capture()
        #expect(await replica.snapshot().notes[note.id]?.title == "Newer title")
        #expect(try await fixture.database.companionNote(id: note.id)?.title == "Newer title")
        let ownLibrary = try await fixture.database.companionWorkspaceID()
        await #expect(throws: (any Error).self) {
            _ = try await fixture.database.applyExecutionReplicaProjection(.init(deviceID: owner, kind: .deleteNote,
                resourceID: note.id, expectedRevision: projected.revision), libraryID: ownLibrary, workspaceID: owner)
        }
    }

    @Test func directCommandsAreIdempotentAndActiveRunsBlockRoleChanges() async throws {
        let fixture = try await FacadeFixture(); defer { fixture.remove() }
        let replica = try MobileStore(file: fixture.directory.appending(path: "client/library.json"))
        let libraryID = UUID().uuidString.lowercased()
        try await replica.verifyWorkspace(libraryID)
        let owner = await replica.snapshot().deviceID
        let workspace = try await SecondaryMacExecutionWorkspace(descriptor: .init(id: owner, libraryID: libraryID,
            ownerDeviceID: owner, kind: .mac, name: "Fixture"), model: fixture.model, replica: replica, directory: fixture.directory)
        let conversation = UUID().uuidString.lowercased()
        let created = try await workspace.command(.init(deviceID: owner, kind: .createSession,
            conversationID: conversation, providerID: "local:codex", workspaceID: owner))
        #expect(created.status == .completed)
        let note = try await replica.createNote(folderID: nil, title: "Context", content: NoteDocument(blocks: [.richText(.init(text: "Bound note"))]).encoded())
        let input = CompanionCommand(deviceID: owner, kind: .send, conversationID: conversation, text: "Exactly once",
            noteID: note.id, noteRevision: note.revision, workspaceID: owner)
        let receipt = try await workspace.command(input)
        #expect(receipt.status == .completed)
        #expect(try await workspace.command(input) == receipt)
        var reused = input; reused.text = "Different request"
        await #expect(throws: (any Error).self) { _ = try await workspace.command(reused) }
        #expect(await fixture.recorder.deliveries.count == 1)
        await #expect(throws: (any Error).self) { try await workspace.prepareToStop() }
        let stopped = try await workspace.command(.init(deviceID: owner, kind: .stop, conversationID: conversation,
            runID: receipt.runID, workspaceID: owner))
        #expect(stopped.status == .completed)
        let nativePayload = String(repeating: "native tool result ", count: 8_000)
        let nativeID = UUID().uuidString.lowercased()
        try await fixture.database.recordHistory(.init(id: nativeID, conversationID: conversation, runID: receipt.runID,
            harness: "codex", kind: "wire.in", payload: nativePayload))
        try await workspace.capture()
        let captured = await workspace.origin.snapshot()
        let parts = captured.entries.values.filter { $0.nativeRecord?.format == "woven-matter-history.v1" }
        let groups = Dictionary(grouping: parts, by: { $0.nativeRecord!.recordID })
        let decoded = try groups.values.map { entries in
            let bytes = entries.sorted { $0.nativeRecord!.partIndex < $1.nativeRecord!.partIndex }.reduce(into: Data()) { $0.append($1.nativeRecord!.data) }
            return try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        }
        #expect(decoded.contains { $0?["id"] as? String == nativeID && $0?["payload"] as? String == nativePayload })
        let recordCount = parts.count
        try await workspace.capture()
        #expect(await workspace.origin.snapshot().entries.values.filter { $0.nativeRecord != nil }.count == recordCount)
        try await workspace.prepareToStop()
        await #expect(throws: (any Error).self) { _ = try await workspace.command(input) }
        let journal = await workspace.origin.snapshot()
        #expect(journal.conversations[conversation]?.workspaceID == owner)
        #expect(journal.entries.values.contains { $0.receipt?.commandID == input.commandID })
    }
}
