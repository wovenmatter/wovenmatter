import Foundation
import SQLite3
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Chat menu persistence and exports")
struct WorkspaceConversationActionsTests {
  private struct Fixture {
    let root = FileManager.default.temporaryDirectory.appending(path: "chat-actions-" + UUID().uuidString)
    let db: WorkspaceDatabase
    let chat: String
    init() async throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      db = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
      chat = try await db.createLocalACPSession(runtimeKind: .codex, title: "New Codex chat", ownerDeviceID: UUID())
    }
    func close() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func pinRenameAndMoveSurviveReopening() async throws {
    let f = try await Fixture(); defer { f.close() }
    let folder = try await f.db.createFolder(name: "Research")
    let original = try #require(try await f.db.workspaceOverview().conversations.first)
    let revision = try await f.db.dashboardRevision()
    try await f.db.mutateConversation(id: f.chat, mutation: .setPinned(true))
    try await f.db.mutateConversation(id: f.chat, mutation: .rename("  Review π / 東京  "))
    #expect(try await f.db.moveConversation(id: f.chat, toFolderID: folder))
    let reopened = try await WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"))
    let saved = try #require(try await reopened.workspaceOverview().conversations.first)
    #expect(saved.isPinned && saved.title == "Review π / 東京" && saved.folderID == folder)
    #expect(saved.lastMessageAt == original.lastMessageAt)
    #expect(try await reopened.localACPSession(conversationID: f.chat).title == saved.title)
    #expect(try await reopened.dashboardRevision() > revision)
    #expect(try await !reopened.updateConversationTitleIfCurrent(id: f.chat, expectedTitle: saved.title, title: "Automatic title"))
    try await reopened.mutateConversation(id: f.chat, mutation: .setPinned(false))
    #expect(try await reopened.moveConversation(id: f.chat, toFolderID: nil))
    let updated = try #require(try await reopened.workspaceOverview().conversations.first)
    #expect(!updated.isPinned && updated.folderID == nil)
  }

  @Test func explicitRenameSurvivesOpenCodeSnapshots() async throws {
    let f = try await Fixture(); defer { f.close() }
    let id = try await f.db.createLocalACPSession(runtimeKind: .opencode, title: "Native title", ownerDeviceID: UUID(),
      openCodeAssociation: ("fixture", "native-session"))
    try await f.db.mutateConversation(id: id, mutation: .rename("My name"))
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.info = ["id": "native-session", "title": "Provider title"]
    try await f.db.saveOpenCodeSnapshot(snapshot, conversationID: id)
    #expect(try await f.db.workspaceOverview().conversations.first(where: { $0.id == id })?.title == "My name")
  }

