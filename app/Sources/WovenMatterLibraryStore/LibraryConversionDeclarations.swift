import Foundation
import WovenMatterCore

/// Tables the previous release left declared as an earlier one had created
/// them. Its own steps for these were tied to a number its libraries had
/// already passed, so they never ran:
/// - A source of agent-tool work (`source_id`, `created_by`,
///   `coordinator_id`) referenced `conversations`. It is any MCP caller
///   (`mcp_callers`): a conversation, the outside caller or a bot. The
///   caller registry held no conversation, though every conversation is a
///   caller.
/// - `session_timers` referenced `conversations` and had no `outside_mcp`.
///   A timer's target is a conversation or a bot, so it references neither.
/// - `harness_sessions` and `calendar_items` held a column added later
///   after the ones a new library declares it before.
///
/// Each is recognised by that shape and rebuilt from the declaration a new
/// library is created from, keeping its rows.
extension WorkspaceDatabaseConnection {
  /// Columns that name an MCP caller, by table.
  private static let callerColumns: [(table: String, columns: [String])] = [
    ("tool_mutations", ["source_id"]), ("automation_requests", ["source_id"]), ("automation_cancellations", ["source_id"]),
    ("session_grants", ["source_id"]), ("session_relationships", ["created_by", "coordinator_id"]),
    ("coordination_access_requests", ["source_id"]), ("session_creations", ["source_id"]),
  ]

  /// Each table with the text that declares it now and an SQL condition
  /// that holds while the library has its earlier declaration. A condition
  /// reads only the table's columns and foreign keys, and is false for a
  /// table the library does not have.
  private static let earlierDeclarations: [(table: String, sql: String, earlier: String)] = {
    func column(_ table: String, _ name: String) -> String { "(SELECT cid FROM pragma_table_info('\(table)') WHERE name='\(name)')" }
    var result = callerColumns.map { entry in
      (entry.table, agentToolsSQL, """
        EXISTS(SELECT 1 FROM pragma_foreign_key_list('\(entry.table)') WHERE "table"='conversations'
          AND "from" IN (\(entry.columns.map { "'\($0)'" }.joined(separator: ","))))
        """)
    }
    result.append(("session_timers", agentToolsSQL, """
      EXISTS(SELECT 1 FROM pragma_foreign_key_list('session_timers'))
        OR (\(column("session_timers", "id")) IS NOT NULL AND \(column("session_timers", "outside_mcp")) IS NULL)
      """))
    result.append(("harness_sessions", coreTablesSQL, "\(column("harness_sessions", "permission"))>\(column("harness_sessions", "remote_workspace_id"))"))
    result.append(("calendar_items", coreTablesSQL, "\(column("calendar_items", "calendar_json"))>\(column("calendar_items", "created_at"))"))
    return result
  }()

  func holdsEarlierDeclarationsUnlocked() throws -> Bool {
    try !historyRowsUnlocked("SELECT 1 AS earlier WHERE " + Self.earlierDeclarations.map { "(\($0.earlier))" }.joined(separator: " OR "),
                             values: []).isEmpty
  }

  func rebuildEarlierDeclarationsUnlocked() throws {
    let earlier = try Self.earlierDeclarations.filter {
      try !historyRowsUnlocked("SELECT 1 AS earlier WHERE \($0.earlier)", values: []).isEmpty
    }
    let tables = try libraryTableNamesUnlocked()
    // Every conversation is an MCP caller; the trigger that says so only
    // covers conversations made since the registry was created.
    if tables.isSuperset(of: ["mcp_callers", "conversations"]) {
      try executeUnlocked("INSERT OR IGNORE INTO mcp_callers(id) SELECT id FROM conversations")
    }
    for entry in earlier {
      try rebuildTableUnlocked(entry.table, from: entry.sql)
      // The rows it kept satisfy what the table now references.
      let broken = try historyRowsUnlocked("PRAGMA foreign_key_check(\(Self.peerQuote(entry.table)))", values: []).count
      guard broken == 0 else {
        throw WorkspaceDatabaseError.execute("\(broken) row(s) of \(entry.table) reference a row the library does not have.")
      }
    }
  }
}
