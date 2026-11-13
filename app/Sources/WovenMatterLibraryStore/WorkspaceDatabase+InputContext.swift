import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabaseConnection {
  /// Every delivered input gets a capture, including an explicit empty capture.
  /// This table never follows the UI selection or a session's latest message.
  func captureInputContext(conversationID: String, noteID: String?) throws -> String {
    try transaction {
      try requireToolSessionUnlocked(conversationID)
      let id = UUID().uuidString.lowercased()
      let permitted = try sessionToolsUnlocked(conversationID).enabled.contains(.notes)
      try toolsExecuteUnlocked("INSERT INTO workspace_input_contexts(id,conversation_id,note_id,created_at) VALUES(?,?,?,?)",
        [id, conversationID, permitted ? noteID : nil, Self.timestamp(Date())])
      return id
    }
  }

  func inputContext(id: String?, callerID: String) throws -> String? {
    try withLock {
      try requireToolUnlocked(.notes, sessionID: callerID)
      guard let id, let row = try historyRowsUnlocked(
        "SELECT note_id FROM workspace_input_contexts WHERE id=? AND conversation_id=?",
        values: [id, callerID]).first else {
        throw WorkspaceToolError.invalid("The native harness has not supplied a context binding for this message.")
      }
      return row.objectValue?["note_id"]?.stringValue
    }
  }
}

extension WorkspaceDatabase {
  public func captureInputContext(conversationID: String, noteID: String?) async throws -> String {
    try await write { try $0.captureInputContext(conversationID: conversationID, noteID: noteID) }
  }

  public func inputContext(id: String?, callerID: String) async throws -> String? {
    try await read { try $0.inputContext(id: id, callerID: callerID) }
  }
}
