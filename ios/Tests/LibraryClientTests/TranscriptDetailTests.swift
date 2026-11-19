import XCTest
import CryptoKit
import WovenMatterShared
@testable import LibraryClient

final class TranscriptDetailTests: XCTestCase {
  func testHTMLReplyRebuildsFromNativeToolResultAndSurvivesJournalReopen() async throws {
    let html = "<button onclick='this.textContent=42'>Calculate</button><img src='data:image/png;base64," + String(repeating: "A", count: 100_000) + "'>"
    let request: [String: Any] = ["action": "render", "html": "<img src='/device-workspace/image.png'>", "title": "Calculator", "height": 160]
    var prepared = request; prepared["html"] = html
    let reference: [String: Any] = ["id": UUID().uuidString.lowercased(), "title": "Calculator", "height": 160]
    let response = String(decoding: try JSONSerialization.data(withJSONObject: ["htmlRender": reference]), as: UTF8.self)
    var focused = request; focused.removeValue(forKey: "action")
    let snapshot: [String: Any] = ["entries": [
      ["id": 1, "model": [["role": "user", "content": "Calculate"]]],
      ["id": 2, "model": [["role": "assistant", "content": [["type": "toolCall", "id": "render", "name": "woven_html_render", "arguments": focused]]]]],
      ["id": 3, "model": [["role": "toolResult", "toolCallId": "render", "content": [["type": "text", "text": response]], "details": ["wovenHTMLPage": prepared]]]]
    ]]
    let transcript = DeviceTranscript.project(snapshot: snapshot, conversationID: "c", storedRuns: .init())
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
    let failed = DeviceTranscript.project(snapshot: failedSnapshot, conversationID: "c", storedRuns: .init())
    XCTAssertFalse(failed.activities.first?.projectionJSON?.contains("htmlRender\":") ?? true)
  }

