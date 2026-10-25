import Foundation
import WovenMatterCompanion

extension WorkspaceDatabaseConnection {
  func saveDictation(_ record: DictationRecord) throws {
    try record.validate()
    try transaction {
      if let existing = try historyRowsUnlocked("SELECT payload_json FROM dictation_history WHERE id = ?", values: [record.id]).first?.objectValue?["payload_json"]?.stringValue {
        guard try JSONDecoder().decode(DictationRecord.self, from: Data(existing.utf8)) == record else { throw DictationHistoryError.identityConflict }
        return
      }
      let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
      try toolsExecuteUnlocked("INSERT INTO dictation_history(id, created_at, payload_json) VALUES (?, ?, ?)",
        [record.id, String(record.createdAt.timeIntervalSince1970), json])
    }
  }
  func dictationHistory(limit: Int, offset: Int) throws -> [DictationRecord] {
    try historyRowsUnlocked("SELECT payload_json FROM dictation_history ORDER BY created_at DESC, id DESC LIMIT ? OFFSET ?",
      values: [String(max(1, limit)), String(max(0, offset))]).map { row in
        guard let json = row.objectValue?["payload_json"]?.stringValue else { throw WorkspaceDatabaseError.corruptRow }
        return try JSONDecoder().decode(DictationRecord.self, from: Data(json.utf8))
      }
  }
  func dictationChanges(after cursor: Int64) throws -> DictationHistoryPage {
    guard cursor >= 0 else { throw DictationHistoryError.invalidPage }
    // Bound both rows and bytes so a long dictation never creates an oversized response.
    let rows = try historyRowsUnlocked("SELECT CAST(sequence AS TEXT) AS sequence, payload_json FROM dictation_history WHERE sequence > ? ORDER BY dictation_history.sequence LIMIT 101", values: [String(cursor)])
    var records: [DictationRecord] = [], next = cursor, bytes = 0
    for row in rows.prefix(100) {
      guard let fields = row.objectValue, let json = fields["payload_json"]?.stringValue,
        let sequence = fields["sequence"]?.stringValue.flatMap(Int64.init) else { throw WorkspaceDatabaseError.corruptRow }
      if !records.isEmpty && bytes + json.utf8.count > 2_097_152 { break }
      records.append(try JSONDecoder().decode(DictationRecord.self, from: Data(json.utf8)))
      next = sequence; bytes += json.utf8.count
    }
    return try .init(workspaceID: companionWorkspaceIDUnlocked(), cursor: next, records: records, hasMore: rows.count > records.count)
  }
}
extension WorkspaceDatabase {
  public func saveDictation(_ record: DictationRecord) async throws { try await write { try $0.saveDictation(record) } }
  public func dictationHistory(limit: Int = 100, offset: Int = 0) async throws -> [DictationRecord] { try await read { try $0.dictationHistory(limit: limit, offset: offset) } }
  public func dictationChanges(after cursor: Int64) async throws -> DictationHistoryPage { try await read { try $0.dictationChanges(after: cursor) } }
}
