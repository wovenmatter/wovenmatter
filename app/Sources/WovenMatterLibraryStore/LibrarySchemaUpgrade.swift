import Foundation
import WovenMatterCore

/// One change to what a library the previous release wrote holds.
///
/// `applies` says whether the library still holds the earlier shape. It runs
/// on every open, so it only looks things up: a table or column in the
/// schema, or a row through an index. `convert` makes the change inside the
/// conversion's one transaction and leaves nothing `applies` would find, so
/// it happens once and is nothing on a current library. The earlier names
/// appear in the conversion alone: everything that reads or writes the
/// library knows only the current shape.
struct LibraryConversion: Sendable {
  /// What it changes, for the log.
  let name: String
  let applies: @Sendable (WorkspaceDatabaseConnection) throws -> Bool
  let convert: @Sendable (WorkspaceDatabaseConnection) throws -> Void
}

/// How a library reaches the current shape. The library has no schema
/// version: nothing writes a number or a marker into the file and nothing
/// reads one.
///
/// A new library is created by the declarations in each `migrate*`
/// (`CREATE ... IF NOT EXISTS`). The same declarations add a new table,
/// index or trigger to an existing library at its next open, so adding one
/// needs nothing here.
///
/// A change to what a library already holds is a `LibraryConversion` in
/// `libraryConversions`. The library the previous release left on a device
/// is converted in place the first time this build opens it; nothing is kept
/// for a library older than that, and every device updates together.
///
/// To change what a library already holds:
/// 1. Change the declaration a new library is created from.
/// 2. Add a conversion that recognises the earlier shape cheaply and makes
///    the same change to an existing library, leaving nothing to recognise.
///    For a value in rows, declare an index it can be found through.
/// 3. Give `LibrarySchemaUpgradeTests` a library of the earlier shape: it must
///    end with exactly the schema of a new one, and opening it again must
///    change and copy nothing.
/// 4. Remove the conversion in the release after every device has taken it.
///
/// For a table peers share (`PairedLibraryTables`), a conversion that
/// changes rows also changes every recorded version of them the same way
/// (`peer_sync_versions`), so each device that converts the same library
/// agrees and nothing is sent as a new version.
extension WorkspaceDatabaseConnection {
  static let libraryConversions: [LibraryConversion] = [
    .init(name: "leftover device tables", applies: { try $0.holdsLeftoverDeviceTablesUnlocked() },
          convert: { try $0.adoptLeftoverDeviceTablesUnlocked() }),
    .init(name: "earlier table declarations", applies: { try $0.holdsEarlierDeclarationsUnlocked() },
          convert: { try $0.rebuildEarlierDeclarationsUnlocked() }),
    .init(name: "earlier record format names", applies: { try $0.holdsEarlierRecordFormatsUnlocked() },
          convert: { try $0.renameEarlierRecordFormatsUnlocked() }),
  ]

  /// Converts what the previous release left in this library, on open and
  /// before anything else creates schema. A library with nothing to convert
  /// is not touched and not copied.
  ///
  /// The library is copied first. The conversions then run in one
  /// transaction with foreign keys off, each one checked again in its turn
  /// (an earlier one may bring in what a later one converts), so a failure
  /// leaves the library exactly as it was. Every trigger of the library's
  /// own tables is dropped first: tables are rebuilt and rows are moved
  /// without recording them as new work for peers or devices, and the
  /// regular schema creation that follows recreates each trigger.
  func convertEarlierLibraryUnlocked(file: URL) throws {
    guard try Self.libraryConversions.contains(where: { try $0.applies(self) }) else { return }
    let reporter = LibraryUpgradeReporter(file: file)
    upgradeReporter = reporter
    backUpLibraryUnlocked(file)
    reporter.reach(.converting, 0, next: 0.3)
    // A rebuilt table takes its place by name: the references other tables
    // hold to it stay as they are written.
    try executeUnlocked("PRAGMA foreign_keys=OFF; PRAGMA legacy_alter_table=ON")
    defer { try? executeUnlocked("PRAGMA legacy_alter_table=OFF; PRAGMA foreign_keys=ON") }
    try transaction {
      for trigger in try historyRowsUnlocked("""
        SELECT name FROM sqlite_master WHERE type='trigger' AND \(Self.libraryOwnTable("tbl_name"))
        """, values: []).compactMap({ $0.objectValue?["name"]?.stringValue }) {
        try executeUnlocked("DROP TRIGGER \(Self.peerQuote(trigger))")
      }
      let count = Double(Self.libraryConversions.count)
      for (index, conversion) in Self.libraryConversions.enumerated() {
        guard try conversion.applies(self) else { continue }
        try conversion.convert(self)
        reporter.reach(.converting, 0.3 * Double(index + 1) / count, next: 0.3, after: conversion.name)
      }
    }
  }

