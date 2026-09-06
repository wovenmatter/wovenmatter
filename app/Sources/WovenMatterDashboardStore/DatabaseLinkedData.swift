import Foundation
import SQLite3
import WovenMatterCore

public enum DatabaseLinkedDataError: LocalizedError, Equatable, Sendable {
  case fileUnavailable
  case fileTooLarge
  case unsupportedFormat
  case malformedJSON
  case sqliteQueryRequired
  case sqliteReadOnlyQueryRequired
  case sqliteFailure(String)

  public var errorDescription: String? {
    switch self {
    case .fileUnavailable: "The linked data file is unavailable."
    case .fileTooLarge: "The linked data file is too large to render safely."
    case .unsupportedFormat: "Linked artifacts currently support JSON and SQLite files."
    case .malformedJSON: "The linked JSON file could not be converted to tabular data."
    case .sqliteQueryRequired: "Add a read-only SQLite query to this artifact link."
    case .sqliteReadOnlyQueryRequired: "Only one read-only SQLite SELECT, WITH, or PRAGMA query is allowed."
    case .sqliteFailure(let detail): "SQLite could not read the linked data: \(detail)"
    }
  }
}

public enum DatabaseLinkedData {
  public static let maximumFileBytes = 8 * 1_024 * 1_024
  public static let maximumRows = 1_000
  public static let maximumColumns = 128

  public static func load(
    queryResponse: AgentDatabaseQueryResponse
  ) throws -> DatabaseTabularData {
    guard queryResponse.contractVersion == 1,
          queryResponse.columns.count <= maximumColumns,
          Set(queryResponse.columns).count == queryResponse.columns.count,
          queryResponse.rows.count <= maximumRows,
          queryResponse.rows.allSatisfy({ $0.count == queryResponse.columns.count }) else {
      throw DatabaseLinkedDataError.sqliteFailure("The database returned an invalid query response.")
    }
    let objects = queryResponse.rows.map { row in
      Dictionary(uniqueKeysWithValues: queryResponse.columns.enumerated().map { index, column in
        (column, row[index])
      })
    }
    return DatabaseTabularData(
      columns: queryResponse.columns,
      rows: queryResponse.rows,
      json: canonicalJSONString(objects)
    )
  }

  public static func requiresSQLiteFileAccess(
    fileExtension: String,
    preference: AgentDatabasePreference
  ) -> Bool {
    let value = fileExtension.lowercased()
    return ["sqlite", "sqlite3", "db"].contains(value)
      || (value != "json" && preference == .sqlite)
  }

  public static func load(
    from fileURL: URL,
    preference: AgentDatabasePreference,
    sqliteQuery: String?
  ) throws -> DatabaseTabularData {
    let extensionName = fileURL.pathExtension.lowercased()
    if ["sqlite", "sqlite3", "db"].contains(extensionName) {
      return try loadSQLite(from: fileURL, query: sqliteQuery)
    }
    if extensionName == "json" {
      return try loadJSON(from: fileURL)
    }
    if preference == .sqlite { return try loadSQLite(from: fileURL, query: sqliteQuery) }
    if preference == .json { return try loadJSON(from: fileURL) }
    throw DatabaseLinkedDataError.unsupportedFormat
  }

  public static func load(
    data: Data,
    fileExtension: String,
    preference: AgentDatabasePreference,
    sqliteQuery: String?
  ) throws -> DatabaseTabularData {
    guard data.count <= maximumFileBytes else {
      throw DatabaseLinkedDataError.fileTooLarge
    }
    let extensionName = fileExtension.lowercased()
    if ["sqlite", "sqlite3", "db"].contains(extensionName) {
      let directory = FileManager.default.temporaryDirectory.appending(
        path: "wovenmatter-linked-data-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
      )
      defer { try? FileManager.default.removeItem(at: directory) }
      let fileURL = directory.appending(path: "database.sqlite")
      try data.write(to: fileURL, options: [.atomic])
      return try loadSQLite(from: fileURL, query: sqliteQuery)
    }
    if extensionName == "json" {
      return try loadJSON(data: data)
    }
    if preference == .sqlite {
      return try load(
        data: data,
        fileExtension: "sqlite",
        preference: .none,
        sqliteQuery: sqliteQuery
      )
    }
    if preference == .json { return try loadJSON(data: data) }
    throw DatabaseLinkedDataError.unsupportedFormat
  }

