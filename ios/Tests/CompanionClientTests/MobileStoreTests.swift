import XCTest
@testable import CompanionClient
import WovenMatterCompanion

final class MobileStoreTests: XCTestCase {
  func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json") }
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
    XCTAssertThrowsError(try { visible = try RichDocumentEditing.replacingText(in: saved, blockID: "stable-block", range: .init(location: 0, length: 0), replacement: String(repeating: "x", count: CompanionProtocol.maximumNoteBytes)) }())
    XCTAssertEqual(visible, saved)
    XCTAssertTrue(RichDocumentEditing.canEdit(visible))
    let full = try NoteDocument(blocks: (0..<10_000).map { .richText(.init(id: "block-\($0)", text: "")) }).encoded()
    XCTAssertTrue(RichDocumentEditing.canEdit(full))
    var visibleBlocks = full
    XCTAssertThrowsError(try { visibleBlocks = try RichDocumentEditing.appendingParagraph(to: full) }())
    XCTAssertEqual(visibleBlocks, full)
  }


}
