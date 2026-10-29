import Foundation
import Testing
@testable import WovenMatterCompanion

@Suite("Canvas document safety and collaboration")
struct CanvasDocumentTests {
  @Test func layoutAndReferencesSurviveAgentEdits() throws {
    let block = NoteRichTextBlock(text: "A shared idea")
    let placement = CanvasCardPlacement(x: 420, y: 120, assetID: "original-asset")
    var document = NoteDocument(kind: .canvas, blocks: [.richText(block)], canvas: [block.id: placement])
    let operations: [NoteEditOperation] = [.appendText("Next step", .paragraph)]
    try RemoteNoteEditEnvelope.validate(operations: operations, applyingTo: document)
    _ = try document.apply(operations)
    let decoded = try NoteDocument.editableDocument(from: document.encoded())
    #expect(decoded.kind == .canvas)
    #expect(decoded.canvas?[block.id] == placement)
    #expect(decoded.blocks.count == 2)
    #expect(decoded.plainText.contains("Next step"))
    #expect(decoded.canvasPlacement(for: decoded.blocks[1].id) == .automatic(index: 1))
  }

  @Test func replacementTransfersPlacementAndDeletionRemovesIt() throws {
    let original = NoteRichTextBlock(text: "Old")
    let replacement = NoteRichTextBlock(text: "Revised")
    let placement = CanvasCardPlacement(x: 80, y: 160)
    var document = NoteDocument(kind: .canvas, blocks: [.richText(original)], canvas: [original.id: placement])
    _ = try document.apply([.replaceBlock(id: original.id, block: .richText(replacement))])
    #expect(document.canvas?[original.id] == nil)
    #expect(document.canvas?[replacement.id] == placement)
    _ = try document.apply([.deleteBlock(id: replacement.id)])
    #expect(document.canvas?.isEmpty == true)
    try document.validateEditableShape()
  }

  @Test func invalidAndFutureLayoutIsReadOnly() throws {
    let block = NoteRichTextBlock(text: "Keep this")
    var document = NoteDocument(kind: .canvas, blocks: [.richText(block)], canvas: [block.id: .init(x: -1, y: 0)])
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try document.validateEditableShape() }
    document.canvas = ["missing": .init(x: 0, y: 0)]
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try document.validateEditableShape() }
    document.canvas = [block.id: .init(x: 0, y: 0)]
    var object = try #require(JSONSerialization.jsonObject(with: Data(document.encoded().utf8)) as? [String: Any])
    object["canvas"] = [block.id: ["x": 0, "y": 0, "width": 360, "height": 300, "futureGroup": "preserve"]]
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: raw) }
    document.blocks = (0...NoteDocument.maximumCanvasCards).map { _ in .richText(NoteRichTextBlock()) }
    #expect(throws: NoteDocumentSafetyError.tooLarge) { try document.validateEditableShape() }
  }

  @Test func ordinaryNotesRetainTheirFormat() throws {
    let document = NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Existing note"))])
    let content = try document.encoded()
    #expect(!content.contains("\"canvas\""))
    #expect(try NoteDocument.editableDocument(from: content) == document)
  }
}
