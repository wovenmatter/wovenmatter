import Foundation
import WovenMatterCore

/// Names people give execution workspaces, keyed by registry ID
/// (`ExecutionWorkspace.id`). Any Mac may name any workspace; the row is
/// shared, so the name reaches every paired device. A workspace's owner also
/// publishes the name as its registry row's `name`, which is what devices
/// that do not read this table show. No row means the default name.
extension WorkspaceDatabaseConnection {
  /// Declared for every library, new or existing: an existing one gains the
  /// table at its next open (`migratePeerSync`).
  static let executionWorkspaceNamesTableSQL = """
    CREATE TABLE IF NOT EXISTS execution_workspace_names(workspace_id TEXT PRIMARY KEY, name TEXT NOT NULL);

    """

  /// What a workspace name may be, as the registry accepts it: not blank, at
  /// most 256 bytes, no NUL. Rows arrive from other devices, so a reader
  /// applies it too.
  static func executionWorkspaceName(_ value: String?) -> String? {
    guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
          name.utf8.count <= 256, !name.contains("\0") else { return nil }
    return name
  }

  func setExecutionWorkspaceNameUnlocked(workspaceID: String, name: String?) throws {
    let id = workspaceID.lowercased()
    guard federationID(id) else { throw federationError("invalid_workspace", "This workspace cannot be renamed.") }
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if trimmed.isEmpty {
      try toolsExecuteUnlocked("DELETE FROM execution_workspace_names WHERE workspace_id=?", [id])
      return
    }
    guard let clean = Self.executionWorkspaceName(trimmed) else {
      throw federationError("invalid_name", "Choose a shorter workspace name.")
    }
    // An unchanged name writes nothing, so it records no new version to send.
    try toolsExecuteUnlocked("""
      INSERT INTO execution_workspace_names(workspace_id,name) VALUES(?,?)
      ON CONFLICT(workspace_id) DO UPDATE SET name=excluded.name WHERE name IS NOT excluded.name
      """, [id, clean])
  }

  func executionWorkspaceNamesUnlocked() throws -> [String: String] {
    var names: [String: String] = [:]
    for row in try historyRowsUnlocked("SELECT workspace_id,name FROM execution_workspace_names", values: []) {
      guard let id = row.objectValue?["workspace_id"]?.stringValue, federationID(id),
            let name = Self.executionWorkspaceName(row.objectValue?["name"]?.stringValue) else { continue }
      names[id] = name
    }
    return names
  }
}

extension WorkspaceDatabase {
  /// nil or blank removes the name, which returns the workspace to its
  /// default. Trimmed; at most 256 bytes; no NUL.
  public func setExecutionWorkspaceName(workspaceID: String, name: String?) async throws {
    try await write { connection in
      try connection.transaction { try connection.setExecutionWorkspaceNameUnlocked(workspaceID: workspaceID, name: name) }
    }
  }

  /// Every chosen name by registry ID.
  public func executionWorkspaceNames() async throws -> [String: String] {
    try await read { try $0.executionWorkspaceNamesUnlocked() }
  }
}
