import Foundation
import SQLite3
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  /// Only the app scheduler uses timer/notification kinds. Agent commands always
  /// use message/created with a caller bound to their endpoint.
  public func reserveToolDelivery(sourceID: String, targetID: String, text: String, requestID: String,
                                  kind: WorkspaceSessionDeliveryKind = .message, purpose: String? = nil,
                                  eventKey: String? = nil) throws -> WorkspaceSessionDelivery {
    try transaction {
      guard UUID(uuidString: requestID) != nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            text.utf8.count <= 65_536 else { throw WorkspaceToolError.invalid("A delivery needs a UUID and a message of at most 64 KiB.") }
      if kind == .message || kind == .created {
        try requireToolUnlocked(.sessions, sessionID: sourceID)
        guard sourceID != targetID else { throw WorkspaceToolError.invalid("Use a timer for follow-ups to this session.") }
      }
      try requireToolSessionUnlocked(sourceID)
      try requireToolSessionUnlocked(targetID)
      if let existing = try deliveryUnlocked(requestID) {
        guard existing.sourceID == sourceID, existing.targetID == targetID, existing.text == text, existing.kind == kind else {
          throw WorkspaceToolError.invalid("Delivery request ID collision.")
        }
        return existing
      }
      if let eventKey, let existing = try historyRowsUnlocked("SELECT id FROM workspace_session_deliveries WHERE event_key=?", values: [eventKey]).first?.objectValue?["id"]?.stringValue,
         let delivery = try deliveryUnlocked(existing) { return delivery }
      try toolsExecuteUnlocked("""
        INSERT INTO workspace_session_deliveries(id,source_id,target_id,content,status,source_agent,source_title,
          kind,purpose,target_title,target_harness,target_model,event_key)
        SELECT ?,?,?,?,'queued',coalesce(s.runtime_kind,c.agent_codename),c.title,?,?,t.title,
          coalesce(d.runtime_kind,t.agent_codename),d.model,?
        FROM dashboard_conversations c JOIN dashboard_conversations t ON t.id=?
        LEFT JOIN desktop_local_acp_sessions s ON s.conversation_id=c.id
        LEFT JOIN desktop_local_acp_sessions d ON d.conversation_id=t.id WHERE c.id=?
        """, [requestID, sourceID, targetID, text, kind.rawValue, purpose, eventKey, targetID, sourceID])
      guard let result = try deliveryUnlocked(requestID) else { throw WorkspaceToolError.invalid("Unable to reserve delivery.") }
      return result
    }
  }

  /// A durable claim prevents concurrent callbacks or retries dispatching twice.
  /// Sending claims recovered after an app exit stay uncertain until reconciled.
  public func claimToolDelivery(id: String) throws -> WorkspaceSessionDelivery? {
    try transaction {
      guard let delivery = try deliveryUnlocked(id), delivery.status == "queued" else { return nil }
      try requireToolSessionUnlocked(delivery.sourceID)
      try requireToolSessionUnlocked(delivery.targetID)
      switch delivery.kind {
      case .message, .created: try requireToolUnlocked(.sessions, sessionID: delivery.sourceID)
      case .timer: try requireToolUnlocked(.timers, sessionID: delivery.targetID)
      case .notification:
        let relation = try relationshipUnlocked(delivery.sourceID)
        guard relation.coordinatorID == delivery.targetID, relation.notificationsEnabled else {
          try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='cancelled' WHERE id=?", [id])
          return nil
        }
      }
      try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='sending' WHERE id=? AND status='queued'", [id])
      return try deliveryUnlocked(id)
    }
  }

  public func setToolDeliveryStatus(id: String, status: String, messageID: String? = nil) throws {
    guard ["queued", "accepted", "failed", "uncertain", "cancelled"].contains(status) else {
      throw WorkspaceToolError.invalid("Invalid delivery status.")
    }
    try transaction {
      guard let current = try deliveryUnlocked(id), current.status != "accepted" else { return }
      try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status=?,message_id=coalesce(?,message_id) WHERE id=?", [status, messageID, id])
    }
  }

  public func recoverToolDeliveries() throws {
    try transaction { try executeUnlocked("UPDATE workspace_session_deliveries SET status='uncertain' WHERE status='sending' AND message_id IS NULL") }
  }

  public func sessionDeliveries(sessionID: String? = nil, queuedOnly: Bool = false, limit: Int = 200) throws -> [WorkspaceSessionDelivery] {
    try lock.withLock {
      var sql = "SELECT * FROM workspace_session_deliveries WHERE 1=1"
      var values: [String?] = []
      if let sessionID { sql += " AND (source_id=? OR target_id=?)"; values += [sessionID, sessionID] }
      if queuedOnly { sql += " AND status='queued'" }
      sql += " ORDER BY created_at DESC,id DESC LIMIT ?"; values.append(String(min(max(limit, 1), 500)))
      return try historyRowsUnlocked(sql, values: values).map(deliveryFromRow)
    }
  }

  private func deliveryUnlocked(_ id: String) throws -> WorkspaceSessionDelivery? {
    try historyRowsUnlocked("SELECT * FROM workspace_session_deliveries WHERE id=?", values: [id]).first.map(deliveryFromRow)
  }

  private func deliveryFromRow(_ value: GatewayJSONValue) -> WorkspaceSessionDelivery {
    let r = value.objectValue ?? [:]
    func string(_ key: String) -> String { r[key]?.stringValue ?? "" }
    return WorkspaceSessionDelivery(id: string("id"), sourceID: string("source_id"), targetID: string("target_id"), text: string("content"),
      kind: WorkspaceSessionDeliveryKind(rawValue: string("kind")) ?? .message, status: string("status"), messageID: r["message_id"]?.stringValue,
      sourceTitle: string("source_title"), sourceHarness: string("source_agent"), targetTitle: string("target_title"), targetHarness: string("target_harness"),
      targetModel: r["target_model"]?.stringValue, purpose: r["purpose"]?.stringValue, createdAt: string("created_at"))
  }
}
