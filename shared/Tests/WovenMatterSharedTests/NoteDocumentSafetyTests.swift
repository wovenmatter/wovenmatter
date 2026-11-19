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
    // A note with nothing in it yet is an empty document; text that is not a document is not edited.
    #expect(try NoteDocument.editableDocument(from: "").plainText == "")
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: "Not a document") }
    #expect(NoteDocument.decode("Not a document").plainText == "Not a document")
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
    for unrecognised in ["{}", #"{"kind":"note","html":""}"#, #"{"blocks":{}}"#, "[]"] {
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
    // The permissive display entry point must also avoid expansion.
    #expect(NoteDocument.decode(raw).blocks.count == 1)
    for cells in [[], [NoteTableCell(text: "first"), NoteTableCell(text: "must not disappear")]] {
      let ragged = NoteTableBlock(columns: [NoteTableColumn()], rows: [NoteTableRow(cells: cells)])
      let content = String(decoding: try JSONEncoder().encode(NoteDocument(blocks: [.table(ragged)])), as: UTF8.self)
      #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: content) }
    }
  }

  /// The one-time conversion of stored note content: the release before this
  /// one stored a number under a top-level `version` key, which a document
  /// does not have. Today's stored bytes in, the same bytes without that
  /// member out, and nothing left to convert.
  @Test("a stored note loses its version member once, and nothing else")
  func storedNotesAreConvertedOnce() throws {
    let note = #"{"blocks":[{"type":"richText","value":{"id":"b1","runs":[{"bold":true,"italic":false,"text":"Plan, \"version\":2}","underline":false}],"style":"heading2"}}],"html":"","kind":"note","version":2}"#
    let page = #"{"blocks":[{"type":"richText","value":{"id":"a","runs":[],"style":"paragraph"}}],"boardItems":{"a":{"task":{"status":"done"}}},"html":"","kind":"canvas","version":2}"#
    // An App's saved value keeps its own revision, which is data and stays.
    let artifact = #"{"artifactState":{"app:x":{"updatedAt":"2026-11-01T00:00:00Z","value":1,"version":3}},"blocks":[{"type":"richText","value":{"id":"e","runs":[],"style":"paragraph"}}],"html":"<input>","kind":"html","version":2}"#
    for stored in [note, page, artifact] {
      // As stored, the member is a field no document has, so the note is read-only.
      #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: stored) }
      let converted = try #require(EarlierNoteContent.removingVersionMember(stored))
      #expect(converted == String(stored.dropLast(#","version":2}"#.count)) + "}")
      #expect(EarlierNoteContent.removingVersionMember(converted) == nil)
      // The same document as before, and now one this build edits.
      #expect(try NoteDocument.editableDocument(from: converted) == NoteDocument.decode(stored))
      // A host keeps its clocks after the document; they stay where they are.
      let clocked = String(stored.dropLast()) + #","~sync":{"title":{"n":4,"r":"mac"}}}"#
      #expect(EarlierNoteContent.removingVersionMember(clocked) == String(converted.dropLast()) + #","~sync":{"title":{"n":4,"r":"mac"}}}"#)
    }
    #expect(try NoteDocument.editableDocument(from: #require(EarlierNoteContent.removingVersionMember(artifact))).artifactState?["app:x"]?.version == 3)
    // For a Note, the converted bytes are exactly what this build writes for it.
    let converted = try #require(EarlierNoteContent.removingVersionMember(note))
    #expect(try NoteDocument.editableDocument(from: converted).encoded() == converted)
    // Wherever the member sits, only it goes.
    #expect(EarlierNoteContent.removingVersionMember(#"{"version":2,"blocks":[],"kind":"note"}"#) == #"{"blocks":[],"kind":"note"}"#)
    #expect(EarlierNoteContent.removingVersionMember(#"{ "blocks" : [ ] , "version" : 2 , "kind" : "note" }"#) == #"{ "blocks" : [ ] , "kind" : "note" }"#)
    #expect(EarlierNoteContent.removingVersionMember(#"{"version":2}"#) == "{}")
    for untouched in ["Plain text about a \"version\" key", #"{"blocks":[],"kind":"note"}"#, #"{"artifactState":{"a":{"version":3}},"blocks":[]}"#, #"["version"]"#, #"{"blocks":[],"version""#] {
      #expect(EarlierNoteContent.removingVersionMember(untouched) == nil)
    }
  }

  @Test("an edit envelope is found between its markers and checked against the note")
  func editEnvelope() throws {
    let nonce = "n", begin = RemoteNoteEditEnvelope.beginMarker(nonce: nonce), end = RemoteNoteEditEnvelope.endMarker(nonce: nonce)
    let envelope = RemoteNoteEditEnvelope(nonce: nonce, noteID: "note", expectedRevision: "r", operations: [.appendText("More", .paragraph)])
    let written = String(decoding: try JSONEncoder().encode(envelope), as: UTF8.self)
    let found = try RemoteNoteEditEnvelope.extract(from: "\(begin)\n\(written)\n\(end)", nonce: nonce, noteID: "note",
                                                   expectedRevision: "r", noteKind: .note)
    #expect(found == envelope)
    #expect(throws: RemoteNoteEditError.invalidEnvelope) {
      try RemoteNoteEditEnvelope.extract(from: "\(begin)\n\(written)\n\(end)", nonce: nonce, noteID: "note",
                                         expectedRevision: "stale", noteKind: .note)
    }
  }

  private func encode(_ object: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
  }
}
