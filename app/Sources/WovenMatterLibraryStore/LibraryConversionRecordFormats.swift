#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

/// A native history record names its format (`execution_native_history.format`),
/// and so does each journal entry that carried a part of it
/// (`execution_journal.payload`, `nativeRecord.format`, under the entry's
/// `fingerprint`). The previous release wrote those names with a number.
/// Everything that reads a record compares its format with the current name
/// alone, so stored names are converted here, with each recorded version of
/// the rows (`peer_sync_*`), applied or waiting.
///
/// It is recognised by a record under an earlier name, found through
/// `execution_native_history_format`. A journal entry carries a format only
/// as part of a record, and the record's row is written in the same
/// transaction (`archiveLibraryNativeRecordUnlocked`) and never deleted, so
/// a library without such a record has no such entry. Rows a device that
/// has not converted sends afterwards bring a record under an earlier name
/// with them, and the next open converts them.
///
/// A record's own bytes are left as they are: its parts are files named by
/// their digests, and nothing inside them names a format. So is the text of
/// the history events native files were captured as
/// (`history_events.payload`): each is identified by a digest of that text,
/// and nothing reads a format out of it. A record's search entry does take
/// the current name (`renameEarlierRecordManifestsUnlocked`).
extension WorkspaceDatabaseConnection {
  /// A format's name as the previous release wrote it, and its name now.
  static let earlierRecordFormats: [(earlier: String, current: String)] = [
    ("wovenmatter.activity.v1", "wovenmatter.activity"),
    ("wovenmatter.activity.v2", "wovenmatter.activity.chained"),
    ("pi-durable.entry.v1", "pi-durable.entry"),
    ("woven-native-update-v1", "woven-native-update"),
    ("woven-native-file-manifest/v1", "woven-native-file-manifest"),
    ("woven-native-file-manifest/v2", "woven-native-file-manifest"),
    ("woven-native-file-chunk/v1", "woven-native-file-chunk"),
    ("woven-native-record-reference/v1", "woven-native-record-reference"),
    ("woven-native-text-fragment/v1", "woven-native-text-fragment"),
  ]

  /// The current name of a format, whichever name it is given by.
  static func currentRecordFormat(_ format: String) -> String {
    earlierRecordFormats.first { $0.earlier == format }?.current ?? format
  }

  /// SQL for the earlier names, and for the current name of the format `value` holds.
  static let earlierRecordFormatList = earlierRecordFormats.map { "'\($0.earlier)'" }.joined(separator: ",")
  static func currentRecordFormatSQL(_ value: String) -> String {
    "CASE \(value) " + earlierRecordFormats.map { "WHEN '\($0.earlier)' THEN '\($0.current)'" }.joined(separator: " ") + " ELSE \(value) END"
  }

  func holdsEarlierRecordFormatsUnlocked() throws -> Bool {
    guard try !historyRowsUnlocked("SELECT 1 AS present FROM sqlite_master WHERE type='table' AND name='execution_native_history'",
                                   values: []).isEmpty else { return false }
    return try !historyRowsUnlocked("SELECT 1 AS earlier FROM execution_native_history WHERE format IN (\(Self.earlierRecordFormatList)) LIMIT 1",
                                    values: []).isEmpty
  }

