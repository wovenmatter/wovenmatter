import Foundation
import SQLite3
import WovenMatterCore

public struct CompanionRetainedAssociation: Codable, Sendable {
  public var conversationID: String
  public var runID: String
  public var nativeSessionID: String
  public var runtimeKind: String
}
extension WorkspaceDatabaseConnection {
  func retainedAssociationUnlocked(workspaceID: String, runID: String, nativeSessionID: String?) throws -> CompanionRetainedAssociation? {
    guard federationID(runID) else { return nil }
    let statement = try prepareUnlocked("""
      SELECT r.conversation_id,s.runtime_kind,s.acp_session_id,r.openclaw_session_key,d.native_session_id,d.remote_workspace_id
      FROM dashboard_runs r JOIN desktop_local_acp_sessions s ON s.conversation_id=r.conversation_id
      LEFT JOIN desktop_local_acp_durable_runs d ON d.run_id=r.id
      WHERE r.id=? AND s.remote_workspace_id=?
      """)
    defer { sqlite3_finalize(statement) }
    try bind(runID, at: 1, to: statement); try bind(workspaceID, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW, let currentNative = optionalText(statement, column: 2), !currentNative.isEmpty,
          nativeSessionID == nil || nativeSessionID == currentNative else { return nil }
    let durable = optionalText(statement, column: 5) == workspaceID ? optionalText(statement, column: 4) : nil
    guard optionalText(statement, column: 3) == currentNative || durable == currentNative else { return nil }
    return try .init(conversationID: text(statement, column: 0), runID: runID, nativeSessionID: currentNative, runtimeKind: text(statement, column: 1))
  }
  public func companionRetainedAssociation(workspaceID: String, runID: String, nativeSessionID: String?) throws -> CompanionRetainedAssociation? {
    try withLock { try retainedAssociationUnlocked(workspaceID: workspaceID, runID: runID, nativeSessionID: nativeSessionID) }
  }
  private func validatedRetainedProofUnlocked(_ entry: CompanionJournalEntry, workspace: CompanionExecutionWorkspace) throws -> CompanionRetainedExecution {
    guard workspace.kind == .linux, entry.kind == .conversation, let proof = entry.retainedExecution,
          ["task-gateway", "default-agent-rpc"].contains(proof.source), ["completed", "failed", "cancelled", "interrupted"].contains(proof.status),
          entry.runID == proof.runID, entry.conversation?.id == entry.conversationID, entry.conversation?.activeRunID == nil,
          entry.conversation?.runtimeKind == proof.runtimeKind, proof.nativeSessionID.utf8.count <= 4096,
          let association = try retainedAssociationUnlocked(workspaceID: workspace.id, runID: proof.runID, nativeSessionID: proof.nativeSessionID),
          association.conversationID == entry.conversationID, association.runtimeKind == proof.runtimeKind else {
      throw federationError("wrong_owner", "Retained history does not match an exact settled execution in this workspace.")
    }
    let settled = try prepareUnlocked("SELECT fingerprint FROM companion_retained_settlements WHERE event_id=?")
    defer { sqlite3_finalize(settled) }
    try bind(entry.eventID, at: 1, to: settled)
    let code = sqlite3_step(settled)
    if code == SQLITE_ROW {
      guard try blob(settled, column: 0) == companionFingerprint(entry) else {
        throw federationError("event_conflict", "The retained journal differs from its accepted terminal proof.")
      }
    } else if code != SQLITE_DONE { throw stepError() }
    return proof
  }
  /// Settle only exact terminal run proofs before applying the chronological
  /// journal. This changes no conversation owner and never touches a runtime.
  public func settleCompanionRetainedRuns(_ batch: CompanionJournalBatch, deviceID: String) throws -> CompanionJournalBatchResult {
    try transaction {
      let library = try companionWorkspaceIDUnlocked()
      guard batch.libraryID == library, batch.entries.count <= CompanionFederationProtocol.maximumBatchEntries,
            try JSONEncoder().encode(batch).count <= CompanionFederationProtocol.maximumBatchBytes else {
        throw federationError("invalid_event", "Retained run proofs require a bounded batch for this library.")
      }
      for entry in batch.entries {
        let workspace = try federationAuthorizedWorkspaceUnlocked(entry.workspaceID, deviceID: deviceID)
        guard federationID(entry.eventID), federationID(entry.conversationID), entry.originSequence > 0,
              try JSONEncoder().encode(entry).count <= CompanionFederationProtocol.maximumEntryBytes else {
          throw federationError("invalid_event", "Retained run proofs require immutable bounded event identities.")
        }
        let fingerprint = try companionFingerprint(entry)
        let existing = try prepareUnlocked("SELECT workspace_id,fingerprint FROM companion_retained_settlements WHERE event_id=?")
        defer { sqlite3_finalize(existing) }
        try bind(entry.eventID, at: 1, to: existing)
        let code = sqlite3_step(existing)
        if code == SQLITE_ROW {
          guard try text(existing, column: 0) == workspace.id, try blob(existing, column: 1) == fingerprint else {
            throw federationError("event_conflict", "A retained proof identity was reused with different content.")
          }
          continue
        }
        guard code == SQLITE_DONE else { throw stepError() }
        let proof = try validatedRetainedProofUnlocked(entry, workspace: workspace)
        let owner = try companionIDsUnlocked("SELECT workspace_id || '/' || conversation_id FROM companion_execution_runs WHERE id=?", bindings: [proof.runID]).first
        guard owner == nil || owner == workspace.id + "/" + entry.conversationID else {
          throw federationError("wrong_owner", "This retained run belongs to another workspace or conversation.")
        }
        try companionExecuteUnlocked("UPDATE dashboard_runs SET status=?,updated_at=?,completed_at=COALESCE(completed_at,?) WHERE id=?", values: [proof.status, Self.timestamp(Date()), Self.timestamp(Date()), proof.runID])
        let insert = try prepareUnlocked("INSERT INTO companion_retained_settlements VALUES (?,?,?)")
        defer { sqlite3_finalize(insert) }
        try bind(entry.eventID, at: 1, to: insert); try bind(workspace.id, at: 2, to: insert); try bind(fingerprint, at: 3, to: insert); try stepDone(insert)
      }
      return .init(libraryID: library, acceptedEventIDs: batch.entries.map(\.eventID), cursor: 0)
    }
  }
  /// Only an authenticated origin may claim its exact recorded legacy session,
  /// after any other live run has settled. Preflight does not relax this fence.
  func acceptRetainedExecutionIdentityUnlocked(_ entry: CompanionJournalEntry, workspace: CompanionExecutionWorkspace) throws {
    let proof = try validatedRetainedProofUnlocked(entry, workspace: workspace)
    guard try federationScalarUnlocked("SELECT COUNT(*) FROM dashboard_runs WHERE conversation_id=? AND id<>? AND status IN ('running','queued','pending','cancelling','uncertain')", bindings: [entry.conversationID, proof.runID]) == 0,
          var conversation = try companionConversationUnlocked(id: entry.conversationID) else {
      throw federationError("wrong_owner", "Retained ownership cannot replace another active execution.")
    }
    let owner = try companionIDsUnlocked("SELECT workspace_id FROM companion_execution_conversations WHERE id=?", bindings: [entry.conversationID]).first
    guard owner == nil || owner == workspace.id else { throw federationError("wrong_owner", "Retained history belongs to another execution workspace.") }
    if owner == nil {
      conversation.workspaceID = workspace.id; conversation.libraryID = workspace.libraryID; conversation.activeRunID = nil
      let insert = try prepareUnlocked("INSERT INTO companion_execution_conversations(id,workspace_id,conversation,transcript) VALUES (?,?,?,?)")
      defer { sqlite3_finalize(insert) }
      try bind(entry.conversationID, at: 1, to: insert); try bind(workspace.id, at: 2, to: insert)
      try bind(JSONEncoder().encode(conversation), at: 3, to: insert)
      try bind(JSONEncoder().encode(federationLegacyTranscriptUnlocked(entry.conversationID)), at: 4, to: insert); try stepDone(insert)
    }
    let runOwner = try companionIDsUnlocked("SELECT workspace_id || '/' || conversation_id FROM companion_execution_runs WHERE id=?", bindings: [proof.runID]).first
    guard runOwner == nil || runOwner == workspace.id + "/" + entry.conversationID else {
      throw federationError("wrong_owner", "Retained run identity belongs to another execution workspace or conversation.")
    }
    try companionExecuteUnlocked("INSERT OR IGNORE INTO companion_execution_runs(id,workspace_id,conversation_id) VALUES (?,?,?)", values: [proof.runID, workspace.id, entry.conversationID])
    try companionExecuteUnlocked("UPDATE dashboard_runs SET status=?,updated_at=?,completed_at=COALESCE(completed_at,?) WHERE id=?", values: [proof.status, Self.timestamp(Date()), Self.timestamp(Date()), proof.runID])
  }
}
extension WorkspaceDatabase {
  public func settleCompanionRetainedRuns(_ batch: CompanionJournalBatch, deviceID: String) async throws -> CompanionJournalBatchResult {
    try await write { try $0.settleCompanionRetainedRuns(batch, deviceID: deviceID) }
  }
  public func companionRetainedAssociation(workspaceID: String, runID: String, nativeSessionID: String?) async throws -> CompanionRetainedAssociation? {
    try await read { try $0.companionRetainedAssociation(workspaceID: workspaceID, runID: runID, nativeSessionID: nativeSessionID) }
  }
}
