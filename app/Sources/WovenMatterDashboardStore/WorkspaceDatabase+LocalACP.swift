import CryptoKit
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
  public let buzzWorkspaceLinkID: UUID?
  public let buzzAgentID: String?
  public let remoteWorkspaceID: UUID?

  public init(
    conversationID: String,
    runtimeKind: AgentRuntimeKind,
    title: String,
    acpSessionID: String?,
    model: String? = nil,
    thinking: String? = nil,
    buzzWorkspaceLinkID: UUID? = nil,
    buzzAgentID: String? = nil,
    remoteWorkspaceID: UUID? = nil
  ) {
    self.conversationID = conversationID
    self.runtimeKind = runtimeKind
    self.title = title
    self.acpSessionID = acpSessionID
    self.model = model
    self.thinking = thinking
    self.buzzWorkspaceLinkID = buzzWorkspaceLinkID
    self.buzzAgentID = buzzAgentID
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
extension WorkspaceDatabase {
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
    hermesImport: HermesSessionImport? = nil
  ) throws -> String {
    try transaction { try createLocalACPSessionUnlocked(runtimeKind: runtimeKind, title: title, ownerDeviceID: ownerDeviceID, createdAt: createdAt, openCodeAssociation: openCodeAssociation, importedOpenCodeSnapshot: importedOpenCodeSnapshot, hermesImport: hermesImport) }
  }

  @discardableResult
  func createLocalACPSessionUnlocked(
    runtimeKind: AgentRuntimeKind,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date(),
    openCodeAssociation: (connectionID: String, sessionID: String)? = nil,
    importedOpenCodeSnapshot: OpenCodeSessionSnapshot? = nil,
    hermesImport: HermesSessionImport? = nil
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
    if hermesImport != nil && runtimeKind != .hermes { throw LocalACPSessionDatabaseError.runtimeUnavailable }

      if let imported = hermesImport {
        let requested = HermesGatewayClient.parseIdentity(imported.identity)
        guard requested.home != nil, !requested.storedID.isEmpty else { throw WorkspaceDatabaseError.corruptRow }
        let existing = try prepareUnlocked("SELECT conversation_id, acp_session_id FROM desktop_local_acp_sessions WHERE runtime_kind='hermes' AND acp_session_id IS NOT NULL")
        defer { sqlite3_finalize(existing) }
        while sqlite3_step(existing) == SQLITE_ROW {
          let linked = HermesGatewayClient.parseIdentity(try text(existing, column: 1))
          if linked.storedID == requested.storedID && (linked.home == nil || linked.home == requested.home) {
            return try text(existing, column: 0)
          }
        }
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
      let conversationID = UUID().uuidString.lowercased()
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
      if let link = openCodeAssociation {
        let association = try prepareUnlocked("INSERT INTO desktop_opencode_sessions(conversation_id, connection_id, session_id, snapshot_json) VALUES (?, ?, ?, '{}')")
        defer { sqlite3_finalize(association) }
        try bind(conversationID, at: 1, to: association); try bind(link.connectionID, at: 2, to: association)
        try bind(link.sessionID, at: 3, to: association); try stepDone(association)
      }
      if let snapshot = importedOpenCodeSnapshot {
        try markSessionImportedUnlocked(conversationID: conversationID)
        try saveOpenCodeSnapshotUnlocked(snapshot, conversationID: conversationID, fallbackTitle: sessionTitle)
      }
      if let imported = hermesImport {
        try markSessionImportedUnlocked(conversationID: conversationID)
        let touch = try prepareUnlocked("UPDATE dashboard_conversations SET last_message_at = MAX(last_message_at, (SELECT imported_at FROM desktop_session_imports WHERE conversation_id = ?)), updated_at = ? WHERE id = ?")
        defer { sqlite3_finalize(touch) }
        try bind(conversationID, at: 1, to: touch); try bind(Self.timestamp(Date()), at: 2, to: touch)
        try bind(conversationID, at: 3, to: touch); try stepDone(touch)
        let association = try prepareUnlocked("UPDATE desktop_local_acp_sessions SET acp_session_id=? WHERE conversation_id=?")
        defer { sqlite3_finalize(association) }
        try bind(imported.identity, at: 1, to: association); try bind(conversationID, at: 2, to: association); try stepDone(association)
        let message = try prepareUnlocked("""
          INSERT INTO dashboard_messages (id, conversation_id, role, message_source, content, status,
            governing_plane, authority_kind, authority_device_id, authority_agent_id, created_at, updated_at, desktop_owned)
          VALUES (?, ?, ?, 'hermes_history', ?, 'completed', 'wovenmatter_macos', 'device_owned', ?, ?, ?, ?, 1)
          """)
        defer { sqlite3_finalize(message) }
        var seen: Set<Double> = []
        var previousDate = createdAt.addingTimeInterval(-0.001)
        var toolOwners: [String: String] = [:]
        var lastAssistantID: String?
        for row in imported.messages {
          guard let rowID = row["id"].number, rowID >= 1, rowID <= 9_007_199_254_740_991, rowID.rounded() == rowID, seen.insert(rowID).inserted,
                ["user", "assistant", "system", "tool"].contains(row["role"].text) else { throw WorkspaceDatabaseError.corruptRow }
          let date = max(Date(timeIntervalSince1970: row["timestamp"].number ?? createdAt.timeIntervalSince1970), previousDate.addingTimeInterval(0.001))
          previousDate = date
          let rowTime = Self.timestamp(date)
          let nativeMessageID = "hermes-" + conversationID + "-" + String(Int64(rowID))
          let role = row["role"].text
          let toolResult = role == "tool"
          let toolID = row["tool_call_id"].string ?? row["tool_id"].string
          let ownerID = toolResult ? (toolID.flatMap { toolOwners[$0] } ?? lastAssistantID ?? nativeMessageID) : nativeMessageID
          let body = toolResult ? "" : row["content"].string ?? (row["content"].isNull ? "" : row["content"].json)
          if !toolResult || ownerID == nativeMessageID {
            sqlite3_reset(message); sqlite3_clear_bindings(message)
            try bind(ownerID, at: 1, to: message)
            try bind(conversationID, at: 2, to: message); try bind(toolResult ? "assistant" : role, at: 3, to: message)
            try bind(body, at: 4, to: message); try bind(ownerDeviceID.uuidString.lowercased(), at: 5, to: message)
            try bind(agentID, at: 6, to: message); try bind(rowTime, at: 7, to: message); try bind(rowTime, at: 8, to: message)
            try stepDone(message)
          }
          if role == "assistant" { lastAssistantID = ownerID }
          var activities: [AgentRunActivity] = []
          if let reasoning = row["reasoning"].string ?? row["reasoning_content"].string, !reasoning.isEmpty {
            activities.append(AgentRunActivity(id: nativeMessageID + ":reasoning", kind: .thought, content: reasoning))
          }
          if case .array(let calls) = row["tool_calls"] {
            for (index, call) in calls.enumerated() {
              let callID = call["id"].string ?? "\(nativeMessageID):tool:\(index)"
              toolOwners[callID] = ownerID
              let function = call["function"].isNull ? call : call["function"]
              activities.append(AgentRunActivity(id: callID, kind: .tool, phase: "start",
                title: function["name"].string, status: "unknown", toolName: function["name"].string,
                rawInputJSON: function["arguments"].isNull ? nil : function["arguments"].json, rawPayloadJSON: call.json))
            }
          }
          if toolResult {
            activities.append(AgentRunActivity(id: toolID ?? nativeMessageID, kind: .tool, phase: "result",
              title: row["name"].string, status: row["is_error"].bool ? "failed" : "completed", toolName: row["name"].string,
              content: row["content"].string, rawOutputJSON: row["content"].json, rawPayloadJSON: row.json))
          }
          if !activities.isEmpty {
            let runID = ownerID + ":run"
            let run = try prepareUnlocked("""
              INSERT INTO dashboard_runs(id, conversation_id, user_id, agent_id, agent_codename,
                governing_plane, authority_kind, authority_device_id, authority_agent_id,
                assistant_message_id, status, started_at, completed_at, created_at, updated_at, desktop_owned)
              SELECT ?, c.id, c.user_id, c.agent_id, c.agent_codename, c.governing_plane, c.authority_kind,
                c.authority_device_id, c.authority_agent_id, ?, 'running', ?, ?, ?, ?, 1
              FROM dashboard_conversations c WHERE c.id = ?
              ON CONFLICT(id) DO UPDATE SET status = 'running', completed_at = excluded.completed_at
              """)
            defer { sqlite3_finalize(run) }
            for (index, value) in [runID, ownerID, rowTime, rowTime, rowTime, rowTime, conversationID].enumerated() {
              try bind(value, at: Int32(index + 1), to: run)
            }
            try stepDone(run)
            for activity in activities {
              try upsertDeviceOwnedRunActivityUnlocked(runID: runID, activity: activity, appendingContent: false, updatedAt: date)
            }
            let finish = try prepareUnlocked("UPDATE dashboard_runs SET status = 'completed' WHERE id = ?")
            defer { sqlite3_finalize(finish) }
            try bind(runID, at: 1, to: finish); try stepDone(finish)
            let link = try prepareUnlocked("UPDATE dashboard_messages SET run_id = ? WHERE id = ?")
            defer { sqlite3_finalize(link) }
            try bind(runID, at: 1, to: link); try bind(ownerID, at: 2, to: link); try stepDone(link)
          }
        }
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
    openCodeAssociation: (connectionID: String, sessionID: String)? = nil
  ) throws -> String {
    try transaction { try createRemoteACPSessionUnlocked(runtimeKind: runtimeKind, remoteWorkspaceID: remoteWorkspaceID, remoteWorkspaceName: remoteWorkspaceName, title: title, ownerDeviceID: ownerDeviceID, createdAt: createdAt, openCodeAssociation: openCodeAssociation) }
  }

  @discardableResult
  func createRemoteACPSessionUnlocked(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date(),
    openCodeAssociation: (connectionID: String, sessionID: String)? = nil
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
      let conversationID = UUID().uuidString.lowercased()
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
          session.thinking, session.buzz_workspace_link_id,
          session.buzz_agent_id, session.remote_workspace_id
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
        buzzWorkspaceLinkID: optionalText(statement, column: 6)
          .flatMap(UUID.init(uuidString:)),
        buzzAgentID: optionalText(statement, column: 7),
        remoteWorkspaceID: optionalText(statement, column: 8)
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
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      let statement = try prepareUnlocked("""
        UPDATE desktop_local_acp_sessions
        SET model = ?, thinking = ?, revision = revision + 1, updated_at = ?
        WHERE conversation_id = ?
        """)
      defer { sqlite3_finalize(statement) }
      try bindNullable(model, at: 1, to: statement)
      try bindNullable(thinking, at: 2, to: statement)
      try bind(Self.timestamp(updatedAt), at: 3, to: statement)
      try bind(conversationID, at: 4, to: statement)
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
      let active = try prepareUnlocked("""
        SELECT 1 FROM dashboard_runs
        WHERE conversation_id = ? AND desktop_owned = 1 AND status = 'running'
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
          AND conversation.deleted_at IS NULL
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

      try recordOpenClawInputUnlocked(conversationID: conversationID, localRunID: identifiers.runID,
        remoteRunID: identifiers.runID, userMessageID: identifiers.userMessageID, assistantMessageID: identifiers.assistantMessageID)
      return identifiers
    }
  }

  private func insertMessageAttachmentsUnlocked(
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
        try bind(reference.contentSnapshot, at: 11, to: statement)
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
          AND status = 'running'
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

      try recordOpenClawInputUnlocked(conversationID: authority.conversationID, localRunID: runID,
        remoteRunID: identifiers.userMessageID, userMessageID: identifiers.userMessageID, assistantMessageID: identifiers.assistantMessageID)
      return identifiers
    }
  }

  public enum DeviceOwnedAssistantMutation: Sendable {
    case append(String)
    case replace(String)
  }

  public enum DeviceOwnedGatewayProjectionResult: Equatable, Sendable {
    case applied
    case duplicate
    case legacyUncertain
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

  public func appendLocalACPAssistantChunk(
    runID: String,
    assistantMessageID: String,
    chunk: String,
    updatedAt: Date = Date()
  ) throws {
    guard !chunk.isEmpty else { return }
    try transaction {
      try mutateLocalACPAssistantMessageUnlocked(runID: runID,
        assistantMessageID: assistantMessageID, mutation: .append(chunk), updatedAt: updatedAt)
    }
  }

  public func replaceLocalACPAssistantMessage(
    runID: String,
    assistantMessageID: String,
    content: String,
    preservingStreamCommentary: Bool = false,
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      var content = content
      if preservingStreamCommentary {
        content = try assistantContentReplacingFinalSegmentUnlocked(runID: runID,
          assistantMessageID: assistantMessageID, content: content)
      }
      try mutateLocalACPAssistantMessageUnlocked(runID: runID,
        assistantMessageID: assistantMessageID, mutation: .replace(content), updatedAt: updatedAt)
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

  /// Persists the lossless Gateway frame alongside the normalized activity.
  /// Raw frames are intentionally not visible transcript rows; they remain
  /// available for durable inspection after app relaunch.
  public func appendDeviceOwnedGatewayTraceEvent(
    runID: String,
    remoteRunID: String? = nil,
    eventName: String,
    eventStream: String? = nil,
    sequence: Int,
    eventType: String,
    eventPhase: String?,
    toolName: String?,
    content: String?,
    rawEventJSON: String,
    createdAt: Date = Date()
  ) throws {
    try transaction {
      _ = try claimDeviceOwnedGatewayTraceEventUnlocked(runID: runID,
        remoteRunID: remoteRunID, eventName: eventName, eventStream: eventStream,
        sequence: sequence, eventType: eventType,
        eventPhase: eventPhase, toolName: toolName, content: content,
        rawEventJSON: rawEventJSON, createdAt: createdAt)
    }
  }

  @discardableResult
  public func applyDeviceOwnedGatewayProjection(
    runID: String, remoteRunID: String, eventName: String, eventStream: String? = nil,
    sequence: Int, eventType: String,
    eventPhase: String?, toolName: String?, content: String?, rawEventJSON: String,
    assistantMessageID: String?, assistantMutation: DeviceOwnedAssistantMutation?,
    streamBoundary: Bool = false, finalAssistantSegment: Bool = false,
    activity: AgentRunActivity?, appendingActivity: Bool = false,
    createdAt: Date = Date()
  ) throws -> DeviceOwnedGatewayProjectionResult {
    try transaction {
      let claim = try claimDeviceOwnedGatewayTraceEventUnlocked(runID: runID,
        remoteRunID: remoteRunID, eventName: eventName, eventStream: eventStream,
        sequence: sequence, eventType: eventType,
        eventPhase: eventPhase, toolName: toolName, content: content,
        rawEventJSON: rawEventJSON, createdAt: createdAt)
      guard claim == .applied else { return claim }
      if let assistantMutation {
        guard let assistantMessageID else { throw LocalACPSessionDatabaseError.runNotFound }
        try mutateLocalACPAssistantMessageUnlocked(runID: runID,
          assistantMessageID: assistantMessageID, mutation: assistantMutation,
          updatedAt: createdAt)
      }
      if streamBoundary || finalAssistantSegment {
        guard let assistantMessageID else { throw LocalACPSessionDatabaseError.runNotFound }
        try recordAssistantStreamBoundaryUnlocked(runID: runID,
          assistantMessageID: assistantMessageID,
          finalSegment: finalAssistantSegment, updatedAt: createdAt)
      }
      if let activity {
        try upsertDeviceOwnedRunActivityUnlocked(runID: runID, activity: activity,
          appendingContent: appendingActivity, updatedAt: createdAt)
      }
      let applied = try prepareUnlocked("UPDATE dashboard_run_trace_events SET projection_applied = 1 WHERE id = ?")
      defer { sqlite3_finalize(applied) }
      try bind(gatewayTraceRecordID(runID: runID, remoteRunID: remoteRunID,
        eventName: eventName, eventStream: eventStream, sequence: sequence), at: 1, to: applied)
      try stepDone(applied)
      guard changedRowCountUnlocked == 1 else { throw LocalACPSessionDatabaseError.runNotFound }
      return .applied
    }
  }

  public func deviceOwnedGatewayTraceEvents(
    runID: String
  ) throws -> [(sequence: Int, rawEventJSON: String)] {
    try withLock {
      let statement = try prepareUnlocked("""
        SELECT seq, raw_event_json FROM dashboard_run_trace_events
        WHERE run_id = ? AND event_source = 'openclaw_gateway' AND projection_applied = 1
        ORDER BY created_at, rowid
        """)
      defer { sqlite3_finalize(statement) }
      try bind(runID, at: 1, to: statement)
      var result: [(Int, String)] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return result }
        guard code == SQLITE_ROW else { throw stepError() }
        result.append((Int(sqlite3_column_int64(statement, 0)), try text(statement, column: 1)))
      }
    }
  }

  private func claimDeviceOwnedGatewayTraceEventUnlocked(
    runID: String, remoteRunID: String?, eventName: String, eventStream: String?,
    sequence: Int, eventType: String,
    eventPhase: String?, toolName: String?, content: String?, rawEventJSON: String,
    createdAt: Date
  ) throws -> DeviceOwnedGatewayProjectionResult {
    let recordID = gatewayTraceRecordID(runID: runID, remoteRunID: remoteRunID,
      eventName: eventName, eventStream: eventStream, sequence: sequence)
    let legacyID = "\(runID):gateway:\(eventName):\(sequence)"
    if recordID != legacyID {
      let legacy = try prepareUnlocked("SELECT projection_applied FROM dashboard_run_trace_events WHERE id = ?")
      defer { sqlite3_finalize(legacy) }
      try bind(legacyID, at: 1, to: legacy)
      if sqlite3_step(legacy) == SQLITE_ROW {
        // The former identity omitted remote input and stream, so even a row
        // marked applied cannot prove which scoped event it represented.
        return .legacyUncertain
      }
    }
    let statement = try prepareUnlocked("""
      INSERT OR IGNORE INTO dashboard_run_trace_events (
        id, run_id, conversation_id, user_id, governing_plane,
        authority_kind, authority_device_id, authority_agent_id,
        desktop_owned, agent_codename, openclaw_session_key, seq,
        event_source, event_type, event_name, event_phase, tool_name,
        content, is_visible, raw_event_json, stream_event_json, created_at
      ) SELECT ?, run.id, run.conversation_id, run.user_id,
          run.governing_plane, run.authority_kind, run.authority_device_id,
          run.authority_agent_id, 1, run.agent_codename,
          run.openclaw_session_key, ?, 'openclaw_gateway', ?, ?, ?, ?, ?,
          0, ?, '[]', ?
        FROM dashboard_runs AS run
        WHERE run.id = ? AND run.desktop_owned = 1
    """)
    defer { sqlite3_finalize(statement) }
    try bind(recordID, at: 1, to: statement)
    guard sqlite3_bind_int64(statement, 2, Int64(sequence)) == SQLITE_OK else {
      throw bindError()
    }
    try bind(eventType, at: 3, to: statement)
    try bind(eventName, at: 4, to: statement)
    try bindNullable(eventPhase, at: 5, to: statement)
    try bindNullable(toolName, at: 6, to: statement)
    try bindNullable(content, at: 7, to: statement)
    try bind(rawEventJSON, at: 8, to: statement)
    try bind(Self.timestamp(createdAt), at: 9, to: statement)
    try bind(runID, at: 10, to: statement)
    try stepDone(statement)
    if changedRowCountUnlocked == 1 { return .applied }
    let existing = try prepareUnlocked("SELECT projection_applied FROM dashboard_run_trace_events WHERE id = ?")
    defer { sqlite3_finalize(existing) }
    try bind(recordID, at: 1, to: existing)
    guard sqlite3_step(existing) == SQLITE_ROW else {
      throw LocalACPSessionDatabaseError.runNotFound
    }
    return sqlite3_column_int64(existing, 0) == 1 ? .duplicate : .legacyUncertain
  }

  private func gatewayTraceRecordID(
    runID: String, remoteRunID: String?, eventName: String,
    eventStream: String?, sequence: Int
  ) -> String {
    guard remoteRunID != nil || eventStream != nil else {
      return "\(runID):gateway:\(eventName):\(sequence)"
    }
    let components = [runID, remoteRunID ?? runID, eventName, eventStream ?? "", String(sequence)]
    let identity = components.map { "\($0.utf8.count):\($0)" }.joined()
    let digest = SHA256.hash(data: Data(identity.utf8))
      .map { String(format: "%02x", $0) }.joined()
    return "gateway:" + digest
  }

  func assistantContentReplacingFinalSegmentUnlocked(
    runID: String, assistantMessageID: String, content: String
  ) throws -> String {
    let current = try prepareUnlocked("SELECT content FROM dashboard_messages WHERE id = ? AND run_id = ? AND role = 'assistant'")
    defer { sqlite3_finalize(current) }
    try bind(assistantMessageID, at: 1, to: current)
    try bind(runID, at: 2, to: current)
    guard sqlite3_step(current) == SQLITE_ROW else { throw LocalACPSessionDatabaseError.runNotFound }
    let text = try text(current, column: 0)
    let segments = try runActivityRecordsUnlocked(runIDs: [runID], assistantOnly: true).map(\.activity)
    guard let last = segments.last(where: {
      $0.assistantMessageID == assistantMessageID
        && $0.assistantCheckpoint?.followingText(in: text) != nil
    }), let checkpoint = last.assistantCheckpoint else { return content }
    let prefixBytes = checkpoint.byteCount - (last.phase == "final" ? (last.content ?? "").utf8.count : 0)
    guard prefixBytes >= 0 else { return content }
    return String(decoding: text.utf8.prefix(prefixBytes), as: UTF8.self) + content
  }

  private func mutateLocalACPAssistantMessageUnlocked(
    runID: String, assistantMessageID: String,
    mutation: DeviceOwnedAssistantMutation, updatedAt: Date
  ) throws {
    let authority = try localRunAuthorityUnlocked(runID: runID)
    let timestamp = Self.timestamp(updatedAt)
    let message = try prepareUnlocked("""
      UPDATE dashboard_messages
      SET content = CASE WHEN ? THEN content || ? ELSE ? END,
          status = 'streaming', updated_at = ?
      WHERE id = ? AND run_id = ? AND role = 'assistant'
        AND desktop_owned = 1
        AND EXISTS (SELECT 1 FROM dashboard_runs
          WHERE id = ? AND desktop_owned = 1 AND status = 'running')
      """)
    defer { sqlite3_finalize(message) }
    let append: Bool
    let value: String
    switch mutation {
    case .append(let text): append = true; value = text
    case .replace(let text): append = false; value = text
    }
    guard sqlite3_bind_int64(message, 1, append ? 1 : 0) == SQLITE_OK else {
      throw bindError()
    }
    try bind(value, at: 2, to: message)
    try bind(value, at: 3, to: message)
    try bind(timestamp, at: 4, to: message)
    try bind(assistantMessageID, at: 5, to: message)
    try bind(runID, at: 6, to: message)
    try bind(runID, at: 7, to: message)
    try stepDone(message)
    guard changedRowCountUnlocked == 1 else { throw LocalACPSessionDatabaseError.runNotFound }
    let conversation = try prepareUnlocked("""
      UPDATE dashboard_conversations
      SET last_message_preview = ?, last_message_at = MAX(?, COALESCE(
        (SELECT imported_at FROM desktop_session_imports WHERE conversation_id=dashboard_conversations.id), '')),
        updated_at = ?
      WHERE id = ? AND desktop_owned = 1
        AND ? = (SELECT assistant_message_id FROM dashboard_runs WHERE id = ?)
      """)
    defer { sqlite3_finalize(conversation) }
    try bind(try localAssistantPreviewUnlocked(runID: runID,
      assistantMessageID: assistantMessageID), at: 1, to: conversation)
    try bind(timestamp, at: 2, to: conversation)
    try bind(timestamp, at: 3, to: conversation)
    try bind(authority.conversationID, at: 4, to: conversation)
    try bind(assistantMessageID, at: 5, to: conversation)
    try bind(runID, at: 6, to: conversation)
    try stepDone(conversation)
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

  private func localAssistantPreviewUnlocked(
    runID: String,
    assistantMessageID: String? = nil
  ) throws -> String {
    let statement = try prepareUnlocked("""
      SELECT content FROM dashboard_messages
      WHERE id = COALESCE(?, (
        SELECT assistant_message_id FROM dashboard_runs WHERE id = ?
      )) AND run_id = ? AND role = 'assistant'
      """)
    defer { sqlite3_finalize(statement) }
    try bindNullable(assistantMessageID, at: 1, to: statement)
    try bind(runID, at: 2, to: statement)
    try bind(runID, at: 3, to: statement)
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
