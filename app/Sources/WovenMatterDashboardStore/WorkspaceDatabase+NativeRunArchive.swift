import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Additive current-run archive schema; native stores remain execution-owned.
  /// The existing journal is the canonical table so its paging/access contracts
  /// also cover native records and immutable activity revisions.
  func createNativeRunArchive() throws {
    try transaction {
      let columns = Set(try historyRowsUnlocked("PRAGMA table_info(workspace_history_events)", values: [])
        .compactMap { $0.objectValue?["name"]?.stringValue })
      for column in ["source_id", "native_record_id", "native_revision_id", "content_mode", "text_content", "projection_json"] where !columns.contains(column) {
        try executeUnlocked("ALTER TABLE workspace_history_events ADD COLUMN \(column) TEXT")
      }
      try executeUnlocked("""
        CREATE INDEX IF NOT EXISTS history_native_record ON workspace_history_events(harness,source_id,native_session_id,native_record_id,sequence);
        """)
      try executeUnlocked("""
        DROP TRIGGER IF EXISTS history_search_insert;
        DROP TRIGGER IF EXISTS history_search_delete;
        """)
      try executeUnlocked("""
        CREATE TRIGGER IF NOT EXISTS history_search_insert AFTER INSERT ON workspace_history_events
          WHEN new.kind NOT LIKE 'cli.%' BEGIN
          INSERT INTO workspace_history_search(rowid,payload)
            VALUES(new.sequence,new.payload||' '||coalesce(new.text_content,'')||' '||coalesce(new.projection_json,''));
        END;
        CREATE TRIGGER IF NOT EXISTS history_search_delete AFTER DELETE ON workspace_history_events
          WHEN old.kind NOT LIKE 'cli.%' BEGIN
          INSERT INTO workspace_history_search(workspace_history_search,rowid,payload)
            VALUES('delete',old.sequence,old.payload||' '||coalesce(old.text_content,'')||' '||coalesce(old.projection_json,''));
        END;
        """)
      for (table, kind, textColumn) in [
        ("dashboard_message_attachments", "attachment", "file_name"),
        ("dashboard_message_references", "reference", "title_snapshot")
      ] {
        let names = try historyRowsUnlocked("PRAGMA table_info(\(table))", values: [])
          .compactMap { $0.objectValue?["name"]?.stringValue }
        func object(_ alias: String) -> String {
          "json_object(" + names.map {
            "'\($0.replacingOccurrences(of: "'", with: "''"))',\(alias).\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\""
          }.joined(separator: ",") + ")"
        }
        let newObject = object("new")
        let conversation = "coalesce(nullif(new.conversation_id,''),(SELECT conversation_id FROM dashboard_messages WHERE id=new.message_id))"
        for operation in ["INSERT", "UPDATE"] {
          let condition = operation == "UPDATE" ? "WHEN \(object("old")) IS NOT \(newObject)" : ""
          try executeUnlocked("""
            CREATE TRIGGER IF NOT EXISTS history_\(kind)_\(operation.lowercased()) AFTER \(operation) ON \(table) \(condition) BEGIN
              INSERT INTO workspace_history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content)
              VALUES(lower(hex(randomblob(16))),\(conversation),(SELECT run_id FROM dashboard_messages WHERE id=new.message_id),
                coalesce((SELECT runtime_kind FROM desktop_local_acp_sessions WHERE conversation_id=\(conversation)),'unknown'),
                '\(kind).snapshot',woven_history_redact(\(newObject)),'woven:\(kind)',\(conversation),new.id,'snapshot',woven_history_redact(new.\(textColumn)));
            END;
            """)
        }
      }
      // Presentation rows are upserted; archive each exposed value before that
      // projection can overwrite it. The raw saved activity includes inputs,
      // results, thought summaries and non-text references when exposed.
      for operation in ["INSERT", "UPDATE"] {
        let suffix = operation.lowercased()
        let condition = operation == "UPDATE" ? "WHEN old.content IS NOT new.content OR old.event_type IS NOT new.event_type" : ""
        // Streaming app rows already contain accumulated text. Keep only the
        // appended normalized text in each archive revision; raw native update
        // fields remain intact. A final snapshot below retains the whole value.
        let incremental = operation == "UPDATE" ? """
          CASE WHEN json_valid(new.content) AND json_valid(old.content) THEN
            json_extract(new.content,'$.contentIsDelta')=1
              AND json_type(new.content,'$.content')='text' AND json_type(old.content,'$.content')='text'
              AND woven_text_substr(json_extract(new.content,'$.content'),1,woven_text_length(json_extract(old.content,'$.content')))=json_extract(old.content,'$.content')
            ELSE 0 END
          """ : "0"
        let delta = operation == "UPDATE"
          ? "woven_text_substr(json_extract(new.content,'$.content'),woven_text_length(json_extract(old.content,'$.content'))+1)"
          : "NULL"
        let savedProjection = "CASE WHEN \(incremental) THEN json_set(new.content,'$.content',\(delta)) ELSE new.content END"
        try executeUnlocked("DROP TRIGGER IF EXISTS history_activity_\(suffix)")
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS history_activity_\(suffix) AFTER \(operation) ON dashboard_run_events \(condition) BEGIN
            INSERT INTO workspace_history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content,projection_json)
            VALUES(lower(hex(randomblob(16))),new.conversation_id,new.run_id,
              coalesce((SELECT runtime_kind FROM desktop_local_acp_sessions WHERE conversation_id=new.conversation_id),'unknown'),
              CASE WHEN \(incremental) THEN 'activity.delta' ELSE 'activity.snapshot' END,
              woven_history_redact(\(savedProjection)),'woven:activity',new.conversation_id,new.id,
              CASE WHEN \(incremental) THEN 'delta' ELSE 'snapshot' END,
              CASE WHEN \(incremental) THEN woven_history_redact(\(delta)) WHEN json_valid(new.content) THEN woven_history_redact(json_extract(new.content,'$.content')) ELSE woven_history_redact(new.content) END,
              woven_history_redact(\(savedProjection)));
          END;
          """)
        let traceCondition = operation == "UPDATE" ? "WHEN old.raw_event_json IS NOT new.raw_event_json OR old.stream_event_json IS NOT new.stream_event_json" : ""
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS history_trace_\(suffix) AFTER \(operation) ON dashboard_run_trace_events \(traceCondition) BEGIN
            INSERT INTO workspace_history_events(id,conversation_id,run_id,agent_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content,projection_json)
            VALUES(lower(hex(randomblob(16))),new.conversation_id,new.run_id,(SELECT agent_id FROM dashboard_runs WHERE id=new.run_id),'openclaw','trace.snapshot',
              woven_history_redact(new.raw_event_json),'woven:trace',new.openclaw_session_key,new.id,'snapshot',
              woven_history_redact(new.content),woven_history_redact(new.stream_event_json));
          END;
          """)
      }
      try executeUnlocked("""
        CREATE TRIGGER IF NOT EXISTS history_activity_final AFTER UPDATE ON dashboard_runs
          WHEN new.status IN ('completed','failed','cancelled','interrupted') AND old.status IS NOT new.status BEGIN
          INSERT INTO workspace_history_events(id,conversation_id,run_id,harness,kind,payload,source_id,native_session_id,native_record_id,content_mode,text_content,projection_json)
          SELECT lower(hex(randomblob(16))),e.conversation_id,e.run_id,
            coalesce((SELECT runtime_kind FROM desktop_local_acp_sessions WHERE conversation_id=e.conversation_id),'unknown'),
            'activity.final',woven_history_redact(e.content),'woven:activity',e.conversation_id,e.id,'snapshot',
            woven_history_redact(json_extract(e.content,'$.content')),woven_history_redact(e.content)
          FROM dashboard_run_events e WHERE e.run_id=new.id
            AND CASE WHEN json_valid(e.content) THEN json_extract(e.content,'$.contentIsDelta')=1 ELSE 0 END;
        END;
        """)
    }
  }

  func recordNativeRunRecordsUnlocked(_ batch: WorkspaceNativeRunRecordBatch,
    conversationID: String? = nil, runID: String? = nil, agentID: String? = nil,
    harness: String, sourceConnectionID: String? = nil, pendingRunID: String? = nil) throws {
    guard batch.schemaVersion == 1, !batch.sourceID.isEmpty, !batch.nativeSessionID.isEmpty else {
      throw WorkspaceDatabaseError.open("Invalid native archive source")
    }
    let sourceID = batch.sourceID
    for record in batch.records {
      guard !record.id.isEmpty, !record.kind.isEmpty,
        ["event", "delta", "snapshot"].contains(record.contentMode) else {
        throw WorkspaceDatabaseError.open("Invalid native archive record")
      }
      var mappedRunID: String?
      if let proposed = record.runID ?? runID {
        if let target = try historyRowsUnlocked("SELECT conversation_id FROM dashboard_runs WHERE id=?", values: [proposed]).first?.objectValue?["conversation_id"]?.stringValue {
          guard conversationID == nil || target == conversationID else { throw WorkspaceDatabaseError.open("Native archive run belongs to another conversation") }
          mappedRunID = proposed
        } else if let pendingRunID, record.runID == pendingRunID {
          // A validated scheduled result may precede its display run. Only an
          // explicit native attribution can name that pending run.
          mappedRunID = pendingRunID
        }
      }
      let payload = WorkspaceHistoryPrivacy.redactingToolEndpoints(record.payload)
      let projection = record.projectionJSON.map(WorkspaceHistoryPrivacy.redactingToolEndpoints)
      let text = record.text.map(WorkspaceHistoryPrivacy.redactingToolEndpoints)
      // Attribution can arrive after a supported import. It is not part of the
      // native identity, so reconciliation enriches the original retained row.
      let encoder = JSONEncoder()
      let identity = try encoder.encode([harness, sourceID, batch.nativeSessionID, record.id,
        record.revision ?? "", record.kind, record.contentMode, payload, projection ?? "", text ?? ""])
      let eventID = "native:" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
      if let existing = try historyRowsUnlocked("SELECT conversation_id,run_id,agent_id,source_connection_id FROM workspace_history_events WHERE id=?", values: [eventID]).first?.objectValue {
        if let previous = existing["conversation_id"]?.stringValue, let conversationID, previous != conversationID {
          throw WorkspaceDatabaseError.open("Native archive source belongs to another conversation")
        }
        if let previous = existing["run_id"]?.stringValue, let mappedRunID, previous != mappedRunID {
          throw WorkspaceDatabaseError.open("Native archive record belongs to another run")
        }
        if let previous = existing["agent_id"]?.stringValue, let agentID, previous != agentID {
          throw WorkspaceDatabaseError.open("Native archive source belongs to another agent")
        }
        if let previous = existing["source_connection_id"]?.stringValue, let sourceConnectionID, previous != sourceConnectionID {
          throw WorkspaceDatabaseError.open("Native archive source belongs to another connection")
        }
        try toolsExecuteUnlocked("UPDATE workspace_history_events SET conversation_id=coalesce(conversation_id,?),run_id=coalesce(run_id,?),agent_id=coalesce(agent_id,?),source_connection_id=coalesce(source_connection_id,?) WHERE id=?",
          [conversationID, mappedRunID, agentID, sourceConnectionID, eventID])
        continue
      }
      try recordHistoryUnlocked(.init(id: eventID, conversationID: conversationID, runID: mappedRunID,
        agentID: agentID, harness: harness, kind: record.kind.hasPrefix("native.") ? record.kind : "native." + record.kind,
        payload: payload, completeness: record.completeness, nativeSessionID: batch.nativeSessionID,
        sourceConnectionID: sourceConnectionID, sourceID: sourceID, nativeRecordID: record.id,
        nativeRevisionID: record.revision ?? eventID, contentMode: record.contentMode, textContent: text, projectionJSON: projection))
    }
  }

  func recordNativeRunRecords(_ batch: WorkspaceNativeRunRecordBatch,
    conversationID: String? = nil, runID: String? = nil, agentID: String? = nil,
    harness: String, sourceConnectionID: String? = nil) throws {
    try transaction { try recordNativeRunRecordsUnlocked(batch, conversationID: conversationID,
      runID: runID, agentID: agentID, harness: harness, sourceConnectionID: sourceConnectionID) }
  }
}

extension WorkspaceDatabase {
  public func recordNativeRunRecords(_ batch: WorkspaceNativeRunRecordBatch,
    conversationID: String? = nil, runID: String? = nil, agentID: String? = nil,
    harness: String, sourceConnectionID: String? = nil) async throws {
    try await write { try $0.recordNativeRunRecords(batch, conversationID: conversationID,
      runID: runID, agentID: agentID, harness: harness, sourceConnectionID: sourceConnectionID) }
  }
}
