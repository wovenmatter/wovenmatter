import Foundation

public struct AgentNoteContext: Codable, Equatable, Sendable {
  public var noteID: String
  public var title: String
  public var folderID: String?
  public var revision: String
  public var remoteEditNonce: String?
  public var artifactKind: NoteArtifactKind?

  public init(
    noteID: String,
    title: String,
    folderID: String? = nil,
    revision: String,
    remoteEditNonce: String? = nil,
    artifactKind: NoteArtifactKind? = nil
  ) {
    self.noteID = noteID
    self.title = title
    self.folderID = folderID
    self.revision = revision
    self.remoteEditNonce = remoteEditNonce
    self.artifactKind = artifactKind
  }
}

/// A one-run, revision-checked edit request returned by an agent that cannot
/// reach the host-only woven-note socket. The nonce binds the response to the
/// prompt that disclosed the note and prevents an unrelated transcript block
/// from being applied as an edit.
public struct RemoteNoteEditEnvelope: Codable, Equatable, Sendable {
  public static let currentVersion = 1
  public static let maximumEnvelopeBytes = 1 * 1_024 * 1_024
  public static let maximumOperationCount = 128

  public var version: Int
  public var nonce: String
  public var noteID: String
  public var expectedRevision: String
  public var operations: [NoteEditOperation]

  public init(
    version: Int = Self.currentVersion,
    nonce: String,
    noteID: String,
    expectedRevision: String,
    operations: [NoteEditOperation]
  ) {
    self.version = version
    self.nonce = nonce
    self.noteID = noteID
    self.expectedRevision = expectedRevision
    self.operations = operations
  }

  public static func beginMarker(nonce: String) -> String {
    "WOVEN_MATTER_NOTE_EDIT_BEGIN_\(nonce)"
  }

  public static func endMarker(nonce: String) -> String {
    "WOVEN_MATTER_NOTE_EDIT_END_\(nonce)"
  }

  public static func extract(
    from content: String,
    nonce: String,
    noteID: String,
    expectedRevision: String,
    noteKind: NoteArtifactKind
  ) throws -> RemoteNoteEditEnvelope? {
    let begin = beginMarker(nonce: nonce)
    let end = endMarker(nonce: nonce)
    guard let beginRange = content.range(of: begin) else { return nil }
    guard content.range(of: begin, range: beginRange.upperBound..<content.endIndex) == nil,
          let endRange = content.range(of: end, range: beginRange.upperBound..<content.endIndex),
          content.range(of: end, range: endRange.upperBound..<content.endIndex) == nil else {
      throw RemoteNoteEditError.invalidEnvelope
    }
    let payload = content[beginRange.upperBound..<endRange.lowerBound]
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !payload.isEmpty,
          payload.utf8.count <= maximumEnvelopeBytes,
          let data = payload.data(using: .utf8) else {
      throw RemoteNoteEditError.responseTooLarge
    }
    let envelope: RemoteNoteEditEnvelope
    do {
      envelope = try JSONDecoder().decode(Self.self, from: data)
    } catch {
      throw RemoteNoteEditError.invalidEnvelope
    }
    guard envelope.version == currentVersion,
          envelope.nonce == nonce,
          envelope.noteID == noteID,
          envelope.expectedRevision == expectedRevision,
          !envelope.operations.isEmpty,
          envelope.operations.count <= maximumOperationCount else {
      throw RemoteNoteEditError.invalidEnvelope
    }
    try envelope.validateOperations(noteKind: noteKind)
    return envelope
  }

  public func validateApplying(to document: NoteDocument) throws {
    guard version == Self.currentVersion,
          !operations.isEmpty,
          operations.count <= Self.maximumOperationCount else {
      throw RemoteNoteEditError.invalidEnvelope
    }
    try validateOperations(noteKind: document.kind)
    var result = document
    _ = try result.apply(operations)
    guard result.blocks.count <= 10_000,
          result.html.utf8.count <= Self.maximumEnvelopeBytes,
          (try result.encoded()).utf8.count <= Self.maximumEnvelopeBytes else {
      throw RemoteNoteEditError.operationTooLarge
    }
    var totalCells = 0
    var totalRuns = 0
    var totalTextBytes = 0
    for block in result.blocks {
      switch block {
      case .richText(let richText):
        let (nextRuns, runOverflow) = totalRuns.addingReportingOverflow(richText.runs.count)
        let blockBytes = richText.runs.reduce(into: 0) { $0 += $1.text.utf8.count }
        let (nextBytes, byteOverflow) = totalTextBytes.addingReportingOverflow(blockBytes)
        guard !runOverflow, !byteOverflow, nextRuns <= 100_000,
              nextBytes <= Self.maximumEnvelopeBytes else {
          throw RemoteNoteEditError.operationTooLarge
        }
        totalRuns = nextRuns
        totalTextBytes = nextBytes
      case .table(let table):
        let (cells, cellOverflow) = table.rows.count.multipliedReportingOverflow(
          by: table.columns.count
        )
        let (nextTotal, totalOverflow) = totalCells.addingReportingOverflow(cells)
        guard !cellOverflow, !totalOverflow,
              table.rows.count <= 1_000,
              table.columns.count <= 128,
              cells <= 100_000,
              nextTotal <= 100_000 else {
          throw RemoteNoteEditError.operationNotAllowed
        }
        totalCells = nextTotal
      }
    }
  }

