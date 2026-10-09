import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Canonical native run archive")
struct WorkspaceNativeRunArchiveTests {
  @Test func interruptedBatchAdmissionRollsBackEveryRecordAndItsSearchIndexBeforeRetry() async throws {
    let (db, directory) = try await database()
    defer { try? FileManager.default.removeItem(at: directory) }
    let conversation = try await session(db)
    var batch = WorkspaceNativeRunRecordBatch(sourceID: "local:store", nativeSessionID: "s", records: [
      .init(id: "first", kind: "event", payload: #"{"text":"rollback-violet-marker"}"#),
      .init(id: "invalid", kind: "event", payload: #"{"text":"second"}"#, contentMode: "invalid-mode")])
    await #expect(throws: (any Error).self) {
      try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "pi")
    }
    #expect(rows(try await db.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.event"))).isEmpty)
    #expect(rows(try await db.queryHistory(.init(command: "search", search: "rollback-violet-marker", conversationID: conversation))).isEmpty)
    batch.records[1].contentMode = "event"
    try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "pi")
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    try await reopened.recordNativeRunRecords(batch, conversationID: conversation, harness: "pi")
    let first = try await reopened.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.event", limit: 1))
    #expect(rows(first).count == 1 && first.objectValue?["hasMore"]?.boolValue == true)
    let next = try await reopened.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.event",
      after: Int64(first.objectValue?["nextCursor"]?.intValue ?? 0), limit: 1))
    #expect(rows(next).count == 1 && next.objectValue?["hasMore"]?.boolValue == false)
    #expect(rows(try await reopened.queryHistory(.init(command: "search", search: "rollback-violet-marker", conversationID: conversation))).count == 1)
  }

  @Test func stableNativeIdentityRetainsSnapshotsAndDistinctRepeatedDeltasAfterReopen() async throws {
    let (db, directory) = try await database()
    defer { try? FileManager.default.removeItem(at: directory) }
    let conversation = try await session(db)
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "Prompt")
    let original = WorkspaceNativeRunRecord(id: "message:42", runID: run.runID, kind: "message",
      payload: #"{"id":42,"content":[{"type":"image","url":"native://image/7"}],"futureField":true}"#,
      contentMode: "snapshot", text: "normalized searchable violet harbor", projectionJSON: #"{"role":"assistant"}"#)
    var batch = WorkspaceNativeRunRecordBatch(sourceID: "local:store-uuid", nativeSessionID: "7", records: [original])
    try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "defaultAgent")
    try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "defaultAgent")
    try await db.recordNativeRunRecords(.init(sourceID: "remote:host:" + batch.sourceID,
      nativeSessionID: batch.nativeSessionID, records: [original]), conversationID: conversation, harness: "defaultAgent")
    var revised = original
    revised.payload = #"{"id":42,"content":[{"type":"image","url":"native://image/8"}],"futureField":true}"#
    batch.records = [revised,
      .init(id: "delta:1", runID: run.runID, kind: "thought", payload: #"{"text":"again"}"#, contentMode: "delta"),
      .init(id: "delta:2", runID: run.runID, kind: "thought", payload: #"{"text":"again"}"#, contentMode: "delta")]
    try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "defaultAgent")
    let reopened = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    try await reopened.recordNativeRunRecords(batch, conversationID: conversation, harness: "defaultAgent")
    let records = rows(try await reopened.queryHistory(.init(command: "events", runID: run.runID, harness: "defaultAgent")))
      .filter { $0.objectValue?["source_id"]?.stringValue == batch.sourceID }
    #expect(records.count == 4)
    #expect(rows(try await reopened.queryHistory(.init(command: "events", runID: run.runID, kind: "native.message"))).count == 3)
    #expect(records.filter { $0.objectValue?["native_record_id"]?.stringValue == "message:42" }.count == 2)
    #expect(records.contains { $0.objectValue?["payload"]?.stringValue == original.payload })
    #expect(records.contains { $0.objectValue?["payload"]?.stringValue == revised.payload })
    #expect(rows(try await reopened.queryHistory(.init(command: "search", search: "normalized searchable violet harbor", conversationID: conversation, sourceID: batch.sourceID))).count == 2)
    let nativeID = "entry:fragmented"
    batch.records = [
      .init(id: nativeID, kind: "message", payload: "{}", completeness: "native-export-reference"),
      .init(id: nativeID, revision: "projection:0:sha-one", runID: run.runID, kind: "native-text-fragment",
        payload: "{}", text: "needleé after decoded newline", completeness: "native-text-fragment"),
      .init(id: nativeID, revision: "projection:262144:sha-two", kind: "native-text-fragment",
        payload: "{}", text: "separate later text", completeness: "native-text-fragment")]
    for _ in 0..<2 { try await reopened.recordNativeRunRecords(batch, conversationID: conversation, harness: "defaultAgent") }
    var query = WorkspaceHistoryQuery(command: "search", search: "needleé", conversationID: conversation,
      sourceID: batch.sourceID, nativeSessionID: batch.nativeSessionID, nativeRecordID: nativeID)
    let found = rows(try await reopened.queryHistory(query))
    #expect(found.count == 1)
    let fragment = try #require(found.first?.objectValue)
    #expect(fragment["native_record_id"]?.stringValue == nativeID)
    #expect(fragment["run_id"]?.stringValue == run.runID)
    #expect(fragment["native_revision_id"]?.stringValue == "projection:0:sha-one")
    query.command = "events"; query.search = nil
    #expect(rows(try await reopened.queryHistory(query)).count == 3)
    query.command = "search"; query.search = "needleé"; query.sourceID = "another-source"
    #expect(rows(try await reopened.queryHistory(query)).isEmpty)
  }

  @Test func unboundNativeRecordsOnlyUseExplicitRunMappings() async throws {
    let (db, directory) = try await database()
    defer { try? FileManager.default.removeItem(at: directory) }
    let conversation = try await session(db)
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "Different active run")
    var batch = WorkspaceNativeRunRecordBatch(sourceID: "local:archive", nativeSessionID: "session", records: [
      .init(id: "message", runID: "unavailable-native-run", kind: "message", payload: #"{"text":"historical"}"#, contentMode: "snapshot")])
    try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "pi")
    let before = try #require(rows(try await db.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.message"))).first?.objectValue)
    #expect(before["run_id"] == .null)
    batch.records[0].runID = run.runID
    try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "pi", sourceConnectionID: "new metadata")
    let after = rows(try await db.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.message")))
    #expect(after.count == 1)
    #expect(after.first?.objectValue?["id"] == before["id"])
    #expect(after.first?.objectValue?["run_id"]?.stringValue == run.runID)
    let other = try await session(db)
    let otherRun = try await db.beginLocalACPRun(conversationID: other, content: "Other")
    batch.records[0].runID = otherRun.runID
    await #expect(throws: (any Error).self) {
      try await db.recordNativeRunRecords(batch, conversationID: conversation, harness: "pi")
    }
  }

  @Test func nativeContentKeepsTokenFieldsAndFormattingWhileCredentialTransportIsRedacted() async throws {
    let (db, directory) = try await database()
    defer { try? FileManager.default.removeItem(at: directory) }
    let conversation = try await session(db)
    let raw = "{ \"toolResult\": {\"method\":\"connect\",\"token\":\"lexical-token\",\"headers\":{\"Authorization\":\"content evidence\"}}, \"future\": [1,2] }"
    try await db.historyWireRecorder(conversationID: conversation, harness: "pi", sourceScope: "local")("native", JSONEncoder().encode(
      WorkspaceNativeRunRecordBatch(sourceID: "pi:/store", nativeSessionID: "s", records: [.init(id: "r", kind: "tool.result", payload: raw)])))
    let retained = try #require(rows(try await db.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.tool.result"))).first?.objectValue)
    #expect(retained["payload"]?.stringValue == raw)
    #expect(retained["source_id"]?.stringValue == "local:pi:/store")
    let credentials = #"{"jsonrpc":"2.0","method":"woven/credentials","params":{"apiKey":"secret-key","scope":"provider","nested":{"accessToken":"secret-token"}}}"#
    let body = try String(decoding: JSONEncoder().encode(WorkspaceHTTPObservation(method: "POST", path: "/rpc", query: [:], status: 200, body: credentials)), as: UTF8.self)
    let envelope = "{\"method\":\"POST\",\"path\":\"/rpc\",\"headers\":{\"Authorization\":\"earlier-secret\"},\"body\":\(try String(decoding: JSONEncoder().encode(body), as: UTF8.self))}"
    let safe = WorkspaceHistoryPrivacy.redactingTransportSecrets(envelope)
    #expect(!safe.contains("secret-key") && !safe.contains("secret-token") && !safe.contains("earlier-secret"))
    #expect(safe.contains("provider"))
    #expect(WorkspaceHistoryPrivacy.redactingTransportSecrets(raw) == raw)
  }

  @Test func mutableActivitiesKeepEverySavedRawRevision() async throws {
    let (db, directory) = try await database()
    defer { try? FileManager.default.removeItem(at: directory) }
    let conversation = try await session(db)
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "Prompt")
    try await db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: .init(id: "tool", kind: .tool,
      phase: "start", toolName: "read", rawInputJSON: #"{"path":"a.png"}"#, rawPayloadJSON: #"{"native":"first"}"#))
    try await db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: .init(id: "tool", kind: .tool,
      phase: "end", toolName: "read", content: "exposed summary", rawOutputJSON: #"{"type":"image","url":"native://image/7"}"#,
      rawPayloadJSON: #"{"native":"final","unknown":true}"#))
    let history = rows(try await db.queryHistory(.init(command: "events", runID: run.runID, kind: "activity.snapshot")))
    #expect(history.count == 2)
    #expect(history.first?.objectValue?["payload"]?.stringValue?.contains("first") == true)
    let saved = try JSONDecoder().decode(AgentRunActivity.self, from: Data(try #require(history.last?.objectValue?["payload"]?.stringValue).utf8))
    #expect(saved.rawOutputJSON == #"{"type":"image","url":"native://image/7"}"#)
  }



  @Test func largeNativeRawAndProjectionWindowsRemainExactAndIndependentlyPageable() async throws {
    let (db, directory) = try await database()
    defer { try? FileManager.default.removeItem(at: directory) }
    let conversation = try await session(db)
    let payload = String(repeating: "a\0🧵", count: 30_000)
    let projection = String(repeating: "π", count: 100_000)
    try await db.recordNativeRunRecords(.init(sourceID: "local:store", nativeSessionID: "s", records: [
      .init(id: "big", kind: "message", payload: payload, contentMode: "snapshot", text: projection, projectionJSON: projection)]),
      conversationID: conversation, harness: "pi")
    let listing = try #require(rows(try await db.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.message"))).first?.objectValue)
    #expect(listing["payload"] == .null && listing["projection_json"] == .null)
    var query = WorkspaceHistoryQuery(command: "event", id: try #require(listing["id"]?.stringValue))
    let first = try #require(rows(try await db.queryHistory(query)).first?.objectValue)
    query.offset = 65_536
    let next = try #require(rows(try await db.queryHistory(query)).first?.objectValue)
    #expect((first["payload"]?.stringValue ?? "") + (next["payload"]?.stringValue ?? "") == payload)
    #expect((first["projection_json"]?.stringValue ?? "") + (next["projection_json"]?.stringValue ?? "") == projection)
    #expect(first["projection_has_more"]?.intValue == 1 && next["projection_has_more"]?.intValue == 0)
  }

  @Test func streamedFullArchiveExportsBeyondMemoryBudgetAndPreservesDestinationOnFailure() async throws {
    let (db, directory) = try await database()
    defer { try? FileManager.default.removeItem(at: directory) }
    let conversation = try await session(db)
    let payload = String(repeating: "x", count: WorkspaceExportBudget.maximumStoredBytes + 1)
    let count = WorkspaceExportBudget.maximumItems + 5
    let records: [WorkspaceNativeRunRecord] = [.init(id: "large", kind: "tool.result", payload: payload)]
      + (1..<count).map { .init(id: "event:\($0)", kind: "event", payload: "{}") }
    try await db.recordNativeRunRecords(.init(sourceID: "local:store", nativeSessionID: "s", records: records),
      conversationID: conversation, harness: "pi")
    await #expect(throws: WorkspaceExportError.tooLarge) {
      try await db.conversationExport(id: conversation, format: .fullRun)
    }
    let destination = directory.appending(path: "archive.json")
    try await db.exportConversationArchive(id: conversation, to: destination)
    let exported = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(contentsOf: destination))
    #expect(exported.objectValue?["schemaVersion"]?.intValue == 2)
    let exportedRecords = exported.objectValue?["historyEvents"]?.arrayValue ?? []
    #expect(exportedRecords.count == count)
    let page = try await db.queryHistory(.init(command: "events", conversationID: conversation, kind: "native.event", limit: 200))
    #expect(rows(page).count == 200 && page.objectValue?["hasMore"]?.boolValue == true)
    #expect(exportedRecords.first { $0.objectValue?["native_record_id"]?.stringValue == "large" }?.objectValue?["payload"]?.stringValue == payload)
    let previous = try Data(contentsOf: destination)
    await #expect(throws: (any Error).self) {
      try await db.exportConversationArchive(id: "not-authorized", to: destination)
    }
    #expect(try Data(contentsOf: destination) == previous)
    #expect(try FileManager.default.attributesOfItem(atPath: destination.path)[.posixPermissions] as? Int == 0o600)
  }


  @Test func fullExportsRedactWovenCapabilitiesFromSavedProjectionRowsWithoutRemovingRunContent() async throws {
    let (db, directory) = try await database()
    defer { try? FileManager.default.removeItem(at: directory) }
    let conversation = try await session(db)
    let run = try await db.beginLocalACPRun(conversationID: conversation, content: "Prompt")
    let capability = "/private/tmp/wmtools-" + String(repeating: "a", count: 32) + "/" + String(repeating: "b", count: 32) + ".sock"
    let output = "{\"token\":\"retained-lexical-token\",\"toolEndpoint\":\"\(capability)\"}"
    try await db.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: .init(id: "tool", kind: .tool, rawOutputJSON: output, rawPayloadJSON: output))
    let bounded = try await db.conversationExport(id: conversation, format: .fullRun)
    let destination = directory.appending(path: "capabilities.json")
    try await db.exportConversationArchive(id: conversation, to: destination)
    for data in [bounded, try Data(contentsOf: destination)] {
      let text = String(decoding: data, as: UTF8.self)
      #expect(!text.contains(String(repeating: "a", count: 32)))
      #expect(!text.contains(String(repeating: "b", count: 32)))
      #expect(text.contains("retained-lexical-token"))
    }
  }

  private func database() async throws -> (WorkspaceDatabase, URL) {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString.lowercased())
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return (try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite")), directory)
  }
  private func session(_ db: WorkspaceDatabase) async throws -> String {
    try await db.createLocalACPSession(runtimeKind: .pi, title: "Archive", ownerDeviceID: UUID())
  }
  private func rows(_ result: GatewayJSONValue) -> [GatewayJSONValue] { result.objectValue?["rows"]?.arrayValue ?? [] }
}
