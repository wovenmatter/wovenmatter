import Foundation
import SQLite3
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  public func listAgentNotes(callerID: String, search: String? = nil, folderID: String? = nil,
                              after: Int64 = Int64.max, limit: Int = 50,
                              newestFirst: Bool = true) throws -> GatewayJSONValue {
    try withLock {
      try requireToolUnlocked(.notes, sessionID: callerID)
      guard after >= 0, (1...200).contains(limit) else { throw WorkspaceToolError.invalid("Invalid pagination.") }
      let operatorID = try localMutationOperatorIDUnlocked()
      var values: [String?] = [operatorID, String(after)]
      var sql = "SELECT rowid AS sequence,id,title,folder_id,CASE WHEN json_valid(content) THEN coalesce(json_extract(content,'$.kind'),'note') ELSE 'note' END AS kind,snippet,updated_at FROM notes WHERE user_id=? AND rowid \(newestFirst ? "<" : ">") ? AND deleted_at IS NULL"
      if let folderID { sql += " AND folder_id=?"; values.append(folderID) }
      if let search { sql += " AND (instr(lower(title),lower(?))>0 OR instr(lower(content),lower(?))>0)"; values += [search, search] }
      sql += " ORDER BY rowid \(newestFirst ? "DESC" : "ASC") LIMIT ?"; values.append(String(limit + 1))
      var rows = try historyRowsUnlocked(sql, values: values)
      let more = rows.count > limit
      if more { rows.removeLast() }
      return .object(["rows": .array(rows), "hasMore": .bool(more), "nextCursor": rows.last?.objectValue?["sequence"] ?? .number(Double(after))])
    }
  }

  public func listAgentFolders(callerID: String, requiredTool: WorkspaceToolGroup = .sessions,
                               after: Int64 = 0, limit: Int = 100) throws -> GatewayJSONValue {
    try withLock {
      guard requiredTool == .sessions || requiredTool == .notes else {
        throw WorkspaceToolError.invalid("Folders are available through Notes or Session management.")
      }
      try requireToolUnlocked(requiredTool, sessionID: callerID)
      guard after >= 0, (1...200).contains(limit) else { throw WorkspaceToolError.invalid("Invalid pagination.") }
      let operatorID = try localMutationOperatorIDUnlocked()
      var rows = try historyRowsUnlocked(
        "SELECT id,name,position FROM folders WHERE user_id=? ORDER BY position,id LIMIT ? OFFSET ?",
        values: [operatorID, String(limit + 1), String(after)])
      let more = rows.count > limit
      if more { rows.removeLast() }
      let (next, overflow) = after.addingReportingOverflow(Int64(rows.count))
      guard !overflow else { throw WorkspaceToolError.invalid("Invalid pagination.") }
      return .object(["rows": .array(rows), "hasMore": .bool(more),
        "nextCursor": .number(Double(next))])
    }
  }

  public func listAgentCalendar(callerID: String, since: Date? = nil, until: Date? = nil,
                                 after: Int64 = 0, limit: Int = 100) throws -> GatewayJSONValue {
    try withLock {
      try requireToolUnlocked(.calendar, sessionID: callerID)
      guard after >= 0, (1...200).contains(limit) else { throw WorkspaceToolError.invalid("Invalid pagination.") }
      let operatorID = try localMutationOperatorIDUnlocked()
      var sql = "SELECT rowid AS sequence,id,kind,title,description,starts_at,ends_at,all_day,status,source,created_at,updated_at,json(calendar_json) AS calendar FROM dashboard_calendar_items WHERE user_id=? AND deleted_at IS NULL AND rowid>?"
      var values: [String?] = [operatorID, String(after)]
      if let since { sql += " AND (json_extract(calendar_json,'$.recurrence') IS NOT NULL OR coalesce(ends_at,starts_at)>=?)"; values.append(Self.timestamp(since)) }
      if let until { sql += " AND starts_at<=?"; values.append(Self.timestamp(until)) }
      sql += " ORDER BY rowid LIMIT ?"; values.append(String(limit + 1))
      var rows = try historyRowsUnlocked(sql, values: values)
      rows = try rows.map { value in
        guard var row = value.objectValue, let json = row["calendar"]?.stringValue else { return value }
        row["calendar"] = try JSONDecoder().decode(GatewayJSONValue.self, from: Data(json.utf8))
        return .object(row)
      }
      let more = rows.count > limit
      if more { rows.removeLast() }
      return .object(["rows": .array(rows), "hasMore": .bool(more), "nextCursor": rows.last?.objectValue?["sequence"] ?? .number(Double(after))])
    }
  }

  public func saveAgentCalendar(callerID: String, id: String = UUID().uuidString.lowercased(),
                                 creating: Bool, title: String, details: String?,
                                 startsAt: Date, endsAt: Date?, allDay: Bool, requestID: String? = nil) throws -> String {
    try saveCalendarEvent(id: id, draft: .init(title: title, details: details ?? "",
      startsAt: startsAt, endsAt: endsAt, allDay: allDay), creating: creating,
      callerID: callerID, requestID: requestID)
  }

  public func removeAgentCalendar(callerID: String, id: String, requestID: String? = nil) throws {
    try deleteCalendarEvent(id: id, callerID: callerID, requestID: requestID)
  }
}
