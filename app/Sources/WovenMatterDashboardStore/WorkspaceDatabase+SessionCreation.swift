import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  /// App launch routing reads the original resolved location, including after a
  /// restart or failed final coordination. It never derives a path from a title.
  public func toolSessionCreationConfiguration(targetID: String) throws -> WorkspaceSessionCreationConfiguration? {
    try withLock {
      guard let json = try historyRowsUnlocked("SELECT configuration_json FROM workspace_session_creations WHERE target_id=?",
        values: [targetID]).first?.objectValue?["configuration_json"]?.stringValue else { return nil }
      return try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(json.utf8))
    }
  }

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

  /// The first resolved configuration wins. Current source capabilities and
  /// General defaults cannot silently change the meaning of a retry.
  public func saveToolSessionCreationConfiguration(requestID: String, sourceID: String,
      configuration: WorkspaceSessionCreationConfiguration) throws -> WorkspaceSessionCreationConfiguration {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      guard let row = try historyRowsUnlocked("SELECT configuration_json,status FROM workspace_session_creations WHERE id=? AND source_id=?",
        values: [requestID, sourceID]).first?.objectValue else { throw WorkspaceToolError.invalid("Creation reservation not found.") }
      if let json = row["configuration_json"]?.stringValue {
        return try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(json.utf8))
      }
      guard row["status"]?.stringValue == "planned" else { throw WorkspaceToolError.invalid("This creation request is not being prepared.") }
      let title = configuration.title.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, title.utf8.count <= 4_096,
            configuration.nativeWorkingDirectory.map({ $0.hasPrefix("/") && !$0.contains("\0") && $0.utf8.count <= 4_096 }) ?? true,
            configuration.nativeWorkspaceID.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true else {
        throw WorkspaceToolError.invalid("A session needs a title and a valid working directory.")
      }
      let operatorID = try localMutationOperatorIDUnlocked()
      try validateFolderUnlocked(id: configuration.folderID, operatorID: operatorID)
      var saved = configuration
      saved.title = title
      saved.tools = try sessionToolsUnlocked(sourceID)
      try toolsExecuteUnlocked("UPDATE workspace_session_creations SET configuration_json=? WHERE id=?",
        [try toolsJSON(saved), requestID])
      return saved
    }
  }

  /// A later coordination failure must not cause a confirmed native selection
  /// to be applied again over a user's subsequent model choice on retry.
  public func markToolSessionCreationConfigured(requestID: String, sourceID: String) throws {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      guard let target = try historyRowsUnlocked("SELECT target_id FROM workspace_session_creations WHERE id=? AND source_id=? AND status='planned'",
        values: [requestID, sourceID]).first?.objectValue?["target_id"]?.stringValue else {
        throw WorkspaceToolError.invalid("This creation request is not being prepared.")
      }
      try requireToolSessionUnlocked(target)
      try toolsExecuteUnlocked("UPDATE workspace_session_creations SET configuration_applied=1 WHERE id=?", [requestID])
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
    guard let row = try historyRowsUnlocked("SELECT source_id,purpose,configuration_json FROM workspace_session_creations WHERE target_id=?", values: [targetID]).first?.objectValue,
          let source = row["source_id"]?.stringValue else { return }
    try requireToolUnlocked(.sessions, sessionID: source)
    try toolsExecuteUnlocked("INSERT INTO workspace_session_relationships(session_id,created_by,purpose) VALUES(?,?,?)",
      [targetID, source, row["purpose"]?.stringValue])
    if let json = row["configuration_json"]?.stringValue {
      let configuration = try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(json.utf8))
      try validateFolderUnlocked(id: configuration.folderID, operatorID: localMutationOperatorIDUnlocked())
      try toolsExecuteUnlocked("UPDATE dashboard_conversations SET title=?,folder_id=? WHERE id=?",
        [configuration.title, configuration.folderID, targetID])
      try toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET title=? WHERE conversation_id=?", [configuration.title, targetID])
      try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=? WHERE session_id=?", [try toolsJSON(configuration.tools.enabled), targetID])
    } else {
      // Reservations from older builds retain the existing inheritance behavior.
      try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=(SELECT enabled_json FROM workspace_session_tools WHERE session_id=?) WHERE session_id=?", [source, targetID])
    }
  }
}
