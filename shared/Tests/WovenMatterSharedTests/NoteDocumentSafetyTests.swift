import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Library document fidelity")
struct NoteDocumentSafetyTests {
  @Test("rich blocks, stable IDs, style, links and table cells survive an edit")
  func richRoundTrip() throws {
    var run = NoteTextRun(text: "Linked idea")
    run.bold = true; run.italic = true; run.link = "https://example.com"
    let text = NoteRichTextBlock(style: .heading2, runs: [run])
    let table = NoteTableBlock(rows: 2, columns: 2, headerRow: true)
    let original = NoteDocument(blocks: [.richText(text), .table(table)])
    let raw = try original.encoded()
    #expect(try NoteDocument.editableDocument(from: "Legacy text").plainText == "Legacy text")
    #expect(!raw.contains("\"version\""))
    var edited = try NoteDocument.editableDocument(from: raw)
    edited.blocks.append(.richText(NoteRichTextBlock(text: "New idea")))
    let read = try NoteDocument.editableDocument(from: edited.encoded())
    #expect(Array(read.blocks.prefix(2)) == original.blocks)
    #expect(read.blocks.map(\.id).prefix(2) == original.blocks.map(\.id).prefix(2))
  }

  @Test("damaged documents, unrecognised shapes, unknown nested attributes and blocks are read-only")
  func futureFields() throws {
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: "{\"blocks\":[],broken") }
    // A JSON object that is not a structured document is never opened as an empty one.
    for unrecognised in ["{}", #"{"kind":"note","html":""}"#, #"{"blocks":{}}"#, #"{"version":2}"#, "[]"] {
      #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: unrecognised) }
    }
    let raw = try NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Retain me"))]).encoded()
    var object = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
    object["futureMetadata"] = ["retain": "this"]
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
    #expect(raw.utf8.count < LibraryProtocol.maximumNoteBytes)
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: raw) }
    #expect(throws: NoteDocumentSafetyError.tooLarge) {
      try NoteDocument.editableDocument(from: String(repeating: "x", count: LibraryProtocol.maximumNoteBytes + 1))
    }
    // The permissive legacy display entry point must also avoid expansion.
    #expect(NoteDocument.decode(raw).blocks.count == 1)
    for cells in [[], [NoteTableCell(text: "first"), NoteTableCell(text: "must not disappear")]] {
      let ragged = NoteTableBlock(columns: [NoteTableColumn()], rows: [NoteTableRow(cells: cells)])
      let content = String(decoding: try JSONEncoder().encode(NoteDocument(blocks: [.table(ragged)])), as: UTF8.self)
      #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: content) }
    }
  }

  /// Notes as builds up to 0.4.6 stored them, key for key. Each must open as
  /// the document it always was, and be editable.
  @Test("notes already stored open as the same documents, whatever number they carry")
  func storedNotesKeepOpening() throws {
    let text = #"{"blocks":[{"type":"richText","value":{"id":"b1","runs":[{"bold":true,"italic":false,"text":"Plan","underline":false}],"style":"heading2"}},{"type":"table","value":{"columns":[{"id":"c1"}],"headerRowCount":1,"id":"t1","rows":[{"cells":[{"id":"x1","runs":[{"bold":false,"italic":false,"text":"Cell","underline":false}]}],"id":"r1"}]}}],"html":"","kind":"note","version":2}"#
    let expectedText = NoteDocument(blocks: [
      .richText(NoteRichTextBlock(id: "b1", style: .heading2, runs: [NoteTextRun(text: "Plan", bold: true)])),
      .table(NoteTableBlock(id: "t1", columns: [NoteTableColumn(id: "c1")],
                            rows: [NoteTableRow(id: "r1", cells: [NoteTableCell(id: "x1", text: "Cell")])], headerRowCount: 1)),
    ])
    let page = #"{"blocks":[{"type":"richText","value":{"id":"a","runs":[],"style":"paragraph"}}],"boardItems":{"a":{"task":{"status":"done"}}},"html":"","kind":"canvas","version":2}"#
    let artifact = #"{"artifactState":{"app:x":{"updatedAt":"2026-11-01T00:00:00Z","value":1,"version":3}},"blocks":[{"type":"richText","value":{"id":"e","runs":[],"style":"paragraph"}}],"html":"<input>","kind":"html","version":2}"#
    // The earlier shape: blocks alone, under the earlier number or none.
    let earlier = #"{"version":1,"blocks":[{"type":"richText","value":{"id":"b1","style":"paragraph","runs":[{"text":"Earlier","bold":false,"italic":false,"underline":false}]}}]}"#
    let expectedEarlier = NoteDocument(blocks: [.richText(NoteRichTextBlock(id: "b1", text: "Earlier"))])

    #expect(NoteDocument.decode(text) == expectedText)
    #expect(try NoteDocument.editableDocument(from: text) == expectedText)
    #expect(NoteDocument.decode(earlier) == expectedEarlier)
    #expect(try NoteDocument.editableDocument(from: earlier) == expectedEarlier)
    #expect(try NoteDocument.editableDocument(from: earlier.replacingOccurrences(of: #""version":1,"#, with: "")) == expectedEarlier)

    let decodedPage = try NoteDocument.editableDocument(from: page)
    #expect(decodedPage.kind == .canvas)
    #expect(decodedPage.boardItems?["a"]?.task?.status == .done)
    let decodedArtifact = try NoteDocument.editableDocument(from: artifact)
    #expect(decodedArtifact.kind == .html)
    #expect(decodedArtifact.html == "<input>")
    // An App's saved value keeps its own revision, which is data, not a format number.
    #expect(decodedArtifact.artifactState?["app:x"]?.version == 3)

    for stored in [text, page, artifact, earlier] {
      // The same document with and without the stored key, and whatever its value.
      let without = stored.replacingOccurrences(of: #","version":2"#, with: "").replacingOccurrences(of: #""version":1,"#, with: "")
      #expect(!without.contains(#""version":2"#) && !without.contains(#""version":1"#))
      #expect(NoteDocument.decode(without) == NoteDocument.decode(stored))
      var object = try #require(JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: Any])
      object["version"] = 99
      #expect(try NoteDocument.editableDocument(from: encode(object)) == NoteDocument.editableDocument(from: stored))
      // What is written from now on carries no such key, and reads back the same.
      let rewritten = try NoteDocument.editableDocument(from: stored).encoded()
      let keys = try #require(JSONSerialization.jsonObject(with: Data(rewritten.utf8)) as? [String: Any]).keys
      #expect(!keys.contains("version"))
      #expect(NoteDocument.decode(rewritten) == NoteDocument.decode(stored))
      #expect(try NoteDocument.editableDocument(from: rewritten) == NoteDocument.editableDocument(from: stored))
    }
    // Only the key is dropped: every other byte of a stored note is written as before.
    #expect(try NoteDocument.editableDocument(from: text).encoded() == text.replacingOccurrences(of: #","version":2"#, with: ""))
  }

  @Test("an edit envelope carries no format number, and one that does is read the same")
  func editEnvelope() throws {
    let nonce = "n", begin = RemoteNoteEditEnvelope.beginMarker(nonce: nonce), end = RemoteNoteEditEnvelope.endMarker(nonce: nonce)
    let envelope = RemoteNoteEditEnvelope(nonce: nonce, noteID: "note", expectedRevision: "r", operations: [.appendText("More", .paragraph)])
    let written = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    #expect(!written.contains("version"))
    let numbered = #"{"version":1,"# + written.dropFirst()
    for payload in [written, numbered] {
      let found = try RemoteNoteEditEnvelope.extract(from: "\(begin)\n\(payload)\n\(end)", nonce: nonce, noteID: "note",
                                                     expectedRevision: "r", noteKind: .note)
      #expect(found == envelope)
    }
    #expect(throws: RemoteNoteEditError.invalidEnvelope) {
      try RemoteNoteEditEnvelope.extract(from: "\(begin)\n\(written)\n\(end)", nonce: nonce, noteID: "note",
                                         expectedRevision: "stale", noteKind: .note)
    }
  }

  private func encode(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }
}
