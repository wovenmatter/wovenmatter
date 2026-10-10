import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Trusted central-host migration, never an HTTP peer claim. Ownership is
  /// fenced durably before remote enrollment; failure must retry this same
  /// adoption rather than falling back to the legacy native attachment.
  public func prepareCompanionExecutionAdoption(conversationID: String, workspaceID: String, deviceID: String) throws -> CompanionExecutionAdoption {
    try transaction {
      let identity = try companionLibraryIdentityUnlocked()
      guard deviceID == identity.hostDeviceID,
            let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted,
            workspace.kind == .linux, workspace.ownerDeviceID == identity.hostDeviceID else {
        throw federationError("wrong_owner", "Only the central host may transfer one of its configured remote sessions.")
      }
      if let saved = try federationValuesUnlocked("SELECT payload FROM companion_execution_adoptions WHERE conversation_id=?", bindings: [conversationID], as: CompanionExecutionAdoption.self).first {
        guard saved.workspaceID == workspaceID,
              try companionIDsUnlocked("SELECT workspace_id FROM companion_execution_conversations WHERE id=?", bindings: [conversationID]).first == workspaceID else {
          throw federationError("wrong_owner", "This conversation was transferred to another execution workspace.")
        }
        // Retry the immutable original transfer even after the new owner has
        // started another run. Enrollment itself is idempotent at that owner.
        return saved
      }
      let session = try prepareUnlocked("SELECT runtime_kind,acp_session_id,model,thinking,permission FROM desktop_local_acp_sessions WHERE conversation_id=? AND remote_workspace_id=?")
      defer { sqlite3_finalize(session) }
      try bind(conversationID, at: 1, to: session); try bind(workspaceID, at: 2, to: session)
      guard sqlite3_step(session) == SQLITE_ROW, let nativeID = optionalText(session, column: 1), !nativeID.isEmpty,
            var conversation = try companionConversationUnlocked(id: conversationID) else {
        throw federationError("adoption_unavailable", "This conversation has no known native session in the selected remote workspace.")
      }
      guard try federationScalarUnlocked("SELECT COUNT(*) FROM dashboard_runs WHERE conversation_id=? AND status IN ('running','queued','pending','cancelling','uncertain')", bindings: [conversationID]) == 0 else {
        throw federationError("execution_busy", "Wait for the current run to settle before transferring this conversation's execution control.")
      }
      if let existing = try federationConversationUnlocked(conversationID) {
        guard existing.workspaceID == workspaceID else { throw federationError("wrong_owner", "This conversation already belongs to another execution workspace.") }
        conversation = existing
      } else {
        conversation.workspaceID = workspaceID; conversation.libraryID = identity.libraryID
        let statement = try prepareUnlocked("INSERT INTO companion_execution_conversations(id,workspace_id,conversation,transcript) VALUES (?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(conversationID, at: 1, to: statement); try bind(workspaceID, at: 2, to: statement)
        try bind(JSONEncoder().encode(conversation), at: 3, to: statement)
        try bind(JSONEncoder().encode(federationLegacyTranscriptUnlocked(conversationID)), at: 4, to: statement)
        try stepDone(statement)
        for runID in try companionIDsUnlocked("SELECT id FROM dashboard_runs WHERE conversation_id=?", bindings: [conversationID]) {
          try companionExecuteUnlocked("INSERT INTO companion_execution_runs(id,workspace_id,conversation_id) VALUES (?,?,?)", values: [runID, workspaceID, conversationID])
        }
        // Notify every client that control now belongs to the independent origin.
        try companionExecuteUnlocked("UPDATE dashboard_conversations SET updated_at=? WHERE id=?", values: [Self.timestamp(Date()), conversationID])
      }
      let adoption = try CompanionExecutionAdoption(workspaceID: workspaceID, conversation: conversation,
        runtimeKind: text(session, column: 0), nativeSessionID: nativeID, model: optionalText(session, column: 2),
        thinking: optionalText(session, column: 3), permission: optionalText(session, column: 4),
        knownRunIDs: companionIDsUnlocked("SELECT id FROM dashboard_runs WHERE conversation_id=? ORDER BY created_at,id", bindings: [conversationID]))
      let saved = try prepareUnlocked("INSERT INTO companion_execution_adoptions(conversation_id,workspace_id,payload) VALUES (?,?,?)")
      defer { sqlite3_finalize(saved) }
      try bind(conversationID, at: 1, to: saved); try bind(workspaceID, at: 2, to: saved)
      try bind(JSONEncoder().encode(adoption), at: 3, to: saved); try stepDone(saved)
      return adoption
    }
  }

  private func federationLegacyTranscriptUnlocked(_ conversationID: String) throws -> CompanionTranscript {
    let statement = try prepareUnlocked("SELECT id,run_id,role,content,status,created_at FROM dashboard_messages WHERE conversation_id=? ORDER BY created_at,id")
    defer { sqlite3_finalize(statement) }
    try bind(conversationID, at: 1, to: statement)
    var transcript = CompanionTranscript(conversationID: conversationID)
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      transcript.messages.append(try CompanionMessage(id: text(statement, column: 0), conversationID: conversationID,
        runID: optionalText(statement, column: 1), role: text(statement, column: 2), content: text(statement, column: 3),
        status: optionalText(statement, column: 4), createdAt: text(statement, column: 5)))
    }
    let events = try prepareUnlocked("SELECT id,run_id,content FROM dashboard_run_events WHERE conversation_id=? ORDER BY created_at,id")
    defer { sqlite3_finalize(events) }
    try bind(conversationID, at: 1, to: events)
    while true {
      let code = sqlite3_step(events)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let raw = try text(events, column: 2)
      let activity = try? JSONDecoder().decode(AgentRunActivity.self, from: Data(raw.utf8))
      transcript.activities.append(try CompanionActivity(id: text(events, column: 0), runID: text(events, column: 1),
        title: activity?.title ?? activity?.kind.rawValue ?? "Activity", detail: activity?.detail ?? activity?.content ?? raw,
        status: activity?.status ?? "completed"))
    }
    return transcript
  }
}

extension WorkspaceDatabase {
  public func prepareCompanionExecutionAdoption(conversationID: String, workspaceID: String, deviceID: String) async throws -> CompanionExecutionAdoption {
    try await write { try $0.prepareCompanionExecutionAdoption(conversationID: conversationID, workspaceID: workspaceID, deviceID: deviceID) }
  }
}