  @Test func trashFencesNativeOpenCodeWorkBeforeTheFirstRun() async throws {
    let f = try await Fixture(); defer { f.close() }
    let id = try await f.db.createLocalACPSession(runtimeKind: .opencode, title: "Native chat", ownerDeviceID: UUID(),
      openCodeAssociation: ("fixture", "native-session"))
    try await f.db.saveOpenCodeSubmission(conversationID: id, id: "pending", payload: [:], status: "sending")
    for status in ["sending", "uncertain"] {
      try await f.db.saveOpenCodeSubmission(conversationID: id, id: "pending", payload: [:], status: status)
      await #expect(throws: WorkspaceConversationActionError.self) {
        try await f.db.mutateConversation(id: id, mutation: .moveToTrash)
      }
    }
    try await f.db.saveOpenCodeSubmission(conversationID: id, id: "pending", payload: [:], status: "rejected")
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.active = true
    try await f.db.saveOpenCodeSnapshot(snapshot, conversationID: id)
    #expect(try await f.db.conversationContent(id: id).runs.isEmpty)
    await #expect(throws: WorkspaceConversationActionError.self) {
      try await f.db.mutateConversation(id: id, mutation: .moveToTrash)
    }
    snapshot.active = false
    try await f.db.saveOpenCodeSnapshot(snapshot, conversationID: id)
    try await f.db.mutateConversation(id: id, mutation: .moveToTrash)
    await #expect(throws: LocalACPSessionDatabaseError.self) {
      try await f.db.saveOpenCodeSubmission(conversationID: id, id: "new", payload: [:], status: "sending")
    }
    // Finishing an existing receipt remains legal even after visibility changes.
    try await f.db.saveOpenCodeSubmission(conversationID: id, id: "pending", payload: [:], status: "rejected")
    try await f.db.mutateConversation(id: id, mutation: .restore)
    #expect(try await f.db.openCodeUncertainSubmissions(conversationID: id).isEmpty)
  }

  @Test func invalidMutationsDoNotChangeTheChat() async throws {
    let f = try await Fixture(); defer { f.close() }
    await #expect(throws: WorkspaceConversationActionError.self) { try await f.db.mutateConversation(id: f.chat, mutation: .rename(" \n\t")) }
    await #expect(throws: WorkspaceConversationActionError.self) { try await f.db.mutateConversation(id: "missing", mutation: .setPinned(true)) }
    await #expect(throws: WorkspaceConversationActionError.self) { try await f.db.mutateConversation(id: f.chat, mutation: .restore) }
    #expect(try await f.db.localACPSession(conversationID: f.chat).title == "New Codex chat")
    let reader = try await WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"), readOnlyProjection: true)
    await #expect(throws: (any Error).self) { try await reader.mutateConversation(id: f.chat, mutation: .setPinned(true)) }
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET desktop_owned = 0 WHERE id = ?", [f.chat])
    } }
    await #expect(throws: WorkspaceConversationActionError.self) { try await f.db.mutateConversation(id: f.chat, mutation: .moveToTrash) }
  }

  @Test func trashRejectsActiveWorkThenRestoresRetainedMessagesAndPin() async throws {
    let f = try await Fixture(); defer { f.close() }
    let folder = try await f.db.createFolder(name: "Saved folder")
    _ = try await f.db.moveConversation(id: f.chat, toFolderID: folder)
    try await f.db.mutateConversation(id: f.chat, mutation: .setPinned(true))
    let run = try await f.db.beginLocalACPRun(conversationID: f.chat, content: "Keep this message")
    for status in ["queued", "accepted", "running", "uncertain"] {
      try await f.db.write { connection in try connection.transaction {
        try connection.toolsExecuteUnlocked("UPDATE dashboard_runs SET status = ? WHERE id = ?", [status, run.runID])
      } }
      await #expect(throws: WorkspaceConversationActionError.self) { try await f.db.mutateConversation(id: f.chat, mutation: .moveToTrash) }
    }
    #expect(try await f.db.trashedConversations().isEmpty)
    // The statuses above exercise Trash admission. Ordinary completion still
    // requires a running owner; remote uncertainty has its own reconciliation.
    try await f.db.write { connection in
      try connection.toolsExecuteUnlocked("UPDATE dashboard_runs SET status='running' WHERE id=?", [run.runID])
    }
    try await f.db.completeLocalACPRun(runID: run.runID)
    try await f.db.mutateConversation(id: f.chat, mutation: .moveToTrash)
    #expect(try await f.db.workspaceOverview().conversations.isEmpty)
    let reopened = try await WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"))
    #expect(try await reopened.trashedConversations().map(\.id) == [f.chat])
    await #expect(throws: WorkspaceConversationActionError.self) { try await reopened.mutateConversation(id: f.chat, mutation: .rename("Hidden")) }
    await #expect(throws: WorkspaceConversationActionError.self) { try await reopened.conversationExport(id: f.chat, format: .messages) }
    await #expect(throws: (any Error).self) { try await reopened.beginLocalACPRun(conversationID: f.chat, content: "Must not run") }
    try await reopened.mutateConversation(id: f.chat, mutation: .restore)
    let restored = try #require(try await reopened.workspaceOverview().conversations.first)
    #expect(restored.isPinned && restored.folderID == folder)
    #expect(try await reopened.conversationContent(id: f.chat).messages.first?.content == "Keep this message")
    try await reopened.mutateConversation(id: f.chat, mutation: .moveToTrash)
    _ = try await reopened.deleteFolder(id: folder)
    try await reopened.mutateConversation(id: f.chat, mutation: .restore)
    #expect(try await reopened.workspaceOverview().conversations.first?.folderID == nil)
  }

  @Test func trashPausesTimersAndCancelsQueuedDeliveriesWithoutResumingOnRestore() async throws {
    let f = try await Fixture(); defer { f.close() }
    let timer = WorkspaceSessionTimer(sessionID: f.chat, instruction: "Follow up", nextFireAt: .distantPast)
    try await f.db.saveSessionTimer(timer, callerID: f.chat)
    let due = try #require(try await f.db.dueSessionTimers().first)
    let deliveryID = try #require(due.pendingDeliveryID)
    _ = try await f.db.reserveToolDelivery(sourceID: f.chat, targetID: f.chat, text: due.instruction, requestID: deliveryID, kind: .timer)
    try await f.db.mutateConversation(id: f.chat, mutation: .moveToTrash)
    #expect(try await f.db.dueSessionTimers().isEmpty)
    #expect(try await f.db.claimToolDelivery(id: deliveryID) == nil)
    try await f.db.mutateConversation(id: f.chat, mutation: .restore)
    #expect(try await f.db.sessionTimers(sessionID: f.chat).first?.isPaused == true)
    #expect(try await f.db.sessionTimers(sessionID: f.chat).first?.pendingDeliveryID == nil)
    #expect(try await f.db.dueSessionTimers().isEmpty)
    #expect(try await f.db.claimToolDelivery(id: deliveryID) == nil)
  }

  @Test func trashRetainsLibraryFilesAcrossCleanupAndRestore() async throws {
    let f = try await Fixture(); defer { f.close() }
    try await f.db.setLibraryLocation(conversationID: f.chat, workspaceName: "Original workspace", root: f.root.path)
    let run = try await f.db.beginLocalACPRun(conversationID: f.chat, content: "Keep the file")
    try await f.db.replaceLocalACPAssistantMessage(runID: run.runID, content: "[Report](./report.txt)")
    try await f.db.completeLocalACPRun(runID: run.runID)
    try await f.db.indexLibraryMessages()
    let item = try #require(try await f.db.libraryItems().first)
    let files = LibraryFileStore(supportDirectory: f.root)
    let bytes = Data("Retained original file".utf8)
    let hash = try files.retain(bytes)
    try await f.db.finishLibraryFile(id: item.id, hash: hash, size: Int64(bytes.count))
    let blob = f.root.appending(path: "library-files/" + hash)
    try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-7200)], ofItemAtPath: blob.path)
    // Simulate upgrading a database that still has the old destructive trash trigger.
    try await f.db.write { connection in try connection.transaction {
      try connection.executeUnlocked("""
        DROP TRIGGER library_trashed_conversation;
        CREATE TRIGGER library_trashed_conversation AFTER UPDATE OF deleted_at ON dashboard_conversations
        WHEN NEW.deleted_at IS NOT NULL BEGIN
          DELETE FROM library_messages WHERE message_id IN (SELECT id FROM dashboard_messages WHERE conversation_id=NEW.id);
          DELETE FROM library_locations WHERE conversation_id=NEW.id;
        END;
        """)
    } }
    let upgraded = try await WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"))
    let revision = try await upgraded.libraryRevision()
    try await upgraded.mutateConversation(id: f.chat, mutation: .moveToTrash)
    #expect(try await f.db.libraryItems().isEmpty)
    #expect(try await f.db.retainedLibraryHashes().contains(hash))
    try await f.db.cleanupLibraryFiles()
    #expect(FileManager.default.fileExists(atPath: blob.path))
    let reopened = try await WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"))
    try await reopened.mutateConversation(id: f.chat, mutation: .restore)
    let restored = try #require(try await reopened.libraryItem(id: item.id))
    #expect(restored.workspaceName == "Original workspace")
    #expect(try await reopened.libraryRoot(conversationID: f.chat) == f.root.path)
    #expect(try Data(contentsOf: files.url(for: restored)) == bytes)
    #expect(try await reopened.libraryRevision() > revision)
  }

  @Test func trashCancelsClaimedUnsentDeliveriesPermanently() async throws {
    let f = try await Fixture(); defer { f.close() }
    let other = try await f.db.createLocalACPSession(runtimeKind: .pi, title: "Sender", ownerDeviceID: UUID())
    let id = UUID().uuidString.lowercased()
    _ = try await f.db.reserveToolDelivery(sourceID: other, targetID: f.chat, text: "Deferred work", requestID: id)
    #expect(try await f.db.claimToolDelivery(id: id) != nil)
    try await f.db.mutateConversation(id: f.chat, mutation: .moveToTrash)
    try await f.db.mutateConversation(id: f.chat, mutation: .restore)
    await #expect(throws: WorkspaceToolError.self) { try await f.db.validateClaimedToolDelivery(id: id) }
    try await f.db.failToolDeliveryAttempt(id: id)
    try await f.db.recoverToolDeliveries()
    #expect(try await f.db.claimToolDelivery(id: id) == nil)
    #expect(try await f.db.sessionDeliveries().first(where: { $0.id == id })?.status == "cancelled")
  }

  @Test func unicodeExportFilenamesFitTheFilesystem() async throws {
    let f = try await Fixture(); defer { f.close() }
    for title in [String(repeating: "🙂", count: 100), String(repeating: "界", count: 100),
                  String(repeating: "a\u{0301}", count: 100)] {
      let filename = WorkspaceConversationExportFormat.fullRun.suggestedFilename(title: title)
      #expect(filename.utf8.count <= 255)
      let file = f.root.appending(path: filename)
      try Data("Export".utf8).write(to: file)
      #expect(try Data(contentsOf: file) == Data("Export".utf8))
    }
  }

  @Test func exportsContainOlderMessagesReferencesAndUntruncatedRunHistory() async throws {
    let f = try await Fixture(); defer { f.close() }
    let reference = AgentMessageReferenceDraft(kind: .note, resourceID: "note", titleSnapshot: "Research note",
      contentSnapshot: "Reference snapshot", revisionSnapshot: "1")
    let run = try await f.db.beginLocalACPRun(conversationID: f.chat, input: .init(text: "Oldest prompt", attachments: [.reference(reference)]))
    try await f.db.replaceLocalACPAssistantMessage(runID: run.runID, content: "Oldest response")
    try await f.db.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: .init(id: "tool", kind: .tool, phase: "completed", title: "Read", content: "Tool output"))
    try await f.db.appendDeviceOwnedGatewayTraceEvent(runID: run.runID, eventName: "agent", sequence: 1,
      eventType: "raw", eventPhase: nil, toolName: nil, content: nil, rawEventJSON: "{\"retained\":true}")
    try await f.db.completeLocalACPRun(runID: run.runID)
    let largePayload = String(repeating: "x", count: 70_000) + " end of history"
    try await f.db.recordHistory(.init(conversationID: f.chat, runID: run.runID, harness: "codex", kind: "wire.in", payload: largePayload))
    try await f.db.write { connection in try connection.transaction {
      for index in 0..<205 {
        try connection.toolsExecuteUnlocked("""
          INSERT INTO dashboard_messages(id,conversation_id,role,content,created_at)
          VALUES(?,?,'user',?,'2099-01-01T00:00:00Z')
          """, ["extra-\(index)", f.chat, "Older window test \(index)"])
        try connection.toolsExecuteUnlocked("""
          INSERT INTO dashboard_runs(id,conversation_id,status,created_at)
          VALUES(?,?,'completed','2099-01-01T00:00:00Z')
          """, ["extra-run-\(index)", f.chat])
      }
    } }
    #expect(try await f.db.conversationHistoryPage(id: f.chat, limit: 200).messages.count == 200)
    let markdown = String(decoding: try await f.db.conversationExport(id: f.chat, format: .messages), as: UTF8.self)
    #expect(markdown.contains("Oldest prompt") && markdown.contains("Oldest response"))
    #expect(markdown.contains("Older window test 204") && markdown.contains("Reference snapshot"))
    #expect(!markdown.contains("Tool output"))
    // A low connection-local bind limit exercises long histories without tens of
    // thousands of fixtures. The handle stays entirely inside its reader job.
    let data = try await f.db.read { connection in
      let statement = try connection.prepareUnlocked("SELECT 1")
      defer { sqlite3_finalize(statement) }
      let handle = sqlite3_db_handle(statement)
      let originalLimit = sqlite3_limit(handle, SQLITE_LIMIT_VARIABLE_NUMBER, 64)
      defer { sqlite3_limit(handle, SQLITE_LIMIT_VARIABLE_NUMBER, originalLimit) }
      return try connection.conversationExport(id: f.chat, format: .fullRun)
    }
    let json = try JSONDecoder().decode(GatewayJSONValue.self, from: data).objectValue
    let content = try #require(json?["content"]?.objectValue)
    #expect(content["messages"]?.arrayValue?.count == 207)
    #expect(content["runs"]?.arrayValue?.count == 206)
    #expect(content["references"]?.arrayValue?.count == 1)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("Tool output") && text.contains("end of history") && text.contains("retained"))
    #expect(json?["schemaVersion"]?.intValue == 1)
    let other = try await f.db.createLocalACPSession(runtimeKind: .pi, title: "Other chat", ownerDeviceID: UUID())
    let unrelated = try await f.db.beginLocalACPRun(conversationID: other, content: "Other private content")
    try await f.db.completeLocalACPRun(runID: unrelated.runID)
    #expect(!String(decoding: try await f.db.conversationExport(id: f.chat, format: .fullRun), as: UTF8.self).contains("Other private content"))
    try await f.db.mutateConversation(id: f.chat, mutation: .moveToTrash)
    let hidden = try await f.db.conversationContent(id: f.chat)
    #expect(hidden.messages.isEmpty && hidden.runs.isEmpty && hidden.attachments.isEmpty && hidden.references.isEmpty)
  }

  @Test func emptyExportsAndFilenamesAreUsable() async throws {
    let f = try await Fixture(); defer { f.close() }
    #expect(String(decoding: try await f.db.conversationExport(id: f.chat, format: .messages), as: UTF8.self) == "# New Codex chat\n")
    let name = WorkspaceConversationExportFormat.fullRun.suggestedFilename(title: "../../A:B\\C\nD")
    #expect(!name.contains("/") && !name.contains(":") && !name.contains("\\") && !name.contains("\n"))
    #expect(name.hasSuffix("-full-run.json"))
    #expect(WorkspaceConversationExportFormat.messages.suggestedFilename(title: " ") == "Chat-messages.md")
    await #expect(throws: WorkspaceConversationActionError.self) { try await f.db.conversationExport(id: "missing", format: .fullRun) }
  }

  @Test func renameRejectsSilentCStringTruncationAndOversizedNames() async throws {
    let f = try await Fixture(); defer { f.close() }
    for title in ["\0Hidden", "Visible\0hidden", String(repeating: "界", count: 1_366)] {
      await #expect(throws: WorkspaceConversationActionError.invalidTitle) {
        try await f.db.mutateConversation(id: f.chat, mutation: .rename(title))
      }
    }
    #expect(try await f.db.localACPSession(conversationID: f.chat).title == "New Codex chat")
  }

  @Test func restoreDoesNotAdoptAFolderThatChangedOwnership() async throws {
    let f = try await Fixture(); defer { f.close() }
    let folder = try await f.db.createFolder(name: "Original")
    _ = try await f.db.moveConversation(id: f.chat, toFolderID: folder)
    try await f.db.mutateConversation(id: f.chat, mutation: .moveToTrash)
    try await f.db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("UPDATE folders SET user_id='someone-else' WHERE id=?", [folder])
    } }
    try await f.db.mutateConversation(id: f.chat, mutation: .restore)
    #expect(try await f.db.workspaceOverview().conversations.first?.folderID == nil)
  }

  @Test func exportBudgetIncludesRawPayloadsBeforeDecodingAndCountsEmptyRows() async throws {
    let f = try await Fixture(); defer { f.close() }
    let run = try await f.db.beginLocalACPRun(conversationID: f.chat, content: "Small message")
    try await f.db.completeLocalACPRun(runID: run.runID)
    let largePayload = String(repeating: "x", count: 16_384)
    for column in ["raw_event_json", "stream_event_json"] {
      try await f.db.write { connection in try connection.transaction {
        try connection.toolsExecuteUnlocked("DELETE FROM dashboard_run_trace_events WHERE conversation_id=?", [f.chat])
        // Deliberately malformed oversized JSON proves the preflight runs first.
        try connection.toolsExecuteUnlocked("INSERT INTO dashboard_run_trace_events(id,run_id,conversation_id,\(column)) VALUES('large',?,?,?)",
          [run.runID, f.chat, largePayload])
      } }
      let messages = try await f.db.read { connection in
        try connection.conversationExport(id: f.chat, format: .messages, budget: .init(maximumBytes: 12_000))
      }
      #expect(String(decoding: messages, as: UTF8.self).contains("Small message"))
      await #expect(throws: WorkspaceExportError.tooLarge) {
        try await f.db.read { connection in
          try connection.conversationExport(id: f.chat, format: .fullRun, budget: .init(maximumBytes: 12_000))
        }
      }
    }
    await #expect(throws: WorkspaceExportError.tooLarge) {
      try await f.db.read { connection in
        try connection.conversationExport(id: f.chat, format: .messages, budget: .init(maximumItems: 1))
      }
    }
    // A refusal leaves the retained snapshot intact.
    #expect(try await f.db.conversationContent(id: f.chat).messages.first?.content == "Small message")
  }

}
