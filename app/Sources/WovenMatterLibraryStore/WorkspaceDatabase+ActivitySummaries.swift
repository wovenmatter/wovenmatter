#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
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
        CREATE TABLE IF NOT EXISTS activity_revision (
          singleton INTEGER PRIMARY KEY CHECK(singleton=1), revision INTEGER NOT NULL);
        INSERT OR IGNORE INTO activity_revision VALUES(1,0);
        CREATE TABLE IF NOT EXISTS activity_summaries (
          id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, run_id TEXT NOT NULL,
          revision INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0, summary TEXT);
        CREATE INDEX IF NOT EXISTS activity_summaries_conversation_revision
          ON activity_summaries(conversation_id,revision);
        CREATE INDEX IF NOT EXISTS activity_summaries_run ON activity_summaries(run_id);
        CREATE TABLE IF NOT EXISTS message_revisions (
          id TEXT PRIMARY KEY, revision INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS opencode_hidden_messages (
          message_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL);
        """)
      // Reconciliation may replace a completed message or remove an earlier
      // steering reply. Track mutations without copying its potentially large text.
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        let row = operation == "DELETE" ? "old" : "new"
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS messages_revision_\(operation.lowercased())
          AFTER \(operation) ON messages BEGIN
            UPDATE activity_revision SET revision=revision+1 WHERE singleton=1;
            INSERT INTO message_revisions(id,revision)
              VALUES(\(row).id,(SELECT revision FROM activity_revision WHERE singleton=1))
              ON CONFLICT(id) DO UPDATE SET revision=excluded.revision;
          END;
          """)
      }
      for operation in ["INSERT", "UPDATE"] {
        let condition = operation == "UPDATE"
          ? "WHEN old.content IS NOT new.content OR old.event_type IS NOT new.event_type OR old.run_id IS NOT new.run_id OR old.conversation_id IS NOT new.conversation_id OR old.created_at IS NOT new.created_at"
          : ""
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS run_activities_summary_\(operation.lowercased()) AFTER \(operation) ON run_activities \(condition) BEGIN
            UPDATE activity_revision SET revision=revision+1 WHERE singleton=1;
            INSERT INTO activity_summaries(id,conversation_id,run_id,revision,deleted)
              VALUES(new.id,new.conversation_id,new.run_id,
                (SELECT revision FROM activity_revision WHERE singleton=1),0)
            ON CONFLICT(id) DO UPDATE SET conversation_id=excluded.conversation_id,run_id=excluded.run_id,
              revision=excluded.revision,deleted=excluded.deleted,summary=NULL;
          END;
          """)
      }
      try executeUnlocked("""
        CREATE TRIGGER IF NOT EXISTS run_activities_summary_delete AFTER DELETE ON run_activities BEGIN
          UPDATE activity_revision SET revision=revision+1 WHERE singleton=1;
          UPDATE activity_summaries SET deleted=1,summary=NULL,
            revision=(SELECT revision FROM activity_revision WHERE singleton=1)
            WHERE id=old.id;
        END;
        """)
    }
  }

  func storeActivitySummaryUnlocked(recordID: String, activity: AgentRunActivity) throws {
    let summary = String(decoding: try JSONEncoder().encode(activity.presentationSummary()), as: UTF8.self)
    let update = try prepareUnlocked("UPDATE activity_summaries SET summary=? WHERE id=? AND deleted=0")
    defer { sqlite3_finalize(update) }
    try bind(summary, at: 1, to: update)
    try bind(recordID, at: 2, to: update)
    try stepDone(update)
  }

  func compactRunActivitiesUnlocked(conversationID: String, runIDs: [String],
    after: Int64?, knownRunIDs: [String]) throws ->
    (records: [WorkspaceRunActivityRecord], removed: [String], revision: Int64, metrics: ConversationActivityReadMetrics) {
    let clock = try prepareUnlocked("SELECT revision FROM activity_revision WHERE singleton=1")
    defer { sqlite3_finalize(clock) }
    guard sqlite3_step(clock) == SQLITE_ROW else { throw stepError() }
    let revision = sqlite3_column_int64(clock, 0)
    let after = after.flatMap { $0 <= revision ? $0 : nil }
    let allowed = Array(Set(runIDs + knownRunIDs))
    guard !allowed.isEmpty else { return ([], [], revision, .init()) }
    let allowedJSON = String(decoding: try JSONEncoder().encode(allowed), as: UTF8.self)
    let knownJSON = String(decoding: try JSONEncoder().encode(knownRunIDs), as: UTF8.self)
    let query = try prepareUnlocked("""
      SELECT id,run_id,revision,deleted,summary
      FROM activity_summaries WHERE conversation_id=?
        AND run_id IN (SELECT value FROM json_each(?))
        AND (revision>? OR run_id NOT IN (SELECT value FROM json_each(?)))
      ORDER BY revision,id
      """)
    defer { sqlite3_finalize(query) }
    for (i, value) in [conversationID, allowedJSON, String(after ?? -1), after == nil ? "[]" : knownJSON].enumerated() {
      try bind(value, at: Int32(i + 1), to: query)
    }
    var records: [WorkspaceRunActivityRecord] = [], removed: [String] = []
    var pending: [String] = []
    var versions: [String: Int64] = [:]
    var summaries: [(String, String, String, Int64)] = []
    while true {
      let code = sqlite3_step(query)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let id = try text(query, column: 0)
      let version = sqlite3_column_int64(query, 2)
      if sqlite3_column_int(query, 3) != 0 { removed.append(id); continue }
      versions[id] = version
      if let summary = optionalText(query, column: 4) {
        summaries.append((id, try text(query, column: 1), summary, version))
      } else { pending.append(id) }
    }
    // Metadata stays in its source table: no second ordering system or copies
    // of full payloads. Cached summaries join only small columns on reads.
    if !summaries.isEmpty {
      let idsJSON = String(decoding: try JSONEncoder().encode(summaries.map { $0.0 }), as: UTF8.self)
      let metadata = try prepareUnlocked("""
        SELECT e.id,e.created_at,e.rowid FROM run_activities e
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
    if !pending.isEmpty {
      let full = try runActivityRecordsUnlocked(runIDs: allowed, recordIDs: pending)
      records += full.map { record in
        .init(id: record.id, runID: record.runID, conversationID: record.conversationID,
          activity: record.activity.presentationSummary(version: versions[record.id]),
          createdAt: record.createdAt, sequence: record.sequence)
      }
    }
    return (records.sorted(by: WorkspaceRunActivityRecord.precedes), removed, revision,
      .init(summaryRows: summaries.count, fullRowsDecoded: pending.count))
  }

  /// Resolve the existing federated detail pointer only on disclosure. Routine
  /// activity pages continue to read the bounded projection and summary index.
  private func libraryActivityDetailsUnlocked(conversationID: String, runID: String,
    activityID: String) throws -> AgentRunActivity? {
    // An activity the execution owner projected names its details record.
    let lookup = try prepareUnlocked("""
      SELECT c.workspace_id,a.details_record_id,a.content FROM execution_conversations c
      JOIN run_activities a ON a.conversation_id=c.id
      WHERE c.id=? AND c.deleted=0 AND a.id=? AND a.run_id=? AND a.title IS NOT NULL
      """)
    defer { sqlite3_finalize(lookup) }
    try bind(conversationID, at: 1, to: lookup); try bind(activityID, at: 2, to: lookup); try bind(runID, at: 3, to: lookup)
    let lookupCode = sqlite3_step(lookup)
    if lookupCode == SQLITE_DONE { return nil }
    guard lookupCode == SQLITE_ROW else { throw stepError() }
    let workspaceID = try text(lookup, column: 0)
    guard let recordID = optionalText(lookup, column: 1) else {
      return try? JSONDecoder().decode(AgentRunActivity.self, from: Data(text(lookup, column: 2).utf8))
    }
    let data = try LibraryActivityDetails.reconstruct(recordID: recordID, activityID: activityID) { pointer in
      try libraryActivityRecordUnlocked(workspaceID: workspaceID, conversationID: conversationID,
        runID: runID, recordID: pointer)
    }
    return try JSONDecoder().decode(AgentRunActivity.self, from: data)
  }

  private func libraryActivityRecordUnlocked(workspaceID: String, conversationID: String,
    runID: String, recordID: String) throws -> (format: String, data: Data) {
    // Query by immutable identity first so a cross-run/conversation reference is
    // rejected, rather than treated as an incomplete record that could arrive.
    let manifest = try prepareUnlocked("SELECT conversation_id,run_id,format,part_count,byte_count,sha256,complete FROM execution_native_history WHERE workspace_id=? AND record_id=?")
    defer { sqlite3_finalize(manifest) }
    try bind(workspaceID, at: 1, to: manifest); try bind(recordID, at: 2, to: manifest)
    let code = sqlite3_step(manifest)
    if code == SQLITE_DONE { throw LibraryActivityDetails.incomplete }
    guard code == SQLITE_ROW else { throw stepError() }
    guard try text(manifest, column: 0) == conversationID,
      try text(manifest, column: 1) == runID else { throw LibraryActivityDetails.invalid }
    let format = try text(manifest, column: 2)
    let count = Int(sqlite3_column_int(manifest, 3)), size = sqlite3_column_int64(manifest, 4)
    let digest = try text(manifest, column: 5)
    guard count > 0, count <= 65_536, size >= 0,
      size <= LibraryActivityDetails.maximumBytes else { throw LibraryActivityDetails.invalid }
    guard sqlite3_column_int(manifest, 6) == 1 else { throw LibraryActivityDetails.incomplete }
    let parts = try prepareUnlocked("SELECT part_index,sha256,byte_count FROM execution_native_history_parts WHERE workspace_id=? AND record_id=? ORDER BY part_index")
    defer { sqlite3_finalize(parts) }
    try bind(workspaceID, at: 1, to: parts); try bind(recordID, at: 2, to: parts)
    var data = Data(), index = 0
    while true {
      let code = sqlite3_step(parts)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      guard sqlite3_column_int(parts, 0) == index else { throw LibraryActivityDetails.invalid }
      let count = sqlite3_column_int64(parts, 2)
      guard count >= 0, count <= size - Int64(data.count) else { throw LibraryActivityDetails.invalid }
      let bytes = try libraryFiles.chunk(text(parts, column: 1), byteCount: count)
      data.append(bytes); index += 1
    }
    guard index == count, data.count == size,
      SHA256.hash(data: data).hexString == digest else { throw LibraryActivityDetails.invalid }
    return (format, data)
  }

  public func conversationActivityDetails(conversationID: String, runID: String,
    activityID: String) throws -> AgentRunActivity? {
    try withLock {
      let access = try prepareUnlocked("""
        SELECT 1 FROM runs r JOIN conversations c ON c.id=r.conversation_id
        WHERE r.id=? AND c.id=? AND \(Self.listedConversation("c"))
        """)
      defer { sqlite3_finalize(access) }
      for (i, value) in [runID, conversationID].enumerated() { try bind(value, at: Int32(i + 1), to: access) }
      guard sqlite3_step(access) == SQLITE_ROW else { return nil }
      if let activity = try libraryActivityDetailsUnlocked(conversationID: conversationID,
        runID: runID, activityID: activityID) { return activity }
      // The common normalized current item is fetched directly by its stable ID.
      let directID = "\(runID):activity:\(activityID)"
      let direct = try runActivityRecordsUnlocked(runIDs: [runID], recordIDs: [directID])
      if let activity = direct.first?.activity { return activity }
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
