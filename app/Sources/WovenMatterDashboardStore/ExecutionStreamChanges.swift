import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

/// One pointer in the Mac's stream change source ("Mac change source" in
/// docs/architecture/WOVEN_EVERYWHERE.md). The server reads the current rows
/// when it sends; the pointer says only which entity of which conversation changed.
public struct ExecutionStreamChange: Equatable, Sendable {
  public enum EntityKind: String, Sendable { case conversation, message, run, runEvent = "run_event", activity, session }
  public let sequence: Int64
  public let conversationID: String
  public let entityKind: String
  public let entityID: String
}

public struct ExecutionStreamChangePage: Equatable, Sendable {
  public var changes: [ExecutionStreamChange]
  /// The newest sequence written, which `after` may reach.
  public var latest: Int64
  /// Entries after `after` were pruned: the reader must start from a snapshot.
  public var truncated: Bool
  /// More entries remain after this page.
  public var hasMore: Bool
}

extension WorkspaceDatabaseConnection {
  /// Tables whose rows make up a conversation this Mac runs, with the entity
  /// each row names. `desktop_local_acp_sessions` is what makes a conversation
  /// one this Mac runs, so its rows are conversation changes too. A session's
  /// goal and enabled tools are part of its settings (the `session` item).
  static let executionStreamTables: [(table: String, kind: ExecutionStreamChange.EntityKind, conversation: String, entity: String)] = [
    ("dashboard_conversations", .conversation, "id", "id"),
    ("desktop_local_acp_sessions", .conversation, "conversation_id", "conversation_id"),
    ("dashboard_messages", .message, "conversation_id", "id"),
    ("dashboard_runs", .run, "conversation_id", "id"),
    ("dashboard_run_events", .runEvent, "conversation_id", "id"),
    ("dashboard_run_trace_events", .activity, "conversation_id", "id"),
    ("workspace_session_goals", .session, "session_id", "session_id"),
    ("workspace_session_tools", .session, "session_id", "session_id"),
  ]

  /// Whether `conversation` (an SQL expression) is a conversation this Mac
  /// runs, as `MacExecutionAPI.isLocal` decides it: a local ACP session that
  /// is neither a remote-workspace nor a gateway session, and no execution
  /// record or paired owner naming another machine. History synchronized from
  /// another Mac, iPhone or Linux host always has one of those.
  static func executionStreamIsLocal(_ conversation: String, requireSession: Bool = true) -> String {
    var clauses = [
      "NOT EXISTS (SELECT 1 FROM execution_conversations f WHERE f.id = \(conversation) AND f.deleted = 0)",
      "NOT EXISTS (SELECT 1 FROM paired_conversation_owners o WHERE o.id = \(conversation) AND o.device_id <> COALESCE((SELECT host_device_id FROM library_identity WHERE singleton = 1), ''))",
      "NOT EXISTS (SELECT 1 FROM desktop_openclaw_gateway_sessions g WHERE g.conversation_id = \(conversation))",
    ]
    if requireSession {
      clauses.append("EXISTS (SELECT 1 FROM desktop_local_acp_sessions s WHERE s.conversation_id = \(conversation) AND s.remote_workspace_id IS NULL)")
    }
    return clauses.joined(separator: " AND ")
  }

