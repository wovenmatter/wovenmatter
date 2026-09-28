import Foundation
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
    init() throws {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      db = try WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
      chat = try db.createLocalACPSession(runtimeKind: .codex, title: "New Codex chat", ownerDeviceID: UUID())
    }
    func close() { try? FileManager.default.removeItem(at: root) }
  }

  @Test func pinRenameAndMoveSurviveReopening() throws {
    let f = try Fixture(); defer { f.close() }
    let folder = try f.db.createFolder(name: "Research")
    let original = try #require(f.db.workspaceOverview().conversations.first)
    let revision = try f.db.dashboardRevision()
    try f.db.mutateConversation(id: f.chat, mutation: .setPinned(true))
    try f.db.mutateConversation(id: f.chat, mutation: .rename("  Review π / 東京  "))
    #expect(try f.db.moveConversation(id: f.chat, toFolderID: folder))
    let reopened = try WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"))
    let saved = try #require(reopened.workspaceOverview().conversations.first)
    #expect(saved.isPinned && saved.title == "Review π / 東京" && saved.folderID == folder)
    #expect(saved.lastMessageAt == original.lastMessageAt)
    #expect(try reopened.localACPSession(conversationID: f.chat).title == saved.title)
    #expect(try reopened.dashboardRevision() > revision)
    #expect(try !reopened.updateConversationTitleIfCurrent(id: f.chat, expectedTitle: saved.title, title: "Automatic title"))
    try reopened.mutateConversation(id: f.chat, mutation: .setPinned(false))
    #expect(try reopened.moveConversation(id: f.chat, toFolderID: nil))
    let updated = try #require(reopened.workspaceOverview().conversations.first)
    #expect(!updated.isPinned && updated.folderID == nil)
  }

  @Test func explicitRenameSurvivesOpenCodeSnapshots() throws {
    let f = try Fixture(); defer { f.close() }
    let id = try f.db.createLocalACPSession(runtimeKind: .opencode, title: "Native title", ownerDeviceID: UUID(),
      openCodeAssociation: ("fixture", "native-session"))
    try f.db.mutateConversation(id: id, mutation: .rename("My name"))
    var snapshot = OpenCodeSessionSnapshot()
    snapshot.info = ["id": "native-session", "title": "Provider title"]
    try f.db.saveOpenCodeSnapshot(snapshot, conversationID: id)
    #expect(try f.db.workspaceOverview().conversations.first(where: { $0.id == id })?.title == "My name")
  }

  @Test func invalidMutationsDoNotChangeTheChat() throws {
    let f = try Fixture(); defer { f.close() }
    #expect(throws: WorkspaceConversationActionError.self) { try f.db.mutateConversation(id: f.chat, mutation: .rename(" \n\t")) }
    #expect(throws: WorkspaceConversationActionError.self) { try f.db.mutateConversation(id: "missing", mutation: .setPinned(true)) }
    #expect(throws: WorkspaceConversationActionError.self) { try f.db.mutateConversation(id: f.chat, mutation: .restore) }
    #expect(try f.db.localACPSession(conversationID: f.chat).title == "New Codex chat")
    let reader = try WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"), readOnlyProjection: true)
    #expect(throws: (any Error).self) { try reader.mutateConversation(id: f.chat, mutation: .setPinned(true)) }
    try f.db.transaction {
      try f.db.toolsExecuteUnlocked("UPDATE dashboard_conversations SET desktop_owned = 0 WHERE id = ?", [f.chat])
    }
    #expect(throws: WorkspaceConversationActionError.self) { try f.db.mutateConversation(id: f.chat, mutation: .moveToTrash) }
  }

  @Test func trashRejectsActiveWorkThenRestoresRetainedMessagesAndPin() throws {
    let f = try Fixture(); defer { f.close() }
    let folder = try f.db.createFolder(name: "Saved folder")
    _ = try f.db.moveConversation(id: f.chat, toFolderID: folder)
    try f.db.mutateConversation(id: f.chat, mutation: .setPinned(true))
    let run = try f.db.beginLocalACPRun(conversationID: f.chat, content: "Keep this message")
    #expect(throws: WorkspaceConversationActionError.self) { try f.db.mutateConversation(id: f.chat, mutation: .moveToTrash) }
    #expect(try f.db.trashedConversations().isEmpty)
    try f.db.completeLocalACPRun(runID: run.runID)
    try f.db.mutateConversation(id: f.chat, mutation: .moveToTrash)
    #expect(try f.db.workspaceOverview().conversations.isEmpty)
    let reopened = try WorkspaceDatabase(url: f.root.appending(path: "workspace.sqlite"))
    #expect(try reopened.trashedConversations().map(\.id) == [f.chat])
    #expect(throws: WorkspaceConversationActionError.self) { try reopened.mutateConversation(id: f.chat, mutation: .rename("Hidden")) }
    #expect(throws: WorkspaceConversationActionError.self) { try reopened.conversationExport(id: f.chat, format: .messages) }
    #expect(throws: (any Error).self) { try reopened.beginLocalACPRun(conversationID: f.chat, content: "Must not run") }
    try reopened.mutateConversation(id: f.chat, mutation: .restore)
    let restored = try #require(reopened.workspaceOverview().conversations.first)
    #expect(restored.isPinned && restored.folderID == folder)
    #expect(try reopened.conversationContent(id: f.chat).messages.first?.content == "Keep this message")
    try reopened.mutateConversation(id: f.chat, mutation: .moveToTrash)
    _ = try reopened.deleteFolder(id: folder)
    try reopened.mutateConversation(id: f.chat, mutation: .restore)
    #expect(try reopened.workspaceOverview().conversations.first?.folderID == nil)
  }

  @Test func trashPausesTimersAndCancelsQueuedDeliveriesWithoutResumingOnRestore() throws {
    let f = try Fixture(); defer { f.close() }
    let timer = WorkspaceSessionTimer(sessionID: f.chat, instruction: "Follow up", nextFireAt: .distantPast)
    try f.db.saveSessionTimer(timer, callerID: f.chat)
    let due = try #require(f.db.dueSessionTimers().first)
    let deliveryID = try #require(due.pendingDeliveryID)
    _ = try f.db.reserveToolDelivery(sourceID: f.chat, targetID: f.chat, text: due.instruction, requestID: deliveryID, kind: .timer)
    try f.db.mutateConversation(id: f.chat, mutation: .moveToTrash)
    #expect(try f.db.dueSessionTimers().isEmpty)
    #expect(try f.db.claimToolDelivery(id: deliveryID) == nil)
    try f.db.mutateConversation(id: f.chat, mutation: .restore)
    #expect(try f.db.sessionTimers(sessionID: f.chat).first?.isPaused == true)
    #expect(try f.db.sessionTimers(sessionID: f.chat).first?.pendingDeliveryID == nil)
    #expect(try f.db.dueSessionTimers().isEmpty)
    #expect(try f.db.claimToolDelivery(id: deliveryID) == nil)
  }

  @Test func exportsContainOlderMessagesReferencesAndUntruncatedRunHistory() throws {
    let f = try Fixture(); defer { f.close() }
    let reference = AgentMessageReferenceDraft(kind: .note, resourceID: "note", titleSnapshot: "Research note",
      contentSnapshot: "Reference snapshot", revisionSnapshot: "1")
    let run = try f.db.beginLocalACPRun(conversationID: f.chat, input: .init(text: "Oldest prompt", attachments: [.reference(reference)]))
    try f.db.replaceLocalACPAssistantMessage(runID: run.runID, content: "Oldest response")
    try f.db.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: .init(id: "tool", kind: .tool, phase: "completed", title: "Read", content: "Tool output"))
    try f.db.appendDeviceOwnedGatewayTraceEvent(runID: run.runID, eventName: "agent", sequence: 1,
      eventType: "raw", eventPhase: nil, toolName: nil, content: nil, rawEventJSON: "{\"retained\":true}")
    try f.db.completeLocalACPRun(runID: run.runID)
    let largePayload = String(repeating: "x", count: 70_000) + " end of history"
    try f.db.recordHistory(.init(conversationID: f.chat, runID: run.runID, harness: "codex", kind: "wire.in", payload: largePayload))
    try f.db.transaction {
      for index in 0..<205 {
        try f.db.toolsExecuteUnlocked("""
          INSERT INTO dashboard_messages(id,conversation_id,role,content,created_at)
          VALUES(?,?,'user',?,'2099-01-01T00:00:00Z')
          """, ["extra-\(index)", f.chat, "Older window test \(index)"])
      }
    }
    #expect(try f.db.conversationHistoryPage(id: f.chat, limit: 200).messages.count == 200)
    let markdown = String(decoding: try f.db.conversationExport(id: f.chat, format: .messages), as: UTF8.self)
    #expect(markdown.contains("Oldest prompt") && markdown.contains("Oldest response"))
    #expect(markdown.contains("Older window test 204") && markdown.contains("Reference snapshot"))
    #expect(!markdown.contains("Tool output"))
    let data = try f.db.conversationExport(id: f.chat, format: .fullRun)
    let json = try JSONDecoder().decode(GatewayJSONValue.self, from: data).objectValue
    let content = try #require(json?["content"]?.objectValue)
    #expect(content["messages"]?.arrayValue?.count == 207)
    #expect(content["runs"]?.arrayValue?.count == 1)
    #expect(content["references"]?.arrayValue?.count == 1)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("Tool output") && text.contains("end of history") && text.contains("retained"))
    #expect(json?["schemaVersion"]?.intValue == 1)
    let other = try f.db.createLocalACPSession(runtimeKind: .pi, title: "Other chat", ownerDeviceID: UUID())
    let unrelated = try f.db.beginLocalACPRun(conversationID: other, content: "Other private content")
    try f.db.completeLocalACPRun(runID: unrelated.runID)
    #expect(!String(decoding: try f.db.conversationExport(id: f.chat, format: .fullRun), as: UTF8.self).contains("Other private content"))
  }

  @Test func emptyExportsAndFilenamesAreUsable() throws {
    let f = try Fixture(); defer { f.close() }
    #expect(String(decoding: try f.db.conversationExport(id: f.chat, format: .messages), as: UTF8.self) == "# New Codex chat\n")
    let name = WorkspaceConversationExportFormat.fullRun.suggestedFilename(title: "../../A:B\\C\nD")
    #expect(!name.contains("/") && !name.contains(":") && !name.contains("\\") && !name.contains("\n"))
    #expect(name.hasSuffix("-full-run.json"))
    #expect(WorkspaceConversationExportFormat.messages.suggestedFilename(title: " ") == "Chat-messages.md")
    #expect(throws: WorkspaceConversationActionError.self) { try f.db.conversationExport(id: "missing", format: .fullRun) }
  }
}
