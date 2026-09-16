import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

/// Sanitized shapes from a recorded Gateway run: commentary, mirrored tool
/// call/result, display-cap preview, then a complete native final record.
struct OpenClawTranscriptRepairTests {
  @Test func partiallySequencedHistoryUsesConsistentChronologicalOrder() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try WorkspaceDatabase(url: directory.appending(path: "test.sqlite"))
    let conversation = try db.createLocalACPSession(runtimeKind: .openclaw, title: "Ordering", ownerDeviceID: UUID())
    func commentary(_ id: String, seq: Int?, time: Int) throws -> GatewayJSONValue {
      var row = try #require(record(id, run: "r", kind: "commentary", text: id, seq: seq ?? 0).objectValue)
      var metadata = try #require(row["__openclaw"]?.objectValue)
      if seq == nil { metadata.removeValue(forKey: "seq") }
      row["__openclaw"] = .object(metadata)
      row["timestamp"] = .number(1_700_000_000_000 + Double(time))
      return .object(row)
    }
    let values = try [commentary("A", seq: 1, time: 3), commentary("B", seq: 2, time: 1),
      commentary("C", seq: nil, time: 2), record("final", run: "r", kind: "assistant", text: "Answer", seq: 4)]
    try db.synchronizeOpenClawHistory(conversationID: conversation,
      history: OpenClawGatewayHistory(payload: .object(["messages": .array(values)])))
    let page = try db.conversationHistoryPage(id: conversation, limit: 20)
    let reply = try #require(page.messages.first)
    #expect(reply.content == "BCAAnswer")
    let projection = AssistantTranscriptProjection(messageID: reply.id, content: reply.content,
      activities: page.activities.map(\.activity))
    #expect(projection.body == "Answer")
    #expect(projection.commentary.map(\.content) == ["B", "C", "A"])
  }

  private func record(_ id: String, run: String, kind: String, text: String = "", truncated: Bool = false, seq: Int) -> GatewayJSONValue {
    var metadata: [String: GatewayJSONValue] = [
      "id": .string(id), "runId": .string(run), "seq": .number(Double(seq)),
      "idempotencyKey": .string("codex-app-server:session:turn:" + (kind == "commentary" ? "commentary:\(id)" : kind))
    ]
    if truncated { metadata["truncated"] = .bool(true); metadata["reason"] = .string("display-cap") }
    var row: [String: GatewayJSONValue] = ["role": .string(kind == "result" ? "toolResult" : "assistant"),
      "__openclaw": .object(metadata), "timestamp": .number(1_700_000_000_000 + Double(seq)),
      "stopReason": .string(kind == "call" ? "toolUse" : "stop")]
    switch kind {
    case "call": row["content"] = .array([.object(["type": .string("toolCall"), "id": .string("tool-1"), "name": .string("exec"), "arguments": .object(["cmd": .string("echo fixture")])])])
    case "result":
      row["toolCallId"] = .string("tool-1"); row["toolName"] = .string("exec")
      row["content"] = .array([.object(["type": .string("toolResult"), "toolCallId": .string("tool-1"), "text": .string("fixture output")])])
    default: row["content"] = .array([.object(["type": .string("text"), "text": .string(text)])])
    }
    return .object(row)
  }

  @Test func markedPreviewHydratesOnlyMatchingNativeRecord() async throws {
    let preview = record("final", run: "r", kind: "assistant", text: "short", truncated: true, seq: 44)
    let full = record("final", run: "r", kind: "assistant", text: String(repeating: "long ", count: 3_000), seq: 44)
    let payload = GatewayJSONValue.object(["messages": .array([preview])])
    let hydrated = try await OpenClawGatewayHistoryHydration.hydrate(payload) { id in
      #expect(id == "final")
      return .object(["ok": .bool(true), "message": full])
    }
    #expect(try OpenClawGatewayHistory(payload: hydrated).messages.first?.text.count == 15_000)
    let wrong = try await OpenClawGatewayHistoryHydration.hydrate(payload) { _ in
      .object(["message": record("different", run: "r", kind: "assistant", text: "wrong", seq: 44)])
    }
    #expect(try OpenClawGatewayHistory(payload: wrong).messages.first?.isTruncated == true)
    var differentInput = try #require(full.objectValue)
    var metadata = try #require(differentInput["__openclaw"]?.objectValue)
    metadata["idempotencyKey"] = .string("another-input:assistant")
    differentInput["__openclaw"] = .object(metadata)
    let mismatchedInput = GatewayJSONValue.object(differentInput)
    let wrongInput = try await OpenClawGatewayHistoryHydration.hydrate(payload) { _ in
      .object(["message": mismatchedInput])
    }
    #expect(try OpenClawGatewayHistory(payload: wrongInput).messages.first?.isTruncated == true)
  }

  @Test func completeResponseSurvivesPreviewAndHistoryReopen() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "test.sqlite")
    let db = try WorkspaceDatabase(url: url)
    let conversation = try db.createLocalACPSession(runtimeKind: .openclaw, title: "Fixture", ownerDeviceID: UUID())
    let run = try db.beginLocalACPRun(conversationID: conversation, content: "Fixture question")
    let final = String(repeating: "Complete answer. ", count: 900)
    try db.replaceLocalACPAssistantMessage(runID: run.runID, assistantMessageID: run.assistantMessageID, content: final)
    let commentary = record("comment", run: run.runID, kind: "commentary", text: "Checking.\n\n", seq: 3)
    let call = record("call", run: run.runID, kind: "call", seq: 4)
    let result = record("result", run: run.runID, kind: "result", seq: 5)
    let full = record("final", run: run.runID, kind: "assistant", text: final, seq: 44)
    let preview = record("final", run: run.runID, kind: "assistant", text: String(final.prefix(8_000)) + "\n...(truncated)...", truncated: true, seq: 44)
    func sync(_ values: [GatewayJSONValue], _ database: WorkspaceDatabase) throws {
      try database.synchronizeOpenClawHistory(conversationID: conversation, history: OpenClawGatewayHistory(payload: .object(["messages": .array(values)])))
    }
    try sync([commentary], db) // Existing installations may have anchored this first.
    try sync([commentary, call, result, preview], db)
    try sync([commentary, call, result, full], db)
    try sync([preview], db) // A late sparse tail must not replace the full record.
    let reopened = try WorkspaceDatabase(url: url)
    try sync([commentary, call, result, full], reopened)
    let content = try reopened.conversationHistoryPage(id: conversation, limit: 100)
    #expect(content.messages.count == 2)
    let assistant = try #require(content.messages.first { $0.id == run.assistantMessageID })
    let projection = AssistantTranscriptProjection(messageID: assistant.id, content: assistant.content, activities: content.activities.map(\.activity))
    #expect(projection.body == final)
    #expect(projection.commentary.map(\.content) == ["Checking.\n\n"])
    let tools = content.activities.filter { $0.activity.kind == .tool }
    #expect(tools.count == 1)
    #expect(tools.first?.activity.rawInputJSON?.contains("echo fixture") == true)
    #expect(tools.first?.activity.rawOutputJSON?.contains("fixture output") == true)
    #expect(!assistant.content.contains("**Tool:**"))
  }

  @Test func coldHistoryUsesStructuredToolActivities() throws {
    let db = try WorkspaceDatabase(url: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".sqlite"))
    let conversation = try db.createLocalACPSession(runtimeKind: .openclaw, title: "Cold", ownerDeviceID: UUID())
    let messages = [record("c", run: "remote", kind: "commentary", text: "Looking.\n", seq: 1),
      record("t", run: "remote", kind: "call", seq: 2), record("r", run: "remote", kind: "result", seq: 3),
      record("f", run: "remote", kind: "assistant", text: "Done.", seq: 4)]
    let history = try OpenClawGatewayHistory(payload: .object(["messages": .array(messages)]))
    try db.synchronizeOpenClawHistory(conversationID: conversation, history: history)
    try db.synchronizeOpenClawHistory(conversationID: conversation, history: history)
    let content = try db.conversationHistoryPage(id: conversation, limit: 100)
    #expect(content.messages.count == 1)
    #expect(content.runs.count == 1)
    #expect(content.activities.filter { $0.activity.kind == .tool }.count == 1)
  }
  @Test func activityOnlyCompletionKeepsIdentityWithoutInventedAssistantText() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try WorkspaceDatabase(url: directory.appending(path: "test.sqlite"))
    let conversation = try db.createLocalACPSession(runtimeKind: .pi, title: "Command", ownerDeviceID: UUID())
    let run = try db.beginLocalACPRun(conversationID: conversation, content: "/notify")
    try db.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: AgentRunActivity(id: "notice", kind: .activity, title: "Notification", content: "Command complete"))
    try db.completeLocalACPAssistantMessage(runID: run.runID, assistantMessageID: run.assistantMessageID)
    try db.completeLocalACPRun(runID: run.runID)
    let page = try db.conversationHistoryPage(id: conversation, limit: 100)
    let assistant = try #require(page.messages.first { $0.id == run.assistantMessageID })
    #expect(assistant.content.isEmpty)
    #expect(assistant.status == "completed")
    #expect(page.runs.first?.assistantMessageID == assistant.id)
    #expect(page.activities.first?.activity.content == "Command complete")
    #expect(AssistantTranscriptProjection(messageID: assistant.id, content: assistant.content,
      activities: page.activities.map(\.activity)).body.isEmpty)
    let failure = try db.beginLocalACPRun(conversationID: conversation, content: "/fail")
    try db.completeLocalACPRun(runID: failure.runID, error: "Command failed")
    #expect(try db.conversationContent(id: conversation).messages.first { $0.id == failure.assistantMessageID }?.content == "Command failed")
  }

  @Test func incrementalToolsKeepMixedProseAndFailedResultAcrossCallReplay() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try WorkspaceDatabase(url: directory.appending(path: "test.sqlite"))
    let conversation = try db.createLocalACPSession(runtimeKind: .openclaw, title: "Incremental", ownerDeviceID: UUID())
    var call = try #require(record("call", run: "remote", kind: "call", seq: 1).objectValue)
    call["content"] = .array([.object(["type": .string("text"), "text": .string("I will check.\n")])]
      + (call["content"]?.arrayValue ?? []))
    var result = try #require(record("result", run: "remote", kind: "result", seq: 2).objectValue)
    result["isError"] = .bool(true)
    func sync(_ rows: [GatewayJSONValue]) throws {
      try db.synchronizeOpenClawHistory(conversationID: conversation,
        history: OpenClawGatewayHistory(payload: .object(["messages": .array(rows)])))
    }
    try sync([.object(call)])
    let first = try db.conversationHistoryPage(id: conversation, limit: 100)
    #expect(first.messages.count == 1)
    #expect(first.messages.first?.content == "I will check.\n")
    #expect(first.activities.first { $0.activity.kind == .tool }?.activity.status == "unknown")
    try sync([.object(result), record("final", run: "remote", kind: "assistant", text: "The check failed.", seq: 3)])
    try sync([.object(call)])
    let page = try db.conversationHistoryPage(id: conversation, limit: 100)
    #expect(page.messages.count == 1)
    let reply = try #require(page.messages.first)
    let projection = AssistantTranscriptProjection(messageID: reply.id, content: reply.content, activities: page.activities.map(\.activity))
    #expect(projection.body == "The check failed.")
    #expect(projection.commentary.map(\.content) == ["I will check.\n"])
    #expect(page.activities.filter { $0.activity.kind == .tool }.count == 1)
    #expect(page.activities.first { $0.activity.kind == .tool }?.activity.status == "failed")
  }

  @Test func auditHashesAndPreambleMirrorsReconcileOnlyProvenNativeIdentities() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "test.sqlite")
    let db = try WorkspaceDatabase(url: url)
    let conversation = try db.createLocalACPSession(runtimeKind: .openclaw, title: "Legacy audit", ownerDeviceID: UUID())
    let run = try db.beginLocalACPRun(conversationID: conversation, content: "Check")
    let nativeID = run.runID + ":tool-1"
    let hashID = GatewayAuditToolIdentity.ledgerID(nativeCallID: "tool-1")
    #expect(GatewayAuditToolIdentity.matches(hashID, scopedID: nativeID, remoteRunID: run.runID))
    #expect(!GatewayAuditToolIdentity.matches(hashID, scopedID: nativeID, remoteRunID: "another-run"))
    try db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: AgentRunActivity(
      id: nativeID, kind: .tool, phase: "result", detail: "Keep this detail", status: "completed", toolName: "exec"))
    try db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: AgentRunActivity(
      id: hashID, kind: .tool, phase: "result", status: "failed", toolName: "exec"))
    let unmatched = GatewayAuditToolIdentity.ledgerID(nativeCallID: "unmatched")
    try db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: AgentRunActivity(
      id: unmatched, kind: .tool, phase: "result", status: "completed", toolName: "exec"))
    let preambleRaw = "{\"data\":{\"kind\":\"preamble\",\"itemId\":\"preamble-1\"}}"
    try db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: AgentRunActivity(
      id: run.runID + ":preamble-1", kind: .thought, title: "Preamble", content: "Checking.\n", rawPayloadJSON: preambleRaw))
    try db.upsertDeviceOwnedRunActivity(runID: run.runID, activity: AgentRunActivity(
      id: run.runID + ":unrelated-thought", kind: .thought, title: "Preamble", content: "Checking.\n", rawPayloadJSON: preambleRaw))
    var commentary = try #require(record("commentary", run: run.runID, kind: "commentary", text: "Checking.\n", seq: 1).objectValue)
    commentary["openclawStreamFallback"] = .object(["itemId": .string("preamble-1"), "source": .string("segment")])
    var result = try #require(record("result", run: run.runID, kind: "result", seq: 3).objectValue)
    result["isError"] = .bool(false)
    let history = try OpenClawGatewayHistory(payload: .object(["messages": .array([
      .object(commentary), record("call", run: run.runID, kind: "call", seq: 2), .object(result),
      record("final", run: run.runID, kind: "assistant", text: "Done.", seq: 4)
    ])]))
    try db.synchronizeOpenClawHistory(conversationID: conversation, history: history)
    let reopened = try WorkspaceDatabase(url: url)
    try reopened.synchronizeOpenClawHistory(conversationID: conversation, history: history)
    let page = try reopened.conversationHistoryPage(id: conversation, limit: 100)
    let tools = page.activities.filter { $0.activity.kind == .tool }
    #expect(Set(tools.map { $0.activity.id }) == [nativeID, unmatched])
    let native = try #require(tools.first { $0.activity.id == nativeID })
    #expect(native.activity.status == "failed")
    #expect(native.activity.detail == "Keep this detail")
    #expect(native.activity.rawInputJSON?.contains("echo fixture") == true)
    #expect(native.activity.rawOutputJSON?.contains("fixture output") == true)
    #expect(page.activities.filter { $0.activity.kind == .thought }.map { $0.activity.id } == [run.runID + ":unrelated-thought"])
    #expect(page.activities.first { $0.activity.kind == .assistant }?.activity.rawPayloadJSON == preambleRaw)
  }

  @Test func auditFailureSettlesCanonicalLiveStartWithoutDiscardingInput() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try WorkspaceDatabase(url: directory.appending(path: "test.sqlite"))
    let conversation = try db.createLocalACPSession(runtimeKind: .openclaw, title: "Audit", ownerDeviceID: UUID())
    let run = try db.beginLocalACPRun(conversationID: conversation, content: "Check")
    let id = run.runID + ":native-call"
    try db.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: AgentRunActivity(id: id, kind: .tool, phase: "start", status: "running", rawInputJSON: "fixture input"))
    #expect(try db.openClawToolActivityIDs(runID: run.runID) == [id])
    try db.reconcileOpenClawAuditTool(runID: run.runID,
      activity: AgentRunActivity(id: id, kind: .tool, phase: "result", status: "failed"))
    try db.reconcileOpenClawAuditTool(runID: run.runID,
      activity: AgentRunActivity(id: id, kind: .tool, phase: "result", status: "completed"))
    let activities = try db.conversationHistoryPage(id: conversation, limit: 100).activities
    #expect(activities.count == 1)
    #expect(activities.first?.activity.status == "failed")
    #expect(activities.first?.activity.rawInputJSON == "fixture input")
  }

}
