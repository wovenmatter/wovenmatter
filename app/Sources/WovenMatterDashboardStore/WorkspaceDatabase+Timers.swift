import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  /// The app is the scheduler. No timer is installed with a provider or operating system.
  public func sessionTimers(sessionID: String? = nil) throws -> [WorkspaceSessionTimer] {
    try withLock { try timersUnlocked(sessionID: sessionID) }
  }

  private func timersUnlocked(sessionID: String? = nil) throws -> [WorkspaceSessionTimer] {
    let sql = "SELECT t.* FROM workspace_session_timers t JOIN dashboard_conversations c ON c.id=t.session_id WHERE c.deleted_at IS NULL"
      + (sessionID == nil ? "" : " AND t.session_id=?") + " ORDER BY t.next_fire_at,t.id"
    return try historyRowsUnlocked(sql, values: sessionID.map { [$0] } ?? []).map { value in
      let r = value.objectValue ?? [:]
      return WorkspaceSessionTimer(id: r["id"]?.stringValue ?? "", sessionID: r["session_id"]?.stringValue ?? "",
        instruction: r["instruction"]?.stringValue ?? "", nextFireAt: Date(timeIntervalSince1970: r["next_fire_at"]?.doubleValue ?? 0),
        intervalSeconds: r["interval_seconds"]?.doubleValue, isPaused: r["is_paused"]?.intValue == 1,
        pendingDeliveryID: r["pending_delivery_id"]?.stringValue)
    }
  }

  func requireTimerAccessUnlocked(sourceID: String, targetID: String) throws {
    try requireToolUnlocked(.timers, sessionID: sourceID)
    try requireToolUnlocked(.timers, sessionID: targetID)
    if sourceID != targetID {
      try requireToolUnlocked(.sessions, sessionID: sourceID)
      guard try relationshipUnlocked(targetID).coordinatorID == sourceID else {
        throw WorkspaceToolError.invalid("Only the session itself or its coordinator can change its timers.")
      }
    }
  }

  @discardableResult
  public func saveSessionTimer(_ timer: WorkspaceSessionTimer, callerID: String,
                               requestID: String? = nil, creating: Bool? = nil) throws -> WorkspaceSessionTimer {
    try timer.validate()
    return try transaction {
      try requireToolUnlocked(.timers, sessionID: callerID)
      let outcome = try performToolMutationUnlocked(callerID: callerID, requestID: requestID,
        operation: creating == true ? "timers.create" : "timers.save", input: timer) {
        // Include timers whose destination was deleted: an upsert must not reuse
        // their identity or silently modify a timer hidden from the active list.
        let existing = try historyRowsUnlocked("SELECT session_id FROM workspace_session_timers WHERE id=?", values: [timer.id])
          .first?.objectValue?["session_id"]?.stringValue
        if creating == true, existing != nil { throw WorkspaceToolError.invalid("Timer already exists.") }
        if creating == false, existing == nil { throw WorkspaceToolError.invalid("Timer not found.") }
        var saved = timer
        if creating == false, let existing { saved.sessionID = existing }
        try requireTimerAccessUnlocked(sourceID: callerID, targetID: saved.sessionID)
        if let existing, existing != saved.sessionID {
          throw WorkspaceToolError.invalid("A timer cannot move to another session.")
        }
        try toolsExecuteUnlocked("""
          INSERT INTO workspace_session_timers(id,session_id,instruction,next_fire_at,interval_seconds,is_paused)
          VALUES(?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET instruction=excluded.instruction,
            next_fire_at=excluded.next_fire_at,interval_seconds=excluded.interval_seconds,
            is_paused=excluded.is_paused,pending_delivery_id=NULL
          """, [saved.id, saved.sessionID, saved.instruction, String(saved.nextFireAt.timeIntervalSince1970),
                 saved.intervalSeconds.map { String($0) }, saved.isPaused ? "1" : "0"])
        return saved
      }
      try requireTimerAccessUnlocked(sourceID: callerID, targetID: outcome.result.sessionID)
      return outcome.result
    }
  }

  public func pauseSessionTimer(id: String, paused: Bool, callerID: String? = nil, requestID: String? = nil) throws {
    try transaction {
      if let callerID { try requireToolUnlocked(.timers, sessionID: callerID) }
      let outcome = try performToolMutationUnlocked(callerID: callerID, requestID: requestID,
        operation: paused ? "timers.pause" : "timers.resume", input: id) {
        guard let timer = try timersUnlocked().first(where: { $0.id == id }) else {
          throw WorkspaceToolError.invalid("Timer not found.")
        }
        if let callerID { try requireTimerAccessUnlocked(sourceID: callerID, targetID: timer.sessionID) }
        if !paused { try requireToolUnlocked(.timers, sessionID: timer.sessionID) }
        try toolsExecuteUnlocked("UPDATE workspace_session_timers SET is_paused=?,pending_delivery_id=NULL WHERE id=?", [paused ? "1" : "0", id])
        return timer.sessionID
      }
      if let callerID { try requireTimerAccessUnlocked(sourceID: callerID, targetID: outcome.result) }
    }
  }

  public func removeSessionTimer(id: String, callerID: String? = nil, requestID: String? = nil) throws {
    try transaction {
      if let callerID { try requireToolUnlocked(.timers, sessionID: callerID) }
      let outcome = try performToolMutationUnlocked(callerID: callerID, requestID: requestID,
        operation: "timers.remove", input: id) { () -> String? in
        guard let timer = try timersUnlocked().first(where: { $0.id == id }) else { return nil }
        if let callerID { try requireTimerAccessUnlocked(sourceID: callerID, targetID: timer.sessionID) }
        try toolsExecuteUnlocked("DELETE FROM workspace_session_timers WHERE id=?", [id])
        return timer.sessionID
      }
      if let callerID, let targetID = outcome.result {
        try requireTimerAccessUnlocked(sourceID: callerID, targetID: targetID)
      }
    }
  }

  /// An occurrence keeps the same delivery ID across retries/restarts. The dispatcher
  /// reserves that ID before sending and settles it before advancing the timer.
  public func dueSessionTimers(now: Date = Date()) throws -> [WorkspaceSessionTimer] {
    try transaction {
      var due: [WorkspaceSessionTimer] = []
      for var timer in try timersUnlocked() where !timer.isPaused && timer.nextFireAt <= now {
        guard try sessionToolsUnlocked(timer.sessionID).enabled.contains(.timers) else { continue }
        if timer.pendingDeliveryID == nil {
          timer.pendingDeliveryID = UUID().uuidString.lowercased()
          try toolsExecuteUnlocked("UPDATE workspace_session_timers SET pending_delivery_id=? WHERE id=?", [timer.pendingDeliveryID, timer.id])
        }
        due.append(timer)
      }
      return due
    }
  }

  /// Revalidate after an async wait: a pause, deletion or capability revocation wins.
  public func isTimerOccurrenceActive(id: String, deliveryID: String) throws -> Bool {
    try withLock {
      guard let timer = try timersUnlocked().first(where: { $0.id == id }), !timer.isPaused,
            timer.pendingDeliveryID == deliveryID else { return false }
      return try sessionToolsUnlocked(timer.sessionID).enabled.contains(.timers)
    }
  }

  public func finishTimerOccurrence(id: String, deliveryID: String, now: Date = Date()) throws {
    try transaction {
      guard let timer = try timersUnlocked().first(where: { $0.id == id }), !timer.isPaused,
            timer.pendingDeliveryID == deliveryID else { return }
      if let interval = timer.intervalSeconds {
        // Coalesce missed firings, including time while the application was closed.
        let skipped = max(1, floor(now.timeIntervalSince(timer.nextFireAt) / interval) + 1)
        let next = timer.nextFireAt.addingTimeInterval(skipped * interval)
        try toolsExecuteUnlocked("UPDATE workspace_session_timers SET next_fire_at=?,pending_delivery_id=NULL WHERE id=?", [String(next.timeIntervalSince1970), id])
      } else {
        try toolsExecuteUnlocked("UPDATE workspace_session_timers SET is_paused=1,pending_delivery_id=NULL WHERE id=?", [id])
      }
    }
  }
}
