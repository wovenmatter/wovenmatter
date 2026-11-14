import XCTest
@testable import LibraryClient
import WovenMatterShared

final class MobileStoreTests: XCTestCase {
  func content(_ text: String) throws -> String { try NoteDocument(blocks: [.richText(.init(id: "stable-block", text: text))]).encoded() }

  func testSelectedFormattingPreservesOtherRunsBlocksAndUnknownDocumentFields() throws {
    var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try content("Before selected after").utf8)) as? [String: Any])
    let source = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
    let styled = try RichDocumentEditing.formattingText(in: source, blockID: "stable-block", range: NSRange(location: 7, length: 8), format: .bold)
    let document = try XCTUnwrap(RichDocumentEditing.document(styled))
    guard case .richText(let block) = document.blocks[0] else { return XCTFail("Expected rich text") }
    XCTAssertEqual(block.runs.map(\.text), ["Before ", "selected", " after"])
    XCTAssertEqual(block.runs.map(\.bold), [false, true, false])
    let restoredRaw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(styled.utf8)) as? [String: Any])
    XCTAssertNotNil(restoredRaw["blocks"])
    raw["futureDocumentField"] = ["preserve": true]
    let future = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
    XCTAssertThrowsError(try RichDocumentEditing.formattingText(in: future, blockID: block.id, range: nil, format: .bold), "Unfamiliar document semantics must never be flattened")
    let italic = try RichDocumentEditing.formattingText(in: styled, blockID: block.id, range: NSRange(location: 7, length: 8), format: .italic)
    let unbold = try RichDocumentEditing.formattingText(in: italic, blockID: block.id, range: NSRange(location: 7, length: 8), format: .bold)
    guard case .richText(let result) = try XCTUnwrap(RichDocumentEditing.document(unbold)).blocks[0] else { return XCTFail("Expected rich text") }
    XCTAssertTrue(result.runs[1].italic)
    XCTAssertFalse(result.runs[1].bold)
    XCTAssertEqual(result.plainText, "Before selected after")
    XCTAssertThrowsError(try RichDocumentEditing.formattingText(in: source, blockID: block.id, range: NSRange(location: 100, length: 2), format: .underline))
    let emoji = try content("A👨‍👩‍👧‍👦 B")
    XCTAssertThrowsError(try RichDocumentEditing.formattingText(in: emoji, blockID: block.id, range: NSRange(location: 2, length: 1), format: .bold))
  }

  func testCaretTypingAttributesApplyOnlyToInsertedTextAndPreserveNeighbors() throws {
    let source = try content("Before after")
    var attributes = NoteTextRun(text: "", bold: true, italic: true, highlightHex: "#FFF59D")
    attributes.fontFamily = "Georgia"
    let result = try RichDocumentEditing.replacingText(in: source, blockID: "stable-block", range: NSRange(location: 7, length: 0), replacement: "typed ", attributes: attributes)
    guard case .richText(let block) = try XCTUnwrap(RichDocumentEditing.document(result)).blocks[0] else { return XCTFail("Expected rich text") }
    XCTAssertEqual(block.runs.map(\.text), ["Before ", "typed ", "after"])
    XCTAssertFalse(block.runs[0].bold); XCTAssertFalse(block.runs[2].bold)
    XCTAssertTrue(block.runs[1].bold); XCTAssertTrue(block.runs[1].italic)
    XCTAssertEqual(block.runs[1].fontFamily, "Georgia")
    let empty = try content("")
    let inserted = try RichDocumentEditing.replacingText(in: empty, blockID: "stable-block", range: NSRange(location: 0, length: 0), replacement: "First words", attributes: attributes)
    guard case .richText(let first) = try XCTUnwrap(RichDocumentEditing.document(inserted)).blocks[0] else { return XCTFail("Expected rich text") }
    XCTAssertTrue(first.runs[0].bold)
    XCTAssertEqual(first.runs[0].highlightHex, "#FFF59D")
  }

  func testTextStatisticsMatchDesktopWordsAndGraphemeCounts() {
    let document = NoteDocument(blocks: [.richText(.init(text: "Hello world")), .richText(.init(text: "One 👨‍👩‍👧‍👦"))])
    let counts = MobileNoteTextStatistics(document: document)
    XCTAssertEqual(counts.words, 3)
    XCTAssertEqual(counts.characters, document.plainText.count)
    XCTAssertEqual(counts.wordLabel, "3 words")
    XCTAssertEqual(MobileNoteTextStatistics(document: NoteDocument(blocks: [.richText(.init(text: "I"))])).characterLabel, "1 character")
  }

  func testOversizePasteAndBlockAdditionAreRejectedBeforeEditorAdoption() throws {
    let saved = try content("Saved writing")
    var visible = saved
    XCTAssertThrowsError(try { visible = try RichDocumentEditing.replacingText(in: saved, blockID: "stable-block", range: .init(location: 0, length: 0), replacement: String(repeating: "x", count: LibraryProtocol.maximumNoteBytes)) }())
    XCTAssertEqual(visible, saved)
    XCTAssertTrue(RichDocumentEditing.canEdit(visible))
    let full = try NoteDocument(blocks: (0..<10_000).map { .richText(.init(id: "block-\($0)", text: "")) }).encoded()
    XCTAssertTrue(RichDocumentEditing.canEdit(full))
    var visibleBlocks = full
    XCTAssertThrowsError(try { visibleBlocks = try RichDocumentEditing.appendingParagraph(to: full) }())
    XCTAssertEqual(visibleBlocks, full)
  }


}