  /// Whether the table `column` names is the library's own. The built-in
  /// agent keeps its store in the same file under `wm_pi_`; the library
  /// neither converts nor drops anything of it.
  static func libraryOwnTable(_ column: String) -> String {
    "\(column) NOT LIKE 'wm\\_pi\\_%' ESCAPE '\\' AND \(column) NOT LIKE 'sqlite\\_%' ESCAPE '\\'"
  }

  /// The names of the library's tables.
  func libraryTableNamesUnlocked() throws -> Set<String> {
    Set(try historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='table'", values: [])
      .compactMap { $0.objectValue?["name"]?.stringValue })
  }

  /// The names of a table's columns, in their physical order.
  func libraryColumnNamesUnlocked(_ table: String) throws -> [String] {
    try historyRowsUnlocked("SELECT name FROM pragma_table_info(?) ORDER BY cid", values: [table])
      .compactMap { $0.objectValue?["name"]?.stringValue }
  }

  // MARK: The copy made before a conversion

  /// Where the copy made before a library is converted is kept, beside the library.
  static func libraryBackupDirectory(for file: URL) -> URL {
    file.deletingLastPathComponent().appending(path: "Library Backups", directoryHint: .isDirectory)
  }
  /// How long such a copy is kept.
  static let libraryBackupRetention: TimeInterval = 30 * 24 * 60 * 60