  public static func redactingEnvelopes(in content: String) -> String {
    var result = content
    let prefix = "WOVEN_MATTER_NOTE_EDIT_BEGIN_"
    while let begin = result.range(of: prefix) {
      let nonceStart = begin.upperBound
      guard let lineEnd = result[nonceStart...].firstIndex(where: { $0.isNewline }) else {
        result.removeSubrange(begin.lowerBound..<result.endIndex)
        break
      }
      let nonce = String(result[nonceStart..<lineEnd])
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !nonce.isEmpty else { break }
      let endMarker = endMarker(nonce: nonce)
      guard let end = result.range(of: endMarker, range: lineEnd..<result.endIndex) else {
        result.removeSubrange(begin.lowerBound..<result.endIndex)
        break
      }
      var removalEnd = end.upperBound
      while removalEnd < result.endIndex, result[removalEnd].isNewline {
        removalEnd = result.index(after: removalEnd)
      }
      result.removeSubrange(begin.lowerBound..<removalEnd)
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func validateOperations(noteKind: NoteArtifactKind) throws {
    for operation in operations {
      let encoded = try JSONEncoder().encode(operation)
      guard encoded.count <= Self.maximumEnvelopeBytes else {
        throw RemoteNoteEditError.operationTooLarge
      }
      switch operation {
      case .setTitle(let title):
        guard noteKind != .html, title.utf8.count <= 1_024 else {
          throw RemoteNoteEditError.operationNotAllowed
        }
      case .appendText(let text, _), .insertText(_, let text, _):
        guard text.utf8.count <= 256 * 1_024 else {
          throw RemoteNoteEditError.operationTooLarge
        }
      case .createTable(_, let rows, let columns, _):
        guard (1...1_000).contains(rows), (1...128).contains(columns),
              rows * columns <= 100_000 else {
          throw RemoteNoteEditError.operationNotAllowed
        }
      case .setTableCell(_, let row, let column, let runs):
        guard row >= 0, column >= 0, row < 1_000, column < 128,
              runs.count <= 4_096 else {
          throw RemoteNoteEditError.operationNotAllowed
        }
      case .setHTML(let html):
        guard noteKind == .html, html.utf8.count <= Self.maximumEnvelopeBytes else {
          throw RemoteNoteEditError.operationNotAllowed
        }
      case .setArtifactDatabaseLink(let link):
        try Self.validate(link)
      case .setTableDatabaseLink(_, let link):
        try Self.validate(link)
      case .replaceBlock, .deleteBlock, .setParagraphStyle,
           .addTableRow, .removeTableRow, .addTableColumn, .removeTableColumn:
        break
      }
    }
  }

  private static func validate(_ link: DatabaseArtifactLink?) throws {
    guard let link else { return }
    guard link.sourceID.utf8.count <= 4_096,
          link.databaseID.utf8.count <= 4_096,
          link.relativePath.utf8.count <= 4_096,
          (link.sqliteQuery?.utf8.count ?? 0) <= 64 * 1_024 else {
      throw RemoteNoteEditError.operationTooLarge
    }
  }
}

public enum RemoteNoteEditError: LocalizedError, Equatable, Sendable {
  case responseTooLarge
  case invalidEnvelope
  case operationTooLarge
  case operationNotAllowed

  public var errorDescription: String? {
    switch self {
    case .responseTooLarge: "The remote note edit response is too large."
    case .invalidEnvelope: "The remote note edit response is invalid or stale."
    case .operationTooLarge: "A remote note edit exceeds the safe size limit."
    case .operationNotAllowed: "The remote note edit contains an operation that is not allowed for this artifact."
    }
  }
}

public struct NoteEditingRequest: Codable, Equatable, Sendable {
  public var command: NoteEditingCommand
  public var noteID: String
  public var expectedRevision: String?
  public var operations: [NoteEditOperation]

  public init(
    command: NoteEditingCommand,
    noteID: String,
    expectedRevision: String? = nil,
    operations: [NoteEditOperation] = []
  ) {
    self.command = command
    self.noteID = noteID
    self.expectedRevision = expectedRevision
    self.operations = operations
  }
}

public enum NoteEditingCommand: String, Codable, Sendable {
  case read
  case apply
}

public struct NoteEditingResponse: Codable, Equatable, Sendable {
  public var success: Bool
  public var noteID: String
  public var title: String?
  public var revision: String?
  public var document: NoteDocument?
  public var error: String?

  public init(
    success: Bool,
    noteID: String,
    title: String? = nil,
    revision: String? = nil,
    document: NoteDocument? = nil,
    error: String? = nil
  ) {
    self.success = success
    self.noteID = noteID
    self.title = title
    self.revision = revision
    self.document = document
    self.error = error
  }
}

public enum NoteEditOperation: Codable, Equatable, Sendable {
  case setTitle(String)
  case appendText(String, NoteParagraphStyle)
  case insertText(afterBlockID: String?, text: String, style: NoteParagraphStyle)
  case replaceBlock(id: String, block: NoteBlock)
  case deleteBlock(id: String)
  case setParagraphStyle(blockID: String, style: NoteParagraphStyle)
  case createTable(afterBlockID: String?, rows: Int, columns: Int, headerRow: Bool)
  case setTableCell(tableID: String, row: Int, column: Int, runs: [NoteTextRun])
  case addTableRow(tableID: String, after: Int?)
  case removeTableRow(tableID: String, row: Int)
  case addTableColumn(tableID: String, after: Int?)
  case removeTableColumn(tableID: String, column: Int)
  case setHTML(String)
  case setArtifactDatabaseLink(DatabaseArtifactLink?)
  case setTableDatabaseLink(tableID: String, link: DatabaseArtifactLink?)

  private enum CodingKeys: String, CodingKey {
    case type, title, text, style, afterBlockID, id, block, blockID
    case rows, columns, headerRow, tableID, row, column, runs, after
    case html, databaseLink
  }

  private enum Kind: String, Codable {
    case setTitle, appendText, insertText, replaceBlock, deleteBlock
    case setParagraphStyle, createTable, setTableCell
    case addTableRow, removeTableRow, addTableColumn, removeTableColumn
    case setHTML, setArtifactDatabaseLink, setTableDatabaseLink
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .type) {
    case .setTitle:
      self = .setTitle(try values.decode(String.self, forKey: .title))
    case .appendText:
      self = .appendText(
        try values.decode(String.self, forKey: .text),
        try values.decodeIfPresent(NoteParagraphStyle.self, forKey: .style) ?? .paragraph
      )
    case .insertText:
      self = .insertText(
        afterBlockID: try values.decodeIfPresent(String.self, forKey: .afterBlockID),
        text: try values.decode(String.self, forKey: .text),
        style: try values.decodeIfPresent(NoteParagraphStyle.self, forKey: .style) ?? .paragraph
      )
    case .replaceBlock:
      self = .replaceBlock(
        id: try values.decode(String.self, forKey: .id),
        block: try values.decode(NoteBlock.self, forKey: .block)
      )
    case .deleteBlock:
      self = .deleteBlock(id: try values.decode(String.self, forKey: .id))
    case .setParagraphStyle:
      self = .setParagraphStyle(
        blockID: try values.decode(String.self, forKey: .blockID),
        style: try values.decode(NoteParagraphStyle.self, forKey: .style)
      )
    case .createTable:
      self = .createTable(
        afterBlockID: try values.decodeIfPresent(String.self, forKey: .afterBlockID),
        rows: try values.decode(Int.self, forKey: .rows),
        columns: try values.decode(Int.self, forKey: .columns),
        headerRow: try values.decodeIfPresent(Bool.self, forKey: .headerRow) ?? false
      )
    case .setTableCell:
      self = .setTableCell(
        tableID: try values.decode(String.self, forKey: .tableID),
        row: try values.decode(Int.self, forKey: .row),
        column: try values.decode(Int.self, forKey: .column),
        runs: try values.decode([NoteTextRun].self, forKey: .runs)
      )
    case .addTableRow:
      self = .addTableRow(
        tableID: try values.decode(String.self, forKey: .tableID),
        after: try values.decodeIfPresent(Int.self, forKey: .after)
      )
    case .removeTableRow:
      self = .removeTableRow(
        tableID: try values.decode(String.self, forKey: .tableID),
        row: try values.decode(Int.self, forKey: .row)
      )
    case .addTableColumn:
      self = .addTableColumn(
        tableID: try values.decode(String.self, forKey: .tableID),
        after: try values.decodeIfPresent(Int.self, forKey: .after)
      )
    case .removeTableColumn:
      self = .removeTableColumn(
        tableID: try values.decode(String.self, forKey: .tableID),
        column: try values.decode(Int.self, forKey: .column)
      )
    case .setHTML:
      self = .setHTML(try values.decode(String.self, forKey: .html))
    case .setArtifactDatabaseLink:
      self = .setArtifactDatabaseLink(
        try values.decodeIfPresent(DatabaseArtifactLink.self, forKey: .databaseLink)
      )
    case .setTableDatabaseLink:
      self = .setTableDatabaseLink(
        tableID: try values.decode(String.self, forKey: .tableID),
        link: try values.decodeIfPresent(DatabaseArtifactLink.self, forKey: .databaseLink)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .setTitle(let title):
      try values.encode(Kind.setTitle, forKey: .type)
      try values.encode(title, forKey: .title)
    case .appendText(let text, let style):
      try values.encode(Kind.appendText, forKey: .type)
      try values.encode(text, forKey: .text)
      try values.encode(style, forKey: .style)
    case .insertText(let afterBlockID, let text, let style):
      try values.encode(Kind.insertText, forKey: .type)
      try values.encodeIfPresent(afterBlockID, forKey: .afterBlockID)
      try values.encode(text, forKey: .text)
      try values.encode(style, forKey: .style)
    case .replaceBlock(let id, let block):
      try values.encode(Kind.replaceBlock, forKey: .type)
      try values.encode(id, forKey: .id)
      try values.encode(block, forKey: .block)
    case .deleteBlock(let id):
      try values.encode(Kind.deleteBlock, forKey: .type)
      try values.encode(id, forKey: .id)
    case .setParagraphStyle(let blockID, let style):
      try values.encode(Kind.setParagraphStyle, forKey: .type)
      try values.encode(blockID, forKey: .blockID)
      try values.encode(style, forKey: .style)
    case .createTable(let afterBlockID, let rows, let columns, let headerRow):
      try values.encode(Kind.createTable, forKey: .type)
      try values.encodeIfPresent(afterBlockID, forKey: .afterBlockID)
      try values.encode(rows, forKey: .rows)
      try values.encode(columns, forKey: .columns)
      try values.encode(headerRow, forKey: .headerRow)
    case .setTableCell(let tableID, let row, let column, let runs):
      try values.encode(Kind.setTableCell, forKey: .type)
      try values.encode(tableID, forKey: .tableID)
      try values.encode(row, forKey: .row)
      try values.encode(column, forKey: .column)
      try values.encode(runs, forKey: .runs)
    case .addTableRow(let tableID, let after):
      try values.encode(Kind.addTableRow, forKey: .type)
      try values.encode(tableID, forKey: .tableID)
      try values.encodeIfPresent(after, forKey: .after)
    case .removeTableRow(let tableID, let row):
      try values.encode(Kind.removeTableRow, forKey: .type)
      try values.encode(tableID, forKey: .tableID)
      try values.encode(row, forKey: .row)
    case .addTableColumn(let tableID, let after):
      try values.encode(Kind.addTableColumn, forKey: .type)
      try values.encode(tableID, forKey: .tableID)
      try values.encodeIfPresent(after, forKey: .after)
    case .removeTableColumn(let tableID, let column):
      try values.encode(Kind.removeTableColumn, forKey: .type)
      try values.encode(tableID, forKey: .tableID)
      try values.encode(column, forKey: .column)
    case .setHTML(let html):
      try values.encode(Kind.setHTML, forKey: .type)
      try values.encode(html, forKey: .html)
    case .setArtifactDatabaseLink(let link):
      try values.encode(Kind.setArtifactDatabaseLink, forKey: .type)
      try values.encodeIfPresent(link, forKey: .databaseLink)
    case .setTableDatabaseLink(let tableID, let link):
      try values.encode(Kind.setTableDatabaseLink, forKey: .type)
      try values.encode(tableID, forKey: .tableID)
      try values.encodeIfPresent(link, forKey: .databaseLink)
    }
  }
}

public extension NoteDocument {
  mutating func apply(_ operations: [NoteEditOperation]) throws -> String? {
    var title: String?
    for operation in operations {
      switch operation {
      case .setTitle(let value):
        title = value
      case .appendText(let text, let style):
        blocks.append(.richText(NoteRichTextBlock(style: style, text: text)))
      case .insertText(let afterBlockID, let text, let style):
        let block = NoteBlock.richText(NoteRichTextBlock(style: style, text: text))
        blocks.insert(block, at: insertionIndex(after: afterBlockID))
      case .replaceBlock(let id, let block):
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
          throw NoteEditError.blockNotFound(id)
        }
        blocks[index] = block
      case .deleteBlock(let id):
        guard let index = blocks.firstIndex(where: { $0.id == id }) else {
          throw NoteEditError.blockNotFound(id)
        }
        blocks.remove(at: index)
      case .setParagraphStyle(let blockID, let style):
        guard let index = blocks.firstIndex(where: { $0.id == blockID }),
              case .richText(var block) = blocks[index] else {
          throw NoteEditError.blockNotFound(blockID)
        }
        block.style = style
        blocks[index] = .richText(block)
      case .createTable(let afterBlockID, let rows, let columns, let headerRow):
        blocks.insert(
          .table(NoteTableBlock(rows: rows, columns: columns, headerRow: headerRow)),
          at: insertionIndex(after: afterBlockID)
        )
      case .setTableCell(let tableID, let row, let column, let runs):
        try mutateTable(id: tableID) { table in
          guard table.rows.indices.contains(row), table.columns.indices.contains(column) else {
            throw NoteEditError.tableCoordinateOutOfRange
          }
          table.rows[row].cells[column].runs = runs
        }
      case .addTableRow(let tableID, let after):
        try mutateTable(id: tableID) { table in
          let index = min(max(0, (after ?? table.rows.count - 1) + 1), table.rows.count)
          table.rows.insert(NoteTableRow(cellCount: table.columns.count), at: index)
        }
      case .removeTableRow(let tableID, let row):
        try mutateTable(id: tableID) { table in
          guard table.rows.count > 1, table.rows.indices.contains(row) else {
            throw NoteEditError.tableCoordinateOutOfRange
          }
          table.rows.remove(at: row)
          table.headerRowCount = min(table.headerRowCount, table.rows.count)
        }
      case .addTableColumn(let tableID, let after):
        try mutateTable(id: tableID) { table in
          let index = min(max(0, (after ?? table.columns.count - 1) + 1), table.columns.count)
          table.columns.insert(NoteTableColumn(), at: index)
          for row in table.rows.indices {
            table.rows[row].cells.insert(NoteTableCell(), at: index)
          }
        }
      case .removeTableColumn(let tableID, let column):
        try mutateTable(id: tableID) { table in
          guard table.columns.count > 1, table.columns.indices.contains(column) else {
            throw NoteEditError.tableCoordinateOutOfRange
          }
          table.columns.remove(at: column)
          for row in table.rows.indices { table.rows[row].cells.remove(at: column) }
        }
      case .setHTML(let value):
        guard kind == .html else { throw NoteEditError.artifactKindMismatch }
        html = value
      case .setArtifactDatabaseLink(let link):
        databaseLink = link
      case .setTableDatabaseLink(let tableID, let link):
        try mutateTable(id: tableID) { $0.databaseLink = link }
      }
    }
    self = normalized()
    return title
  }

  private func insertionIndex(after blockID: String?) -> Int {
    guard let blockID, let index = blocks.firstIndex(where: { $0.id == blockID }) else {
      return blocks.endIndex
    }
    return index + 1
  }

  private mutating func mutateTable(
    id: String,
    _ mutation: (inout NoteTableBlock) throws -> Void
  ) throws {
    guard let index = blocks.firstIndex(where: { $0.id == id }),
          case .table(var table) = blocks[index] else {
      throw NoteEditError.tableNotFound(id)
    }
    try mutation(&table)
    blocks[index] = .table(table.normalized())
  }
}

public enum NoteEditError: Error, Equatable, LocalizedError {
  case blockNotFound(String)
  case tableNotFound(String)
  case tableCoordinateOutOfRange
  case artifactKindMismatch

  public var errorDescription: String? {
    switch self {
    case .blockNotFound(let id): "Note block not found: \(id)"
    case .tableNotFound(let id): "Note table not found: \(id)"
    case .tableCoordinateOutOfRange: "The table row or column is out of range."
    case .artifactKindMismatch: "This operation does not match the artifact type."
    }
  }
}
