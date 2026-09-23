import Foundation
import CryptoKit
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  public func calendarEvent(id: String, callerID: String) throws -> WorkspaceCalendarItemRecord {
    try withLock {
      try requireToolUnlocked(.calendar, sessionID: callerID)
      guard let event = try calendarItemsUnlocked().first(where: { $0.id == id }) else { throw WorkspaceToolError.invalid("Calendar event not found.") }
      return event
    }
  }

  /// Resolve retries before reading today's event/defaults, including after deletion.
  public func replayCalendarRequest(callerID: String, requestID: String, input: String) throws -> String? {
    try withLock {
      try requireToolUnlocked(.calendar, sessionID: callerID, writesCalendar: true)
      guard let row = try historyRowsUnlocked("SELECT operation,input_digest,result_json FROM workspace_tool_mutations WHERE source_id=? AND request_id=?",
        values: [callerID, requestID]).first?.objectValue else { return nil }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let digest = SHA256.hash(data: try encoder.encode(input)).map { String(format: "%02x", $0) }.joined()
      guard row["operation"]?.stringValue?.hasPrefix("calendar.") == true, row["input_digest"]?.stringValue == digest,
            let json = row["result_json"]?.stringValue else { throw WorkspaceToolError.invalid("This request ID was already used for a different mutation.") }
      return try JSONDecoder().decode(String.self, from: Data(json.utf8))
    }
  }
  func migrateCalendar() throws {
    try transaction {
      let columns = Set(try historyRowsUnlocked("PRAGMA table_info(dashboard_calendar_items)", values: [])
        .compactMap { $0.objectValue?["name"]?.stringValue })
      for (name, type) in [("calendar_json", "TEXT"), ("next_fire_at", "REAL"),
                           ("task_session_id", "TEXT"), ("deleted_at", "TEXT")] where !columns.contains(name) {
        try executeUnlocked("ALTER TABLE dashboard_calendar_items ADD COLUMN \(name) \(type)")
      }
      try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS workspace_calendar_runs(
          id TEXT PRIMARY KEY, event_id TEXT NOT NULL REFERENCES dashboard_calendar_items(id),
          scheduled_at TEXT NOT NULL, occurrence_index INTEGER NOT NULL, session_id TEXT NOT NULL,
          task_json TEXT NOT NULL, title TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',
          error TEXT, retry_after REAL, coalesced_through REAL NOT NULL, hidden_at TEXT,
          UNIQUE(event_id,scheduled_at));
        CREATE INDEX IF NOT EXISTS workspace_calendar_due ON dashboard_calendar_items(next_fire_at) WHERE deleted_at IS NULL;
        CREATE INDEX IF NOT EXISTS workspace_calendar_run_event ON workspace_calendar_runs(event_id);
        CREATE INDEX IF NOT EXISTS workspace_calendar_pending_runs ON workspace_calendar_runs(status) WHERE status='pending';
        CREATE TABLE IF NOT EXISTS workspace_calendar_sessions(id TEXT PRIMARY KEY, configuration_json TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS workspace_calendar_remote_ownership(
          workspace_id TEXT PRIMARY KEY, state TEXT NOT NULL CHECK(state IN ('pending','remote')));
        CREATE TABLE IF NOT EXISTS workspace_calendar_remote_receipts(
          id TEXT PRIMARY KEY, workspace_id TEXT NOT NULL, session_id TEXT NOT NULL, payload_json TEXT NOT NULL);

        """)
      let runColumns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_calendar_runs)", values: [])
        .compactMap { $0.objectValue?["name"]?.stringValue })
      if !runColumns.contains("hidden_at") {
        try executeUnlocked("ALTER TABLE workspace_calendar_runs ADD COLUMN hidden_at TEXT")
      }
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS workspace_calendar_runs_revision_\(operation.lowercased())
          AFTER \(operation) ON workspace_calendar_runs BEGIN
            UPDATE desktop_dashboard_revision SET revision=revision+1 WHERE singleton=1;
          END;
          """)
      }
      for row in try historyRowsUnlocked("SELECT id,source FROM dashboard_calendar_items WHERE calendar_json IS NULL", values: []) {
        guard let id = row.objectValue?["id"]?.stringValue else { continue }
        let source = row.objectValue?["source"]?.stringValue ?? "user"
        let author = try calendarAuthorUnlocked(source.hasPrefix("session:") ? String(source.dropFirst(8)) : nil)
        try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET calendar_json=? WHERE id=?",
          [try toolsJSON(WorkspaceCalendarDetails(createdBy: author)), id])
      }
    }
  }

  func calendarAuthorUnlocked(_ callerID: String?) throws -> WorkspaceCalendarAuthor {
    guard let callerID else { return .init() }
    let row = try historyRowsUnlocked("""
      SELECT c.title,coalesce(s.runtime_kind,c.agent_codename) AS agent
      FROM dashboard_conversations c LEFT JOIN desktop_local_acp_sessions s ON s.conversation_id=c.id WHERE c.id=?
      """, values: [callerID]).first?.objectValue
    return .init(sessionID: callerID, agent: row?["agent"]?.stringValue, sessionTitle: row?["title"]?.stringValue)
  }

  func calendarItemsUnlocked(includeDeleted: Bool = false) throws -> [WorkspaceCalendarItemRecord] {
    guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked() else { return [] }
    return try decodeCanonicalRowsUnlocked("""
      SELECT json_object('id',id,'user_id',user_id,'kind',kind,'title',title,'description',description,
        'starts_at',starts_at,'ends_at',ends_at,'all_day',all_day,'status',status,'source',source,
        'created_at',created_at,'updated_at',updated_at,'calendar',json(calendar_json))
      FROM dashboard_calendar_items WHERE user_id=? \(includeDeleted ? "" : "AND deleted_at IS NULL") ORDER BY starts_at,id
      """, operatorID: operatorID, as: WorkspaceCalendarItemRecord.self)
  }

  private struct CalendarMutationInput: Codable {
    var id: String; var draft: WorkspaceCalendarDraft; var creating: Bool
    var revision: Int?; var detachedOccurrence: Int?
  }

  /// The native editor and agent CLI share validation, revision checks,
  /// attribution, detachment, and retry receipts.
  @discardableResult
  public func saveCalendarEvent(id: String = UUID().uuidString.lowercased(), draft: WorkspaceCalendarDraft,
      creating: Bool, expectedRevision: Int? = nil, detaching occurrence: Int? = nil,
      callerID: String? = nil, requestID: String? = nil, requestInput: String? = nil,
      now: Date = Date()) throws -> String {
    let draft = try draft.validated()
    guard UUID(uuidString: id) != nil else { throw WorkspaceToolError.invalid("An event ID must be a UUID.") }
    return try transaction {
      if let callerID {
        try requireToolUnlocked(.calendar, sessionID: callerID, writesCalendar: true)
        if draft.task != nil { try requireToolUnlocked(.sessions, sessionID: callerID) }
      }
      let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
      let input = try requestInput ?? String(decoding: encoder.encode(CalendarMutationInput(id: id, draft: draft, creating: creating,
        revision: expectedRevision, detachedOccurrence: occurrence)), as: UTF8.self)
      return try performToolMutationUnlocked(callerID: callerID, requestID: requestID,
        operation: creating ? "calendar.create" : occurrence == nil ? "calendar.update" : "calendar.detach", input: input) {
        let existing = try calendarItemsUnlocked().first { $0.id == id }
        let idExists = try !historyRowsUnlocked("SELECT 1 FROM dashboard_calendar_items WHERE id=?", values: [id]).isEmpty
        guard creating ? !idExists : existing != nil else { throw WorkspaceToolError.invalid("Calendar event not found or already exists.") }
        if let expectedRevision, existing?.calendar.revision != expectedRevision {
          throw WorkspaceToolError.invalid("This event changed. Reopen it before saving your changes.")
        }
        if let previousWorkspace = existing?.calendar.task?.configuration.workspaceID,
           previousWorkspace != draft.task?.configuration.workspaceID,
           try remoteCalendarWorkspaceIDsUnlocked().contains(previousWorkspace.uuidString.lowercased()) {
          throw WorkspaceToolError.invalid("Turn off background execution for this workspace before moving its scheduled task to another workspace.")
        }
        if let task = draft.task { try validateFolderUnlocked(id: task.configuration.folderID, operatorID: localMutationOperatorIDUnlocked()) }
        let author = try calendarAuthorUnlocked(callerID)
        if let occurrence {
          guard var calendar = existing?.calendar, calendar.recurrence != nil,
                let existing, let detached = WorkspaceCalendarSchedule.occurrence(existing, index: occurrence) else {
            throw WorkspaceToolError.invalid("This recurring occurrence is no longer available.")
          }
          calendar.excludedOccurrences.insert(occurrence)
          calendar.editedBy = author; calendar.revision += 1
          try cancelCalendarRunsUnlocked(eventID: id, scheduledAt: detached.startsAt)
          try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET calendar_json=?,updated_at=? WHERE id=?",
            [try toolsJSON(calendar), Self.timestamp(now), id])
          var independent = draft; independent.recurrence = nil
          let newID = UUID().uuidString.lowercased()
          var newDetails = calendar
          newDetails.recurrence = nil; newDetails.excludedOccurrences = []; newDetails.revision = 0
          try writeCalendarEventUnlocked(id: newID, draft: independent, existing: nil, details: newDetails, now: now)
          // Preserve the session link if the detached occurrence already ran.
          try toolsExecuteUnlocked("""
            UPDATE workspace_calendar_runs SET event_id=?,occurrence_index=0
            WHERE event_id=? AND scheduled_at=? AND
              (coalesce((SELECT status FROM workspace_session_deliveries d WHERE d.id=workspace_calendar_runs.id),status)
                NOT IN ('pending','queued','cancelled') OR
               EXISTS(SELECT 1 FROM workspace_session_deliveries d WHERE d.id=workspace_calendar_runs.id AND d.transport_started=1))
            """,
            [newID, id, Self.timestamp(detached.startsAt)])
          if !(try calendarRunsUnlocked(eventID: newID)).isEmpty {
            try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET next_fire_at=NULL WHERE id=?", [newID])
          }
          return newID
        }
        var details = existing?.calendar ?? .init(createdBy: author)
        if existing != nil { details.editedBy = author; details.revision += 1 }
        if draft.recurrence == nil { details.excludedOccurrences = [] }
        if let existing {
          var previousDraft = WorkspaceCalendarDraft(existing)
          previousDraft.showsOnCalendar = draft.showsOnCalendar
          if existing.calendar.showsOnCalendar != draft.showsOnCalendar, try previousDraft.validated() == draft {
            // A display-only change must not cancel queued work, advance the
            // schedule, or replace the recurring session.
            details.showsOnCalendar = draft.showsOnCalendar
            try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET calendar_json=?,updated_at=? WHERE id=?",
              [try toolsJSON(details), Self.timestamp(now), id])
            if let callerID {
              try recordHistoryUnlocked(.init(conversationID: callerID, harness: "wovenmatter", kind: "calendar.write",
                payload: try toolsJSON(["eventID": id, "action": "update"])))
            }
            return id
          }
        }
        try cancelCalendarRunsUnlocked(eventID: id)
        try writeCalendarEventUnlocked(id: id, draft: draft, existing: existing, details: details, now: now)
        if let callerID {
          try recordHistoryUnlocked(.init(conversationID: callerID, harness: "wovenmatter", kind: "calendar.write",
            payload: try toolsJSON(["eventID": id, "action": creating ? "create" : "update"])))
        }
        return id
      }.result
    }
  }

  private func writeCalendarEventUnlocked(id: String, draft: WorkspaceCalendarDraft,
      existing: WorkspaceCalendarItemRecord?, details: WorkspaceCalendarDetails, now: Date) throws {
    var details = details
    details.timeZoneID = draft.timeZoneID; details.recurrence = draft.recurrence; details.task = draft.task
    details.showsOnCalendar = draft.task == nil || draft.showsOnCalendar
    let operatorID = try localMutationOperatorIDUnlocked()
    let stamp = Self.timestamp(now)
    // Match the precision of the canonical persisted start date. Comparing a
    // sub-millisecond draft against its rounded ISO timestamp can skip a task.
    var next: Date? = draft.task == nil ? nil : Self.date(Self.timestamp(draft.startsAt))
    let pastRuns = try calendarRunsUnlocked(eventID: id).filter { $0.status != "cancelled" }
    if draft.task != nil, existing != nil, !pastRuns.isEmpty {
      let event = WorkspaceCalendarItemRecord(id: id, userID: operatorID, kind: "event", title: draft.title,
        details: draft.details, startsAt: Self.timestamp(draft.startsAt), endsAt: draft.endsAt.map(Self.timestamp),
        allDay: draft.allDay, status: "scheduled", source: existing?.source ?? "user",
        createdAt: existing?.createdAt ?? stamp, updatedAt: stamp, calendar: details)
      next = WorkspaceCalendarSchedule.next(event, after: now)
    }
    let source = details.createdBy.sessionID.map { "session:" + $0 } ?? "user"
    try toolsExecuteUnlocked("""
      INSERT INTO dashboard_calendar_items(id,user_id,kind,title,description,starts_at,ends_at,all_day,status,source,created_at,updated_at,calendar_json,next_fire_at)
      VALUES(?,?,'event',?,?,?,?,?,'scheduled',?,?,?,?,?)
      ON CONFLICT(id) DO UPDATE SET title=excluded.title,description=excluded.description,starts_at=excluded.starts_at,
        ends_at=excluded.ends_at,all_day=excluded.all_day,updated_at=excluded.updated_at,
        calendar_json=excluded.calendar_json,next_fire_at=excluded.next_fire_at,
        task_session_id=CASE WHEN json_extract(dashboard_calendar_items.calendar_json,'$.task.configuration.runtimeKind') IS json_extract(excluded.calendar_json,'$.task.configuration.runtimeKind')
          AND json_extract(dashboard_calendar_items.calendar_json,'$.task.configuration.workspaceID') IS json_extract(excluded.calendar_json,'$.task.configuration.workspaceID')
          AND json_extract(dashboard_calendar_items.calendar_json,'$.task.configuration.nativeWorkingDirectory') IS json_extract(excluded.calendar_json,'$.task.configuration.nativeWorkingDirectory')
          THEN task_session_id ELSE NULL END
      """, [id, operatorID, draft.title, draft.details.isEmpty ? nil : draft.details, Self.timestamp(draft.startsAt),
        draft.endsAt.map(Self.timestamp), draft.allDay ? "1" : "0", source, existing?.createdAt ?? stamp, stamp,
        try toolsJSON(details), next.map { String($0.timeIntervalSince1970) }])
  }

  public func deleteCalendarEvent(id: String, occurrence: Int? = nil, expectedRevision: Int? = nil,
      callerID: String? = nil, requestID: String? = nil, requestInput: String? = nil, now: Date = Date()) throws {
    try transaction {
      if let callerID { try requireToolUnlocked(.calendar, sessionID: callerID, writesCalendar: true) }
      _ = try performToolMutationUnlocked(callerID: callerID, requestID: requestID, operation: "calendar.remove",
        input: requestInput ?? [id, occurrence.map(String.init) ?? "", expectedRevision.map(String.init) ?? ""].joined(separator: ":")) {
        guard let event = try calendarItemsUnlocked().first(where: { $0.id == id }) else { throw WorkspaceToolError.invalid("Calendar event not found.") }
        if let expectedRevision, expectedRevision != event.calendar.revision { throw WorkspaceToolError.invalid("This event changed. Reopen it before deleting.") }
        if let occurrence {
          guard event.calendar.recurrence != nil else { throw WorkspaceToolError.invalid("This event is not recurring.") }
          guard let value = WorkspaceCalendarSchedule.occurrence(event, index: occurrence) else { throw WorkspaceToolError.invalid("Occurrence not found.") }
          var details = event.calendar
          details.excludedOccurrences.insert(occurrence); details.editedBy = try calendarAuthorUnlocked(callerID); details.revision += 1
          try cancelCalendarRunsUnlocked(eventID: id, scheduledAt: value.startsAt)
          // Hide the removed occurrence without rewriting its delivery outcome.
          try toolsExecuteUnlocked("UPDATE workspace_calendar_runs SET hidden_at=? WHERE event_id=? AND scheduled_at=?",
            [Self.timestamp(now), id, Self.timestamp(value.startsAt)])
          try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET calendar_json=?,updated_at=? WHERE id=?", [try toolsJSON(details), Self.timestamp(now), id])
        } else {
          try cancelCalendarRunsUnlocked(eventID: id)
          try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET deleted_at=?,next_fire_at=NULL WHERE id=?", [Self.timestamp(now), id])
        }
        if let callerID { try recordHistoryUnlocked(.init(conversationID: callerID, harness: "wovenmatter", kind: "calendar.remove", payload: try toolsJSON(["eventID": id]))) }
        return id
      }
    }
  }

  private func cancelCalendarRunsUnlocked(eventID: String, scheduledAt: Date? = nil) throws {
    for run in try calendarRunsUnlocked(eventID: eventID) where run.isPending && (scheduledAt == nil || run.scheduledAt == scheduledAt) {
      // Once transport starts, preserve the historical outcome and session link.
      let started = try historyRowsUnlocked("SELECT transport_started FROM workspace_session_deliveries WHERE id=? AND status!='queued'", values: [run.id])
        .first?.objectValue?["transport_started"]?.intValue == 1
      guard !started else { continue }
      try toolsExecuteUnlocked("UPDATE workspace_calendar_runs SET status='cancelled' WHERE id=?", [run.id])
      try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET status='cancelled' WHERE id=?", [run.id])
    }
  }

  public func calendarRuns() throws -> [WorkspaceCalendarRun] { try withLock { try calendarRunsUnlocked(visibleOnly: true) } }

  func calendarRunsUnlocked(eventID: String? = nil, unfinishedOnly: Bool = false, visibleOnly: Bool = false) throws -> [WorkspaceCalendarRun] {
    let rows = try historyRowsUnlocked("""
      SELECT r.*,coalesce(d.status,r.status) AS delivery_status FROM workspace_calendar_runs r
      LEFT JOIN workspace_session_deliveries d ON d.id=r.id
      WHERE \(visibleOnly ? "r.hidden_at IS NULL" : "1=1") \(eventID == nil ? "" : "AND r.event_id=?") \(unfinishedOnly ? "AND r.status='pending'" : "") ORDER BY r.scheduled_at,r.id
      """, values: eventID.map { [$0] } ?? [])
    return try rows.map { value in
      guard let r = value.objectValue, let id = r["id"]?.stringValue, let eventID = r["event_id"]?.stringValue,
            let scheduled = r["scheduled_at"]?.stringValue.flatMap(Self.date), let json = r["task_json"]?.stringValue,
            let sessionID = r["session_id"]?.stringValue else { throw WorkspaceDatabaseError.corruptRow }
      return WorkspaceCalendarRun(id: id, eventID: eventID, occurrenceIndex: r["occurrence_index"]?.intValue ?? 0,
        scheduledAt: scheduled, sessionID: sessionID, task: try JSONDecoder().decode(WorkspaceCalendarTask.self, from: Data(json.utf8)),
        status: r["delivery_status"]?.stringValue ?? "pending", error: r["error"]?.stringValue,
        title: r["title"]?.stringValue ?? "Scheduled task")
    }
  }

  /// Reserve one latest missed occurrence per series, and every overdue one-off.
  /// Retain a pending occurrence through preparation errors and process restarts.
  public func dueCalendarRuns(now: Date = Date()) throws -> [WorkspaceCalendarRun] {
    try transaction {
      let dueIDs = Set(try historyRowsUnlocked("SELECT id FROM dashboard_calendar_items WHERE next_fire_at<=? AND deleted_at IS NULL",
        values: [String(now.timeIntervalSince1970)]).compactMap { $0.objectValue?["id"]?.stringValue })
      let delegated = try remoteCalendarWorkspaceIDsUnlocked()
      let events = dueIDs.isEmpty ? [] : try calendarItemsUnlocked().filter {
        dueIDs.contains($0.id) && !delegated.contains($0.calendar.task?.configuration.workspaceID?.uuidString.lowercased() ?? "")
      }
      for event in events {
        guard let task = event.calendar.task, let start = event.startDate else { continue }
        let row = try historyRowsUnlocked("SELECT next_fire_at,task_session_id FROM dashboard_calendar_items WHERE id=?", values: [event.id]).first?.objectValue
        guard let next = row?["next_fire_at"]?.doubleValue, next <= now.timeIntervalSince1970 else { continue }
        let runs = try calendarRunsUnlocked(eventID: event.id)
        if runs.contains(where: { $0.isPending }) { continue }
        var index = WorkspaceCalendarSchedule.index(onOrBefore: now, start: start, recurrence: event.calendar.recurrence, timeZoneID: event.calendar.timeZoneID) ?? 0
        while index >= 0 && event.calendar.excludedOccurrences.contains(index) { index -= 1 }
        guard let occurrence = WorkspaceCalendarSchedule.occurrence(event, index: index), occurrence.startsAt.timeIntervalSince1970 >= next,
              !runs.contains(where: { $0.scheduledAt == occurrence.startsAt && $0.status != "cancelled" }) else {
          try advanceCalendarUnlocked(event, after: now); continue
        }
        let reusable = task.sessionMode == .same && event.calendar.recurrence != nil ? row?["task_session_id"]?.stringValue : nil
        let sessionID = reusable ?? UUID().uuidString.lowercased()
        let id = UUID().uuidString.lowercased()
        try toolsExecuteUnlocked("""
          INSERT INTO workspace_calendar_runs(id,event_id,scheduled_at,occurrence_index,session_id,task_json,title,coalesced_through)
          VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(event_id,scheduled_at) DO UPDATE SET
            id=excluded.id,occurrence_index=excluded.occurrence_index,session_id=excluded.session_id,
            task_json=excluded.task_json,title=excluded.title,status='pending',error=NULL,retry_after=NULL,hidden_at=NULL,
            coalesced_through=excluded.coalesced_through
          WHERE workspace_calendar_runs.status='cancelled'
          """, [id, event.id, Self.timestamp(occurrence.startsAt), String(index), sessionID, try toolsJSON(task), event.title, String(now.timeIntervalSince1970)])
        // A series can keep its session ID through an edit before that session
        // is created. Its insertion settings must follow the newly reserved run.
        try toolsExecuteUnlocked("""
          INSERT INTO workspace_calendar_sessions(id,configuration_json) VALUES(?,?)
          ON CONFLICT(id) DO UPDATE SET configuration_json=excluded.configuration_json
          """, [sessionID, try toolsJSON(task.configuration)])
        if task.sessionMode == .same && event.calendar.recurrence != nil {
          try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET task_session_id=? WHERE id=?", [sessionID, event.id])
        }
      }
      let eligible = Set(try historyRowsUnlocked("""
        SELECT r.id FROM workspace_calendar_runs r LEFT JOIN workspace_session_deliveries d ON d.id=r.id
        WHERE r.status='pending' AND (r.retry_after IS NULL OR r.retry_after<=?)
          AND (d.retry_after IS NULL OR d.retry_after<=?)
        """, values: [String(now.timeIntervalSince1970), String(now.timeIntervalSince1970)]).compactMap { $0.objectValue?["id"]?.stringValue })
      return eligible.isEmpty ? [] : try calendarRunsUnlocked(unfinishedOnly: true).filter { $0.isPending && eligible.contains($0.id) && !delegated.contains($0.task.configuration.workspaceID?.uuidString.lowercased() ?? "") }
    }
  }

  private func advanceCalendarUnlocked(_ event: WorkspaceCalendarItemRecord, after now: Date) throws {
    let next = WorkspaceCalendarSchedule.next(event, after: now)
    try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET next_fire_at=? WHERE id=?", [next.map { String($0.timeIntervalSince1970) }, event.id])
  }

  public func isCalendarRunActive(_ id: String) throws -> Bool { try withLock { try calendarRunAuthorizedUnlocked(id) } }

  func calendarRunAuthorizedUnlocked(_ id: String) throws -> Bool {
    !(try historyRowsUnlocked("""
      SELECT 1 FROM workspace_calendar_runs r JOIN dashboard_calendar_items e ON e.id=r.event_id
      WHERE r.id=? AND r.status='pending' AND e.deleted_at IS NULL AND json_extract(e.calendar_json,'$.task') IS NOT NULL
      AND NOT EXISTS(SELECT 1 FROM workspace_calendar_remote_ownership o
        WHERE o.workspace_id=lower(json_extract(e.calendar_json,'$.task.configuration.workspaceID')))
      """, values: [id])).isEmpty
  }

  public func prepareCalendarDelivery(runID: String, now: Date = Date()) throws -> WorkspaceSessionDelivery {
    try transaction {
      guard try calendarRunAuthorizedUnlocked(runID), let run = try calendarRunsUnlocked(unfinishedOnly: true).first(where: { $0.id == runID }) else {
        throw WorkspaceToolError.invalid("This calendar task was changed or removed.")
      }
      try toolsExecuteUnlocked("UPDATE workspace_calendar_runs SET error=NULL,retry_after=NULL,coalesced_through=? WHERE id=?", [String(now.timeIntervalSince1970), runID])
      return try reserveToolDeliveryUnlocked(sourceID: run.sessionID, targetID: run.sessionID, text: run.task.prompt,
        requestID: run.id, kind: .calendar, purpose: run.title)
    }
  }

  public func deferCalendarRun(_ id: String, error: String, now: Date = Date()) throws {
    try transaction {
      try toolsExecuteUnlocked("UPDATE workspace_calendar_runs SET error=?,retry_after=? WHERE id=? AND status='pending'",
        [String(error.prefix(2_000)), String(now.addingTimeInterval(30).timeIntervalSince1970), id])
    }
  }

  public func settleCalendarRuns() throws {
    try transaction {
      for run in try calendarRunsUnlocked(unfinishedOnly: true) where ["accepted", "cancelled", "uncertain", "failed"].contains(run.status) {
        try toolsExecuteUnlocked("UPDATE workspace_calendar_runs SET status=?,error=NULL WHERE id=?", [run.status, run.id])
        let through = try historyRowsUnlocked("SELECT coalesced_through FROM workspace_calendar_runs WHERE id=?", values: [run.id])
          .first?.objectValue?["coalesced_through"]?.doubleValue.map(Date.init(timeIntervalSince1970:)) ?? run.scheduledAt
        let next = try historyRowsUnlocked("SELECT next_fire_at FROM dashboard_calendar_items WHERE id=?", values: [run.eventID])
          .first?.objectValue?["next_fire_at"]?.doubleValue
        // An edit may already have replaced this schedule while transport was in flight.
        if let next, next <= run.scheduledAt.timeIntervalSince1970,
           let event = try calendarItemsUnlocked().first(where: { $0.id == run.eventID }) {
          try advanceCalendarUnlocked(event, after: through)
        }
      }
    }
  }

  /// Called from the ordinary session-insertion transaction.
  func adoptCalendarSessionUnlocked(_ id: String) throws {
    guard let json = try historyRowsUnlocked("SELECT configuration_json FROM workspace_calendar_sessions WHERE id=?", values: [id])
      .first?.objectValue?["configuration_json"]?.stringValue else { return }
    let configuration = try JSONDecoder().decode(WorkspaceSessionCreationConfiguration.self, from: Data(json.utf8))
    try validateFolderUnlocked(id: configuration.folderID, operatorID: localMutationOperatorIDUnlocked())
    try toolsExecuteUnlocked("UPDATE dashboard_conversations SET title=?,folder_id=? WHERE id=?", [configuration.title, configuration.folderID, id])
    try toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET title=? WHERE conversation_id=?", [configuration.title, id])
    try toolsExecuteUnlocked("UPDATE workspace_session_tools SET enabled_json=?,defaults_applied=1 WHERE session_id=?", [try toolsJSON(configuration.tools.enabled), id])
  }
}

