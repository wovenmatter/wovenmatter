import WorkspaceFixtures
import Foundation
import SQLite3
import Testing
import WovenMatterClient
import WovenMatterCore

@testable import WovenMatterDashboardStore

@Suite("Workspace history and bounded versions")
struct WorkspaceHistoryTests {

  private func database() async throws -> (WorkspaceDatabase, URL) {
    let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return (try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite")), url)
  }
  private func rows(_ value: GatewayJSONValue) -> [GatewayJSONValue] {
    value.objectValue?["rows"]?.arrayValue ?? []
  }

  @Test func nativePayloadsSurviveReopenAndSearchWithStablePagination() async throws {
    let (db, url) = try await database()
    defer { try? FileManager.default.removeItem(at: url) }
    let conversation = try await db.createFixtureLocalACPSession(
      runtimeKind: .claudeCode, title: "Pi", ownerDeviceID: UUID())
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "research")
    let raw =
      #"{"type":"tool_execution_end","result":{"text":"unique needle","futureField":[1,2]}}"#
    let event = WorkspaceHistoryEvent(
      id: "native-1", conversationID: conversation, harness: "pi", kind: "wire.in", payload: raw)
    try await db.recordHistory(event)
    try await db.recordHistory(event)
    try await db.recordHistory(
      WorkspaceHistoryEvent(
        id: "native-2", conversationID: conversation, harness: "pi", kind: "wire.in", payload: raw))
    let query = WorkspaceHistoryQuery(
      command: "search", search: "unique needle", harness: "pi", limit: 1)
    let first = try await db.queryHistory(query)
    #expect(rows(first).count == 1)
    #expect(rows(first).first?.objectValue?["payload"]?.stringValue == raw)
    #expect(rows(first).first?.objectValue?["run_id"]?.stringValue == run.runID)
    #expect(first.objectValue?["hasMore"]?.boolValue == true)
    let reopened = try await WorkspaceDatabase(url: url.appending(path: "workspace.sqlite"))
    var next = query
    next.after = Int64(first.objectValue?["nextCursor"]?.intValue ?? 0)
    #expect(
      rows(try await reopened.queryHistory(next)).first?.objectValue?["id"]?.stringValue == "native-2")
    await #expect(throws: (any Error).self) {
      try await db.recordHistory(
        WorkspaceHistoryEvent(id: "native-1", harness: "pi", kind: "wire.in", payload: "different"))
    }
    await #expect(throws: (any Error).self) { try await db.queryHistory(.init(command: "DELETE FROM notes")) }
  }

}
