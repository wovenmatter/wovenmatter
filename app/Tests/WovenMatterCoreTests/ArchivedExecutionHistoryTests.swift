import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Retained archived execution history")
struct ArchivedExecutionHistoryTests {
  @Test func oldUnrootedSessionsStayReadableWhileArchivedRootedAndForeignRowsStayHidden() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "retained-history-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let db = try await WorkspaceDatabase(url: root.appending(path: "history.sqlite"))
    let owner = UUID()
    let location = WorkspaceFolderLocation(workspaceID: "device:test", rootPath: root.appending(path: "project").path, managed: false)
    let old = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Retained old chat", ownerDeviceID: owner, fixtureLocation: location)
    let hidden = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Archived current chat", ownerDeviceID: owner, fixtureLocation: location)
    let foreign = try await db.createFixtureLocalACPSession(runtimeKind: .codex, title: "Someone else's chat", ownerDeviceID: owner)
    let run = try await db.beginLocalACPRun(conversationID: old, content: "Preserve this conversation")
    try await db.completeLocalACPRun(runID: run.runID)
    try await db.recordHistory(.init(id: "retained-native", conversationID: old, harness: "pi", kind: "native.message", payload: "Retained native bytes"))
    try await db.write { connection in try connection.transaction {
      try connection.toolsExecuteUnlocked("DELETE FROM session_execution_roots WHERE conversation_id=?", [old])
      try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET is_archived=1 WHERE id IN (?,?,?)", [old,hidden,foreign])
      try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET user_id='foreign-user', desktop_owned=0 WHERE id=?", [foreign])
    } }
    let reopened = try await WorkspaceDatabase(url: root.appending(path: "history.sqlite"))
    let overview = try await reopened.workspaceOverview()
    #expect(overview.conversations.contains(where: { $0.id == old && $0.isArchived }))
    #expect(!overview.conversations.contains(where: { $0.id == hidden || $0.id == foreign }))
    #expect(try await reopened.conversationContent(id: old).messages.first?.content == "Preserve this conversation")
    #expect(try await reopened.conversationHistoryPage(id: old, limit: 20).messages.first?.content == "Preserve this conversation")
    let export = try await reopened.conversationExport(id: old, format: .fullRun)
    #expect(String(decoding: export, as: UTF8.self).contains("Retained native bytes"))
    await #expect(throws: (any Error).self) { try await reopened.lockSessionFolder(id: old) }
    await #expect(throws: (any Error).self) { try await reopened.beginLocalACPRun(conversationID: old, content: "Cannot resume") }
    #expect(try await reopened.conversationContent(id: hidden).messages.isEmpty)
    #expect(try await reopened.conversationContent(id: foreign).messages.isEmpty)
    for retired in [AgentRuntimeKind.pi, .hermes, .cursor, .openclaw] {
      await #expect(throws: LocalACPSessionDatabaseError.runtimeUnavailable) {
        try await reopened.createFixtureLocalACPSession(runtimeKind: retired, title: "Unavailable", ownerDeviceID: owner)
      }
    }
  }
}