public enum RemoteCalendarExecutionOwnership: String, Codable, Sendable {
  case local, pending, remote
}

public struct RemoteCalendarScheduleExport: Sendable {
  public let event: WorkspaceCalendarItemRecord
  public let nextFireAt: Date?
  public let taskSessionID: String?
  public let nativeSessionID: String?
  public let runs: [WorkspaceCalendarRun]
}

extension WorkspaceDatabase {
  func remoteCalendarWorkspaceIDsUnlocked() throws -> Set<String> {
    Set(try historyRowsUnlocked("SELECT workspace_id FROM workspace_calendar_remote_ownership", values: [])
      .compactMap { $0.objectValue?["workspace_id"]?.stringValue })
  }

  public func remoteCalendarExecutionOwnership(workspaceID: UUID) throws -> RemoteCalendarExecutionOwnership {
    try withLock {
      let value = try historyRowsUnlocked("SELECT state FROM workspace_calendar_remote_ownership WHERE workspace_id=?",
        values: [workspaceID.uuidString.lowercased()]).first?.objectValue?["state"]?.stringValue
      return value.flatMap(RemoteCalendarExecutionOwnership.init(rawValue:)) ?? .local
    }
  }

  /// Persist pending BEFORE publication. An ambiguous response must remain pending
  /// until remote acknowledgement/reconciliation; reconnect never re-enables local execution.
  public func setRemoteCalendarExecutionOwnership(workspaceID: UUID, state: RemoteCalendarExecutionOwnership) throws {
    try transaction {
      let workspace = workspaceID.uuidString.lowercased()
      if state == .pending {
        let runs = try calendarRunsUnlocked().filter { $0.task.configuration.workspaceID == workspaceID }
        for run in runs where run.isPending {
          let started = try historyRowsUnlocked("SELECT transport_started FROM workspace_session_deliveries WHERE id=?", values: [run.id])
            .first?.objectValue?["transport_started"]?.intValue == 1
          guard !started else { throw WorkspaceToolError.invalid("Wait for the current scheduled task to finish before moving execution.") }
          try cancelCalendarRunsUnlocked(eventID: run.eventID, scheduledAt: run.scheduledAt)
        }
      }
      if state == .local {
        try toolsExecuteUnlocked("DELETE FROM workspace_calendar_remote_ownership WHERE workspace_id=?", [workspace])
      } else {
        try toolsExecuteUnlocked("INSERT INTO workspace_calendar_remote_ownership(workspace_id,state) VALUES(?,?) ON CONFLICT(workspace_id) DO UPDATE SET state=excluded.state", [workspace, state.rawValue])
      }
    }
  }

