import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Canonical native run archive")
struct WorkspaceNativeRunArchiveTests {

  @Test func fullExportsRedactWovenCapabilitiesFromSavedProjectionRowsWithoutRemovingRunContent() async throws {
    let (db, persistence) = try await database()
    defer { persistence.remove() }
    let conversation = try await session(db)
    let run = try await db.beginLocalACPRun(conversationID: conversation, input: .init(text: "Prompt"))
    let capability = "/private/tmp/wmtools-" + String(repeating: "a", count: 32) + "/" + String(repeating: "b", count: 32) + ".sock"
    let output = "{\"token\":\"retained-lexical-token\",\"toolEndpoint\":\"\(capability)\"}"
    try await db.upsertRunActivity(runID: run.runID,
      activity: .init(id: "tool", kind: .tool, rawOutputJSON: output, rawPayloadJSON: output))
    let bounded = try await db.conversationExport(id: conversation, format: .fullRun)
    let destination = persistence.directory.appending(path: "capabilities.json")
    try await db.exportConversationArchive(id: conversation, to: destination)
    for data in [bounded, try Data(contentsOf: destination)] {
      let text = String(decoding: data, as: UTF8.self)
      #expect(!text.contains(String(repeating: "a", count: 32)))
      #expect(!text.contains(String(repeating: "b", count: 32)))
      #expect(text.contains("retained-lexical-token"))
    }
  }

  @Test func interruptedBatchAdmissionRollsBackEveryRecordAndItsSearchIndexBeforeRetry() async throws {
    let (db, persistence) = try await database()
    defer { persistence.remove() }
    let conversation = try await session(db)
    var batch = WorkspaceNativeRunRecordBatch(sourceID: "local:store", nativeSessionID: "s", records: [
      .init(id: "first", kind: "event", payload: #"{"text":"rollback-violet-marker"}"#),
      .init(id: "invalid", kind: "event", payload: #"{"text":"second"}"#, contentMode: "invalid-mode")])
    await #expect(throws: (any Error).self) {
      try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "default_agent")
    }
    #expect(rows(try await db.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.event"))).isEmpty)
    #expect(rows(try await db.queryHistory(.init(command: "search", search: "rollback-violet-marker", conversationID: conversation))).isEmpty)
    batch.records[1].contentMode = "event"
    try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "default_agent")
    let reopened = try await persistence.openDatabase()
    try await reopened.recordNativeRunRecords(batch, conversationID: conversation, harness: "default_agent")
    let first = try await reopened.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.event", limit: 1))
    #expect(rows(first).count == 1 && first.objectValue?["hasMore"]?.boolValue == true)
    let next = try await reopened.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.event",
      after: Int64(first.objectValue?["nextCursor"]?.intValue ?? 0), limit: 1))
    #expect(rows(next).count == 1 && next.objectValue?["hasMore"]?.boolValue == false)
    #expect(rows(try await reopened.queryHistory(.init(command: "search", search: "rollback-violet-marker", conversationID: conversation))).count == 1)
  }

  @Test func nativeContentKeepsTokenFieldsAndFormattingWhileCredentialTransportIsRedacted() async throws {
    let (db, persistence) = try await database()
    defer { persistence.remove() }
    let conversation = try await session(db)
    let raw = "{ \"toolResult\": {\"method\":\"connect\",\"token\":\"lexical-token\",\"headers\":{\"Authorization\":\"content evidence\"}}, \"future\": [1,2] }"
    try await db.historyWireRecorder(conversationID: conversation, harness: "default_agent", sourceScope: "local")("native", JSONEncoder().encode(
      WorkspaceNativeRunRecordBatch(sourceID: "default_agent:/store", nativeSessionID: "s", records: [.init(id: "r", kind: "tool.result", payload: raw)])))
    let retained = try #require(rows(try await db.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.tool.result"))).first?.objectValue)
    #expect(retained["payload"]?.stringValue == raw)
    #expect(retained["source_id"]?.stringValue == "local:default_agent:/store")
    let credentials = #"{"jsonrpc":"2.0","method":"woven/credentials","params":{"apiKey":"secret-key","scope":"provider","nested":{"accessToken":"secret-token"}}}"#
    let body = try String(decoding: JSONEncoder().encode(WorkspaceHTTPObservation(method: "POST", path: "/rpc", query: [:], status: 200, body: credentials)), as: UTF8.self)
    let envelope = "{\"method\":\"POST\",\"path\":\"/rpc\",\"headers\":{\"Authorization\":\"earlier-secret\"},\"body\":\(try String(decoding: JSONEncoder().encode(body), as: UTF8.self))}"
    let safe = WorkspaceHistoryPrivacy.redactingTransportSecrets(envelope)
    #expect(!safe.contains("secret-key") && !safe.contains("secret-token") && !safe.contains("earlier-secret"))
    #expect(safe.contains("provider"))
    #expect(WorkspaceHistoryPrivacy.redactingTransportSecrets(raw) == raw)
  }

  private func database() async throws -> (WorkspaceDatabase, PersistenceFixture) {
    let persistence = try PersistenceFixture()
    return (try await persistence.openDatabase(), persistence)
  }
  private func session(_ db: WorkspaceDatabase) async throws -> String {
    try await db.createFixtureLocalACPSession(runtimeKind: .claudeCode, title: "Archive", ownerDeviceID: UUID())
  }
}
