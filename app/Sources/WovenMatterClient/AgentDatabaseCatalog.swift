import Darwin
import Foundation
import SQLite3
import WovenMatterCore

public struct LocalAgentDatabase: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public var revision: Int64
    public var updatedAt: String
    public let owner: String
    public let url: URL
    public var preference: AgentDatabasePreference { .sqlite }
    public var isExternal: Bool { false }
}

public struct ManagedDatabaseSnapshot: Codable, Sendable {
    public let database: LocalAgentDatabase
    public let sqliteBase64: String
}

public enum AgentDatabaseCatalogError: LocalizedError, Equatable, Sendable {
    case invalidName, rootUnavailable, databaseAlreadyExists, databaseUnavailable
    case externalDirectoryUnavailable, externalDirectoryContainsRoot, unsafeRelativePath
    case dataFileTooLarge, unsupportedManifest
    case sql(String)
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Enter a database name of 1–128 characters."
        case .databaseAlreadyExists: "A database with that name already exists."
        case .sql(let message): "Database query failed: \(message)"
        case .dataFileTooLarge: "The database snapshot is too large."
        case .externalDirectoryUnavailable, .externalDirectoryContainsRoot: "Databases are managed by Woven Matter."
        default: "The managed database is unavailable."
        }
    }
}

/// Dataset files and catalog live outside the history/settings database and all project roots.
/// A workspace owns every write. Replicas are immutable complete SQLite backups.
public enum AgentDatabaseCatalog {
    public static let maximumSQLiteSnapshotBytes = 32 * 1_024 * 1_024
    private static let catalogName = "catalog.json"

