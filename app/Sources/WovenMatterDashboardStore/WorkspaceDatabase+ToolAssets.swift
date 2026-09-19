import Foundation
import SQLite3
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  public func listAgentNotes(callerID: String, search: String? = nil, folderID: String? = nil,
                              after: Int64 = 0, limit: Int = 50) throws -> GatewayJSONValue {
    try withLock {
      try requireToolUnlocked(.notes, sessionID: callerID)
      guard after >= 0, (1...200).contains(limit) else { throw WorkspaceToolError.invalid("Invalid pagination.") }
      let operatorID = try localMutationOperatorIDUnlocked()
      var values: [String?] = [operatorID, String(after)]
      var sql = "SELECT rowid AS sequence,id,title,folder_id,snippet,updated_at FROM notes WHERE user_id=? AND rowid>? AND deleted_at IS NULL"
      if let folderID { sql += " AND folder_id=?"; values.append(folderID) }
      if let search { sql += " AND (instr(lower(title),lower(?))>0 OR instr(lower(snippet),lower(?))>0)"; values += [search, search] }
      sql += " ORDER BY rowid LIMIT ?"; values.append(String(limit + 1))
      var rows = try historyRowsUnlocked(sql, values: values)
      let more = rows.count > limit
      if more { rows.removeLast() }
      return .object(["rows": .array(rows), "hasMore": .bool(more), "nextCursor": rows.last?.objectValue?["sequence"] ?? .number(Double(after))])
    }
  }

  public func listAgentFolders(callerID: String) throws -> GatewayJSONValue {
    try withLock {
      try requireToolUnlocked(.sessions, sessionID: callerID)
      let operatorID = try localMutationOperatorIDUnlocked()
      return .array(try historyRowsUnlocked("SELECT id,name,position FROM folders WHERE user_id=? ORDER BY position,id", values: [operatorID]))
    }
  }

  public func listAgentCalendar(callerID: String, since: Date? = nil, until: Date? = nil,
                                 after: Int64 = 0, limit: Int = 100) throws -> GatewayJSONValue {
    try withLock {
      try requireToolUnlocked(.calendar, sessionID: callerID)
      guard after >= 0, (1...200).contains(limit) else { throw WorkspaceToolError.invalid("Invalid pagination.") }
      let operatorID = try localMutationOperatorIDUnlocked()
      var sql = "SELECT rowid AS sequence,id,kind,title,description,starts_at,ends_at,all_day,status,source,updated_at FROM dashboard_calendar_items WHERE user_id=? AND rowid>?"
      var values: [String?] = [operatorID, String(after)]
      if let since { sql += " AND coalesce(ends_at,starts_at)>=?"; values.append(Self.timestamp(since)) }
      if let until { sql += " AND starts_at<=?"; values.append(Self.timestamp(until)) }
      sql += " ORDER BY rowid LIMIT ?"; values.append(String(limit + 1))
      var rows = try historyRowsUnlocked(sql, values: values)
      let more = rows.count > limit
      if more { rows.removeLast() }
      return .object(["rows": .array(rows), "hasMore": .bool(more), "nextCursor": rows.last?.objectValue?["sequence"] ?? .number(Double(after))])
    }
  }

  /// Full access is rechecked in the same transaction as the write.
  public func saveAgentCalendar(callerID: String, id: String = UUID().uuidString.lowercased(),
                                 creating: Bool, title: String, details: String?,
                                 startsAt: Date, endsAt: Date?, allDay: Bool, requestID: String? = nil) throws -> String {
    guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, title.utf8.count <= 4_096,
          (details?.utf8.count ?? 0) <= 65_536, startsAt.timeIntervalSince1970.isFinite,
          endsAt.map({ $0.timeIntervalSince1970.isFinite && $0 > startsAt }) ?? true else {
      throw WorkspaceToolError.invalid("A calendar event needs a title and valid dates.")
    }
    return try transaction {
      try requireToolUnlocked(.calendar, sessionID: callerID, writesCalendar: true)
      return try performToolMutationUnlocked(callerID: callerID, requestID: requestID,
        operation: creating ? "calendar.create" : "calendar.update",
        input: [id, title, details, String(startsAt.timeIntervalSince1970), endsAt.map { String($0.timeIntervalSince1970) }, allDay ? "true" : "false"]) {
        let operatorID = try localMutationOperatorIDUnlocked()
        let now = Self.timestamp(Date())
        if creating {
          guard UUID(uuidString: id) != nil else { throw WorkspaceToolError.invalid("An event ID must be a UUID.") }
          try toolsExecuteUnlocked("""
            INSERT INTO dashboard_calendar_items(id,user_id,kind,title,description,starts_at,ends_at,all_day,status,source,created_at,updated_at)
            VALUES(?,?,'event',?,?,?,?,?,'scheduled',?,?,?)
            """, [id, operatorID, title, details, Self.timestamp(startsAt), endsAt.map(Self.timestamp), allDay ? "1" : "0", "session:" + callerID, now, now])
        } else {
          try toolsExecuteUnlocked("""
            UPDATE dashboard_calendar_items SET title=?,description=?,starts_at=?,ends_at=?,all_day=?,updated_at=?
            WHERE id=? AND user_id=? AND kind='event'
            """, [title, details, Self.timestamp(startsAt), endsAt.map(Self.timestamp), allDay ? "1" : "0", now, id, operatorID])
          guard changedRowCountUnlocked == 1 else { throw WorkspaceToolError.invalid("Calendar event not found.") }
        }
        try recordHistoryUnlocked(.init(conversationID: callerID, harness: "wovenmatter", kind: "calendar.write",
          payload: try toolsJSON(["eventID": id, "action": creating ? "create" : "update"])))
        return id
      }.result
    }
  }

  public func removeAgentCalendar(callerID: String, id: String, requestID: String? = nil) throws {
    try transaction {
      try requireToolUnlocked(.calendar, sessionID: callerID, writesCalendar: true)
      _ = try performToolMutationUnlocked(callerID: callerID, requestID: requestID,
        operation: "calendar.remove", input: id) {
        let operatorID = try localMutationOperatorIDUnlocked()
        try toolsExecuteUnlocked("DELETE FROM dashboard_calendar_items WHERE id=? AND user_id=? AND kind='event'", [id, operatorID])
        guard changedRowCountUnlocked == 1 else { throw WorkspaceToolError.invalid("Calendar event not found.") }
        try recordHistoryUnlocked(.init(conversationID: callerID, harness: "wovenmatter", kind: "calendar.remove", payload: try toolsJSON(["eventID": id])))
        return id
      }
    }
  }
}
