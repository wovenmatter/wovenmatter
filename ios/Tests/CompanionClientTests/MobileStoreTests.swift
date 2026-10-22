import XCTest
@testable import CompanionClient
import WovenMatterCompanion

final class MobileStoreTests: XCTestCase {
  func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json") }
  func content(_ text: String) throws -> String { try NoteDocument(blocks: [.richText(.init(id: "stable-block", text: text))]).encoded() }

  func testCacheBudgetDoesNotEvictUnsyncedNotes() async throws {
    let store = try MobileStore(file: file(), budget: .init(noteBytes: 1_600))
    let note = try await store.createNote(folderID: nil, title: "Unsynced", content: content("keep"))
    let remote = (0..<20).map { CompanionNote(id: "remote-\($0)", title: "Remote", content: String(repeating: "r", count: 150)) }
    try await store.apply(.init(workspaceID: "mac", cursor: 1, notes: remote))
    let state = await store.snapshot()
    XCTAssertEqual(state.notes[note.id], note)
    XCTAssertTrue(state.isDirty(note.id))
  }

  func testRichEditPreservesUnchangedTablesUnknownKeysLinksAndIDs() throws {
    let document = NoteDocument(blocks: [.richText(.init(id: "text", style: .heading2, runs: [.init(text: "Hello", bold: true, link: "https://example.com")])), .table(.init(rows: 2, columns: 2, headerRow: true))])
    var raw = try JSONSerialization.jsonObject(with: Data(document.encoded().utf8)) as! [String: Any]
    let source = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
    let edited = try RichDocumentEditing.replacingText(in: source, blockID: "text", range: .init(location: 5, length: 0), replacement: " world")
    let decoded = RichDocumentEditing.document(edited)!
    XCTAssertEqual(decoded.blocks[0].id, "text")
    XCTAssertEqual(decoded.blocks[1], document.blocks[1])
    guard case .richText(let block) = decoded.blocks[0] else { return XCTFail() }
    XCTAssertTrue(block.runs.allSatisfy(\.bold)); XCTAssertTrue(block.runs.allSatisfy { $0.link == "https://example.com" })
    XCTAssertEqual(block.plainText, "Hello world")
    let result = try JSONSerialization.jsonObject(with: Data(edited.utf8)) as! [String: Any]
    XCTAssertNotNil(result["blocks"])
    raw["futureDocumentMetadata"] = ["keep": true]
    let unknown = String(decoding: try JSONSerialization.data(withJSONObject: raw), as: UTF8.self)
    XCTAssertFalse(RichDocumentEditing.canEdit(unknown))
  }

