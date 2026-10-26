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
  private func object(_ text: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
  }
}
