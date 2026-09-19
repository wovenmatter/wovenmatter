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
        if row["status"]?.stringValue == "failed" {
          if managed {
            let limit = try toolSettingsUnlocked().maximumManagedSessions
            guard try managedSessionCountUnlocked(sourceID, excluding: row["target_id"]?.stringValue) < limit else { throw WorkspaceToolError.managedLimit(limit) }
          }
          try toolsExecuteUnlocked("UPDATE workspace_session_creations SET status='planned' WHERE id=?", [requestID])
        }
        return try historyRowsUnlocked("SELECT * FROM workspace_session_creations WHERE id=?", values: [requestID]).first ?? value
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

  /// Failed setup releases its reservation slot while preserving the target ID
  /// for a safe retry. An already completed creation is never downgraded by a
  /// later failure to deliver its first message.
  public func failToolSessionCreation(requestID: String) throws {
    try transaction {
      try toolsExecuteUnlocked("UPDATE workspace_session_creations SET status='failed' WHERE id=? AND status='planned'", [requestID])
    }
  }

  public func recoverToolSessionCreations() throws {
    try transaction { try executeUnlocked("UPDATE workspace_session_creations SET status='failed' WHERE status='planned'") }
  }

  public func completeToolSessionCreation(requestID: String, sourceID: String) throws {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      guard let row = try historyRowsUnlocked("SELECT * FROM workspace_session_creations WHERE id=? AND source_id=?", values: [requestID, sourceID]).first?.objectValue,
            let target = row["target_id"]?.stringValue else { throw WorkspaceToolError.invalid("Creation reservation not found.") }
      if row["status"]?.stringValue == "ready" { return }
      try requireToolSessionUnlocked(target)
      if row["managed"]?.intValue == 1 {
        try validateCoordinationUnlocked(sourceID: sourceID, targetID: target)
        try beginCoordinationUnlocked(sourceID: sourceID, targetID: target, purpose: row["purpose"]?.stringValue ?? "", notifications: true)
      }
      try toolsExecuteUnlocked("UPDATE workspace_session_creations SET status='ready' WHERE id=?", [requestID])
    }
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