  /// Full replacement snapshot: deleted events are absent, so remote schedules
  /// removed on this Mac are removed during the next successful publication.
  public func remoteCalendarExecutionSnapshot(workspaceID: UUID) throws -> [RemoteCalendarScheduleExport] {
    try withLock {
      try calendarItemsUnlocked().filter { $0.calendar.task?.configuration.workspaceID == workspaceID }.map { event in
        let row = try historyRowsUnlocked("SELECT next_fire_at,task_session_id,(SELECT acp_session_id FROM desktop_local_acp_sessions WHERE conversation_id=task_session_id) AS native_session_id FROM dashboard_calendar_items WHERE id=?", values: [event.id]).first?.objectValue
        return RemoteCalendarScheduleExport(event: event,
          nextFireAt: row?["next_fire_at"]?.doubleValue.map(Date.init(timeIntervalSince1970:)),
          taskSessionID: row?["task_session_id"]?.stringValue,
          nativeSessionID: row?["native_session_id"]?.stringValue,
          runs: try calendarRunsUnlocked(eventID: event.id).filter { $0.status != "cancelled" })
      }
    }
  }

  /// Import immutable remote outcomes even after an event was deleted. The
  /// occurrence uniqueness key prevents a repeated receipt from creating a run.
  public func importRemoteCalendarRun(_ run: WorkspaceCalendarRun, workspaceID: UUID,
      coalescedThrough: Date? = nil, eventRevision: Int? = nil) throws {
    try transaction {
      guard run.task.configuration.workspaceID == workspaceID,
        try calendarItemsUnlocked(includeDeleted: true).contains(where: { $0.id == run.eventID }) else {
        throw WorkspaceToolError.invalid("Remote scheduled task does not belong to this workspace.")
      }
      try toolsExecuteUnlocked("""
        INSERT INTO workspace_calendar_runs(id,event_id,scheduled_at,occurrence_index,session_id,task_json,title,status,error,coalesced_through)
        VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(event_id,scheduled_at) DO UPDATE SET
          id=excluded.id,status=excluded.status,error=excluded.error,session_id=excluded.session_id
        WHERE workspace_calendar_runs.status IN ('pending','queued','cancelled')
        """, [run.id,run.eventID,Self.timestamp(run.scheduledAt),String(run.occurrenceIndex),run.sessionID,
          try toolsJSON(run.task),run.title,run.status,run.error,
          String((coalescedThrough ?? run.scheduledAt).timeIntervalSince1970)])
      try toolsExecuteUnlocked("INSERT INTO workspace_calendar_sessions(id,configuration_json) VALUES(?,?) ON CONFLICT(id) DO NOTHING",
        [run.sessionID,try toolsJSON(run.task.configuration)])
      if let event = try calendarItemsUnlocked().first(where: { $0.id == run.eventID }),
         event.calendar.revision == eventRevision,
         event.calendar.task?.configuration.workspaceID == workspaceID {
        if run.task.sessionMode == .same {
          try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET task_session_id=? WHERE id=?", [run.sessionID,run.eventID])
        }
        let row = try historyRowsUnlocked("SELECT next_fire_at FROM dashboard_calendar_items WHERE id=?", values: [run.eventID]).first?.objectValue
        if let next = row?["next_fire_at"]?.doubleValue, next <= run.scheduledAt.timeIntervalSince1970 {
          try advanceCalendarUnlocked(event, after: coalescedThrough ?? run.scheduledAt)
        }
      }
    }
  }
}

