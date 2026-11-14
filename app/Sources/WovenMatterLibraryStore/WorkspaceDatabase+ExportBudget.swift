import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Table/predicate come only from the fixed export queries below. SQLite counts
  /// blob bytes before Swift allocates payload strings; the reader snapshot keeps
  /// this preflight and the subsequent export at the same revision.
  func consumeExportRows(table: String, predicate: String, values: [String?],
    budget: inout WorkspaceExportBudget) throws {
    func quoted(_ identifier: String) -> String { "\"" + identifier.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    let schema = try prepareUnlocked("SELECT * FROM \(quoted(table)) LIMIT 0")
    let columns = (0..<sqlite3_column_count(schema)).map { quoted(String(cString: sqlite3_column_name(schema, $0))) }
    sqlite3_finalize(schema)
    let sizes = columns.map { "COALESCE(length(CAST(\($0) AS BLOB)), 0)" }.joined(separator: ", ")
    let statement = try prepareUnlocked("SELECT \(sizes) FROM \(quoted(table)) WHERE \(predicate) LIMIT \(budget.remainingItems + 1)")
    defer { sqlite3_finalize(statement) }
    for (index, value) in values.enumerated() { try bindNullable(value, at: Int32(index + 1), to: statement) }
    while true {
      let status = sqlite3_step(statement)
      if status == SQLITE_DONE { return }
      guard status == SQLITE_ROW else { throw stepError() }
      // Include per-field encoding/object overhead even for empty rows.
      try budget.consume(bytes: columns.count * 32, items: 1)
      for column in 0..<sqlite3_column_count(statement) {
        try budget.consume(bytes: Int(sqlite3_column_int64(statement, column)))
      }
    }
  }

  func checkConversationExportBudget(id: String, format: WorkspaceConversationExportFormat,
    budget: inout WorkspaceExportBudget) throws {
    try consumeExportRows(table: "conversations", predicate: "id = ?", values: [id], budget: &budget)
    for table in ["messages", "runs"] {
      try consumeExportRows(table: table, predicate: "conversation_id = ?", values: [id], budget: &budget)
    }
    for table in ["message_attachments", "message_references", "session_deliveries"] {
      try consumeExportRows(table: table, predicate: "message_id IN (SELECT id FROM messages WHERE conversation_id = ?)",
        values: [id], budget: &budget)
    }
    if format == .fullRun {
      for table in ["history_events", "run_activities"] {
        try consumeExportRows(table: table, predicate: "conversation_id = ? OR run_id IN (SELECT id FROM runs WHERE conversation_id = ?)",
          values: [id, id], budget: &budget)
      }
    }
  }
}