  func testFutureDocumentAndUnknownRunsAreNotFlattened() throws {
    let future = "{\"version\":999,\"blocks\":[{\"type\":\"drawing\",\"value\":\"keep\"}]}"
    XCTAssertFalse(RichDocumentEditing.canEdit(future))
    XCTAssertThrowsError(try RichDocumentEditing.appendingParagraph(to: future))
    let source = try content("😀 note")
    XCTAssertThrowsError(try RichDocumentEditing.replacingText(in: source, blockID: "stable-block", range: .init(location: 1, length: 0), replacement: "bad"))
  }
  func testDelayedEditorSaveCannotAdoptConcurrentRemoteRevision() async throws {
    let store = try MobileStore(file: file())
    let displayed = CompanionNote(id: "note", title: "Original", content: try content("base"), revision: 2)
    try await store.apply(.init(workspaceID: "mac", cursor: 1, notes: [displayed]))
    let remote = CompanionNote(id: "note", title: "Mac title", content: try content("Mac body"), revision: 3)
    try await store.apply(.init(workspaceID: "mac", cursor: 2, notes: [remote]))
    try await store.editNote(id: displayed.id, title: "iPhone title", content: content("held draft"), folderID: nil, base: displayed)
    let state = await store.snapshot()
    XCTAssertEqual(state.conflicts[displayed.id]?.base, displayed)
    XCTAssertEqual(state.conflicts[displayed.id]?.remote, remote)
    XCTAssertEqual(state.conflicts[displayed.id]?.local.content, try content("held draft"))
    XCTAssertTrue(state.outbox.isEmpty)
  }
  func testOversizePasteAndBlockAdditionAreRejectedBeforeEditorAdoption() throws {
    let saved = try content("Saved writing")
    var visible = saved
    XCTAssertThrowsError(try { visible = try RichDocumentEditing.replacingText(in: saved, blockID: "stable-block", range: .init(location: 0, length: 0), replacement: String(repeating: "x", count: CompanionProtocol.maximumNoteBytes)) }())
    XCTAssertEqual(visible, saved)
    XCTAssertTrue(RichDocumentEditing.canEdit(visible))
    let full = try NoteDocument(blocks: (0..<10_000).map { .richText(.init(id: "block-\($0)", text: "")) }).encoded()
    XCTAssertTrue(RichDocumentEditing.canEdit(full))
    var visibleBlocks = full
    XCTAssertThrowsError(try { visibleBlocks = try RichDocumentEditing.appendingParagraph(to: full) }())
    XCTAssertEqual(visibleBlocks, full)
  }
  func testHTMLLinkedDataEscapesScriptBoundariesAndRetainsOfflineCSP() {
    let html = MobileArtifactPreview.renderedHTML(html: "<p id='chart'></p>", linkedDataJSON: "{\"value\":\"</script>&>\u{2028}\u{2029}\"}")
    XCTAssertTrue(html.contains("window.wovenMatterData = {\"value\":\"\\u003c/script\\u003e\\u0026\\u003e\\u2028\\u2029\"}"))
    XCTAssertTrue(html.contains("default-src 'none'"))
    XCTAssertTrue(html.contains("script-src 'unsafe-inline'"))
    XCTAssertTrue(html.contains("form-action 'none'"))
  }

  func testOfflinePinsPreserveHistoryBeyondCacheBudgetAndRestart() async throws {
    let location = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("library")
    let store = try MobileStore(file: location, budget: .init(transcriptCount: 1, transcriptBytes: 512))
    try await store.setTranscriptPinned("pinned", true)
    let text = String(repeating: "all history ", count: 200)
    try await store.cache(.init(conversationID: "pinned", messages: [.init(id: "older", conversationID: "pinned", role: "assistant", content: text)]))
    try await store.cache(.init(conversationID: "other", messages: [.init(id: "other", conversationID: "other", role: "user", content: "recent")]))
    let restarted = try MobileStore(file: location, budget: .init(transcriptCount: 1, transcriptBytes: 512))
    let state = await restarted.snapshot()
    XCTAssertEqual(state.pinnedTranscriptIDs, ["pinned"])
    XCTAssertEqual(state.transcripts["pinned"]?.messages.first?.content, text)
  }
  func testSettledTranscriptReplacesStreamingRowsWithoutReorderingUserOrDroppingHistory() async throws {
    let location = file(), store = try MobileStore(file: location)
    try await store.setTranscriptPinned("chat", true)
    let older = CompanionMessage(id: "older", conversationID: "chat", role: "user", content: "Earlier turn")
    let user = CompanionMessage(id: "u", conversationID: "chat", runID: "r", role: "user", content: "Weather?", sequence: 0)
    let streaming = CompanionMessage(id: "chat-streaming", conversationID: "chat", runID: "r", role: "assistant", content: "Sunny", status: "streaming", sequence: 1)
    let transient = CompanionActivity(id: "thinking-live", runID: "r", title: "Thinking", status: "running", isTransient: true)
    try await store.cache(.init(conversationID: "chat", messages: [older, user, streaming], activities: [transient]))
    // The final SDK entry gets a durable ID, unlike the temporary streaming row.
    let final = CompanionMessage(id: "answer", conversationID: "chat", runID: "r", role: "assistant", content: "Sunny and breezy.", sequence: 1)
    try await store.cache(.init(conversationID: "chat", messages: [user, final]))
    let restarted = try MobileStore(file: location)
    let state = await restarted.snapshot()
    let transcript = try XCTUnwrap(state.transcripts["chat"])
    XCTAssertEqual(transcript.messages.map(\.id), ["older", "u", "answer"])
    XCTAssertTrue(transcript.activities.isEmpty)
  }

}
