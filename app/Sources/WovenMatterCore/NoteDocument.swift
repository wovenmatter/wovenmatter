import Foundation

public struct NoteDocument: Codable, Equatable, Sendable {
  public static let currentVersion = 2

  public var version: Int
  public var kind: NoteArtifactKind
  public var blocks: [NoteBlock]
  public var html: String
  public var databaseLink: DatabaseArtifactLink?

  public init(
    version: Int = currentVersion,
    kind: NoteArtifactKind = .note,
    blocks: [NoteBlock] = [],
    html: String = "",
    databaseLink: DatabaseArtifactLink? = nil
  ) {
    self.version = version
    self.kind = kind
    self.blocks = if blocks.isEmpty {
      kind == .spreadsheet
        ? [.table(NoteTableBlock(rows: 20, columns: 8, headerRow: true))]
        : [.richText(NoteRichTextBlock())]
    } else {
      blocks
    }
    self.html = html
    self.databaseLink = databaseLink
  }

  private enum CodingKeys: String, CodingKey {
    case version, kind, blocks, html, databaseLink
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let decodedVersion = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
    guard decodedVersion == 1 || decodedVersion == Self.currentVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .version,
        in: values,
        debugDescription: "Unsupported note document version"
      )
    }
    version = Self.currentVersion
    kind = try values.decodeIfPresent(NoteArtifactKind.self, forKey: .kind) ?? .note
    blocks = try values.decodeIfPresent([NoteBlock].self, forKey: .blocks) ?? []
    html = try values.decodeIfPresent(String.self, forKey: .html) ?? ""
    databaseLink = try values.decodeIfPresent(
      DatabaseArtifactLink.self,
      forKey: .databaseLink
    )
  }

  public static func decode(_ content: String) -> NoteDocument {
    guard let data = content.data(using: .utf8),
          let document = try? JSONDecoder().decode(NoteDocument.self, from: data),
          document.version == currentVersion else {
      return NoteDocument(legacyContent: content)
    }
    return document.normalized()
  }

  public func encoded() throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(normalized())
    guard let value = String(data: data, encoding: .utf8) else {
      throw NoteDocumentError.invalidEncoding
    }
    return value
  }

  public var plainText: String {
    kind == .html ? html : blocks.map(\.plainText).joined(separator: "\n")
  }

  public func normalized() -> NoteDocument {
    NoteDocument(
      version: Self.currentVersion,
      kind: kind,
      blocks: blocks.map(\.normalized),
      html: html,
      databaseLink: databaseLink
    )
  }

  private init(legacyContent: String) {
    let text = Self.plainText(fromLegacyContent: legacyContent)
    self.init(blocks: [.richText(NoteRichTextBlock(text: text))])
  }

  private static func plainText(fromLegacyContent content: String) -> String {
    var value = content.replacingOccurrences(
      of: "<!-- wovenmatter-appkit-rich-v1 -->",
      with: ""
    )
    let replacements: [(String, String, String.CompareOptions)] = [
      (#"</p>\s*<p[^>]*>"#, "\n", [.regularExpression, .caseInsensitive]),
      (#"<br\s*/?>"#, "\n", [.regularExpression, .caseInsensitive]),
      (#"</li>\s*<li[^>]*>"#, "\n", [.regularExpression, .caseInsensitive]),
      (#"<[^>]+>"#, "", .regularExpression),
      ("&nbsp;", " ", []),
      ("&amp;", "&", []),
      ("&lt;", "<", []),
      ("&gt;", ">", []),
      ("&quot;", "\"", []),
      ("&#39;", "'", []),
    ]
    for (source, replacement, options) in replacements {
      value = value.replacingOccurrences(of: source, with: replacement, options: options)
    }
    return value.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

public enum NoteBlock: Equatable, Sendable {
  case richText(NoteRichTextBlock)
  case table(NoteTableBlock)

  public var id: String {
    switch self {
    case .richText(let block): block.id
    case .table(let block): block.id
    }
  }

  public var plainText: String {
    switch self {
    case .richText(let block): block.plainText
    case .table(let block): block.plainText
    }
  }

  public var normalized: NoteBlock {
    switch self {
    case .richText(let block): .richText(block.normalized())
    case .table(let block): .table(block.normalized())
    }
  }
}

extension NoteBlock: Codable {
  private enum CodingKeys: String, CodingKey { case type, value }
  private enum BlockType: String, Codable { case richText, table }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(BlockType.self, forKey: .type) {
    case .richText:
      self = .richText(try values.decode(NoteRichTextBlock.self, forKey: .value))
    case .table:
      self = .table(try values.decode(NoteTableBlock.self, forKey: .value))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .richText(let block):
      try values.encode(BlockType.richText, forKey: .type)
      try values.encode(block, forKey: .value)
    case .table(let block):
      try values.encode(BlockType.table, forKey: .type)
      try values.encode(block, forKey: .value)
    }
  }
}

public struct NoteRichTextBlock: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var style: NoteParagraphStyle
  public var runs: [NoteTextRun]

  public init(
    id: String = UUID().uuidString.lowercased(),
    style: NoteParagraphStyle = .paragraph,
    runs: [NoteTextRun] = []
  ) {
    self.id = id
    self.style = style
    self.runs = runs
  }

  public init(
    id: String = UUID().uuidString.lowercased(),
    style: NoteParagraphStyle = .paragraph,
    text: String
  ) {
    self.init(id: id, style: style, runs: text.isEmpty ? [] : [NoteTextRun(text: text)])
  }

  public var plainText: String { runs.map(\.text).joined() }

  public func normalized() -> NoteRichTextBlock {
    var copy = self
    copy.runs = NoteTextRun.mergingAdjacent(runs.filter { !$0.text.isEmpty })
    return copy
  }
}

public enum NoteParagraphStyle: String, Codable, CaseIterable, Sendable {
  case paragraph
  case heading1
  case heading2
  case heading3
  case heading4
  case heading5
  case heading6
  case bulletedList
  case numberedList
}

public struct NoteTextRun: Codable, Equatable, Sendable {
  public var text: String
  public var fontFamily: String?
  public var fontSize: Double?
  public var bold: Bool
  public var italic: Bool
  public var underline: Bool
  public var foregroundHex: String?
  public var highlightHex: String?
  public var link: String?

  public init(
    text: String,
    fontFamily: String? = nil,
    fontSize: Double? = nil,
    bold: Bool = false,
    italic: Bool = false,
    underline: Bool = false,
    foregroundHex: String? = nil,
    highlightHex: String? = nil,
    link: String? = nil
  ) {
    self.text = text
    self.fontFamily = fontFamily
    self.fontSize = fontSize
    self.bold = bold
    self.italic = italic
    self.underline = underline
    self.foregroundHex = foregroundHex
    self.highlightHex = highlightHex
    self.link = link
  }

  fileprivate static func mergingAdjacent(_ runs: [NoteTextRun]) -> [NoteTextRun] {
    runs.reduce(into: []) { result, run in
      guard var previous = result.last, previous.attributesEqual(to: run) else {
        result.append(run)
        return
      }
      previous.text += run.text
      result[result.count - 1] = previous
    }
  }

  private func attributesEqual(to other: NoteTextRun) -> Bool {
    var lhs = self
    var rhs = other
    lhs.text = ""
    rhs.text = ""
    return lhs == rhs
  }
}

public struct NoteTableBlock: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var columns: [NoteTableColumn]
  public var rows: [NoteTableRow]
  public var headerRowCount: Int
  public var databaseLink: DatabaseArtifactLink?

  public init(
    id: String = UUID().uuidString.lowercased(),
    columns: [NoteTableColumn],
    rows: [NoteTableRow],
    headerRowCount: Int = 0,
    databaseLink: DatabaseArtifactLink? = nil
  ) {
    self.id = id
    self.columns = columns
    self.rows = rows
    self.headerRowCount = headerRowCount
    self.databaseLink = databaseLink
  }

  public init(rows: Int, columns: Int, headerRow: Bool = false) {
    let columnCount = max(1, columns)
    let rowCount = max(1, rows)
    self.init(
      columns: (0..<columnCount).map { _ in NoteTableColumn() },
      rows: (0..<rowCount).map { _ in NoteTableRow(cellCount: columnCount) },
      headerRowCount: headerRow ? 1 : 0
    )
  }

  public var plainText: String {
    rows.map { $0.cells.map(\.plainText).joined(separator: "\t") }.joined(separator: "\n")
  }

  public func normalized() -> NoteTableBlock {
    var copy = self
    if copy.columns.isEmpty { copy.columns = [NoteTableColumn()] }
    let cellCount = copy.columns.count
    if copy.rows.isEmpty { copy.rows = [NoteTableRow(cellCount: cellCount)] }
    copy.rows = copy.rows.map { $0.normalized(cellCount: cellCount) }
    copy.headerRowCount = min(max(0, copy.headerRowCount), copy.rows.count)
    return copy
  }
}

public struct NoteTableColumn: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var width: Double?

  public init(id: String = UUID().uuidString.lowercased(), width: Double? = nil) {
    self.id = id
    self.width = width
  }
}

public struct NoteTableRow: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var cells: [NoteTableCell]

  public init(
    id: String = UUID().uuidString.lowercased(),
    cells: [NoteTableCell]
  ) {
    self.id = id
    self.cells = cells
  }

  public init(id: String = UUID().uuidString.lowercased(), cellCount: Int) {
    self.init(id: id, cells: (0..<max(1, cellCount)).map { _ in NoteTableCell() })
  }

  fileprivate func normalized(cellCount: Int) -> NoteTableRow {
    var copy = self
    copy.cells = Array(copy.cells.prefix(cellCount))
    while copy.cells.count < cellCount { copy.cells.append(NoteTableCell()) }
    return copy
  }
}

public struct NoteTableCell: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var runs: [NoteTextRun]
  public var backgroundHex: String?

  public init(
    id: String = UUID().uuidString.lowercased(),
    runs: [NoteTextRun] = [],
    backgroundHex: String? = nil
  ) {
    self.id = id
    self.runs = runs
    self.backgroundHex = backgroundHex
  }

  public init(
    id: String = UUID().uuidString.lowercased(),
    text: String,
    backgroundHex: String? = nil
  ) {
    self.init(
      id: id,
      runs: text.isEmpty ? [] : [NoteTextRun(text: text)],
      backgroundHex: backgroundHex
    )
  }

  public var plainText: String { runs.map(\.text).joined() }
}

public enum NoteDocumentError: Error {
  case invalidEncoding
}
