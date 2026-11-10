import Foundation

/// Sessions an agent on this device created on another member's workspace
/// (docs/architecture/WOVEN_EVERYWHERE.md, "Sessions across devices"), so its
/// later `woven_sessions_status`, `_send`, `_stop` and `_respond` calls name
/// them by ID alone. Like Linux's `member_sessions`, the table stays on this
/// device: it is not in the paired sync table set.
public struct MemberToolSession: Equatable, Sendable {
  public let id: String
  public let callerID: String
  public let workspaceID: String
  public let createdAt: String
}

extension WorkspaceDatabaseConnection {
  func migrateMemberToolSessions() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS member_tool_sessions(id TEXT PRIMARY KEY, caller_id TEXT NOT NULL, workspace_id TEXT NOT NULL, created_at TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS member_tool_sessions_caller ON member_tool_sessions(caller_id, created_at);
      """)
  }

  fileprivate func memberToolSessionsUnlocked(_ sql: String, _ values: [String?]) throws -> [MemberToolSession] {
    try historyRowsUnlocked(sql, values: values).compactMap { row in
      guard let fields = row.objectValue, let id = fields["id"]?.stringValue, let caller = fields["caller_id"]?.stringValue,
            let workspace = fields["workspace_id"]?.stringValue, let created = fields["created_at"]?.stringValue else { return nil }
      return MemberToolSession(id: id, callerID: caller, workspaceID: workspace, createdAt: created)
    }
  }
}

extension WorkspaceDatabase {
  /// Records that `callerID` created session `id` on `workspaceID`. A retry keeps the first record.
  public func rememberMemberToolSession(id: String, callerID: String, workspaceID: String) async throws {
    let now = WorkspaceDatabaseConnection.timestamp(Date())
    try await write { try $0.toolsExecuteUnlocked("INSERT OR IGNORE INTO member_tool_sessions VALUES(?,?,?,?)",
                                                  [id.lowercased(), callerID, workspaceID.lowercased(), now]) }
  }

  public func memberToolSession(id: String) async throws -> MemberToolSession? {
    try await read { try $0.memberToolSessionsUnlocked("SELECT * FROM member_tool_sessions WHERE id=?", [id.lowercased()]).first }
  }

  /// Every session `callerID` created on other workspaces, newest first.
  public func memberToolSessions(callerID: String) async throws -> [MemberToolSession] {
    try await read { try $0.memberToolSessionsUnlocked("SELECT * FROM member_tool_sessions WHERE caller_id=? ORDER BY created_at DESC, id", [callerID]) }
  }
}
