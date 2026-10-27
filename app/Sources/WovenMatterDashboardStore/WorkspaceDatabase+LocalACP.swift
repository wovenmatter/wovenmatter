import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

public struct LocalACPSessionDescriptor: Equatable, Sendable {
  public let conversationID: String
  public let runtimeKind: AgentRuntimeKind
  public let title: String
  public let acpSessionID: String?
  public let model: String?
  public let thinking: String?
  public let permission: String?
  public let remoteWorkspaceID: UUID?

  public init(
    conversationID: String,
    runtimeKind: AgentRuntimeKind,
    title: String,
    acpSessionID: String?,
    model: String? = nil,
    thinking: String? = nil,
    permission: String? = nil,
    remoteWorkspaceID: UUID? = nil
  ) {
    self.conversationID = conversationID
    self.runtimeKind = runtimeKind
    self.title = title
    self.acpSessionID = acpSessionID
    self.model = model
    self.thinking = thinking
    self.permission = permission
    self.remoteWorkspaceID = remoteWorkspaceID
  }
}

public struct LocalACPRunIdentifiers: Equatable, Sendable {
  public let runID: String
  public let userMessageID: String
  public let assistantMessageID: String

  public init(runID: String, userMessageID: String, assistantMessageID: String) {
    self.runID = runID
    self.userMessageID = userMessageID
    self.assistantMessageID = assistantMessageID
  }
}

public struct LocalACPSteeringIdentifiers: Equatable, Sendable {
  public let runID: String
  public let userMessageID: String
  public let assistantMessageID: String

  public init(runID: String, userMessageID: String, assistantMessageID: String) {
    self.runID = runID
    self.userMessageID = userMessageID
    self.assistantMessageID = assistantMessageID
  }
}

public enum LocalACPSessionDatabaseError: LocalizedError, Equatable, Sendable {
  case runtimeUnavailable
  case sessionNotFound
  case runNotFound
  case runAlreadyActive
  case steeringUnsupported
  case anotherApplicationIsRunningPrompt

  public var errorDescription: String? {
    switch self {
    case .runtimeUnavailable:
      "The selected local ACP runtime is not available."
    case .sessionNotFound:
      "The local ACP session is no longer available."
    case .runNotFound:
      "The local ACP run is no longer available."
    case .runAlreadyActive:
      "This local ACP session is already running a prompt."
    case .steeringUnsupported:
      "This agent does not support steering during an active turn."
    case .anotherApplicationIsRunningPrompt:
      "Another Woven Matter app is already running a local prompt."
    }
  }
}

