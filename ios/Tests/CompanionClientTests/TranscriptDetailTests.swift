import XCTest
import CryptoKit
import WovenMatterCompanion
@testable import CompanionClient

final class TranscriptDetailTests: XCTestCase {
  func testHTMLReplyRebuildsFromNativeToolResultAndSurvivesJournalReopen() async throws {
    for legacy in [false, true] {
    let html = "<button onclick='this.textContent=42'>Calculate</button><img src='data:image/png;base64," + String(repeating: "A", count: 100_000) + "'>"
    let request: [String: Any] = ["action": "render", "html": "<img src='/device-workspace/image.png'>", "title": "Calculator", "height": 160]
    var prepared = request; prepared["html"] = html
    let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    let reference: [String: Any] = ["id": UUID().uuidString.lowercased(), "title": "Calculator", "height": 160]
    let responseValue: [String: Any] = legacy ? ["success": true, "result": ["htmlRender": reference]] : ["htmlRender": reference]
    let response = String(decoding: try JSONSerialization.data(withJSONObject: responseValue), as: UTF8.self)
    var focused = request; focused.removeValue(forKey: "action")
    let snapshot: [String: Any] = ["entries": [
      ["id": 1, "model": [["role": "user", "content": "Calculate"]]],
      ["id": 2, "model": [["role": "assistant", "content": [["type": "toolCall", "id": "render", "name": legacy ? "wovenmatter_html" : "woven_html_render", "arguments": legacy ? ["arguments": ["call", "--json", json]] : focused]]]]],
      ["id": 3, "model": [["role": "toolResult", "toolCallId": "render", "content": [["type": "text", "text": response]], "details": ["wovenHTMLPage": prepared]]]]
    ]]
    let transcript = CompanionDeviceTranscript.project(snapshot: snapshot, conversationID: "c")
    let projection = try XCTUnwrap(transcript.activities.first?.projectionJSON)
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(projection.utf8)) as? [String: Any])
    XCTAssertEqual(value["kind"] as? String, "activity")
    XCTAssertEqual((value["htmlRender"] as? [String: Any])?["id"] as? String, reference["id"] as? String)
    let page = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(value["rawOutputJSON"] as? String).utf8)) as? [String: Any])
    XCTAssertEqual(page["html"] as? String, html)
    let path = file()
    let journal = try WorkspaceJournal(file: path)
    _ = try await journal.append(workspaceID: "phone", transcript: transcript)
    let state = await journal.snapshot()
    let summary = try XCTUnwrap(state.transcripts["c"]?.activities.first?.projectionJSON)
    XCTAssertTrue(summary.contains("htmlRender"))
    XCTAssertFalse(summary.contains(html))
    let reopened = try WorkspaceJournal(file: path)
    let detail = try await reopened.activityDetails(conversationID: "c", activityID: try XCTUnwrap(transcript.activities.first?.id))
    XCTAssertEqual(detail?.projectionJSON, projection)
    let replica = try WorkspaceJournal(file: file())
    for entry in state.entries.values.sorted(by: { $0.originSequence < $1.originSequence }) { try await replica.record(entry) }
    let replicated = try await replica.activityDetails(conversationID: "c", activityID: try XCTUnwrap(transcript.activities.first?.id))
    XCTAssertEqual(replicated?.projectionJSON, projection)
    var failedSnapshot = snapshot
    var entries = try XCTUnwrap(failedSnapshot["entries"] as? [[String: Any]])
    entries[2]["model"] = [["role": "toolResult", "toolCallId": "render", "isError": true, "content": [["type": "text", "text": response]]]]
    failedSnapshot["entries"] = entries
    let failed = CompanionDeviceTranscript.project(snapshot: failedSnapshot, conversationID: "c")
    XCTAssertFalse(failed.activities.first?.projectionJSON?.contains("htmlRender\":") ?? true)
    }
  }

  func testLinkedReasoningWaitsForChunksAndReconstructsAfterRestart() async throws {
    let path = file(), journal = try WorkspaceJournal(file: path)
    let base = String(repeating: "Reasoning e\u{301} 🧵\n", count: 30_000)
    var sequence: Int64 = 0
    func add(_ kind: CompanionJournalEntry.Kind, part: CompanionNativeRecordPart? = nil,
      pointer: String? = nil, runID: String = "run") async throws {
      sequence += 1
      try await journal.record(.init(workspaceID: "owner", originSequence: sequence, conversationID: "chat", runID: runID,
        kind: kind, transcript: pointer.map { .init(conversationID: "chat", activities: [
          .init(id: "trace", runID: "run", title: "Thinking", status: "completed", projectionJSON: "{\"id\":\"trace\",\"detailVersion\":3}", detailsRecordID: $0)
        ]) }, nativeRecord: part))
    }
    func parts(_ recordID: String, _ text: String, previous: String? = nil,
      id: String = "trace", version: Int = 3) throws -> [CompanionNativeRecordPart] {
      let value: [String: Any] = ["id": id, "kind": "thought", "title": "Newest metadata", "content": text,
        "contentIsDelta": previous != nil, "detailVersion": version, "detailsAvailable": true]
      var envelope: [String: Any] = ["activity": value]
      if let previous { envelope["previousDetailsRecordID"] = previous }
      let bytes = try JSONSerialization.data(withJSONObject: envelope), chunk = 131_072
      let count = (bytes.count + chunk - 1) / chunk
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      return (0..<count).map { .init(recordID: recordID, format: "wovenmatter.activity.v2", partIndex: $0,
        partCount: count, byteCount: Int64(bytes.count), sha256: digest,
        data: bytes.subdata(in: $0 * chunk..<min(bytes.count, ($0 + 1) * chunk))) }
    }
    func expectError(_ code: String) async throws {
      do {
        _ = try await journal.activityDetails(conversationID: "chat", activityID: "trace")
        XCTFail("Incomplete or invalid chain returned a disclosure")
      } catch let error as CompanionAPIError { XCTAssertEqual(error.code, code) }
    }
    try await add(.transcript, pointer: "head")
    try await expectError("incomplete_activity_details")
    for part in try parts("head", " suffix 🧵", previous: "middle") { try await add(.nativeRecord, part: part) }
    try await expectError("incomplete_activity_details")
    for part in try parts("middle", " café", previous: "base", version: 2) { try await add(.nativeRecord, part: part) }
    let baseParts = try parts("base", base, version: 1)
    for (index, part) in baseParts.enumerated() {
      try await add(.nativeRecord, part: part)
      if index < baseParts.count - 1 { try await expectError("incomplete_activity_details") }
    }
    let reopened = try WorkspaceJournal(file: path)
    let full = try await reopened.activityDetails(conversationID: "chat", activityID: "trace")
    let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(full?.projectionJSON).utf8)) as? [String: Any])
    XCTAssertEqual(value["content"] as? String, base + " café suffix 🧵")
    XCTAssertEqual(value["detailVersion"] as? Int, 3)
    XCTAssertEqual(value["contentIsDelta"] as? Bool, false)
    XCTAssertEqual(value["title"] as? String, "Newest metadata")
    for part in try parts("terminal", "Corrected final 🧵", version: 4) { try await add(.nativeRecord, part: part) }
    try await add(.transcript, pointer: "terminal")
    let terminal = try await journal.activityDetails(conversationID: "chat", activityID: "trace")
    let terminalValue = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(terminal?.projectionJSON).utf8)) as? [String: Any])
    XCTAssertEqual(terminalValue["content"] as? String, "Corrected final 🧵")
    XCTAssertEqual(terminalValue["detailVersion"] as? Int, 4)
    for part in try parts("foreign", "Secret") { try await add(.nativeRecord, part: part, runID: "other-run") }
    for part in try parts("wrong-run", "Suffix", previous: "foreign") { try await add(.nativeRecord, part: part) }
    try await add(.transcript, pointer: "wrong-run")
    try await expectError("invalid_activity_details")
    var corrupt = try parts("corrupt", "Wrong digest")[0]
    corrupt.data[0] ^= 1
    try await add(.nativeRecord, part: corrupt)
    try await add(.transcript, pointer: "corrupt")
    try await expectError("invalid_activity_details")
    for part in try parts("cycle", "Suffix", previous: "cycle") { try await add(.nativeRecord, part: part) }
    try await add(.transcript, pointer: "cycle")
    try await expectError("invalid_activity_details")
    for part in try parts("wrong-id", "Other", id: "another-activity") { try await add(.nativeRecord, part: part) }
    for part in try parts("identity-head", "Suffix", previous: "wrong-id") { try await add(.nativeRecord, part: part) }
    try await add(.transcript, pointer: "identity-head")
    try await expectError("invalid_activity_details")
  }

  func testRetriedNativePartsRemainIdempotentAfterRestartButConflictsAreRejected() async throws {
    for conflict in ["bytes", "manifest", "scope"] {
      let path = file(), journal = try WorkspaceJournal(file: path)
      let base = String(repeating: "café 🧵\n", count: 20_000)
      var sequence: Int64 = 1
      try await journal.record(.init(workspaceID: "owner", originSequence: sequence, conversationID: "chat", runID: "run",
        kind: .transcript, transcript: .init(conversationID: "chat", activities: [
          .init(id: "trace", runID: "run", title: "Thinking", status: "completed", detailsRecordID: "head")
        ])))
      func parts(_ id: String, content: String, previous: String? = nil) throws -> [CompanionNativeRecordPart] {
        var envelope: [String: Any] = ["activity": ["id": "trace", "kind": "thought", "title": "Thinking",
          "content": content, "contentIsDelta": previous != nil, "detailVersion": previous == nil ? 1 : 2]]
        if let previous { envelope["previousDetailsRecordID"] = previous }
        let bytes = try JSONSerialization.data(withJSONObject: envelope), chunk = 131_072
        let count = (bytes.count + chunk - 1) / chunk
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return (0..<count).map { .init(recordID: id, format: "wovenmatter.activity.v2", partIndex: $0,
          partCount: count, byteCount: Int64(bytes.count), sha256: digest,
          data: bytes.subdata(in: $0 * chunk..<min(bytes.count, ($0 + 1) * chunk))) }
      }
      func record(_ journal: WorkspaceJournal, _ part: CompanionNativeRecordPart, runID: String = "run") async throws {
        sequence += 1
        try await journal.record(.init(workspaceID: "owner", originSequence: sequence, conversationID: "chat",
          runID: runID, kind: .nativeRecord, nativeRecord: part))
      }
      let originalParts = try parts("base", content: base) + parts("head", content: "Fresh suffix 🧵", previous: "base")
      XCTAssertGreaterThan(originalParts.count, 2)
      for part in originalParts { try await record(journal, part) }
      // New event IDs and sequences are legitimate retries of immutable parts.
      for part in originalParts.reversed() { try await record(journal, part) }
      let reopened = try WorkspaceJournal(file: path)
      let detail = try await reopened.activityDetails(conversationID: "chat", activityID: "trace")
      let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(detail?.projectionJSON).utf8)) as? [String: Any])
      XCTAssertEqual(value["content"] as? String, base + "Fresh suffix 🧵")
      XCTAssertEqual(value["contentIsDelta"] as? Bool, false)
      XCTAssertEqual(value["detailVersion"] as? Int, 2)
      var invalid = originalParts[0]
      if conflict == "bytes" { invalid.data[0] ^= 1 }
      if conflict == "manifest" { invalid.sha256 = String(repeating: "0", count: 64) }
      try await record(reopened, invalid, runID: conflict == "scope" ? "other-run" : "run")
      let restarted = try WorkspaceJournal(file: path)
      do {
        _ = try await restarted.activityDetails(conversationID: "chat", activityID: "trace")
        XCTFail("Conflicting duplicate \(conflict) was accepted")
      } catch let error as CompanionAPIError { XCTAssertEqual(error.code, "invalid_activity_details") }
    }
  }

  private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json") }
  private func activity(content: String) throws -> CompanionActivity {
    let object: [String: Any] = ["id":"call", "kind":"tool", "title":"read_file", "status":"completed",
      "toolName":"read_file", "content":content, "rawOutputJSON":content, "locations":[], "changes":[], "planEntries":[]]
    return .init(id:"call", runID:"turn", title:"read_file", status:"completed",
      projectionJSON:String(decoding: try JSONSerialization.data(withJSONObject:object), as:UTF8.self), sequence:1)
  }
}
