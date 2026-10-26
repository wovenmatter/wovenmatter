import XCTest
import WovenMatterCompanion
@testable import CompanionClient

final class TranscriptDetailTests: XCTestCase {
  func testHTMLReplyRebuildsFromNativeToolResultAndSurvivesJournalReopen() async throws {
    let html = "<button onclick='this.textContent=42'>Calculate</button><img src='data:image/png;base64," + String(repeating: "A", count: 100_000) + "'>"
    let request: [String: Any] = ["action": "render", "html": "<img src='/device-workspace/image.png'>", "title": "Calculator", "height": 160]
    var prepared = request; prepared["html"] = html
    let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    let reference: [String: Any] = ["id": UUID().uuidString.lowercased(), "title": "Calculator", "height": 160]
    let response = String(decoding: try JSONSerialization.data(withJSONObject: ["success": true, "result": ["htmlRender": reference]]), as: UTF8.self)
    let snapshot: [String: Any] = ["entries": [
      ["id": 1, "model": [["role": "user", "content": "Calculate"]]],
      ["id": 2, "model": [["role": "assistant", "content": [["type": "toolCall", "id": "render", "name": "wovenmatter_html", "arguments": ["arguments": ["call", "--json", json]]]]]]],
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
    let failedResponse = response.replacingOccurrences(of: "true", with: "false")
    var failedSnapshot = snapshot
    var entries = try XCTUnwrap(failedSnapshot["entries"] as? [[String: Any]])
    entries[2]["model"] = [["role": "toolResult", "toolCallId": "render", "content": [["type": "text", "text": failedResponse]]]]
    failedSnapshot["entries"] = entries
    let failed = CompanionDeviceTranscript.project(snapshot: failedSnapshot, conversationID: "c")
    XCTAssertFalse(failed.activities.first?.projectionJSON?.contains("htmlRender\":") ?? true)
  }

  private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json") }
  private func activity(content: String) throws -> CompanionActivity {
    let object: [String: Any] = ["id":"call", "kind":"tool", "title":"read_file", "status":"completed",
      "toolName":"read_file", "content":content, "rawOutputJSON":content, "locations":[], "changes":[], "planEntries":[]]
    return .init(id:"call", runID:"turn", title:"read_file", status:"completed",
      projectionJSON:String(decoding: try JSONSerialization.data(withJSONObject:object), as:UTF8.self), sequence:1)
  }
  func testLegacyToolMigrationPreservesUserTextAndOriginalJournal() async throws {
    let journal = try WorkspaceJournal(file:file())
    let old = CompanionTranscript(conversationID:"c", messages:[
      .init(id:"c-1-0", conversationID:"c", role:"user", content:"Inspect"),
      .init(id:"c-2-0", conversationID:"c", role:"assistant", content:"Tool: list_files"),
      .init(id:"c-3-0", conversationID:"c", role:"tool", content:String(repeating:"old result\n", count:4_000))
    ])
    let originals = try await journal.append(workspaceID:"phone", transcript:old)
    let snapshot: [String:Any] = ["entries":[
      ["id":1,"model":[["role":"user","content":"Inspect"]]],
      ["id":2,"model":[["role":"assistant","content":[["type":"toolCall","id":"files","name":"list_files","arguments":[:]]]]]],
      ["id":3,"model":[["role":"toolResult","toolCallId":"files","content":[["type":"text","text":"[]"]]]]]
    ]]
    let projected = CompanionDeviceTranscript.project(snapshot:snapshot, conversationID:"c")
    _ = try await journal.append(workspaceID:"phone", transcript:projected)
    let state = await journal.snapshot()
    XCTAssertEqual(state.transcripts["c"]?.messages.map(\.content), ["Inspect"])
    XCTAssertEqual(state.transcripts["c"]?.activities.count, 1)
    for original in originals { XCTAssertEqual(state.entries[original.eventID], original) }
    let replay = try await journal.append(workspaceID:"phone", transcript:projected)
    XCTAssertTrue(replay.isEmpty)
    _ = try await journal.append(workspaceID:"phone", transcript:.init(conversationID:"c", messages:Array(old.messages.dropFirst())))
    let delayed = await journal.snapshot()
    XCTAssertEqual(delayed.transcripts["c"]?.messages.map(\.content), ["Inspect"])
    _ = try await journal.append(workspaceID:"phone", transcript:.init(conversationID:"c", removedMessageIDs:["c-1-0"]))
    let preserved = await journal.snapshot()
    XCTAssertEqual(preserved.transcripts["c"]?.messages.first?.content, "Inspect")
  }
  func testLargeDetailsSurviveRestartAndJournalReplication() async throws {
    let path = file()
    let journal = try WorkspaceJournal(file:path)
    let original = try activity(content:String(repeating:"café 🟩\n", count:24_000))
    let transcript = CompanionTranscript(conversationID:"c", messages:[
      .init(id:"a", conversationID:"c", runID:"turn", role:"assistant", content:"Result", sequence:2)
    ], activities:[original], runs:[.init(id:"turn", status:"completed", startedAt:"2026-10-12T10:00:00Z")])
    _ = try await journal.append(workspaceID:"phone", transcript:transcript)
    let saved = await journal.snapshot()
    XCTAssertFalse(saved.entries.values.filter { $0.kind == .nativeRecord }.isEmpty)
    XCTAssertNotNil(saved.transcripts["c"]?.activities.first?.detailsRecordID)
    XCTAssertLessThan(saved.transcripts["c"]?.activities.first?.projectionJSON?.utf8.count ?? .max, 32_768)
    let restarted = try WorkspaceJournal(file:path)
    let restored = try await restarted.activityDetails(conversationID:"c", activityID:"call")
    XCTAssertEqual(restored?.projectionJSON, original.projectionJSON)
    let restartedState = await restarted.snapshot()
    XCTAssertEqual(restartedState.transcripts["c"]?.runs, transcript.runs)
    let replica = try WorkspaceJournal(file:file())
    for entry in saved.entries.values.sorted(by: { $0.originSequence < $1.originSequence }) { try await replica.record(entry) }
    let replicated = try await replica.activityDetails(conversationID:"c", activityID:"call")
    XCTAssertEqual(replicated?.projectionJSON, original.projectionJSON)
    var settled = transcript; settled.runs?[0].completedAt = "2026-10-12T10:00:08Z"
    _ = try await journal.append(workspaceID:"phone", transcript:settled)
    let latest = await journal.snapshot()
    XCTAssertEqual(latest.transcripts["c"]?.runs?.first?.completedAt, "2026-10-12T10:00:08Z")
  }
}