  /// Creates `execution_stream_changes` and its triggers, or brings an
  /// existing database's triggers up to date. Runs after every table it names
  /// exists. Each trigger writes in the transaction of the row it observes.
  func migrateExecutionStreamChanges() throws {
    try transaction {
      try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS execution_stream_changes (
          sequence INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL,
          entity_kind TEXT NOT NULL, entity_id TEXT NOT NULL
        );
        """)
      for (table, kind, conversation, entity) in Self.executionStreamTables {
        let exists = try prepareUnlocked("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?")
        try bind(table, at: 1, to: exists)
        let present = sqlite3_step(exists) == SQLITE_ROW
        sqlite3_finalize(exists)
        guard present else { continue }
        for operation in ["INSERT", "UPDATE", "DELETE"] {
          let row = operation == "DELETE" ? "OLD" : "NEW"
          // A removed session row cannot be looked up any more; its own
          // remote workspace column still tells whether this Mac ran it.
          let local = table == "desktop_local_acp_sessions" && operation == "DELETE"
            ? "OLD.remote_workspace_id IS NULL AND " + Self.executionStreamIsLocal("OLD.conversation_id", requireSession: false)
            : Self.executionStreamIsLocal("\(row).\(conversation)")
          let name = "execution_stream_\(table)_\(operation.lowercased())"
          try executeUnlocked("""
            DROP TRIGGER IF EXISTS \(name);
            CREATE TRIGGER \(name) AFTER \(operation) ON \(table)
            WHEN \(local)
            BEGIN
              INSERT INTO execution_stream_changes(conversation_id, entity_kind, entity_id)
              VALUES (\(row).\(conversation), '\(kind.rawValue)', \(row).\(entity));
              DELETE FROM execution_stream_changes WHERE sequence <=
                (SELECT MAX(sequence) FROM execution_stream_changes) - \(StreamProtocol.maximumRetainedChanges);
            END;
            """)
        }
      }
    }
  }

  func executionStreamCursorUnlocked() throws -> Int64 {
    // sqlite_sequence keeps the high-water mark after pruning.
    let statement = try prepareUnlocked("SELECT COALESCE((SELECT seq FROM sqlite_sequence WHERE name = 'execution_stream_changes'), 0)")
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
    return sqlite3_column_int64(statement, 0)
  }

  func executionStreamChanges(after cursor: Int64, limit: Int) throws -> ExecutionStreamChangePage {
    try transaction {
      let latest = try executionStreamCursorUnlocked()
      let oldestStatement = try prepareUnlocked("SELECT COALESCE(MIN(sequence), 0) FROM execution_stream_changes")
      defer { sqlite3_finalize(oldestStatement) }
      guard sqlite3_step(oldestStatement) == SQLITE_ROW else { throw stepError() }
      let oldest = sqlite3_column_int64(oldestStatement, 0)
      // The sequence has no gaps, so any entry after `cursor` that is missing was pruned.
      let truncated = cursor < latest && (oldest == 0 || oldest > cursor + 1)
      guard !truncated else { return .init(changes: [], latest: latest, truncated: true, hasMore: false) }
      let statement = try prepareUnlocked("SELECT sequence, conversation_id, entity_kind, entity_id FROM execution_stream_changes WHERE sequence > ? ORDER BY sequence LIMIT ?")
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, cursor)
      sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, StreamProtocol.maximumRetainedChanges))))
      var changes: [ExecutionStreamChange] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW else { throw stepError() }
        changes.append(.init(sequence: sqlite3_column_int64(statement, 0), conversationID: try text(statement, column: 1),
                             entityKind: try text(statement, column: 2), entityID: try text(statement, column: 3)))
      }
      return .init(changes: changes, latest: latest, truncated: false, hasMore: (changes.last?.sequence ?? latest) < latest)
    }
  }
}

extension WorkspaceDatabase {
  /// The current library projection of each named conversation that exists
  /// and is neither deleted nor archived.
  public func libraryConversations(ids: Set<String>) async throws -> [String: LibraryConversation] {
    guard !ids.isEmpty else { return [:] }
    return try await read { connection in
      try connection.transaction {
        var values: [String: LibraryConversation] = [:]
        for id in ids { if let value = try connection.libraryConversationUnlocked(id: id) { values[id] = value } }
        return values
      }
    }
  }

  /// The newest sequence in `execution_stream_changes`.
  public func executionStreamCursor() async throws -> Int64 {
    try await read { connection in try connection.withLock { try connection.executionStreamCursorUnlocked() } }
  }

  /// Pointers after `cursor`, oldest first. `truncated` means the entries
  /// after `cursor` were pruned and the reader must start again from a snapshot.
  public func executionStreamChanges(after cursor: Int64, limit: Int = 1_000) async throws -> ExecutionStreamChangePage {
    try await read { try $0.executionStreamChanges(after: cursor, limit: limit) }
  }
}
