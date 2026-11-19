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

/// What the previous release left in every library it opened, whatever else
/// the library held:
/// - A number under a top-level key of every note document. A document has
///   no such member, and one that carries it cannot be edited. It is removed
///   from each note, each kept version of a note, and each recorded version
///   of those rows (`peer_sync_*`), applied, waiting, in conflict or set
///   aside, by `EarlierNoteContent.removingVersionMember`: the phone removes
///   it from its own copies with the same function, so every device ends
///   with the same bytes.
/// - The search entry of each native history record (`history_events`,
///   `native.federated.record`), which names the table the record is kept in
///   and its format. Entries written before those were renamed still give
///   the earlier names. They take the names this build writes, and the
///   search index, which holds no text of its own, has each entry's earlier
///   text removed and its new text added.
/// - A table for moving a chat to another machine, which nothing does any
///   more, and four indexes for looking a request up whatever its case,
///   which nothing does either. They are dropped, with what peer bookkeeping
///   names the table.
///
/// It is recognised by that table or one of those indexes: the previous
/// release declared them in every library it opened and this build declares
/// neither, so one lookup in the schema says whether this library has been
/// converted, and nothing is read from a note or from history on a later
/// open. The table and indexes are dropped last, in the same transaction as
/// everything else, so the conversion is whole or not at all.
///
/// A note's revision (`device_sync_revisions`) counts changes and is not
/// changed: every device converts its own copy. A draft receipt
/// (`device_draft_receipts`) holds a digest of what was submitted, not the
/// document, so it is left as it is; a draft submitted before the update and
/// repeated after it is answered as a conflict, and draft recovery keeps it.
extension WorkspaceDatabaseConnection {
  /// What the previous release declared and this build does not.
  private static let removedTable = "execution_adoptions"
  private static let removedIndexes = ["tool_mutations_request_case", "session_deliveries_request_case",
                                       "session_creations_request_case", "coordination_access_requests_request_case"]
  /// Where the earliest search entries say a native record is kept.
  private static let earlierNativeRecordStorage = "companion_native_history"

  func holdsPreviousReleaseDeclarationsUnlocked() throws -> Bool {
    try !historyRowsUnlocked("""
      SELECT 1 AS earlier FROM sqlite_master WHERE (type='table' AND name='\(Self.removedTable)')
        OR (type='index' AND name IN (\(Self.removedIndexes.map { "'\($0)'" }.joined(separator: ",")))) LIMIT 1
      """, values: []).isEmpty
  }

  func convertPreviousReleaseContentUnlocked() throws {
    try removeNoteVersionMembersUnlocked()
    try renameEarlierRecordManifestsUnlocked()
    // Last: these are what the conversion is recognised by.
    let tables = try libraryTableNamesUnlocked()
    for index in Self.removedIndexes { try executeUnlocked("DROP INDEX IF EXISTS \(Self.peerQuote(index))") }
    try executeUnlocked("DROP TABLE IF EXISTS \(Self.peerQuote(Self.removedTable))")
    for name in ["peer_sync_versions", "peer_sync_conflicts", "peer_sync_quarantine", "peer_sync_seeded", "peer_sync_reassert"]
    where tables.contains(name) {
      try toolsExecuteUnlocked("DELETE FROM \(name) WHERE table_name=?", [Self.removedTable])
    }
  }

  // MARK: Note documents

  /// Tables whose `content` is a note document, and whether a row counts
  /// its bytes (`bytes`: the title's and the content's).
  private static let noteDocumentTables: [(name: String, countsBytes: Bool)] = [("notes", false), ("note_asset_versions", true)]

