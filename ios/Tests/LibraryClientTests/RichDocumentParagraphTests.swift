import XCTest
@testable import LibraryClient
import WovenMatterShared

final class RichDocumentParagraphTests: XCTestCase {
  private func blocks(_ content: String) throws -> [NoteRichTextBlock] {
    try XCTUnwrap(RichDocumentEditing.document(content)).blocks.compactMap { if case .richText(let block) = $0 { block } else { nil } }
  }
  private func raw(_ content: String) throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any])
  }
  private func json(_ raw: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: raw, options: [.sortedKeys]), as: UTF8.self)
  }
  private func ids() -> () -> String {
    var next = 0
    return { next += 1; return "new-\(next)" }
  }

  func testReturnAfterHeadingStartsBodyParagraphAndTypingContinuesThere() throws {
    let source = try NoteDocument(blocks: [.richText(.init(id: "title", style: .heading1, text: "Plan"))]).encoded()
    let split = try RichDocumentEditing.editing(source, blockID: "title", range: NSRange(location: 4, length: 0), replacement: "\n", newBlockID: ids())
    XCTAssertEqual(split.caret, .init(blockID: "new-1", location: 0))
    let typed = try RichDocumentEditing.editing(split.content, blockID: split.caret.blockID, range: NSRange(location: 0, length: 0), replacement: "Details")
    let result = try blocks(typed.content)
    XCTAssertEqual(result.map(\.id), ["title", "new-1"])
    XCTAssertEqual(result.map(\.style), [.heading1, .paragraph])
    XCTAssertEqual(result.map(\.plainText), ["Plan", "Details"])
    // Mid-heading breaks keep both halves as headings, and no newline is stored inside a block.
    let middle = try RichDocumentEditing.editing(source, blockID: "title", range: NSRange(location: 2, length: 0), replacement: "\n", newBlockID: ids())
    XCTAssertEqual(try blocks(middle.content).map(\.style), [.heading1, .heading1])
    XCTAssertEqual(try blocks(middle.content).map(\.plainText), ["Pl", "an"])
    XCTAssertFalse(try blocks(typed.content).contains { $0.plainText.contains("\n") })
  }

  func testListContinuesAndReturnInEmptyItemLeavesTheList() throws {
    let list = NoteListFormatting(levels: [.init(id: "list-identity", markerFormat: "{disc}")], headIndent: 24, firstLineHeadIndent: 0)
    let source = try NoteDocument(blocks: [.richText(.init(id: "item", style: .bulletedList, text: "Milk", list: list))]).encoded()
    let next = try RichDocumentEditing.editing(source, blockID: "item", range: NSRange(location: 4, length: 0), replacement: "\n", newBlockID: ids())
    var result = try blocks(next.content)
    XCTAssertEqual(result.map(\.style), [.bulletedList, .bulletedList])
    XCTAssertEqual(result[1].list?.levels.first?.id, "list-identity", "New items stay in the same native list")
    let exit = try RichDocumentEditing.editing(next.content, blockID: next.caret.blockID, range: NSRange(location: 0, length: 0), replacement: "\n", newBlockID: ids())
    result = try blocks(exit.content)
    XCTAssertEqual(result.count, 2, "Return on an empty item converts it instead of adding another")
    XCTAssertEqual(result.map(\.style), [.bulletedList, .paragraph])
    XCTAssertNil(result[1].list)
    XCTAssertEqual(exit.caret, .init(blockID: "new-1", location: 0))
  }

  func testSplitPreservesFormattingUnicodeNeighborsAndRefusesUnfamiliarFields() throws {
    let bold = NoteTextRun(text: "Café 👨‍👩‍👧‍👦 ", bold: true), plain = NoteTextRun(text: "tail")
    let table = NoteBlock.table(.init(id: "table", columns: [.init(width: 80)], rows: [.init(cells: [.init(text: "cell", backgroundHex: "#C8E6C9")])], headerRowCount: 1))
    let source = try NoteDocument(blocks: [table, .richText(.init(id: "block", runs: [bold, plain])), .richText(.init(id: "after", text: "After"))]).encoded()
    let emojiEnd = ("Café 👨‍👩‍👧‍👦" as NSString).length
    // Splitting inside the family emoji's surrogate pair is refused rather than corrupting it.
    XCTAssertThrowsError(try RichDocumentEditing.editing(source, blockID: "block", range: NSRange(location: 6, length: 0), replacement: "\n"))
    let split = try RichDocumentEditing.editing(source, blockID: "block", range: NSRange(location: emojiEnd, length: 0), replacement: "\n", newBlockID: ids())
    let result = try blocks(split.content)
    XCTAssertEqual(result.map(\.id), ["block", "new-1", "after"])
    XCTAssertEqual(result.map(\.plainText), ["Café 👨‍👩‍👧‍👦", " tail", "After"])
    XCTAssertEqual(result[0].runs.map(\.bold), [true])
    XCTAssertEqual(result[1].runs.map(\.bold), [true, false])
    let before = try XCTUnwrap(raw(source)["blocks"] as? [[String: Any]]), after = try XCTUnwrap(raw(split.content)["blocks"] as? [[String: Any]])
    XCTAssertEqual(try json(before[0]), try json(after[0]), "Untouched blocks keep their exact data")
    XCTAssertEqual(try json(before[2]), try json(after[3]))
    XCTAssertTrue(RichDocumentEditing.canEdit(split.content))

    // Data this device does not understand is never re-encoded by a structural edit.
    for place in ["document", "paragraph"] {
      var document = try raw(source)
      if place == "document" { document["futureDocumentField"] = 7 }
      else {
        var list = try XCTUnwrap(document["blocks"] as? [[String: Any]])
        var value = try XCTUnwrap(list[1]["value"] as? [String: Any]); value["futureParagraphField"] = ["alignment": "center"]
        list[1]["value"] = value; document["blocks"] = list
      }
      let future = try json(document)
      XCTAssertThrowsError(try RichDocumentEditing.editing(future, blockID: "block", range: NSRange(location: emojiEnd, length: 0), replacement: "\n"), place)
      XCTAssertThrowsError(try RichDocumentEditing.mergingBackward(future, blockID: "after"), place)
    }
  }

  func testPastedLinesBecomeParagraphsWithTheCaretAfterTheLastLine() throws {
    let source = try NoteDocument(blocks: [.richText(.init(id: "block", text: "Start end"))]).encoded()
    let pasted = try RichDocumentEditing.editing(source, blockID: "block", range: NSRange(location: 6, length: 0), replacement: "one\r\ntwo\u{2029}three ", newBlockID: ids())
    XCTAssertEqual(try blocks(pasted.content).map(\.plainText), ["Start one", "two", "three end"])
    XCTAssertEqual(pasted.caret, .init(blockID: "new-2", location: 6))
    // Replacing a selection with a break removes the selected text.
    let replaced = try RichDocumentEditing.editing(source, blockID: "block", range: NSRange(location: 5, length: 1), replacement: "\n", newBlockID: ids())
    XCTAssertEqual(try blocks(replaced.content).map(\.plainText), ["Start", "end"])
  }

  func testDeleteAtParagraphStartExitsStylesThenJoinsAndRoundTripsWithSplit() throws {
    let source = try NoteDocument(blocks: [.richText(.init(id: "first", runs: [.init(text: "Hello ", italic: true)])),
                                           .richText(.init(id: "second", style: .numberedList, text: "world"))]).encoded()
    let exited = try XCTUnwrap(try RichDocumentEditing.mergingBackward(source, blockID: "second"))
    XCTAssertEqual(try blocks(exited.content).map(\.style), [.paragraph, .paragraph])
    XCTAssertEqual(exited.caret, .init(blockID: "second", location: 0))
    let joined = try XCTUnwrap(try RichDocumentEditing.mergingBackward(exited.content, blockID: "second"))
    let result = try blocks(joined.content)
    XCTAssertEqual(result.map(\.id), ["first"])
    XCTAssertEqual(result[0].plainText, "Hello world")
    XCTAssertEqual(result[0].runs.map(\.italic), [true, false])
    XCTAssertEqual(joined.caret, .init(blockID: "first", location: 6))
    // Splitting at the caret restores the original text in two paragraphs.
    let again = try RichDocumentEditing.editing(joined.content, blockID: "first", range: NSRange(location: joined.caret.location, length: 0), replacement: "\n", newBlockID: ids())
    XCTAssertEqual(try blocks(again.content).map(\.plainText), ["Hello ", "world"])
    // Nothing precedes the first paragraph.
    XCTAssertNil(try RichDocumentEditing.mergingBackward(joined.content, blockID: "first"))
  }

  func testJoiningStopsAtATableAndLeavesTheDocumentUnchanged() throws {
    let table = try NoteDocument(blocks: [.table(.init(id: "table", columns: [.init()], rows: [.init(cells: [.init(text: "cell")])])), .richText(.init(id: "after", text: "B"))]).encoded()
    XCTAssertNil(try RichDocumentEditing.mergingBackward(table, blockID: "after"))
    XCTAssertThrowsError(try RichDocumentEditing.mergingBackward(table, blockID: "missing"))
  }

  func testNumberedParagraphsCountWithinTheirListAndIndependentListsRestart() throws {
    let saved = NoteListFormatting(levels: [.init(id: "saved", markerFormat: "{decimal}.", startingItemNumber: 4)], headIndent: 28, firstLineHeadIndent: 6)
    let other = NoteListFormatting(levels: [.init(id: "other", markerFormat: "{decimal}.")], headIndent: 28, firstLineHeadIndent: 6)
    let document = NoteDocument(blocks: [
      .richText(.init(id: "a1", style: .numberedList, text: "One")),
      .richText(.init(id: "a2", style: .numberedList, text: "Two")),
      .richText(.init(id: "a3", style: .numberedList, text: "Three")),
      .richText(.init(id: "prose", text: "Between")),
      .richText(.init(id: "b1", style: .numberedList, text: "Restart")),
      .richText(.init(id: "bullet", style: .bulletedList, text: "Dot")),
      .richText(.init(id: "c1", style: .numberedList, text: "Again")),
      .table(.init(id: "table", columns: [.init()], rows: [.init(cells: [.init(text: "cell")])])),
      .richText(.init(id: "d1", style: .numberedList, text: "After table")),
      .richText(.init(id: "s1", style: .numberedList, text: "Saved", list: saved)),
      .richText(.init(id: "s2", style: .numberedList, text: "Saved next", list: saved)),
      .richText(.init(id: "o1", style: .numberedList, text: "Other list", list: other)),
    ])
    let numbers = RichDocumentEditing.listItemNumbers(document)
    XCTAssertEqual(["a1", "a2", "a3"].map { numbers[$0] }, [1, 2, 3])
    XCTAssertNil(numbers["prose"])
    XCTAssertEqual(numbers["b1"], 1, "Body text ends a list")
    XCTAssertEqual(numbers["c1"], 1, "A different list style ends a list")
    XCTAssertEqual(numbers["d1"], 1, "A table ends a list")
    XCTAssertEqual(numbers["s1"], 4, "A saved list keeps its starting number")
    XCTAssertEqual(numbers["s2"], 5)
    XCTAssertEqual(numbers["o1"], 1, "A different saved list restarts even when adjacent")
  }

  func testReturnInANumberedListContinuesItsNumbering() throws {
    let list = NoteListFormatting(levels: [.init(id: "steps", markerFormat: "{decimal}.")], headIndent: 28, firstLineHeadIndent: 6)
    var content = try NoteDocument(blocks: [.richText(.init(id: "first", style: .numberedList, text: "Mix", list: list))]).encoded()
    var caret = RichDocumentEditing.Caret(blockID: "first", location: 3)
    let next = ids()
    for word in ["Bake", "Serve"] {
      let split = try RichDocumentEditing.editing(content, blockID: caret.blockID, range: .init(location: caret.location, length: 0), replacement: "\n", newBlockID: next)
      let typed = try RichDocumentEditing.editing(split.content, blockID: split.caret.blockID, range: .init(location: 0, length: 0), replacement: word)
      content = typed.content; caret = typed.caret
    }
    let document = try XCTUnwrap(RichDocumentEditing.document(content))
    let numbers = RichDocumentEditing.listItemNumbers(document)
    XCTAssertEqual(try blocks(content).map(\.plainText), ["Mix", "Bake", "Serve"])
    XCTAssertEqual(try blocks(content).map { numbers[$0.id] }, [1, 2, 3])
    XCTAssertEqual(Set(try blocks(content).compactMap { $0.list?.levels.first?.id }), ["steps"], "New items keep the list's identity")
    // Changing a list's style drops identity that belonged to the old style.
    let bulleted = try RichDocumentEditing.settingStyle(in: content, blockID: "new-1", style: .bulletedList)
    XCTAssertNil(try blocks(bulleted)[1].list)
    XCTAssertNotNil(try blocks(bulleted)[0].list)
  }

  func testLargeLinePasteIsOneBoundedTransactionAndAnOversizedPasteChangesNothing() throws {
    let source = try NoteDocument(blocks: [.richText(.init(id: "block", runs: [.init(text: "Head tail", italic: true)]))]).encoded()
    let lines = (1...8_000).map { "Line \($0)" }
    let started = ContinuousClock.now
    let pasted = try RichDocumentEditing.editing(source, blockID: "block", range: .init(location: 5, length: 0), replacement: lines.joined(separator: "\n"), newBlockID: ids())
    // Reparsing the growing document once per line is quadratic; one transaction stays far under this bound.
    XCTAssertLessThan(started.duration(to: .now), .seconds(20))
    let result = try blocks(pasted.content)
    XCTAssertEqual(result.count, 8_000)
    XCTAssertEqual(result.first?.plainText, "Head Line 1")
    XCTAssertEqual(result.last?.plainText, "Line 8000tail")
    XCTAssertEqual(result.last?.id, "new-7999")
    XCTAssertTrue(result.allSatisfy { $0.runs.allSatisfy(\.italic) }, "Pasted lines keep the formatting at the caret")
    XCTAssertEqual(pasted.caret, .init(blockID: "new-7999", location: 9))
    XCTAssertTrue(RichDocumentEditing.canEdit(pasted.content))

    // Beyond the block limit the paste is refused before anything is built.
    let tooMany = (0...RichDocumentEditing.maximumBlocks).map(String.init).joined(separator: "\n")
    var created = 0
    XCTAssertThrowsError(try RichDocumentEditing.editing(source, blockID: "block", range: .init(location: 5, length: 0), replacement: tooMany, newBlockID: { created += 1; return "x\(created)" })) {
      XCTAssertEqual($0 as? RichDocumentEditing.Failure, .documentLimit)
    }
    XCTAssertEqual(created, 0)
    let tooLarge = String(repeating: "x", count: LibraryProtocol.maximumNoteBytes) + "\nend"
    XCTAssertThrowsError(try RichDocumentEditing.editing(source, blockID: "block", range: .init(location: 5, length: 0), replacement: tooLarge)) {
      XCTAssertEqual($0 as? RichDocumentEditing.Failure, .documentLimit)
    }
  }

  func testWritingAfterATableOnlyNoteAppendsProseAndLeavesTheTableUnchanged() throws {
    let table = NoteBlock.table(.init(id: "table", columns: [.init(width: 90)], rows: [.init(cells: [.init(text: "cell", backgroundHex: "#C8E6C9")])], headerRowCount: 1))
    let source = try NoteDocument(blocks: [table]).encoded()
    let offered = try RichDocumentEditing.appendingParagraph(to: source, id: "after")
    let typed = try RichDocumentEditing.replacingText(in: offered, blockID: "after", range: .init(location: 0, length: 0), replacement: "Notes")
    let continued = try RichDocumentEditing.editing(typed, blockID: "after", range: .init(location: 5, length: 0), replacement: "\nMore", newBlockID: ids())
    XCTAssertEqual(try blocks(continued.content).map(\.plainText), ["Notes", "More"])
    let before = try XCTUnwrap(raw(source)["blocks"] as? [[String: Any]]), after = try XCTUnwrap(raw(continued.content)["blocks"] as? [[String: Any]])
    XCTAssertEqual(after.count, 3)
    XCTAssertEqual(try json(before[0]), try json(after[0]), "The table keeps its exact data")
    XCTAssertTrue(RichDocumentEditing.canEdit(continued.content))
  }
}
