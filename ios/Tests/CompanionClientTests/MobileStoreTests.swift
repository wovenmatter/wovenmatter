import XCTest
@testable import CompanionClient
import WovenMatterCompanion

final class MobileStoreTests: XCTestCase {
  func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json") }
  func content(_ text: String) throws -> String { try NoteDocument(blocks: [.richText(.init(id: "stable-block", text: text))]).encoded() }

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

  func testCachePressurePreservesDirtyNotesAndSettledPinnedHistoryAcrossRestart() async throws {
    let location = file()
    let budget = MobileStore.Budget(transcriptCount: 1, transcriptBytes: 512, noteBytes: 1_600)
    let store = try MobileStore(file: location, budget: budget)
    let note = try await store.createNote(folderID: nil, title: "Unsynced", content: content("keep"))
    let remote = (0..<20).map { CompanionNote(id: "remote-\($0)", title: "Remote", content: String(repeating: "r", count: 150)) }
    try await store.apply(.init(workspaceID: "mac", cursor: 1, notes: remote))
    let dirty = await store.snapshot()
    XCTAssertEqual(dirty.notes[note.id], note)
    XCTAssertTrue(dirty.isDirty(note.id))
    try await store.setTranscriptPinned("chat", true)
    let older = CompanionMessage(id: "older", conversationID: "chat", role: "user", content: "Earlier turn")
    let user = CompanionMessage(id: "u", conversationID: "chat", runID: "r", role: "user", content: "Weather?", sequence: 0)
    let streaming = CompanionMessage(id: "chat-streaming", conversationID: "chat", runID: "r", role: "assistant", content: "Sunny", status: "streaming", sequence: 1)
    let transient = CompanionActivity(id: "thinking-live", runID: "r", title: "Thinking", status: "running", isTransient: true)
    try await store.cache(.init(conversationID: "chat", messages: [older, user, streaming], activities: [transient]))
    // The final SDK entry gets a durable ID, unlike the temporary streaming row.
    let text = "Sunny and breezy. " + String(repeating: "all history ", count: 200)
    let final = CompanionMessage(id: "answer", conversationID: "chat", runID: "r", role: "assistant", content: text, sequence: 1)
    try await store.cache(.init(conversationID: "chat", messages: [user, final]))
    try await store.cache(.init(conversationID: "other", messages: [.init(id: "other", conversationID: "other", role: "user", content: "recent")]))
    let restarted = try MobileStore(file: location, budget: budget)
    let state = await restarted.snapshot()
    XCTAssertEqual(state.notes[note.id], note)
    XCTAssertTrue(state.isDirty(note.id))
    let transcript = try XCTUnwrap(state.transcripts["chat"])
    XCTAssertEqual(transcript.messages.map(\.id), ["older", "u", "answer"])
    XCTAssertTrue(transcript.activities.isEmpty)
    XCTAssertEqual(state.pinnedTranscriptIDs, ["chat"])
    XCTAssertEqual(transcript.messages.last?.content, text)
  }

}
