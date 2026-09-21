import XCTest
@testable import CompanionClient
import WovenMatterCompanion

final class MobileStoreTests: XCTestCase {
  func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json") }
  func content(_ text: String) throws -> String { try NoteDocument(blocks: [.richText(.init(id: "stable-block", text: text))]).encoded() }

  func testOfflineFolderNoteAndDraftSurviveRestartInDependencyOrder() async throws {
    let url = file(); let store = try MobileStore(file: url)
    let folder = try await store.createFolder(name: "Ideas")
    let note = try await store.createNote(folderID: folder.id, title: "Capture", content: content("offline"))
    try await store.editNote(id: note.id, title: "Better idea", content: content("durable writing"), folderID: folder.id)
    let restarted = try MobileStore(file: url)
    let state = await restarted.snapshot()
    XCTAssertEqual(state.notes[note.id]?.title, "Better idea")
    XCTAssertEqual(state.outbox.count, 2)
    let first = try await restarted.nextMutation()
    XCTAssertEqual(first?.kind, .createFolder)
    try await restarted.acknowledge(.init(operationID: first!.operationID, status: .accepted, folder: .init(id: folder.id, name: folder.name)))
    let second = try await restarted.nextMutation()
    XCTAssertEqual(second?.kind, .createNote)
    XCTAssertEqual(second?.resourceID, note.id)
  }

  func testLostAcknowledgementResendsExactIDAndContentDespiteNewEdit() async throws {
    let url = file(); let store = try MobileStore(file: url)
    let note = try await store.createNote(folderID: nil, title: "Idea", content: content("first"))
    let sent = try await store.nextMutation()!
    try await store.editNote(id: note.id, title: "Idea", content: content("second"), folderID: nil)
    let restarted = try MobileStore(file: url)
    let retry = try await restarted.nextMutation()
    XCTAssertEqual(retry, sent)
    let remote = CompanionNote(id: note.id, title: "Idea", content: sent.content!, revision: 7)
    try await restarted.acknowledge(.init(operationID: sent.operationID, status: .accepted, note: remote))
    let successor = try await restarted.nextMutation()
    XCTAssertEqual(successor?.expectedRevision, 7)
    XCTAssertNotEqual(successor?.operationID, sent.operationID)
    XCTAssertEqual(successor?.content, try content("second"))
    try await restarted.acknowledge(.init(operationID: sent.operationID, status: .accepted, note: remote))
    let afterRepeatedAck = await restarted.snapshot()
    XCTAssertEqual(afterRepeatedAck.outbox.count, 1)
  }

  func testConflictKeepsBaseLocalRemoteAndCopyUsesNewIdentity() async throws {
    let store = try MobileStore(file: file())
    let base = CompanionNote(id: "note", title: "Plan", content: try content("base"), revision: 2)
    try await store.apply(.init(workspaceID: "mac", cursor: 1, notes: [base]))
    try await store.editNote(id: "note", title: "Plan", content: content("local"), folderID: nil)
    let mutation = try await store.nextMutation()!
    var remote = base; remote.content = try content("remote"); remote.revision = 3
    try await store.acknowledge(.init(operationID: mutation.operationID, status: .conflict, note: remote))
    let conflict = await store.snapshot().conflicts["note"]
    XCTAssertEqual(conflict?.base, base)
    XCTAssertEqual(conflict?.remote, remote)
    XCTAssertEqual(conflict?.local.content, try content("local"))
    let copy = try await store.preserveConflictAsCopy(id: "note")
    XCTAssertNotEqual(copy.id, base.id)
    XCTAssertEqual(copy.content, try content("local"))
    let state = await store.snapshot()
    XCTAssertEqual(state.notes[base.id], remote)
    XCTAssertEqual(state.outbox.count, 1)
  }

  func testDeletionNeverDiscardsOrResurrectsDirtyWriting() async throws {
    let url = file(); let store = try MobileStore(file: url)
    let base = CompanionNote(id: "note", title: "Plan", content: try content("base"), revision: 2)
    try await store.apply(.init(workspaceID: "mac", cursor: 1, notes: [base]))
    try await store.editNote(id: base.id, title: "Plan", content: content("local survives"), folderID: nil)
    try await store.apply(.init(workspaceID: "mac", cursor: 2, changes: [.init(cursor: 2, resourceKind: .note, resourceID: base.id, operation: .delete, revision: 3)]))
    let restarted = try MobileStore(file: url)
    let state = await restarted.snapshot()
    XCTAssertEqual(state.conflicts[base.id]?.local.content, try content("local survives"))
    XCTAssertNil(state.conflicts[base.id]?.remote)
    let next = try await restarted.nextMutation()
    XCTAssertNil(next)
  }

  func testSnapshotResetPreservesUnsyncedWritingAndRejectsDifferentWorkspace() async throws {
    let store = try MobileStore(file: file())
    try await store.apply(CompanionSnapshot(workspaceID: "mac", cursor: 9))
    let local = try await store.createNote(folderID: nil, title: "Local", content: content("safe"))
    try await store.apply(CompanionSnapshot(workspaceID: "mac", cursor: 100))
    var state = await store.snapshot()
    XCTAssertEqual(state.notes[local.id], local)
    do { try await store.apply(CompanionSnapshot(workspaceID: "other", cursor: 0)); XCTFail("Workspace was switched") }
    catch MobileStore.Failure.wrongWorkspace {}
    state = await store.snapshot()
    XCTAssertEqual(state.workspaceID, "mac")
  }

  func testTranscriptCacheCountAndBytesSurviveRestart() async throws {
    let url = file(); let store = try MobileStore(file: url, budget: .init(transcriptCount: 2, transcriptBytes: 1_500))
    for i in 0..<10 {
      let id = String(i)
      try await store.cache(.init(conversationID: id, messages: [.init(id: id, conversationID: id, role: "assistant", content: String(repeating: "x", count: 400))]))
    }
    let restarted = try MobileStore(file: url)
    let state = await restarted.snapshot()
    XCTAssertLessThanOrEqual(state.transcripts.count, 2)
    XCTAssertLessThanOrEqual(try JSONEncoder().encode(state.transcripts).count, 1_500)
    XCTAssertNotNil(state.transcripts["9"])
  }

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
  func testPopulatedLibraryIdleDoesNotWriteAndSmallEditDoesNotRewriteLibrary() async throws {
    let store = try MobileStore(file: file())
    let notes = try (0..<40).map { CompanionNote(id: "note-\($0)", title: "Note", content: try content(String(repeating: "x", count: 30_000)), revision: 1) }
    let snapshot = CompanionSnapshot(workspaceID: "mac", cursor: 1, notes: notes)
    try await store.apply(snapshot)
    let before = await store.persistenceStatistics()
    for _ in 0..<10 { try await store.apply(CompanionChangePage(workspaceID: "mac", cursor: 1)); try await store.apply(snapshot) }
    let idle = await store.persistenceStatistics()
    XCTAssertEqual(idle.writes, before.writes)
    try await store.editNote(id: "note-0", title: "Changed", content: content("small replacement"), folderID: nil, base: notes[0])
    let edit = await store.persistenceStatistics()
    XCTAssertLessThan(edit.lastBytes, 80_000)
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

}
