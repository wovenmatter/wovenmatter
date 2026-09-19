import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  /// Bounded durable observations let all native transports share completion
  /// semantics. Only turns completed during the current assignment are eligible.
  public func collectCoordinationTurnNotifications(limit: Int = 100) throws -> [WorkspaceSessionDelivery] {
    try transaction {
      try retireUnavailableCoordinationUnlocked()
      let rows = try historyRowsUnlocked("""
        SELECT r.id,r.conversation_id,r.status,r.error,r.user_message_id,r.started_at,
          m.coordination_epoch FROM dashboard_runs r
        JOIN workspace_session_relationships m ON m.session_id=r.conversation_id
        JOIN dashboard_conversations c ON c.id=r.conversation_id AND c.deleted_at IS NULL
        WHERE m.coordinator_id IS NOT NULL AND m.coordination_epoch IS NOT NULL
          AND r.status IN ('completed','failed','cancelled','canceled')
          AND coalesce(r.completed_at,r.updated_at,r.created_at,'') >= m.coordination_since
          AND NOT EXISTS (SELECT 1 FROM workspace_coordination_observations o
            WHERE o.epoch=m.coordination_epoch AND o.event_key='run:' || r.id)
        ORDER BY coalesce(r.completed_at,r.updated_at,r.created_at),r.id LIMIT ?
        """, values: [String(min(max(limit, 1), 200))])
      var deliveries: [WorkspaceSessionDelivery] = []
      for value in rows {
        guard let row = value.objectValue, let id = row["id"]?.stringValue,
              let session = row["conversation_id"]?.stringValue else { continue }
        let status = row["status"]?.stringValue ?? "completed"
        // Include all steering inputs assigned to the run. A real user or agent
        // instruction mixed into a notification-triggered turn makes it work.
        var inputs = try historyRowsUnlocked("""
          SELECT d.kind FROM dashboard_messages u LEFT JOIN workspace_session_deliveries d ON d.message_id=u.id
          WHERE u.conversation_id=? AND u.role='user' AND (u.run_id=? OR u.id=?)
          """, values: [session, id, row["user_message_id"]?.stringValue])
        if inputs.isEmpty {
          inputs = try historyRowsUnlocked("""
            SELECT d.kind FROM dashboard_messages u LEFT JOIN workspace_session_deliveries d ON d.message_id=u.id
            WHERE u.id=(SELECT id FROM dashboard_messages WHERE conversation_id=? AND role='user'
              AND created_at<=coalesce(?,created_at) ORDER BY created_at DESC,rowid DESC LIMIT 1)
            """, values: [session, row["started_at"]?.stringValue])
        }
        let notificationOnly = !inputs.isEmpty && inputs.allSatisfy { $0.objectValue?["kind"]?.stringValue == "notification" }
        let detail: String
        if status == "completed" {
          detail = "Finished a turn. The assignment remains managed; review its result before deciding whether to send more work or release coordination."
        } else {
          let error = row["error"]?.stringValue.map { " " + String(WorkspaceHistoryPrivacy.redactingToolEndpoints($0).prefix(2_000)) } ?? ""
          detail = "The turn \(status == "failed" ? "failed" : "stopped").\(error)"
        }
        if let delivery = try recordCoordinationObservationUnlocked(sessionID: session, eventID: "run:" + id,
            detail: detail + " Run: " + id + ".", suppress: notificationOnly) {
          deliveries.append(delivery)
        }
      }
      return deliveries
    }
  }

  /// The app observes a live user-facing request; this never answers it or
  /// transfers approval authority to another agent.
  public func recordCoordinationNeedsInput(sessionID: String, requestID: String, requiresUserApproval: Bool) throws -> WorkspaceSessionDelivery? {
    try transaction {
      try retireUnavailableCoordinationUnlocked(sessionID: sessionID)
      return try recordCoordinationObservationUnlocked(sessionID: sessionID, eventID: "input:" + requestID,
        detail: requiresUserApproval
          ? "Needs user approval. The user must answer the permission request in Woven Matter; do not approve it on their behalf."
          : "Needs input. Inspect the session and help with the work if appropriate. User-facing questions remain available in Woven Matter.",
        suppress: false)
    }
  }

  private func recordCoordinationObservationUnlocked(sessionID: String, eventID: String, detail: String, suppress: Bool) throws -> WorkspaceSessionDelivery? {
    let relationship = try relationshipUnlocked(sessionID)
    guard let target = relationship.coordinatorID,
          let epoch = try historyRowsUnlocked("SELECT coordination_epoch FROM workspace_session_relationships WHERE session_id=?", values: [sessionID]).first?.objectValue?["coordination_epoch"]?.stringValue else { return nil }
    guard try historyRowsUnlocked("SELECT 1 FROM workspace_coordination_observations WHERE epoch=? AND event_key=?", values: [epoch, eventID]).isEmpty else { return nil }
    try toolsExecuteUnlocked("INSERT INTO workspace_coordination_observations(epoch,event_key) VALUES(?,?)", [epoch, eventID])
    guard !suppress, relationship.notificationsEnabled,
          try sessionToolsUnlocked(target).enabled.contains(.sessions) else { return nil }
    let title = try historyRowsUnlocked("SELECT title FROM dashboard_conversations WHERE id=? AND deleted_at IS NULL", values: [sessionID]).first?.objectValue?["title"]?.stringValue ?? "Session"
    return try reserveToolDeliveryUnlocked(sourceID: sessionID, targetID: target,
      text: "Woven Matter update from “\(title)” (\(sessionID)).\n\(detail)",
      requestID: UUID().uuidString.lowercased(), kind: .notification,
      eventKey: "coordination:" + epoch + ":" + eventID)
  }

  /// Snapshot tombstones can outlive a coordination relationship. Retire only
  /// those invalid assignments; a missing session must not stop the scheduler.
  private func retireUnavailableCoordinationUnlocked(sessionID: String? = nil) throws {
    let predicate = """
      coordinator_id IS NOT NULL AND (? IS NULL OR session_id=?) AND (
        NOT EXISTS (SELECT 1 FROM dashboard_conversations c WHERE c.id=workspace_session_relationships.session_id AND c.deleted_at IS NULL)
        OR NOT EXISTS (SELECT 1 FROM dashboard_conversations c WHERE c.id=workspace_session_relationships.coordinator_id AND c.deleted_at IS NULL))
      """
    try toolsExecuteUnlocked("DELETE FROM workspace_session_grants WHERE kind='approved' AND target_id IN (SELECT session_id FROM workspace_session_relationships WHERE " + predicate + ")", [sessionID, sessionID])
    try toolsExecuteUnlocked("UPDATE workspace_session_relationships SET coordinator_id=NULL,coordination_epoch=NULL,coordination_since=NULL WHERE " + predicate, [sessionID, sessionID])
  }
}