  func renameEarlierRecordFormatsUnlocked() throws {
    let tables = try libraryTableNamesUnlocked()
    try executeUnlocked("""
      UPDATE execution_native_history SET format=\(Self.currentRecordFormatSQL("format"))
      WHERE format IN (\(Self.earlierRecordFormatList))
      """)
    let recorded = ["peer_sync_versions", "peer_sync_conflicts", "peer_sync_quarantine"].filter(tables.contains)
    for name in recorded {
      let format = "json_extract(payload,'$.row.format.value')"
      try executeUnlocked("""
        UPDATE \(name) SET payload=json_set(payload,'$.row.format.value',\(Self.currentRecordFormatSQL(format)))
        WHERE table_name='execution_native_history' AND json_valid(payload) AND \(format) IN (\(Self.earlierRecordFormatList))
        """)
    }
    try renameEarlierRecordManifestsUnlocked()
    guard tables.contains("execution_journal") else { return }

    // Each journal entry of a record, as this build writes an entry: its
    // text and the fingerprint a repeated upload of it is compared with.
    var entries: [(cursor: Int64, eventID: String, payload: Data)] = []
    let read = try prepareUnlocked("""
      SELECT cursor,event_id,payload FROM execution_journal
      WHERE json_valid(payload) AND json_extract(payload,'$.nativeRecord.format') IN (\(Self.earlierRecordFormatList))
      """)
    defer { sqlite3_finalize(read) }
    while true {
      let code = sqlite3_step(read)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      entries.append((sqlite3_column_int64(read, 0), try text(read, column: 1), try blob(read, column: 2)))
    }
    let update = try prepareUnlocked("UPDATE execution_journal SET payload=?,fingerprint=? WHERE cursor=?")
    defer { sqlite3_finalize(update) }
    var changed: [String] = []
    for entry in entries {
      guard let converted = try journalEntryUnderCurrentFormat(entry.payload) else { continue }
      sqlite3_reset(update)
      try bind(converted.payload, at: 1, to: update); try bind(converted.fingerprint, at: 2, to: update)
      sqlite3_bind_int64(update, 3, entry.cursor)
      try stepDone(update)
      changed.append(entry.eventID)
    }
    try recordConvertedValuesUnlocked("execution_journal", key: "event_id", columns: ["payload", "fingerprint"], ids: changed)

    // Versions of entries that are not this device's applied rows: waiting
    // for their bytes or for an update, losing a conflict, or set aside.
    let records = libraryFiles.supportDirectory.appending(path: "paired-records")
    for name in recorded {
      let waiting = name == "peer_sync_versions" ? "AND pending_peer IS NOT NULL" : ""
      let rows = try historyRowsUnlocked("SELECT rowid AS id,payload FROM \(name) WHERE table_name='execution_journal' \(waiting)", values: [])
      for row in rows.compactMap(\.objectValue) {
        guard let id = row["id"]?.intValue, let stored = row["payload"]?.stringValue,
              let record = try? JSONDecoder().decode(PairedLibraryRecord.self, from: Data(stored.utf8)),
              let value = record.row["payload"], let held = value.value else { continue }
        // A large value travels as a peer record file named by its digest.
        let text: String
        switch value.type {
        case "text": text = held
        case "reference:text":
          guard held.wholeMatch(of: /[0-9a-f]{64}/) != nil,
                let file = try? String(contentsOf: records.appending(path: held), encoding: .utf8) else { continue }
          text = file
        default: continue
        }
        guard let converted = try journalEntryUnderCurrentFormat(Data(text.utf8)) else { continue }
        var payload = PairedLibraryValue(type: "text", value: converted.payload)
        if value.type == "reference:text" {
          let bytes = Data(converted.payload.utf8), hash = SHA256.hash(data: bytes).hexString, file = records.appending(path: hash)
          if !FileManager.default.fileExists(atPath: file.path) {
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
          }
          payload = .init(type: "reference:text", value: hash)
        }
        let fingerprint = converted.fingerprint.map { String(format: "%02X", $0) }.joined()
        try toolsExecuteUnlocked("""
          UPDATE \(name) SET payload=json_set(payload,'$.row.payload',json_object('type',?1,'value',?2),
            '$.row.fingerprint',json_object('type','blob','value',?3)) WHERE rowid=?4
          """, [payload.type, payload.value, fingerprint, String(id)])
      }
    }
  }

  /// A journal entry's text with its record's format under the current
  /// name, and the entry's fingerprint, or nil for an entry that carries no
  /// record under an earlier name or that this build cannot read.
  func journalEntryUnderCurrentFormat(_ payload: Data) throws -> (payload: String, fingerprint: Data)? {
    guard var entry = try? JSONDecoder().decode(ExecutionJournalEntry.self, from: payload), let format = entry.nativeRecord?.format,
          Self.currentRecordFormat(format) != format else { return nil }
    entry.nativeRecord?.format = Self.currentRecordFormat(format)
    return (try toolsJSON(entry), try libraryFingerprint(entry))
  }
}
