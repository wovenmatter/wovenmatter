import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite("Companion document fidelity")
struct NoteDocumentSafetyTests {
  @Test("rich blocks, stable IDs, style, links and table cells survive an edit")
  func richRoundTrip() throws {
    var run = NoteTextRun(text: "Linked idea")
    run.bold = true; run.italic = true; run.link = "https://example.com"
    let text = NoteRichTextBlock(style: .heading2, runs: [run])
    let table = NoteTableBlock(rows: 2, columns: 2, headerRow: true)
    let original = NoteDocument(blocks: [.richText(text), .table(table)])
    let raw = try original.encoded()
    var edited = try NoteDocument.editableDocument(from: raw)
    edited.blocks.append(.richText(NoteRichTextBlock(text: "New idea")))
    let read = try NoteDocument.editableDocument(from: edited.encoded())
    #expect(Array(read.blocks.prefix(2)) == original.blocks)
    #expect(read.blocks.map(\.id).prefix(2) == original.blocks.map(\.id).prefix(2))
  }

  @Test("future versions, unknown nested attributes and blocks are read-only")
  func futureFields() throws {
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: "{\"version\":99,broken") }
    let raw = try NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Retain me"))]).encoded()
    var object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    object["version"] = 99
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: encode(object)) }
    object["version"] = 2; object["futureMetadata"] = ["retain": "this"]
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: encode(object)) }
    object.removeValue(forKey: "futureMetadata")
    var blocks = try #require(object["blocks"] as? [[String: Any]])
    var value = try #require(blocks[0]["value"] as? [String: Any])
    value["newStyle"] = "preserve"; blocks[0]["value"] = value; object["blocks"] = blocks
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: encode(object)) }
  }

  @Test("sparse expansion and ragged cells fail before normalization")
  func unsafeTables() throws {
    let sparse = NoteTableBlock(columns: (0..<10_000).map { _ in NoteTableColumn() }, rows: (0..<10_000).map { _ in NoteTableRow(cells: []) })
    let raw = String(decoding: try JSONEncoder().encode(NoteDocument(blocks: [.table(sparse)])), as: UTF8.self)
    #expect(raw.utf8.count < CompanionProtocol.maximumNoteBytes)
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: raw) }
    // The permissive legacy display entry point must also avoid expansion.
    #expect(NoteDocument.decode(raw).blocks.count == 1)
    for cells in [[], [NoteTableCell(text: "first"), NoteTableCell(text: "must not disappear")]] {
      let ragged = NoteTableBlock(columns: [NoteTableColumn()], rows: [NoteTableRow(cells: cells)])
      let content = String(decoding: try JSONEncoder().encode(NoteDocument(blocks: [.table(ragged)])), as: UTF8.self)
      #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: content) }
    }
  }

  @Test("legacy v1 migration retains text and body byte ceilings apply")
  func legacyAndBounds() throws {
    #expect(try NoteDocument.editableDocument(from: "Legacy text").plainText == "Legacy text")
    let raw = try NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Legacy"))]).encoded()
    let v1 = raw.replacingOccurrences(of: "\"version\":2", with: "\"version\":1")
    #expect(try NoteDocument.editableDocument(from: v1).plainText == "Legacy")
    #expect(throws: NoteDocumentSafetyError.tooLarge) {
      try NoteDocument.editableDocument(from: String(repeating: "x", count: CompanionProtocol.maximumNoteBytes + 1))
    }
  }

  private func encode(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }
}
