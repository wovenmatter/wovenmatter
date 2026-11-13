import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Trusted central-host migration, never an HTTP peer claim. Ownership is
  /// fenced durably before remote enrollment; failure must retry this same
  /// adoption rather than falling back to the legacy native attachment.
  public func prepareExecutionAdoption(conversationID: String, workspaceID: String, deviceID: String) throws -> ExecutionAdoption {
    try transaction {
      let identity = try libraryIdentityUnlocked()
      guard deviceID == identity.hostDeviceID,
            let workspace = try federationWorkspaceUnlocked(workspaceID), !workspace.deleted,
            workspace.kind == .linux, workspace.ownerDeviceID == identity.hostDeviceID else {
        throw federationError("wrong_owner", "Only the central host may transfer one of its configured remote sessions.")
      }
      if let saved = try federationValuesUnlocked("SELECT payload FROM execution_adoptions WHERE conversation_id=?", bindings: [conversationID], as: ExecutionAdoption.self).first {
        guard saved.workspaceID == workspaceID,
              try libraryIDsUnlocked("SELECT workspace_id FROM execution_conversations WHERE id=?", bindings: [conversationID]).first == workspaceID else {
          throw federationError("wrong_owner", "This conversation was transferred to another execution workspace.")
        }
        // Retry the immutable original transfer even after the new owner has
        // started another run. Enrollment itself is idempotent at that owner.
        var retried = saved
        retried.transcript = try adoptionTranscriptUnlocked(conversationID)
        return retried
      }
      guard let root = try sessionExecutionRoot(id: conversationID), root.workspaceID == "remote:" + workspaceID else {
        throw federationError("adoption_unavailable", "This archived conversation has no execution root. Start a new chat.")
      }
      let session = try prepareUnlocked("SELECT runtime_kind,native_session_id,model,thinking,permission FROM harness_sessions WHERE conversation_id=? AND remote_workspace_id=?")
      defer { sqlite3_finalize(session) }
      try bind(conversationID, at: 1, to: session); try bind(workspaceID, at: 2, to: session)
      // An OpenCode chat names its native session in its OpenCode link.
      let openCodeID = try libraryIDsUnlocked("SELECT session_id FROM opencode_sessions WHERE conversation_id=?", bindings: [conversationID]).first
      guard sqlite3_step(session) == SQLITE_ROW, let nativeID = optionalText(session, column: 1).flatMap({ $0.isEmpty ? nil : $0 })
              ?? (optionalText(session, column: 0) == AgentRuntimeKind.opencode.rawValue ? openCodeID : nil), !nativeID.isEmpty,
            var conversation = try libraryConversationUnlocked(id: conversationID) else {
        throw federationError("adoption_unavailable", "This conversation has no known native session in the selected remote workspace.")
      }
      guard try federationScalarUnlocked("SELECT COUNT(*) FROM runs WHERE conversation_id=? AND status IN ('running','queued','pending','cancelling','uncertain')", bindings: [conversationID]) == 0 else {
        throw federationError("execution_busy", "Wait for the current run to settle before transferring this conversation's execution control.")
      }
      var transferredGoal = try goalUnlocked(conversationID)
      if var goal = transferredGoal {
        try cancelQueuedGoalDeliveryUnlocked(goal)
        if goal.status == .active { goal.status = .paused; goal.evidence = "Execution ownership changed. Resume on the new owner." }
        goal.pendingDeliveryID = nil; try saveGoalUnlocked(goal); transferredGoal = goal
      }
      if let existing = try federationConversationUnlocked(conversationID) {
        guard existing.workspaceID == workspaceID else { throw federationError("wrong_owner", "This conversation already belongs to another execution workspace.") }
        conversation = existing
      } else {
        conversation.workspaceID = workspaceID; conversation.libraryID = identity.libraryID
        let statement = try prepareUnlocked("INSERT INTO execution_conversations(id,workspace_id,conversation,transcript) VALUES (?,?,?,?)")
        defer { sqlite3_finalize(statement) }
        try bind(conversationID, at: 1, to: statement); try bind(workspaceID, at: 2, to: statement)
        try bind(JSONEncoder().encode(conversation), at: 3, to: statement)
        try bind(JSONEncoder().encode(federationLegacyTranscriptUnlocked(conversationID)), at: 4, to: statement)
        try stepDone(statement)
        for runID in try libraryIDsUnlocked("SELECT id FROM runs WHERE conversation_id=?", bindings: [conversationID]) {
          try toolsExecuteUnlocked("INSERT INTO execution_runs(id,workspace_id,conversation_id) VALUES (?,?,?)", [runID, workspaceID, conversationID])
        }
        // Notify every client that control now belongs to the independent origin.
        try toolsExecuteUnlocked("UPDATE conversations SET updated_at=? WHERE id=?", [Self.timestamp(Date()), conversationID])
      }
      let adoption = try ExecutionAdoption(workspaceID: workspaceID, conversation: conversation,
        runtimeKind: text(session, column: 0), nativeSessionID: nativeID, model: optionalText(session, column: 2),
        thinking: optionalText(session, column: 3), permission: optionalText(session, column: 4),
        knownRunIDs: libraryIDsUnlocked("SELECT id FROM runs WHERE conversation_id=? ORDER BY created_at,id", bindings: [conversationID]), nativeWorkingDirectory: root.rootPath, goal: transferredGoal)
      let saved = try prepareUnlocked("INSERT INTO execution_adoptions(conversation_id,workspace_id,payload) VALUES (?,?,?)")
      defer { sqlite3_finalize(saved) }
      try bind(conversationID, at: 1, to: saved); try bind(workspaceID, at: 2, to: saved)
      try bind(JSONEncoder().encode(adoption), at: 3, to: saved); try stepDone(saved)
      var request = adoption
      request.transcript = try adoptionTranscriptUnlocked(conversationID)
      return request
    }
  }

  /// The legacy history sent with an adoption: the newest messages and
  /// activities that fit the host's request limit (8 MiB) and its counts
  /// (`adoptionEntityLimit` of each), roles the host accepts. The full
  /// history stays in this library either way.
  func adoptionTranscriptUnlocked(_ conversationID: String, limit: Int = 6 * 1_024 * 1_024) throws -> LibraryTranscript {
    var transcript = try federationLegacyTranscriptUnlocked(conversationID)
    transcript.messages.removeAll { !["user", "assistant", "system"].contains($0.role) }
    return Self.fitted(transcript, limit: limit)
  }

  /// The most messages, and the most activities, a Linux host accepts in an
  /// adopted transcript (`remote/src/client-execution.mjs`).
  static let adoptionEntityLimit = 10_000

  static func fitted(_ transcript: LibraryTranscript, limit: Int, count: Int = adoptionEntityLimit) -> LibraryTranscript {
    var value = transcript
    // Keep the latest turns, as the byte trim below does.
    if value.messages.count > count { value.messages.removeFirst(value.messages.count - count) }
    if value.activities.count > count { value.activities.removeFirst(value.activities.count - count) }
    let encoder = JSONEncoder()
    func size() -> Int { (try? encoder.encode(value).count) ?? Int.max }
    while size() > limit, !value.messages.isEmpty || !value.activities.isEmpty {
      // Drop from the oldest end, a quarter at a time, keeping the latest turns.
      let messages = max(1, value.messages.count / 4), activities = max(1, value.activities.count / 4)
      if !value.messages.isEmpty { value.messages.removeFirst(min(messages, value.messages.count)) }
      if !value.activities.isEmpty { value.activities.removeFirst(min(activities, value.activities.count)) }
    }
    return value
  }

  func federationLegacyTranscriptUnlocked(_ conversationID: String) throws -> LibraryTranscript {
    let statement = try prepareUnlocked("SELECT id,run_id,role,content,status,created_at,COALESCE((SELECT kind FROM workspace_session_deliveries WHERE message_id=messages.id),(SELECT kind FROM device_message_provenance WHERE message_id=messages.id)),COALESCE((SELECT source_id FROM workspace_session_deliveries WHERE message_id=messages.id),(SELECT source_id FROM device_message_provenance WHERE message_id=messages.id)),COALESCE((SELECT source_title FROM workspace_session_deliveries WHERE message_id=messages.id),(SELECT source_title FROM device_message_provenance WHERE message_id=messages.id)),COALESCE((SELECT source_agent FROM workspace_session_deliveries WHERE message_id=messages.id),(SELECT source_agent FROM device_message_provenance WHERE message_id=messages.id)) FROM messages WHERE conversation_id=? ORDER BY created_at,id")
    defer { sqlite3_finalize(statement) }
    try bind(conversationID, at: 1, to: statement)
    var transcript = LibraryTranscript(conversationID: conversationID)
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      transcript.messages.append(try LibraryMessage(id: text(statement, column: 0), conversationID: conversationID,
        runID: optionalText(statement, column: 1), role: text(statement, column: 2), content: text(statement, column: 2) == "user" ? (optionalText(statement, column: 6) == "goal" ? "Continuing toward the goal." : WorkspaceGoal.displayPrompt(text(statement, column: 3))) : text(statement, column: 3),
        status: optionalText(statement, column: 4), createdAt: text(statement, column: 5),
        agentSourceID: optionalText(statement, column: 7), isAgentAuthored: optionalText(statement, column: 7) == nil ? nil : true,
        senderSessionTitle: optionalText(statement, column: 8), senderHarness: optionalText(statement, column: 9), senderKind: optionalText(statement, column: 6)))
    }
    let events = try prepareUnlocked("SELECT id,run_id,content FROM run_activities WHERE conversation_id=? ORDER BY created_at,id")
    defer { sqlite3_finalize(events) }
    try bind(conversationID, at: 1, to: events)
    while true {
      let code = sqlite3_step(events)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let raw = try text(events, column: 2)
      let activity = try? JSONDecoder().decode(AgentRunActivity.self, from: Data(raw.utf8))
      transcript.activities.append(try LibraryActivity(id: text(events, column: 0), runID: text(events, column: 1),
        title: activity?.title ?? activity?.kind.rawValue ?? "Activity", detail: activity?.detail ?? activity?.content ?? raw,
        status: activity?.status ?? "completed"))
    }
    return transcript
  }
}

extension WorkspaceDatabase {
  public func prepareExecutionAdoption(conversationID: String, workspaceID: String, deviceID: String) async throws -> ExecutionAdoption {
    try await write { try $0.prepareExecutionAdoption(conversationID: conversationID, workspaceID: workspaceID, deviceID: deviceID) }
  }
}
