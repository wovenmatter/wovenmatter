import Foundation
import SQLite3
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
extension WorkspaceDatabase {
  public func bindDeviceOwnership(
    ownerDeviceID: UUID,
    boundAt: Date = Date()
  ) throws {
    try withLock {
      let statement = try prepareUnlocked("""
        INSERT INTO desktop_local_identity (singleton, device_id, bound_at)
        VALUES (1, ?, ?)
        ON CONFLICT(singleton) DO UPDATE SET
          device_id = excluded.device_id,
          bound_at = excluded.bound_at
        """)
      defer { sqlite3_finalize(statement) }
      try bind(ownerDeviceID.uuidString.lowercased(), at: 1, to: statement)
      try bind(Self.timestamp(boundAt), at: 2, to: statement)
      try stepDone(statement)
    }
  }

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
      let discardCollision = try prepareUnlocked("""
        DELETE FROM surface_profiles
        WHERE id = ? AND authority_kind != 'device_owned'
        """)
      try bind(profileID, at: 1, to: discardCollision)
      try stepDone(discardCollision)
      sqlite3_finalize(discardCollision)
      let timestamp = Self.timestamp(createdAt)
      let statement = try prepareUnlocked("""
        INSERT INTO surface_profiles (
          id, user_id, surface, device_id, theme, sidebar_style,
          single_sidebar_side, left_rail_visible, right_rail_visible,
          single_rail_visible, chat_width_percent, note_on_left,
          workspace_mode, agent_order_json, revision, authority_kind, authority_device_id,
          origin_device_id, created_at, updated_at
        ) VALUES (?, ?, 'mac_native', ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 1,
          'device_owned', ?, ?, ?, ?)
        """)
      defer { sqlite3_finalize(statement) }
      try bind(profileID, at: 1, to: statement)
      try bind(try localMutationOperatorIDUnlocked(), at: 2, to: statement)
      let deviceID = ownerDeviceID.uuidString.lowercased()
      try bind(deviceID, at: 3, to: statement)
      try bind(bootstrap.theme, at: 4, to: statement)
      try bind(bootstrap.sidebarStyle, at: 5, to: statement)
      try bind(bootstrap.singleSidebarSide, at: 6, to: statement)
      guard sqlite3_bind_int(statement, 7, bootstrap.leftRailVisible ? 1 : 0) == SQLITE_OK,
            sqlite3_bind_int(statement, 8, bootstrap.rightRailVisible ? 1 : 0) == SQLITE_OK,
            sqlite3_bind_int(statement, 9, bootstrap.singleRailVisible ? 1 : 0) == SQLITE_OK,
            sqlite3_bind_double(statement, 10, bootstrap.chatWidthPercent) == SQLITE_OK,
            sqlite3_bind_int(statement, 11, bootstrap.noteOnLeft ? 1 : 0) == SQLITE_OK else {
        throw bindError()
      }
      try bind(bootstrap.workspaceMode, at: 12, to: statement)
      try bind(Self.agentOrderJSON(bootstrap.localCLIAgentOrder), at: 13, to: statement)
      try bind(deviceID, at: 14, to: statement)
      try bind(deviceID, at: 15, to: statement)
      try bind(timestamp, at: 16, to: statement)
      try bind(timestamp, at: 17, to: statement)
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
            profile.surface == .mac,
            profile.deviceID == ownerDeviceID else {
        throw WorkspaceDatabaseError.execute("Mac surface profile ownership mismatch")
      }
      let statement = try prepareUnlocked("""
        UPDATE surface_profiles
        SET theme = ?, sidebar_style = ?, single_sidebar_side = ?,
          left_rail_visible = ?, right_rail_visible = ?, single_rail_visible = ?,
          chat_width_percent = ?, note_on_left = ?, workspace_mode = ?,
          agent_order_json = ?, revision = revision + 1, updated_at = ?
        WHERE id = ? AND surface = 'mac_native' AND authority_kind = 'device_owned'
          AND authority_device_id = ?
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
      SELECT id, user_id, surface, device_id, theme, sidebar_style,
        single_sidebar_side, left_rail_visible, right_rail_visible,
        single_rail_visible, chat_width_percent, note_on_left,
        workspace_mode, agent_order_json, revision, created_at, updated_at
      FROM surface_profiles
      WHERE id = ? AND surface = 'mac_native' AND authority_kind = 'device_owned'
        AND authority_device_id = ?
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(ownerDeviceID.uuidString.lowercased(), at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE { return nil }
    guard code == SQLITE_ROW,
          let surface = DashboardSurface(persistedValue: try text(statement, column: 2)) else {
      throw WorkspaceDatabaseError.corruptRow
    }
    return SurfaceProfile(
      id: try text(statement, column: 0),
      userID: try text(statement, column: 1),
      surface: surface,
      deviceID: optionalText(statement, column: 3).flatMap(UUID.init(uuidString:)),
      theme: try text(statement, column: 4),
      sidebarStyle: try text(statement, column: 5),
      singleSidebarSide: try text(statement, column: 6),
      leftRailVisible: sqlite3_column_int(statement, 7) != 0,
      rightRailVisible: sqlite3_column_int(statement, 8) != 0,
      singleRailVisible: sqlite3_column_int(statement, 9) != 0,
      chatWidthPercent: sqlite3_column_double(statement, 10),
      noteOnLeft: sqlite3_column_int(statement, 11) != 0,
      workspaceMode: try text(statement, column: 12),
      localCLIAgentOrder: Self.agentOrder(from: try text(statement, column: 13)),
      revision: sqlite3_column_int64(statement, 14),
      createdAt: Self.date(try text(statement, column: 15)) ?? .distantPast,
      updatedAt: Self.date(try text(statement, column: 16)) ?? .distantPast
    )
  }

  @discardableResult
  public func createFolder(
    id: UUID = UUID(),
    name: String,
    createdAt: Date = Date()
  ) throws -> String {
    let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      throw WorkspaceFolderMutationError.emptyName
    }

    return try transaction {
      let folderID = id.uuidString.lowercased()
      let operatorID = try localMutationOperatorIDUnlocked()
      let timestamp = Self.timestamp(createdAt)
      let positionStatement = try prepareUnlocked("""
        SELECT COALESCE(MAX(position), -1) + 1
        FROM folders
        WHERE user_id = ?
        """)
      defer { sqlite3_finalize(positionStatement) }
      try bind(operatorID, at: 1, to: positionStatement)
      guard sqlite3_step(positionStatement) == SQLITE_ROW else {
        throw stepError()
      }
      let position = sqlite3_column_int64(positionStatement, 0)

      let insert = try prepareUnlocked("""
        INSERT INTO folders (
          id, user_id, name, icon, position, is_pinned, created_at, updated_at
        ) VALUES (?, ?, ?, 'folder', ?, 0, ?, ?)
        """)
      defer { sqlite3_finalize(insert) }
      try bind(folderID, at: 1, to: insert)
      try bind(operatorID, at: 2, to: insert)
      try bind(normalizedName, at: 3, to: insert)
      guard sqlite3_bind_int64(insert, 4, position) == SQLITE_OK else {
        throw bindError()
      }
      try bind(timestamp, at: 5, to: insert)
      try bind(timestamp, at: 6, to: insert)
      try stepDone(insert)

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
      let operatorID = try localMutationOperatorIDUnlocked()
      let update = try prepareUnlocked("""
        UPDATE folders
        SET name = ?, updated_at = ?
        WHERE id = ? AND user_id = ?
        """)
      defer { sqlite3_finalize(update) }
      try bind(normalizedName, at: 1, to: update)
      try bind(Self.timestamp(updatedAt), at: 2, to: update)
      try bind(id, at: 3, to: update)
      try bind(operatorID, at: 4, to: update)
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
      let operatorID = try localMutationOperatorIDUnlocked()
      let update = try prepareUnlocked("""
        UPDATE folders
        SET is_pinned = ?, updated_at = ?
        WHERE id = ? AND user_id = ?
        """)
      defer { sqlite3_finalize(update) }
      guard sqlite3_bind_int(update, 1, isPinned ? 1 : 0) == SQLITE_OK else {
        throw bindError()
      }
      try bind(Self.timestamp(updatedAt), at: 2, to: update)
      try bind(id, at: 3, to: update)
      try bind(operatorID, at: 4, to: update)
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
      let operatorID = try localMutationOperatorIDUnlocked()
      let isPinned: Bool = try {
        let sourceLookup = try prepareUnlocked("""
          SELECT is_pinned
          FROM folders
          WHERE id = ? AND user_id = ?
          """)
        defer { sqlite3_finalize(sourceLookup) }
        try bind(id, at: 1, to: sourceLookup)
        try bind(operatorID, at: 2, to: sourceLookup)
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
          WHERE user_id = ? AND is_pinned = ?
          """)
        defer { sqlite3_finalize(sectionLookup) }
        try bind(operatorID, at: 1, to: sectionLookup)
        guard sqlite3_bind_int(sectionLookup, 2, isPinned ? 1 : 0) == SQLITE_OK else {
          throw bindError()
        }

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
        WHERE id = ? AND user_id = ?
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
        try bind(operatorID, at: 4, to: update)
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
      let operatorID = try localMutationOperatorIDUnlocked()
      let existing = try prepareUnlocked("""
        SELECT 1 FROM folders
        WHERE id = ? AND user_id = ?
        """)
      defer { sqlite3_finalize(existing) }
      try bind(id, at: 1, to: existing)
      try bind(operatorID, at: 2, to: existing)
      guard sqlite3_step(existing) == SQLITE_ROW else {
        throw WorkspaceFolderMutationError.folderNotFound
      }
      let delete = try prepareUnlocked("""
        DELETE FROM folders
        WHERE id = ? AND user_id = ?
        """)
      defer { sqlite3_finalize(delete) }
      try bind(id, at: 1, to: delete)
      try bind(operatorID, at: 2, to: delete)
      try stepDone(delete)
      guard changedRowCountUnlocked == 1 else {
        throw WorkspaceFolderMutationError.folderNotFound
      }

