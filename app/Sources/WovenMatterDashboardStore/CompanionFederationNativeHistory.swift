import CryptoKit
import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  func archiveCompanionNativeRecordUnlocked(_ part: CompanionNativeRecordPart, entry: CompanionJournalEntry) throws {
    guard !part.recordID.isEmpty, part.recordID.utf8.count <= 256, !part.format.isEmpty, part.format.utf8.count <= 120,
          part.partCount > 0, part.partCount <= 65_536, part.partIndex >= 0, part.partIndex < part.partCount,
          part.byteCount >= 0, part.byteCount <= 512 * 1_024 * 1_024,
          part.data.count <= 512 * 1_024, Int64(part.data.count) <= part.byteCount,
          (part.byteCount == 0 ? part.partCount == 1 && part.data.isEmpty : !part.data.isEmpty && Int64(part.partCount) <= part.byteCount),
          part.sha256.count == 64,
          part.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      throw federationError("invalid_record", "Native history records require bounded parts and a complete-record digest.")
    }
    let lookup = try prepareUnlocked("SELECT conversation_id,run_id,format,part_count,byte_count,sha256 FROM companion_native_history WHERE workspace_id=? AND record_id=?")
    defer { sqlite3_finalize(lookup) }
    try bind(entry.workspaceID, at: 1, to: lookup); try bind(part.recordID, at: 2, to: lookup)
    let code = sqlite3_step(lookup)
    if code == SQLITE_ROW {
      guard try text(lookup, column: 0) == entry.conversationID, optionalText(lookup, column: 1) == entry.runID,
            try text(lookup, column: 2) == part.format, sqlite3_column_int(lookup, 3) == part.partCount,
            sqlite3_column_int64(lookup, 4) == part.byteCount, try text(lookup, column: 5) == part.sha256 else {
        throw federationError("record_conflict", "An existing native history record cannot change its manifest.")
      }
    } else {
      guard code == SQLITE_DONE else { throw stepError() }
      let insert = try prepareUnlocked("INSERT INTO companion_native_history(workspace_id,record_id,conversation_id,run_id,format,part_count,byte_count,sha256) VALUES (?,?,?,?,?,?,?,?)")
      defer { sqlite3_finalize(insert) }
      try bind(entry.workspaceID, at: 1, to: insert); try bind(part.recordID, at: 2, to: insert)
      try bind(entry.conversationID, at: 3, to: insert); try bindNullable(entry.runID, at: 4, to: insert)
      try bind(part.format, at: 5, to: insert); sqlite3_bind_int(insert, 6, Int32(part.partCount))
      sqlite3_bind_int64(insert, 7, part.byteCount); try bind(part.sha256, at: 8, to: insert); try stepDone(insert)
    }
    let previous = try prepareUnlocked("SELECT bytes FROM companion_native_history_parts WHERE workspace_id=? AND record_id=? AND part_index=?")
    defer { sqlite3_finalize(previous) }
    try bind(entry.workspaceID, at: 1, to: previous); try bind(part.recordID, at: 2, to: previous); sqlite3_bind_int(previous, 3, Int32(part.partIndex))
    let previousCode = sqlite3_step(previous)
    if previousCode == SQLITE_ROW {
      guard try blob(previous, column: 0) == part.data else { throw federationError("record_conflict", "A native history part cannot change its content.") }
      return
    }
    guard previousCode == SQLITE_DONE else { throw stepError() }
    let storedBytes = try federationScalarUnlocked("SELECT COALESCE(SUM(length(bytes)),0) FROM companion_native_history_parts WHERE workspace_id=? AND record_id=?", bindings: [entry.workspaceID, part.recordID])
    guard storedBytes <= part.byteCount - Int64(part.data.count) else {
      throw federationError("invalid_record", "Native history parts exceed the declared record size.")
    }
    let insert = try prepareUnlocked("INSERT INTO companion_native_history_parts VALUES (?,?,?,?)")
    defer { sqlite3_finalize(insert) }
    try bind(entry.workspaceID, at: 1, to: insert); try bind(part.recordID, at: 2, to: insert)
    sqlite3_bind_int(insert, 3, Int32(part.partIndex)); try bind(part.data, at: 4, to: insert); try stepDone(insert)
    let count = try federationScalarUnlocked("SELECT COUNT(*) FROM companion_native_history_parts WHERE workspace_id=? AND record_id=?", bindings: [entry.workspaceID, part.recordID])
    guard count == part.partCount else { return }
    let chunks = try prepareUnlocked("SELECT part_index,bytes FROM companion_native_history_parts WHERE workspace_id=? AND record_id=? ORDER BY part_index")
    defer { sqlite3_finalize(chunks) }
    try bind(entry.workspaceID, at: 1, to: chunks); try bind(part.recordID, at: 2, to: chunks)
    var hash = SHA256(); var index = 0; var size: Int64 = 0; var searchBytes = Data()
    while true {
      let code = sqlite3_step(chunks)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW, sqlite3_column_int(chunks, 0) == index else { throw WorkspaceDatabaseError.corruptRow }
      let bytes = try blob(chunks, column: 1); size += Int64(bytes.count); hash.update(data: bytes); index += 1
      if searchBytes.count < 256 * 1_024 { searchBytes.append(bytes.prefix(256 * 1_024 - searchBytes.count)) }
    }
    guard size == part.byteCount, hash.finalize().map({ String(format: "%02x", $0) }).joined() == part.sha256 else {
      throw federationError("record_digest", "Native history record integrity failed. The source must retain its unacknowledged history.")
    }
    try companionExecuteUnlocked("UPDATE companion_native_history SET complete=1 WHERE workspace_id=? AND record_id=?", values: [entry.workspaceID, part.recordID])
    // The canonical searchable archive points at the complete chunked record.
    // Only its search excerpt is bounded; retrieval uses the verified manifest.
    let manifest: [String: String] = ["workspaceID": entry.workspaceID, "recordID": part.recordID, "format": part.format,
      "partCount": String(part.partCount), "byteCount": String(part.byteCount), "sha256": part.sha256, "storage": "companion_native_history"]
    let payload = String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)
    let runtime = try federationConversationUnlocked(entry.conversationID)?.runtimeKind ?? "unknown"
    try recordHistoryUnlocked(.init(id: "federation:" + entry.workspaceID + ":" + part.recordID,
      conversationID: entry.conversationID, runID: entry.runID, harness: runtime, kind: "native.federated.record",
      payload: payload, completeness: "complete", nativeSessionID: entry.conversationID, sourceConnectionID: entry.workspaceID,
      sourceID: "federation:" + entry.workspaceID, nativeRecordID: part.recordID, nativeRevisionID: part.sha256,
      contentMode: "snapshot", textContent: String(decoding: searchBytes, as: UTF8.self)))
  }

  public func companionNativeHistoryPart(workspaceID: String, recordID: String, partIndex: Int) throws -> CompanionNativeRecordPart? {
    try withLock {
      let statement = try prepareUnlocked("SELECT n.format,n.part_count,n.byte_count,n.sha256,p.bytes FROM companion_native_history n JOIN companion_native_history_parts p ON p.workspace_id=n.workspace_id AND p.record_id=n.record_id WHERE n.workspace_id=? AND n.record_id=? AND n.complete=1 AND p.part_index=?")
      defer { sqlite3_finalize(statement) }
      try bind(workspaceID, at: 1, to: statement); try bind(recordID, at: 2, to: statement); sqlite3_bind_int(statement, 3, Int32(clamping: partIndex))
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return nil }
      guard code == SQLITE_ROW else { throw stepError() }
      return try CompanionNativeRecordPart(recordID: recordID, format: text(statement, column: 0), partIndex: partIndex,
        partCount: Int(sqlite3_column_int(statement, 1)), byteCount: sqlite3_column_int64(statement, 2), sha256: text(statement, column: 3), data: blob(statement, column: 4))
    }
  }
}

extension WorkspaceDatabase {
  public func companionNativeHistoryPart(workspaceID: String, recordID: String, partIndex: Int) async throws -> CompanionNativeRecordPart? {
    try await read { try $0.companionNativeHistoryPart(workspaceID: workspaceID, recordID: recordID, partIndex: partIndex) }
  }
}
