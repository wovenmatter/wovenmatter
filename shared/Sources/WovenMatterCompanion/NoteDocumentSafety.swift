import Foundation

public enum NoteDocumentSafetyError: LocalizedError, Equatable {
  case unsupportedFormat
  case tooLarge
  public var errorDescription: String? {
    switch self {
    case .unsupportedFormat: "This document uses a format or attributes this version cannot safely edit. Its original content is preserved."
    case .tooLarge: "This note exceeds the supported editing size."
    }
  }
}

extension NoteDocument {
  /// Decodes an editable document only if every original JSON field survives
  /// typed decoding. Unknown versions, blocks and attributes remain read-only.
  public static func editableDocument(from content: String) throws -> NoteDocument {
    guard content.utf8.count <= CompanionProtocol.maximumNoteBytes else { throw NoteDocumentSafetyError.tooLarge }
    guard let bytes = content.data(using: .utf8) else { throw NoteDocumentSafetyError.unsupportedFormat }
    guard let object = try? JSONSerialization.jsonObject(with: bytes) else {
      // A damaged structured document must never become editable legacy text.
      let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else {
        throw NoteDocumentSafetyError.unsupportedFormat
      }
      // Existing plain text/HTML legacy notes remain intentionally migratable.
      return NoteDocument.decode(content)
    }
    guard var original = object as? [String: Any], original["version"] != nil,
          let document = try? JSONDecoder().decode(NoteDocument.self, from: bytes),
          let encoded = try? JSONEncoder().encode(document),
          let roundTrip = try? JSONSerialization.jsonObject(with: encoded) else {
      throw NoteDocumentSafetyError.unsupportedFormat
    }
    try document.validateEditableShape()
    if (original["version"] as? Int) == 1 { original["version"] = currentVersion }
    guard preserves(original, in: roundTrip) else { throw NoteDocumentSafetyError.unsupportedFormat }
    return document
  }

  /// Bound a sparse table before normalization allocates missing cells, and
  /// reject ragged structures instead of trimming writing or manufacturing IDs.
  public func validateEditableShape() throws {
    guard blocks.count <= 10_000 else { throw NoteDocumentSafetyError.tooLarge }
    var totalCells = 0
    var ids = Set<String>()
    for block in blocks {
      guard !block.id.isEmpty, ids.insert(block.id).inserted else { throw NoteDocumentSafetyError.unsupportedFormat }
      if case .table(let table) = block {
        guard !table.columns.isEmpty, table.columns.count <= 128,
              !table.rows.isEmpty, table.rows.count <= 1_000,
              table.rows.count <= 50_000 / table.columns.count,
              table.headerRowCount >= 0, table.headerRowCount <= table.rows.count else {
          throw NoteDocumentSafetyError.unsupportedFormat
        }
        totalCells += table.columns.count * table.rows.count
        guard totalCells <= 50_000 else { throw NoteDocumentSafetyError.tooLarge }
        for column in table.columns {
          guard !column.id.isEmpty, ids.insert(column.id).inserted else { throw NoteDocumentSafetyError.unsupportedFormat }
        }
        for row in table.rows {
          guard row.cells.count == table.columns.count, !row.id.isEmpty, ids.insert(row.id).inserted else { throw NoteDocumentSafetyError.unsupportedFormat }
          for cell in row.cells {
            guard !cell.id.isEmpty, ids.insert(cell.id).inserted else { throw NoteDocumentSafetyError.unsupportedFormat }
          }
        }
      }
    }
  }

  private static func preserves(_ source: Any, in target: Any) -> Bool {
    if let source = source as? [String: Any] {
      guard let target = target as? [String: Any] else { return false }
      return source.allSatisfy { key, value in target[key].map { preserves(value, in: $0) } ?? (value is NSNull) }
    }
    if let source = source as? [Any] {
      guard let target = target as? [Any], source.count == target.count else { return false }
      return zip(source, target).allSatisfy { preserves($0, in: $1) }
    }
    return (source as? NSObject)?.isEqual(target) == true
  }
}
