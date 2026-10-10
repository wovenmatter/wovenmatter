import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  /// Archive projection only. This path must never call a command dispatcher or runtime.
  func projectCompanionJournalUnlocked(_ entry: CompanionJournalEntry, workspace: CompanionExecutionWorkspace) throws {
    let ownership = try prepareUnlocked("SELECT workspace_id,deleted FROM companion_execution_conversations WHERE id = ?")
    defer { sqlite3_finalize(ownership) }
    try bind(entry.conversationID, at: 1, to: ownership)
    let existingCode = sqlite3_step(ownership)
    let exists = existingCode == SQLITE_ROW
    guard exists || existingCode == SQLITE_DONE else { throw stepError() }
    if exists {
      guard try text(ownership, column: 0) == workspace.id else { throw federationError("wrong_owner", "This conversation belongs to another execution workspace.") }
      // Delayed records still archive after trashing a conversation. Its
      // tombstone remains until an explicit restore, so one late record cannot
      // stall the entire origin's contiguous journal or resurrect the view.
    } else {
      guard entry.kind == .conversation,
            try federationScalarUnlocked("SELECT COUNT(*) FROM dashboard_conversations WHERE id = ?", bindings: [entry.conversationID]) == 0 else {
        throw federationError("unknown_conversation", "Archive the conversation identity before its execution records; existing local identities cannot be claimed.")
      }
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
        let canonical = try prepareUnlocked("SELECT title,folder_id,is_pinned FROM dashboard_conversations WHERE id=?")
        defer { sqlite3_finalize(canonical) }
        try bind(entry.conversationID, at: 1, to: canonical)
        if sqlite3_step(canonical) == SQLITE_ROW {
          conversation.title = try text(canonical, column: 0)
          conversation.folderID = optionalText(canonical, column: 1)
          conversation.isPinned = sqlite3_column_int(canonical, 2) != 0
        }
      }
      if let folderID = conversation.folderID, try companionFolderUnlocked(id: folderID) == nil { conversation.folderID = nil }
      if entry.kind == .restoredConversation {
        try companionExecuteUnlocked("UPDATE companion_execution_conversations SET deleted=0 WHERE id=?", values: [entry.conversationID])
        try companionExecuteUnlocked("UPDATE dashboard_conversations SET deleted_at=NULL,is_archived=0 WHERE id=?", values: [entry.conversationID])
      }
      let statement = try prepareUnlocked("INSERT INTO companion_execution_conversations(id,workspace_id,conversation) VALUES (?,?,?) ON CONFLICT(id) DO UPDATE SET conversation=excluded.conversation")
      defer { sqlite3_finalize(statement) }
      try bind(conversation.id, at: 1, to: statement); try bind(workspace.id, at: 2, to: statement)
      try bind(JSONEncoder().encode(conversation), at: 3, to: statement); try stepDone(statement)
      try companionExecuteUnlocked("""
        INSERT INTO dashboard_conversations(id,user_id,title,last_message_preview,folder_id,authority_device_id,origin_device_id,created_at,updated_at,desktop_owned)
        VALUES (?,?,?,?,?,?,?,?,?,1) ON CONFLICT(id) DO UPDATE SET title=excluded.title,last_message_preview=excluded.last_message_preview,
        folder_id=excluded.folder_id,updated_at=excluded.updated_at
        """, values: [conversation.id, try localMutationOperatorIDUnlocked(), conversation.title, conversation.preview, conversation.folderID,
                         workspace.ownerDeviceID, workspace.ownerDeviceID, now, conversation.updatedAt.isEmpty ? now : conversation.updatedAt])
    case .transcript:
      guard let incoming = entry.transcript, incoming.conversationID == entry.conversationID,
            incoming.olderCursor == nil, entry.conversation == nil, entry.receipt == nil, entry.nativeRecord == nil,
            incoming.messages.allSatisfy({ $0.conversationID == entry.conversationID && !$0.id.isEmpty && $0.id.utf8.count <= 256 && ["user", "assistant", "system", "tool"].contains($0.role) }),
            incoming.activities.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 256 }) else {
        throw federationError("invalid_event", "Transcript records must belong to their conversation and include explicit stable message identities.")
      }
      var transcript = try federationValuesUnlocked("SELECT transcript FROM companion_execution_conversations WHERE id = ? AND transcript IS NOT NULL", bindings: [entry.conversationID], as: CompanionTranscript.self).first ?? CompanionTranscript(conversationID: entry.conversationID)
      for message in incoming.messages {
        if let runID = message.runID { try claimFederationRunUnlocked(runID, conversationID: entry.conversationID, workspaceID: workspace.id) }
        let previous = try prepareUnlocked("SELECT conversation_id,run_id,role FROM dashboard_messages WHERE id=?")
        defer { sqlite3_finalize(previous) }
        try bind(message.id, at: 1, to: previous)
        let previousCode = sqlite3_step(previous)
        if previousCode == SQLITE_ROW {
          guard try text(previous, column: 0) == entry.conversationID,
                optionalText(previous, column: 1) == message.runID,
                try text(previous, column: 2) == message.role else {
            throw federationError("wrong_owner", "A message's conversation, run and role cannot change.")
          }
        } else if previousCode != SQLITE_DONE { throw stepError() }
        if let index = transcript.messages.firstIndex(where: { $0.id == message.id }) { transcript.messages[index] = message }
        else { transcript.messages.append(message) }
        try companionExecuteUnlocked("""
          INSERT INTO dashboard_messages(id,conversation_id,run_id,role,content,status,authority_device_id,origin_device_id,created_at,updated_at,desktop_owned)
          VALUES (?,?,?,?,?,?,?,?,?,?,1) ON CONFLICT(id) DO UPDATE SET content=excluded.content,status=excluded.status,updated_at=excluded.updated_at
          """, values: [message.id, entry.conversationID, message.runID, message.role, message.content, message.status ?? "completed",
                           workspace.ownerDeviceID, workspace.ownerDeviceID, message.createdAt.isEmpty ? now : message.createdAt, now])
      }
      for activity in incoming.activities {
        try claimFederationRunUnlocked(activity.runID, conversationID: entry.conversationID, workspaceID: workspace.id)
        if let index = transcript.activities.firstIndex(where: { $0.id == activity.id }) { transcript.activities[index] = activity }
        else { transcript.activities.append(activity) }
        let existingActivity = try companionIDsUnlocked("SELECT conversation_id || '/' || run_id FROM dashboard_run_events WHERE id=?", bindings: [activity.id])
        guard existingActivity.isEmpty || existingActivity.first == entry.conversationID + "/" + activity.runID else {
          throw federationError("wrong_owner", "An activity identity belongs to another conversation.")
        }
        let display = AgentRunActivity(id: activity.id, kind: .activity, title: activity.title, detail: activity.detail, status: activity.status)
        let encoded = String(decoding: try JSONEncoder().encode(display), as: UTF8.self)
        try companionExecuteUnlocked("""
          INSERT INTO dashboard_run_events(id,run_id,conversation_id,user_id,authority_device_id,origin_device_id,desktop_owned,event_type,content,created_at)
          VALUES (?,?,?,?,?,?,1,'activity',?,?) ON CONFLICT(id) DO UPDATE SET content=excluded.content
          """, values: [activity.id, activity.runID, entry.conversationID, try localMutationOperatorIDUnlocked(),
                           workspace.executionDeviceID ?? workspace.ownerDeviceID, workspace.ownerDeviceID, encoded, now])
      }
      if let runID = incoming.activeRunID { try claimFederationRunUnlocked(runID, conversationID: entry.conversationID, workspaceID: workspace.id) }
      var observedRuns = Set(incoming.messages.compactMap(\.runID) + incoming.activities.map(\.runID))
      if let active = incoming.activeRunID { observedRuns.insert(active) }
      for runID in observedRuns {
        try companionExecuteUnlocked("""
          INSERT OR IGNORE INTO dashboard_runs(id,conversation_id,user_id,status,authority_device_id,origin_device_id,desktop_owned,created_at,updated_at)
          VALUES (?,?,?,'completed',?,?,1,?,?)
          """, values: [runID, entry.conversationID, try localMutationOperatorIDUnlocked(), workspace.executionDeviceID ?? workspace.ownerDeviceID,
                         workspace.ownerDeviceID, now, now])
      }
      if let previous = transcript.activeRunID, previous != incoming.activeRunID {
        let terminal = incoming.messages.last(where: { $0.runID == previous && $0.role == "assistant" })?.status ?? "completed"
        let status = ["completed", "failed", "cancelled", "interrupted"].contains(terminal) ? terminal : "completed"
        try companionExecuteUnlocked("UPDATE dashboard_runs SET status=?,updated_at=?,completed_at=? WHERE id=?", values: [status, now, now, previous])
      }
      if let active = incoming.activeRunID {
        try companionExecuteUnlocked("UPDATE dashboard_runs SET status='running',updated_at=? WHERE id=?", values: [now, active])
      }
      transcript.activeRunID = incoming.activeRunID
      let statement = try prepareUnlocked("UPDATE companion_execution_conversations SET transcript = ? WHERE id = ?")
      defer { sqlite3_finalize(statement) }
      try bind(JSONEncoder().encode(transcript), at: 1, to: statement); try bind(entry.conversationID, at: 2, to: statement); try stepDone(statement)
      if var conversation = try federationConversationUnlocked(entry.conversationID) {
        conversation.activeRunID = incoming.activeRunID
        if let message = incoming.messages.last { conversation.preview = String(message.content.prefix(300)) }
        conversation.updatedAt = now
        let update = try prepareUnlocked("UPDATE companion_execution_conversations SET conversation = ? WHERE id = ?")
        defer { sqlite3_finalize(update) }
        try bind(JSONEncoder().encode(conversation), at: 1, to: update); try bind(entry.conversationID, at: 2, to: update); try stepDone(update)
        try companionExecuteUnlocked("UPDATE dashboard_conversations SET last_message_preview=?,updated_at=? WHERE id=?", values: [conversation.preview, now, entry.conversationID])
      }
    case .receipt:
      guard let receipt = entry.receipt, entry.conversation == nil, entry.transcript == nil, entry.nativeRecord == nil,
            receipt.conversationID == entry.conversationID, federationID(receipt.commandID), federationID(receipt.deviceID),
            receipt.workspaceID == nil || receipt.workspaceID == workspace.id,
            receipt.libraryID == nil || receipt.libraryID == workspace.libraryID else {
        throw federationError("invalid_event", "The archived command receipt must identify its execution workspace and conversation.")
      }
      if let runID = receipt.runID { try claimFederationRunUnlocked(runID, conversationID: entry.conversationID, workspaceID: workspace.id) }
      let existing = try federationValuesUnlocked("SELECT payload FROM companion_execution_receipts WHERE workspace_id=? AND command_id=?", bindings: [workspace.id, receipt.commandID], as: CompanionCommandReceipt.self).first
      if let existing {
        guard existing.deviceID == receipt.deviceID, existing.conversationID == receipt.conversationID,
              existing.runID == nil || existing.runID == receipt.runID,
              existing.status == .accepted || existing.status == .outcomeUnknown || existing == receipt else {
          throw federationError("receipt_conflict", "The command receipt cannot change its owner or replace a settled outcome.")
        }
      }
      let statement = try prepareUnlocked("INSERT INTO companion_execution_receipts(workspace_id,command_id,device_id,payload) VALUES (?,?,?,?) ON CONFLICT(workspace_id,command_id) DO UPDATE SET payload=excluded.payload")
      defer { sqlite3_finalize(statement) }
      try bind(workspace.id, at: 1, to: statement); try bind(receipt.commandID, at: 2, to: statement)
      try bind(receipt.deviceID, at: 3, to: statement); try bind(JSONEncoder().encode(receipt), at: 4, to: statement); try stepDone(statement)
    case .nativeRecord:
      guard let part = entry.nativeRecord, entry.conversation == nil, entry.transcript == nil, entry.receipt == nil else {
        throw federationError("invalid_event", "Native history must contain only its immutable record part.")
      }
      try archiveCompanionNativeRecordUnlocked(part, entry: entry)
    case .deletedConversation:
      guard entry.conversation == nil, entry.transcript == nil, entry.receipt == nil, entry.nativeRecord == nil else { throw federationError("invalid_event", "A deletion event cannot contain executable or replacement data.") }
      try companionExecuteUnlocked("UPDATE companion_execution_conversations SET deleted=1 WHERE id=?", values: [entry.conversationID])
      try companionExecuteUnlocked("UPDATE dashboard_conversations SET deleted_at=?,updated_at=? WHERE id=?", values: [now, now, entry.conversationID])
    }
  }
  private func claimFederationRunUnlocked(_ runID: String, conversationID: String, workspaceID: String) throws {
    guard federationID(runID) else { throw federationError("invalid_event", "Runs require stable UUID identities.") }
    let statement = try prepareUnlocked("SELECT workspace_id,conversation_id FROM companion_execution_runs WHERE id=?")
    defer { sqlite3_finalize(statement) }
    try bind(runID, at: 1, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_ROW {
      guard try text(statement, column: 0) == workspaceID, try text(statement, column: 1) == conversationID else {
        throw federationError("wrong_owner", "This run already belongs to another execution workspace or conversation.")
      }
    } else {
      guard code == SQLITE_DONE else { throw stepError() }
      guard try federationScalarUnlocked("SELECT COUNT(*) FROM dashboard_runs WHERE id=?", bindings: [runID]) == 0 else {
        throw federationError("wrong_owner", "An existing local run cannot be claimed by an execution archive.")
      }
      try companionExecuteUnlocked("INSERT INTO companion_execution_runs VALUES (?,?,?)", values: [runID, workspaceID, conversationID])
    }
  }
}