  private func removeNoteVersionMembersUnlocked() throws {
    let tables = try libraryTableNamesUnlocked()
    for table in Self.noteDocumentTables where tables.contains(table.name) {
      // One document at a time: a note can be megabytes.
      let rows = try historyRowsUnlocked("SELECT rowid AS row FROM \(table.name)", values: []).compactMap { $0.objectValue?["row"]?.intValue }
      let read = try prepareUnlocked("SELECT content FROM \(table.name) WHERE rowid=?")
      let write = try prepareUnlocked(table.countsBytes
        ? "UPDATE \(table.name) SET content=?1,bytes=bytes-?2 WHERE rowid=?3" : "UPDATE \(table.name) SET content=?1 WHERE rowid=?3")
      defer { sqlite3_finalize(read); sqlite3_finalize(write) }
      for row in rows {
        sqlite3_reset(read); sqlite3_bind_int64(read, 1, Int64(row))
        guard sqlite3_step(read) == SQLITE_ROW else { continue }
        let content = try text(read, column: 0)
        sqlite3_reset(read)
        guard let converted = EarlierNoteContent.removingVersionMember(content) else { continue }
        sqlite3_reset(write)
        try bind(converted, at: 1, to: write)
        if table.countsBytes { sqlite3_bind_int64(write, 2, Int64(content.utf8.count - converted.utf8.count)) }
        sqlite3_bind_int64(write, 3, Int64(row))
        try stepDone(write)
      }
    }

    // Each recorded version of those rows carries the document it had, which
    // may differ from the row's: a version that lost a conflict, or waits.
    let records = libraryFiles.supportDirectory.appending(path: "paired-records")
    let names = Self.noteDocumentTables.map { "'\($0.name)'" }.joined(separator: ",")
    for name in ["peer_sync_versions", "peer_sync_conflicts", "peer_sync_quarantine"] where tables.contains(name) {
      let rows = try historyRowsUnlocked("SELECT rowid AS row FROM \(name) WHERE table_name IN (\(names))", values: [])
        .compactMap { $0.objectValue?["row"]?.intValue }
      let read = try prepareUnlocked("SELECT payload FROM \(name) WHERE rowid=?")
      defer { sqlite3_finalize(read) }
      for row in rows {
        sqlite3_reset(read); sqlite3_bind_int64(read, 1, Int64(row))
        guard sqlite3_step(read) == SQLITE_ROW else { continue }
        let stored = try text(read, column: 0)
        sqlite3_reset(read)
        guard let record = try? JSONDecoder().decode(PairedLibraryRecord.self, from: Data(stored.utf8)),
              let value = record.row["content"], let held = value.value else { continue }
        // A large value travels as a peer record file named by its digest.
        let content: String
        switch value.type {
        case "text": content = held
        case "reference:text":
          guard held.wholeMatch(of: /[0-9a-f]{64}/) != nil,
                let file = try? String(contentsOf: records.appending(path: held), encoding: .utf8) else { continue }
          content = file
        default: continue
        }
        guard let converted = EarlierNoteContent.removingVersionMember(content) else { continue }
        var document = PairedLibraryValue(type: "text", value: converted)
        if value.type == "reference:text" {
          let bytes = Data(converted.utf8), hash = SHA256.hash(data: bytes).hexString, file = records.appending(path: hash)
          if !FileManager.default.fileExists(atPath: file.path) {
            try bytes.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
          }
          document = .init(type: "reference:text", value: hash)
        }
        try toolsExecuteUnlocked("""
          UPDATE \(name) SET payload=json_set(payload,'$.row.content',json_object('type',?1,'value',?2)) WHERE rowid=?3
          """, [document.type, document.value, String(row)])
        if let counted = record.row["bytes"], counted.type == "integer", let count = counted.value.flatMap(Int.init) {
          try toolsExecuteUnlocked("UPDATE \(name) SET payload=json_set(payload,'$.row.bytes.value',?1) WHERE rowid=?2",
                                   [String(count - (content.utf8.count - converted.utf8.count)), String(row)])
        }
      }
    }
  }

  // MARK: Search entries of native records

  /// Gives each native record's search entry the table name and format
  /// name this build writes, in the row, in the search index and in each
  /// recorded version of the row. Entries are found through the index on
  /// their IDs, which all begin `federation:`.
  func renameEarlierRecordManifestsUnlocked() throws {
    let tables = try libraryTableNamesUnlocked()
    guard tables.isSuperset(of: ["history_events", "history_search"]) else { return }
    func renamed(_ manifest: String) -> String {
// Text, not JSON to embed: `|| ''` drops what marks a JSON function's result.
      "json_replace(\(manifest),'$.storage','\(Self.nativeRecordStorage)','$.format',\(Self.currentRecordFormatSQL("json_extract(\(manifest),'$.format')")))||''"
    }
    func earlier(_ manifest: String) -> String {
      """
      json_valid(\(manifest)) AND (json_extract(\(manifest),'$.storage')='\(Self.earlierNativeRecordStorage)'
        OR json_extract(\(manifest),'$.format') IN (\(Self.earlierRecordFormatList)))
      """
    }
    let entries = try historyRowsUnlocked("""
      SELECT sequence,id FROM history_events
      WHERE id>='federation:' AND id<'federation;' AND kind='\(Self.nativeRecordManifestKind)' AND \(earlier("payload"))
      """, values: []).compactMap(\.objectValue)
    var changed: [String] = []
    for entry in entries {
      guard let sequence = entry["sequence"]?.intValue, let id = entry["id"]?.stringValue else { continue }
      // The index removes an entry only when given exactly the text it was
      // added with, which is the row's as the insert trigger composed it.
      try toolsExecuteUnlocked("""
        INSERT INTO history_search(history_search,rowid,payload)
        SELECT 'delete',sequence,\(Self.historySearchText("history_events")) FROM history_events WHERE sequence=?
        """, [String(sequence)])
      try toolsExecuteUnlocked("UPDATE history_events SET payload=\(renamed("payload")) WHERE sequence=?", [String(sequence)])
      try toolsExecuteUnlocked("""
        INSERT INTO history_search(rowid,payload)
        SELECT sequence,\(Self.historySearchText("history_events")) FROM history_events WHERE sequence=?
        """, [String(sequence)])
      changed.append(id)
    }
    // An entry is small, so a recorded version always carries its text.
    let manifest = "json_extract(payload,'$.row.payload.value')"
    for name in ["peer_sync_versions", "peer_sync_conflicts", "peer_sync_quarantine"] where tables.contains(name) {
      for batch in stride(from: 0, to: changed.count, by: 500).map({ Array(changed[$0..<min($0 + 500, changed.count)]) }) {
        try toolsExecuteUnlocked("""
          UPDATE \(name) SET payload=json_set(payload,'$.row.payload.value',\(renamed(manifest)))
          WHERE table_name='history_events' AND record_key IN (SELECT json_array(value) FROM json_each(?1))
            AND json_valid(payload) AND json_type(payload,'$.row.payload.value')='text' AND \(earlier(manifest))
          """, [String(decoding: try JSONEncoder().encode(batch), as: UTF8.self)])
      }
    }
  }
}
