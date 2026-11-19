import XCTest
@testable import WovenMatterShared

final class DeviceTranscriptTests: XCTestCase {
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
  func testThinkingAndStreamingRemainOrderedWithoutToolDuplication() throws {
    var snapshot = hey()
    snapshot["generation"] = ["message":["role":"assistant", "content":[
      ["type":"thinking", "thinking":"Checking the available capabilities."],
      ["type":"text", "text":"The currently available"],
      ["type":"toolCall", "id":"live", "name":"list_files", "arguments":[:]]
    ]]]
    snapshot["tools"] = [["callId":"live", "status":"running", "details":["progress":5]]]
    let result = DeviceTranscript.project(snapshot: snapshot, conversationID: "hey", storedRuns: .init(), activeRunID: "request-2")
    XCTAssertEqual(result.messages.last?.status, "streaming")
    XCTAssertEqual(result.activities.last?.status, "running")
    let thought = try object(XCTUnwrap(result.activities.dropLast().last?.projectionJSON))
    XCTAssertEqual(thought["kind"] as? String, "thought")
    XCTAssertNotNil(try object(XCTUnwrap(result.activities.last?.projectionJSON))["rawPayloadJSON"])
  }
  /// A turn's run ID is worked out once. Projecting a stored chat again gives
  /// back the stored IDs, so its runs and tool activities keep their identity.
  func testAStoredChatProjectsWithTheRunsItAlreadyHas() throws {
    let first = DeviceTranscript.project(snapshot: hey(), conversationID: "hey", storedRuns: .init())
    XCTAssertEqual(first.runs?.count, 3)
    XCTAssertEqual(Set(first.runs?.map(\.id) ?? []).count, 3)
    let stored = DeviceTranscript.StoredRuns(first)
    XCTAssertNil(stored.initial)
    XCTAssertEqual(stored.turns, ["hey-1-0": first.runs![0].id, "hey-3-0": first.runs![1].id, "hey-8-0": first.runs![2].id])
    XCTAssertEqual(DeviceTranscript.project(snapshot: hey(), conversationID: "hey", storedRuns: stored), first)

    // A new turn gets a new run; every stored turn keeps its own.
    var longer = hey()
    longer["entries"] = (longer["entries"] as! [[String: Any]]) + [
      ["id": 10, "model": [["role":"user", "content":"And now?", "timestamp":10_000]]],
      ["id": 11, "model": [["role":"assistant", "content":[["type":"toolCall", "id":"files", "name":"list_files", "arguments":[:]]], "timestamp":11_000]]]]
    let second = DeviceTranscript.project(snapshot: longer, conversationID: "hey", storedRuns: stored)
    XCTAssertEqual(second.runs?.prefix(3).map(\.id), first.runs?.map(\.id))
    let added = try XCTUnwrap(second.runs?.last?.id)
    XCTAssertFalse(first.runs!.map(\.id).contains(added))
    XCTAssertEqual(second.messages.prefix(first.messages.count).map(\.runID), first.messages.map(\.runID))
    XCTAssertEqual(Array(second.activities.prefix(first.activities.count)), first.activities)
    XCTAssertEqual(second.activities.last?.id, added + ":files")
  }

  /// The stored IDs are used as they are, however they were first made: a chat
  /// stored with other run IDs keeps them, for its runs and its tool activities.
  func testStoredRunIDsAreUsedAsStored() throws {
    let turn = "0a0a0a0a-0000-4000-8000-000000000001", opening = "0a0a0a0a-0000-4000-8000-000000000002"
    let snapshot: [String: Any] = ["entries": [
      ["id": 1, "model": [["role":"assistant", "content":[["type":"text", "text":"A reminder you asked for."]], "timestamp":1_000]]],
      ["id": 2, "model": [["role":"user", "content":"Thanks. List my files.", "timestamp":2_000]]],
      ["id": 3, "model": [["role":"assistant", "content":[["type":"toolCall", "id":"files", "name":"list_files", "arguments":[:]]], "timestamp":3_000]]]]]
    let derived = DeviceTranscript.project(snapshot: snapshot, conversationID: "chat", storedRuns: .init())
    var stored = derived
    for index in stored.messages.indices { stored.messages[index].runID = stored.messages[index].role == "user" ? turn : opening }
    stored.runs = [.init(id: opening, status: "completed"), .init(id: turn, status: "completed")]
    let runs = DeviceTranscript.StoredRuns(stored)
    XCTAssertEqual(runs, .init(initial: opening, turns: ["chat-2-0": turn]))
    let result = DeviceTranscript.project(snapshot: snapshot, conversationID: "chat", storedRuns: runs)
    XCTAssertEqual(result.runs?.map(\.id), [opening, turn])
    XCTAssertEqual(result.messages.map(\.runID), [opening, turn])
    XCTAssertEqual(result.activities.map(\.id), [turn + ":files"])
    XCTAssertNotEqual(derived.runs?.map(\.id), result.runs?.map(\.id))
  }
  private func object(_ text: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }
}
