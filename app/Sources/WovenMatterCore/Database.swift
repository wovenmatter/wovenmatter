import Foundation

public enum AgentDatabasePreference: String, Codable, CaseIterable, Sendable {
  case none
  case json
  case sqlite

  public var displayName: String {
    switch self {
    case .none: "No preference"
    case .json: "JSON"
    case .sqlite: "SQLite"
    }
  }
}

public struct AgentDatabaseManifest: Codable, Equatable, Sendable {
  public static let currentSchema = "wovenmatter.database.v1"

  public var schema: String
  public var preference: AgentDatabasePreference

  public init(
    schema: String = Self.currentSchema,
    preference: AgentDatabasePreference = .none
  ) {
    self.schema = schema
    self.preference = preference
  }

  public var isSupported: Bool { schema == Self.currentSchema }
}

public struct AgentDatabaseQueryResponse: Codable, Equatable, Sendable {
  public let contractVersion: Int
  public let columns: [String]
  public let rows: [[String]]

  public init(contractVersion: Int = 1, columns: [String], rows: [[String]]) {
    self.contractVersion = contractVersion
    self.columns = columns
    self.rows = rows
  }
}

public struct DatabaseTabularData: Equatable, Sendable {
  public let columns: [String]
  public let rows: [[String]]
  public let json: String

  public init(columns: [String], rows: [[String]], json: String) {
    self.columns = columns
    self.rows = rows
    self.json = json
  }

  public func applying(to existing: NoteTableBlock? = nil) -> NoteTableBlock {
    let columnCount = max(1, columns.count)
    var table = existing ?? NoteTableBlock(rows: max(1, rows.count + 1), columns: columnCount)
    while table.columns.count < columnCount { table.columns.append(NoteTableColumn()) }
    table.columns = Array(table.columns.prefix(columnCount))
    let values = [columns.isEmpty ? ["Value"] : columns] + rows
    while table.rows.count < values.count {
      table.rows.append(NoteTableRow(cellCount: columnCount))
    }
    table.rows = Array(table.rows.prefix(max(1, values.count)))
    for rowIndex in table.rows.indices {
      while table.rows[rowIndex].cells.count < columnCount {
        table.rows[rowIndex].cells.append(NoteTableCell())
      }
      table.rows[rowIndex].cells = Array(table.rows[rowIndex].cells.prefix(columnCount))
      for columnIndex in 0..<columnCount {
        let value = values.indices.contains(rowIndex)
          && values[rowIndex].indices.contains(columnIndex)
          ? values[rowIndex][columnIndex] : ""
        table.rows[rowIndex].cells[columnIndex].runs = value.isEmpty
          ? [] : [NoteTextRun(text: value)]
      }
    }
    table.headerRowCount = columns.isEmpty ? 0 : 1
    return table.normalized()
  }
}
