import Foundation
import WovenMatterCore
import WovenMatterClient

extension WorkspaceDatabase {
  /// This is the only history entry point exposed to agent endpoints. Identity is
  /// supplied by the service binding, never decoded from the agent's request.
  public func queryAgentHistory(_ input: WorkspaceHistoryQuery, callerID: String,
                                allWorkspace: Bool = false) throws -> GatewayJSONValue {
    try transaction {
      var query = input
      query.callerConversationID = callerID
      guard query.schemaVersion == 1, (1...200).contains(query.limit), query.after >= 0,
            query.offset >= 0, query.offset < Int.max, (1...65536).contains(query.characters) else {
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
        let rows = try historyRowsUnlocked(lookup, values: [id])
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
      let ids = (result.objectValue?["rows"]?.arrayValue ?? []).compactMap { $0.objectValue?["id"]?.stringValue }
      try recordHistoryUnlocked(.init(conversationID: callerID, harness: "wovenmatter", kind: "cli.history.read",
        payload: try toolsJSON(["command": query.command, "resultIDs": ids.joined(separator: ",")])))
      var object = result.objectValue ?? [:]
      object["scope"] = .string(scope)
      return .object(object)
    }
  }
}
