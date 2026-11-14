import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterClient
import WovenMatterCore

public enum WorkspaceFolderMutationError: LocalizedError, Equatable, Sendable {
  case emptyName
  case folderNotFound

  public var errorDescription: String? {
    switch self {
    case .emptyName:
      "Enter a name for the folder."
    case .folderNotFound:
      "The folder is no longer available."
    }
  }
}

// Workspace ownership, surface preferences, folders, overview and calendar.
extension WorkspaceDatabaseConnection {
  public func macSurfaceProfile(
    ownerDeviceID: UUID,
    bootstrap: SurfaceProfile,
    createdAt: Date = Date()
  ) throws -> SurfaceProfile {
    try transaction {
      let profileID = SurfaceProfile.macID(deviceID: ownerDeviceID)
      if let existing = try surfaceProfileUnlocked(
        id: profileID,
        ownerDeviceID: ownerDeviceID
      ) {
        return existing
      }
      let timestamp = Self.timestamp(createdAt)
      let statement = try prepareUnlocked("""
        INSERT INTO surface_profiles (
          id, device_id, theme, sidebar_style,
          single_sidebar_side, left_rail_visible, right_rail_visible,
          single_rail_visible, chat_width_percent, note_on_left,
          workspace_mode, agent_order_json, revision, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1, ?, ?)
        """)
      defer { sqlite3_finalize(statement) }
      try bind(profileID, at: 1, to: statement)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 2, to: statement)
      try bind(bootstrap.theme, at: 3, to: statement)
      try bind(bootstrap.sidebarStyle, at: 4, to: statement)
      try bind(bootstrap.singleSidebarSide, at: 5, to: statement)
      guard sqlite3_bind_int(statement, 6, bootstrap.leftRailVisible ? 1 : 0) == SQLITE_OK,
            sqlite3_bind_int(statement, 7, bootstrap.rightRailVisible ? 1 : 0) == SQLITE_OK,
            sqlite3_bind_int(statement, 8, bootstrap.singleRailVisible ? 1 : 0) == SQLITE_OK,
            sqlite3_bind_double(statement, 9, bootstrap.chatWidthPercent) == SQLITE_OK,
            sqlite3_bind_int(statement, 10, bootstrap.noteOnLeft ? 1 : 0) == SQLITE_OK else {
        throw bindError()
      }
      try bind(bootstrap.workspaceMode, at: 11, to: statement)
      try bind(Self.agentOrderJSON(bootstrap.localCLIAgentOrder), at: 12, to: statement)
      try bind(timestamp, at: 13, to: statement)
      try bind(timestamp, at: 14, to: statement)
      try stepDone(statement)
      return try surfaceProfileUnlocked(id: profileID, ownerDeviceID: ownerDeviceID)
        ?? bootstrap
    }
  }

  public func updateMacSurfaceProfile(
    _ profile: SurfaceProfile,
    ownerDeviceID: UUID,
    updatedAt: Date = Date()
  ) throws -> SurfaceProfile {
    try transaction {
      let profileID = SurfaceProfile.macID(deviceID: ownerDeviceID)
      guard profile.id == profileID,
            profile.deviceID == ownerDeviceID else {
        throw WorkspaceDatabaseError.execute("Mac surface profile ownership mismatch")
      }
      let statement = try prepareUnlocked("""
        UPDATE surface_profiles
        SET theme = ?, sidebar_style = ?, single_sidebar_side = ?,
          left_rail_visible = ?, right_rail_visible = ?, single_rail_visible = ?,
          chat_width_percent = ?, note_on_left = ?, workspace_mode = ?,
          agent_order_json = ?, revision = revision + 1, updated_at = ?
        WHERE id = ? AND device_id = ?
        """)
      defer { sqlite3_finalize(statement) }
      try bind(profile.theme, at: 1, to: statement)
      try bind(profile.sidebarStyle, at: 2, to: statement)
      try bind(profile.singleSidebarSide, at: 3, to: statement)
      guard sqlite3_bind_int(statement, 4, profile.leftRailVisible ? 1 : 0) == SQLITE_OK,
            sqlite3_bind_int(statement, 5, profile.rightRailVisible ? 1 : 0) == SQLITE_OK,
            sqlite3_bind_int(statement, 6, profile.singleRailVisible ? 1 : 0) == SQLITE_OK,
            sqlite3_bind_double(
              statement, 7, min(80, max(20, profile.chatWidthPercent))
            ) == SQLITE_OK,
            sqlite3_bind_int(statement, 8, profile.noteOnLeft ? 1 : 0) == SQLITE_OK else {
        throw bindError()
      }
      try bind(profile.workspaceMode, at: 9, to: statement)
      try bind(Self.agentOrderJSON(profile.localCLIAgentOrder), at: 10, to: statement)
      try bind(Self.timestamp(updatedAt), at: 11, to: statement)
      try bind(profileID, at: 12, to: statement)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 13, to: statement)
      try stepDone(statement)
      guard changedRowCountUnlocked == 1 else {
        throw WorkspaceDatabaseError.corruptRow
      }
      guard let updated = try surfaceProfileUnlocked(
        id: profileID,
        ownerDeviceID: ownerDeviceID
      ) else {
        throw WorkspaceDatabaseError.corruptRow
      }
      return updated
    }
  }

  private func surfaceProfileUnlocked(
    id: String,
    ownerDeviceID: UUID
  ) throws -> SurfaceProfile? {
    let statement = try prepareUnlocked("""
      SELECT id, device_id, theme, sidebar_style,
        single_sidebar_side, left_rail_visible, right_rail_visible,
        single_rail_visible, chat_width_percent, note_on_left,
        workspace_mode, agent_order_json, revision, created_at, updated_at
      FROM surface_profiles
      WHERE id = ? AND device_id = ?
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(ownerDeviceID.uuidString.lowercased(), at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW else { throw WorkspaceDatabaseError.corruptRow }
    return SurfaceProfile(
      id: try text(statement, column: 0),
      deviceID: optionalText(statement, column: 1).flatMap(UUID.init(uuidString:)),
      theme: try text(statement, column: 2),
      sidebarStyle: try text(statement, column: 3),
      singleSidebarSide: try text(statement, column: 4),
      leftRailVisible: sqlite3_column_int(statement, 5) != 0,
      rightRailVisible: sqlite3_column_int(statement, 6) != 0,
      singleRailVisible: sqlite3_column_int(statement, 7) != 0,
      chatWidthPercent: sqlite3_column_double(statement, 8),
      noteOnLeft: sqlite3_column_int(statement, 9) != 0,
      workspaceMode: try text(statement, column: 10),
      localCLIAgentOrder: Self.agentOrder(from: try text(statement, column: 11)),
      revision: sqlite3_column_int64(statement, 12),
      createdAt: Self.date(try text(statement, column: 13)) ?? .distantPast,
      updatedAt: Self.date(try text(statement, column: 14)) ?? .distantPast
    )
  }

  @discardableResult
  public func createFolder(
    id: UUID = UUID(),
    name: String,
    location: WorkspaceFolderLocation,
    createdAt: Date = Date()
  ) throws -> String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw WorkspaceFolderMutationError.emptyName
    }

    return try transaction {
      let folderID = id.uuidString.lowercased()
      let timestamp = Self.timestamp(createdAt)
      let positionStatement = try prepareUnlocked("""
        SELECT COALESCE(MAX(position), -1) + 1
        FROM folders
        """)
      defer { sqlite3_finalize(positionStatement) }
      guard sqlite3_step(positionStatement) == SQLITE_ROW else {
        throw stepError()
      }
      let position = sqlite3_column_int64(positionStatement, 0)

      let insert = try prepareUnlocked("""
        INSERT INTO folders (
          id, name, icon, position, is_pinned, created_at, updated_at
        ) VALUES (?, ?, 'folder', ?, 0, ?, ?)
        """)
      defer { sqlite3_finalize(insert) }
      try bind(folderID, at: 1, to: insert)
      try bind(normalizedName, at: 2, to: insert)
      guard sqlite3_bind_int64(insert, 3, position) == SQLITE_OK else {
        throw bindError()
      }
      try bind(timestamp, at: 4, to: insert)
      try bind(timestamp, at: 5, to: insert)
      try stepDone(insert)

      try validateExecutionLocation(location)
      try toolsExecuteUnlocked("INSERT INTO folder_execution_roots(folder_id,workspace_id,root_path,managed) VALUES(?,?,?,?)",
        [folderID, location.workspaceID, location.rootPath, location.managed ? "1" : "0"])
      return folderID
    }
  }

  @discardableResult
  public func renameFolder(
    id: String,
    name: String,
    updatedAt: Date = Date()
  ) throws -> Bool {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw WorkspaceFolderMutationError.emptyName
    }

    return try transaction {
      let update = try prepareUnlocked("""
        UPDATE folders
        SET name = ?, updated_at = ?
        WHERE id = ?
        """)
      defer { sqlite3_finalize(update) }
      try bind(normalizedName, at: 1, to: update)
      try bind(Self.timestamp(updatedAt), at: 2, to: update)
      try bind(id, at: 3, to: update)
      try stepDone(update)
      guard changedRowCountUnlocked == 1 else {
        throw WorkspaceFolderMutationError.folderNotFound
      }

      return true
    }
  }

  @discardableResult
  public func setFolderPinned(
    id: String,
    isPinned: Bool,
    updatedAt: Date = Date()
  ) throws -> Bool {
    try transaction {
      let update = try prepareUnlocked("""
        UPDATE folders
        SET is_pinned = ?, updated_at = ?
        WHERE id = ?
        """)
      defer { sqlite3_finalize(update) }
      guard sqlite3_bind_int(update, 1, isPinned ? 1 : 0) == SQLITE_OK else {
        throw bindError()
      }
      try bind(Self.timestamp(updatedAt), at: 2, to: update)
      try bind(id, at: 3, to: update)
      try stepDone(update)
      guard changedRowCountUnlocked == 1 else {
        throw WorkspaceFolderMutationError.folderNotFound
      }

      return true
    }
  }

  @discardableResult
  public func moveFolder(
    id: String,
    direction: WorkspaceFolderMoveDirection,
    updatedAt: Date = Date()
  ) throws -> Bool {
    return try transaction {
      let isPinned: Bool = try {
        let sourceLookup = try prepareUnlocked("""
          SELECT is_pinned
          FROM folders
          WHERE id = ?
          """)
        defer { sqlite3_finalize(sourceLookup) }
        try bind(id, at: 1, to: sourceLookup)
        let sourceCode = sqlite3_step(sourceLookup)
        guard sourceCode == SQLITE_ROW else {
          if sourceCode == SQLITE_DONE {
            throw WorkspaceFolderMutationError.folderNotFound
          }
          throw stepError()
        }
        return sqlite3_column_int(sourceLookup, 0) != 0
      }()

      var section: [(id: String, name: String, position: Int64)] = try {
        let sectionLookup = try prepareUnlocked("""
          SELECT id, name, position
          FROM folders
          WHERE is_pinned = ?
            AND (SELECT workspace_id FROM folder_execution_roots WHERE folder_id = folders.id)
                IS (SELECT workspace_id FROM folder_execution_roots WHERE folder_id = ?)
          """)
        defer { sqlite3_finalize(sectionLookup) }
        guard sqlite3_bind_int(sectionLookup, 1, isPinned ? 1 : 0) == SQLITE_OK else {
          throw bindError()
        }
        try bind(id, at: 2, to: sectionLookup)

        var values: [(id: String, name: String, position: Int64)] = []
        while true {
          let code = sqlite3_step(sectionLookup)
          if code == SQLITE_DONE { break }
          guard code == SQLITE_ROW else { throw stepError() }
          values.append((
            id: try text(sectionLookup, column: 0),
            name: try text(sectionLookup, column: 1),
            position: sqlite3_column_int64(sectionLookup, 2)
          ))
        }
        return values
      }()
      section.sort {
        if $0.position != $1.position { return $0.position < $1.position }
        let nameComparison = $0.name.localizedCaseInsensitiveCompare($1.name)
        if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
        return $0.id < $1.id
      }
      guard let sourceIndex = section.firstIndex(where: { $0.id == id }) else {
        throw WorkspaceFolderMutationError.folderNotFound
      }
      let targetIndex: Int
      switch direction {
      case .up:
        guard sourceIndex > 0 else { return false }
        targetIndex = sourceIndex - 1
      case .down:
        guard sourceIndex < section.count - 1 else { return false }
        targetIndex = sourceIndex + 1
      }
      section.swapAt(sourceIndex, targetIndex)

      let update = try prepareUnlocked("""
        UPDATE folders
        SET position = ?, updated_at = ?
        WHERE id = ?
        """)
      defer { sqlite3_finalize(update) }
      let timestamp = Self.timestamp(updatedAt)
      var changed = false
      for (offset, folder) in section.enumerated() {
        let position = Int64(offset)
        guard folder.position != position else { continue }
        sqlite3_reset(update)
        sqlite3_clear_bindings(update)
        guard sqlite3_bind_int64(update, 1, position) == SQLITE_OK else {
          throw bindError()
        }
        try bind(timestamp, at: 2, to: update)
        try bind(folder.id, at: 3, to: update)
        try stepDone(update)
        guard changedRowCountUnlocked == 1 else {
          throw WorkspaceFolderMutationError.folderNotFound
        }
        changed = true
      }

      return changed
    }
  }

  @discardableResult
  public func deleteFolder(
    id: String
  ) throws -> Bool {
    try transaction {
      let existing = try prepareUnlocked("""
        SELECT 1 FROM folders
        WHERE id = ?
        """)
      defer { sqlite3_finalize(existing) }
      try bind(id, at: 1, to: existing)
      guard sqlite3_step(existing) == SQLITE_ROW else {
        throw WorkspaceFolderMutationError.folderNotFound
      }
      let delete = try prepareUnlocked("""
        DELETE FROM folders
        WHERE id = ?
        """)
      defer { sqlite3_finalize(delete) }
      try bind(id, at: 1, to: delete)
      try stepDone(delete)
      guard changedRowCountUnlocked == 1 else {
        throw WorkspaceFolderMutationError.folderNotFound
      }

      return true
    }
  }

  public func libraryRecordCounts() throws -> LibraryRecordCounts {
    try withLock {
      func count(_ table: String, where predicate: String? = nil) throws -> Int {
        let statement = try prepareUnlocked("SELECT COUNT(*) FROM \(table)" + (predicate.map { " WHERE " + $0 } ?? ""))
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
        return Int(sqlite3_column_int64(statement, 0))
      }
      let liveConversation = "conversation_id IN (SELECT id FROM conversations WHERE deleted_at IS NULL AND is_archived = 0)"
      return try LibraryRecordCounts(
        folders: count("folders"),
        notes: count("notes", where: "deleted_at IS NULL"),
        agents: count("agents", where: "deleted_at IS NULL"),
        conversations: count("conversations", where: "deleted_at IS NULL AND is_archived = 0"),
        messages: count("messages", where: liveConversation),
        runs: count("runs", where: liveConversation),
        calendarItems: count("calendar_items", where: "deleted_at IS NULL")
      )
    }
  }

  public func calendarItems() throws -> [WorkspaceCalendarItemRecord] {
    try withLock { try calendarItemsUnlocked() }
  }

  public func workspaceOverview() throws -> WorkspaceSnapshot {
    try withLock {
      let folders: [WorkspaceFolderRecord] = try decodeCanonicalRowsUnlocked(
          """
          SELECT json_object(
            'id', id, 'name', name, 'icon', icon, 'position', position,
            'is_pinned', is_pinned,
            'execution_workspace_id', (SELECT workspace_id FROM folder_execution_roots WHERE folder_id=folders.id),
            'root_path', (SELECT root_path FROM folder_execution_roots WHERE folder_id=folders.id),
            'managed_root', COALESCE((SELECT managed FROM folder_execution_roots WHERE folder_id=folders.id),0),
            'reference_paths', json(COALESCE((SELECT reference_paths FROM folder_execution_roots WHERE folder_id=folders.id),'[]'))
          )
          FROM folders
          ORDER BY is_pinned DESC, position, name, id
          """,
          bindings: [],
          as: WorkspaceFolderRecord.self
        )
      var conversations: [WorkspaceConversationRecord] = try decodeCanonicalRowsUnlocked(
          """
          SELECT json_object(
            'id', id, 'agent_id', agent_id,
            'agent_codename', agent_codename, 'title', title,
            'local_runtime_kind', (
              SELECT runtime_kind
              FROM harness_sessions AS local_session
              WHERE local_session.conversation_id = conversations.id
            ),
            'remote_workspace_id', (
              SELECT remote_workspace_id
              FROM harness_sessions AS local_session
              WHERE local_session.conversation_id = conversations.id
            ),
            'unread', unread, 'last_message_preview', last_message_preview,
            'is_scheduled_task', EXISTS(SELECT 1 FROM calendar_task_sessions WHERE id=conversations.id),
            'imported_at',
              (SELECT imported_at FROM session_imports WHERE conversation_id = conversations.id),
            'last_message_at', last_message_at, 'folder_id', folder_id,
            'is_pinned', is_pinned,
            'is_archived', is_archived
          )
          FROM conversations
          WHERE \(Self.listedConversation("conversations"))
          ORDER BY last_message_at DESC, id DESC
          """,
          bindings: [],
          as: WorkspaceConversationRecord.self
        )
      let notes: [WorkspaceNoteRecord] = try decodeCanonicalRowsUnlocked(
          """
          SELECT json_object(
            'id', id, 'folder_id', folder_id, 'title', title,
            'content', content, 'created_at', created_at,
            'updated_at', updated_at, 'is_pinned', is_pinned,
            'revision', CAST(COALESCE((SELECT revision FROM device_sync_revisions WHERE kind = 'note' AND resource_id = notes.id), 1) AS TEXT)
          )
          FROM notes
          WHERE deleted_at IS NULL
          ORDER BY is_pinned DESC, updated_at DESC, id DESC
          """,
          bindings: [],
          as: WorkspaceNoteRecord.self
        )

      let statuses = try programStatusSnapshotsUnlocked()
      for index in conversations.indices {
        conversations[index].programStatus = statuses[conversations[index].id]
          ?? ProgramStatusSnapshot(status: ProgramStatus(state: .idle))
      }
      let revisionStatement = try prepareUnlocked(
        "SELECT revision FROM workspace_revision WHERE singleton = 1"
      )
      defer { sqlite3_finalize(revisionStatement) }
      guard sqlite3_step(revisionStatement) == SQLITE_ROW else { throw stepError() }
      return WorkspaceSnapshot(
        revision: sqlite3_column_int64(revisionStatement, 0),
        folders: folders.sorted {
          if $0.position != $1.position { return $0.position < $1.position }
          let nameComparison = $0.name.localizedCaseInsensitiveCompare($1.name)
          if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
          return $0.id < $1.id
        },
        conversations: conversations,
        messages: [],
        notes: notes,
        runs: []
      )
    }
  }

  func validateFolderUnlocked(id: String?) throws {
    guard let id else { return }
    guard try historyRowsUnlocked("SELECT 1 AS present FROM folders WHERE id = ?", values: [id]).isEmpty == false else {
      throw WorkspaceNoteMutationError.folderNotFound
    }
  }

  private static func agentOrderJSON(_ order: [UUID]?) throws -> String {
    let data = try JSONEncoder().encode(
      (order ?? []).map { $0.uuidString.lowercased() }
    )
    guard let value = String(data: data, encoding: .utf8) else {
      throw WorkspaceDatabaseError.bind("Could not encode the local CLI agent order")
    }
    return value
  }

  private static func agentOrder(from value: String) -> [UUID] {
    guard let data = value.data(using: .utf8),
          let identifiers = try? JSONDecoder().decode([String].self, from: data) else {
      return []
    }
    return identifiers.compactMap(UUID.init(uuidString:))
  }
}

// MARK: - Async worker boundary

extension WorkspaceDatabase {
  public func macSurfaceProfile(
    ownerDeviceID: UUID,
    bootstrap: SurfaceProfile,
    createdAt: Date = Date()
  ) async throws -> SurfaceProfile {
    try await write { try $0.macSurfaceProfile(ownerDeviceID: ownerDeviceID, bootstrap: bootstrap, createdAt: createdAt) }
  }

  public func updateMacSurfaceProfile(
    _ profile: SurfaceProfile,
    ownerDeviceID: UUID,
    updatedAt: Date = Date()
  ) async throws -> SurfaceProfile {
    try await write { try $0.updateMacSurfaceProfile(profile, ownerDeviceID: ownerDeviceID, updatedAt: updatedAt) }
  }

  @discardableResult
  public func createFolder(
    id: UUID = UUID(),
    name: String,
    location: WorkspaceFolderLocation,
    createdAt: Date = Date()
  ) async throws -> String {
    try await write { try $0.createFolder(id: id, name: name, location: location, createdAt: createdAt) }
  }

  @discardableResult
  public func renameFolder(
    id: String,
    name: String,
    updatedAt: Date = Date()
  ) async throws -> Bool {
    try await write { try $0.renameFolder(id: id, name: name, updatedAt: updatedAt) }
  }

  @discardableResult
  public func setFolderPinned(
    id: String,
    isPinned: Bool,
    updatedAt: Date = Date()
  ) async throws -> Bool {
    try await write { try $0.setFolderPinned(id: id, isPinned: isPinned, updatedAt: updatedAt) }
  }

  @discardableResult
  public func moveFolder(
    id: String,
    direction: WorkspaceFolderMoveDirection,
    updatedAt: Date = Date()
  ) async throws -> Bool {
    try await write { try $0.moveFolder(id: id, direction: direction, updatedAt: updatedAt) }
  }

  @discardableResult
  public func deleteFolder(
    id: String
  ) async throws -> Bool {
    try await write { try $0.deleteFolder(id: id) }
  }

  public func libraryRecordCounts() async throws -> LibraryRecordCounts {
    try await read { try $0.libraryRecordCounts() }
  }

  public func calendarItems() async throws -> [WorkspaceCalendarItemRecord] {
    try await read { try $0.calendarItems() }
  }

  public func workspaceOverview() async throws -> WorkspaceSnapshot {
    try await read { try $0.workspaceOverview() }
  }
}

extension WorkspaceDatabaseConnection {
  public func availableSessionExecutionRoot(id: String) throws -> WorkspaceFolderLocation {
    try withLock {
      guard let root = try sessionExecutionRoot(id: id),
            try historyRowsUnlocked("SELECT 1 FROM conversations WHERE id=? AND deleted_at IS NULL AND is_archived=0 AND NOT EXISTS(SELECT 1 FROM retained_execution_history WHERE conversation_id=?)", values: [id,id]).count == 1 else {
        throw WorkspaceToolError.invalid("This saved chat is read-only. Start a new chat in an available execution workspace.")
      }
      return root
    }
  }

  public func sessionExecutionRoot(id: String) throws -> WorkspaceFolderLocation? {
    try withLock {
      guard let row = try historyRowsUnlocked("SELECT * FROM session_execution_roots WHERE conversation_id=?", values: [id]).first?.objectValue,
            let owner = row["workspace_id"]?.stringValue, let path = row["root_path"]?.stringValue else { return nil }
      return .init(workspaceID: owner, rootPath: path, managed: false)
    }
  }

  func validateExecutionLocation(_ location: WorkspaceFolderLocation) throws {
    guard !location.workspaceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
          !location.workspaceID.contains("\0"), location.rootPath.hasPrefix("/"), !location.rootPath.contains("\0") else {
      throw WorkspaceToolError.invalid("An execution location needs an owning workspace and an absolute directory.")
    }
  }

  func saveSessionExecutionRootUnlocked(id: String, folderID: String?, location: WorkspaceFolderLocation, defaultPath: String) throws {
    try validateExecutionLocation(location)
    guard defaultPath.hasPrefix("/"), !defaultPath.contains("\0") else {
      throw WorkspaceToolError.invalid("An execution workspace needs an absolute default directory.")
    }
    // A scheduled session keeps its captured root after its UI folder is removed.
    // Reuse is valid only when the saved owner and directory still match.
    if let existing = try sessionExecutionRoot(id: id) {
      guard existing.workspaceID == location.workspaceID, existing.rootPath == location.rootPath else { throw WorkspaceToolError.invalid("This session's execution root is fixed.") }
      return
    }
    if let folderID {
      guard let row = try historyRowsUnlocked("SELECT workspace_id,root_path FROM folder_execution_roots WHERE folder_id=?", values: [folderID]).first?.objectValue,
            row["workspace_id"]?.stringValue == location.workspaceID,
            row["root_path"]?.stringValue == location.rootPath else {
        throw WorkspaceToolError.invalid("Choose a folder in the agent's execution workspace.")
      }
    }
    try toolsExecuteUnlocked("INSERT INTO execution_workspace_defaults(workspace_id,default_path) VALUES(?,?) ON CONFLICT(workspace_id) DO UPDATE SET default_path=excluded.default_path", [location.workspaceID,defaultPath])
    try toolsExecuteUnlocked("INSERT INTO session_execution_roots(conversation_id,workspace_id,root_path) VALUES(?,?,?)", [id,location.workspaceID,location.rootPath])
    try toolsExecuteUnlocked("UPDATE conversations SET folder_id=? WHERE id=?", [folderID,id])
  }

  public func setFolderReferences(id: String, paths: [String]) throws {
    try transaction {
      guard paths.count <= 64, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else {
        throw WorkspaceToolError.invalid("Reference locations must be absolute paths on the owning workspace.")
      }
      try toolsExecuteUnlocked("UPDATE folder_execution_roots SET reference_paths=? WHERE folder_id=?", [try toolsJSON(Array(Set(paths)).sorted()),id])
      guard changedRowCountUnlocked == 1 else { throw WorkspaceFolderMutationError.folderNotFound }
    }
  }

  public func lockSessionFolder(id: String) throws {
    try transaction {
      _ = try availableSessionExecutionRoot(id: id)
      try toolsExecuteUnlocked("UPDATE session_execution_roots SET folder_locked=1 WHERE conversation_id=?", [id])
    }
  }
}

extension WorkspaceDatabase {
  public func availableSessionExecutionRoot(id: String) async throws -> WorkspaceFolderLocation {
    try await read { try $0.availableSessionExecutionRoot(id: id) }
  }
  public func sessionExecutionRoot(id: String) async throws -> WorkspaceFolderLocation? {
    try await read { try $0.sessionExecutionRoot(id: id) }
  }
  public func setFolderReferences(id: String, paths: [String]) async throws {
    try await write { try $0.setFolderReferences(id: id, paths: paths) }
  }
  public func lockSessionFolder(id: String) async throws {
    try await write { try $0.lockSessionFolder(id: id) }
  }
}


extension WorkspaceDatabaseConnection {
  public func canChooseSessionFolder(id: String) throws -> Bool {
    try withLock {
      guard (try? availableSessionExecutionRoot(id: id)) != nil else { return false }
      guard let row = try historyRowsUnlocked("SELECT folder_locked FROM session_execution_roots WHERE conversation_id=?", values: [id]).first?.objectValue,
            row["folder_locked"]?.intValue == 0 else { return false }
      return try historyRowsUnlocked("SELECT 1 FROM messages WHERE conversation_id=? AND role='user' LIMIT 1", values: [id]).isEmpty
    }
  }
}
extension WorkspaceDatabase {
  public func canChooseSessionFolder(id: String) async throws -> Bool {
    try await read { try $0.canChooseSessionFolder(id: id) }
  }
}


extension WorkspaceDatabaseConnection {
  public func clearDraftNativeSession(id: String) throws {
    try transaction {
      guard try canChooseSessionFolder(id: id) else { throw WorkspaceToolError.invalid("Only a draft can change its execution root.") }
      try toolsExecuteUnlocked("UPDATE harness_sessions SET native_session_id=NULL WHERE conversation_id=?", [id])
    }
  }
}
extension WorkspaceDatabase {
  public func clearDraftNativeSession(id: String) async throws {
    try await write { try $0.clearDraftNativeSession(id: id) }
  }
}


/// Captured owner and directory committed atomically with a new conversation.
public struct SessionCreationRoot: Codable, Sendable {
  public let folderID: String?
  public let location: WorkspaceFolderLocation
  public let defaultPath: String

  public init(folderID: String?, location: WorkspaceFolderLocation, defaultPath: String) {
    self.folderID = folderID
    self.location = location
    self.defaultPath = defaultPath
  }
}
