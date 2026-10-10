import Foundation
import SQLite3
import WovenMatterCore

extension WorkspaceDatabaseConnection {
  public func companionLibraryIdentity() throws -> CompanionLibraryIdentity {
    try withLock { try companionLibraryIdentityUnlocked() }
  }
  func companionLibraryIdentityUnlocked() throws -> CompanionLibraryIdentity {
    let ids = try companionIDsUnlocked("SELECT host_device_id FROM companion_library_identity WHERE singleton = 1", bindings: [])
    guard let deviceID = ids.first else { throw WorkspaceDatabaseError.corruptRow }
    return try CompanionLibraryIdentity(libraryID: companionWorkspaceIDUnlocked(), hostDeviceID: deviceID)
  }
  public func companionExecutionWorkspaces() throws -> [CompanionExecutionWorkspace] {
    try withLock {
      try federationValuesUnlocked("SELECT payload FROM companion_execution_workspaces ORDER BY id", as: CompanionExecutionWorkspace.self)
    }
  }
  public func companionExecutionOwners() throws -> [String: String] {
    try withLock {
      let statement = try prepareUnlocked("SELECT id,workspace_id FROM companion_execution_conversations")
      defer { sqlite3_finalize(statement) }
      var values: [String: String] = [:]
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return values }
        guard code == SQLITE_ROW else { throw stepError() }
        values[try text(statement, column: 0)] = try text(statement, column: 1)
      }
    }
  }
  public func companionExecutionOwner(conversationID: String) throws -> String? {
    try withLock { try companionIDsUnlocked("SELECT workspace_id FROM companion_execution_conversations WHERE id=?", bindings: [conversationID]).first }
  }
  public func companionConversationExecutionWorkspace(conversationID: String) throws -> CompanionExecutionWorkspace? {
    try withLock {
      guard let id = try companionIDsUnlocked("SELECT workspace_id FROM companion_execution_conversations WHERE id=?", bindings: [conversationID]).first else { return nil }
      return try federationWorkspaceUnlocked(id)
    }
  }
  public func companionExecutionOriginCursor(workspaceID: String) throws -> Int64 {
    try withLock { try federationScalarUnlocked("SELECT COALESCE(MAX(origin_sequence),0) FROM companion_execution_journal WHERE workspace_id=?", bindings: [workspaceID]) }
  }
  func federationWorkspaceUnlocked(_ id: String) throws -> CompanionExecutionWorkspace? {
    try federationValuesUnlocked("SELECT payload FROM companion_execution_workspaces WHERE id = ?", bindings: [id], as: CompanionExecutionWorkspace.self).first
  }
  public func registerCompanionExecutionWorkspace(_ request: CompanionWorkspaceRegistration, deviceID: String) throws -> CompanionExecutionWorkspace {
    try transaction {
      var value = request.workspace
      let identity = try companionLibraryIdentityUnlocked()
      guard value.libraryID == (try companionWorkspaceIDUnlocked()) else { throw federationError("library_mismatch", "This workspace belongs to another central library.") }
      guard federationID(value.id), federationID(value.ownerDeviceID), (value.ownerDeviceID == deviceID || deviceID == identity.hostDeviceID),
            value.executionDeviceID.map(federationID) ?? true,
            !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.name.utf8.count <= 256,
            value.journalDeviceIDs.count <= 64, value.journalDeviceIDs.allSatisfy(federationID),
            value.capabilities.count <= 64, value.capabilities.allSatisfy({ $0.utf8.count <= 120 }),
            value.endpoint.map({ CompanionPairingPayload.isValidEndpoint($0) }) ?? true else {
        throw federationError("invalid_workspace", "Only a workspace owner can register its identity and grants with a private Tailscale endpoint.")
      }
      value.journalDeviceIDs = Array(Set(value.journalDeviceIDs)).sorted()
      value.capabilities = Array(Set(value.capabilities)).sorted()
      if let existing = try federationWorkspaceUnlocked(value.id) {
        guard existing.ownerDeviceID == value.ownerDeviceID, existing.kind == value.kind, (existing.executionDeviceID == nil || existing.executionDeviceID == value.executionDeviceID) else {
          throw federationError("wrong_owner", "The execution owner and workspace kind cannot change.")
        }
        value.revision = existing.revision
        if value == existing { return existing }
        guard !existing.deleted, request.expectedRevision == existing.revision else {
          throw federationError("revision_conflict", "The workspace changed or was deleted. Refresh before updating it.")
        }
        value.revision += 1
      } else {
        guard request.expectedRevision == nil, !value.deleted else {
          throw federationError("revision_conflict", "A new workspace cannot replace or resurrect an existing identity.")
        }
        value.revision = 1
      }
      let statement = try prepareUnlocked("INSERT INTO companion_execution_workspaces(id,owner_device_id,revision,deleted,payload) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,deleted=excluded.deleted,payload=excluded.payload")
      defer { sqlite3_finalize(statement) }
      try bind(value.id, at: 1, to: statement); try bind(value.ownerDeviceID, at: 2, to: statement)
      sqlite3_bind_int64(statement, 3, value.revision); sqlite3_bind_int(statement, 4, value.deleted ? 1 : 0)
      try bind(JSONEncoder().encode(value), at: 5, to: statement); try stepDone(statement)
      return value
    }
  }
  func federationAuthorizedWorkspaceUnlocked(_ id: String, deviceID: String) throws -> CompanionExecutionWorkspace {
    let hostDeviceID = try companionLibraryIdentityUnlocked().hostDeviceID
    guard let workspace = try federationWorkspaceUnlocked(id), !workspace.deleted,
          workspace.ownerDeviceID == deviceID || workspace.journalDeviceIDs.contains(deviceID) || deviceID == hostDeviceID else {
      throw federationError("wrong_owner", "This device is not authorized to publish this workspace's history or saved artifacts.")
    }
    return workspace
  }
  public func ingestCompanionJournal(_ batch: CompanionJournalBatch, deviceID: String) throws -> CompanionJournalBatchResult {
    try transaction {
      let libraryID = try companionWorkspaceIDUnlocked()
      guard batch.libraryID == libraryID else { throw federationError("library_mismatch", "History belongs to another library.") }
      guard batch.entries.count <= CompanionFederationProtocol.maximumBatchEntries,
            try JSONEncoder().encode(batch).count <= CompanionFederationProtocol.maximumBatchBytes else {
        throw federationError("too_large", "Upload execution history in smaller batches.")
      }
      for entry in batch.entries {
        let workspace = try federationAuthorizedWorkspaceUnlocked(entry.workspaceID, deviceID: deviceID)
        guard federationID(entry.eventID), federationID(entry.conversationID), entry.originSequence > 0,
              entry.runID.map(federationID) ?? true, try JSONEncoder().encode(entry).count <= 1_024 * 1_024 else {
          throw federationError("invalid_event", "Execution history requires stable UUID identities and bounded records.")
        }
        let fingerprint = try companionFingerprint(entry)
        let lookup = try prepareUnlocked("SELECT event_id,workspace_id,origin_sequence,fingerprint FROM companion_execution_journal WHERE event_id = ? OR (workspace_id = ? AND origin_sequence = ?)")
        defer { sqlite3_finalize(lookup) }
        try bind(entry.eventID, at: 1, to: lookup); try bind(entry.workspaceID, at: 2, to: lookup); sqlite3_bind_int64(lookup, 3, entry.originSequence)
        let code = sqlite3_step(lookup)
        if code == SQLITE_ROW {
          guard try text(lookup, column: 0) == entry.eventID, try text(lookup, column: 1) == entry.workspaceID,
                sqlite3_column_int64(lookup, 2) == entry.originSequence, try blob(lookup, column: 3) == fingerprint else {
            throw federationError("event_conflict", "An event identity or origin sequence was reused with different content.")
          }
          continue
        }
        guard code == SQLITE_DONE else { throw stepError() }
        let current = try federationScalarUnlocked("SELECT COALESCE(MAX(origin_sequence),0) FROM companion_execution_journal WHERE workspace_id = ?", bindings: [entry.workspaceID])
        guard entry.originSequence == current + 1 else {
          throw federationError("origin_gap", "Upload the missing execution history before acknowledging later records. Expected sequence \(current + 1).")
        }
        try projectCompanionJournalUnlocked(entry, workspace: workspace)
        let insert = try prepareUnlocked("INSERT INTO companion_execution_journal(event_id,workspace_id,origin_sequence,fingerprint,payload) VALUES (?,?,?,?,?)")
        defer { sqlite3_finalize(insert) }
        try bind(entry.eventID, at: 1, to: insert); try bind(entry.workspaceID, at: 2, to: insert)
        sqlite3_bind_int64(insert, 3, entry.originSequence); try bind(fingerprint, at: 4, to: insert)
        try bind(JSONEncoder().encode(entry), at: 5, to: insert); try stepDone(insert)
      }
      return try CompanionJournalBatchResult(libraryID: libraryID, acceptedEventIDs: batch.entries.map(\.eventID), cursor: federationJournalCursorUnlocked())
    }
  }
  public func companionJournal(after cursor: Int64, limit: Int = 200) throws -> CompanionJournalPage {
    try transaction {
      let current = try federationJournalCursorUnlocked()
      guard cursor >= 0, cursor <= current else { throw federationError("invalid_cursor", "The library journal cursor is invalid.") }
      let statement = try prepareUnlocked("SELECT cursor,payload FROM companion_execution_journal WHERE cursor > ? ORDER BY cursor LIMIT ?")
      defer { sqlite3_finalize(statement) }
      sqlite3_bind_int64(statement, 1, cursor); sqlite3_bind_int(statement, 2, Int32(max(1, min(limit, 200))))
      var entries: [CompanionJournalEntry] = []; var next = cursor; var bytes = 0
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { break }
        guard code == SQLITE_ROW else { throw stepError() }
        let payload = try blob(statement, column: 1)
        if !entries.isEmpty && bytes + payload.count > 4 * 1_024 * 1_024 { break }
        entries.append(try JSONDecoder().decode(CompanionJournalEntry.self, from: payload))
        next = sqlite3_column_int64(statement, 0); bytes += payload.count
      }
      return try CompanionJournalPage(libraryID: companionWorkspaceIDUnlocked(), cursor: next, entries: entries, hasMore: next < current)
    }
  }
  func federationJournalCursorUnlocked() throws -> Int64 {
    try federationScalarUnlocked("SELECT COALESCE(MAX(cursor),0) FROM companion_execution_journal")
  }
  public func companionFederatedTranscript(conversationID: String, before: String? = nil) throws -> CompanionTranscript? {
    try withLock {
      guard try federationConversationUnlocked(conversationID) != nil else { return nil }
      let stored = try federationValuesUnlocked("SELECT transcript FROM companion_execution_conversations WHERE id = ? AND deleted = 0 AND transcript IS NOT NULL", bindings: [conversationID], as: CompanionTranscript.self).first ?? CompanionTranscript(conversationID: conversationID)
      var end = FederationTranscriptCursor(messages: stored.messages.count, activities: stored.activities.count)
      if let before {
        guard before.utf8.count <= 2_048, let data = Data(base64Encoded: before),
              let cursor = try? JSONDecoder().decode(FederationTranscriptCursor.self, from: data),
              cursor.messages >= 0, cursor.messages <= stored.messages.count,
              cursor.activities >= 0, cursor.activities <= stored.activities.count else {
          throw federationError("invalid_cursor", "This transcript cursor is no longer valid.")
        }
        end = cursor
      }
      // Page both message and activity history without dropping older tool output.
      var messageStart = end.messages; var activityStart = end.activities; var bytes = 0
      while messageStart > 0, end.messages - messageStart < 80 {
        let size = try JSONEncoder().encode(stored.messages[messageStart - 1]).count
        // Legacy native sessions may already contain an oversized individual
        // message. Always make progress for one item rather than returning an
        // unchanged cursor forever; normal incoming events are bounded at 1 MiB.
        if bytes + size > 4 * 1_024 * 1_024, messageStart < end.messages { break }
        bytes += size; messageStart -= 1
      }
      while activityStart > 0, end.activities - activityStart < 80 {
        let size = try JSONEncoder().encode(stored.activities[activityStart - 1]).count
        if bytes + size > 8 * 1_024 * 1_024, bytes > 0 { break }
        bytes += size; activityStart -= 1
      }
      let older = messageStart > 0 || activityStart > 0
        ? try JSONEncoder().encode(FederationTranscriptCursor(messages: messageStart, activities: activityStart)).base64EncodedString() : nil
      return CompanionTranscript(conversationID: conversationID, messages: Array(stored.messages[messageStart..<end.messages]),
        activities: Array(stored.activities[activityStart..<end.activities]), activeRunID: stored.activeRunID, olderCursor: older)
    }
  }
  func federationConversationUnlocked(_ id: String) throws -> CompanionConversation? {
    guard var value = try federationValuesUnlocked("SELECT f.conversation FROM companion_execution_conversations f JOIN dashboard_conversations c ON c.id=f.id WHERE f.id=? AND f.deleted=0 AND c.deleted_at IS NULL AND c.is_archived=0", bindings: [id], as: CompanionConversation.self).first else { return nil }
    let statement = try prepareUnlocked("SELECT title,folder_id,is_pinned,updated_at FROM dashboard_conversations WHERE id=?")
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw WorkspaceDatabaseError.corruptRow }
    value.title = try text(statement, column: 0); value.folderID = optionalText(statement, column: 1)
    value.isPinned = sqlite3_column_int(statement, 2) != 0; value.updatedAt = try text(statement, column: 3)
    return value
  }
  func federationValuesUnlocked<Value: Decodable>(_ sql: String, bindings: [String] = [], as type: Value.Type) throws -> [Value] {
    let statement = try prepareUnlocked(sql); defer { sqlite3_finalize(statement) }
    for (index, value) in bindings.enumerated() { try bind(value, at: Int32(index + 1), to: statement) }
    var result: [Value] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return result }
      guard code == SQLITE_ROW else { throw stepError() }
      result.append(try JSONDecoder().decode(type, from: blob(statement, column: 0)))
    }
  }
  func federationScalarUnlocked(_ sql: String, bindings: [String] = []) throws -> Int64 {
    let statement = try prepareUnlocked(sql); defer { sqlite3_finalize(statement) }
    for (index, value) in bindings.enumerated() { try bind(value, at: Int32(index + 1), to: statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
    return sqlite3_column_int64(statement, 0)
  }
  func federationID(_ value: String) -> Bool {
    guard let id = UUID(uuidString: value) else { return false }
    return id.uuidString.lowercased() == value
  }
  func federationError(_ code: String, _ message: String) -> CompanionAPIError { CompanionAPIError(code: code, message: message) }
}

extension WorkspaceDatabase {
  public func companionExecutionOwners() async throws -> [String: String] {
    try await read { try $0.companionExecutionOwners() }
  }
  public func companionExecutionOwner(conversationID: String) async throws -> String? {
    try await read { try $0.companionExecutionOwner(conversationID: conversationID) }
  }
  public func companionConversationExecutionWorkspace(conversationID: String) async throws -> CompanionExecutionWorkspace? {
    try await read { try $0.companionConversationExecutionWorkspace(conversationID: conversationID) }
  }
  public func companionExecutionOriginCursor(workspaceID: String) async throws -> Int64 {
    try await read { try $0.companionExecutionOriginCursor(workspaceID: workspaceID) }
  }
  public func companionLibraryIdentity() async throws -> CompanionLibraryIdentity { try await read { try $0.companionLibraryIdentity() } }
  public func companionExecutionWorkspaces() async throws -> [CompanionExecutionWorkspace] { try await read { try $0.companionExecutionWorkspaces() } }
  public func registerCompanionExecutionWorkspace(_ request: CompanionWorkspaceRegistration, deviceID: String) async throws -> CompanionExecutionWorkspace {
    try await write { try $0.registerCompanionExecutionWorkspace(request, deviceID: deviceID) }
  }
  public func ingestCompanionJournal(_ batch: CompanionJournalBatch, deviceID: String) async throws -> CompanionJournalBatchResult {
    try await write { try $0.ingestCompanionJournal(batch, deviceID: deviceID) }
  }
  public func companionJournal(after cursor: Int64, limit: Int = 200) async throws -> CompanionJournalPage {
    try await read { try $0.companionJournal(after: cursor, limit: limit) }
  }
  public func companionFederatedTranscript(conversationID: String, before: String? = nil) async throws -> CompanionTranscript? {
    try await read { try $0.companionFederatedTranscript(conversationID: conversationID, before: before) }
  }
}

private struct FederationTranscriptCursor: Codable {
  var messages: Int
  var activities: Int
}