extension WorkspaceDatabase {
  /// Atomic transcript projection and receipt: a crash/repeated fetch cannot
  /// duplicate a prompt or assistant reply. Native updates are retained verbatim.
  public func importRemoteCalendarTranscript(receiptID: String, run: WorkspaceCalendarRun,
      workspaceID: UUID, workspaceName: String, ownerDeviceID: UUID,
      nativeSessionID: String?, updates: [GatewayJSONValue], error: String?, completedAt: Date) throws {
    try transaction {
      guard run.task.configuration.workspaceID == workspaceID,
            let conversationID = UUID(uuidString: run.sessionID) else {
        throw WorkspaceToolError.invalid("Invalid remote scheduled session.")
      }
      if try !historyRowsUnlocked("SELECT 1 FROM workspace_calendar_remote_receipts WHERE id=?", values: [receiptID]).isEmpty { return }
      let configuration = run.task.configuration
      let existing = try historyRowsUnlocked("SELECT remote_workspace_id,runtime_kind FROM desktop_local_acp_sessions WHERE conversation_id=?", values: [run.sessionID]).first?.objectValue
      if let existing {
        guard existing["remote_workspace_id"]?.stringValue?.lowercased() == workspaceID.uuidString.lowercased(),
              existing["runtime_kind"]?.stringValue == configuration.runtimeKind.rawValue else {
          throw WorkspaceToolError.invalid("Remote session identity conflicts with an existing session.")
        }
      } else {
        try toolsExecuteUnlocked("INSERT INTO workspace_calendar_sessions(id,configuration_json) VALUES(?,?) ON CONFLICT(id) DO NOTHING", [run.sessionID,try toolsJSON(configuration)])
        _ = try createRemoteACPSessionUnlocked(runtimeKind: configuration.runtimeKind,
          remoteWorkspaceID: workspaceID, remoteWorkspaceName: workspaceName,
          title: configuration.title, ownerDeviceID: ownerDeviceID, createdAt: run.scheduledAt,
          openCodeAssociation: configuration.runtimeKind == .opencode ? nativeSessionID.map { ("remote-workspace:" + workspaceID.uuidString.lowercased(),$0) } : nil,
          requestedConversationID: conversationID)
      }
      try toolsExecuteUnlocked("""
        UPDATE desktop_local_acp_sessions SET acp_session_id=coalesce(?,acp_session_id),model=?,thinking=?,permission=?,updated_at=?,revision=revision+1
        WHERE conversation_id=?
        """, [nativeSessionID,configuration.model,configuration.thinking,configuration.permission,Self.timestamp(completedAt),run.sessionID])
      // OpenCode's server remains its transcript owner; attaching the native
      // session above makes the existing synchronization path fetch its history.
      if configuration.runtimeKind != .opencode {
        let response = updates.compactMap { update -> String? in
          let object = update.objectValue?["update"]?.objectValue ?? update.objectValue
          guard object?["sessionUpdate"]?.stringValue == "agent_message_chunk" else { return nil }
          return object?["content"]?.objectValue?["text"]?.stringValue
        }.joined()
        let runID = UUID().uuidString.lowercased()
        let userID = UUID().uuidString.lowercased(), assistantID = UUID().uuidString.lowercased()
        let status = error == nil ? "completed" : "failed"
        let started = Self.timestamp(run.scheduledAt), finished = Self.timestamp(completedAt)
        for (id,role,content,stamp) in [(userID,"user",run.task.prompt,started),
          (assistantID,"assistant",response,Self.timestamp(run.scheduledAt.addingTimeInterval(0.001)))] {
          try toolsExecuteUnlocked("""
            INSERT INTO dashboard_messages(id,conversation_id,run_id,role,message_source,content,status,
              governing_plane,authority_kind,authority_device_id,authority_agent_id,created_at,updated_at,desktop_owned)
            SELECT ?,id,?,?,'local_acp',?,?,'wovenmatter_macos','device_owned',authority_device_id,agent_id,?,?,1
            FROM dashboard_conversations WHERE id=?
            """, [id,runID,role,content,role == "user" ? "completed" : status,stamp,finished,run.sessionID])
        }
        try toolsExecuteUnlocked("""
          INSERT INTO dashboard_runs(id,conversation_id,user_id,agent_id,agent_codename,governing_plane,authority_kind,
            authority_device_id,authority_agent_id,openclaw_session_key,user_message_id,assistant_message_id,status,
            started_at,created_at,updated_at,completed_at,error,desktop_owned)
          SELECT ?,id,user_id,agent_id,agent_codename,'wovenmatter_macos','device_owned',authority_device_id,agent_id,
            ?,?,?,?,?,?,?,?,?,1 FROM dashboard_conversations WHERE id=?
          """, [runID,nativeSessionID,userID,assistantID,status,started,started,finished,finished,error,run.sessionID])
        try toolsExecuteUnlocked("UPDATE dashboard_runs SET status='running' WHERE id=?", [runID])
        var thoughtSequence = 0
        var activeThought: String?
        for update in updates {
          let value = update.objectValue?["update"] ?? update
          guard let object = value.objectValue, let kind = object["sessionUpdate"]?.stringValue else { continue }
          let raw = try toolsJSON(value)
          var activity: AgentRunActivity?
          var appending = false
          if kind == "agent_thought_chunk" {
            if activeThought == nil { thoughtSequence += 1; activeThought = "thought-\(thoughtSequence)" }
            let id = object["_meta"]?.objectValue?["wovenThoughtID"]?.stringValue ?? activeThought!
            activity = .init(id: id, kind: .thought, title: "Thinking", status: "completed",
              content: object["content"]?.objectValue?["text"]?.stringValue, contentIsDelta: true, rawPayloadJSON: raw)
            appending = true
          } else {
            activeThought = nil
            if ["tool_call", "tool_call_update"].contains(kind), let id = object["toolCallId"]?.stringValue {
              activity = .init(id: id, kind: .tool, title: object["title"]?.stringValue,
                status: object["status"]?.stringValue, toolName: object["kind"]?.stringValue,
                rawInputJSON: try object["rawInput"].map(toolsJSON),
                rawOutputJSON: try object["rawOutput"].map(toolsJSON), rawPayloadJSON: raw)
            } else if kind == "plan" {
              let entries = object["entries"]?.arrayValue?.compactMap { entry -> AgentRunPlanEntry? in
                guard let fields = entry.objectValue, let content = fields["content"]?.stringValue,
                      let status = fields["status"]?.stringValue else { return nil }
                return .init(content: content, priority: fields["priority"]?.stringValue, status: status)
              } ?? []
              activity = .init(id: "plan", kind: .plan, title: "Plan", planEntries: entries, rawPayloadJSON: raw)
            }
          }
          if let activity {
            try upsertDeviceOwnedRunActivityUnlocked(runID: runID, activity: activity,
              appendingContent: appending, updatedAt: completedAt)
          }
        }
        try toolsExecuteUnlocked("UPDATE dashboard_runs SET status=? WHERE id=?", [status,runID])
        try toolsExecuteUnlocked("""
          UPDATE dashboard_conversations SET last_message_preview=?,last_message_at=max(coalesce(last_message_at,''),?),updated_at=max(updated_at,?) WHERE id=?
          """, [String((response.isEmpty ? run.task.prompt : response).prefix(200)),finished,finished,run.sessionID])
      }
      try toolsExecuteUnlocked("INSERT INTO workspace_calendar_remote_receipts(id,workspace_id,session_id,payload_json) VALUES(?,?,?,?)",
        [receiptID,workspaceID.uuidString.lowercased(),run.sessionID,try toolsJSON(updates)])
    }
  }
}

