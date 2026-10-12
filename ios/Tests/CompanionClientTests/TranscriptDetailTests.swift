import XCTest
import WovenMatterCompanion
@testable import CompanionClient

final class TranscriptDetailTests: XCTestCase {
  private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json") }
  private func activity(content: String) throws -> CompanionActivity {
    let object: [String: Any] = ["id":"call", "kind":"tool", "title":"read_file", "status":"completed",
      "toolName":"read_file", "content":content, "rawOutputJSON":content, "locations":[], "changes":[], "planEntries":[]]
    return .init(id:"call", runID:"turn", title:"read_file", status:"completed",
      projectionJSON:String(decoding: try JSONSerialization.data(withJSONObject:object), as:UTF8.self), sequence:1)
  }
  func testLargeToolOutputDoesNotEvictChatMessages() async throws {
    let store = try MobileStore(file:file(), budget:.init(transcriptBytes:8_192))
    let transcript = CompanionTranscript(conversationID:"c", messages:[
      .init(id:"u", conversationID:"c", runID:"turn", role:"user", content:"Read it", sequence:0),
      .init(id:"a", conversationID:"c", runID:"turn", role:"assistant", content:"Here is the result.", sequence:2)
    ], activities:[try activity(content:String(repeating:"output🟩", count:20_000))], runs:[.init(id:"turn", status:"completed")])
    try await store.cache(transcript)
    let state = await store.snapshot()
    let cached = try XCTUnwrap(state.transcripts["c"])
    XCTAssertEqual(cached.messages, transcript.messages)
    XCTAssertEqual(cached.activities.count, 1)
    XCTAssertEqual(cached.activities.first?.sequence, 1)
    XCTAssertLessThan(try JSONEncoder().encode(cached).count, 8_192)
    let projection = try XCTUnwrap(cached.activities.first?.projectionJSON)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with:Data(projection.utf8)) as? [String:Any])
    XCTAssertNil(object["rawOutputJSON"])
    XCTAssertEqual(object["detailsAvailable"] as? Bool, true)
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
  func testTransientThoughtDoesNotLeaveDuplicateJournalRows() async throws {
    let journal = try WorkspaceJournal(file:file())
    var transient = try activity(content:"Thinking")
    transient.id = "streaming-thought"; transient.isTransient = true
    _ = try await journal.append(workspaceID:"phone", transcript:.init(conversationID:"c", activities:[transient]))
    let live = await journal.snapshot()
    XCTAssertTrue(live.transcripts["c"]?.activities.isEmpty == true)
    var final = transient; final.id = "saved-thought"; final.isTransient = nil
    _ = try await journal.append(workspaceID:"phone", transcript:.init(conversationID:"c", activities:[final]))
    let settled = await journal.snapshot()
    XCTAssertEqual(settled.transcripts["c"]?.activities.map(\.id), ["saved-thought"])
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
