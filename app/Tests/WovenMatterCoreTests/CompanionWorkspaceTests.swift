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

  @Test("all metadata remains discoverable above 80 MiB and coalesced changes always progress")
  func boundedLargeLibrary() async throws {
    let fixture = try CompanionFixture(); defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.url)
    let raw = try document(String(repeating: "x", count: 2_200_000))
    let ids = (0..<40).map { _ in UUID().uuidString.lowercased() }
    try await db.write { db in try db.transaction {
      for id in ids {
        try db.companionExecuteUnlocked("INSERT INTO notes(id,user_id,title,content) VALUES (?,'local-operator','Large',?)", values: [id, raw])
      }
    } }
    let snapshot = try await db.companionSnapshot()
    #expect(snapshot.notes.count == 40)
    #expect(snapshot.notes.allSatisfy { !$0.contentIncluded && $0.contentByteCount > 2_000_000 })
    #expect(try JSONEncoder().encode(snapshot).count < 1_024 * 1_024)
    #expect(try await db.companionNote(id: ids[0])?.content == raw)
    try await db.write { db in try db.transaction {
      for index in 0..<410 {
        try db.companionExecuteUnlocked("UPDATE notes SET updated_at = ? WHERE id = ?", values: [String(index), ids[0]])
        if index == 205 { try db.companionExecuteUnlocked("INSERT INTO folders(id,user_id,name) VALUES (?,'local-operator','Independent')", values: [UUID().uuidString.lowercased()]) }
      }
    } }
    var cursor = snapshot.cursor; var seenFolder = false; var pages = 0
    while true {
      let page = try await db.companionChanges(after: cursor, limit: 200)
      #expect(!page.resetRequired && page.cursor > cursor)
      #expect(try JSONEncoder().encode(page).count < 1_024 * 1_024)
      #expect(page.changes.filter { $0.resourceKind == .note }.count <= 1)
      seenFolder = seenFolder || page.changes.contains { $0.resourceKind == .folder }
      cursor = page.cursor; pages += 1
      if !page.hasMore { break }
      #expect(pages < 4)
    }
    #expect(seenFolder && pages == 3)
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

  @Test("recovery copies preserve unknown bytes and history without reviving a tombstone")
  func recoveryCopiesKeepHistory() async throws {
    let fixture = try CompanionFixture(); defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.url)
    let noteID = try await db.createNote(folderID: nil, content: document("Before deletion"))
    #expect(try await db.applyCompanionMutation(CompanionMutation(deviceID: device, kind: .deleteNote,
      resourceID: noteID, expectedRevision: 1)).status == .accepted)
    let raw = #"{"version":99,"kind":"note","future":{"writing":"preserve exact bytes"}}"#
    let recoveredID = try await db.preserveRecoveryCopy(sourceID: noteID, title: "Future document", content: raw, folderID: nil)
    #expect(recoveredID != noteID)
    #expect(try await db.preserveRecoveryCopy(sourceID: noteID, title: "Future document", content: raw, folderID: nil) == recoveredID)
    #expect(try await db.companionNote(id: noteID) == nil)
    #expect(try await db.companionNote(id: recoveredID)?.content == raw)
    let versions = try await db.noteAssetVersions(id: recoveredID)
    #expect(versions.count == 1 && versions[0].content == raw && versions[0].source == "recovered")
    await #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try await db.readNoteForEditing(id: recoveredID) }
  }

  private let device = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

  @Test("phone, desktop autosave and agent edits share integer CAS despite identical timestamps")
  func allWriterCAS() async throws {
    let fixture = try CompanionFixture(); defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.url)
    let noteID = try await db.createNote(folderID: nil, content: document("Base"), createdAt: Date(timeIntervalSince1970: 100))
    let base = try #require(try await db.companionNote(id: noteID))
    let localContent = try document("Desktop writing")
    let operationID = UUID().uuidString.lowercased()
    _ = try await db.persistNoteDraft(id: noteID, title: "Desktop", content: localContent,
                               updatedAt: Date(timeIntervalSince1970: 100), expectedRevision: String(base.revision), operationID: operationID)
    let committed = try #require(try await db.companionDraftRevision(operationID: operationID))
    #expect(committed == "2")
    let phoneContent = try document("Phone writing")
    _ = try await db.applyCompanionMutation(CompanionMutation(deviceID: device, kind: .updateNote, resourceID: noteID, expectedRevision: 2, title: "Phone", content: phoneContent))
    // A delayed desktop completion reads its exact receipt, never the current phone revision.
    #expect(try await db.companionDraftRevision(operationID: operationID) == "2")
    await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
      try await db.persistNoteDraft(id: noteID, title: "New desktop writing", content: document("Retain locally"), expectedRevision: committed)
    }
    await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
      try await db.applyNoteEdits(NoteEditingRequest(command: .apply, noteID: noteID, expectedRevision: "2", operations: [.appendText("Agent", .paragraph)]))
    }
    #expect(try await db.companionNote(id: noteID)?.content == phoneContent)
    // Retrying a committed desktop mutation never overwrites the later phone edit.
    _ = try await db.persistNoteDraft(id: noteID, title: "Desktop", content: localContent, expectedRevision: "1", operationID: operationID)
    #expect(try await db.companionNote(id: noteID)?.content == phoneContent)
    let agent = try await db.applyNoteEdits(NoteEditingRequest(command: .apply, noteID: noteID, expectedRevision: "3", operations: [.appendText("Agent", .paragraph)]))
    #expect(agent.revision == "4")
    // Main's safe append API remains usable without a destructive-write revision.
    let appended = try await db.applyNoteEdits(NoteEditingRequest(command: .apply, noteID: noteID, operations: [.appendText("Safe append", .paragraph)]))
    #expect(appended.revision == "5" && appended.document?.plainText.contains("Safe append") == true)
  }

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

  @Test("current note bindings validate in run acceptance while historical snapshots stay usable")
  func boundRunChecksRevisionAtomically() async throws {
    let fixture = try CompanionFixture(); defer { fixture.remove() }
    let db = try await WorkspaceDatabase(url: fixture.url)
    let conversation = try await db.createLocalACPSession(runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID())
    try await db.setSessionTools(.init(enabled: [.notes]), sessionID: conversation)
    let noteID = try await db.createNote(folderID: nil, title: "Original", content: document("Initial"))
    var binding = AgentNoteContext(noteID: noteID, title: "Original", revision: "1", requireCurrentRevision: true)
    _ = try await db.applyCompanionMutation(CompanionMutation(deviceID: device, kind: .updateNote,
      resourceID: noteID, expectedRevision: 1, title: "Changed", content: document("Changed after discovery")))
    await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
      try await db.beginLocalACPRun(conversationID: conversation, content: "Edit this note", noteContext: binding)
    }
    #expect(try await db.activeRunID(conversationID: conversation) == nil)
    #expect(try fixture.scalar("SELECT count(*) FROM dashboard_messages") == 0)
    #expect(try fixture.scalar("SELECT count(*) FROM dashboard_run_visible_context") == 0)
    binding.revision = "2"
    try await db.setSessionTools(.init(enabled: []), sessionID: conversation)
    await #expect(throws: WorkspaceToolError.disabled(.notes)) {
      try await db.beginLocalACPRun(conversationID: conversation, content: "Permission changed", noteContext: binding)
    }
    #expect(try fixture.scalar("SELECT count(*) FROM dashboard_runs") == 0)
    try await db.setSessionTools(.init(enabled: [.notes]), sessionID: conversation)
    let accepted = try await db.beginLocalACPRun(conversationID: conversation, content: "Current binding", noteContext: binding)
    #expect(try await db.activeRunID(conversationID: conversation) == accepted.runID)
    let historicalConversation = try await db.createLocalACPSession(runtimeKind: .codex, title: "History", ownerDeviceID: UUID())
    let historical = AgentNoteContext(noteID: noteID, title: "Original snapshot", revision: "1")
    let historicalRun = try await db.beginLocalACPRun(conversationID: historicalConversation,
      content: "Discuss an earlier snapshot", noteContext: historical)
    #expect(try await db.activeRunID(conversationID: historicalConversation) == historicalRun.runID)
    let legacyJSON = #"{"noteID":"old-note","title":"Old","revision":"old-revision"}"#
    #expect(try JSONDecoder().decode(AgentNoteContext.self, from: Data(legacyJSON.utf8)).requireCurrentRevision == nil)
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
