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
  case sqliteQueryLimitExceeded
  case sqliteResultTooLarge
  case sqliteFailure(String)

  public var errorDescription: String? {
    switch self {
    case .fileUnavailable: "The linked data file is unavailable."
    case .fileTooLarge: "The linked data file is too large to render safely."
    case .unsupportedFormat: "Linked artifacts currently support JSON and SQLite files."
    case .malformedJSON: "The linked JSON file could not be converted to tabular data."
    case .sqliteQueryRequired: "Add a read-only SQLite query to this artifact link."
    case .sqliteReadOnlyQueryRequired: "Only one read-only SQLite SELECT or WITH query is allowed."
    case .sqliteQueryLimitExceeded: "The linked SQLite query exceeded its execution limit."
    case .sqliteResultTooLarge: "The linked SQLite result is too large to render safely."
    case .sqliteFailure(let detail): "SQLite could not read the linked data: \(detail)"
    }
  }
}

public enum DatabaseLinkedData {
  public static let maximumFileBytes = 8 * 1_024 * 1_024
  public static let maximumRows = 1_000
  public static let maximumColumns = 128
  public static let maximumSQLiteQueryBytes = 64 * 1_024
  public static let maximumSQLiteCellBytes = 256 * 1_024
  public static let maximumSQLiteResultBytes = 2 * 1_024 * 1_024
  private static let maximumSQLiteProgressCallbacks = 5_000
  private static let maximumSQLiteDuration: TimeInterval = 1

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
    var resultBytes = 2
    for column in queryResponse.columns {
      let (next, overflow) = resultBytes.addingReportingOverflow(try sqliteJSONStringBytes(column))
      guard !overflow, column.utf8.count <= maximumSQLiteCellBytes,
            next <= maximumSQLiteResultBytes else {
        throw DatabaseLinkedDataError.sqliteResultTooLarge
      }
      resultBytes = next
    }
    for row in queryResponse.rows {
      resultBytes += 3 // Object delimiters and its array separator, including empty rows.
      for (index, value) in row.enumerated() {
        let (namedBytes, nameOverflow) = try sqliteJSONStringBytes(value).addingReportingOverflow(sqliteJSONStringBytes(queryResponse.columns[index]))
        let (cellBytes, cellOverflow) = namedBytes.addingReportingOverflow(8)
        let (next, totalOverflow) = resultBytes.addingReportingOverflow(cellBytes)
        guard !nameOverflow, !cellOverflow, !totalOverflow, value.utf8.count <= maximumSQLiteCellBytes,
              next <= maximumSQLiteResultBytes else {
          throw DatabaseLinkedDataError.sqliteResultTooLarge
        }
        resultBytes = next
      }
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
    guard normalized.utf8.count <= maximumSQLiteQueryBytes,
          let firstWord, ["select", "with"].contains(firstWord),
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
    sqlite3_limit(connection, SQLITE_LIMIT_LENGTH, Int32(maximumSQLiteCellBytes))
    sqlite3_limit(connection, SQLITE_LIMIT_SQL_LENGTH, Int32(maximumSQLiteQueryBytes))
    sqlite3_limit(connection, SQLITE_LIMIT_COLUMN, Int32(maximumColumns))
    sqlite3_limit(connection, SQLITE_LIMIT_EXPR_DEPTH, 100)
    sqlite3_set_authorizer(connection, { _, action, _, _, _, _ in
      switch action {
      case SQLITE_PRAGMA, SQLITE_ATTACH, SQLITE_DETACH, SQLITE_ALTER_TABLE, SQLITE_ANALYZE,
           SQLITE_CREATE_INDEX, SQLITE_CREATE_TABLE, SQLITE_CREATE_TEMP_INDEX,
           SQLITE_CREATE_TEMP_TABLE, SQLITE_CREATE_TEMP_TRIGGER, SQLITE_CREATE_TEMP_VIEW,
           SQLITE_CREATE_TRIGGER, SQLITE_CREATE_VIEW, SQLITE_CREATE_VTABLE,
           SQLITE_DELETE, SQLITE_DROP_INDEX, SQLITE_DROP_TABLE, SQLITE_DROP_TEMP_INDEX,
           SQLITE_DROP_TEMP_TABLE, SQLITE_DROP_TEMP_TRIGGER, SQLITE_DROP_TEMP_VIEW,
           SQLITE_DROP_TRIGGER, SQLITE_DROP_VIEW, SQLITE_DROP_VTABLE, SQLITE_INSERT,
           SQLITE_REINDEX, SQLITE_SAVEPOINT, SQLITE_TRANSACTION, SQLITE_UPDATE:
        return SQLITE_DENY
      default: return SQLITE_OK
      }
    }, nil)
    let budget = SQLiteQueryBudget(maximumCallbacks: maximumSQLiteProgressCallbacks,
      deadline: Date().addingTimeInterval(maximumSQLiteDuration))
    sqlite3_progress_handler(connection, 1_000, { pointer in
      guard let pointer else { return 1 }
      return Unmanaged<SQLiteQueryBudget>.fromOpaque(pointer).takeUnretainedValue().shouldInterrupt() ? 1 : 0
    }, Unmanaged.passUnretained(budget).toOpaque())
    defer { sqlite3_progress_handler(connection, 0, nil, nil); sqlite3_set_authorizer(connection, nil, nil) }

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
    var resultBytes = 2
    for column in columns {
      let (next, overflow) = resultBytes.addingReportingOverflow(try sqliteJSONStringBytes(column))
      guard !overflow, next <= maximumSQLiteResultBytes else {
        throw DatabaseLinkedDataError.sqliteResultTooLarge
      }
      resultBytes = next
    }
    while rows.count < maximumRows {
      let result = sqlite3_step(statement)
      if result == SQLITE_DONE { break }
      if result == SQLITE_INTERRUPT { throw DatabaseLinkedDataError.sqliteQueryLimitExceeded }
      if result == SQLITE_TOOBIG { throw DatabaseLinkedDataError.sqliteResultTooLarge }
      guard result == SQLITE_ROW else {
        throw DatabaseLinkedDataError.sqliteFailure(String(cString: sqlite3_errmsg(connection)))
      }
      resultBytes += 3
      var row: [String] = []
      row.reserveCapacity(count)
      for index in 0..<count {
        let value = try sqliteValue(statement, index: Int32(index))
        let (namedBytes, nameOverflow) = try sqliteJSONStringBytes(value).addingReportingOverflow(sqliteJSONStringBytes(columns[index]))
        let (cellBytes, cellOverflow) = namedBytes.addingReportingOverflow(8)
        let (next, totalOverflow) = resultBytes.addingReportingOverflow(cellBytes)
        guard !nameOverflow, !cellOverflow, !totalOverflow,
              next <= maximumSQLiteResultBytes else {
          throw DatabaseLinkedDataError.sqliteResultTooLarge
        }
        resultBytes = next
        row.append(value)
      }
      rows.append(row)
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

  // Budget the emitted JSON, including escaped controls and repeated object keys,
  // before allocating dictionaries and the final serialization.
  private static func sqliteJSONStringBytes(_ value: String) throws -> Int {
    guard value.utf8.count <= maximumSQLiteCellBytes else {
      throw DatabaseLinkedDataError.sqliteResultTooLarge
    }
    var bytes = 2 // String quotes.
    for scalar in value.unicodeScalars {
      switch scalar.value {
      case 0...0x1f, 0x2028, 0x2029: bytes += 6
      case 0x22, 0x2f, 0x5c: bytes += 2
      case 0...0x7f: bytes += 1
      case 0...0x7ff: bytes += 2
      case 0...0xffff: bytes += 3
      default: bytes += 4
      }
    }
    return bytes
  }

  private static func sqliteValue(_ statement: OpaquePointer, index: Int32) throws -> String {
    switch sqlite3_column_type(statement, index) {
    case SQLITE_NULL: return ""
    case SQLITE_INTEGER: return String(sqlite3_column_int64(statement, index))
    case SQLITE_FLOAT: return String(sqlite3_column_double(statement, index))
    case SQLITE_TEXT:
      guard sqlite3_column_bytes(statement, index) <= maximumSQLiteCellBytes else {
        throw DatabaseLinkedDataError.sqliteResultTooLarge
      }
      guard let bytes = sqlite3_column_text(statement, index) else { return "" }
      return String(decoding: UnsafeBufferPointer(start: bytes,
        count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)
    case SQLITE_BLOB:
      let count = Int(sqlite3_column_bytes(statement, index))
      guard count <= maximumSQLiteCellBytes * 3 / 4 else {
        throw DatabaseLinkedDataError.sqliteResultTooLarge
      }
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

private final class SQLiteQueryBudget {
  private var remainingCallbacks: Int
  private let deadline: Date
  init(maximumCallbacks: Int, deadline: Date) {
    self.remainingCallbacks = maximumCallbacks
    self.deadline = deadline
  }
  func shouldInterrupt() -> Bool {
    remainingCallbacks -= 1
    return remainingCallbacks < 0 || Date() >= deadline
  }
}