  func testLinkedReasoningWaitsForChunksAndReconstructsAfterRestart() async throws {
    let path = file(), journal = try WorkspaceJournal(file: path)
    let base = String(repeating: "Reasoning e\u{301} 🧵\n", count: 30_000)
    var sequence: Int64 = 0
    func add(_ kind: ExecutionJournalEntry.Kind, part: NativeRecordPart? = nil,
      pointer: String? = nil, runID: String = "run") async throws {
      sequence += 1
      try await journal.record(.init(workspaceID: "owner", originSequence: sequence, conversationID: "chat", runID: runID,
        kind: kind, transcript: pointer.map { .init(conversationID: "chat", activities: [
          .init(id: "trace", runID: "run", title: "Thinking", status: "completed", projectionJSON: "{\"id\":\"trace\",\"detailVersion\":3}", detailsRecordID: $0)
        ]) }, nativeRecord: part))
    }
    func expectError(_ code: String) async throws {
      do {
        _ = try await journal.activityDetails(conversationID: "chat", activityID: "trace")
        XCTFail("Incomplete or invalid chain returned a disclosure")
      } catch let error as LibraryAPIError { XCTAssertEqual(error.code, code) }
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
      func record(_ journal: WorkspaceJournal, _ part: NativeRecordPart, runID: String = "run") async throws {
        sequence += 1
        try await journal.record(.init(workspaceID: "owner", originSequence: sequence, conversationID: "chat",
          runID: runID, kind: .nativeRecord, nativeRecord: part))
      }
      let originalParts = try parts("base", base, version: 1, title: "Thinking", detailsAvailable: false)
        + parts("head", "Fresh suffix 🧵", previous: "base", version: 2, title: "Thinking", detailsAvailable: false)
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
      } catch let error as LibraryAPIError { XCTAssertEqual(error.code, "invalid_activity_details") }
    }
  }

  /// A Quick Chat is projected from its native history every time it is
  /// opened. Each turn keeps the run ID stored for it, so projecting a stored
  /// chat again changes nothing: the journal records no new run and no second
  /// copy of a tool activity. Only a turn that is not stored yet gets an ID.
  func testProjectingAStoredChatAgainRecordsNothingNew() async throws {
    let turn = "0a0a0a0a-0000-4000-8000-000000000001"
    var entries: [[String: Any]] = [
      ["id": 1, "model": [["role": "user", "content": "List my files.", "timestamp": 1_000]]],
      ["id": 2, "model": [["role": "assistant", "content": [["type": "toolCall", "id": "files", "name": "list_files", "arguments": [:]]], "timestamp": 2_000]]],
      ["id": 3, "model": [["role": "toolResult", "toolCallId": "files", "toolName": "list_files", "content": [["type": "text", "text": "[]"]], "timestamp": 3_000]]],
      ["id": 4, "model": [["role": "assistant", "content": [["type": "text", "text": "No files."]], "timestamp": 4_000]]]]
    // `stored` is nil for a chat this build first projects, and otherwise the
    // run ID its first turn was stored with, however that ID was made.
    for stored in [nil, turn] as [String?] {
      let journal = try WorkspaceJournal(file: file())
      let chat = LibraryConversation(id: "c", title: "Chat")
      var runs = await journal.storedRuns(conversationID: "c")
      XCTAssertEqual(runs, .init())
      if let stored { runs = .init(turns: ["c-1-0": stored]) }
      let first = DeviceTranscript.project(snapshot: ["entries": entries], conversationID: "c", storedRuns: runs)
      if let stored { XCTAssertEqual(first.runs?.map(\.id), [stored]) }
      let recorded = try await journal.append(workspaceID: "phone", conversation: chat, transcript: first)
      XCTAssertFalse(recorded.isEmpty)

      runs = await journal.storedRuns(conversationID: "c")
      XCTAssertEqual(runs, .init(turns: ["c-1-0": try XCTUnwrap(first.runs?.first?.id)]))
      let again = DeviceTranscript.project(snapshot: ["entries": entries], conversationID: "c", storedRuns: runs)
      XCTAssertEqual(again, first)
      let nothing = try await journal.append(workspaceID: "phone", conversation: chat, transcript: again)
      XCTAssertTrue(nothing.isEmpty, "The same chat projected again is the same rows")

      // The next turn: one new run, and every stored row as it was.
      let longer = entries + [
        ["id": 5, "model": [["role": "user", "content": "And notes?", "timestamp": 5_000]]],
        ["id": 6, "model": [["role": "assistant", "content": [["type": "toolCall", "id": "files", "name": "list_notes", "arguments": [:]]], "timestamp": 6_000]]]]
      let next = DeviceTranscript.project(snapshot: ["entries": longer], conversationID: "c", storedRuns: runs)
      let added = try await journal.append(workspaceID: "phone", conversation: chat, transcript: next)
      let delta = try XCTUnwrap(added.compactMap(\.transcript).first)
      XCTAssertEqual(next.runs?.count, 2)
      let newRun = try XCTUnwrap(next.runs?.last?.id)
      XCTAssertNotEqual(newRun, first.runs?.first?.id)
      XCTAssertEqual(Set(delta.messages.compactMap(\.runID)), [newRun])
      XCTAssertEqual(delta.activities.map(\.id), [newRun + ":files"])
      let state = await journal.snapshot()
      XCTAssertEqual(state.transcripts["c"]?.activities.map(\.id), [try XCTUnwrap(first.runs?.first?.id) + ":files", newRun + ":files"])
      XCTAssertEqual(state.transcripts["c"]?.runs?.map(\.id), next.runs?.map(\.id))
      if stored == nil { entries = Array(longer.prefix(4)) }
    }
  }

  private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json") }
}

private func parts(_ recordID: String, _ text: String, previous: String? = nil, id: String = "trace",
  version: Int = 3, title: String = "Newest metadata", detailsAvailable: Bool = true) throws -> [NativeRecordPart] {
  var value: [String: Any] = ["id": id, "kind": "thought", "title": title, "content": text,
    "contentIsDelta": previous != nil, "detailVersion": version]
  if detailsAvailable { value["detailsAvailable"] = true }
  var envelope: [String: Any] = ["activity": value]
  if let previous { envelope["previousDetailsRecordID"] = previous }
  let bytes = try JSONSerialization.data(withJSONObject: envelope), chunk = 131_072
  let count = (bytes.count + chunk - 1) / chunk
  let digest = SHA256.hash(data: bytes).hexString
  return (0..<count).map { .init(recordID: recordID, format: NativeRecordFormat.chainedActivity.name, partIndex: $0,
    partCount: count, byteCount: Int64(bytes.count), sha256: digest,
    data: bytes.subdata(in: $0 * chunk..<min(bytes.count, ($0 + 1) * chunk))) }
}