/// What the phone does with a page a newer host wrote.
final class MobileStoreNewerHostTests: XCTestCase {
  private func store() throws -> MobileStore {
    try MobileStore(file: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "store.json"))
  }
  private func note(_ id: String, revision: Int = 1, kind: String = "note") -> String {
    #"{"id":"\#(id)","title":"Note \#(id)","content":"text","contentIncluded":true,"contentByteCount":4,"revision":\#(revision),"updatedAt":"","kind":"\#(kind)"}"#
  }
  private let folder = #"{"id":"f1","name":"Work","revision":1,"updatedAt":""}"#
  private let chat = #"{"id":"c1","title":"Chat","preview":"","updatedAt":""}"#

  /// "Absent from the snapshot" means "deleted on the host" only for a list
  /// this build read in full.
  func testASnapshotThisBuildCannotReadInFullDeletesNothing() async throws {
    let store = try store()
    func snapshot(cursor: Int, notes: [String], folders: [String], conversations: [String]) throws -> LibrarySnapshot {
      try JSONDecoder().decode(LibrarySnapshot.self, from: Data(
        #"{"workspaceID":"library","cursor":\#(cursor),"notes":[\#(notes.joined(separator: ","))],"folders":[\#(folders.joined(separator: ","))],"conversations":[\#(conversations.joined(separator: ","))]}"#.utf8))
    }
    try await store.apply(try snapshot(cursor: 1, notes: [note("n1"), note("n2")], folders: [folder], conversations: [chat]))
    // The host now holds n2, the folder and the chat in a shape this build
    // cannot read, and a note of a kind it does not know.
    let partial = try snapshot(cursor: 9, notes: [note("n1", revision: 2), #"{"id":"n2","title":7}"#, note("n3", kind: "slides")],
                               folders: [#"{"id":"f1","name":7}"#], conversations: [#"{"id":"c1","title":7}"#])
    XCTAssertFalse(partial.hasEveryNote || partial.hasEveryFolder || partial.hasEveryConversation)
    try await store.apply(partial)
    var state = await store.snapshot()
    XCTAssertEqual(state.cursor, 9)
    XCTAssertEqual(state.notes.keys.sorted(), ["n1", "n2", "n3"])
    XCTAssertEqual(state.notes["n1"]?.revision, 2)
    XCTAssertNil(state.notes["n3"]?.kind)
    XCTAssertEqual(state.notes["n3"]?.content, "text", "A note of a newer kind keeps its document as the host sent it")
    XCTAssertFalse(state.deletedNotes.contains("n2"))
    XCTAssertEqual(state.folders.keys.sorted(), ["f1"])
    XCTAssertEqual(state.conversations.keys.sorted(), ["c1"])
    XCTAssertNotEqual(state.libraryDeletedConversationIDs?.contains("c1"), true)
    // A snapshot read in full still removes what the host no longer holds.
    try await store.apply(try snapshot(cursor: 10, notes: [note("n1", revision: 2)], folders: [], conversations: []))
    state = await store.snapshot()
    XCTAssertEqual(state.notes.keys.sorted(), ["n1"])
    XCTAssertTrue(state.folders.isEmpty && state.conversations.isEmpty)
    // A move to another host compares both libraries in full, so it waits.
    do { try await store.rebindLibrary(to: partial, bodies: [:]); XCTFail("Moved with a partial snapshot") }
    catch MobileConnectionError.invalidResponse { }
  }

  /// The change feed is re-requested from the stored cursor, so a change this
  /// build cannot read must not hold the cursor back.
  func testAChangeThisBuildCannotReadIsPassedOverAndTheCursorAdvances() async throws {
    let store = try store()
    try await store.apply(LibrarySnapshot(workspaceID: "library", cursor: 5))
    let page = try JSONDecoder().decode(LibraryChangePage.self, from: Data(#"""
      {"workspaceID":"library","cursor":8,"hasMore":true,"resetRequired":false,"changes":[
        {"cursor":6,"resourceKind":"calendar","resourceID":"e1","operation":"upsert","revision":1},
        {"cursor":7,"resourceKind":"note","resourceID":"n1","operation":"archive","revision":1},
        {"cursor":8,"resourceKind":"note","resourceID":"n2","operation":"upsert","revision":1,"note":\#(note("n2"))}]}
      """#.utf8))
    XCTAssertEqual(page.changes.map(\.cursor), [8])
    try await store.apply(page)
    let state = await store.snapshot()
    XCTAssertEqual(state.cursor, 8)
    XCTAssertEqual(state.notes.keys.sorted(), ["n2"])
  }
}

final class MobileLaunchSelectionTests: XCTestCase {
  func testOnlyTheSameRequestRetriesAnUnconfirmedLaunchAndOthersStartSeparately() {
    func launch(_ text: String, workspace: String? = nil, provider: String = "codex", note: String? = nil) -> MobileLaunchRecord {
      var create = LibraryCommand(deviceID: "phone", kind: .createSession, conversationID: UUID().uuidString, providerID: provider)
      var send = LibraryCommand(deviceID: "phone", kind: .send, conversationID: create.conversationID, text: text, noteID: note)
      create.workspaceID = workspace; send.workspaceID = workspace
      return .init(create: create, initialSend: send)
    }
    let unknown = launch("Earlier question")
    var rejected = launch("Rejected"); rejected.createReceipt = .init(commandID: rejected.create.commandID, deviceID: "phone", status: .rejected)
    let linux = launch("Earlier question", workspace: "linux")
    let launches = [rejected, unknown, linux]
    XCTAssertEqual(MobileLaunchRecord.reusable(launches, workspaceID: nil, providerID: "codex", text: "Earlier question", noteID: nil)?.id, unknown.id,
      "Retrying the same message keeps its original IDs, so it cannot be duplicated")
    XCTAssertNil(MobileLaunchRecord.reusable(launches, workspaceID: nil, providerID: "codex", text: "A new question", noteID: nil),
      "A different message is not blocked by the unconfirmed one")
    XCTAssertNil(MobileLaunchRecord.reusable(launches, workspaceID: nil, providerID: "claude", text: "Earlier question", noteID: nil))
    XCTAssertNil(MobileLaunchRecord.reusable(launches, workspaceID: nil, providerID: "codex", text: "Earlier question", noteID: "note"))
    XCTAssertNil(MobileLaunchRecord.reusable(launches, workspaceID: nil, providerID: "codex", text: "Rejected", noteID: nil))
    XCTAssertEqual(MobileLaunchRecord.reusable(launches, workspaceID: "linux", providerID: "codex", text: "Earlier question", noteID: nil)?.id, linux.id)
  }
}
