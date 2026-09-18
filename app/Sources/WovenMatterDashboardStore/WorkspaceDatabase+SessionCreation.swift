import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  public func reserveToolSessionCreation(sourceID: String, requestID: String, arguments: [String], purpose: String, managed: Bool) throws -> GatewayJSONValue {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      guard UUID(uuidString: requestID) != nil else { throw WorkspaceToolError.invalid("A creation request needs a UUID.") }
      let encoded = try toolsJSON(arguments)
      if let value = try historyRowsUnlocked("SELECT * FROM workspace_session_creations WHERE id=?", values: [requestID]).first,
         let row = value.objectValue {
        guard row["source_id"]?.stringValue == sourceID, row["arguments_json"]?.stringValue == encoded else {
          throw WorkspaceToolError.invalid("Session creation request ID collision.")
        }
        return value
      }
      if managed {
        let limit = try toolSettingsUnlocked().maximumManagedSessions
        guard try managedSessionCountUnlocked(sourceID) < limit else { throw WorkspaceToolError.managedLimit(limit) }
      }
      let target = UUID().uuidString.lowercased()
      try toolsExecuteUnlocked("INSERT INTO workspace_session_creations(id,source_id,target_id,arguments_json,purpose,managed) VALUES(?,?,?,?,?,?)",
        [requestID, sourceID, target, encoded, purpose, managed ? "1" : "0"])
      return .object(["id": .string(requestID), "source_id": .string(sourceID), "target_id": .string(target), "status": .string("planned")])
    }
  }

  public func finishToolSessionCreation(requestID: String, status: String) throws {
    guard ["ready", "failed"].contains(status) else { throw WorkspaceToolError.invalid("Invalid creation status.") }
    try transaction { try toolsExecuteUnlocked("UPDATE workspace_session_creations SET status=? WHERE id=?", [status, requestID]) }
  }

  /// Session insertion and creation provenance commit together, so an interrupted
  /// remote setup cannot leave an apparently user-created conversation behind.
  func adoptReservedSessionOriginUnlocked(_ targetID: String) throws {
    guard let row = try historyRowsUnlocked("SELECT source_id,purpose FROM workspace_session_creations WHERE target_id=?", values: [targetID]).first?.objectValue,
          let source = row["source_id"]?.stringValue else { return }
    try toolsExecuteUnlocked("INSERT INTO workspace_session_relationships(session_id,created_by,purpose) VALUES(?,?,?)",
      [targetID, source, row["purpose"]?.stringValue])
    try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=(SELECT enabled_json FROM workspace_session_tools WHERE session_id=?) WHERE session_id=?", [source, targetID])
  }
}
