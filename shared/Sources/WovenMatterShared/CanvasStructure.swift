import Foundation

public extension NoteDocument {
  /// Only a Page has placements, a purpose and component metadata, and each
  /// belongs to a block the Page holds.
  func validateCanvasStructure() throws {
    guard canvas != nil || boardPurpose != nil || boardItems != nil else { return }
    guard kind == .canvas else { throw NoteDocumentSafetyError.unsupportedFormat }
    let blockIDs = Set(blocks.map(\.id))
    guard (boardPurpose?.utf8.count ?? 0) <= Self.maximumBoardPurposeBytes,
          (boardItems ?? [:]).allSatisfy({ blockIDs.contains($0.key) && $0.value.isValid }) else {
      throw NoteDocumentSafetyError.unsupportedFormat
    }
  }
}
