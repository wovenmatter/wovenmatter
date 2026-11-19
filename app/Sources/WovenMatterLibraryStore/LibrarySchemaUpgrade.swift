import Foundation
import WovenMatterCore

/// One change to what a library the previous release wrote holds.
///
/// `applies` says whether the library still holds the earlier shape. It runs
/// on every open, so it only looks things up: a table or column in the
/// schema, or a row through an index. `convert` makes the change inside one
/// transaction and leaves nothing `applies` would find, so it happens once
/// and is nothing on a current library. The earlier names appear in the
/// conversion alone: everything that reads or writes the library knows only
/// the current shape.
struct LibraryConversion: Sendable {
  enum Kind: Sendable {
    /// Gives what the library holds the shape this build would have written
    /// it in, before anything else creates schema and with no trigger in
    /// place. It is for a change every device makes to the same content in
    /// the same way: rows peers share and each recorded version of them
    /// (`peer_sync_*`) are changed alike, so the devices agree afterwards
    /// and nothing is sent as a new version.
    case inPlace
    /// Writes rows as the app writes them, once the schema is current and
    /// every trigger exists. It is for content one device may hold and
    /// another may not: each row it writes is recorded as this device's new
    /// version and reaches peers, the device change feed and everything
    /// else that follows a write.
    case asWrites
  }
  /// What it changes, for the log.
  let name: String
  let kind: Kind
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
/// is converted the first time this build opens it; nothing is kept for a
/// library older than that, and every device updates together.
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
/// A conversion never refuses a library for what its rows hold: a row that
/// already references something the library lacks is carried over as it is.
extension WorkspaceDatabaseConnection {
  static let libraryConversions: [LibraryConversion] = [
    .init(name: "earlier table declarations", kind: .inPlace, applies: { try $0.holdsEarlierDeclarationsUnlocked() },
          convert: { try $0.rebuildEarlierDeclarationsUnlocked() }),
    .init(name: "earlier record format names", kind: .inPlace, applies: { try $0.holdsEarlierRecordFormatsUnlocked() },
          convert: { try $0.renameEarlierRecordFormatsUnlocked() }),
    .init(name: "what the previous release wrote and declared", kind: .inPlace, applies: { try $0.holdsPreviousReleaseDeclarationsUnlocked() },
          convert: { try $0.convertPreviousReleaseContentUnlocked() }),
    .init(name: "leftover device tables", kind: .asWrites, applies: { try $0.holdsLeftoverDeviceTablesUnlocked() },
          convert: { try $0.adoptLeftoverDeviceTablesUnlocked() }),
  ]

  /// Converts in place what the previous release left in this library, on
  /// open and before anything else creates schema. A library with nothing
  /// to convert is not touched and not copied.
  ///
  /// The library is copied first, whichever conversion applies. The
  /// conversions made in place then run in one transaction with foreign
  /// keys off, each one checked again in its turn, so a failure leaves the
  /// library exactly as it was. Every trigger of the library's own tables
  /// is dropped first, and the regular schema creation that follows
  /// recreates each one. The conversions made as writes follow that
  /// creation (`finishLibraryConversionUnlocked`).
  ///
  /// A conversion in place that fails stops the open, because this build
  /// reads and writes only the current shape. The error names the
  /// conversion; the library is unchanged, and the next open tries again
  /// with the copy it already has.
  func convertEarlierLibraryUnlocked(file: URL) throws {
    guard try Self.libraryConversions.contains(where: { try $0.applies(self) }) else { return }
    let reporter = LibraryUpgradeReporter(file: file)
    upgradeReporter = reporter
    backUpLibraryUnlocked(file)
    reporter.reach(.converting, 0, next: 0.3)
    let inPlace = Self.libraryConversions.filter { $0.kind == .inPlace }
    guard try inPlace.contains(where: { try $0.applies(self) }) else { return }
    // A rebuilt table takes its place by name: the references other tables
    // hold to it stay as they are written.
    try executeUnlocked("PRAGMA foreign_keys=OFF; PRAGMA legacy_alter_table=ON")
    defer { try? executeUnlocked("PRAGMA legacy_alter_table=OFF; PRAGMA foreign_keys=ON") }
    var running = ""
    do {
      try transaction {
        for trigger in try historyRowsUnlocked("""
          SELECT name FROM sqlite_master WHERE type='trigger' AND \(Self.libraryOwnTable("tbl_name"))
          """, values: []).compactMap({ $0.objectValue?["name"]?.stringValue }) {
          try executeUnlocked("DROP TRIGGER \(Self.peerQuote(trigger))")
        }
        for (index, conversion) in inPlace.enumerated() {
          running = conversion.name
          guard try conversion.applies(self) else { continue }
          try conversion.convert(self)
          reporter.reach(.converting, 0.3 * Double(index + 1) / Double(inPlace.count), next: 0.3, after: conversion.name)
        }
      }
    } catch {
      throw WorkspaceDatabaseError.open("""
        This library could not be converted for this version of Woven Matter (\(running): \(Self.conversionFailure(error))). \
        Nothing in it was changed, and a copy of it is kept in \(Self.libraryBackupDirectory(for: file).lastPathComponent).
        """)
    }
  }

  /// Runs the conversions made as writes, once the schema is current and
  /// every trigger exists, in one transaction, and names the copy made
  /// before the conversion as finished when nothing is left to convert.
  ///
  /// One that fails leaves the library open and usable: it is already in
  /// the current shape, and what was not converted stays where nothing
  /// reads it. The failure is logged, and the next open tries again with
  /// the copy it already has.
  func finishLibraryConversionUnlocked(file: URL) {
    do {
      let writes = try Self.libraryConversions.filter { try $0.kind == .asWrites && $0.applies(self) }
      if !writes.isEmpty {
        try transaction {
          for conversion in writes {
            try conversion.convert(self)
            upgradeReporter?.reach(.converting, 0.98, after: conversion.name)
          }
        }
      }
      guard upgradeReporter != nil, try !Self.libraryConversions.contains(where: { try $0.applies(self) }) else { return }
      Self.finishLibraryBackups(for: file)
    } catch {
      NSLog("The library's conversion is not finished and will be tried again: %@", Self.conversionFailure(error))
    }
  }

