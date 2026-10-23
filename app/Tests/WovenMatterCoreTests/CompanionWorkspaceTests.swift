import Foundation
import SQLite3
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Companion canonical persistence", .serialized)
struct CompanionWorkspaceTests {

  @Test("deletion detaches children, emits tombstones and never resurrects old IDs")
  func deletion() async throws {
    let fixture = try CompanionFixture(); defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.url)
    let folderID = try await db.createFolder(name: "Folder")
    let noteID = try await db.createNote(folderID: folderID, content: document("Writing"))
    let before = try await db.companionSnapshot()
    _ = try await db.deleteFolder(id: folderID)
    let page = try await db.companionChanges(after: before.cursor)
    #expect(page.changes.contains { $0.resourceKind == .folder && $0.resourceID == folderID && $0.operation == .delete })
    #expect(page.changes.contains { $0.note?.id == noteID && $0.note?.folderID == nil })
    let note = try #require(try await db.companionNote(id: noteID))
    _ = try await db.applyCompanionMutation(CompanionMutation(deviceID: device, kind: .deleteNote, resourceID: noteID, expectedRevision: note.revision))
    await #expect(throws: WorkspaceNoteMutationError.noteNotFound) {
      try await db.persistNoteDraft(id: noteID, title: "Recovered", content: document("Unsynced writing"), expectedRevision: String(note.revision))
    }
    #expect(try await db.applyCompanionMutation(CompanionMutation(deviceID: device, kind: .createNote, resourceID: noteID, title: "Accidental resurrection", content: document("No"))).status == .conflict)
    #expect(try await db.companionNote(id: noteID) == nil)
  }

  @Test("local agent table operations are bounded before allocation and unknown documents retain raw bytes")
  func agentFormatBoundary() async throws {
    let fixture = try CompanionFixture(); defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.url)
    let noteID = try await db.createNote(folderID: nil, content: document("Base"))
    await #expect(throws: RemoteNoteEditError.operationNotAllowed) {
      try await db.applyNoteEdits(NoteEditingRequest(command: .apply, noteID: noteID, expectedRevision: "1", operations: [
        .createTable(afterBlockID: nil, rows: 1_000_000, columns: 1_000_000, headerRow: false)
      ]))
    }
    #expect(try await db.companionNote(id: noteID)?.revision == 1)
    let unknown = "{\"version\":99,\"kind\":\"note\",\"future\":{\"writing\":\"preserve me\"}}"
    try await db.write { db in try db.transaction { try db.companionExecuteUnlocked("UPDATE notes SET content = ? WHERE id = ?", values: [unknown, noteID]) } }
    await #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try await db.readNoteForEditing(id: noteID) }
    let result = try await db.applyCompanionMutation(CompanionMutation(deviceID: device, kind: .updateNote, resourceID: noteID, expectedRevision: 2, title: "Overwrite", content: document("Must fail")))
    #expect(result.status == .invalid)
    #expect(try await db.companionNote(id: noteID)?.content == unknown)
  }

  private let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  @Test("mobile history, desktop drafts and agent restore share revisions and independent receipts")
  func mobileHistoryAndAgentRestore() async throws {
    let fixture = try CompanionFixture(); defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.url)
    let caller = try await db.createLocalACPSession(runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID())
    try await db.setSessionTools(.init(enabled: [.notes]), sessionID: caller)
    let noteID = UUID().uuidString.lowercased()
    let mobileCreate = CompanionMutation(deviceID: device, kind: .createNote, resourceID: noteID,
      title: "Phone", content: try document("Offline writing"))
    #expect(try await db.applyCompanionMutation(mobileCreate).status == .accepted)
    let first = try await #require(db.noteAssetVersions(id: noteID).first)
    #expect(first.revision == "1" && first.source == "companion")
    let draftID = UUID().uuidString.lowercased()
    _ = try await db.persistNoteDraft(id: noteID, title: "Desktop", content: document("Desktop writing"),
      expectedRevision: "1", operationID: draftID)
    let mobileUpdate = CompanionMutation(deviceID: device, kind: .updateNote, resourceID: noteID,
      expectedRevision: 2, title: "Phone again", content: try document("New phone writing"))
    let accepted = try await db.applyCompanionMutation(mobileUpdate)
    #expect(accepted.status == .accepted && accepted.note?.revision == 3)
    let versions = try await db.noteAssetVersions(id: noteID)
    #expect(versions.map(\.revision) == ["3", "2", "1"])
    #expect(versions[1].title == "Desktop" && versions[1].source == "before-companion-edit")
    #expect(try await db.workspaceOverview().notes.first(where: { $0.id == noteID })?.revision == "3")
    let restoreID = UUID().uuidString.lowercased()
    let restored = try await db.restoreNoteAssetVersion(noteID: noteID, versionID: first.id,
      expectedRevision: "3", callerConversationID: caller, requestID: restoreID)
    #expect(restored.revision == "4" && restored.title == "Phone")
    let afterRestore = try #require(try await db.companionNote(id: noteID))
    #expect(afterRestore.revision == 4 && afterRestore.content == mobileCreate.content)
    let stale = CompanionMutation(deviceID: device, kind: .updateNote, resourceID: noteID,
      expectedRevision: 3, title: "Stale", content: try document("Retain locally"))
    #expect(try await db.applyCompanionMutation(stale).status == .conflict)
    let agentRequest = NoteEditingRequest(command: .apply, noteID: noteID,
      expectedRevision: restored.revision, operations: [.setTitle("Agent after restore")])
    let agentID = UUID().uuidString.lowercased()
    let agentResult = try await db.applyNoteEdits(agentRequest, callerConversationID: caller, requestID: agentID)
    #expect(agentResult.revision == "5")
    let reopened = try await WorkspaceDatabase(url: fixture.url)
    #expect(try await reopened.applyCompanionMutation(mobileUpdate) == accepted)
    #expect(try await reopened.companionDraftRevision(operationID: draftID) == "2")
    let replay = try await reopened.restoreNoteAssetVersion(noteID: noteID, versionID: first.id,
      expectedRevision: "3", callerConversationID: caller, requestID: restoreID)
    #expect(replay.replayed == true && replay.revision == "4" && replay.document == nil)
    #expect(try await reopened.companionNote(id: noteID)?.title == "Agent after restore")
    #expect(try await reopened.applyNoteEdits(agentRequest, callerConversationID: caller, requestID: agentID).replayed == true)
    try await reopened.setSessionTools(.init(enabled: []), sessionID: caller)
    await #expect(throws: WorkspaceToolError.disabled(.notes)) {
      try await reopened.restoreNoteAssetVersion(noteID: noteID, versionID: first.id,
        expectedRevision: "3", callerConversationID: caller, requestID: restoreID)
    }
  }

  private func document(_ text: String) throws -> String {
    try NoteDocument(blocks: [.richText(NoteRichTextBlock(text: text))]).encoded()
  }
}

private struct CompanionFixture {
  let directory: URL
  var url: URL { directory.appending(path: "workspace.sqlite") }
  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: "companion-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
  func scalar(_ sql: String) throws -> Int64 {
    var db: OpaquePointer?
    guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw WorkspaceDatabaseError.open("fixture") }
    defer { sqlite3_close(db) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw WorkspaceDatabaseError.prepare("fixture") }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw WorkspaceDatabaseError.step("fixture") }
    return sqlite3_column_int64(statement, 0)
  }
}
