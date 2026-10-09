import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabaseConnection {
  /// The coordinator supplies run/source identity; a report cannot address
  /// another session or change the durable run's execution state.
  public func recordProgramStatus(_ report: ProgramStatus, runID: String, source: String = "native") throws {
    try transaction {
      guard report.validated != nil,
        try historyRowsUnlocked("SELECT 1 FROM dashboard_runs WHERE id=? AND status='running' AND desktop_owned=1", values: [runID]).count == 1 else { return }
      let previous = try historyRowsUnlocked("SELECT records_json FROM desktop_program_status WHERE run_id=? AND source=?", values: [runID, source]).first?.objectValue?["records_json"]?.stringValue
      var records = previous.flatMap { try? JSONDecoder().decode(ProgramStatusRecords.self, from: Data($0.utf8)) } ?? ProgramStatusRecords()
      guard records.apply(report) else { return }
      if records.records.isEmpty {
        try toolsExecuteUnlocked("DELETE FROM desktop_program_status WHERE run_id=? AND source=?", [runID, source])
        return
      }
      try toolsExecuteUnlocked("""
        INSERT INTO desktop_program_status(run_id,source,records_json,updated_at) VALUES(?,?,?,?)
        ON CONFLICT(run_id,source) DO UPDATE SET records_json=excluded.records_json,updated_at=excluded.updated_at
        """, [runID, source, String(decoding: try JSONEncoder().encode(records), as: UTF8.self), Self.timestamp(Date())])
    }
  }

  func programStatusSnapshotsUnlocked() throws -> [String: ProgramStatusSnapshot] {
    let rows = try historyRowsUnlocked("""
      SELECT r.id,r.conversation_id,r.status,r.error,s.runtime_kind,
        (SELECT json_group_array(json(records_json)) FROM
          (SELECT records_json FROM desktop_program_status WHERE run_id=r.id ORDER BY updated_at,source)) AS reports
      FROM dashboard_conversations c JOIN dashboard_runs r ON r.id=(
        SELECT latest.id FROM dashboard_runs latest WHERE latest.conversation_id=c.id
        ORDER BY CASE WHEN latest.status='running' THEN 0 ELSE 1 END,latest.started_at DESC,latest.rowid DESC LIMIT 1)
      LEFT JOIN desktop_local_acp_sessions s ON s.conversation_id=c.id
      WHERE c.deleted_at IS NULL
      """, values: [])
    var result: [String: ProgramStatusSnapshot] = [:]
    for row in rows {
      guard let value = row.objectValue, let id = value["id"]?.stringValue,
            let conversationID = value["conversation_id"]?.stringValue,
            let executionStatus = value["status"]?.stringValue else { continue }
      let reports = value["reports"]?.stringValue.flatMap {
        try? JSONDecoder().decode([ProgramStatusRecords].self, from: Data($0.utf8))
      }?.flatMap(\.resolvedRecords) ?? []
      result[conversationID] = .run(id: id, executionStatus: executionStatus,
        error: value["error"]?.stringValue, app: value["runtime_kind"]?.stringValue == "default_agent" ? "pi-durable" : value["runtime_kind"]?.stringValue, reports: reports)
    }
    // OpenCode's native active/decision snapshot spans multiple message runs.
    // An assistant message ending in tool use does not settle that session.
    for row in try historyRowsUnlocked("""
      SELECT conversation_id,json_extract(snapshot_json,'$.active') AS active,
        json_array_length(snapshot_json,'$.permissions') AS permission_count,
        json_array_length(snapshot_json,'$.forms') AS form_count
      FROM desktop_opencode_sessions WHERE json_valid(snapshot_json)
      """, values: []) {
      guard let value = row.objectValue, let id = value["conversation_id"]?.stringValue else { continue }
      let prior = result[id]
      let blocked: ProgramStatus.Kind? = (value["permission_count"]?.intValue ?? 0) > 0 ? .permission
        : (value["form_count"]?.intValue ?? 0) > 0 ? .question : nil
      if blocked != nil || value["active"]?.intValue == 1 {
        result[id] = ProgramStatusSnapshot(runID: prior?.runID, executionStatus: "running",
          status: ProgramStatus(state: blocked == nil ? .working : .blocked, app: "opencode", kind: blocked))
      } else if prior == nil {
        result[id] = ProgramStatusSnapshot(status: ProgramStatus(state: .idle, app: "opencode"))
      }
    }
    for row in try historyRowsUnlocked("SELECT DISTINCT conversation_id FROM desktop_opencode_submissions WHERE status IN ('sending','uncertain')", values: []) {
      guard let id = row.objectValue?["conversation_id"]?.stringValue,
            result[id]?.status?.isActive != true else { continue }
      result[id] = ProgramStatusSnapshot(runID: result[id]?.runID, executionStatus: "uncertain")
    }
    return result
  }
}

extension WorkspaceDatabase {
  public func recordProgramStatus(_ report: ProgramStatus, runID: String, source: String = "native") async throws {
    try await write { try $0.recordProgramStatus(report, runID: runID, source: source) }
  }
}
