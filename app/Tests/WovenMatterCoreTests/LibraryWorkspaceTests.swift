import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

@Suite("Library canonical persistence", .serialized)
struct LibraryWorkspaceTests {

  private let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  @Test("mobile history, desktop drafts and agent restore share revisions and independent receipts")
  func mobileHistoryAndAgentRestore() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let caller = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID())
    try await db.setSessionTools(.init(enabled: [.notes]), sessionID: caller)
    let noteID = UUID().uuidString.lowercased()
    let mobileCreate = LibraryMutation(deviceID: device, kind: .createNote, resourceID: noteID,
      title: "Phone", content: try document("Offline writing"))
    #expect(try await db.applyLibraryMutation(mobileCreate).status == .accepted)
    let first = try await #require(db.noteAssetVersions(id: noteID).first)
    #expect(first.revision == "1" && first.source == "device")
    let draftID = UUID().uuidString.lowercased()
    _ = try await db.persistNoteDraft(id: noteID, title: "Desktop", content: document("Desktop writing"),
      expectedRevision: "1", operationID: draftID)
    let mobileUpdate = LibraryMutation(deviceID: device, kind: .updateNote, resourceID: noteID,
      expectedRevision: 2, title: "Phone again", content: try document("New phone writing"))
    let accepted = try await db.applyLibraryMutation(mobileUpdate)
    #expect(accepted.status == .accepted && accepted.note?.revision == 3)
    let versions = try await db.noteAssetVersions(id: noteID)
    #expect(versions.map(\.revision) == ["3", "2", "1"])
    #expect(versions[1].title == "Desktop" && versions[1].source == "before-device-edit")
    #expect(try await db.workspaceOverview().notes.first(where: { $0.id == noteID })?.revision == "3")
    let restoreID = UUID().uuidString.lowercased()
    let restored = try await db.restoreNoteAssetVersion(noteID: noteID, versionID: first.id,
      expectedRevision: "3", callerConversationID: caller, requestID: restoreID)
    #expect(restored.revision == "4" && restored.title == "Phone")
    let afterRestore = try #require(try await db.libraryNote(id: noteID))
    #expect(afterRestore.revision == 4 && afterRestore.content == mobileCreate.content)
    let stale = LibraryMutation(deviceID: device, kind: .updateNote, resourceID: noteID,
      expectedRevision: 3, title: "Stale", content: try document("Retain locally"))
    #expect(try await db.applyLibraryMutation(stale).status == .conflict)
    let agentRequest = NoteEditingRequest(command: .apply, noteID: noteID,
      expectedRevision: restored.revision, operations: [.setTitle("Agent after restore")])
    let agentID = UUID().uuidString.lowercased()
    let agentResult = try await db.applyNoteEdits(agentRequest, callerConversationID: caller, requestID: agentID)
    #expect(agentResult.revision == "5")
    let reopened = try await fixture.openDatabase()
    #expect(try await reopened.applyLibraryMutation(mobileUpdate) == accepted)
    #expect(try await reopened.libraryDraftRevision(operationID: draftID) == "2")
    let replay = try await reopened.restoreNoteAssetVersion(noteID: noteID, versionID: first.id,
      expectedRevision: "3", callerConversationID: caller, requestID: restoreID)
    #expect(replay.replayed == true && replay.revision == "4" && replay.document == nil)
    #expect(try await reopened.libraryNote(id: noteID)?.title == "Agent after restore")
    #expect(try await reopened.applyNoteEdits(agentRequest, callerConversationID: caller, requestID: agentID).replayed == true)
    try await reopened.setSessionTools(.init(enabled: []), sessionID: caller)
    await #expect(throws: WorkspaceToolError.disabled(.notes)) {
      try await reopened.restoreNoteAssetVersion(noteID: noteID, versionID: first.id,
        expectedRevision: "3", callerConversationID: caller, requestID: restoreID)
    }
  }

  @Test("a Page edited on a phone syncs within the size every writer can still change")
  func phonePagesAreBounded() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let pageID = UUID().uuidString.lowercased()
    func page(_ text: String) throws -> String {
      try NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "a", text: text))], pageNodes: [:]).encoded()
    }
    let create = LibraryMutation(deviceID: device, kind: .createNote, resourceID: pageID, title: "Phone Page", content: try page("From the phone"))
    #expect(try await db.applyLibraryMutation(create).status == .accepted)
    let edit = LibraryMutation(deviceID: device, kind: .updateNote, resourceID: pageID, expectedRevision: 1, title: "Phone Page", content: try page("Edited"))
    #expect(try await db.applyLibraryMutation(edit).status == .accepted)
    let large = try page(String(repeating: "x", count: NoteDocument.maximumBoardBytes))
    #expect(large.utf8.count <= LibraryProtocol.maximumNoteBytes)
    let tooLarge = LibraryMutation(deviceID: device, kind: .updateNote, resourceID: pageID, expectedRevision: 2, title: "Phone Page", content: large)
    let refused = try await db.applyLibraryMutation(tooLarge)
    #expect(refused.status == .invalid && refused.message?.contains("too large") == true)
    let createLarge = LibraryMutation(deviceID: device, kind: .createNote, resourceID: UUID().uuidString.lowercased(), title: "Big", content: large)
    #expect(try await db.applyLibraryMutation(createLarge).status == .invalid)
    #expect(try await db.libraryNote(id: pageID)?.revision == 2)
  }

  @Test("libraries holding the same note versions in different arrival orders agree on the newest and the pruned")
  func noteVersionOrderIsTheSameOnEveryMac() async throws {
    let noteID = UUID().uuidString.lowercased()
    // 60 versions over 30 milliseconds: pairs share a created_at, so the ID decides between them.
    let versions = (0..<60).map { index in
      (id: UUID().uuidString.lowercased(), createdAt: String(format: "2026-11-13T22:18:11.%03dZ", index / 2))
    }
    let newestFirst = versions.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    var kept: [[String]] = []
    for arrival in [versions, versions.reversed(), versions.shuffled()] {
      let fixture = try PersistenceFixture(); defer { fixture.remove() }
      let db = try await fixture.openDatabase()
      try await db.write { connection in
        for version in arrival {
          try connection.toolsExecuteUnlocked("""
            INSERT INTO note_asset_versions(id,note_id,title,content,revision,source,bytes,created_at)
            VALUES(?,?,'Plan','{}','1','device',2,?)
            """, [version.id, noteID, version.createdAt])
        }
        try connection.pruneNoteAssetVersionsUnlocked(noteID: noteID)
      }
      kept.append(try await db.noteAssetVersions(id: noteID).map(\.id))
    }
    #expect(kept[0] == Array(newestFirst.prefix(50).map(\.id)))
    #expect(kept[1] == kept[0] && kept[2] == kept[0])
  }

  private func document(_ text: String) throws -> String {
    try NoteDocument(blocks: [.richText(NoteRichTextBlock(text: text))]).encoded()
  }
}
