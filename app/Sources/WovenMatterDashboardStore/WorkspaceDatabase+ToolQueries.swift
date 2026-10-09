import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabaseConnection {
  /// This is the only history entry point exposed to agent endpoints. Identity is
  /// supplied by the service binding, never decoded from the agent's request.
  public func queryAgentHistory(_ input: WorkspaceHistoryQuery, callerID: String,
                                allWorkspace: Bool = false) throws -> GatewayJSONValue {
    try transaction {
      var query = input
      query.callerConversationID = callerID
      guard query.schemaVersion == 1, (1...200).contains(query.limit), query.after >= 0,
            query.offset >= 0, query.offset < Int.max, (1...65536).contains(query.characters),
            ["oldest", "newest"].contains(query.sort) else {
        throw WorkspaceToolError.invalid("Unsupported schema or invalid pagination.")
      }
      let groups = try sessionToolsUnlocked(callerID).enabled
      switch query.command {
      case "versions", "version": try requireToolUnlocked(.notes, sessionID: callerID)
      case "conversations":
        guard groups.contains(.sessions) || groups.contains(.history) else { throw WorkspaceToolError.disabled(.sessions) }
      case "conversation":
        guard let target = query.id else { throw WorkspaceToolError.invalid("A session ID is required.") }
        try requireTranscriptAccessUnlocked(sourceID: callerID, targetID: target)
      case "message", "event", "trace":
        let lookup: String
        let id: String?
        switch query.command {
        case "message": lookup = "SELECT conversation_id FROM dashboard_messages WHERE id=?"; id = query.id
        case "event": lookup = "SELECT conversation_id FROM workspace_history_events WHERE id=?"; id = query.id
        default: lookup = "SELECT conversation_id FROM dashboard_runs WHERE id=?"; id = query.runID ?? query.id
        }
        guard let id else { throw WorkspaceToolError.invalid("A record ID is required.") }
        var rows = try historyRowsUnlocked(lookup, values: [id])
        if rows.isEmpty, query.command == "trace" {
          rows = try historyRowsUnlocked(
            "SELECT conversation_id FROM workspace_history_events WHERE run_id=? LIMIT 1", values: [id])
        }
        guard !rows.isEmpty else {
          throw WorkspaceToolError.notFound("The requested record was not found.")
        }
        if let target = rows.first?.objectValue?["conversation_id"]?.stringValue {
          try requireTranscriptAccessUnlocked(sourceID: callerID, targetID: target)
        } else { try requireToolUnlocked(.history, sessionID: callerID) }
        // Do not accept a mismatched caller-supplied session filter.
        query.conversationID = rows.first?.objectValue?["conversation_id"]?.stringValue
      case "runs", "events", "search":
        if let target = query.conversationID { try requireTranscriptAccessUnlocked(sourceID: callerID, targetID: target) }
        else { try requireToolUnlocked(.history, sessionID: callerID) }
      default: throw WorkspaceToolError.invalid("Unknown history command.")
      }
      if !allWorkspace, query.folderID == nil, query.conversationID == nil,
         query.command == "search" || (query.command == "conversations" && query.search != nil) {
        query.folderID = try historyRowsUnlocked("SELECT folder_id FROM dashboard_conversations WHERE id=?", values: [callerID]).first?.objectValue?["folder_id"]?.stringValue
      }
      var result = try queryHistoryUnlocked(query)
      var scope = query.folderID == nil ? "workspace" : "folder"
      if !allWorkspace, input.folderID == nil, query.folderID != nil,
         result.objectValue?["rows"]?.arrayValue?.isEmpty == true {
        query.folderID = nil
        result = try queryHistoryUnlocked(query)
        scope = "workspace"
      }
      if ["message", "event", "version"].contains(query.command),
         result.objectValue?["rows"]?.arrayValue?.isEmpty == true {
        throw WorkspaceToolError.notFound("The requested record was not found.")
      }
      let ids = (result.objectValue?["rows"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
      try recordHistoryUnlocked(.init(conversationID: callerID, harness: "wovenmatter", kind: "cli.history.read",
        payload: try toolsJSON(["command": query.command, "resultIDs": ids.joined(separator: ",")])))
      var object = result.objectValue ?? [:]
      if query.command == "conversations" {
        let statuses = try programStatusSnapshotsUnlocked()
        object["rows"] = .array(try (object["rows"]?.arrayValue ?? []).map { row in
          guard var fields = row.objectValue, let id = fields["id"]?.stringValue else { return row }
          var snapshot = statuses[id] ?? ProgramStatusSnapshot(status: ProgramStatus(state: .idle))
          if try !canReadTranscriptUnlocked(sourceID: callerID, targetID: id, enabled: groups) {
            snapshot = snapshot.sessionMetadata
          }
          fields["programStatus"] = try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(snapshot))
          fields["executionStatus"] = snapshot.executionStatus.map { .string($0) } ?? fields["status"] ?? .null
          fields["status"] = snapshot.status.map { .string($0.state.rawValue) } ?? .null
          return .object(fields)
        })
      }
      object["scope"] = .string(scope)
      return .object(object)
    }
  }
}

private extension ProgramStatusSnapshot {
  /// Session discovery exposes status, while run identity and free text follow
  /// the same grants as the underlying transcript and error details.
  var sessionMetadata: Self {
    func metadata(_ report: ProgramStatus) -> ProgramStatus {
      ProgramStatus(state: report.state, id: report.id, app: report.app,
                    kind: report.kind, progress: report.progress)
    }
    return Self(executionStatus: executionStatus, status: status.map(metadata), records: records.map(metadata))
  }
}

// MARK: - Async worker boundary

extension WorkspaceDatabase {
  public func queryAgentHistory(_ input: WorkspaceHistoryQuery, callerID: String,
                                allWorkspace: Bool = false) async throws -> GatewayJSONValue {
    try await write { try $0.queryAgentHistory(input, callerID: callerID, allWorkspace: allWorkspace) }
  }
}
