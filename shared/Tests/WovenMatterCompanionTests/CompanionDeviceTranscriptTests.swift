import XCTest
@testable import WovenMatterCompanion

final class CompanionDeviceTranscriptTests: XCTestCase {
  /// Redacted shape of the three-turn “Hey” case. No phone data or provider calls.
  private func hey() -> [String: Any] {
    ["entries": [
      ["id": 1, "model": [["role":"user", "content":"Hey", "timestamp": 1_000]]],
      ["id": 2, "model": [["role":"assistant", "content":[["type":"text", "text":"Hello."]], "timestamp":2_000]]],
      ["id": 3, "model": [["role":"user", "content":"Inspect your environment.", "timestamp":3_000]]],
      ["id": 4, "model": [["role":"assistant", "content":[
        ["type":"text", "text":"I’ll inspect the workspace."],
        ["type":"toolCall", "id":"files", "name":"list_files", "arguments":["path":"."]],
        ["type":"toolCall", "id":"notes", "name":"list_notes", "arguments":[:]]
      ], "timestamp":4_000]]],
      ["id": 5, "model": [["role":"toolResult", "toolCallId":"files", "toolName":"list_files", "content":[["type":"text", "text":"[]"]], "timestamp":5_000]]],
      ["id": 6, "model": [["role":"toolResult", "toolCallId":"notes", "toolName":"list_notes", "content":[["type":"text", "text":"{\"notes\":[]}"]], "timestamp":6_000]]],
      ["id": 7, "model": [["role":"assistant", "content":[["type":"text", "text":"## Workspace\n\n- No files\n- No notes\n\n```js\ntext(1 + 1);\n```"]], "timestamp":7_000]]],
      ["id": 8, "model": [["role":"user", "content":"Do you have a shell?", "timestamp":8_000]]],
      ["id": 9, "model": [["role":"assistant", "content":[["type":"text", "text":"I can use the tools exposed on this device."]], "timestamp":9_000]]]
    ]]
  }
  func testSavedHeyProjectsToolsInsteadOfRawMessages() throws {
    let result = CompanionDeviceTranscript.project(snapshot: hey(), conversationID: "hey")
    XCTAssertEqual(result.messages.filter { $0.role == "user" }.count, 3)
    XCTAssertEqual(result.messages.filter { $0.role == "assistant" }.count, 4)
    XCTAssertFalse(result.messages.contains { $0.role == "tool" || $0.content.hasPrefix("Tool:") || $0.content == "[]" })
    XCTAssertEqual(result.runs?.count, 3)
    XCTAssertTrue(result.runs?.allSatisfy { UUID(uuidString: $0.id) != nil } == true)
    XCTAssertEqual(result.activities.map(\.title), ["list_files", "list_notes"])
    XCTAssertEqual(result.activities.map(\.status), ["completed", "completed"])
    let files = try XCTUnwrap(result.activities.first)
    let projected = try object(XCTUnwrap(files.projectionJSON))
    XCTAssertEqual(projected["toolName"] as? String, "list_files")
    XCTAssertEqual(try object(XCTUnwrap(projected["rawInputJSON"] as? String))["path"] as? String, ".")
    XCTAssertEqual(try object(XCTUnwrap(projected["rawOutputJSON"] as? String))["toolCallId"] as? String, "files")
    XCTAssertNotNil(files.createdAt); XCTAssertNotNil(files.completedAt)
    let commentary = try XCTUnwrap(result.messages.first { $0.content.contains("inspect the workspace") })
    let final = try XCTUnwrap(result.messages.first { $0.content.contains("## Workspace") })
    XCTAssertEqual(commentary.runID, files.runID); XCTAssertEqual(final.runID, files.runID)
    XCTAssertLessThan(try XCTUnwrap(commentary.sequence), try XCTUnwrap(files.sequence))
    XCTAssertLessThan(try XCTUnwrap(files.sequence), try XCTUnwrap(final.sequence))
    XCTAssertEqual(result, CompanionDeviceTranscript.project(snapshot: hey(), conversationID: "hey"))
  }
  func testIDsSurviveLiveToSettledAndSerialization() throws {
    let live = CompanionDeviceTranscript.project(snapshot: hey(), conversationID: "hey", activeRunID: "request-1")
    let settled = CompanionDeviceTranscript.project(snapshot: hey(), conversationID: "hey")
    XCTAssertEqual(live.messages.map(\.id), settled.messages.map(\.id))
    XCTAssertEqual(live.activities.map(\.id), settled.activities.map(\.id))
    XCTAssertEqual(live.runs?.map(\.id), settled.runs?.map(\.id))
    XCTAssertEqual(live.runs?.last?.status, "running")
    XCTAssertNil(live.runs?.last?.completedAt)
    XCTAssertEqual(try JSONDecoder().decode(CompanionTranscript.self, from: JSONEncoder().encode(settled)), settled)
  }
  func testFailedToolPreservesArgumentsResultAndFailure() throws {
    let snapshot: [String: Any] = ["entries": [
      ["id":1, "model":[["role":"user", "content":"Read a file"]]],
      ["id":2, "model":[["role":"assistant", "content":[["type":"toolCall", "id":"read", "name":"read_file", "arguments":["path":"missing.txt"]]]]]],
      ["id":3, "model":[["role":"toolResult", "toolCallId":"read", "isError":true, "content":[["type":"text", "text":"File not found"]]]]]
    ]]
    let result = CompanionDeviceTranscript.project(snapshot: snapshot, conversationID: "c", runStatus: "failed")
    XCTAssertEqual(result.activities.count, 1)
    XCTAssertEqual(result.activities.first?.status, "failed")
    XCTAssertEqual(result.runs?.last?.status, "failed")
    XCTAssertEqual(try object(XCTUnwrap(result.activities.first?.projectionJSON))["content"] as? String, "File not found")
  }
  func testThinkingAndStreamingRemainOrderedWithoutToolDuplication() throws {
    var snapshot = hey()
    snapshot["generation"] = ["message":["role":"assistant", "content":[
      ["type":"thinking", "thinking":"Checking the available capabilities."],
      ["type":"text", "text":"The currently available"],
      ["type":"toolCall", "id":"live", "name":"list_files", "arguments":[:]]
    ]]]
    snapshot["tools"] = [["callId":"live", "status":"running", "details":["progress":5]]]
    let result = CompanionDeviceTranscript.project(snapshot: snapshot, conversationID: "hey", activeRunID: "request-2")
    XCTAssertEqual(result.messages.last?.status, "streaming")
    XCTAssertEqual(result.activities.last?.status, "running")
    let thought = try object(XCTUnwrap(result.activities.dropLast().last?.projectionJSON))
    XCTAssertEqual(thought["kind"] as? String, "thought")
    XCTAssertNotNil(try object(XCTUnwrap(result.activities.last?.projectionJSON))["rawPayloadJSON"])
  }
  func testLifecycleStatusesUseCanonicalRunVocabulary() {
    for (lifecycle, expected) in ["ready":"completed", "idle":"completed", "stopping":"cancelled", "stopped":"cancelled", "failed":"failed", "interrupted":"interrupted"] {
      let transcript = CompanionDeviceTranscript.project(snapshot: hey(), conversationID: "hey", runStatus: lifecycle)
      XCTAssertEqual(transcript.runs?.last?.status, expected, lifecycle)
      XCTAssertEqual(transcript.runs?.dropLast().map(\.status), ["completed", "completed"])
    }
    XCTAssertEqual(CompanionDeviceTranscript.project(snapshot: hey(), conversationID: "hey", activeRunID: "active", runStatus: "idle").runs?.last?.status, "running")
  }
  func testLegacyTransportRecordsStillDecode() throws {
    let data = Data(#"{"conversationID":"c","messages":[{"id":"m","conversationID":"c","role":"assistant","content":"Hello","createdAt":""}],"activities":[{"id":"a","runID":"r","title":"Read","status":"completed"}]}"#.utf8)
    let result = try JSONDecoder().decode(CompanionTranscript.self, from: data)
    XCTAssertNil(result.runs); XCTAssertNil(result.messages.first?.sequence)
    XCTAssertNil(result.activities.first?.projectionJSON)
  }
  func testSubagentSummaryRetainsTaskAndResult() throws {
    let snapshot: [String: Any] = ["entries": [
      ["id":1, "model":[["role":"user", "content":"Research"]]],
      ["id":2, "model":[["role":"assistant", "content":[["type":"toolCall", "id":"child", "name":"subagent", "arguments":["name":"Researcher","task":"Read the document"]]]]]],
      ["id":3, "model":[["role":"toolResult", "toolCallId":"child", "content":[["type":"text", "text":"Findings"]], "details":["nativeConversationID":42]]]]
    ]]
    let result = CompanionDeviceTranscript.project(snapshot: snapshot, conversationID: "c")
    let projection = try object(XCTUnwrap(result.activities.first?.projectionJSON))
    let child = try XCTUnwrap((projection["subagents"] as? [[String:Any]])?.first)
    XCTAssertEqual(child["name"] as? String, "Researcher")
    XCTAssertEqual(child["task"] as? String, "Read the document")
    XCTAssertEqual(child["result"] as? String, "Findings")
    XCTAssertEqual(child["nativeConversationID"] as? String, "42")
  }
  private func object(_ text: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }
}
