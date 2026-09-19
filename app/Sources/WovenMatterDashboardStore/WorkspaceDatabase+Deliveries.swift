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
    try transaction { try reserveToolDeliveryUnlocked(sourceID: sourceID, targetID: targetID, text: text,
      requestID: requestID, kind: kind, purpose: purpose, eventKey: eventKey) }
  }

  func reserveToolDeliveryUnlocked(sourceID: String, targetID: String, text: String, requestID: String,
                                   kind: WorkspaceSessionDeliveryKind, purpose: String? = nil,
                                   eventKey: String? = nil) throws -> WorkspaceSessionDelivery {
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

  /// A durable claim prevents concurrent callbacks or retries dispatching twice.
  /// Preparation is safe to recover; an unconfirmed native submission is not.
  public func claimToolDelivery(id: String, now: Date = Date()) throws -> WorkspaceSessionDelivery? {
    try transaction {
      guard let delivery = try deliveryUnlocked(id), delivery.status == "queued" else { return nil }
      let retryAfter = try historyRowsUnlocked("SELECT retry_after FROM workspace_session_deliveries WHERE id=?", values: [id])
        .first?.objectValue?["retry_after"]?.doubleValue
      if let retryAfter, retryAfter > now.timeIntervalSince1970 { return nil }
      guard try toolDeliveryAuthorizedUnlocked(delivery) else {
        try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='cancelled' WHERE id=?", [id])
        return nil
      }
      try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='sending',transport_started=0,retry_after=NULL WHERE id=? AND status='queued'", [id])
      return try deliveryUnlocked(id)
    }
  }

  public func validateClaimedToolDelivery(id: String) throws {
    try withLock { try validateClaimedToolDeliveryUnlocked(id: id) }
  }

  /// Native HTTP dispatch has no durable local input acceptance. Record this
  /// boundary before issuing a request so a lost response can never be retried.
  public func markToolDeliveryTransportStarted(id: String) throws {
    try transaction { try markToolDeliveryTransportStartedUnlocked(id: id) }
  }

  func markToolDeliveryTransportStartedUnlocked(id: String) throws {
    try validateClaimedToolDeliveryUnlocked(id: id)
    try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET transport_started=1 WHERE id=?", [id])
  }

  /// A scheduler may retry preparation with the same occurrence identity. Once
  /// input could have reached the backend, only reconciliation can settle it.
  public func failToolDeliveryAttempt(id: String, now: Date = Date()) throws {
    try transaction {
      guard let delivery = try deliveryUnlocked(id), delivery.status == "sending" else { return }
      let submitted = try historyRowsUnlocked("SELECT transport_started FROM workspace_session_deliveries WHERE id=?", values: [id])
        .first?.objectValue?["transport_started"]?.intValue != 0
      if !submitted, try !toolDeliveryAuthorizedUnlocked(delivery) {
        try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='cancelled' WHERE id=?", [id])
        return
      }
      let scheduled = delivery.kind == .timer || delivery.kind == .notification
      let status = submitted ? "uncertain" : scheduled ? "queued" : "failed"
      try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status=?,retry_after=? WHERE id=?",
        [status, status == "queued" ? String(now.addingTimeInterval(30).timeIntervalSince1970) : nil, id])
    }
  }

  /// Call inside the final acceptance transaction, after asynchronous connection
  /// and attachment preparation. A prior app-level check is only a preflight.
  func validateClaimedToolDeliveryUnlocked(id: String) throws {
    guard let delivery = try deliveryUnlocked(id), delivery.status == "sending",
          try toolDeliveryAuthorizedUnlocked(delivery) else {
      throw WorkspaceToolError.invalid("This delivery was cancelled or its access was revoked.")
    }
  }

  private func toolDeliveryAuthorizedUnlocked(_ delivery: WorkspaceSessionDelivery) throws -> Bool {
    for id in [delivery.sourceID, delivery.targetID] {
      guard !(try historyRowsUnlocked("SELECT 1 FROM dashboard_conversations WHERE id=? AND deleted_at IS NULL", values: [id])).isEmpty else { return false }
    }
    let source = try sessionToolsUnlocked(delivery.sourceID)
    let target = try sessionToolsUnlocked(delivery.targetID)
    switch delivery.kind {
    case .message, .created: return source.enabled.contains(.sessions)
    case .timer:
      guard target.enabled.contains(.timers) else { return false }
      return !(try historyRowsUnlocked(
        "SELECT 1 FROM workspace_session_timers WHERE session_id=? AND pending_delivery_id=? AND is_paused=0",
        values: [delivery.targetID, delivery.id])).isEmpty
    case .notification:
      let relation = try relationshipUnlocked(delivery.sourceID)
      if let key = try historyRowsUnlocked("SELECT event_key FROM workspace_session_deliveries WHERE id=?", values: [delivery.id]).first?.objectValue?["event_key"]?.stringValue,
         key.hasPrefix("coordination:") {
        let epoch = try historyRowsUnlocked("SELECT coordination_epoch FROM workspace_session_relationships WHERE session_id=?", values: [delivery.sourceID]).first?.objectValue?["coordination_epoch"]?.stringValue ?? ""
        guard key.hasPrefix("coordination:" + epoch + ":") else { return false }
      }
      return target.enabled.contains(.sessions) && relation.coordinatorID == delivery.targetID && relation.notificationsEnabled
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
    try transaction {
      try executeUnlocked("""
        UPDATE workspace_session_deliveries SET status=CASE
          WHEN transport_started=1 THEN 'uncertain'
          WHEN kind IN ('timer','notification') THEN 'queued' ELSE 'failed' END
          WHERE status='sending' AND message_id IS NULL
        """)
    }
  }

  public func toolDelivery(id: String) throws -> WorkspaceSessionDelivery? {
    try withLock { try deliveryUnlocked(id) }
  }

  public func sessionDeliveries(sessionID: String? = nil, queuedOnly: Bool = false, limit: Int = 200, beforeID: String? = nil, outgoingOnly: Bool = false) throws -> [WorkspaceSessionDelivery] {
    try withLock {
      var sql = "SELECT rowid AS sequence,* FROM workspace_session_deliveries WHERE 1=1"
      var values: [String?] = []
      if let sessionID {
        if outgoingOnly { sql += " AND source_id=? AND kind IN ('message','created')"; values.append(sessionID) }
        else { sql += " AND (source_id=? OR target_id=?)"; values += [sessionID, sessionID] }
      }
      if let beforeID {
        guard !queuedOnly, let cursor = try deliveryUnlocked(beforeID),
              sessionID == nil || cursor.sourceID == sessionID || cursor.targetID == sessionID else {
          throw WorkspaceToolError.invalid("The delivery cursor is unavailable for this session.")
        }
        guard let sequence = cursor.sequence else { throw WorkspaceToolError.invalid("The delivery cursor is unavailable.") }
        sql += " AND rowid<?"
        values.append(String(sequence))
      }
      if queuedOnly {
        sql += " AND status='queued' AND (retry_after IS NULL OR retry_after<=?)"
        values.append(String(Date().timeIntervalSince1970))
      }
      sql += queuedOnly ? " ORDER BY rowid LIMIT ?" : " ORDER BY rowid DESC LIMIT ?"
      values.append(String(min(max(limit, 1), 500)))
      return try historyRowsUnlocked(sql, values: values).map(deliveryFromRow)
    }
  }

  /// Refresh exactly the loaded transcript window, so polling updates receipt
  /// statuses without dropping older pages or skipping bursts of new activity.
  public func outgoingDeliveryWindow(sessionID: String, throughID: String) throws -> [WorkspaceSessionDelivery] {
    try withLock {
      guard let cursor = try deliveryUnlocked(throughID), cursor.sourceID == sessionID, let sequence = cursor.sequence else {
        throw WorkspaceToolError.invalid("The delivery cursor is unavailable for this session.")
      }
      return try historyRowsUnlocked("""
        SELECT rowid AS sequence,* FROM workspace_session_deliveries WHERE source_id=? AND kind IN ('message','created')
          AND rowid>=? ORDER BY rowid DESC
        """, values: [sessionID, String(sequence)]).map(deliveryFromRow)
    }
  }

  private func deliveryUnlocked(_ id: String) throws -> WorkspaceSessionDelivery? {
    try historyRowsUnlocked("SELECT rowid AS sequence,* FROM workspace_session_deliveries WHERE id=?", values: [id]).first.map(deliveryFromRow)
  }

  private func deliveryFromRow(_ value: GatewayJSONValue) -> WorkspaceSessionDelivery {
    let r = value.objectValue ?? [:]
    func string(_ key: String) -> String { r[key]?.stringValue ?? "" }
    return WorkspaceSessionDelivery(id: string("id"), sourceID: string("source_id"), targetID: string("target_id"), text: string("content"),
      kind: WorkspaceSessionDeliveryKind(rawValue: string("kind")) ?? .message, status: string("status"), messageID: r["message_id"]?.stringValue,
      sourceTitle: string("source_title"), sourceHarness: string("source_agent"), targetTitle: string("target_title"), targetHarness: string("target_harness"),
      targetModel: r["target_model"]?.stringValue, purpose: r["purpose"]?.stringValue, createdAt: string("created_at"), sequence: r["sequence"]?.intValue.map(Int64.init))
  }
}
