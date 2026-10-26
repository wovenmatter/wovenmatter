import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  func publishConversationHTML(_ page: ConversationHTMLPage, callerID: String, requestID: String) throws -> ConversationHTMLRenderReference {
    try transaction {
      try requireToolUnlocked(.html, sessionID: callerID)
      let requestID = try canonicalToolRequestID(requestID)
      try requireAutomationNotCancelled(callerID: callerID, requestID: requestID)
      let activityID = "html-render:" + requestID
      let payload = String(decoding: try JSONEncoder().encode(page), as: UTF8.self)
      let prior = try historyRowsUnlocked("""
        SELECT content FROM dashboard_run_events
        WHERE conversation_id=? AND id LIKE ?
        """, values: [callerID, "%:activity:" + activityID]).first?.objectValue?["content"]?.stringValue
      if let prior {
        let saved = try JSONDecoder().decode(AgentRunActivity.self, from: Data(prior.utf8))
        guard let raw = saved.rawOutputJSON,
              try JSONDecoder().decode(ConversationHTMLPage.self, from: Data(raw.utf8)) == page,
              let reference = saved.htmlRender else {
          throw WorkspaceToolError.invalid("This HTML request ID was already used for a different page.")
        }
        return reference
      }
      guard let runID = try historyRowsUnlocked("""
        SELECT id FROM dashboard_runs WHERE conversation_id=? AND status='running'
          AND authority_kind='device_owned' ORDER BY created_at DESC LIMIT 1
        """, values: [callerID]).first?.objectValue?["id"]?.stringValue else {
        throw WorkspaceToolError.invalid("HTML pages can only be published by an active run in this conversation.")
      }
      let reference = ConversationHTMLRenderReference(id: requestID, title: page.title, height: page.height)
      try upsertDeviceOwnedRunActivityUnlocked(runID: runID,
        activity: .init(id: activityID, kind: .activity, phase: "completed", title: page.title,
          status: "completed", toolName: "html_render", rawOutputJSON: payload, htmlRender: reference),
        appendingContent: false, updatedAt: Date())
      return reference
    }
  }
}

extension WorkspaceDatabase {
  public func publishConversationHTML(_ page: ConversationHTMLPage, callerID: String, requestID: String) async throws -> ConversationHTMLRenderReference {
    try await write { try $0.publishConversationHTML(page, callerID: callerID, requestID: requestID) }
  }
}
