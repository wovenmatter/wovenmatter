import Foundation

// Databases: named SQLite files that notes, pages, sheets and apps link to for live
// data. Each lives on one owning machine, whose server is its only writer. A
// write made through any other machine's server is forwarded to the owner.
// After each committed write the owner publishes a copy into the content
// store; every other machine answers reads from the latest copy.

/// A database as the library describes it.
public struct Database: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  /// The owning machine, its only writer.
  public var machineID: String
  public var name: String
  public var description: String
  /// The latest copy the owner published, by content digest; nil before the first.
  public var copyDigest: String?
  public var copySize: Int64?
  /// When the owner published that copy: when the data last changed.
  public var copiedAt: Date?
  public var createdAt: Date

  public init(id: String, machineID: String, name: String, description: String, copyDigest: String?, copySize: Int64?,
              copiedAt: Date?, createdAt: Date) {
    self.id = id
    self.machineID = machineID
    self.name = name
    self.description = description
    self.copyDigest = copyDigest
    self.copySize = copySize
    self.copiedAt = copiedAt
    self.createdAt = createdAt
  }
}

public struct DatabaseColumn: Codable, Sendable, Hashable {
  public var name: String
  /// The declared type, as the table's schema has it.
  public var type: String

  public init(name: String, type: String) {
    self.name = name
    self.type = type
  }
}

public struct DatabaseTable: Codable, Sendable, Hashable {
  public var name: String
  public var columns: [DatabaseColumn]
  public var rowCount: Int64

  public init(name: String, columns: [DatabaseColumn], rowCount: Int64) {
    self.name = name
    self.columns = columns
    self.rowCount = rowCount
  }
}

/// A database's tables, read from the owner's file or the latest copy.
public struct DatabaseDescription: Codable, Sendable, Hashable {
  public var database: Database
  public var tables: [DatabaseTable]
  /// Read from the latest published copy rather than the owner's file.
  public var fromCopy: Bool

  public init(database: Database, tables: [DatabaseTable], fromCopy: Bool) {
    self.database = database
    self.tables = tables
    self.fromCopy = fromCopy
  }
}

/// What a query returned: each value as text (a blob as hex, null as empty),
/// and the same rows as a JSON array of objects for an app.
public struct DatabaseRows: Codable, Sendable, Hashable {
  public var columns: [String]
  public var rows: [[String]]
  public var json: String
  /// Read from the latest published copy rather than the owner's file.
  public var fromCopy: Bool

  public init(columns: [String], rows: [[String]], json: String, fromCopy: Bool) {
    self.columns = columns
    self.rows = rows
    self.json = json
    self.fromCopy = fromCopy
  }
}

/// A committed write and the copy published after it.
public struct DatabaseWritten: Codable, Sendable, Hashable {
  public var database: Database
  /// Rows the write inserted, changed or deleted.
  public var changes: Int64

  public init(database: Database, changes: Int64) {
    self.database = database
    self.changes = changes
  }
}

/// The limits every database read and write keeps to.
public enum DatabaseLimits {
  /// The largest database a copy is published of; a write that would grow it
  /// beyond this is rolled back.
  public static let maximumCopyBytes: Int64 = 32 * 1_024 * 1_024
  public static let maximumRows = 1_000
  public static let maximumColumns = 128
  /// The most text a query's result may hold.
  public static let maximumResultBytes = 1_048_576
  public static let maximumExecuteSQLBytes = 262_144
  public static let maximumQuerySQLBytes = 65_536
  /// How long one statement may run.
  public static let maximumSeconds = 5.0
  public static let maximumNameLength = 128
}

// MARK: Requests

/// Every database in the library, by name.
public struct ListDatabases: Request {
  public static let method = "databases.list"
  public typealias Reply = [Database]
  public init() {}
}

/// Creates a database owned by `machineID` (the machine of the server asked
/// when nil). With `copyOf`, it starts as a copy of that database's latest
/// published copy and is independent of it afterwards.
public struct CreateDatabase: Request {
  public static let method = "databases.create"
  public typealias Reply = Database
  public var name: String
  public var description: String
  public var machineID: String?
  public var copyOf: String?
  public init(name: String, description: String = "", machineID: String? = nil, copyOf: String? = nil) {
    self.name = name
    self.description = description
    self.machineID = machineID
    self.copyOf = copyOf
  }
}

public struct DescribeDatabase: Request {
  public static let method = "databases.describe"
  public typealias Reply = DatabaseDescription
  public var databaseID: String
  public init(databaseID: String) { self.databaseID = databaseID }
}

/// Runs SQL that changes the database, as one transaction on the owner. It may
/// change its own tables and schema; it may not attach other files, load
/// extensions or begin, commit or roll back transactions itself.
public struct ExecuteDatabase: Request {
  public static let method = "databases.execute"
  public typealias Reply = DatabaseWritten
  public var databaseID: String
  public var sql: String
  public init(databaseID: String, sql: String) {
    self.databaseID = databaseID
    self.sql = sql
  }
}

/// Runs one read-only statement: on the owner its file, elsewhere the latest copy.
public struct QueryDatabase: Request {
  public static let method = "databases.query"
  public typealias Reply = DatabaseRows
  public var databaseID: String
  public var sql: String
  public init(databaseID: String, sql: String) {
    self.databaseID = databaseID
    self.sql = sql
  }
}

/// Deletes a database on its owner and from every library.
public struct DeleteDatabase: Request {
  public static let method = "databases.delete"
  public typealias Reply = Done
  public var databaseID: String
  public init(databaseID: String) { self.databaseID = databaseID }
}