  private static func conversionFailure(_ error: any Error) -> String {
    switch error {
    case WorkspaceDatabaseError.open(let message), WorkspaceDatabaseError.execute(let message), WorkspaceDatabaseError.prepare(let message),
         WorkspaceDatabaseError.bind(let message), WorkspaceDatabaseError.step(let message): message
    default: error.localizedDescription
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
  /// (`Library Backups/before-library-conversion-<time>.sqlite`). The copy
  /// is named `….unfinished.sqlite` until the conversion it was made for
  /// has finished (`finishLibraryBackups`): a conversion that failed or was
  /// interrupted finds that copy at the next open and makes no other, so a
  /// conversion that keeps failing keeps one copy, the library as it was
  /// before the first attempt.
  ///
  /// When the library folds completely into its main file and nothing is
  /// written before this connection's read transaction has begun, that
  /// file is the whole library and no other connection can checkpoint into
  /// it during the transaction; it is copied as a file, which on a Mac is a
  /// clone that takes no time or space until the conversion changes the
  /// original. Otherwise SQLite's own backup copies the library page by
  /// page. A copy that cannot be made (a full disk on a Linux host) leaves
  /// nothing behind and does not stop the conversion, which leaves the
  /// library as it was if it fails. Copies older than
  /// `libraryBackupRetention` are removed on a later open.
  private func backUpLibraryUnlocked(_ file: URL) {
    let directory = Self.libraryBackupDirectory(for: file)
    guard Self.unfinishedLibraryBackup(in: directory) == nil else { return }
    Self.writeLibraryBackup(named: Self.libraryBackupName(at: Date(), finished: false), in: directory) { partial in
      var copied = false
      if try historyRowsUnlocked("PRAGMA wal_checkpoint(TRUNCATE)", values: []).first?.objectValue?["busy"]?.intValue == 0 {
        try executeUnlocked("BEGIN")
        defer { try? executeUnlocked("COMMIT") }
        _ = try historyRowsUnlocked("SELECT count(*) AS count FROM sqlite_master", values: [])
        // A log that is empty now was empty when the transaction began:
        // this connection reads the main file itself, which holds every
        // other connection's checkpoint off that file until the copy is made.
        let log = (try? FileManager.default.attributesOfItem(atPath: file.path + "-wal")[.size] as? NSNumber)?.int64Value ?? 0
        if log == 0 {
          try FileManager.default.copyItem(at: file, to: partial)
          copied = true
        }
      }
      if !copied { try copyLibraryUnlocked(to: partial) }
    }
  }

  /// Makes one copy named `name` in `directory` with `copy`, which writes
  /// it to the path it is given. The copy appears under its name only when
  /// it is whole, and is dated now whatever date the library's file has, so
  /// it is kept for `libraryBackupRetention` from the conversion. A copy
  /// that fails leaves nothing behind.
  @discardableResult
  static func writeLibraryBackup(named name: String, in directory: URL, copy: (URL) throws -> Void) -> URL? {
    let destination = directory.appending(path: name), partial = directory.appending(path: name + ".partial")
    func discard() { for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: partial.path + suffix) } }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
      discard()
      try copy(partial)
      try FileManager.default.setAttributes([.posixPermissions: 0o600, .modificationDate: Date()], ofItemAtPath: partial.path)
      try? FileManager.default.removeItem(at: destination)
      try FileManager.default.moveItem(at: partial, to: destination)
      discard()
      return destination
    } catch {
      discard()
      NSLog("The library was not copied before its conversion: %@", error.localizedDescription)
      return nil
    }
  }

  private static let unfinishedBackupSuffix = ".unfinished.sqlite"

  /// The name of a copy made at `time`, to the second (UTC), for a
  /// conversion that has finished or has not.
  static func libraryBackupName(at time: Date, finished: Bool = true) -> String {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(identifier: "UTC")
    format.dateFormat = "yyyyMMdd-HHmmss"
    return "before-library-conversion-\(format.string(from: time))" + (finished ? ".sqlite" : unfinishedBackupSuffix)
  }

  /// The copy an earlier attempt at the conversion made, while it is kept.
  static func unfinishedLibraryBackup(in directory: URL, now: Date = Date()) -> URL? {
    ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
      .filter { $0.lastPathComponent.hasPrefix("before-library-conversion-") && $0.lastPathComponent.hasSuffix(unfinishedBackupSuffix) }
      .filter { copy in
        (try? copy.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
          .map { now.timeIntervalSince($0) <= libraryBackupRetention } ?? false
      }
      .max { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// Names each copy made for the conversion that has now finished as a finished one.
  static func finishLibraryBackups(for file: URL) {
    let directory = libraryBackupDirectory(for: file)
    for copy in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    where copy.lastPathComponent.hasPrefix("before-library-conversion-") && copy.lastPathComponent.hasSuffix(unfinishedBackupSuffix) {
      let finished = directory.appending(path: String(copy.lastPathComponent.dropLast(unfinishedBackupSuffix.count)) + ".sqlite")
      try? FileManager.default.removeItem(at: finished)
      try? FileManager.default.moveItem(at: copy, to: finished)
    }
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
  /// device has applied. It is for a change made in place, which every
  /// device makes to the same rows in the same way.
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