      return true
    }
  }

  public func dashboardRecordCounts() throws -> DashboardRecordCounts {
    try withLock {
      let operatorID = try canonicalWorkspaceOperatorIDUnlocked()
      func count(_ table: String, where predicate: String? = nil) throws -> Int {
        var sql = "SELECT COUNT(*) FROM \(table)"
        if let predicate {
          sql += " WHERE \(predicate)"
        }
        let statement = try prepareUnlocked(sql)
        defer { sqlite3_finalize(statement) }
        if predicate?.contains("?") == true, let operatorID {
          try bind(operatorID, at: 1, to: statement)
        }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
        return Int(sqlite3_column_int64(statement, 0))
      }

      let scoped = operatorID == nil ? nil : "user_id = ?"
      let activeScoped = operatorID == nil ? "deleted_at IS NULL" : "user_id = ? AND deleted_at IS NULL"
      let activeAgentScoped = operatorID == nil
        ? "deleted_at IS NULL"
        : "(user_id = ? OR desktop_owned = 1) AND deleted_at IS NULL"
      let activeConversationScoped = operatorID == nil
        ? "deleted_at IS NULL AND is_archived = 0"
        : "(user_id = ? OR desktop_owned = 1) AND deleted_at IS NULL AND is_archived = 0"
      let conversationChildScope = operatorID == nil ? nil : """
        conversation_id IN (
          SELECT id FROM dashboard_conversations
          WHERE (user_id = ? OR desktop_owned = 1)
            AND deleted_at IS NULL AND is_archived = 0
        )
        """

      return try DashboardRecordCounts(
        profiles: count("profiles", where: operatorID == nil ? nil : "id = ?"),
        folders: count("folders", where: scoped),
        notes: count("notes", where: activeScoped),
        agents: count("dashboard_agents", where: activeAgentScoped),
        conversations: count("dashboard_conversations", where: activeConversationScoped),
        messages: count("dashboard_messages", where: conversationChildScope),
        runs: count("dashboard_runs", where: conversationChildScope),
        calendarItems: count("dashboard_calendar_items", where: activeScoped)
      )
    }
  }

  public func calendarItems() throws -> [WorkspaceCalendarItemRecord] {
    try withLock { try calendarItemsUnlocked() }
  }

  @discardableResult
  public func createCalendarItem(
    id: UUID = UUID(), title: String, details: String? = nil, startsAt: Date,
    endsAt: Date?, allDay: Bool, createdAt: Date = Date()
  ) throws -> String {
    try saveCalendarEvent(id: id.uuidString.lowercased(),
      draft: .init(title: title, details: details ?? "", startsAt: startsAt, endsAt: endsAt, allDay: allDay),
      creating: true, now: createdAt)
  }

  public func workspaceOverview() throws -> WorkspaceSnapshot {
    try withLock {
      var folders: [WorkspaceFolderRecord] = []
      var conversations: [WorkspaceConversationRecord] = []
      var notes: [WorkspaceNoteRecord] = []
      if let operatorID = try canonicalWorkspaceOperatorIDUnlocked() {
        folders = try decodeCanonicalRowsUnlocked(
          """
          SELECT json_object(
            'id', id, 'name', name, 'icon', icon, 'position', position,
            'is_pinned', is_pinned
          )
          FROM folders
          WHERE user_id = ?
          ORDER BY is_pinned DESC, position, name, id
          """,
          operatorID: operatorID,
          as: WorkspaceFolderRecord.self
        )
        conversations = try decodeCanonicalRowsUnlocked(
          """
          SELECT json_object(
            'id', id, 'agent_id', agent_id,
            'agent_codename', agent_codename,
            'governing_plane', governing_plane,
            'authority_device_id', authority_device_id, 'title', title,
            'local_runtime_kind', (
              SELECT runtime_kind
              FROM desktop_local_acp_sessions AS local_session
              WHERE local_session.conversation_id = dashboard_conversations.id
            ),
            'remote_workspace_id', (
              SELECT remote_workspace_id
              FROM desktop_local_acp_sessions AS local_session
              WHERE local_session.conversation_id = dashboard_conversations.id
            ),
            'unread', unread, 'last_message_preview', last_message_preview,
            'openclaw_session_key', COALESCE(openclaw_session_key,
              (SELECT session_key FROM desktop_openclaw_gateway_sessions
               WHERE conversation_id = dashboard_conversations.id)),
            'imported_at', COALESCE(
              (SELECT imported_at FROM desktop_session_imports WHERE conversation_id = dashboard_conversations.id),
              (SELECT imported_at FROM desktop_openclaw_import_activity WHERE conversation_id = dashboard_conversations.id
                AND instr(COALESCE(dashboard_conversations.openclaw_session_key, ''), ':wovenmatter:') = 0)
            ),
            'last_message_at', last_message_at, 'folder_id', folder_id,
            'is_pinned', is_pinned,
            'is_archived', is_archived
          )
          FROM dashboard_conversations
          WHERE (user_id = ? OR desktop_owned = 1)
            AND deleted_at IS NULL AND is_archived = 0
            AND governing_plane = 'wovenmatter_macos'
          ORDER BY last_message_at DESC, id DESC
          """,
          operatorID: operatorID,
          as: WorkspaceConversationRecord.self
        )

        notes = try decodeCanonicalRowsUnlocked(
          """
          SELECT json_object(
            'id', id, 'folder_id', folder_id, 'title', title,
            'content', content, 'created_at', created_at,
            'updated_at', updated_at, 'is_pinned', is_pinned
          )
          FROM notes
          WHERE user_id = ? AND deleted_at IS NULL
          ORDER BY is_pinned DESC, updated_at DESC, id DESC
          """,
          operatorID: operatorID,
          as: WorkspaceNoteRecord.self
        )
      }

      let revisionStatement = try prepareUnlocked(
        "SELECT revision FROM desktop_dashboard_revision WHERE singleton = 1"
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

  func canonicalWorkspaceOperatorIDUnlocked() throws -> String? {
    let inferred = try prepareUnlocked("""
      SELECT user_id
      FROM (
        SELECT user_id FROM dashboard_conversations WHERE deleted_at IS NULL
        UNION ALL
        SELECT user_id FROM dashboard_agents WHERE deleted_at IS NULL
        UNION ALL
        SELECT user_id FROM notes WHERE deleted_at IS NULL
        UNION ALL
        SELECT user_id FROM folders
        UNION ALL
        SELECT user_id FROM dashboard_calendar_items
        UNION ALL
        SELECT id AS user_id FROM profiles
      )
      GROUP BY user_id
      ORDER BY COUNT(*) DESC, user_id
      LIMIT 1
      """)
    defer { sqlite3_finalize(inferred) }
    let inferredCode = sqlite3_step(inferred)
    if inferredCode == SQLITE_ROW { return try text(inferred, column: 0) }
    guard inferredCode == SQLITE_DONE else { throw stepError() }
    return nil
  }

  func localMutationOperatorIDUnlocked() throws -> String {
    try canonicalWorkspaceOperatorIDUnlocked() ?? "local-operator"
  }

  func validateFolderUnlocked(id: String?, operatorID: String) throws {
    guard let id else { return }
    let statement = try prepareUnlocked("""
      SELECT 1 FROM folders
      WHERE id = ? AND user_id = ?
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(operatorID, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
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
