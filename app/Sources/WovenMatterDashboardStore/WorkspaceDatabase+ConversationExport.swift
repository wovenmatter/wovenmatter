import Foundation
import WovenMatterClient
import WovenMatterCore

private struct ConversationRunExport: Encodable {
  let schemaVersion = 1
  let historicalCoverage = "Exports retained history. Earlier raw events may not have been captured; attachment files are represented by metadata."
  let exportedAt: String
  let conversation: GatewayJSONValue
  let content: WorkspaceConversationContent
  let activities: [WorkspaceRunActivityRecord]
  let historyEvents: [GatewayJSONValue]
  let events: [GatewayJSONValue]
  let traceEvents: [GatewayJSONValue]
}

extension WorkspaceDatabase {
  public func conversationExport(id: String, format: WorkspaceConversationExportFormat) throws -> Data {
    // One transaction keeps metadata, messages and events at the same point in time.
    try transaction {
      guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked(),
            let conversation = try historyRowsUnlocked("""
              SELECT * FROM dashboard_conversations WHERE id = ? AND (user_id = ? OR desktop_owned = 1)
                AND deleted_at IS NULL AND is_archived = 0 AND governing_plane = 'wovenmatter_macos'
              """, values: [id, operatorID]).first else { throw WorkspaceConversationActionError.unavailable }
      let content = try conversationContentUnlocked(id: id)
      switch format {
      case .messages:
        let title = conversation.objectValue?["title"]?.stringValue ?? "Chat"
        var sections = ["# " + title]
        let attachments = Dictionary(grouping: content.attachments, by: \.messageID)
        let references = Dictionary(grouping: content.references, by: \.messageID)
        for message in content.messages {
          var section = "## \(message.role.capitalized) · \(message.createdAt)\n\n\(message.content)"
          for attachment in attachments[message.id, default: []] {
            section += "\n\nAttachment: \(attachment.fileName) (\(attachment.mimeType), \(attachment.sizeBytes) bytes)"
          }
          for reference in references[message.id, default: []] {
            section += "\n\n### Reference: \(reference.titleSnapshot)\n\n\(reference.contentSnapshot)"
          }
          sections.append(section)
        }
        return Data((sections.joined(separator: "\n\n") + "\n").utf8)
      case .fullRun:
        let export = ConversationRunExport(exportedAt: Self.timestamp(Date()), conversation: conversation,
          content: content, activities: try runActivityRecordsUnlocked(runIDs: content.runs.map(\.id)),
          historyEvents: try historyRowsUnlocked("""
            SELECT * FROM workspace_history_events WHERE conversation_id = ?
              OR run_id IN (SELECT id FROM dashboard_runs WHERE conversation_id = ?)
            ORDER BY sequence
            """, values: [id, id]),
          events: try historyRowsUnlocked("SELECT * FROM dashboard_run_events WHERE conversation_id = ? ORDER BY created_at, rowid", values: [id]),
          traceEvents: try historyRowsUnlocked("SELECT * FROM dashboard_run_trace_events WHERE conversation_id = ? ORDER BY created_at, seq, id", values: [id]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(export)
      }
    }
  }
}
