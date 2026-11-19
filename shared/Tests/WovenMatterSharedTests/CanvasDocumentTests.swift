import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Page document safety")
struct CanvasDocumentTests {
  @Test func linkedOriginalsSurviveAgentEdits() throws {
    let block = NoteRichTextBlock(text: "A shared idea")
    let placement = CanvasCardPlacement(assetID: "original-asset")
    var document = NoteDocument(kind: .canvas, blocks: [.richText(block)], canvas: [block.id: placement])
    let operations: [NoteEditOperation] = [.appendText("Next step", .paragraph)]
    try RemoteNoteEditEnvelope.validate(operations: operations, applyingTo: document)
    _ = try document.apply(operations)
    let decoded = try NoteDocument.editableDocument(from: document.encoded())
    #expect(decoded.kind == .canvas)
    #expect(decoded.canvas?[block.id] == placement)
    #expect(decoded.blocks.count == 2)
    #expect(decoded.plainText.contains("Next step"))
    #expect(decoded.canvas?[decoded.blocks[1].id] == nil)
  }

  @Test func replacementKeepsPlacementAndDeletionRemovesIt() throws {
    let original = NoteRichTextBlock(text: "Old")
    let replacement = NoteRichTextBlock(id: original.id, text: "Revised")
    var placement = CanvasCardPlacement()
    placement.title = "A label"
    var document = NoteDocument(kind: .canvas, blocks: [.richText(original)], canvas: [original.id: placement])
    _ = try document.apply([.replaceBlock(id: original.id, block: .richText(replacement))])
    #expect(document.canvas?[original.id] == placement)
    #expect(document.plainText == "Revised")
    _ = try document.apply([.deleteBlock(id: replacement.id)])
    #expect(document.canvas?.isEmpty == true)
    try document.validateEditableShape()
  }

  @Test func invalidAndUnknownPlacementsAreReadOnly() throws {
    let block = NoteRichTextBlock(text: "Keep this")
    var document = NoteDocument(kind: .canvas, blocks: [.richText(block)], canvas: [block.id: .init(height: .infinity)])
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try document.validateEditableShape() }
    document.canvas = ["missing": .init()]
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try document.validateEditableShape() }
    document.canvas = [block.id: .init()]
    var object = try #require(JSONSerialization.jsonObject(with: Data(document.encoded().utf8)) as? [String: Any])
    object["canvas"] = [block.id: ["height": 300, "unknownGroup": "preserve"]]
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: raw) }
    document.blocks = (0...10_000).map { _ in .richText(NoteRichTextBlock()) }
    #expect(throws: NoteDocumentSafetyError.tooLarge) { try document.validateEditableShape() }
  }

  @Test func onlyAPageHasPlacementsAndComponentMetadata() throws {
    var plain = NoteDocument()
    plain.boardPurpose = "Not a Page"
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try plain.validateEditableShape() }
    #expect(NoteDocument().pageNodes == nil)
    // A Page always has its nesting, empty while nothing is nested, also when read.
    #expect(NoteDocument(kind: .canvas).pageNodes == [:])
    let read = try NoteDocument.editableDocument(from: #"{"blocks":[],"html":"","kind":"canvas"}"#)
    #expect(read.pageNodes == [:])
    #expect(try read.encoded().contains(#""pageNodes":{}"#))
  }

  @Test func ordinaryNotesRetainTheirFormat() throws {
    let document = NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Existing note"))])
    let content = try document.encoded()
    #expect(!content.contains("\"canvas\""))
    #expect(try NoteDocument.editableDocument(from: content) == document)
  }
}
