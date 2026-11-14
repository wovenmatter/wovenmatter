import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Archive projection only. This path must never call a command dispatcher or runtime.
  func projectExecutionJournalUnlocked(_ entry: ExecutionJournalEntry, workspace: ExecutionWorkspace) throws {
    let ownership = try prepareUnlocked("SELECT workspace_id,deleted FROM execution_conversations WHERE id = ?")
    defer { sqlite3_finalize(ownership) }
    try bind(entry.conversationID, at: 1, to: ownership)
    let existingCode = sqlite3_step(ownership)
    var exists = existingCode == SQLITE_ROW
    guard exists || existingCode == SQLITE_DONE else { throw stepError() }
    if exists {
      guard try text(ownership, column: 0) == workspace.id else { throw federationError("wrong_owner", "This conversation belongs to another execution workspace.") }
      // Delayed records still archive after trashing a conversation. Its
      // tombstone remains until an explicit restore, so one late record cannot
      // stall the entire origin's contiguous journal or resurrect the view.
    } else {
      guard entry.kind == .conversation else { throw federationError("unknown_conversation", "Archive the conversation identity before its execution records.") }
    }
    let collidesWithLocalConversation = !exists ? try federationScalarUnlocked("SELECT COUNT(*) FROM conversations WHERE id = ?", bindings: [entry.conversationID]) != 0 : false
    if entry.retainedExecution != nil || collidesWithLocalConversation {
      try acceptRetainedExecutionIdentityUnlocked(entry, workspace: workspace)
      exists = true
    }
    if let runID = entry.runID { try claimFederationRunUnlocked(runID, conversationID: entry.conversationID, workspaceID: workspace.id) }
    let now = Self.timestamp(Date())
    switch entry.kind {
    case .conversation, .restoredConversation:
      guard var conversation = entry.conversation, conversation.id == entry.conversationID,
            entry.transcript == nil, entry.receipt == nil, entry.nativeRecord == nil,
            conversation.workspaceID == nil || conversation.workspaceID == workspace.id,
            conversation.libraryID == nil || conversation.libraryID == workspace.libraryID,
            conversation.title.utf8.count <= 4_096 else {
        throw federationError("invalid_event", "Conversation metadata must match its immutable execution owner.")
      }
      if let runID = conversation.activeRunID { try claimFederationRunUnlocked(runID, conversationID: entry.conversationID, workspaceID: workspace.id) }
      conversation.workspaceID = workspace.id; conversation.libraryID = workspace.libraryID
      if exists {
        if entry.retainedExecution != nil { conversation.activeRunID = try federationConversationUnlocked(entry.conversationID)?.activeRunID }
        let canonical = try prepareUnlocked("SELECT title,folder_id,is_pinned FROM conversations WHERE id=?")
        defer { sqlite3_finalize(canonical) }
        try bind(entry.conversationID, at: 1, to: canonical)
        if sqlite3_step(canonical) == SQLITE_ROW {
          conversation.title = try text(canonical, column: 0)
          conversation.folderID = optionalText(canonical, column: 1)
          conversation.isPinned = sqlite3_column_int(canonical, 2) != 0
        }
      }
      if let folderID = conversation.folderID, try libraryFolderUnlocked(id: folderID) == nil { conversation.folderID = nil }
      if entry.kind == .restoredConversation {
        try toolsExecuteUnlocked("UPDATE execution_conversations SET deleted=0 WHERE id=?", [entry.conversationID])
        try toolsExecuteUnlocked("UPDATE conversations SET deleted_at=NULL,is_archived=0 WHERE id=?", [entry.conversationID])
      }
      let statement = try prepareUnlocked("INSERT INTO execution_conversations(id,workspace_id,conversation) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET conversation=excluded.conversation")
      defer { sqlite3_finalize(statement) }
      try bind(conversation.id, at: 1, to: statement); try bind(workspace.id, at: 2, to: statement)
      try bindJSON(conversation, at: 3, to: statement); try stepDone(statement)
      try toolsExecuteUnlocked("""
        INSERT INTO conversations(id,title,last_message_preview,folder_id,created_at,updated_at)
        VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET title=excluded.title,last_message_preview=excluded.last_message_preview,
        folder_id=excluded.folder_id,updated_at=excluded.updated_at
        """, [conversation.id, conversation.title, conversation.preview, conversation.folderID,
                         now, conversation.updatedAt.isEmpty ? now : conversation.updatedAt])
    case .transcript:
      guard let incoming = entry.transcript, incoming.conversationID == entry.conversationID,
            incoming.olderCursor == nil, entry.conversation == nil, entry.receipt == nil, entry.nativeRecord == nil,
            incoming.messages.allSatisfy({ $0.conversationID == entry.conversationID && !$0.id.isEmpty && $0.id.utf8.count <= 256 && ["user", "assistant", "system", "tool"].contains($0.role) }),
            incoming.activities.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 }),
            (incoming.removedMessageIDs ?? []).allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
        throw federationError("invalid_event", "Transcript records must belong to their conversation and include explicit stable message identities.")
      }
      // An entry upserts rows; the transcript is built from them on read.
      let previousActiveRunID = try libraryIDsUnlocked("SELECT active_run_id FROM execution_conversations WHERE id=? AND active_run_id IS NOT NULL",
                                                       bindings: [entry.conversationID]).first
      // Delete exact legacy tool-only rows that structured activities
      // replace. The immutable native journal stays intact. User input cannot
      // be hidden by structured-tool migration.
      let removed = Set(incoming.removedMessageIDs ?? [])
      for id in removed.sorted() {
        guard try federationScalarUnlocked("SELECT COUNT(*) FROM messages WHERE id=? AND conversation_id=? AND role='user'",
                                           bindings: [id, entry.conversationID]) == 0 else {
          throw federationError("invalid_event", "Structured-tool migration cannot hide user messages.")
        }
        try toolsExecuteUnlocked("DELETE FROM messages WHERE id=? AND conversation_id=?", [id, entry.conversationID])
      }
      for message in incoming.messages where !removed.contains(message.id) || message.role == "user" {
        guard message.agentSourceID == nil || (UUID(uuidString: message.agentSourceID!) != nil && message.role == "user" && message.isAgentAuthored != false),
              message.isAgentAuthored != true || message.agentSourceID != nil,
              (message.senderSessionTitle?.utf8.count ?? 0) <= 4_096,
              (message.senderHarness?.utf8.count ?? 0) <= 128,
              message.senderKind == nil || WorkspaceSessionDeliveryKind(rawValue: message.senderKind!) != nil else {
          throw federationError("invalid_event", "Agent message provenance requires a source session and a supported delivery kind.")
        }
        // Recorded provenance makes a message agent-authored for good.
        if let prior = try historyRowsUnlocked("SELECT source_id,kind FROM message_provenance WHERE message_id=?", values: [message.id]).first?.objectValue {
          guard prior["source_id"]?.stringValue == message.agentSourceID,
                prior["kind"]?.stringValue == message.senderKind ?? "message" else {
            throw federationError("wrong_owner", "A message's agent provenance cannot change.")
          }
        }
        if let runID = message.runID { try claimFederationRunUnlocked(runID, conversationID: entry.conversationID, workspaceID: workspace.id) }
        let previous = try prepareUnlocked("SELECT conversation_id,run_id,role FROM messages WHERE id=?")
        defer { sqlite3_finalize(previous) }
        try bind(message.id, at: 1, to: previous)
        let previousCode = sqlite3_step(previous)
        if previousCode == SQLITE_ROW {
          // A phone may attach its native run to a message of this
          // conversation (checked below), whose execution this workspace
          // owns (checked above).
          let priorRun = optionalText(previous, column: 1)
          let canBackfillNativeRun = try workspace.kind == .ios && priorRun == nil && message.sequence != nil && message.runID.map { run in
            try (incoming.runs ?? []).contains(where: { $0.id == run })
              || federationScalarUnlocked("SELECT COUNT(*) FROM runs WHERE id=? AND conversation_id=? AND position IS NOT NULL",
                                          bindings: [run, entry.conversationID]) != 0
          } == true
          guard try text(previous, column: 0) == entry.conversationID,
                priorRun == message.runID || canBackfillNativeRun,
                try text(previous, column: 2) == message.role else {
            throw federationError("wrong_owner", "A message's conversation, run and role cannot change.")
          }
        } else if previousCode != SQLITE_DONE { throw stepError() }
        // A new message takes the next position; an updated one keeps its place.
        try toolsExecuteUnlocked("""
          INSERT INTO messages(id,conversation_id,run_id,role,content,status,created_at,updated_at,sequence,attachment_references,position)
          VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,(SELECT COALESCE(MAX(position),0)+1 FROM messages WHERE conversation_id=?2 AND position IS NOT NULL))
          ON CONFLICT(id) DO UPDATE SET content=excluded.content,status=excluded.status,created_at=excluded.created_at,updated_at=excluded.updated_at,
          run_id=COALESCE(messages.run_id,excluded.run_id),sequence=excluded.sequence,attachment_references=excluded.attachment_references
          """, [message.id, entry.conversationID, message.runID, message.role, message.content, message.status ?? "", message.createdAt, now,
                message.sequence.map(String.init), try message.attachments.map { try toolsJSON($0) }])
        if let source = message.agentSourceID {
          try toolsExecuteUnlocked("""
            INSERT INTO message_provenance(message_id,source_id,source_title,source_agent,kind)
            VALUES (?,?,?,?,?) ON CONFLICT(message_id) DO NOTHING
            """, [message.id, source, message.senderSessionTitle, message.senderHarness, message.senderKind ?? "message"])
        }
      }
      for activity in incoming.activities {
        try claimFederationRunUnlocked(activity.runID, conversationID: entry.conversationID, workspaceID: workspace.id)
        let existingActivity = try libraryIDsUnlocked("SELECT conversation_id || '/' || run_id FROM run_activities WHERE id=?", bindings: [activity.id])
        guard existingActivity.isEmpty || existingActivity.first == entry.conversationID + "/" + activity.runID else {
          throw federationError("wrong_owner", "An activity identity belongs to another conversation.")
        }
        // The owner's projection is kept as it was sent; one this Mac cannot
        // read is replaced by the row's own title, detail and status.
        let content = try activity.projectionJSON.flatMap { json in
          (try? JSONDecoder().decode(AgentRunActivity.self, from: Data(json.utf8))).map { _ in json }
        } ?? toolsJSON(AgentRunActivity(id: activity.id, kind: .activity, title: activity.title, detail: activity.detail, status: activity.status))
        try toolsExecuteUnlocked("""
          INSERT INTO run_activities(id,run_id,conversation_id,event_type,content,created_at,title,detail,status,details_record_id,is_transient,sequence,completed_at,position)
          VALUES (?1,?2,?3,'activity',?4,?5,?6,?7,?8,?9,?10,?11,?12,
            (SELECT COALESCE(MAX(position),0)+1 FROM run_activities WHERE conversation_id=?3 AND position IS NOT NULL))
          ON CONFLICT(id) DO UPDATE SET content=excluded.content,created_at=excluded.created_at,title=excluded.title,detail=excluded.detail,
          status=excluded.status,details_record_id=excluded.details_record_id,is_transient=excluded.is_transient,
          sequence=excluded.sequence,completed_at=excluded.completed_at
          """, [activity.id, activity.runID, entry.conversationID, content, activity.createdAt ?? "", activity.title, activity.detail,
                activity.status, activity.detailsRecordID, activity.isTransient.map { $0 ? "1" : "0" },
                activity.sequence.map(String.init), activity.completedAt])
      }
      if let runID = incoming.activeRunID { try claimFederationRunUnlocked(runID, conversationID: entry.conversationID, workspaceID: workspace.id) }
      var observedRuns = Set(incoming.messages.compactMap(\.runID) + incoming.activities.map(\.runID))
      if let active = incoming.activeRunID { observedRuns.insert(active) }
      for runID in observedRuns {
        try toolsExecuteUnlocked("""
          INSERT OR IGNORE INTO runs(id,conversation_id,status,created_at,updated_at)
          VALUES (?,?,'completed',?,?)
          """, [runID, entry.conversationID, now, now])
      }
      let activeRunID = incoming.activeRunID ?? (entry.runID != nil && entry.runID != previousActiveRunID ? previousActiveRunID : nil)
      if let previous = previousActiveRunID, previous != activeRunID {
        let terminal = incoming.messages.last(where: { $0.runID == previous && $0.role == "assistant" })?.status ?? "completed"
        let status = ["completed", "failed", "cancelled", "interrupted"].contains(terminal) ? terminal : "completed"
        try toolsExecuteUnlocked("UPDATE runs SET status=?,updated_at=?,completed_at=? WHERE id=?", [status, now, now, previous])
      }
      if let active = incoming.activeRunID {
        try toolsExecuteUnlocked("UPDATE runs SET status='running',updated_at=? WHERE id=?", [now, active])
      }
      for run in incoming.runs ?? [] {
        guard ["queued", "running", "completed", "failed", "cancelled", "interrupted"].contains(run.status),
              (run.startedAt?.utf8.count ?? 0) <= 128, (run.completedAt?.utf8.count ?? 0) <= 128 else {
          throw federationError("invalid_event", "Run metadata requires a supported status and bounded timestamps.")
        }
        try claimFederationRunUnlocked(run.id, conversationID: entry.conversationID, workspaceID: workspace.id)
        // A run joins the transcript's runs the first time the owner lists it.
        try toolsExecuteUnlocked("""
          INSERT INTO runs(id,conversation_id,status,created_at,updated_at,started_at,completed_at,user_message_id,assistant_message_id,position)
          VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,(SELECT COALESCE(MAX(position),0)+1 FROM runs WHERE conversation_id=?2 AND position IS NOT NULL))
          ON CONFLICT(id) DO UPDATE SET status=excluded.status,updated_at=excluded.updated_at,
          started_at=COALESCE(runs.started_at,excluded.started_at),completed_at=excluded.completed_at,
          user_message_id=COALESCE(excluded.user_message_id,runs.user_message_id),
          assistant_message_id=COALESCE(excluded.assistant_message_id,runs.assistant_message_id),
          position=COALESCE(runs.position,excluded.position)
          """, [run.id, entry.conversationID, run.status, run.startedAt ?? now, now, run.startedAt, run.completedAt,
                run.userMessageID, run.assistantMessageID])
      }
      try toolsExecuteUnlocked("UPDATE execution_conversations SET active_run_id=? WHERE id=?", [activeRunID, entry.conversationID])
      if var conversation = try federationConversationUnlocked(entry.conversationID) {
        conversation.activeRunID = activeRunID
        if let message = incoming.messages.last { conversation.preview = String(message.content.prefix(300)) }
        conversation.updatedAt = now
        let update = try prepareUnlocked("UPDATE execution_conversations SET conversation = ? WHERE id = ?")
        defer { sqlite3_finalize(update) }
        try bindJSON(conversation, at: 1, to: update); try bind(entry.conversationID, at: 2, to: update); try stepDone(update)
        try toolsExecuteUnlocked("UPDATE conversations SET last_message_preview=?,updated_at=? WHERE id=?", [conversation.preview, now, entry.conversationID])
      }
    case .receipt:
      guard let receipt = entry.receipt, entry.conversation == nil, entry.transcript == nil, entry.nativeRecord == nil,
            receipt.conversationID == entry.conversationID, federationID(receipt.commandID), federationID(receipt.deviceID),
            receipt.workspaceID == nil || receipt.workspaceID == workspace.id,
            receipt.libraryID == nil || receipt.libraryID == workspace.libraryID else {
        throw federationError("invalid_event", "The archived command receipt must identify its execution workspace and conversation.")
      }
      if let runID = receipt.runID { try claimFederationRunUnlocked(runID, conversationID: entry.conversationID, workspaceID: workspace.id) }
      let existing = try federationValuesUnlocked("SELECT payload FROM execution_receipts WHERE workspace_id=? AND command_id=?", bindings: [workspace.id, receipt.commandID], as: LibraryCommandReceipt.self).first
      if let existing {
        guard existing.deviceID == receipt.deviceID, existing.conversationID == receipt.conversationID,
              existing.runID == nil || existing.runID == receipt.runID,
              existing.status == .accepted || existing.status == .outcomeUnknown || existing == receipt else {
          throw federationError("receipt_conflict", "The command receipt cannot change its owner or replace a settled outcome.")
        }
      }
      let statement = try prepareUnlocked("INSERT INTO execution_receipts(workspace_id,command_id,device_id,payload) VALUES (?,?,?,?) ON CONFLICT(workspace_id,command_id) DO UPDATE SET payload=excluded.payload")
      defer { sqlite3_finalize(statement) }
      try bind(workspace.id, at: 1, to: statement); try bind(receipt.commandID, at: 2, to: statement)
      try bind(receipt.deviceID, at: 3, to: statement); try bindJSON(receipt, at: 4, to: statement); try stepDone(statement)
    case .nativeRecord:
      guard let part = entry.nativeRecord, entry.conversation == nil, entry.transcript == nil, entry.receipt == nil else {
        throw federationError("invalid_event", "Native history must contain only its immutable record part.")
      }
      try archiveLibraryNativeRecordUnlocked(part, entry: entry)
    case .deletedConversation:
      guard entry.conversation == nil, entry.transcript == nil, entry.receipt == nil, entry.nativeRecord == nil else { throw federationError("invalid_event", "A deletion event cannot contain executable or replacement data.") }
      try toolsExecuteUnlocked("UPDATE execution_conversations SET deleted=1 WHERE id=?", [entry.conversationID])
      try toolsExecuteUnlocked("UPDATE conversations SET deleted_at=?,updated_at=? WHERE id=?", [now, now, entry.conversationID])
    }
  }
  private func claimFederationRunUnlocked(_ runID: String, conversationID: String, workspaceID: String) throws {
    guard federationID(runID) else { throw federationError("invalid_event", "Runs require stable UUID identities.") }
    let statement = try prepareUnlocked("SELECT workspace_id,conversation_id FROM execution_runs WHERE id=?")
    defer { sqlite3_finalize(statement) }
    try bind(runID, at: 1, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_ROW {
      guard try text(statement, column: 0) == workspaceID, try text(statement, column: 1) == conversationID else {
        throw federationError("wrong_owner", "This run already belongs to another execution workspace or conversation.")
      }
    } else {
      guard code == SQLITE_DONE else { throw stepError() }
      guard try federationScalarUnlocked("SELECT COUNT(*) FROM runs WHERE id=?", bindings: [runID]) == 0 else {
        throw federationError("wrong_owner", "An existing local run cannot be claimed by an execution archive.")
      }
      try toolsExecuteUnlocked("INSERT INTO execution_runs VALUES (?,?,?)", [runID, workspaceID, conversationID])
    }
  }
}
