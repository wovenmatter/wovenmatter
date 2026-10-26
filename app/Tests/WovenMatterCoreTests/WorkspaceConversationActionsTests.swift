import WorkspaceFixtures
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
      chat = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "New Codex chat", ownerDeviceID: UUID(),
        fixtureLocation: .init(workspaceID: "device:test", rootPath: root.path, managed: false))
    }
    var location: WorkspaceFolderLocation { .init(workspaceID: "device:test", rootPath: root.path, managed: false) }
    func close() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func chatMenuEditsAndRetainedFilesSurviveReopenTrashAndRestore() async throws {
    let f = try await Fixture(); defer { f.close() }
    let folder = try await f.db.createFolder(name: "Research", location: f.location)
    let original = try #require(try await f.db.workspaceOverview().conversations.first)
    let editRevision = try await f.db.dashboardRevision()
    try await f.db.mutateConversation(id: f.chat, mutation: .setPinned(true))
    try await f.db.mutateConversation(id: f.chat, mutation: .rename("  Review π / 東京  "))
    #expect(try await f.db.moveConversation(id: f.chat, toFolderID: folder))
    let afterEdits = try await WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"))
    let saved = try #require(try await afterEdits.workspaceOverview().conversations.first)
    #expect(saved.isPinned && saved.title == "Review π / 東京" && saved.folderID == folder)
    #expect(saved.lastMessageAt == original.lastMessageAt)
    #expect(try await afterEdits.localACPSession(conversationID: f.chat).title == saved.title)
    #expect(try await afterEdits.dashboardRevision() > editRevision)
    #expect(try await !afterEdits.updateConversationTitleIfCurrent(id: f.chat, expectedTitle: saved.title, title: "Automatic title"))
    try await afterEdits.mutateConversation(id: f.chat, mutation: .setPinned(false))
    #expect(try await afterEdits.moveConversation(id: f.chat, toFolderID: nil))
    let updated = try #require(try await afterEdits.workspaceOverview().conversations.first)
    #expect(!updated.isPinned && updated.folderID == nil)
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
    let other = try await f.db.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Other chat", ownerDeviceID: UUID())
    let unrelated = try await f.db.beginLocalACPRun(conversationID: other, content: "Other private content")
    try await f.db.completeLocalACPRun(runID: unrelated.runID)
    #expect(!String(decoding: try await f.db.conversationExport(id: f.chat, format: .fullRun), as: UTF8.self).contains("Other private content"))
    try await f.db.mutateConversation(id: f.chat, mutation: .moveToTrash)
    let hidden = try await f.db.conversationContent(id: f.chat)
    #expect(hidden.messages.isEmpty && hidden.runs.isEmpty && hidden.attachments.isEmpty && hidden.references.isEmpty)
  }

}

extension WorkspaceConversationActionsTests {
}
