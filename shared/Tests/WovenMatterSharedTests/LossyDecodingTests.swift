import Foundation
import Testing
@testable import WovenMatterShared

private func decode<Value: Decodable>(_ type: Value.Type, _ json: String) throws -> Value {
  try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func object<Value: Encodable>(_ value: Value) throws -> [String: Any] {
  try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
}

private let folder = #"{"id":"f1","name":"Work","revision":1,"updatedAt":""}"#
private func note(_ id: String, kind: String? = "note") -> String {
  #"{"id":"\#(id)","title":"T","content":"{}","contentIncluded":true,"contentByteCount":2,"revision":3,"updatedAt":""\#(kind.map { #","kind":"\#($0)""# } ?? "")}"#
}
private func conversation(_ id: String) -> String { #"{"id":"\#(id)","title":"Chat","preview":"","updatedAt":""}"# }
private func entry(_ sequence: Int, kind: String = "deletedConversation", workspace: String = "w") -> String {
  #"{"eventID":"e\#(sequence)","workspaceID":"\#(workspace)","originSequence":\#(sequence),"conversationID":"c","kind":"\#(kind)"}"#
}
private func interaction(_ id: String, kind: String) -> String {
  #"{"id":"\#(id)","conversationID":"c","kind":"\#(kind)","title":"Run?","options":[],"questions":[]}"#
}
private func workspace(_ id: String, kind: String) -> String {
  #"{"id":"\#(id)","libraryID":"l","ownerDeviceID":"o","kind":"\#(kind)","name":"Device","capabilities":[],"journalDeviceIDs":[],"revision":1,"deleted":false}"#
}

/// Devices of one user run different versions for days. What an older build
/// reads from a newer one keeps everything it understands.
@Suite("Reading what a newer build wrote")
struct LossyDecodingTests {
  @Test("a library snapshot keeps the items it can read and says which lists are incomplete")
  func snapshot() throws {
    let snapshot = try decode(LibrarySnapshot.self, #"""
      {"workspaceID":"library","cursor":41,
       "folders":[\#(folder),{"id":"f2","name":7}],
       "notes":[\#(note("n1")),\#(note("n2", kind: "slides")),{"id":"n3","title":["not","text"]},\#(note("n4", kind: "html"))],
       "conversations":[\#(conversation("c1")),\#(conversation("c2"))]}
      """#)
    #expect(snapshot.cursor == 41)
    #expect(snapshot.folders.map(\.id) == ["f1"])
    // A note of a kind a newer build added still syncs; only the hint is absent.
    #expect(snapshot.notes.map(\.id) == ["n1", "n2", "n4"])
    #expect(snapshot.notes.map(\.kind) == [.note, nil, .html])
    #expect(snapshot.conversations.map(\.id) == ["c1", "c2"])
    #expect(!snapshot.hasEveryFolder && !snapshot.hasEveryNote && snapshot.hasEveryConversation)
    let whole = LibrarySnapshot(workspaceID: "library", cursor: 1, notes: snapshot.notes)
    #expect(whole.hasEveryFolder && whole.hasEveryNote && whole.hasEveryConversation)
  }

  @Test("a change page drops a change it cannot read and its cursor still moves past it")
  func changePage() throws {
    let page = try decode(LibraryChangePage.self, #"""
      {"workspaceID":"library","cursor":9,"hasMore":true,"resetRequired":false,"changes":[
        {"cursor":7,"resourceKind":"folder","resourceID":"f1","operation":"upsert","revision":1,"folder":\#(folder)},
        {"cursor":8,"resourceKind":"calendar","resourceID":"e1","operation":"upsert","revision":1},
        {"cursor":9,"resourceKind":"note","resourceID":"n2","operation":"upsert","revision":3,"note":\#(note("n2", kind: "slides"))}]}
      """#)
    #expect(page.changes.map(\.cursor) == [7, 9])
    #expect(page.changes.last?.note?.id == "n2" && page.changes.last?.note?.kind == nil)
    #expect(page.cursor == 9 && page.hasMore)
  }

  @Test("a journal page names the position of an entry it cannot read, and needs that position")
  func journalPage() throws {
    let page = try decode(ExecutionJournalPage.self, #"""
      {"libraryID":"library","cursor":4,"hasMore":false,"entries":[
        \#(entry(1)),\#(entry(2, kind: "forkedConversation")),\#(entry(3)),
        {"eventID":"e4","workspaceID":"w","originSequence":4,"conversationID":"c","kind":"receipt",
         "receipt":{"commandID":"k","deviceID":"d","status":"superseded"}}]}
      """#)
    #expect(page.entries.map(\.originSequence) == [1, 3])
    #expect(page.skipped == [.init(workspaceID: "w", originSequence: 2), .init(workspaceID: "w", originSequence: 4)])
    #expect(page.cursor == 4)
    // What a serving member skipped travels with what this build skips.
    let served = try decode(ExecutionJournalPage.self, #"""
      {"libraryID":"library","cursor":3,"hasMore":true,"skipped":[{"workspaceID":"w","originSequence":1}],
       "entries":[\#(entry(2)),\#(entry(3, kind: "forkedConversation", workspace: "x"))]}
      """#)
    #expect(served.skipped == [.init(workspaceID: "w", originSequence: 1), .init(workspaceID: "x", originSequence: 3)])
    // Without a workspace and sequence there is no position to move past.
    #expect(throws: DecodingError.self) {
      try decode(ExecutionJournalPage.self, #"{"libraryID":"library","cursor":1,"hasMore":false,"entries":[{"kind":"forkedConversation"}]}"#)
    }
    #expect(try decode(ExecutionJournalPage.self, #"{"libraryID":"library","cursor":2,"hasMore":false,"entries":[\#(entry(1)),\#(entry(2))]}"#).skipped == nil)
  }

  @Test("registry and pending lists drop only the element of a kind this build does not know")
  func lists() throws {
    let registry = try decode(LossyArray<ExecutionWorkspace>.self, "[\(workspace("a", kind: "mac")),\(workspace("b", kind: "visionos")),\(workspace("c", kind: "linux"))]")
    #expect(registry.wrappedValue.map(\.id) == ["a", "c"] && registry.unreadable.count == 1)
    let pending = try decode(LossyArray<PendingInteraction>.self, "[\(interaction("q1", kind: "approval")),\(interaction("q2", kind: "signature")),\(interaction("q3", kind: "question"))]")
    #expect(pending.wrappedValue.map(\.id) == ["q1", "q3"])
    let stream = try decode(StreamPending.self, #"{"interactions":[\#(interaction("q2", kind: "signature")),\#(interaction("q3", kind: "question"))]}"#)
    #expect(stream.interactions.map(\.id) == ["q3"])
    #expect(try decode(LossyArray<PendingInteraction>.self, "[]").wrappedValue.isEmpty)
    // A list that is not a list is still an error, not an empty list.
    #expect(throws: DecodingError.self) { try decode(LossyArray<PendingInteraction>.self, #"{"interactions":[]}"#) }
  }

  @Test("session settings arrive without a goal in a state this build does not know")
  func sessionSettings() throws {
    let goal = #"{"id":"g","sessionID":"s","objective":"Ship","status":"awaiting_review","completedTurns":0,"createdAt":0,"updatedAt":0,"baselineRunSequence":0,"observedRunSequence":0,"enrolledRunSequence":0,"progressRevision":0,"pendingProgressRevision":0}"#
    func settings(_ goal: String) throws -> SessionSettings {
      try decode(SessionSettings.self, #"{"conversationID":"s","model":"m","models":[],"thinkingLevels":[],"permissions":[],"availableTools":[],"enabledTools":["notes"],"canConfigure":true,"goal":\#(goal)}"#)
    }
    let future = try settings(goal)
    #expect(future.goal == nil && future.model == "m" && future.enabledTools == ["notes"] && future.canConfigure)
    #expect(try settings(goal.replacingOccurrences(of: "awaiting_review", with: "paused")).goal?.status == .paused)
    #expect(try settings("null").goal == nil)
  }

  @Test("the wrappers encode exactly as the array or optional they wrap")
  func encoding() throws {
    let plain = LibraryNote(id: "n", title: "T", content: "{}")
    #expect(try object(plain)["kind"] == nil)
    #expect(try object(LibraryNote(id: "n", title: "T", content: "{}", kind: .html))["kind"] as? String == "html")
    #expect(try JSONDecoder().decode(LibraryNote.self, from: JSONEncoder().encode(plain)) == plain)
    // A note with no kind key at all, as older hosts send it.
    #expect(try decode(LibraryNote.self, note("n", kind: nil)).kind == nil)
    let snapshot = LibrarySnapshot(workspaceID: "library", cursor: 2, folders: [.init(id: "f", name: "Work")], notes: [plain])
    let encoded = try object(snapshot)
    #expect((encoded["folders"] as? [[String: Any]])?.count == 1 && (encoded["notes"] as? [[String: Any]])?.count == 1)
    #expect((encoded["conversations"] as? [Any])?.isEmpty == true)
    #expect(try JSONDecoder().decode(LibrarySnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
    let settings = SessionSettings(conversationID: "s", model: nil, thinking: nil, permission: nil, models: [], thinkingLevels: [],
                                   permissions: [], availableTools: [], enabledTools: [], canConfigure: true)
    #expect(try object(settings)["goal"] == nil)
    let page = ExecutionJournalPage(libraryID: "library", cursor: 0)
    #expect(try object(page).keys.sorted() == ["cursor", "entries", "hasMore", "libraryID"])
  }

  @Test("what a device must not lose is still refused whole")
  func writesStayStrict() throws {
    // A sender keeps a batch the host cannot read and retries after the host updates.
    #expect(throws: DecodingError.self) {
      try decode(ExecutionJournalBatch.self, #"{"libraryID":"library","entries":[\#(entry(1)),\#(entry(2, kind: "forkedConversation"))]}"#)
    }
    #expect(throws: DecodingError.self) {
      try decode(LibraryWorkspaceRegistration.self, #"{"workspace":\#(workspace("b", kind: "visionos"))}"#)
    }
    #expect(throws: DecodingError.self) {
      try decode(LibraryCommandReceipt.self, #"{"commandID":"k","deviceID":"d","status":"superseded"}"#)
    }
    #expect(throws: DecodingError.self) {
      try decode(LibraryMutationResult.self, #"{"operationID":"o","status":"deferred"}"#)
    }
  }
}
