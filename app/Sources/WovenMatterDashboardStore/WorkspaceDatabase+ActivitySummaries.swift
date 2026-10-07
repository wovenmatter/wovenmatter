import Foundation
import SQLite3
import WovenMatterCore

public struct ConversationActivityReadMetrics: Equatable, Sendable {
  public let summaryRows: Int
  public let fullRowsDecoded: Int
  public init(summaryRows: Int = 0, fullRowsDecoded: Int = 0) {
    self.summaryRows = summaryRows; self.fullRowsDecoded = fullRowsDecoded
  }
}

extension WorkspaceDatabaseConnection {
  /// A current-item index with one row per source record. Revisions are change
  /// cursors, not chronology. Triggers carry only identities and invalidate the
  /// small cached summary; they never copy raw payloads into this index.
  func createConversationActivityIndex() throws {
    try transaction {
      try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS desktop_activity_revision (
          singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL);
        INSERT OR IGNORE INTO desktop_activity_revision VALUES(1,0);
        CREATE TABLE IF NOT EXISTS desktop_activity_index (
          id TEXT PRIMARY KEY, source_kind TEXT NOT NULL, source_id TEXT NOT NULL,
          conversation_id TEXT NOT NULL, run_id TEXT NOT NULL,
          revision INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
          activity_id TEXT, summary TEXT);
        CREATE INDEX IF NOT EXISTS activity_index_conversation_revision
          ON desktop_activity_index(conversation_id,revision);
        CREATE INDEX IF NOT EXISTS activity_index_run ON desktop_activity_index(run_id);
        CREATE TABLE IF NOT EXISTS desktop_activity_index_schema(version INTEGER PRIMARY KEY);
        CREATE TABLE IF NOT EXISTS desktop_message_revisions (
          id TEXT PRIMARY KEY, revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS desktop_opencode_hidden_messages (
          message_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL);
        """)
      // Reconciliation may replace a completed message or remove an earlier
      // steering reply. Track mutations without copying its potentially large text.
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        let row = operation == "DELETE" ? "old" : "new"
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS conversation_message_\(operation.lowercased())
          AFTER \(operation) ON dashboard_messages BEGIN
            UPDATE desktop_activity_revision SET revision=revision+1 WHERE singleton=1;
            INSERT INTO desktop_message_revisions(id,revision)
              VALUES(\(row).id,(SELECT revision FROM desktop_activity_revision WHERE singleton=1))
              ON CONFLICT(id) DO UPDATE SET revision=excluded.revision;
          END;
          """)
      }
      let backfillQuery = try prepareUnlocked("SELECT 1 FROM desktop_activity_index_schema WHERE version=1")
      let needsBackfill = sqlite3_step(backfillQuery) != SQLITE_ROW
      sqlite3_finalize(backfillQuery)
      for (table, kind, prefix) in [
        ("dashboard_run_events", "event", ""),
        ("dashboard_run_trace_events", "trace", "trace-")
      ] {
        let hidden = kind == "trace"
          ? "new.is_visible=0 OR new.event_type IN ('assistant_delta','assistant_replace','done')" : "0"
        for operation in ["INSERT", "UPDATE"] {
          let condition = operation == "UPDATE"
            ? (kind == "event"
              ? "WHEN old.content IS NOT new.content OR old.event_type IS NOT new.event_type OR old.run_id IS NOT new.run_id OR old.conversation_id IS NOT new.conversation_id OR old.created_at IS NOT new.created_at"
              : "WHEN old.raw_event_json IS NOT new.raw_event_json OR old.content IS NOT new.content OR old.is_visible IS NOT new.is_visible OR old.event_type IS NOT new.event_type OR old.event_name IS NOT new.event_name OR old.event_phase IS NOT new.event_phase OR old.tool_name IS NOT new.tool_name OR old.run_id IS NOT new.run_id OR old.conversation_id IS NOT new.conversation_id OR old.created_at IS NOT new.created_at")
            : ""
          try executeUnlocked("""
            CREATE TRIGGER IF NOT EXISTS activity_index_\(kind)_\(operation.lowercased()) AFTER \(operation) ON \(table) \(condition) BEGIN
              UPDATE desktop_activity_revision SET revision=revision+1 WHERE singleton=1;
              INSERT INTO desktop_activity_index(id,source_kind,source_id,conversation_id,run_id,revision,deleted)
                VALUES('\(prefix)'||new.id,'\(kind)',new.id,new.conversation_id,new.run_id,
                  (SELECT revision FROM desktop_activity_revision WHERE singleton=1),CASE WHEN \(hidden) THEN 1 ELSE 0 END)
              ON CONFLICT(id) DO UPDATE SET conversation_id=excluded.conversation_id,run_id=excluded.run_id,
                revision=excluded.revision,deleted=excluded.deleted,summary=NULL,activity_id=NULL;
            END;
            CREATE TRIGGER IF NOT EXISTS activity_index_\(kind)_delete AFTER DELETE ON \(table) BEGIN
              UPDATE desktop_activity_revision SET revision=revision+1 WHERE singleton=1;
              UPDATE desktop_activity_index SET deleted=1,summary=NULL,
                revision=(SELECT revision FROM desktop_activity_revision WHERE singleton=1)
                WHERE id='\(prefix)'||old.id;
            END;
            """)
        }
        // Old records are indexed without decoding their payloads at startup.
        // They are read once when their page is opened, then excluded by cursor.
        let historicalHidden = kind == "trace"
          ? "is_visible=0 OR event_type IN ('assistant_delta','assistant_replace','done')" : "0"
        if needsBackfill { try executeUnlocked("""
          INSERT OR IGNORE INTO desktop_activity_index(id,source_kind,source_id,conversation_id,run_id,revision,deleted)
          SELECT '\(prefix)'||id,'\(kind)',id,conversation_id,run_id,0,
            CASE WHEN \(historicalHidden) THEN 1 ELSE 0 END FROM \(table);
          """) }
      }
      try executeUnlocked("INSERT OR IGNORE INTO desktop_activity_index_schema VALUES(1)")
    }
  }

  func storeActivitySummaryUnlocked(recordID: String, activity: AgentRunActivity) throws {
    let summary = String(decoding: try JSONEncoder().encode(activity.presentationSummary()), as: UTF8.self)
    let update = try prepareUnlocked("UPDATE desktop_activity_index SET summary=?,activity_id=? WHERE id=? AND deleted=0")
    defer { sqlite3_finalize(update) }
    try bind(summary, at: 1, to: update)
    try bind(activity.id, at: 2, to: update)
    try bind(recordID, at: 3, to: update)
    try stepDone(update)
  }

  func compactRunActivitiesUnlocked(conversationID: String, runIDs: [String],
    after: Int64?, knownRunIDs: [String]) throws ->
    (records: [WorkspaceRunActivityRecord], removed: [String], revision: Int64, metrics: ConversationActivityReadMetrics) {
    let clock = try prepareUnlocked("SELECT revision FROM desktop_activity_revision WHERE singleton=1")
    defer { sqlite3_finalize(clock) }
    guard sqlite3_step(clock) == SQLITE_ROW else { throw stepError() }
    let revision = sqlite3_column_int64(clock, 0)
    let after = after.flatMap { $0 <= revision ? $0 : nil }
    let allowed = Array(Set(runIDs + knownRunIDs))
    guard !allowed.isEmpty else { return ([], [], revision, .init()) }
    let allowedJSON = String(decoding: try JSONEncoder().encode(allowed), as: UTF8.self)
    let knownJSON = String(decoding: try JSONEncoder().encode(knownRunIDs), as: UTF8.self)
    let query = try prepareUnlocked("""
      SELECT id,source_kind,source_id,run_id,revision,deleted,summary
      FROM desktop_activity_index WHERE conversation_id=?
        AND run_id IN (SELECT value FROM json_each(?))
        AND (revision>? OR run_id NOT IN (SELECT value FROM json_each(?)))
      ORDER BY revision,id
      """)
    defer { sqlite3_finalize(query) }
    for (i, value) in [conversationID, allowedJSON, String(after ?? -1), after == nil ? "[]" : knownJSON].enumerated() {
      try bind(value, at: Int32(i + 1), to: query)
    }
    var records: [WorkspaceRunActivityRecord] = [], removed: [String] = []
    var pendingEvents: [String] = [], pendingTraces: [String] = []
    var versions: [String: Int64] = [:]
    var summaries: [(String, String, String, Int64)] = []
    while true {
      let code = sqlite3_step(query)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let id = try text(query, column: 0)
      let version = sqlite3_column_int64(query, 4)
      if sqlite3_column_int(query, 5) != 0 { removed.append(id); continue }
      versions[id] = version
      if let summary = optionalText(query, column: 6) {
        summaries.append((id, try text(query, column: 3), summary, version))
      } else if try text(query, column: 1) == "event" {
        pendingEvents.append(try text(query, column: 2))
      } else { pendingTraces.append(try text(query, column: 2)) }
    }
    // Metadata stays in its source table: no second ordering system or copies
    // of full payloads. Cached summaries join only small columns on reads.
    if !summaries.isEmpty {
      let idsJSON = String(decoding: try JSONEncoder().encode(summaries.map { $0.0 }), as: UTF8.self)
      let metadata = try prepareUnlocked("""
        SELECT e.id,e.created_at,e.rowid FROM dashboard_run_events e
        WHERE e.id IN (SELECT value FROM json_each(?))
        """)
      defer { sqlite3_finalize(metadata) }
      try bind(idsJSON, at: 1, to: metadata)
      var dates: [String: (String, Int64)] = [:]
      while true {
        let code = sqlite3_step(metadata)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW else { throw stepError() }
        dates[try text(metadata, column: 0)] = (try text(metadata, column: 1), sqlite3_column_int64(metadata, 2))
      }
      for (id, runID, json, version) in summaries {
        guard let date = dates[id] else { continue }
        let activity = try JSONDecoder().decode(AgentRunActivity.self, from: Data(json.utf8)).presentationSummary(version: version)
        records.append(.init(id: id, runID: runID, conversationID: conversationID,
          activity: activity, createdAt: date.0, sequence: activity.position.map(Int64.init) ?? date.1))
      }
    }
    if !pendingEvents.isEmpty || !pendingTraces.isEmpty {
      let full = try runActivityRecordsUnlocked(runIDs: allowed,
        eventRecordIDs: pendingEvents, traceRecordIDs: pendingTraces)
      records += full.map { record in
        .init(id: record.id, runID: record.runID, conversationID: record.conversationID,
          activity: record.activity.presentationSummary(version: versions[record.id]),
          createdAt: record.createdAt, sequence: record.sequence)
      }
    }
    return (records.sorted(by: WorkspaceRunActivityRecord.precedes), removed, revision,
      .init(summaryRows: summaries.count, fullRowsDecoded: pendingEvents.count + pendingTraces.count))
  }

  public func conversationActivityDetails(conversationID: String, runID: String,
    activityID: String) throws -> AgentRunActivity? {
    try withLock {
      guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked() else { return nil }
      let access = try prepareUnlocked("""
        SELECT 1 FROM dashboard_runs r JOIN dashboard_conversations c ON c.id=r.conversation_id
        WHERE r.id=? AND c.id=? AND (c.user_id=? OR c.desktop_owned=1)
          AND c.deleted_at IS NULL AND c.is_archived=0
          AND c.governing_plane='wovenmatter_macos'
        """)
      defer { sqlite3_finalize(access) }
      for (i, value) in [runID, conversationID, operatorID].enumerated() { try bind(value, at: Int32(i + 1), to: access) }
      guard sqlite3_step(access) == SQLITE_ROW else { return nil }
      // The common normalized current item is fetched directly by its stable ID.
      let directID = "\(runID):activity:\(activityID)"
      let direct = try runActivityRecordsUnlocked(runIDs: [runID], eventRecordIDs: [directID], traceRecordIDs: [])
      if let activity = direct.first?.activity { return activity }
      // Legacy visible trace-only records have no normalized current-item row.
      // This fallback is disclosure-only; full trace revisions stay in history.
      let records = try runActivityRecordsUnlocked(runIDs: [runID])
      return records.filter { $0.activity.id == activityID }.reduce(nil as AgentRunActivity?) { prior, record in
        prior?.merging(record.activity) ?? record.activity
      }
    }
  }
}

extension WorkspaceDatabase {
  public func conversationActivityDetails(conversationID: String, runID: String,
    activityID: String) async throws -> AgentRunActivity? {
    try await read { try $0.conversationActivityDetails(conversationID: conversationID, runID: runID, activityID: activityID) }
  }
}