    private static func locked<T>(_ root: URL, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let fd = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw AgentDatabaseCatalogError.rootUnavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw AgentDatabaseCatalogError.rootUnavailable }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
    private static func catalog(_ root: URL) throws -> [LocalAgentDatabase] {
        let file = root.appendingPathComponent(catalogName)
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        var rows = try JSONDecoder().decode([LocalAgentDatabase].self, from: Data(contentsOf: file))
        for index in rows.indices {
            rows[index].revision = try connection(try self.file(rows[index].id, root), writable: false) { db in
                var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
                guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else { throw AgentDatabaseCatalogError.databaseUnavailable }
                return sqlite3_column_int64(stmt, 0)
            }
        }
        return rows
    }
    private static func save(_ rows: [LocalAgentDatabase], _ root: URL) throws {
        try JSONEncoder().encode(rows).write(to: root.appendingPathComponent(catalogName), options: .atomic)
    }
    private static func file(_ id: String, _ root: URL) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw AgentDatabaseCatalogError.databaseUnavailable }
        return root.appendingPathComponent(id + ".sqlite")
    }
    private static func connection<T>(_ url: URL, writable: Bool, _ body: (OpaquePointer) throws -> T) throws -> T {
        var db: OpaquePointer?
        let flags = writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READWRITE
        guard let parent = realpath(url.deletingLastPathComponent().path, nil) else { throw AgentDatabaseCatalogError.rootUnavailable }
        defer { free(parent) }
        let physicalPath = URL(fileURLWithPath: String(cString: parent)).appendingPathComponent(url.lastPathComponent).path
        guard sqlite3_open_v2(physicalPath, &db, flags | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }; throw AgentDatabaseCatalogError.databaseUnavailable
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)
        sqlite3_limit(db, SQLITE_LIMIT_LENGTH, Int32(maximumSQLiteSnapshotBytes))
        var deadline = Date().timeIntervalSinceReferenceDate + 5
        return try withUnsafeMutablePointer(to: &deadline) { limit in
            sqlite3_progress_handler(db, 1000, { context in
                guard let context else { return 1 }
                return Date().timeIntervalSinceReferenceDate > context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
            }, limit)
            defer { sqlite3_progress_handler(db, 0, nil, nil) }
            return try body(db)
        }
    }
    private static func run(_ db: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw AgentDatabaseCatalogError.sql(String(cString: sqlite3_errmsg(db)))
        }
    }
    public static func list(at root: URL) throws -> [LocalAgentDatabase] {
        try locked(root) { try catalog(root).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    }
    @discardableResult
    public static func create(named rawName: String, preference: AgentDatabasePreference = .sqlite, in root: URL, owner: String = "") throws -> LocalAgentDatabase {
        try locked(root) {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 128, !name.contains("\0") else { throw AgentDatabaseCatalogError.invalidName }
            var rows = try catalog(root)
            guard !rows.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { throw AgentDatabaseCatalogError.databaseAlreadyExists }
            let id = UUID().uuidString.lowercased(), url = try file(id, root)
            try connection(url, writable: true) { try run($0, "PRAGMA journal_mode=WAL; PRAGMA user_version=1") }
            let row = LocalAgentDatabase(id: id, name: name, revision: 1, updatedAt: ISO8601DateFormatter().string(from: Date()), owner: owner, url: url)
            rows.append(row); try save(rows, root); return row
        }
    }
    public static func execute(id: String, sql: String, in root: URL, owner: String) throws -> LocalAgentDatabase {
        try locked(root) {
            var rows = try catalog(root)
            guard let index = rows.firstIndex(where: { $0.id == id && $0.owner == owner }) else { throw AgentDatabaseCatalogError.databaseUnavailable }
            guard !sql.isEmpty, sql.utf8.count <= 262_144 else { throw AgentDatabaseCatalogError.sql("Enter SQL up to 256 KiB.") }
            let path = try file(id, root)
            guard FileManager.default.fileExists(atPath: path.path) else { throw AgentDatabaseCatalogError.databaseUnavailable }
            try connection(path, writable: true) { db in
                try run(db, "BEGIN IMMEDIATE")
                // Agents may change their dataset schema, never other SQLite files or transaction boundaries.
                sqlite3_set_authorizer(db, { _, action, _, detail, _, _ in
                    if [SQLITE_ATTACH, SQLITE_DETACH, SQLITE_TRANSACTION, SQLITE_SAVEPOINT, SQLITE_PRAGMA].contains(action) { return SQLITE_DENY }
                    if action == SQLITE_FUNCTION, let detail, String(cString: detail) == "load_extension" { return SQLITE_DENY }
                    return SQLITE_OK
                }, nil)
                do { try run(db, sql) } catch { sqlite3_set_authorizer(db, nil, nil); try? run(db, "ROLLBACK"); throw error }
                sqlite3_set_authorizer(db, nil, nil)
                try run(db, "PRAGMA user_version=\(rows[index].revision + 1)")
                try run(db, "COMMIT")
            }
            rows[index].revision += 1; rows[index].updatedAt = ISO8601DateFormatter().string(from: Date())
            try save(rows, root); return rows[index]
        }
    }
    public static func query(id: String, sql: String, in root: URL) throws -> DatabaseTabularData {
        try locked(root) {
            guard try catalog(root).contains(where: { $0.id == id }), sql.utf8.count <= 65_536 else { throw AgentDatabaseCatalogError.databaseUnavailable }
            return try connection(try file(id, root), writable: false) { db in
                sqlite3_limit(db, SQLITE_LIMIT_LENGTH, 1_048_576)
                        var deadline = Date().timeIntervalSinceReferenceDate + 5
                return try withUnsafeMutablePointer(to: &deadline) { limit in
                    sqlite3_progress_handler(db, 1000, { context in
                        guard let context else { return 1 }
                        return Date().timeIntervalSinceReferenceDate > context.assumingMemoryBound(to: Double.self).pointee ? 1 : 0
                    }, limit)
                    defer { sqlite3_progress_handler(db, 0, nil, nil) }
                    sqlite3_set_authorizer(db, { _, action, _, detail, _, _ in
                        let allowed = [SQLITE_SELECT, SQLITE_READ, SQLITE_FUNCTION, SQLITE_RECURSIVE]
                        if !allowed.contains(action) { return SQLITE_DENY }
                        if action == SQLITE_FUNCTION, let detail, String(cString: detail) == "load_extension" { return SQLITE_DENY }
                        return SQLITE_OK
                    }, nil)
                    var stmt: OpaquePointer?
                    defer { sqlite3_finalize(stmt) }
                    let prepared = sql.withCString { pointer -> Bool in
                        var tail: UnsafePointer<CChar>?
                        let result = sqlite3_prepare_v2(db, pointer, -1, &stmt, &tail)
                        return result == SQLITE_OK && (tail.map { String(cString: $0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? true)
                    }
                    guard prepared, let stmt, sqlite3_stmt_readonly(stmt) == 1 else { throw AgentDatabaseCatalogError.sql(String(cString: sqlite3_errmsg(db))) }
                    let columns = (0..<sqlite3_column_count(stmt)).map { String(cString: sqlite3_column_name(stmt, $0)) }
                    guard !columns.isEmpty, columns.count <= 128, Set(columns).count == columns.count else { throw AgentDatabaseCatalogError.sql("Use unique query column names.") }
                    var rows: [[String]] = [], bytes = 0
                    while rows.count < 1000 {
                        let code = sqlite3_step(stmt)
                        if code == SQLITE_DONE { break }
                        guard code == SQLITE_ROW else { throw AgentDatabaseCatalogError.sql(String(cString: sqlite3_errmsg(db))) }
                        var row: [String] = []
                        for column in 0..<sqlite3_column_count(stmt) {
                            let count = Int(sqlite3_column_bytes(stmt, column))
                            bytes += count + columns[Int(column)].utf8.count + 8
                            guard bytes <= 1_048_576 else { throw AgentDatabaseCatalogError.dataFileTooLarge }
                            if sqlite3_column_type(stmt, column) == SQLITE_BLOB, let value = sqlite3_column_blob(stmt, column) {
                                row.append(Data(bytes: value, count: count).map { String(format: "%02x", $0) }.joined())
                            } else if let value = sqlite3_column_text(stmt, column) {
                                row.append(String(decoding: UnsafeBufferPointer(start: value, count: count), as: UTF8.self))
                            } else { row.append("") }
                        }
                        rows.append(row)
                    }
                    let values = rows.map { row in Dictionary(uniqueKeysWithValues: columns.enumerated().map { ($0.element,row[$0.offset]) }) }
                    let json = try JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
                    guard json.count <= 1_048_576 else { throw AgentDatabaseCatalogError.dataFileTooLarge }
                    return .init(columns: columns, rows: rows, json: String(decoding: json, as: UTF8.self))
                }
            }
        }
    }
    private static func backup(_ source: URL, to target: URL) throws {
        try connection(source, writable: false) { sourceDB in
            try connection(target, writable: true) { targetDB in
                guard let backup = sqlite3_backup_init(targetDB, "main", sourceDB, "main") else { throw AgentDatabaseCatalogError.databaseUnavailable }
                let result = sqlite3_backup_step(backup, -1)
                let finished = sqlite3_backup_finish(backup)
                guard result == SQLITE_DONE, finished == SQLITE_OK else { throw AgentDatabaseCatalogError.databaseUnavailable }
                try run(targetDB, "PRAGMA journal_mode=DELETE")
            }
        }
    }
    public static func snapshot(id: String, in root: URL) throws -> ManagedDatabaseSnapshot {
        try locked(root) {
            guard let row = try catalog(root).first(where: { $0.id == id }) else { throw AgentDatabaseCatalogError.databaseUnavailable }
            let temp = root.appendingPathComponent(".snapshot-" + UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at: temp) }
            try backup(try file(id, root), to: temp)
            let size = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= maximumSQLiteSnapshotBytes else { throw AgentDatabaseCatalogError.dataFileTooLarge }
            return .init(database: row, sqliteBase64: try Data(contentsOf: temp).base64EncodedString())
        }
    }
    @discardableResult
    public static func importSnapshot(_ snapshot: ManagedDatabaseSnapshot, in root: URL, sourceOwner: String, copyName: String? = nil, destinationOwner: String? = nil) throws -> LocalAgentDatabase {
        try locked(root) {
            var rows = try catalog(root)
            let original = snapshot.database
            guard (copyName != nil || destinationOwner == nil), original.owner == sourceOwner, let data = Data(base64Encoded: snapshot.sqliteBase64), data.count <= maximumSQLiteSnapshotBytes,
                  data.starts(with: Data("SQLite format 3\0".utf8)) else { throw AgentDatabaseCatalogError.unsupportedManifest }
            if copyName == nil, let old = rows.first(where: { $0.id == original.id }) {
                guard old.owner == sourceOwner else { throw AgentDatabaseCatalogError.unsupportedManifest }
                if old.revision >= original.revision { return old }
            }
            let id = copyName == nil ? original.id : UUID().uuidString.lowercased()
            let target = try file(id, root), temp = root.appendingPathComponent(".incoming-" + UUID().uuidString + ".sqlite")
            defer { try? FileManager.default.removeItem(at: temp) }
            try data.write(to: temp)
            try connection(temp, writable: true) { db in
                try run(db, "PRAGMA journal_mode=DELETE")
                var version: OpaquePointer?; defer { sqlite3_finalize(version) }
                guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &version, nil) == SQLITE_OK,
                      sqlite3_step(version) == SQLITE_ROW, sqlite3_column_int64(version, 0) == original.revision else { throw AgentDatabaseCatalogError.unsupportedManifest }
                if copyName != nil { try run(db, "PRAGMA user_version=1") }
                var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
                guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0), String(cString: text) == "ok" else { throw AgentDatabaseCatalogError.unsupportedManifest }
            }
            let name = (copyName ?? original.name).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 128, !name.contains("\0") else { throw AgentDatabaseCatalogError.invalidName }
            if copyName != nil, rows.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { throw AgentDatabaseCatalogError.databaseAlreadyExists }
            let row = LocalAgentDatabase(id: id, name: name, revision: copyName == nil ? original.revision : 1,
                updatedAt: copyName == nil ? original.updatedAt : ISO8601DateFormatter().string(from: Date()), owner: destinationOwner ?? sourceOwner, url: target)
            // The store lock excludes readers while atomically publishing the complete file and catalog.
            guard rename(temp.path, target.path) == 0 else { throw AgentDatabaseCatalogError.databaseUnavailable }
            rows.removeAll { $0.id == id }; rows.append(row); try save(rows, root); return row
        }
    }
}
