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
    var document = NoteDocument(kind: .canvas, blocks: [.richText(block)], canvas: [block.id: .init(x: -1_000_000_001, y: 0)])
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

  @Test func spatialEditsRoundTripAndMoveGroupsWithoutChangingAssets() throws {
    let a = NoteRichTextBlock(text: "A"), b = NoteRichTextBlock(text: "B")
    var document = NoteDocument(kind: .canvas)
    let section = CanvasSection(title: "Research", x: -800, y: -400)
    var placement = CanvasCardPlacement(x: -700, y: -300, assetID: "original")
    placement.sectionID = section.id; placement.title = "Evidence"; placement.color = "blue"
    let edits: [CanvasEdit] = [.init(action: .section, section: section),
      .init(action: .add, block: .richText(a), placement: placement),
      .init(action: .add, block: .richText(b), placement: .init(x: 200, y: 100)),
      .init(action: .connect, connection: .init(from: a.id, to: b.id, label: "supports"))]
    let operations = edits.map(NoteEditOperation.canvas)
    #expect(RemoteNoteEditEnvelope.requiresRevision(operations))
    try RemoteNoteEditEnvelope.validate(operations: operations, applyingTo: document)
    _ = try document.apply(operations)
    #expect(try NoteDocument.editableDocument(from: document.encoded()) == document)
    var moved = section; moved.x += 500; moved.y += 200
    _ = try document.apply([.canvas(.init(action: .section, section: moved))])
    #expect(document.canvas?[a.id]?.x == -200)
    #expect(document.canvas?[a.id]?.y == -100)
    #expect(document.canvas?[a.id]?.assetID == "original")
    #expect(document.canvas?[b.id]?.x == 200)
    var resized = document.canvasPlacement(for: a.id)
    resized.assetID = nil; resized.width = 640
    _ = try document.apply([.canvas(.init(action: .place, id: a.id, placement: resized))])
    #expect(document.canvas?[a.id]?.assetID == "original")
    #expect(document.canvas?[a.id]?.width == 640)
    _ = try document.apply([.canvas(.init(action: .removeSection, id: section.id))])
    #expect(document.canvas?[a.id]?.sectionID == nil)
    #expect(document.canvas?[a.id]?.assetID == "original")
    _ = try document.apply([.deleteBlock(id: a.id)])
    #expect(document.canvasConnections?.isEmpty == true)
  }

  @Test func spatialValidationRejectsDanglingConnectionsAndNonCanvasEdits() throws {
    var plain = NoteDocument()
    #expect(throws: NoteEditError.artifactKindMismatch) {
      _ = try plain.apply([.canvas(.init(action: .section, section: .init(title: "Bad", x: 0, y: 0)))])
    }
    let block = NoteRichTextBlock(text: "Safe")
    let document = NoteDocument(kind: .canvas, blocks: [.richText(block)])
    #expect(throws: (any Error).self) {
      try RemoteNoteEditEnvelope.validate(operations: [.canvas(.init(action: .connect,
        connection: .init(from: block.id, to: "missing")))], applyingTo: document)
    }
    #expect(throws: (any Error).self) {
      try RemoteNoteEditEnvelope.validate(operations: [.canvas(.init(action: .place,
        id: block.id, placement: .init(x: .infinity, y: 0)))], applyingTo: document)
    }
  }

  @Test func simpleAgentCardPayloadNeedsNoInternalTextSchema() throws {
    let payload = #"[{"action":"add","id":"idea","text":"An idea","placement":{"x":-20,"y":50,"width":360,"height":300}}]"#
    let edits = try JSONDecoder().decode([CanvasEdit].self, from: Data(payload.utf8))
    var document = NoteDocument(kind: .canvas)
    _ = try document.apply(edits.map(NoteEditOperation.canvas))
    #expect(document.blocks.first?.id == "idea")
    #expect(document.plainText == "An idea")
    #expect(document.canvas?["idea"]?.x == -20)
  }

  @Test func ordinaryNotesRetainTheirFormat() throws {
    let document = NoteDocument(blocks: [.richText(NoteRichTextBlock(text: "Existing note"))])
    let content = try document.encoded()
    #expect(!content.contains("\"canvas\""))
    #expect(try NoteDocument.editableDocument(from: content) == document)
  }
}