  private static func loadJSON(from url: URL) throws -> DatabaseTabularData {
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
      throw DatabaseLinkedDataError.fileUnavailable
    }
    guard size <= maximumFileBytes else {
      throw DatabaseLinkedDataError.fileTooLarge
    }
    guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
      throw DatabaseLinkedDataError.fileUnavailable
    }
    return try loadJSON(data: data)
  }

  private static func loadJSON(data: Data) throws -> DatabaseTabularData {
    guard data.count <= maximumFileBytes else {
      throw DatabaseLinkedDataError.fileTooLarge
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    } catch {
      throw DatabaseLinkedDataError.malformedJSON
    }
    let table = try tabularJSON(object)
    return DatabaseTabularData(
      columns: table.columns,
      rows: table.rows,
      json: canonicalJSONString(object)
    )
  }

  private static func tabularJSON(_ object: Any) throws -> (columns: [String], rows: [[String]]) {
    if let values = object as? [[String: Any]] {
      var seen = Set<String>()
      var columns: [String] = []
      for row in values.prefix(maximumRows) {
        for key in row.keys.sorted() where seen.insert(key).inserted {
          columns.append(key)
          if columns.count == maximumColumns { break }
        }
        if columns.count == maximumColumns { break }
      }
      if columns.isEmpty { columns = ["Value"] }
      return (
        columns,
        values.prefix(maximumRows).map { row in
          columns.map { displayValue(row[$0] ?? NSNull()) }
        }
      )
    }
    if let values = object as? [[Any]] {
      let width = min(max(1, values.lazy.map(\.count).max() ?? 1), maximumColumns)
      let columns = (0..<width).map(columnName)
      return (
        columns,
        values.prefix(maximumRows).map { row in
          (0..<width).map { $0 < row.count ? displayValue(row[$0]) : "" }
        }
      )
    }
    if let dictionary = object as? [String: Any] {
      return (
        ["Key", "Value"],
        dictionary.keys.sorted().prefix(maximumRows).map {
          [$0, displayValue(dictionary[$0] ?? NSNull())]
        }
      )
    }
    if let values = object as? [Any] {
      return (["Value"], values.prefix(maximumRows).map { [displayValue($0)] })
    }
    return (["Value"], [[displayValue(object)]])
  }

  private static func loadSQLite(
    from url: URL,
    query rawQuery: String?
  ) throws -> DatabaseTabularData {
    let query = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !query.isEmpty else { throw DatabaseLinkedDataError.sqliteQueryRequired }
    let normalized = query.hasSuffix(";")
      ? String(query.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
      : query
    let firstWord = normalized.split(whereSeparator: \.isWhitespace).first?.lowercased()
    guard let firstWord, ["select", "with", "pragma"].contains(firstWord),
          !normalized.contains(";") else {
      throw DatabaseLinkedDataError.sqliteReadOnlyQueryRequired
    }

    var connection: OpaquePointer?
    guard sqlite3_open_v2(
      url.path,
      &connection,
      SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX,
      nil
    ) == SQLITE_OK, let connection else {
      defer { if connection != nil { sqlite3_close(connection) } }
      throw DatabaseLinkedDataError.sqliteFailure("The database could not be opened read-only.")
    }
    defer { sqlite3_close(connection) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, normalized, -1, &statement, nil) == SQLITE_OK,
          let statement else {
      throw DatabaseLinkedDataError.sqliteFailure(String(cString: sqlite3_errmsg(connection)))
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_stmt_readonly(statement) == 1 else {
      throw DatabaseLinkedDataError.sqliteReadOnlyQueryRequired
    }

    let count = min(Int(sqlite3_column_count(statement)), maximumColumns)
    let rawColumns = (0..<count).map { index in
      sqlite3_column_name(statement, Int32(index)).map(String.init(cString:))
        ?? columnName(index)
    }
    let columns = uniqueColumnNames(rawColumns)
    var rows: [[String]] = []
    while rows.count < maximumRows {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      guard result == SQLITE_ROW else {
        throw DatabaseLinkedDataError.sqliteFailure(String(cString: sqlite3_errmsg(connection)))
      }
      rows.append((0..<count).map { sqliteValue(statement, index: Int32($0)) })
    }
    let objects = rows.map { row in
      Dictionary(uniqueKeysWithValues: columns.enumerated().map { index, column in
        (column, index < row.count ? row[index] : "")
      })
    }
    return DatabaseTabularData(
      columns: columns,
      rows: rows,
      json: canonicalJSONString(objects)
    )
  }

  private static func sqliteValue(_ statement: OpaquePointer, index: Int32) -> String {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_NULL: return ""
    case SQLITE_INTEGER: return String(sqlite3_column_int64(statement, index))
    case SQLITE_FLOAT: return String(sqlite3_column_double(statement, index))
    case SQLITE_TEXT:
      return sqlite3_column_text(statement, index).map(String.init(cString:)) ?? ""
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, index))
      guard let bytes = sqlite3_column_blob(statement, index), count > 0 else { return "" }
      return Data(bytes: bytes, count: count).base64EncodedString()
    default: return ""
    }
  }

  private static func uniqueColumnNames(_ names: [String]) -> [String] {
    var used = Set<String>()
    return names.map { rawName in
      let base = rawName.isEmpty ? "Column" : rawName
      var candidate = base
      var suffix = 2
      while !used.insert(candidate).inserted {
        candidate = "\(base) (\(suffix))"
        suffix += 1
      }
      return candidate
    }
  }

  private static func displayValue(_ value: Any) -> String {
    switch value {
    case is NSNull: ""
    case let string as String: string
    case let number as NSNumber: number.stringValue
    default: canonicalJSONString(value)
    }
  }

  private static func canonicalJSONString(_ object: Any) -> String {
    guard JSONSerialization.isValidJSONObject(object),
          let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
          let string = String(data: data, encoding: .utf8) else {
      if let string = object as? String,
         let data = try? JSONEncoder().encode(string),
         let encoded = String(data: data, encoding: .utf8) {
        return encoded
      }
      return "null"
    }
    return string
  }

  private static func columnName(_ index: Int) -> String {
    var value = index
    var result = ""
    repeat {
      result.insert(Character(UnicodeScalar(65 + (value % 26))!), at: result.startIndex)
      value = value / 26 - 1
    } while value >= 0
    return result
  }
}