// Device-owned sessions and run writes, including streaming and steering.
extension WorkspaceDatabaseConnection {
  func knownSessionIDs(sql: String, scope: String) throws -> Set<String> {
    try withLock {
      let statement = try prepareUnlocked(sql)
      defer { sqlite3_finalize(statement) }
      try bind(scope, at: 1, to: statement)
      var ids: Set<String> = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return ids }
        guard code == SQLITE_ROW else { throw stepError() }
        ids.insert(try text(statement, column: 0))
      }
    }
  }

  func markSessionImportedUnlocked(conversationID: String) throws {
    let statement = try prepareUnlocked("INSERT OR IGNORE INTO desktop_session_imports (conversation_id, imported_at) VALUES (?, ?)")
    defer { sqlite3_finalize(statement) }
    try bind(conversationID, at: 1, to: statement)
    try bind(Self.timestamp(Date()), at: 2, to: statement)
    try stepDone(statement)
  }

  @discardableResult
  public func createLocalACPSession(
    runtimeKind: AgentRuntimeKind,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date(),
    openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
    importedOpenCodeSnapshot: OpenCodeSessionSnapshot? = nil,
    requestedConversationID: UUID? = nil,
    allowMissingCalendarFolder: Bool = false,
    executionRoot: SessionCreationRoot
  ) throws -> String {
    try transaction {
      let id = try createLocalACPSessionUnlocked(runtimeKind: runtimeKind, title: title, ownerDeviceID: ownerDeviceID, createdAt: createdAt, openCodeAssociation: openCodeAssociation, importedOpenCodeSnapshot: importedOpenCodeSnapshot, requestedConversationID: requestedConversationID, allowMissingCalendarFolder: allowMissingCalendarFolder)
      try saveSessionExecutionRootUnlocked(id: id, folderID: executionRoot.folderID,
        location: executionRoot.location, defaultPath: executionRoot.defaultPath)
      if importedOpenCodeSnapshot != nil {
        try toolsExecuteUnlocked("INSERT OR IGNORE INTO retained_execution_history(conversation_id) VALUES(?)", [id])
        try toolsExecuteUnlocked("UPDATE dashboard_conversations SET is_archived=1 WHERE id=?", [id])
      }
      return id
    }
  }

  @discardableResult
  func createLocalACPSessionUnlocked(
    runtimeKind: AgentRuntimeKind,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date(),
    openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
    importedOpenCodeSnapshot: OpenCodeSessionSnapshot? = nil,
    requestedConversationID: UUID? = nil,
    allowMissingCalendarFolder: Bool = false
  ) throws -> String {
    guard LocalACPRuntimeCatalog.definition(for: runtimeKind) != nil,
          let codename = LocalACPRuntimeCatalog.conversationCodename(
            for: runtimeKind
          ) else {
      throw LocalACPSessionDatabaseError.runtimeUnavailable
    }
    if openCodeAssociation != nil && runtimeKind != .opencode { throw LocalACPSessionDatabaseError.runtimeUnavailable }
    if let snapshot = importedOpenCodeSnapshot {
      guard let link = openCodeAssociation, snapshot.info["id"].text == link.sessionID,
            snapshot.olderCursor == nil else { throw WorkspaceDatabaseError.corruptRow }
    }

      if let link = openCodeAssociation {
        let existing = try prepareUnlocked("SELECT conversation_id FROM desktop_opencode_sessions WHERE connection_id=? AND session_id=?")
        defer { sqlite3_finalize(existing) }
        try bind(link.connectionID, at: 1, to: existing); try bind(link.sessionID, at: 2, to: existing)
        if sqlite3_step(existing) == SQLITE_ROW { return try text(existing, column: 0) }
      }
      let operatorID = try localMutationOperatorIDUnlocked()
      let agentID = try ensureLocalCLIAgentUnlocked(
        runtimeKind: runtimeKind,
        ownerDeviceID: ownerDeviceID,
        operatorID: operatorID,
        status: .ready,
        updatedAt: createdAt
      )
      let conversationID = (requestedConversationID ?? UUID()).uuidString.lowercased()
      let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
      let sessionTitle = cleanTitle.isEmpty
        ? "New \(runtimeKind.displayName) chat"
        : cleanTitle
      let timestamp = Self.timestamp(createdAt)
      let conversation = try prepareUnlocked("""
        INSERT INTO dashboard_conversations (
          id, user_id, agent_id, agent_codename, governing_plane,
          authority_kind, authority_device_id, authority_agent_id,
          title, unread, kind,
          is_deletable, is_archived, last_message_at, is_pinned,
          created_at, updated_at, desktop_owned
        ) VALUES (?, ?, ?, ?, 'wovenmatter_macos', 'device_owned', ?, ?,
          ?, 0, 'local_acp', 1, 0, ?, 0, ?, ?, 1)
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(conversationID, at: 1, to: conversation)
      try bind(operatorID, at: 2, to: conversation)
      try bind(agentID, at: 3, to: conversation)
      try bind(codename, at: 4, to: conversation)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 5, to: conversation)
      try bind(agentID, at: 6, to: conversation)
      try bind(sessionTitle, at: 7, to: conversation)
      try bind(timestamp, at: 8, to: conversation)
      try bind(timestamp, at: 9, to: conversation)
      try bind(timestamp, at: 10, to: conversation)
      try stepDone(conversation)

      let session = try prepareUnlocked("""
        INSERT INTO desktop_local_acp_sessions (
          conversation_id, agent_id, runtime_kind, governing_plane,
          authority_kind, authority_device_id, authority_agent_id, revision,
          title, created_at, updated_at
        ) VALUES (?, ?, ?, 'wovenmatter_macos', 'device_owned', ?, ?, 1, ?, ?, ?)
        """)
      defer { sqlite3_finalize(session) }
      try bind(conversationID, at: 1, to: session)
      try bind(agentID, at: 2, to: session)
      try bind(runtimeKind.rawValue, at: 3, to: session)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 4, to: session)
      try bind(agentID, at: 5, to: session)
      try bind(sessionTitle, at: 6, to: session)
      try bind(timestamp, at: 7, to: session)
      try bind(timestamp, at: 8, to: session)
      try stepDone(session)
      try adoptReservedSessionOriginUnlocked(conversationID, allowMissingCalendarFolder: allowMissingCalendarFolder)
      if let link = openCodeAssociation {
        let association = try prepareUnlocked("INSERT INTO desktop_opencode_sessions(conversation_id, connection_id, session_id, snapshot_json) VALUES (?, ?, ?, '{}')")
        defer { sqlite3_finalize(association) }
        try bind(conversationID, at: 1, to: association); try bind(link.connectionID, at: 2, to: association)
        try bind(link.sessionID, at: 3, to: association); try stepDone(association)
      }
      if let snapshot = importedOpenCodeSnapshot {
        try markSessionImportedUnlocked(conversationID: conversationID)
        try recordHistoryUnlocked(.init(conversationID: conversationID, harness: "opencode",
          kind: "import.snapshot", payload: String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self), completeness: "native-export"))
        try saveOpenCodeSnapshotUnlocked(snapshot, conversationID: conversationID, fallbackTitle: sessionTitle)
      }
      return conversationID
  }

  @discardableResult
  public func createRemoteACPSession(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date(),
    openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
    requestedConversationID: UUID? = nil,
    allowMissingCalendarFolder: Bool = false,
    executionRoot: SessionCreationRoot
  ) throws -> String {
    guard executionRoot.location.workspaceID == "remote:" + remoteWorkspaceID.uuidString.lowercased() else {
      throw WorkspaceToolError.invalid("Create this chat in its owning execution workspace.")
    }
    return try transaction {
      let id = try createRemoteACPSessionUnlocked(runtimeKind: runtimeKind, remoteWorkspaceID: remoteWorkspaceID, remoteWorkspaceName: remoteWorkspaceName, title: title, ownerDeviceID: ownerDeviceID, createdAt: createdAt, openCodeAssociation: openCodeAssociation, requestedConversationID: requestedConversationID, allowMissingCalendarFolder: allowMissingCalendarFolder)
      try saveSessionExecutionRootUnlocked(id: id, folderID: executionRoot.folderID,
        location: executionRoot.location, defaultPath: executionRoot.defaultPath)
      return id
    }
  }

  @discardableResult
  func createRemoteACPSessionUnlocked(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date(),
    openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
    requestedConversationID: UUID? = nil,
    allowMissingCalendarFolder: Bool = false
  ) throws -> String {
    guard LocalACPRuntimeCatalog.definition(for: runtimeKind) != nil else {
      throw LocalACPSessionDatabaseError.runtimeUnavailable
    }

      if let link = openCodeAssociation {
        guard runtimeKind == .opencode,
              link.connectionID == "remote-workspace:" + remoteWorkspaceID.uuidString.lowercased() else {
          throw LocalACPSessionDatabaseError.runtimeUnavailable
        }
        let existing = try prepareUnlocked("SELECT conversation_id FROM desktop_opencode_sessions WHERE connection_id=? AND session_id=?")
        defer { sqlite3_finalize(existing) }
        try bind(link.connectionID, at: 1, to: existing)
        try bind(link.sessionID, at: 2, to: existing)
        if sqlite3_step(existing) == SQLITE_ROW { return try text(existing, column: 0) }
      }
      let operatorID = try localMutationOperatorIDUnlocked()
      let agentID = try ensureRemoteHarnessAgentUnlocked(
        runtimeKind: runtimeKind,
        remoteWorkspaceID: remoteWorkspaceID,
        remoteWorkspaceName: remoteWorkspaceName,
        ownerDeviceID: ownerDeviceID,
        operatorID: operatorID,
        status: .ready,
        updatedAt: createdAt
      )
      let conversationID = (requestedConversationID ?? UUID()).uuidString.lowercased()
      let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
      let sessionTitle = cleanTitle.isEmpty
        ? "New \(runtimeKind.displayName) chat"
        : cleanTitle
      let workspaceID = remoteWorkspaceID.uuidString.lowercased()
      let timestamp = Self.timestamp(createdAt)
      let conversation = try prepareUnlocked("""
        INSERT INTO dashboard_conversations (
          id, user_id, agent_id, agent_codename, governing_plane,
          authority_kind, authority_device_id, authority_agent_id,
          title, unread, kind,
          is_deletable, is_archived, last_message_at, is_pinned,
          created_at, updated_at, desktop_owned
        ) VALUES (?, ?, ?, ?, 'wovenmatter_macos', 'device_owned', ?, ?,
          ?, 0, 'remote_acp', 1, 0, ?, 0, ?, ?, 1)
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(conversationID, at: 1, to: conversation)
      try bind(operatorID, at: 2, to: conversation)
      try bind(agentID, at: 3, to: conversation)
      try bind("remote-\(workspaceID.prefix(8))-\(runtimeKind.rawValue)", at: 4, to: conversation)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 5, to: conversation)
      try bind(agentID, at: 6, to: conversation)
      try bind(sessionTitle, at: 7, to: conversation)
      try bind(timestamp, at: 8, to: conversation)
      try bind(timestamp, at: 9, to: conversation)
      try bind(timestamp, at: 10, to: conversation)
      try stepDone(conversation)

      let session = try prepareUnlocked("""
        INSERT INTO desktop_local_acp_sessions (
          conversation_id, agent_id, runtime_kind, governing_plane,
          authority_kind, authority_device_id, authority_agent_id, revision,
          title, remote_workspace_id, created_at, updated_at
        ) VALUES (?, ?, ?, 'wovenmatter_macos', 'device_owned', ?, ?, 1,
          ?, ?, ?, ?)
        """)
      defer { sqlite3_finalize(session) }
      try bind(conversationID, at: 1, to: session)
      try bind(agentID, at: 2, to: session)
      try bind(runtimeKind.rawValue, at: 3, to: session)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 4, to: session)
      try bind(agentID, at: 5, to: session)
      try bind(sessionTitle, at: 6, to: session)
      try bind(workspaceID, at: 7, to: session)
      try bind(timestamp, at: 8, to: session)
      try bind(timestamp, at: 9, to: session)
      try stepDone(session)
      try adoptReservedSessionOriginUnlocked(conversationID, allowMissingCalendarFolder: allowMissingCalendarFolder)
      if let link = openCodeAssociation {
        let association = try prepareUnlocked("INSERT INTO desktop_opencode_sessions(conversation_id, connection_id, session_id, snapshot_json) VALUES (?, ?, ?, '{}')")
        defer { sqlite3_finalize(association) }
        try bind(conversationID, at: 1, to: association)
        try bind(link.connectionID, at: 2, to: association)
        try bind(link.sessionID, at: 3, to: association)
        try stepDone(association)
      }
      return conversationID
  }

  @discardableResult
  public func localACPSession(
    conversationID: String
  ) throws -> LocalACPSessionDescriptor {
    try withLock {
      let statement = try prepareUnlocked("""
        SELECT session.conversation_id, session.runtime_kind,
          session.title, session.acp_session_id, session.model,
          session.thinking, session.remote_workspace_id, session.permission
        FROM desktop_local_acp_sessions AS session
        JOIN dashboard_conversations AS conversation
          ON conversation.id = session.conversation_id
        WHERE session.conversation_id = ?
          AND conversation.desktop_owned = 1
          AND conversation.deleted_at IS NULL
        """)
      defer { sqlite3_finalize(statement) }
      try bind(conversationID, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_ROW,
            let runtimeKind = AgentRuntimeKind(rawValue: try text(statement, column: 1)) else {
        throw LocalACPSessionDatabaseError.sessionNotFound
      }
      return LocalACPSessionDescriptor(
        conversationID: try text(statement, column: 0),
        runtimeKind: runtimeKind,
        title: try text(statement, column: 2),
        acpSessionID: optionalText(statement, column: 3),
        model: optionalText(statement, column: 4),
        thinking: optionalText(statement, column: 5),
        permission: optionalText(statement, column: 7),
        remoteWorkspaceID: optionalText(statement, column: 6)
          .flatMap(UUID.init(uuidString:))
      )
    }
  }

  private func localRunAuthorityUnlocked(
    runID: String
  ) throws -> (
    conversationID: String,
    assistantMessageID: String,
    userID: String,
    agentID: String,
    ownerDeviceID: UUID
  ) {
    let statement = try prepareUnlocked("""
      SELECT conversation_id, assistant_message_id, user_id, agent_id,
        authority_device_id
      FROM dashboard_runs
      WHERE id = ? AND authority_kind = 'device_owned'
        AND governing_plane = 'wovenmatter_macos'
      """)
    defer { sqlite3_finalize(statement) }
    try bind(runID, at: 1, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW,
          let ownerDeviceID = UUID(uuidString: try text(statement, column: 4)) else {
      throw LocalACPSessionDatabaseError.runNotFound
    }
    return (
      try text(statement, column: 0),
      try text(statement, column: 1),
      try text(statement, column: 2),
      try text(statement, column: 3),
      ownerDeviceID
    )
  }

  /// Repair IDs saved by older configuration-only Claude probes. A missing
  /// native draft is replaceable only before this local chat has any history.
  func discardUnpromptedClaudeDraftSessionID(conversationID: String, expectedSessionID: String) throws -> Bool {
    try transaction {
      let statement = try prepareUnlocked("""
        UPDATE desktop_local_acp_sessions
        SET acp_session_id=NULL, revision=revision+1, updated_at=?
        WHERE conversation_id=? AND acp_session_id=? AND runtime_kind='claude_code'
          AND remote_workspace_id IS NULL AND governing_plane='wovenmatter_macos' AND authority_kind='device_owned'
          AND EXISTS (SELECT 1 FROM dashboard_conversations c WHERE c.id=desktop_local_acp_sessions.conversation_id
            AND c.desktop_owned=1 AND c.deleted_at IS NULL AND c.governing_plane='wovenmatter_macos')
          AND NOT EXISTS (SELECT 1 FROM dashboard_runs WHERE conversation_id=desktop_local_acp_sessions.conversation_id)
          AND NOT EXISTS (SELECT 1 FROM dashboard_messages WHERE conversation_id=desktop_local_acp_sessions.conversation_id)
          AND NOT EXISTS (SELECT 1 FROM dashboard_run_events WHERE conversation_id=desktop_local_acp_sessions.conversation_id)
          AND NOT EXISTS (SELECT 1 FROM dashboard_run_trace_events WHERE conversation_id=desktop_local_acp_sessions.conversation_id)
          AND NOT EXISTS (SELECT 1 FROM desktop_session_imports WHERE conversation_id=desktop_local_acp_sessions.conversation_id)
          AND NOT EXISTS (SELECT 1 FROM retained_execution_history WHERE conversation_id=desktop_local_acp_sessions.conversation_id)
        """)
      defer { sqlite3_finalize(statement) }
      try bind(Self.timestamp(Date()), at: 1, to: statement)
      try bind(conversationID, at: 2, to: statement)
      try bind(expectedSessionID, at: 3, to: statement)
      try stepDone(statement)
      return changedRowCountUnlocked == 1
    }
  }

  public func updateLocalACPSessionID(
    conversationID: String,
    runID: String? = nil,
    sessionID: String,
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      let timestamp = Self.timestamp(updatedAt)
      let session = try prepareUnlocked("""
        UPDATE desktop_local_acp_sessions
        SET acp_session_id = ?, revision = revision + 1, updated_at = ?
        WHERE conversation_id = ?
        """)
      defer { sqlite3_finalize(session) }
      try bind(sessionID, at: 1, to: session)
      try bind(timestamp, at: 2, to: session)
      try bind(conversationID, at: 3, to: session)
      try stepDone(session)
      guard changedRowCountUnlocked == 1 else {
        throw LocalACPSessionDatabaseError.sessionNotFound
      }

      if let runID {
        let run = try prepareUnlocked("""
          UPDATE dashboard_runs
          SET openclaw_session_key = ?, updated_at = ?
          WHERE id = ? AND conversation_id = ?
            AND desktop_owned = 1 AND status = 'running'
          """)
        defer { sqlite3_finalize(run) }
        try bind(sessionID, at: 1, to: run)
        try bind(timestamp, at: 2, to: run)
        try bind(runID, at: 3, to: run)
        try bind(conversationID, at: 4, to: run)
        try stepDone(run)
        guard changedRowCountUnlocked == 1 else {
          throw LocalACPSessionDatabaseError.runNotFound
        }
      }
    }
  }

  public func updateLocalACPSessionConfiguration(
    conversationID: String,
    model: String?,
    thinking: String?,
    permission: String? = nil,
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      let statement = try prepareUnlocked("""
        UPDATE desktop_local_acp_sessions
        SET model = ?, thinking = ?, permission = COALESCE(?, permission), revision = revision + 1, updated_at = ?
        WHERE conversation_id = ?
        """)
      defer { sqlite3_finalize(statement) }
      try bindNullable(model, at: 1, to: statement)
      try bindNullable(thinking, at: 2, to: statement)
      try bindNullable(permission, at: 3, to: statement)
      try bind(Self.timestamp(updatedAt), at: 4, to: statement)
      try bind(conversationID, at: 5, to: statement)
      try stepDone(statement)
      guard changedRowCountUnlocked == 1 else {
        throw LocalACPSessionDatabaseError.sessionNotFound
      }
    }
  }

  public func beginLocalACPRun(
    conversationID: String,
    content: String,
    noteContext: AgentNoteContext? = nil,
    createdAt: Date = Date()
  ) throws -> LocalACPRunIdentifiers {
    try beginLocalACPRun(
      conversationID: conversationID,
      input: AgentMessageInput(text: content),
      noteContext: noteContext,
      createdAt: createdAt
    )
  }

  public func beginLocalACPRun(
    conversationID: String,
    input: AgentMessageInput,
    noteContext: AgentNoteContext? = nil,
    createdAt: Date = Date()
  ) throws -> LocalACPRunIdentifiers {
    guard try localACPSession(conversationID: conversationID).runtimeKind != .opencode else {
      throw OpenCodeError.message("OpenCode v1 transcripts are read-only. OpenCode v2 uses the shared server directly.")
    }
    return try transaction {
      _ = try availableSessionExecutionRoot(id: conversationID)
      guard try companionIDsUnlocked("SELECT workspace_id FROM companion_execution_conversations WHERE id=?", bindings: [conversationID]).isEmpty else {
        throw CompanionAPIError(code: "execution_owner", message: "This conversation is owned by its independent execution workspace. Reconnect it instead of starting a legacy attachment.")
      }
      let active = try prepareUnlocked("""
        SELECT 1 FROM dashboard_runs
        WHERE conversation_id = ? AND desktop_owned = 1 AND status IN ('running', 'uncertain')
        LIMIT 1
        """)
      defer { sqlite3_finalize(active) }
      try bind(conversationID, at: 1, to: active)
      guard sqlite3_step(active) == SQLITE_DONE else {
        throw LocalACPSessionDatabaseError.runAlreadyActive
      }

      let context = try prepareUnlocked("""
        SELECT conversation.user_id, conversation.agent_id,
          conversation.agent_codename, conversation.authority_device_id,
          COALESCE(session.acp_session_id, '')
        FROM dashboard_conversations AS conversation
        JOIN desktop_local_acp_sessions AS session
          ON session.conversation_id = conversation.id
        WHERE conversation.id = ? AND conversation.desktop_owned = 1
          AND conversation.deleted_at IS NULL AND conversation.is_archived = 0
        """)
      defer { sqlite3_finalize(context) }
      try bind(conversationID, at: 1, to: context)
      guard sqlite3_step(context) == SQLITE_ROW else {
        throw LocalACPSessionDatabaseError.sessionNotFound
      }
      let userID = try text(context, column: 0)
      let agentID = try text(context, column: 1)
      let codename = try text(context, column: 2)
      guard let ownerDeviceID = UUID(uuidString: try text(context, column: 3)) else {
        throw WorkspaceDatabaseError.corruptRow
      }
      let acpSessionID = try text(context, column: 4)
      let identifiers = LocalACPRunIdentifiers(
        runID: UUID().uuidString.lowercased(),
        userMessageID: UUID().uuidString.lowercased(),
        assistantMessageID: UUID().uuidString.lowercased()
      )
      let latestMessage = try prepareUnlocked("""
        SELECT created_at
        FROM dashboard_messages
        WHERE conversation_id = ?
        ORDER BY created_at DESC
        LIMIT 1
        """)
      defer { sqlite3_finalize(latestMessage) }
      try bind(conversationID, at: 1, to: latestMessage)
      let minimumCreatedAt: Date?
      let latestMessageCode = sqlite3_step(latestMessage)
      if latestMessageCode == SQLITE_ROW {
        minimumCreatedAt = Self.date(
          try text(latestMessage, column: 0)
        )?.addingTimeInterval(0.001)
      } else if latestMessageCode == SQLITE_DONE {
        minimumCreatedAt = nil
      } else {
        throw stepError()
      }
      let orderedCreatedAt = max(createdAt, minimumCreatedAt ?? createdAt)
      let userTimestamp = Self.timestamp(orderedCreatedAt)
      let assistantTimestamp = Self.timestamp(
        orderedCreatedAt.addingTimeInterval(0.001)
      )

      let message = try prepareUnlocked("""
        INSERT INTO dashboard_messages (
          id, conversation_id, run_id, role, message_source, content,
          status, governing_plane, authority_kind, authority_device_id,
          authority_agent_id, created_at, updated_at, desktop_owned
        ) VALUES (?, ?, ?, ?, 'local_acp', ?, ?, 'wovenmatter_macos',
          'device_owned', ?, ?, ?, ?, 1)
        """)
      defer { sqlite3_finalize(message) }
      for (id, role, body, status, timestamp) in [
        (identifiers.userMessageID, "user", input.text, "completed", userTimestamp),
        (identifiers.assistantMessageID, "assistant", "", "streaming", assistantTimestamp),
      ] {
        sqlite3_reset(message)
        sqlite3_clear_bindings(message)
        try bind(id, at: 1, to: message)
        try bind(conversationID, at: 2, to: message)
        try bind(identifiers.runID, at: 3, to: message)
        try bind(role, at: 4, to: message)
        try bind(body, at: 5, to: message)
        try bind(status, at: 6, to: message)
        try bind(ownerDeviceID.uuidString.lowercased(), at: 7, to: message)
        try bind(agentID, at: 8, to: message)
        try bind(timestamp, at: 9, to: message)
        try bind(timestamp, at: 10, to: message)
        try stepDone(message)
      }

      let run = try prepareUnlocked("""
        INSERT INTO dashboard_runs (
          id, conversation_id, user_id, agent_id, agent_codename,
          governing_plane, authority_kind, authority_device_id,
          authority_agent_id, openclaw_session_key,
          user_message_id, assistant_message_id, status, started_at,
          created_at, updated_at, desktop_owned
        ) VALUES (?, ?, ?, ?, ?, 'wovenmatter_macos', 'device_owned', ?, ?,
          ?, ?, ?, 'running', ?, ?, ?, 1)
        """)
      defer { sqlite3_finalize(run) }
      try bind(identifiers.runID, at: 1, to: run)
      try bind(conversationID, at: 2, to: run)
      try bind(userID, at: 3, to: run)
      try bind(agentID, at: 4, to: run)
      try bind(codename, at: 5, to: run)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 6, to: run)
      try bind(agentID, at: 7, to: run)
      try bind(acpSessionID, at: 8, to: run)
      try bind(identifiers.userMessageID, at: 9, to: run)
      try bind(identifiers.assistantMessageID, at: 10, to: run)
      try bind(userTimestamp, at: 11, to: run)
      try bind(userTimestamp, at: 12, to: run)
      try bind(userTimestamp, at: 13, to: run)
      try stepDone(run)
      try insertNoteContextUnlocked(
        noteContext,
        identifiers: identifiers,
        conversationID: conversationID,
        userID: userID,
        governingPlane: "wovenmatter_macos",
        authorityDeviceID: ownerDeviceID.uuidString.lowercased(),
        authorityAgentID: agentID,
        createdAt: orderedCreatedAt
      )

      if let deliveryID=input.historyDeliveryID {
        try attachSessionMessageUnlocked(requestID:deliveryID,messageID:identifiers.userMessageID)
      }
      try insertMessageAttachmentsUnlocked(
        input.attachments,
        conversationID: conversationID,
        messageID: identifiers.userMessageID,
        userID: userID,
        agentID: agentID,
        ownerDeviceID: ownerDeviceID,
        governingPlane: .wovenmatterMacOS,
        createdAt: orderedCreatedAt
      )

      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, last_message_at = MAX(?, COALESCE((SELECT imported_at FROM desktop_session_imports WHERE conversation_id=dashboard_conversations.id), '')), updated_at = ?
        WHERE id = ? AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(Self.localPreview(input.previewText), at: 1, to: conversation)
      try bind(userTimestamp, at: 2, to: conversation)
      try bind(userTimestamp, at: 3, to: conversation)
      try bind(conversationID, at: 4, to: conversation)
      try stepDone(conversation)

      return identifiers
    }
  }

  func insertMessageAttachmentsUnlocked(
    _ attachments: [AgentMessageAttachmentDraft],
    conversationID: String,
    messageID: String,
    userID: String,
    agentID: String,
    ownerDeviceID: UUID,
    governingPlane: AgentGoverningPlane,
    createdAt: Date
  ) throws {
    let timestamp = Self.timestamp(createdAt)
    for attachment in attachments {
      switch attachment {
      case .file(let file):
        let statement = try prepareUnlocked("""
          INSERT INTO dashboard_message_attachments (
            id, conversation_id, message_id, kind, governing_plane,
            authority_kind, authority_device_id, authority_agent_id,
            desktop_owned, file_name, mime_type, size_bytes, content_hash,
            created_at
          ) VALUES (?, ?, ?, ?, ?, 'device_owned', ?, ?, 1, ?, ?, ?, ?, ?)
          """)
        defer { sqlite3_finalize(statement) }
        try bind(file.id, at: 1, to: statement)
        try bind(conversationID, at: 2, to: statement)
        try bind(messageID, at: 3, to: statement)
        try bind(file.kind.rawValue, at: 4, to: statement)
        try bind(governingPlane.rawValue, at: 5, to: statement)
        try bind(ownerDeviceID.uuidString.lowercased(), at: 6, to: statement)
        try bind(agentID, at: 7, to: statement)
        try bind(file.fileName, at: 8, to: statement)
        try bind(file.mimeType, at: 9, to: statement)
        guard sqlite3_bind_int64(statement, 10, file.sizeBytes) == SQLITE_OK else {
          throw bindError()
        }
        try bind(file.contentHash, at: 11, to: statement)
        try bind(timestamp, at: 12, to: statement)
        try stepDone(statement)
      case .reference(let reference):
        if reference.kind == .conversation {
          try grantSessionReadUnlocked(sourceID: conversationID, targetID: reference.resourceID, kind: "attachment")
        }
        let statement = try prepareUnlocked("""
          INSERT INTO dashboard_message_references (
            id, conversation_id, message_id, user_id, governing_plane,
            authority_kind, authority_device_id, authority_agent_id,
            desktop_owned, resource_type, resource_id, source,
            title_snapshot, content_snapshot, folder_id_snapshot,
            folder_title_snapshot, agent_codename_snapshot, revision_snapshot,
            created_at
          ) VALUES (?, ?, ?, ?, ?, 'device_owned', ?, ?, 1, ?, ?, 'attached',
            ?, ?, ?, ?, ?, ?, ?)
          """)
        defer { sqlite3_finalize(statement) }
        try bind(reference.id, at: 1, to: statement)
        try bind(conversationID, at: 2, to: statement)
        try bind(messageID, at: 3, to: statement)
        try bind(userID, at: 4, to: statement)
        try bind(governingPlane.rawValue, at: 5, to: statement)
        try bind(ownerDeviceID.uuidString.lowercased(), at: 6, to: statement)
        try bind(agentID, at: 7, to: statement)
        try bind(reference.kind.rawValue, at: 8, to: statement)
        try bind(reference.resourceID, at: 9, to: statement)
        try bind(reference.titleSnapshot, at: 10, to: statement)
        try bind(reference.kind == .conversation ? "" : reference.contentSnapshot, at: 11, to: statement)
        try bindNullable(reference.folderIDSnapshot, at: 12, to: statement)
        try bindNullable(reference.folderTitleSnapshot, at: 13, to: statement)
        try bindNullable(reference.agentCodenameSnapshot, at: 14, to: statement)
        try bind(reference.revisionSnapshot, at: 15, to: statement)
        try bind(timestamp, at: 16, to: statement)
        try stepDone(statement)
      }
    }
  }

  public func activeDeviceOwnedConversationIDs() throws -> Set<String> {
    try withLock {
      let statement = try prepareUnlocked("""
        SELECT DISTINCT conversation_id
        FROM dashboard_runs
        WHERE desktop_owned = 1 AND authority_kind = 'device_owned'
          AND status IN ('running', 'uncertain')
        """)
      defer { sqlite3_finalize(statement) }
      var conversationIDs: Set<String> = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return conversationIDs }
        guard code == SQLITE_ROW else { throw stepError() }
        conversationIDs.insert(try text(statement, column: 0))
      }
    }
  }

  public func beginLocalACPSteeringTurn(
    runID: String,
    content: String,
    createdAt: Date = Date()
  ) throws -> LocalACPSteeringIdentifiers {
    try beginLocalACPSteeringTurn(
      runID: runID,
      input: AgentMessageInput(text: content),
      createdAt: createdAt
    )
  }

  public func beginLocalACPSteeringTurn(
    runID: String,
    input: AgentMessageInput,
    completesPreviousAssistant: Bool = true,
    createdAt: Date = Date()
  ) throws -> LocalACPSteeringIdentifiers {
    try transaction {
      try beginLocalACPSteeringTurnUnlocked(runID: runID, input: input,
        completesPreviousAssistant: completesPreviousAssistant, createdAt: createdAt)
    }
  }

  /// Commit the input before native dispatch. A definitive rejection may undo
  /// this reservation; an uncertain receipt must retain the original identity.
  func reserveLocalACPSteeringTurn(runID: String, input: AgentMessageInput,
                                   completesPreviousAssistant: Bool = true) throws -> LocalACPSteeringReservation {
    try transaction {
      guard let previous = try historyRowsUnlocked("""
        SELECT r.assistant_message_id, r.updated_at AS run_updated_at,
          m.status AS assistant_status, m.updated_at AS assistant_updated_at,
          c.id AS conversation_id, c.last_message_preview, c.last_message_at,
          c.updated_at AS conversation_updated_at
        FROM dashboard_runs r JOIN dashboard_messages m ON m.id=r.assistant_message_id
        JOIN dashboard_conversations c ON c.id=r.conversation_id
        WHERE r.id=? AND r.desktop_owned=1 AND r.status='running'
        """, values: [runID]).first?.objectValue else { throw LocalACPSessionDatabaseError.runNotFound }
      if let deliveryID = input.historyDeliveryID {
        let target = try historyRowsUnlocked("SELECT target_id FROM workspace_session_deliveries WHERE id=?", values: [deliveryID])
          .first?.objectValue?["target_id"]?.stringValue
        guard target == previous["conversation_id"]?.stringValue else {
          throw WorkspaceToolError.invalid("This delivery is not reserved for this session.")
        }
        try markToolDeliveryTransportStartedUnlocked(id: deliveryID)
      }
      let existingGrants = Set(try historyRowsUnlocked(
        "SELECT target_id FROM workspace_session_grants WHERE source_id=? AND kind='attachment'",
        values: [previous["conversation_id"]?.stringValue]).compactMap { $0.objectValue?["target_id"]?.stringValue })
      let newGrants = Set(input.references.filter { $0.kind == .conversation }.map(\.resourceID)).subtracting(existingGrants)
      let identifiers = try beginLocalACPSteeringTurnUnlocked(runID: runID, input: input,
        completesPreviousAssistant: completesPreviousAssistant, createdAt: Date())
      return LocalACPSteeringReservation(identifiers: identifiers,
        previous: previous.mapValues { $0.stringValue }, deliveryID: input.historyDeliveryID, newAttachmentGrants: newGrants)
    }
  }

  /// Only remove an untouched, latest segment after a definitive native refusal.
  /// If output or another owner advanced it, preserve the durable receipt instead.
  @discardableResult
  func rejectLocalACPSteeringTurn(_ reservation: LocalACPSteeringReservation) throws -> Bool {
    try transaction {
      let ids = reservation.identifiers
      guard !(try historyRowsUnlocked("""
        SELECT 1 FROM dashboard_runs r JOIN dashboard_messages m ON m.id=r.assistant_message_id
        WHERE r.id=? AND r.status='running' AND r.assistant_message_id=? AND m.content=''
        """, values: [ids.runID, ids.assistantMessageID])).isEmpty else { return false }
      func value(_ key: String) -> String? { reservation.previous[key] ?? nil }
      try toolsExecuteUnlocked("UPDATE dashboard_runs SET assistant_message_id=?,updated_at=? WHERE id=?",
        [value("assistant_message_id"), value("run_updated_at"), ids.runID])
      try toolsExecuteUnlocked("UPDATE dashboard_messages SET status=?,updated_at=? WHERE id=?",
        [value("assistant_status"), value("assistant_updated_at"), value("assistant_message_id")])
      if let deliveryID = reservation.deliveryID {
        try toolsExecuteUnlocked("UPDATE workspace_session_deliveries SET message_id=NULL,status='sending',transport_started=0 WHERE id=? AND message_id=?",
          [deliveryID, ids.userMessageID])
      }
      try toolsExecuteUnlocked("DELETE FROM desktop_openclaw_run_inputs WHERE local_run_id=? AND user_message_id=?",
        [ids.runID, ids.userMessageID])
      for table in ["dashboard_message_attachments", "dashboard_message_references"] {
        try toolsExecuteUnlocked("DELETE FROM \(table) WHERE message_id IN (?,?)", [ids.userMessageID, ids.assistantMessageID])
      }
      try toolsExecuteUnlocked("DELETE FROM dashboard_messages WHERE id IN (?,?)", [ids.userMessageID, ids.assistantMessageID])
      for target in reservation.newAttachmentGrants {
        try toolsExecuteUnlocked("""
          DELETE FROM workspace_session_grants WHERE source_id=? AND target_id=? AND kind='attachment'
            AND NOT EXISTS (SELECT 1 FROM dashboard_message_references WHERE conversation_id=? AND resource_type='conversation' AND resource_id=?)
          """, [value("conversation_id"), target, value("conversation_id"), target])
      }
      try toolsExecuteUnlocked("""
        UPDATE dashboard_conversations SET last_message_preview=?,last_message_at=?,updated_at=? WHERE id=?
        """, [value("last_message_preview"), value("last_message_at"), value("conversation_updated_at"), value("conversation_id")])
      return true
    }
  }

  private func beginLocalACPSteeringTurnUnlocked(
    runID: String, input: AgentMessageInput, completesPreviousAssistant: Bool, createdAt: Date
  ) throws -> LocalACPSteeringIdentifiers {
      let authority = try localRunAuthorityUnlocked(runID: runID)
      let active = try prepareUnlocked("""
        SELECT 1 FROM dashboard_runs
        WHERE id = ? AND desktop_owned = 1 AND status = 'running'
        LIMIT 1
        """)
      defer { sqlite3_finalize(active) }
      try bind(runID, at: 1, to: active)
      guard sqlite3_step(active) == SQLITE_ROW else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let latestMessage = try prepareUnlocked("""
        SELECT created_at
        FROM dashboard_messages
        WHERE conversation_id = ?
        ORDER BY created_at DESC
        LIMIT 1
        """)
      defer { sqlite3_finalize(latestMessage) }
      try bind(authority.conversationID, at: 1, to: latestMessage)
      let latestCode = sqlite3_step(latestMessage)
      let minimumCreatedAt: Date?
      if latestCode == SQLITE_ROW {
        minimumCreatedAt = Self.date(
          try text(latestMessage, column: 0)
        )?.addingTimeInterval(0.001)
      } else if latestCode == SQLITE_DONE {
        minimumCreatedAt = nil
      } else {
        throw stepError()
      }
      let orderedCreatedAt = max(createdAt, minimumCreatedAt ?? createdAt)
      let userTimestamp = Self.timestamp(orderedCreatedAt)
      let assistantTimestamp = Self.timestamp(
        orderedCreatedAt.addingTimeInterval(0.001)
      )
      let identifiers = LocalACPSteeringIdentifiers(
        runID: runID,
        userMessageID: UUID().uuidString.lowercased(),
        assistantMessageID: UUID().uuidString.lowercased()
      )

      if completesPreviousAssistant {
        let completedSegment = try prepareUnlocked("""
          UPDATE dashboard_messages
          SET status = 'completed', updated_at = ?
          WHERE id = ? AND desktop_owned = 1
          """)
        defer { sqlite3_finalize(completedSegment) }
        try bind(userTimestamp, at: 1, to: completedSegment)
        try bind(authority.assistantMessageID, at: 2, to: completedSegment)
        try stepDone(completedSegment)
        guard changedRowCountUnlocked == 1 else {
          throw LocalACPSessionDatabaseError.runNotFound
        }
      }

      let message = try prepareUnlocked("""
        INSERT INTO dashboard_messages (
          id, conversation_id, run_id, role, message_source, content,
          status, governing_plane, authority_kind, authority_device_id,
          authority_agent_id, created_at, updated_at, desktop_owned
        ) VALUES (?, ?, ?, ?, 'local_acp', ?, ?, 'wovenmatter_macos',
          'device_owned', ?, ?, ?, ?, 1)
        """)
      defer { sqlite3_finalize(message) }
      for (id, role, body, status, timestamp) in [
        (identifiers.userMessageID, "user", input.text, "completed", userTimestamp),
        (identifiers.assistantMessageID, "assistant", "", "streaming", assistantTimestamp),
      ] {
        sqlite3_reset(message)
        sqlite3_clear_bindings(message)
        try bind(id, at: 1, to: message)
        try bind(authority.conversationID, at: 2, to: message)
        try bind(runID, at: 3, to: message)
        try bind(role, at: 4, to: message)
        try bind(body, at: 5, to: message)
        try bind(status, at: 6, to: message)
        try bind(authority.ownerDeviceID.uuidString.lowercased(), at: 7, to: message)
        try bind(authority.agentID, at: 8, to: message)
        try bind(timestamp, at: 9, to: message)
        try bind(timestamp, at: 10, to: message)
        try stepDone(message)
      }

      if let deliveryID=input.historyDeliveryID {
        try attachSessionMessageUnlocked(requestID:deliveryID,messageID:identifiers.userMessageID)
      }
      try insertMessageAttachmentsUnlocked(
        input.attachments,
        conversationID: authority.conversationID,
        messageID: identifiers.userMessageID,
        userID: authority.userID,
        agentID: authority.agentID,
        ownerDeviceID: authority.ownerDeviceID,
        governingPlane: .wovenmatterMacOS,
        createdAt: orderedCreatedAt
      )

      let run = try prepareUnlocked("""
        UPDATE dashboard_runs
        SET assistant_message_id = ?, updated_at = ?
        WHERE id = ? AND desktop_owned = 1 AND status = 'running'
        """)
      defer { sqlite3_finalize(run) }
      try bind(identifiers.assistantMessageID, at: 1, to: run)
      try bind(userTimestamp, at: 2, to: run)
      try bind(runID, at: 3, to: run)
      try stepDone(run)
      guard changedRowCountUnlocked == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, last_message_at = MAX(?, COALESCE((SELECT imported_at FROM desktop_session_imports WHERE conversation_id=dashboard_conversations.id), '')), updated_at = ?
        WHERE id = ? AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(Self.localPreview(input.previewText), at: 1, to: conversation)
      try bind(userTimestamp, at: 2, to: conversation)
      try bind(userTimestamp, at: 3, to: conversation)
      try bind(authority.conversationID, at: 4, to: conversation)
      try stepDone(conversation)

      return identifiers
  }

  public func appendLocalACPAssistantChunk(
    runID: String,
    chunk: String,
    updatedAt: Date = Date()
  ) throws {
    guard !chunk.isEmpty else { return }
    try transaction {
      let timestamp = Self.timestamp(updatedAt)
      let message = try prepareUnlocked("""
        UPDATE dashboard_messages
        SET content = content || ?, status = 'streaming', updated_at = ?
        WHERE id = (
          SELECT assistant_message_id FROM dashboard_runs
          WHERE id = ? AND desktop_owned = 1 AND status = 'running'
        ) AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(message) }
      try bind(chunk, at: 1, to: message)
      try bind(timestamp, at: 2, to: message)
      try bind(runID, at: 3, to: message)
      try stepDone(message)
      guard changedRowCountUnlocked == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, last_message_at = MAX(?, COALESCE((SELECT imported_at FROM desktop_session_imports WHERE conversation_id=dashboard_conversations.id), '')), updated_at = ?
        WHERE id = (
          SELECT conversation_id FROM dashboard_runs WHERE id = ?
        ) AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(try localAssistantPreviewUnlocked(runID: runID), at: 1, to: conversation)
      try bind(timestamp, at: 2, to: conversation)
      try bind(timestamp, at: 3, to: conversation)
      try bind(runID, at: 4, to: conversation)
      try stepDone(conversation)
    }
  }

  public func replaceLocalACPAssistantMessage(
    runID: String,
    content: String,
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      let authority = try localRunAuthorityUnlocked(runID: runID)
      let timestamp = Self.timestamp(updatedAt)
      let message = try prepareUnlocked("""
        UPDATE dashboard_messages
        SET content = ?, status = 'streaming', updated_at = ?
        WHERE id = (
          SELECT assistant_message_id FROM dashboard_runs
          WHERE id = ? AND desktop_owned = 1 AND status = 'running'
        ) AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(message) }
      try bind(content, at: 1, to: message)
      try bind(timestamp, at: 2, to: message)
      try bind(runID, at: 3, to: message)
      try stepDone(message)
      guard changedRowCountUnlocked == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, last_message_at = MAX(?, COALESCE((SELECT imported_at FROM desktop_session_imports WHERE conversation_id=dashboard_conversations.id), '')), updated_at = ?
        WHERE id = ? AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(Self.localPreview(
        RemoteNoteEditEnvelope.redactingEnvelopes(in: content)
      ), at: 1, to: conversation)
      try bind(timestamp, at: 2, to: conversation)
      try bind(timestamp, at: 3, to: conversation)
      try bind(authority.conversationID, at: 4, to: conversation)
      try stepDone(conversation)
    }
  }

  public func completeLocalACPAssistantMessage(
    runID: String,
    assistantMessageID: String,
    error: String? = nil,
    completedAt: Date = Date()
  ) throws {
    try transaction {
      let timestamp = Self.timestamp(completedAt)
      let status = error == nil ? "completed" : "failed"
      let message = try prepareUnlocked("""
        UPDATE dashboard_messages
        SET content = CASE
          WHEN content = '' AND ? IS NOT NULL THEN ?
          ELSE content
        END, status = ?, updated_at = ?
        WHERE id = ? AND run_id = ? AND role = 'assistant'
          AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(message) }
      try bindNullable(error, at: 1, to: message)
      try bindNullable(error, at: 2, to: message)
      try bind(status, at: 3, to: message)
      try bind(timestamp, at: 4, to: message)
      try bind(assistantMessageID, at: 5, to: message)
      try bind(runID, at: 6, to: message)
      try stepDone(message)
      guard changedRowCountUnlocked == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }
    }
  }

  /// Freeze text before an activity without changing the canonical reply. The
  /// transaction and explicit reply identity also cover steering and app reopen.
  public func recordAssistantStreamBoundary(
    runID: String,
    assistantMessageID requestedMessageID: String? = nil,
    finalSegment: Bool = false,
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      let authority = try localRunAuthorityUnlocked(runID: runID)
      try recordAssistantStreamBoundaryUnlocked(runID: runID,
        assistantMessageID: requestedMessageID ?? authority.assistantMessageID,
        finalSegment: finalSegment, updatedAt: updatedAt)
    }
  }

  public func upsertDeviceOwnedRunActivity(
    runID: String,
    activity update: AgentRunActivity,
    appendingContent: Bool = false,
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      try upsertDeviceOwnedRunActivityUnlocked(
        runID: runID,
        activity: update,
        appendingContent: appendingContent,
        updatedAt: updatedAt
      )
    }
  }

  private func recordAssistantStreamBoundaryUnlocked(
    runID: String, assistantMessageID: String, finalSegment: Bool, updatedAt: Date
  ) throws {
    let statement = try prepareUnlocked("""
      SELECT content FROM dashboard_messages
      WHERE id = ? AND run_id = ? AND role = 'assistant' AND desktop_owned = 1
      """)
    defer { sqlite3_finalize(statement) }
    try bind(assistantMessageID, at: 1, to: statement)
    try bind(runID, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else { throw LocalACPSessionDatabaseError.runNotFound }
    let content = try text(statement, column: 0)
    let segments = try runActivityRecordsUnlocked(runIDs: [runID], assistantOnly: true)
      .map(\.activity).filter { $0.kind == .assistant && $0.assistantMessageID == assistantMessageID }
    let prefix = segments.compactMap(\.content).joined()
    // A canonical snapshot may invalidate later checkpoints while retaining
    // earlier commentary. Resume at the last prefix that still matches.
    let matchingSegment = segments.last { $0.assistantCheckpoint?.followingText(in: content) != nil }
    let tail = matchingSegment?.assistantCheckpoint?.followingText(in: content)
      ?? (content.hasPrefix(prefix) ? String(content.dropFirst(prefix.count)) : content)
    guard !tail.isEmpty else {
      if finalSegment, let last = matchingSegment ?? segments.last {
        try upsertDeviceOwnedRunActivityUnlocked(runID: runID,
          activity: AgentRunActivity(id: last.id, kind: .assistant, phase: "final"),
          appendingContent: false, updatedAt: updatedAt)
      }
      return
    }
    try upsertDeviceOwnedRunActivityUnlocked(runID: runID,
      activity: AgentRunActivity(
        id: "assistant:\(assistantMessageID):\(String(format: "%08d", segments.count))",
        kind: .assistant, phase: finalSegment ? "final" : "boundary", status: "completed",
        content: tail, assistantMessageID: assistantMessageID,
        assistantCheckpoint: AssistantTextCheckpoint(content)),
      appendingContent: false, updatedAt: updatedAt)
  }

  func upsertDeviceOwnedRunActivityUnlocked(
    runID: String,
    activity update: AgentRunActivity,
    appendingContent: Bool,
    updatedAt: Date,
    replacingActivity: Bool = false
  ) throws {
      let context = try prepareUnlocked("""
        SELECT 1
        FROM dashboard_runs
        WHERE id = ? AND authority_kind = 'device_owned' AND status = 'running'
        """)
      defer { sqlite3_finalize(context) }
      try bind(runID, at: 1, to: context)
      guard sqlite3_step(context) == SQLITE_ROW else {
        throw LocalACPSessionDatabaseError.runNotFound
      }
      let recordID = "\(runID):activity:\(update.id)"
      let existing = try prepareUnlocked("""
        SELECT content FROM dashboard_run_events WHERE id = ?
        """)
      try bind(recordID, at: 1, to: existing)
      let existingCode = sqlite3_step(existing)
      let prior: AgentRunActivity?
      if existingCode == SQLITE_ROW {
        prior = try? JSONDecoder().decode(
          AgentRunActivity.self,
          from: Data(try text(existing, column: 0).utf8)
        )
      } else if existingCode == SQLITE_DONE {
        prior = nil
      } else {
        sqlite3_finalize(existing)
        throw stepError()
      }
      sqlite3_finalize(existing)
      let activity = replacingActivity ? update : prior?.merging(update, appendingContent: appendingContent) ?? update
      let content = String(
        decoding: try JSONEncoder().encode(activity),
        as: UTF8.self
      )
      let timestamp = Self.timestamp(updatedAt)
      let statement = try prepareUnlocked("""
        INSERT INTO dashboard_run_events (
          id, run_id, conversation_id, user_id, governing_plane,
          authority_kind, authority_device_id, authority_agent_id,
          desktop_owned, event_type, content, created_at
        ) SELECT ?, run.id, run.conversation_id, run.user_id, run.governing_plane,
            run.authority_kind, run.authority_device_id, run.authority_agent_id,
            1, ?, ?, ?
          FROM dashboard_runs AS run WHERE run.id = ?
        ON CONFLICT(id) DO UPDATE SET
          event_type = excluded.event_type,
          content = excluded.content
        """)
      defer { sqlite3_finalize(statement) }
      try bind(recordID, at: 1, to: statement)
      try bind(activity.kind.rawValue, at: 2, to: statement)
      try bind(content, at: 3, to: statement)
      try bind(timestamp, at: 4, to: statement)
      try bind(runID, at: 5, to: statement)
      try stepDone(statement)
      guard changedRowCountUnlocked == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }
      try storeActivitySummaryUnlocked(recordID: recordID, activity: activity)
  }

  /// Recover only input identities recorded in this exact native session's archive.
  public func builtInRunRecoveryRequests(conversationID: String, sessionID: String) throws -> [DefaultAgentRunRecoveryRequest] {
    try withLock {
      let rows = try historyRowsUnlocked("""
        SELECT r.id AS run_id,json_extract(h.payload,'$.value.requestId') AS request_id
        FROM dashboard_runs r JOIN desktop_local_acp_sessions s ON s.conversation_id=r.conversation_id
        JOIN workspace_history_events h ON h.run_id=r.id AND h.conversation_id=r.conversation_id
        WHERE r.conversation_id=? AND r.desktop_owned=1 AND r.status='uncertain'
          AND s.runtime_kind='default_agent' AND s.acp_session_id=?
          AND h.harness='default_agent' AND h.native_session_id=? AND json_valid(h.payload)
          AND json_extract(h.payload,'$.type')='submission'
          AND json_extract(h.payload,'$.value.type')='input'
          AND json_valid(h.projection_json) AND json_extract(h.projection_json,'$.childID') IS NULL
        ORDER BY h.sequence
        """, values: [conversationID, sessionID, sessionID])
      var inputs: [String: [String]] = [:]
      for row in rows {
        guard let value = row.objectValue, let runID = value["run_id"]?.stringValue,
              let requestID = value["request_id"]?.stringValue,
              let suffix = requestID.range(of: ":attempt:", options: .backwards),
              Int(requestID[suffix.upperBound...]) != nil else { continue }
        let inputID = String(requestID[..<suffix.lowerBound])
        guard UUID(uuidString: inputID) != nil else { continue }
        if !inputs[runID, default: []].contains(inputID) { inputs[runID, default: []].append(inputID) }
      }
      return inputs.keys.sorted().map { .init(runID: $0, inputIDs: inputs[$0] ?? []) }
    }
  }

  /// Called only after the attached owner proved idle and returned exact native receipts.
  public func recoverBuiltInAgentRuns(conversationID: String, sessionID: String, snapshots: [DefaultAgentRunSnapshot]) throws {
    try transaction {
      let route = try localACPSession(conversationID: conversationID)
      guard route.runtimeKind == .defaultAgent, route.acpSessionID == sessionID else {
        throw LocalACPSessionDatabaseError.sessionNotFound
      }
      let allowed = Set(try builtInRunRecoveryRequests(conversationID: conversationID, sessionID: sessionID).map(\.runID))
      let now = Self.timestamp(Date())
      for snapshot in snapshots where allowed.contains(snapshot.runID) {
        let status = snapshot.error == nil ? "completed" : "failed"
        try toolsExecuteUnlocked("""
          UPDATE dashboard_messages SET content=CASE WHEN ?='' THEN content ELSE ? END,status=?,updated_at=?
          WHERE id IN (SELECT assistant_message_id FROM dashboard_runs WHERE id=? AND conversation_id=?
            AND desktop_owned=1 AND status='uncertain')
          """, [snapshot.content, snapshot.content, status, now, snapshot.runID, conversationID])
        try toolsExecuteUnlocked("""
          UPDATE dashboard_runs SET status=?,error=?,completed_at=?,updated_at=?
          WHERE id=? AND conversation_id=? AND desktop_owned=1 AND status='uncertain'
          """, [status, snapshot.error, now, now, snapshot.runID, conversationID])
      }
    }
  }

  /// Reconcile only the exact remote run identities that this Mac submitted.
  /// A disconnected transport may have marked them failed while the workspace kept running.
  public func recoverRemoteAgentRuns(conversationID: String, snapshots: [DefaultAgentRunSnapshot]) throws {
    try transaction {
      try recoverRemoteAgentRunsUnlocked(conversationID: conversationID, snapshots: snapshots)
    }
  }

  /// A fenced service attachment proved this exact native session idle after
  /// retiring every older admission. A plain load or a timeout is not proof.
  func reconcileUncertainRemoteRuns(conversationID: String, remoteWorkspaceID: UUID,
    sessionID: String, snapshots: [DefaultAgentRunSnapshot]) throws {
    try transaction {
      let route = try historyRowsUnlocked("""
        SELECT 1 FROM desktop_local_acp_sessions WHERE conversation_id=?
          AND remote_workspace_id=?
        """, values: [conversationID, remoteWorkspaceID.uuidString.lowercased()])
      guard !route.isEmpty else { throw LocalACPSessionDatabaseError.sessionNotFound }
      try recoverRemoteAgentRunsUnlocked(conversationID: conversationID, snapshots: snapshots,
        confirmedSessionID: sessionID, confirmedWorkspaceID: remoteWorkspaceID.uuidString.lowercased())
      let now = Self.timestamp(Date())
      let detail = "The remote session is idle, but no completed result was retained for this input."
      try toolsExecuteUnlocked("""
        UPDATE dashboard_messages SET status='failed',updated_at=?
        WHERE id IN (SELECT assistant_message_id FROM dashboard_runs WHERE conversation_id=?
          AND desktop_owned=1 AND status='uncertain' AND id IN
            (SELECT run_id FROM desktop_local_acp_durable_runs WHERE native_session_id=? AND remote_workspace_id=?))
        """, [now, conversationID, sessionID, remoteWorkspaceID.uuidString.lowercased()])
      try toolsExecuteUnlocked("""
        UPDATE dashboard_runs SET status='failed',error=?,completed_at=?,updated_at=?
        WHERE conversation_id=? AND desktop_owned=1 AND status='uncertain' AND id IN
          (SELECT run_id FROM desktop_local_acp_durable_runs WHERE native_session_id=? AND remote_workspace_id=?)
        """, [detail, now, now, conversationID, sessionID, remoteWorkspaceID.uuidString.lowercased()])
    }
  }

  private func recoverRemoteAgentRunsUnlocked(conversationID: String,
    snapshots: [DefaultAgentRunSnapshot], confirmedSessionID: String? = nil, confirmedWorkspaceID: String? = nil) throws {
      let route = try prepareUnlocked("SELECT 1 FROM desktop_local_acp_sessions WHERE conversation_id=? AND (runtime_kind='default_agent' OR remote_workspace_id IS NOT NULL)")
      defer { sqlite3_finalize(route) }
      try bind(conversationID, at: 1, to: route)
      guard sqlite3_step(route) == SQLITE_ROW else { throw LocalACPSessionDatabaseError.runtimeUnavailable }
      for snapshot in snapshots {
        let query = try prepareUnlocked("""
          SELECT assistant_message_id FROM dashboard_runs WHERE id=? AND conversation_id=?
            AND desktop_owned=1 AND status!='completed'
            AND (status!='uncertain' OR id IN (SELECT run_id FROM desktop_local_acp_durable_runs
              WHERE native_session_id=? AND remote_workspace_id=?))
          """)
        defer { sqlite3_finalize(query) }
        try bind(snapshot.runID, at: 1, to: query); try bind(conversationID, at: 2, to: query)
        try bindNullable(confirmedSessionID, at: 3, to: query)
        try bindNullable(confirmedWorkspaceID, at: 4, to: query)
        guard sqlite3_step(query) == SQLITE_ROW else { continue }
        let messageID = try text(query, column: 0)
        let status = snapshot.error == nil ? "completed" : "failed"
        let now = Self.timestamp(Date())
        let message = try prepareUnlocked("UPDATE dashboard_messages SET content=?,status=?,updated_at=? WHERE id=? AND conversation_id=? AND desktop_owned=1")
        defer { sqlite3_finalize(message) }
        for (index, value) in [snapshot.content, status, now, messageID, conversationID].enumerated() { try bind(value, at: Int32(index + 1), to: message) }
        try stepDone(message)
        let run = try prepareUnlocked("UPDATE dashboard_runs SET status=?,error=?,completed_at=?,updated_at=? WHERE id=? AND conversation_id=? AND desktop_owned=1")
        defer { sqlite3_finalize(run) }
        try bind(status, at: 1, to: run); try bindNullable(snapshot.error, at: 2, to: run)
        for (index, value) in [now, now, snapshot.runID, conversationID].enumerated() { try bind(value, at: Int32(index + 3), to: run) }
        try stepDone(run)
      }
  }

  public func completeLocalACPRun(
    runID: String,
    error: String? = nil,
    completedAt: Date = Date()
  ) throws {
    try transaction {
      let timestamp = Self.timestamp(completedAt)
      let runStatus = error == nil ? "completed" : "failed"
      let messageStatus = error == nil ? "completed" : "failed"
      let run = try prepareUnlocked("""
        UPDATE dashboard_runs
        SET status = ?, error = ?, completed_at = ?, updated_at = ?
        WHERE id = ? AND desktop_owned = 1 AND status = 'running'
        """)
      defer { sqlite3_finalize(run) }
      try bind(runStatus, at: 1, to: run)
      try bindNullable(error, at: 2, to: run)
      try bind(timestamp, at: 3, to: run)
      try bind(timestamp, at: 4, to: run)
      try bind(runID, at: 5, to: run)
      try stepDone(run)
      guard changedRowCountUnlocked == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let message = try prepareUnlocked("""
        UPDATE dashboard_messages
        SET content = CASE
          WHEN content = '' AND ? IS NOT NULL THEN ?
          ELSE content
        END, status = ?, updated_at = ?
        WHERE id = (
          SELECT assistant_message_id FROM dashboard_runs WHERE id = ?
        ) AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(message) }
      try bindNullable(error, at: 1, to: message)
      try bindNullable(error, at: 2, to: message)
      try bind(messageStatus, at: 3, to: message)
      try bind(timestamp, at: 4, to: message)
      try bind(runID, at: 5, to: message)
      try stepDone(message)


    }
  }

  /// The attachment ended without proving the native outcome. Preserve its
  /// identity and block automatic resubmission while that outcome is unknown.
  func markLocalACPRunUncertain(runID: String, detail: String) throws {
    try transaction { try markLocalACPRunUncertainUnlocked(runID: runID, detail: detail) }
  }

  func registerDurableLocalACPRun(runID: String, remoteWorkspaceID: UUID, sessionID: String) throws {
    try transaction {
      try toolsExecuteUnlocked("""
        INSERT INTO desktop_local_acp_durable_runs(run_id,remote_workspace_id,native_session_id)
        SELECT r.id,?,? FROM dashboard_runs r JOIN desktop_local_acp_sessions s ON s.conversation_id=r.conversation_id
        WHERE r.id=? AND r.status='running' AND s.remote_workspace_id=?
        ON CONFLICT(run_id) DO UPDATE SET remote_workspace_id=excluded.remote_workspace_id,native_session_id=excluded.native_session_id
        """, [remoteWorkspaceID.uuidString.lowercased(), sessionID, runID, remoteWorkspaceID.uuidString.lowercased()])
      guard changedRowCountUnlocked == 1 else { throw LocalACPSessionDatabaseError.runNotFound }
      // A service-owned session is already recoverable before its first prompt;
      // keep this identity even for harnesses whose local CLI defers persistence.
      try toolsExecuteUnlocked("""
        UPDATE desktop_local_acp_sessions SET acp_session_id=?,revision=revision+1,updated_at=?
        WHERE conversation_id=(SELECT conversation_id FROM dashboard_runs WHERE id=?) AND remote_workspace_id=?
        """, [sessionID, Self.timestamp(Date()), runID, remoteWorkspaceID.uuidString.lowercased()])
      try toolsExecuteUnlocked("UPDATE dashboard_runs SET openclaw_session_key=? WHERE id=?", [sessionID, runID])
    }
  }

  private func markLocalACPRunUncertainUnlocked(runID: String, detail: String) throws {
      let now = Self.timestamp(Date())
      try toolsExecuteUnlocked("""
        UPDATE dashboard_runs SET status='uncertain',error=?,completed_at=NULL,updated_at=?
        WHERE id=? AND desktop_owned=1 AND status='running'
          AND (id IN (SELECT run_id FROM desktop_local_acp_durable_runs)
            OR conversation_id IN (SELECT conversation_id FROM desktop_local_acp_sessions
              WHERE runtime_kind='default_agent'))
        """, [detail, now, runID])
      guard changedRowCountUnlocked == 1 else { throw LocalACPSessionDatabaseError.runNotFound }
      try toolsExecuteUnlocked("""
        UPDATE dashboard_messages SET status='uncertain',updated_at=?
        WHERE id=(SELECT assistant_message_id FROM dashboard_runs WHERE id=?) AND desktop_owned=1
        """, [now, runID])
  }

  public func cancelLocalACPRun(
    runID: String,
    completedAt: Date = Date()
  ) throws {
    try transaction {
      let authority = try localRunAuthorityUnlocked(runID: runID)
      let timestamp = Self.timestamp(completedAt)
      let run = try prepareUnlocked("""
        UPDATE dashboard_runs
        SET status = 'cancelled', error = NULL, completed_at = ?, updated_at = ?
        WHERE id = ? AND desktop_owned = 1 AND status = 'running'
        """)
      defer { sqlite3_finalize(run) }
      try bind(timestamp, at: 1, to: run)
      try bind(timestamp, at: 2, to: run)
      try bind(runID, at: 3, to: run)
      try stepDone(run)
      guard changedRowCountUnlocked == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let message = try prepareUnlocked("""
        UPDATE dashboard_messages
        SET content = CASE WHEN content = ''
          THEN 'Stopped before the agent produced a response.' ELSE content END,
          status = 'completed', updated_at = ?
        WHERE id = ? AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(message) }
      try bind(timestamp, at: 1, to: message)
      try bind(authority.assistantMessageID, at: 2, to: message)
      try stepDone(message)

    }
  }

  public func recoverInterruptedLocalACPRuns(
    recoveredAt: Date = Date()
  ) throws {
    try transaction {
      let timestamp = Self.timestamp(recoveredAt)
      // Losing this process ends a local CLI, but only detaches a service-owned
      // native run. Do not manufacture terminal truth for the latter.
      let durable = try historyRowsUnlocked("""
        SELECT r.id FROM dashboard_runs r JOIN desktop_local_acp_durable_runs d ON d.run_id=r.id
        WHERE r.desktop_owned=1 AND r.status='running'
          AND r.conversation_id NOT IN (SELECT conversation_id FROM desktop_openclaw_gateway_sessions)
          AND r.conversation_id NOT IN (SELECT conversation_id FROM desktop_opencode_sessions)
        """, values: [])
      for row in durable {
        guard let id = row.objectValue?["id"]?.stringValue else { continue }
        try markLocalACPRunUncertainUnlocked(runID: id,
          detail: "The connection ended before the remote outcome was confirmed. Reconnect this conversation to recover its result.")
      }
      let message = try prepareUnlocked("""
        UPDATE dashboard_messages
        SET content = CASE
          WHEN content = '' THEN 'The local agent stopped when Woven Matter closed.'
          ELSE content
        END, status = 'failed', updated_at = ?
        WHERE desktop_owned = 1 AND id IN (
          SELECT assistant_message_id
          FROM dashboard_runs
          WHERE desktop_owned = 1 AND status = 'running'
            AND conversation_id NOT IN (SELECT conversation_id FROM desktop_openclaw_gateway_sessions)
          AND conversation_id NOT IN (SELECT conversation_id FROM desktop_opencode_sessions)
        )
        """)
      defer { sqlite3_finalize(message) }
      try bind(timestamp, at: 1, to: message)
      try stepDone(message)

      let run = try prepareUnlocked("""
        UPDATE dashboard_runs
        SET status = 'failed',
          error = 'The local agent stopped when Woven Matter closed.',
          completed_at = ?, updated_at = ?
        WHERE desktop_owned = 1 AND status = 'running'
          AND conversation_id NOT IN (SELECT conversation_id FROM desktop_openclaw_gateway_sessions)
          AND conversation_id NOT IN (SELECT conversation_id FROM desktop_opencode_sessions)
        """)
      defer { sqlite3_finalize(run) }
      try bind(timestamp, at: 1, to: run)
      try bind(timestamp, at: 2, to: run)
      try stepDone(run)
    }
  }

  private func localAssistantPreviewUnlocked(runID: String) throws -> String {
    let statement = try prepareUnlocked("""
      SELECT content FROM dashboard_messages
      WHERE id = (
        SELECT assistant_message_id FROM dashboard_runs WHERE id = ?
      ) AND run_id = ? AND role = 'assistant'
      """)
    defer { sqlite3_finalize(statement) }
    try bind(runID, at: 1, to: statement)
    try bind(runID, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw LocalACPSessionDatabaseError.runNotFound
    }
    return Self.localPreview(RemoteNoteEditEnvelope.redactingEnvelopes(
      in: try text(statement, column: 0)
    ))
  }

  static func localPreview(_ content: String) -> String {
    let compact = content
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(compact.prefix(240))
  }
}

// MARK: - Async worker boundary

extension WorkspaceDatabase {
  @discardableResult
  public func createLocalACPSession(
    runtimeKind: AgentRuntimeKind,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date(),
    openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
    importedOpenCodeSnapshot: OpenCodeSessionSnapshot? = nil,
    requestedConversationID: UUID? = nil,
    allowMissingCalendarFolder: Bool = false,
    executionRoot: SessionCreationRoot
  ) async throws -> String {
    try await write { try $0.createLocalACPSession(runtimeKind: runtimeKind, title: title, ownerDeviceID: ownerDeviceID, createdAt: createdAt, openCodeAssociation: openCodeAssociation, importedOpenCodeSnapshot: importedOpenCodeSnapshot, requestedConversationID: requestedConversationID, allowMissingCalendarFolder: allowMissingCalendarFolder, executionRoot: executionRoot) }
  }

  @discardableResult
  public func createRemoteACPSession(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date(),
    openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
    requestedConversationID: UUID? = nil,
    allowMissingCalendarFolder: Bool = false,
    executionRoot: SessionCreationRoot
  ) async throws -> String {
    try await write { try $0.createRemoteACPSession(runtimeKind: runtimeKind, remoteWorkspaceID: remoteWorkspaceID, remoteWorkspaceName: remoteWorkspaceName, title: title, ownerDeviceID: ownerDeviceID, createdAt: createdAt, openCodeAssociation: openCodeAssociation, requestedConversationID: requestedConversationID, allowMissingCalendarFolder: allowMissingCalendarFolder, executionRoot: executionRoot) }
  }

  @discardableResult
  public func localACPSession(
    conversationID: String
  ) async throws -> LocalACPSessionDescriptor {
    try await read { try $0.localACPSession(conversationID: conversationID) }
  }

  public func updateLocalACPSessionID(
    conversationID: String,
    runID: String? = nil,
    sessionID: String,
    updatedAt: Date = Date()
  ) async throws {
    try await write { try $0.updateLocalACPSessionID(conversationID: conversationID, runID: runID, sessionID: sessionID, updatedAt: updatedAt) }
  }

  public func updateLocalACPSessionConfiguration(
    conversationID: String,
    model: String?,
    thinking: String?,
    permission: String? = nil,
    updatedAt: Date = Date()
  ) async throws {
    try await write { try $0.updateLocalACPSessionConfiguration(conversationID: conversationID, model: model, thinking: thinking, permission: permission, updatedAt: updatedAt) }
  }

  public func beginLocalACPRun(
    conversationID: String,
    content: String,
    noteContext: AgentNoteContext? = nil,
    createdAt: Date = Date()
  ) async throws -> LocalACPRunIdentifiers {
    try await write { try $0.beginLocalACPRun(conversationID: conversationID, content: content, noteContext: noteContext, createdAt: createdAt) }
  }

  public func beginLocalACPRun(
    conversationID: String,
    input: AgentMessageInput,
    noteContext: AgentNoteContext? = nil,
    createdAt: Date = Date()
  ) async throws -> LocalACPRunIdentifiers {
    try await write { try $0.beginLocalACPRun(conversationID: conversationID, input: input, noteContext: noteContext, createdAt: createdAt) }
  }

  public func activeDeviceOwnedConversationIDs() async throws -> Set<String> {
    try await read { try $0.activeDeviceOwnedConversationIDs() }
  }

  public func beginLocalACPSteeringTurn(
    runID: String,
    content: String,
    createdAt: Date = Date()
  ) async throws -> LocalACPSteeringIdentifiers {
    try await write { try $0.beginLocalACPSteeringTurn(runID: runID, content: content, createdAt: createdAt) }
  }

  public func beginLocalACPSteeringTurn(
    runID: String,
    input: AgentMessageInput,
    completesPreviousAssistant: Bool = true,
    createdAt: Date = Date()
  ) async throws -> LocalACPSteeringIdentifiers {
    try await write { try $0.beginLocalACPSteeringTurn(runID: runID, input: input, completesPreviousAssistant: completesPreviousAssistant, createdAt: createdAt) }
  }

  public func appendLocalACPAssistantChunk(
    runID: String,
    chunk: String,
    updatedAt: Date = Date()
  ) async throws {
    try await write { try $0.appendLocalACPAssistantChunk(runID: runID, chunk: chunk, updatedAt: updatedAt) }
  }

  public func replaceLocalACPAssistantMessage(
    runID: String,
    content: String,
    updatedAt: Date = Date()
  ) async throws {
    try await write { try $0.replaceLocalACPAssistantMessage(runID: runID, content: content, updatedAt: updatedAt) }
  }

  public func completeLocalACPAssistantMessage(
    runID: String,
    assistantMessageID: String,
    error: String? = nil,
    completedAt: Date = Date()
  ) async throws {
    try await finishWrite { try $0.completeLocalACPAssistantMessage(runID: runID, assistantMessageID: assistantMessageID, error: error, completedAt: completedAt) }
  }

  public func recordAssistantStreamBoundary(
    runID: String,
    assistantMessageID requestedMessageID: String? = nil,
    finalSegment: Bool = false,
    updatedAt: Date = Date()
  ) async throws {
    try await write { try $0.recordAssistantStreamBoundary(runID: runID, assistantMessageID: requestedMessageID, finalSegment: finalSegment, updatedAt: updatedAt) }
  }

  public func upsertDeviceOwnedRunActivity(
    runID: String,
    activity update: AgentRunActivity,
    appendingContent: Bool = false,
    updatedAt: Date = Date()
  ) async throws {
    try await write { try $0.upsertDeviceOwnedRunActivity(runID: runID, activity: update, appendingContent: appendingContent, updatedAt: updatedAt) }
  }

  public func builtInRunRecoveryRequests(conversationID: String, sessionID: String) async throws -> [DefaultAgentRunRecoveryRequest] {
    try await read { try $0.builtInRunRecoveryRequests(conversationID: conversationID, sessionID: sessionID) }
  }

  public func recoverBuiltInAgentRuns(conversationID: String, sessionID: String, snapshots: [DefaultAgentRunSnapshot]) async throws {
    try await finishWrite { try $0.recoverBuiltInAgentRuns(conversationID: conversationID, sessionID: sessionID, snapshots: snapshots) }
  }

  public func recoverRemoteAgentRuns(conversationID: String, snapshots: [DefaultAgentRunSnapshot]) async throws {
    try await write { try $0.recoverRemoteAgentRuns(conversationID: conversationID, snapshots: snapshots) }
  }

  public func completeLocalACPRun(
    runID: String,
    error: String? = nil,
    completedAt: Date = Date()
  ) async throws {
    try await finishWrite { try $0.completeLocalACPRun(runID: runID, error: error, completedAt: completedAt) }
  }

  public func cancelLocalACPRun(
    runID: String,
    completedAt: Date = Date()
  ) async throws {
    try await finishWrite { try $0.cancelLocalACPRun(runID: runID, completedAt: completedAt) }
  }

  public func recoverInterruptedLocalACPRuns(
    recoveredAt: Date = Date()
  ) async throws {
    try await write { try $0.recoverInterruptedLocalACPRuns(recoveredAt: recoveredAt) }
  }
}
