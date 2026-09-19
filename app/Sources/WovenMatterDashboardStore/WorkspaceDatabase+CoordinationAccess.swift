import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  /// A durable intent returns immediately instead of keeping a CLI connection
  /// open while the user considers an access sheet. Replays never reacquire a
  /// completed or released assignment and never create a second sheet.
  public func requestCoordinationAccess(sourceID: String, targetID: String, purpose: String,
                                       notifications: Bool = true, requestID: String) throws -> WorkspaceCoordinationAccessRequest {
    try transaction {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      guard UUID(uuidString: requestID) != nil, !purpose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            purpose.utf8.count <= 65_536 else { throw WorkspaceToolError.invalid("A valid request ID and management purpose are required.") }
      if let existing = try coordinationAccessRequestUnlocked(requestID) {
        guard existing.sourceID == sourceID, existing.targetID == targetID,
              existing.purpose == purpose, existing.notifications == notifications else {
          throw WorkspaceToolError.invalid("This request ID already identifies a different management request.")
        }
        return existing
      }
      try validateCoordinationUnlocked(sourceID: sourceID, targetID: targetID)
      let pending: Bool
      do {
        try requireTranscriptAccessUnlocked(sourceID: sourceID, targetID: targetID)
        pending = false
      } catch WorkspaceToolError.accessRequired { pending = true }
      if pending {
        let count = try historyRowsUnlocked("SELECT count(*) AS n FROM workspace_coordination_access_requests WHERE state='pending'", values: []).first?.objectValue?["n"]?.intValue ?? 0
        guard count < 48 else { throw WorkspaceToolError.invalid("Resolve the pending session access requests before requesting more.") }
      } else {
        try beginCoordinationUnlocked(sourceID: sourceID, targetID: targetID, purpose: purpose, notifications: notifications)
      }
      try toolsExecuteUnlocked("""
        INSERT INTO workspace_coordination_access_requests(id,source_id,target_id,purpose,notifications,state)
        VALUES(?,?,?,?,?,?)
        """, [requestID, sourceID, targetID, purpose, notifications ? "1" : "0", pending ? "pending" : "accepted"])
      guard let result = try coordinationAccessRequestUnlocked(requestID) else { throw WorkspaceToolError.invalid("Unable to save management request.") }
      return result
    }
  }

  public func pendingCoordinationAccessRequests() throws -> [WorkspaceCoordinationAccessRequest] {
    try lock.withLock {
      try historyRowsUnlocked(coordinationAccessSelect + " WHERE r.state='pending' ORDER BY r.created_at,r.id", values: []).map(coordinationAccessFromRow)
    }
  }

  /// User-only entry point. Capability, ownership, cycle and fanout checks are
  /// repeated inside the same transaction as acquiring coordination.
  public func resolveCoordinationAccess(requestID: String, allowed: Bool) throws -> WorkspaceCoordinationAccessRequest {
    try transaction {
      guard let request = try coordinationAccessRequestUnlocked(requestID) else { throw WorkspaceToolError.invalid("The access request is unavailable.") }
      guard request.state == "pending" else { return request }
      var state = "rejected"
      var reason: String? = "The user did not grant access to this session."
      if allowed {
        do {
          try requireToolUnlocked(.sessions, sessionID: request.sourceID)
          try validateCoordinationUnlocked(sourceID: request.sourceID, targetID: request.targetID)
          try beginCoordinationUnlocked(sourceID: request.sourceID, targetID: request.targetID,
            purpose: request.purpose, notifications: request.notifications)
          state = "accepted"; reason = nil
        } catch let error as WorkspaceToolError {
          state = "failed"; reason = error.localizedDescription
        }
      }
      try toolsExecuteUnlocked("UPDATE workspace_coordination_access_requests SET state=?,error=? WHERE id=?", [state, reason, requestID])
      guard let result = try coordinationAccessRequestUnlocked(requestID) else { throw WorkspaceToolError.invalid("The access request is unavailable.") }
      return result
    }
  }

  /// Both orderly shutdown and recovery from an interrupted app lifetime revoke
  /// unanswered requests. A new explicit request is needed after reopening.
  public func cancelPendingCoordinationAccess() throws {
    try transaction {
      try executeUnlocked("""
        UPDATE workspace_coordination_access_requests SET state='cancelled',
          error='Woven Matter closed before access was approved. Use a new request ID to ask again.' WHERE state='pending'
        """)
    }
  }

  private var coordinationAccessSelect: String {
    """
      SELECT r.*,s.title AS source_title,t.title AS target_title FROM workspace_coordination_access_requests r
      JOIN dashboard_conversations s ON s.id=r.source_id JOIN dashboard_conversations t ON t.id=r.target_id
      """
  }

  private func coordinationAccessRequestUnlocked(_ id: String) throws -> WorkspaceCoordinationAccessRequest? {
    try historyRowsUnlocked(coordinationAccessSelect + " WHERE r.id=?", values: [id]).first.map(coordinationAccessFromRow)
  }

  private func coordinationAccessFromRow(_ row: GatewayJSONValue) -> WorkspaceCoordinationAccessRequest {
    let value = row.objectValue ?? [:]
    func text(_ key: String) -> String { value[key]?.stringValue ?? "" }
    return .init(id: text("id"), sourceID: text("source_id"), targetID: text("target_id"),
      sourceTitle: text("source_title"), targetTitle: text("target_title"), purpose: text("purpose"),
      notifications: value["notifications"]?.intValue == 1, state: text("state"), error: value["error"]?.stringValue)
  }
}
