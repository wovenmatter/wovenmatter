import Foundation
import Darwin
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

extension WorkspaceDatabaseConnection {
  /// Complete file export streams one stored row at a time. Display/retrieval
  /// windows and the bounded in-memory export do not limit this additional copy.
  func streamConversationArchive(id: String, to temporaryURL: URL) throws {
    guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked(),
      let conversation = try historyRowsUnlocked("""
        SELECT * FROM dashboard_conversations WHERE id=? AND (user_id=? OR desktop_owned=1)
          AND deleted_at IS NULL AND is_archived=0 AND governing_plane='wovenmatter_macos'
        """, values: [id, operatorID]).first else { throw WorkspaceConversationActionError.unavailable }
    guard FileManager.default.createFile(atPath: temporaryURL.path, contents: nil,
      attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
    let output = try FileHandle(forWritingTo: temporaryURL)
    defer { try? output.close() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    func write(_ value: String) throws { try output.write(contentsOf: Data(value.utf8)) }
    try write("{\"schemaVersion\":2,\"format\":\"woven-native-run-archive\",\"exportedAt\":")
    try output.write(contentsOf: encoder.encode(Self.timestamp(Date())))
    try write(",\"conversation\":")
    try output.write(contentsOf: encoder.encode(conversation))
    let runPredicate = "conversation_id=? OR run_id IN (SELECT id FROM dashboard_runs WHERE conversation_id=?)"
    let sections: [(String, String, [String?])] = [
      ("messages", "SELECT * FROM dashboard_messages WHERE conversation_id=? ORDER BY created_at,rowid", [id]),
      ("runs", "SELECT * FROM dashboard_runs WHERE conversation_id=? ORDER BY created_at,rowid", [id]),
      ("attachments", "SELECT * FROM dashboard_message_attachments WHERE conversation_id=? OR message_id IN (SELECT id FROM dashboard_messages WHERE conversation_id=?) ORDER BY created_at,rowid", [id,id]),
      ("references", "SELECT * FROM dashboard_message_references WHERE conversation_id=? OR message_id IN (SELECT id FROM dashboard_messages WHERE conversation_id=?) ORDER BY created_at,rowid", [id,id]),
      ("activities", "SELECT * FROM dashboard_run_events WHERE \(runPredicate) ORDER BY created_at,rowid", [id,id]),
      ("historyEvents", "SELECT * FROM workspace_history_events WHERE \(runPredicate) ORDER BY sequence", [id,id]),
      ("traceEvents", "SELECT * FROM dashboard_run_trace_events WHERE \(runPredicate) ORDER BY created_at,seq,id", [id,id]),
      ("deliveries", "SELECT * FROM workspace_session_deliveries WHERE message_id IN (SELECT id FROM dashboard_messages WHERE conversation_id=?) ORDER BY created_at,rowid", [id]),
    ]
    for (name, sql, bindings) in sections {
      try write(",\"\(name)\":[")
      var first = true
      try forEachHistoryRowUnlocked(sql, values: bindings, redactingCapabilities: true) { row in
        if !first { try write(",") }
        first = false
        try output.write(contentsOf: encoder.encode(row))
      }
      try write("]")
    }
    try write("}\n")
    try output.synchronize()
  }

  public func conversationExport(id: String, format: WorkspaceConversationExportFormat) throws -> Data {
    try conversationExport(id: id, format: format, budget: WorkspaceExportBudget())
  }

  func conversationExport(id: String, format: WorkspaceConversationExportFormat, budget: WorkspaceExportBudget) throws -> Data {
    // One transaction keeps metadata, messages and events at the same point in time.
    try transaction {
      guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked(),
            let _ = try historyRowsUnlocked("""
              SELECT id FROM dashboard_conversations WHERE id = ? AND (user_id = ? OR desktop_owned = 1)
                AND deleted_at IS NULL AND is_archived = 0 AND governing_plane = 'wovenmatter_macos'
              """, values: [id, operatorID]).first else { throw WorkspaceConversationActionError.unavailable }
      var budget = budget
      try checkConversationExportBudget(id: id, format: format, budget: &budget)
      guard let conversation = try historyRowsUnlocked("SELECT * FROM dashboard_conversations WHERE id = ?", values: [id]).first else {
        throw WorkspaceConversationActionError.unavailable
      }
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
        return try WorkspaceExportBudget.checked(Data((sections.joined(separator: "\n\n") + "\n").utf8))
      case .fullRun:
        let export = ConversationRunExport(exportedAt: Self.timestamp(Date()), conversation: conversation,
          content: content, activities: try runActivityRecordsUnlocked(conversationID: id),
          historyEvents: try historyRowsUnlocked("""
            SELECT * FROM workspace_history_events WHERE conversation_id = ?
              OR run_id IN (SELECT id FROM dashboard_runs WHERE conversation_id = ?)
            ORDER BY sequence
            """, values: [id, id]),
          events: try historyRowsUnlocked("SELECT * FROM dashboard_run_events WHERE conversation_id = ? ORDER BY created_at, rowid", values: [id]),
          traceEvents: try historyRowsUnlocked("SELECT * FROM dashboard_run_trace_events WHERE conversation_id = ? ORDER BY created_at, seq, id", values: [id]))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try WorkspaceExportBudget.checked(encoder.encode(export))
        return try WorkspaceExportBudget.checked(Data(WorkspaceHistoryPrivacy.redactingToolEndpoints(String(decoding: encoded, as: UTF8.self)).utf8))
      }
    }
  }
}

extension WorkspaceDatabase {
  public func exportConversationArchive(id: String, to destinationURL: URL) async throws {
    let temporaryURL = destinationURL.deletingLastPathComponent()
      .appending(path: ".wovenmatter-archive-" + UUID().uuidString.lowercased() + ".partial")
    defer { try? FileManager.default.removeItem(at: temporaryURL) }
    // Reader snapshot and SQLite cancellation cover streaming. A failed or
    // cancelled query leaves the selected destination intact.
    try await read(timeout: 300) { try $0.streamConversationArchive(id: id, to: temporaryURL) }
    try await WorkspaceExportFileIO.perform {
      let status = temporaryURL.path.withCString { source in
        destinationURL.path.withCString { destination in Darwin.rename(source, destination) }
      }
      guard status == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
  }

  public func conversationExport(id: String, format: WorkspaceConversationExportFormat) async throws -> Data {
    try await read { try $0.conversationExport(id: id, format: format) }
  }
}