  /// Copies the library as it is before the conversion changes it
  /// (`Library Backups/before-library-conversion-<time>.sqlite`: each
  /// conversion makes its own copy, so one that runs again, as after the
  /// previous release wrote to the library in between, never passes for
  /// the copy of the first). When the library folds completely into its
  /// main file, that file is copied while a read transaction here keeps any
  /// other connection from checkpointing into it; on a Mac that copy is a
  /// clone that takes no time or space until the conversion changes the
  /// original. When another connection keeps it from folding, SQLite's own
  /// backup copies it page by page instead. A copy that cannot be made (a
  /// full disk on a Linux host) does not stop the conversion, which is one
  /// transaction and leaves the library as it was if it fails. Copies older
  /// than `libraryBackupRetention` are removed on a later open.
  private func backUpLibraryUnlocked(_ file: URL) {
    let directory = Self.libraryBackupDirectory(for: file)
    let copy = directory.appending(path: Self.libraryBackupName(at: Date()))
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      let partial = directory.appending(path: copy.lastPathComponent + ".partial")
      for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: partial.path + suffix) }
      try? FileManager.default.removeItem(at: copy)
      let folded = try historyRowsUnlocked("PRAGMA wal_checkpoint(TRUNCATE)", values: []).first?.objectValue?["busy"]?.intValue == 0
      if folded {
        // The read transaction pins this connection to the main file as it
        // is now: nothing can move later writing into it during the copy.
        try executeUnlocked("BEGIN")
        defer { try? executeUnlocked("COMMIT") }
        _ = try historyRowsUnlocked("SELECT count(*) AS count FROM sqlite_master", values: [])
        try FileManager.default.copyItem(at: file, to: partial)
      } else {
        try copyLibraryUnlocked(to: partial)
      }
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partial.path)
      try FileManager.default.moveItem(at: partial, to: copy)
    } catch {
      NSLog("The library was not copied before its conversion: %@", error.localizedDescription)
    }
  }

  /// The name of a copy made at `time`, to the second (UTC).
  static func libraryBackupName(at time: Date) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = "yyyyMMdd-HHmmss"
    return "before-library-conversion-\(format.string(from: time)).sqlite"
  }

  /// Removes copies made before earlier conversions once they are old enough.
  static func removeExpiredLibraryBackups(for file: URL, now: Date = Date()) {
    let directory = libraryBackupDirectory(for: file)
    guard let copies = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    for copy in copies where copy.lastPathComponent.hasPrefix("before-library-") {
      guard let written = try? copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
            now.timeIntervalSince(written) > libraryBackupRetention else { continue }
      try? FileManager.default.removeItem(at: copy)
    }
  }

  /// Returns the pages deletions freed to the file system once they are
  /// worth it: a quarter of the file and at least 32 MiB. A library gives
  /// them back without a VACUUM (`auto_vacuum` INCREMENTAL, set when it is
  /// created), which never renumbers a row.
  func reclaimFreeSpaceUnlocked() throws {
    func number(_ pragma: String) throws -> Int {
      try historyRowsUnlocked("PRAGMA \(pragma)", values: []).first?.objectValue?[pragma]?.intValue ?? 0
    }
    let free = try number("freelist_count"), pages = try number("page_count"), size = try number("page_size")
    guard free * size >= 32 * 1_024 * 1_024, free * 4 >= pages else { return }
    try executeUnlocked("PRAGMA incremental_vacuum")
  }

  // MARK: What conversions share

  /// The statement that declares `table` in `sql`, the text a new library
  /// is created from (`CREATE TABLE IF NOT EXISTS name (...)`).
  static func tableDeclaration(_ table: String, in sql: String) -> String? {
    guard let head = sql.range(of: "CREATE TABLE IF NOT EXISTS \(NSRegularExpression.escapedPattern(for: table))\\s*\\(",
                               options: .regularExpression) else { return nil }
    var depth = 0, quoted = false, index = sql.index(before: head.upperBound)
    while index < sql.endIndex {
      let character = sql[index]
      if character == "'" { quoted.toggle() }
      else if !quoted, character == "(" { depth += 1 }
      else if !quoted, character == ")" {
        depth -= 1
        if depth == 0 { return String(sql[head.lowerBound...index]) }
      }
      index = sql.index(after: index)
    }
    return nil
  }

  /// Replaces a table with one made from its current declaration in `sql`,
  /// keeping every row and rowid in the columns both have. The earlier
  /// table steps aside under another name and is dropped with its indexes;
  /// the regular schema creation that follows recreates the current ones.
  /// The new table is created by the declaration exactly as a new library
  /// creates it.
  func rebuildTableUnlocked(_ table: String, from sql: String) throws {
    guard let declaration = Self.tableDeclaration(table, in: sql) else {
      throw WorkspaceDatabaseError.execute("No current declaration for \(table)")
    }
    let earlier = Self.peerQuote(table + "_earlier"), name = Self.peerQuote(table)
    try executeUnlocked("DROP TABLE IF EXISTS \(earlier);\nALTER TABLE \(name) RENAME TO \(earlier);\n\(declaration);")
    let held = Set(try libraryColumnNamesUnlocked(table + "_earlier"))
    let columns = try libraryColumnNamesUnlocked(table).filter(held.contains).map(Self.peerQuote).joined(separator: ",")
    try executeUnlocked("""
      INSERT INTO \(name)(rowid,\(columns)) SELECT rowid,\(columns) FROM \(earlier);
      DROP TABLE \(earlier);
      """)
  }

  /// A column's value as a recorded version carries it (`capturePayload`).
  static func peerRecordedValue(_ value: String) -> String {
    "json_object('type',typeof(\(value)),'value',CASE typeof(\(value)) WHEN 'blob' THEN hex(\(value)) WHEN 'real' THEN printf('%!.17g',\(value)) ELSE CAST(\(value) AS TEXT) || '' END)"
  }

  /// Records what the rows of `table` that `ids` name (by `key`, the
  /// table's identity) now hold in `columns`, in each version of them this
  /// device has applied. Each device that converts the same library changes
  /// the same rows the same way, so the change is not sent as a new version.
  func recordConvertedValuesUnlocked(_ table: String, key: String = "id", columns: [String], ids: [String]) throws {
    guard !ids.isEmpty, !columns.isEmpty, try libraryTableNamesUnlocked().contains("peer_sync_versions") else { return }
    let row = "FROM \(Self.peerQuote(table)) s WHERE s.\(Self.peerQuote(key))=json_extract(peer_sync_versions.record_key,'$[0]')"
    let values = columns.map { "'$.row.\($0)',json((SELECT \(Self.peerRecordedValue("s." + Self.peerQuote($0))) \(row)))" }
      .joined(separator: ",")
    for batch in stride(from: 0, to: ids.count, by: 500).map({ Array(ids[$0..<min($0 + 500, ids.count)]) }) {
      try toolsExecuteUnlocked("""
        UPDATE peer_sync_versions SET payload=json_set(payload,\(values))
        WHERE table_name=?1 AND record_key IN (SELECT json_array(value) FROM json_each(?2))
          AND pending_peer IS NULL AND json_valid(payload) AND EXISTS(SELECT 1 \(row))
        """, [table, String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)])
    }
  }
}