extension WorkspaceDatabase {
  /// Call only after the remote gateway confirms it is disabled and its result
  /// journal is drained. Keep the durable fence until this checkpoint is saved.
  public func restoreRemoteCalendarExecutionCheckpoint(workspaceID: UUID, schedules: [RemoteTaskGatewaySchedule]) throws {
    try transaction {
      guard try remoteCalendarWorkspaceIDsUnlocked().contains(workspaceID.uuidString.lowercased()) else {
        throw WorkspaceToolError.invalid("Remote scheduled task execution is not fenced.")
      }
      let events = try calendarItemsUnlocked()
      for schedule in schedules {
        guard schedule.task.configuration.workspaceID == workspaceID,
              let event = events.first(where: { $0.id == schedule.id }),
              event.calendar.task?.configuration.workspaceID == workspaceID,
              event.calendar.revision == schedule.revision else { continue }
        try toolsExecuteUnlocked("UPDATE dashboard_calendar_items SET next_fire_at=?,task_session_id=? WHERE id=?",
          [schedule.nextFireAt.map { String($0.timeIntervalSince1970) },schedule.taskSessionID,schedule.id])
        if let session = schedule.taskSessionID, let native = schedule.nativeSessionID {
          try toolsExecuteUnlocked("UPDATE desktop_local_acp_sessions SET acp_session_id=? WHERE conversation_id=? AND remote_workspace_id=?",
            [native,session,workspaceID.uuidString.lowercased()])
        }
      }
    }
  }
}
