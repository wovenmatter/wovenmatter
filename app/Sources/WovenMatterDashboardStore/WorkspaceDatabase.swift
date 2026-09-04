import CoreFoundation
import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

public enum WorkspaceDatabaseError: Error, Equatable {
  case open(String)
  case execute(String)
  case prepare(String)
  case bind(String)
  case step(String)
  case corruptRow
}

public enum BuzzWorkspaceDatabaseError: LocalizedError, Equatable, Sendable {
  case workspaceNotFound
  case enrollmentNotFound
  case localACPRequired
  case enrollmentRequiresRefresh

  public var errorDescription: String? {
    switch self {
    case .workspaceNotFound:
      "The linked Buzz workspace is no longer available."
    case .enrollmentNotFound:
      "The linked Buzz agent is no longer enrolled."
    case .localACPRequired:
      "This Buzz agent is not available through a local ACP workspace."
    case .enrollmentRequiresRefresh:
      "This Buzz agent’s runtime changed. Remove and re-enroll it to use the current definition."
    }
  }
}

public enum WorkspaceNoteMutationError: LocalizedError, Equatable, Sendable {
  case folderNotFound
  case noteNotFound
  case revisionConflict

  public var errorDescription: String? {
    switch self {
    case .folderNotFound:
      "The selected folder is no longer available."
    case .noteNotFound:
      "The note is no longer available."
    case .revisionConflict:
      "The note changed since it was read. Read it again before applying edits."
    }
  }
}

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

public enum WorkspaceCalendarMutationError: LocalizedError, Equatable, Sendable {
  case emptyTitle
  case invalidDateRange

  public var errorDescription: String? {
    switch self {
    case .emptyTitle:
      "Enter a title for the event."
    case .invalidDateRange:
      "The event must end after it starts."
    }
  }
}

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

public struct BuzzLocalAgentLaunchSource: Equatable, Sendable {
  public let link: BuzzWorkspaceLink
  public let enrollment: BuzzWorkspaceAgentEnrollment

  public init(
    link: BuzzWorkspaceLink,
    enrollment: BuzzWorkspaceAgentEnrollment
  ) {
    self.link = link
    self.enrollment = enrollment
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

public struct PendingRemoteNoteEdit: Equatable, Sendable {
  public let runID: String
  public let assistantMessageID: String
  public let noteID: String
  public let expectedRevision: String
  public let nonce: String
  public let noteKind: NoteArtifactKind
  public let assistantContent: String
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

public final class WorkspaceDatabase: @unchecked Sendable {
  private let lock = NSLock()
  private var connection: OpaquePointer?

  public init(url: URL) throws {
    var database: OpaquePointer?
    let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
    guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK, let database else {
      let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to allocate SQLite connection"
      if let database { sqlite3_close(database) }
      throw WorkspaceDatabaseError.open(message)
    }
    connection = database

    do {
      try execute("PRAGMA journal_mode = WAL")
      try execute("PRAGMA foreign_keys = ON")
      try execute("PRAGMA busy_timeout = 5000")
      try migrate()
    } catch {
      sqlite3_close(database)
      connection = nil
      throw error
    }
  }

  deinit {
    if let connection { sqlite3_close(connection) }
  }

  private func transaction<T>(_ operation: () throws -> T) throws -> T {
    try lock.withLock {
      try executeUnlocked("BEGIN IMMEDIATE")
      do {
        let result = try operation()
        try executeUnlocked("COMMIT")
        return result
      } catch {
        try? executeUnlocked("ROLLBACK")
        throw error
      }
    }
  }

  // MARK: - Buzz workspace links

  public func upsertBuzzWorkspaceLink(_ link: BuzzWorkspaceLink) throws {
    try lock.withLock {
      try upsertBuzzWorkspaceLinkUnlocked(link)
    }
  }

  private func upsertBuzzWorkspaceLinkUnlocked(
    _ link: BuzzWorkspaceLink
  ) throws {
    let statement = try prepareUnlocked("""
      INSERT INTO desktop_buzz_workspace_links (
        id, display_name, local_workspace_url, local_agent_store_url, is_enabled,
        created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        display_name = excluded.display_name,
        local_workspace_url = excluded.local_workspace_url,
        local_agent_store_url = excluded.local_agent_store_url,
        is_enabled = excluded.is_enabled,
        updated_at = excluded.updated_at
    """)
    defer { sqlite3_finalize(statement) }
    try bind(link.id.uuidString.lowercased(), at: 1, to: statement)
    try bind(link.displayName, at: 2, to: statement)
    try bind(link.localWorkspaceURL.absoluteString, at: 3, to: statement)
    try bind(link.localAgentStoreURL.absoluteString, at: 4, to: statement)
    guard sqlite3_bind_int(statement, 5, link.isEnabled ? 1 : 0) == SQLITE_OK else {
      throw bindError()
    }
    try bind(Self.timestamp(link.createdAt), at: 6, to: statement)
    try bind(Self.timestamp(link.updatedAt), at: 7, to: statement)
    try stepDone(statement)
  }

  public func buzzWorkspaceLinks() throws -> [BuzzWorkspaceLink] {
    try lock.withLock {
      try buzzWorkspaceLinksUnlocked()
    }
  }

  private func buzzWorkspaceLinksUnlocked() throws -> [BuzzWorkspaceLink] {
    let statement = try prepareUnlocked("""
      SELECT id, display_name, local_workspace_url, local_agent_store_url,
        is_enabled, created_at, updated_at
      FROM desktop_buzz_workspace_links
      ORDER BY display_name COLLATE NOCASE, id
      """)
    defer { sqlite3_finalize(statement) }
    var links: [BuzzWorkspaceLink] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return links }
      guard code == SQLITE_ROW else { throw stepError() }
      links.append(try buzzWorkspaceLink(from: statement))
    }
  }

  public func deleteBuzzWorkspaceLink(id: UUID) throws {
    try lock.withLock {
      let statement = try prepareUnlocked(
        "DELETE FROM desktop_buzz_workspace_links WHERE id = ?"
      )
      defer { sqlite3_finalize(statement) }
      try bind(id.uuidString.lowercased(), at: 1, to: statement)
      try stepDone(statement)
    }
  }

  @discardableResult
  public func enrollBuzzWorkspaceAgent(
    _ candidate: BuzzWorkspaceAgentCandidate,
    enrollmentID: UUID = UUID(),
    at date: Date = Date()
  ) throws -> BuzzWorkspaceAgentEnrollment {
    try transaction {
      let statement = try prepareUnlocked("""
        INSERT INTO desktop_buzz_agent_enrollments (
          id, workspace_link_id, agent_id, handle_snapshot,
          display_name_snapshot, harness_identifier, runtime_kind,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(workspace_link_id, agent_id) DO UPDATE SET
          handle_snapshot = excluded.handle_snapshot,
          display_name_snapshot = excluded.display_name_snapshot,
          harness_identifier = excluded.harness_identifier,
          runtime_kind = excluded.runtime_kind,
          updated_at = excluded.updated_at
        """)
      defer { sqlite3_finalize(statement) }
      let timestamp = Self.timestamp(date)
      try bind(enrollmentID.uuidString.lowercased(), at: 1, to: statement)
      try bind(candidate.workspaceLinkID.uuidString.lowercased(), at: 2, to: statement)
      try bind(candidate.agentID, at: 3, to: statement)
      try bind(candidate.handle, at: 4, to: statement)
      try bind(candidate.displayName, at: 5, to: statement)
      try bind(candidate.harnessIdentifier, at: 6, to: statement)
      try bindNullable(candidate.runtimeKind?.rawValue, at: 7, to: statement)
      try bind(timestamp, at: 8, to: statement)
      try bind(timestamp, at: 9, to: statement)
      try stepDone(statement)

      let select = try prepareUnlocked("""
        SELECT id, workspace_link_id, agent_id, handle_snapshot,
          display_name_snapshot, harness_identifier, runtime_kind,
          created_at, updated_at
        FROM desktop_buzz_agent_enrollments
        WHERE workspace_link_id = ? AND agent_id = ?
        """)
      defer { sqlite3_finalize(select) }
      try bind(candidate.workspaceLinkID.uuidString.lowercased(), at: 1, to: select)
      try bind(candidate.agentID, at: 2, to: select)
      guard sqlite3_step(select) == SQLITE_ROW else {
        throw WorkspaceDatabaseError.corruptRow
      }
      return try buzzWorkspaceAgentEnrollment(from: select)
    }
  }

  public func buzzWorkspaceAgentEnrollments(
    workspaceLinkID: UUID? = nil
  ) throws -> [BuzzWorkspaceAgentEnrollment] {
    try lock.withLock {
      let statement = try prepareUnlocked(
        workspaceLinkID == nil
          ? """
            SELECT id, workspace_link_id, agent_id, handle_snapshot,
              display_name_snapshot, harness_identifier, runtime_kind,
              created_at, updated_at
            FROM desktop_buzz_agent_enrollments
            ORDER BY display_name_snapshot COLLATE NOCASE, agent_id
            """
          : """
            SELECT id, workspace_link_id, agent_id, handle_snapshot,
              display_name_snapshot, harness_identifier, runtime_kind,
              created_at, updated_at
            FROM desktop_buzz_agent_enrollments
            WHERE workspace_link_id = ?
            ORDER BY display_name_snapshot COLLATE NOCASE, agent_id
            """
      )
      defer { sqlite3_finalize(statement) }
      if let workspaceLinkID {
        try bind(workspaceLinkID.uuidString.lowercased(), at: 1, to: statement)
      }
      var enrollments: [BuzzWorkspaceAgentEnrollment] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return enrollments }
        guard code == SQLITE_ROW else { throw stepError() }
        enrollments.append(try buzzWorkspaceAgentEnrollment(from: statement))
      }
    }
  }

  public func removeBuzzWorkspaceAgentEnrollment(id: UUID) throws {
    try lock.withLock {
      let statement = try prepareUnlocked(
        "DELETE FROM desktop_buzz_agent_enrollments WHERE id = ?"
      )
      defer { sqlite3_finalize(statement) }
      try bind(id.uuidString.lowercased(), at: 1, to: statement)
      try stepDone(statement)
    }
  }

  public func buzzWorkspaceSnapshot() throws -> BuzzWorkspaceSnapshot {
    BuzzWorkspaceSnapshot(
      links: try buzzWorkspaceLinks(),
      enrollments: try buzzWorkspaceAgentEnrollments()
    )
  }

  // MARK: - Device-local OpenClaw Gateway routing

  public func saveOpenClawGatewayLink(_ link: OpenClawGatewayLink) throws {
    try lock.withLock {
      let statement = try prepareUnlocked("""
        INSERT INTO desktop_openclaw_gateway_links (
          agent_id, location, endpoint_url, authorization, status,
          openclaw_version, last_connected_at, last_error, linked_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(agent_id) DO UPDATE SET
          location = excluded.location,
          endpoint_url = excluded.endpoint_url,
          authorization = excluded.authorization,
          status = excluded.status,
          openclaw_version = excluded.openclaw_version,
          last_connected_at = excluded.last_connected_at,
          last_error = excluded.last_error,
          updated_at = excluded.updated_at
        """)
      defer { sqlite3_finalize(statement) }
      try bind(link.agentID.uuidString.lowercased(), at: 1, to: statement)
      try bind(link.location.rawValue, at: 2, to: statement)
      try bind(link.endpoint.url.absoluteString, at: 3, to: statement)
      try bind(link.endpoint.authorization.rawValue, at: 4, to: statement)
      try bind(link.status, at: 5, to: statement)
      try bindNullable(link.openClawVersion, at: 6, to: statement)
      try bindNullable(link.lastConnectedAt.map(Self.timestamp), at: 7, to: statement)
      try bindNullable(link.lastError, at: 8, to: statement)
      try bind(Self.timestamp(link.linkedAt), at: 9, to: statement)
      try bind(Self.timestamp(link.updatedAt), at: 10, to: statement)
      try stepDone(statement)
    }
  }

  public func openClawGatewayLinks() throws -> [OpenClawGatewayLink] {
    try lock.withLock {
      let statement = try prepareUnlocked("""
        SELECT agent_id, location, endpoint_url, authorization, status,
          openclaw_version, last_connected_at, last_error, linked_at, updated_at
        FROM desktop_openclaw_gateway_links
        ORDER BY linked_at, agent_id
        """)
      defer { sqlite3_finalize(statement) }
      var links: [OpenClawGatewayLink] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return links }
        guard code == SQLITE_ROW,
              let agentID = UUID(uuidString: try text(statement, column: 0)),
              let location = OpenClawGatewayLocation(rawValue: try text(statement, column: 1)),
              let url = URL(string: try text(statement, column: 2)),
              let authorization = OpenClawGatewayAuthorization(rawValue: try text(statement, column: 3)),
              let linkedAt = Self.date(try text(statement, column: 8)),
              let updatedAt = Self.date(try text(statement, column: 9)) else {
          throw code == SQLITE_ROW ? WorkspaceDatabaseError.corruptRow : stepError()
        }
        links.append(OpenClawGatewayLink(
          agentID: agentID,
          location: location,
          endpoint: OpenClawGatewayEndpoint(url: url, authorization: authorization),
          status: try text(statement, column: 4),
          openClawVersion: optionalText(statement, column: 5),
          lastConnectedAt: optionalText(statement, column: 6).flatMap(Self.date),
          lastError: optionalText(statement, column: 7),
          linkedAt: linkedAt,
          updatedAt: updatedAt
        ))
      }
    }
  }

  public func removeOpenClawGatewayLink(agentID: UUID) throws {
    try lock.withLock {
      let statement = try prepareUnlocked(
        "DELETE FROM desktop_openclaw_gateway_links WHERE agent_id = ?"
      )
      defer { sqlite3_finalize(statement) }
      try bind(agentID.uuidString.lowercased(), at: 1, to: statement)
      try stepDone(statement)
    }
  }

  public func attachOpenClawGatewaySession(
    conversationID: String,
    agentID: UUID,
    sessionKey: String,
    createdAt: Date = Date()
  ) throws {
    let cleanKey = sessionKey.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanKey.isEmpty else { throw WorkspaceDatabaseError.corruptRow }
    try transaction {
      let statement = try prepareUnlocked("""
        INSERT INTO desktop_openclaw_gateway_sessions (
          conversation_id, agent_id, session_key, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(conversation_id) DO UPDATE SET
          agent_id = excluded.agent_id,
          session_key = excluded.session_key,
          updated_at = excluded.updated_at
        """)
      defer { sqlite3_finalize(statement) }
      let timestamp = Self.timestamp(createdAt)
      try bind(conversationID, at: 1, to: statement)
      try bind(agentID.uuidString.lowercased(), at: 2, to: statement)
      try bind(cleanKey, at: 3, to: statement)
      try bind(timestamp, at: 4, to: statement)
      try bind(timestamp, at: 5, to: statement)
      try stepDone(statement)

      // Keep the existing device-owned transcript/run machinery as the single
      // persistence authority for Gateway-backed conversations.
      let projection = try prepareUnlocked("""
        INSERT INTO desktop_local_acp_sessions (
          conversation_id, agent_id, runtime_kind, governing_plane,
          authority_kind, authority_device_id, authority_agent_id, revision,
          title, acp_session_id, created_at, updated_at
        )
        SELECT id, agent_id, 'openclaw', governing_plane, authority_kind,
          authority_device_id, authority_agent_id, 1, title, ?, ?, ?
        FROM dashboard_conversations WHERE id = ? AND desktop_owned = 1
        ON CONFLICT(conversation_id) DO UPDATE SET
          acp_session_id = excluded.acp_session_id,
          updated_at = excluded.updated_at
        """)
      defer { sqlite3_finalize(projection) }
      try bind(cleanKey, at: 1, to: projection)
      try bind(timestamp, at: 2, to: projection)
      try bind(timestamp, at: 3, to: projection)
      try bind(conversationID, at: 4, to: projection)
      try stepDone(projection)
      guard sqlite3_changes(connection) == 1 else {
        throw LocalACPSessionDatabaseError.sessionNotFound
      }
    }
  }

  public func openClawGatewayConversationIDs() throws -> Set<String> {
    try lock.withLock {
      let statement = try prepareUnlocked(
        "SELECT conversation_id FROM desktop_openclaw_gateway_sessions"
      )
      defer { sqlite3_finalize(statement) }
      var ids: Set<String> = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return ids }
        guard code == SQLITE_ROW else { throw stepError() }
        ids.insert(try text(statement, column: 0))
      }
    }
  }

  public func openClawGatewaySession(
    conversationID: String
  ) throws -> (agentID: UUID, sessionKey: String, preferences: OpenClawSessionPreferences) {
    try lock.withLock {
      let statement = try prepareUnlocked("""
        SELECT agent_id, session_key, model, thinking_level
        FROM desktop_openclaw_gateway_sessions WHERE conversation_id = ?
        """)
      defer { sqlite3_finalize(statement) }
      try bind(conversationID, at: 1, to: statement)
      guard sqlite3_step(statement) == SQLITE_ROW,
            let agentID = UUID(uuidString: try text(statement, column: 0)) else {
        throw LocalACPSessionDatabaseError.sessionNotFound
      }
      return (
        agentID,
        try text(statement, column: 1),
        OpenClawSessionPreferences(
          model: optionalText(statement, column: 2),
          thinkingLevel: optionalText(statement, column: 3)
        )
      )
    }
  }

  public func updateOpenClawGatewaySessionPreferences(
    conversationID: String,
    preferences: OpenClawSessionPreferences,
    updatedAt: Date = Date()
  ) throws {
    try lock.withLock {
      let statement = try prepareUnlocked("""
        UPDATE desktop_openclaw_gateway_sessions
        SET model = ?, thinking_level = ?, updated_at = ?
        WHERE conversation_id = ?
        """)
      defer { sqlite3_finalize(statement) }
      try bindNullable(preferences.model, at: 1, to: statement)
      try bindNullable(preferences.thinkingLevel, at: 2, to: statement)
      try bind(Self.timestamp(updatedAt), at: 3, to: statement)
      try bind(conversationID, at: 4, to: statement)
      try stepDone(statement)
      guard sqlite3_changes(connection) == 1 else {
        throw LocalACPSessionDatabaseError.sessionNotFound
      }
    }
  }

  public func replaceOpenClawCronSnapshot(
    agentID: UUID,
    jobs: [OpenClawCronJob],
    runs: [OpenClawCronRun],
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      let rawAgentID = agentID.uuidString.lowercased()
      let remoteJobIDs = Set(jobs.map(\.id))
      let existing = try prepareUnlocked("""
        SELECT remote_job_id FROM desktop_openclaw_cron_jobs
        WHERE agent_id = ? AND archive_state = 'active'
        """)
      defer { sqlite3_finalize(existing) }
      try bind(rawAgentID, at: 1, to: existing)
      var missing: [String] = []
      while sqlite3_step(existing) == SQLITE_ROW {
        let id = try text(existing, column: 0)
        if !remoteJobIDs.contains(id) { missing.append(id) }
      }
      let jobStatement = try prepareUnlocked("""
        INSERT INTO desktop_openclaw_cron_jobs (
          agent_id, remote_job_id, name, schedule, enabled,
          native_session_id, native_session_key, archive_state,
          remote_payload, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, 'active', ?, ?)
        ON CONFLICT(agent_id, remote_job_id) DO UPDATE SET
          name = excluded.name, schedule = excluded.schedule,
          enabled = excluded.enabled,
          native_session_id = excluded.native_session_id,
          native_session_key = excluded.native_session_key,
          archive_state = 'active', remote_payload = excluded.remote_payload,
          updated_at = excluded.updated_at
        """)
      defer { sqlite3_finalize(jobStatement) }
      for job in jobs {
        sqlite3_reset(jobStatement)
        sqlite3_clear_bindings(jobStatement)
        try bind(rawAgentID, at: 1, to: jobStatement)
        try bind(job.id, at: 2, to: jobStatement)
        try bind(job.name, at: 3, to: jobStatement)
        try bind(job.schedule, at: 4, to: jobStatement)
        guard sqlite3_bind_int(jobStatement, 5, job.enabled ? 1 : 0) == SQLITE_OK else {
          throw bindError()
        }
        try bindNullable(job.nativeSessionID, at: 6, to: jobStatement)
        try bindNullable(job.nativeSessionKey, at: 7, to: jobStatement)
        try bind(job.remotePayload, at: 8, to: jobStatement)
        try bind(Self.timestamp(job.updatedAt), at: 9, to: jobStatement)
        try stepDone(jobStatement)
      }
      let deleted = try prepareUnlocked("""
        UPDATE desktop_openclaw_cron_jobs
        SET archive_state = 'deleted', updated_at = ?
        WHERE agent_id = ? AND remote_job_id = ?
        """)
      defer { sqlite3_finalize(deleted) }
      for id in missing {
        sqlite3_reset(deleted)
        sqlite3_clear_bindings(deleted)
        try bind(Self.timestamp(updatedAt), at: 1, to: deleted)
        try bind(rawAgentID, at: 2, to: deleted)
        try bind(id, at: 3, to: deleted)
        try stepDone(deleted)
      }
      let runStatement = try prepareUnlocked("""
        INSERT INTO desktop_openclaw_cron_runs (
          agent_id, remote_run_id, remote_job_id, status, output,
          native_session_id, native_session_key, started_at, completed_at,
          remote_payload
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(agent_id, remote_run_id) DO UPDATE SET
          remote_job_id = excluded.remote_job_id, status = excluded.status,
          output = excluded.output,
          native_session_id = excluded.native_session_id,
          native_session_key = excluded.native_session_key,
          started_at = excluded.started_at, completed_at = excluded.completed_at,
          remote_payload = excluded.remote_payload
        """)
      defer { sqlite3_finalize(runStatement) }
      for run in runs {
        sqlite3_reset(runStatement)
        sqlite3_clear_bindings(runStatement)
        try bind(rawAgentID, at: 1, to: runStatement)
        try bind(run.id, at: 2, to: runStatement)
        try bind(run.jobID, at: 3, to: runStatement)
        try bind(run.status, at: 4, to: runStatement)
        try bindNullable(run.output, at: 5, to: runStatement)
        try bindNullable(run.nativeSessionID, at: 6, to: runStatement)
        try bindNullable(run.nativeSessionKey, at: 7, to: runStatement)
        try bindNullable(run.startedAt.map(Self.timestamp), at: 8, to: runStatement)
        try bindNullable(run.completedAt.map(Self.timestamp), at: 9, to: runStatement)
        try bind(run.remotePayload, at: 10, to: runStatement)
        try stepDone(runStatement)
      }
    }
  }

  public func openClawCronJobs(agentID: UUID? = nil) throws -> [OpenClawCronJob] {
    try lock.withLock {
      let statement = try prepareUnlocked(agentID == nil ? """
        SELECT remote_job_id, agent_id, name, schedule, enabled,
          native_session_id, native_session_key, archive_state,
          remote_payload, updated_at
        FROM desktop_openclaw_cron_jobs
        ORDER BY updated_at DESC, remote_job_id
        """ : """
        SELECT remote_job_id, agent_id, name, schedule, enabled,
          native_session_id, native_session_key, archive_state,
          remote_payload, updated_at
        FROM desktop_openclaw_cron_jobs WHERE agent_id = ?
        ORDER BY updated_at DESC, remote_job_id
        """)
      defer { sqlite3_finalize(statement) }
      if let agentID { try bind(agentID.uuidString.lowercased(), at: 1, to: statement) }
      var jobs: [OpenClawCronJob] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return jobs }
        guard code == SQLITE_ROW,
              let ownerID = UUID(uuidString: try text(statement, column: 1)),
              let archive = OpenClawCronArchiveState(rawValue: try text(statement, column: 7)),
              let updatedAt = Self.date(try text(statement, column: 9)) else {
          throw code == SQLITE_ROW ? WorkspaceDatabaseError.corruptRow : stepError()
        }
        jobs.append(OpenClawCronJob(
          id: try text(statement, column: 0), agentID: ownerID,
          name: try text(statement, column: 2),
          schedule: try text(statement, column: 3),
          enabled: sqlite3_column_int(statement, 4) != 0,
          nativeSessionID: optionalText(statement, column: 5),
          nativeSessionKey: optionalText(statement, column: 6),
          archiveState: archive, remotePayload: try blob(statement, column: 8),
          updatedAt: updatedAt
        ))
      }
    }
  }

  public func openClawCronRuns(agentID: UUID? = nil) throws -> [OpenClawCronRun] {
    try lock.withLock {
      let statement = try prepareUnlocked(agentID == nil ? """
        SELECT remote_run_id, remote_job_id, agent_id, status, output,
          native_session_id, native_session_key, started_at, completed_at,
          remote_payload
        FROM desktop_openclaw_cron_runs
        ORDER BY COALESCE(started_at, completed_at) DESC, remote_run_id DESC
        """ : """
        SELECT remote_run_id, remote_job_id, agent_id, status, output,
          native_session_id, native_session_key, started_at, completed_at,
          remote_payload
        FROM desktop_openclaw_cron_runs WHERE agent_id = ?
        ORDER BY COALESCE(started_at, completed_at) DESC, remote_run_id DESC
        """)
      defer { sqlite3_finalize(statement) }
      if let agentID { try bind(agentID.uuidString.lowercased(), at: 1, to: statement) }
      var runs: [OpenClawCronRun] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return runs }
        guard code == SQLITE_ROW,
              let ownerID = UUID(uuidString: try text(statement, column: 2)) else {
          throw code == SQLITE_ROW ? WorkspaceDatabaseError.corruptRow : stepError()
        }
        runs.append(OpenClawCronRun(
          id: try text(statement, column: 0),
          jobID: try text(statement, column: 1), agentID: ownerID,
          status: try text(statement, column: 3),
          output: optionalText(statement, column: 4),
          nativeSessionID: optionalText(statement, column: 5),
          nativeSessionKey: optionalText(statement, column: 6),
          startedAt: optionalText(statement, column: 7).flatMap(Self.date),
          completedAt: optionalText(statement, column: 8).flatMap(Self.date),
          remotePayload: try blob(statement, column: 9)
        ))
      }
    }
  }

  public func emptyOpenClawCronTrash(agentID: UUID? = nil) throws {
    try transaction {
      let jobs = try prepareUnlocked(agentID == nil ? """
        DELETE FROM desktop_openclaw_cron_jobs WHERE archive_state = 'deleted'
        """ : """
        DELETE FROM desktop_openclaw_cron_jobs
        WHERE archive_state = 'deleted' AND agent_id = ?
        """)
      defer { sqlite3_finalize(jobs) }
      if let agentID { try bind(agentID.uuidString.lowercased(), at: 1, to: jobs) }
      try stepDone(jobs)
      // Remote run history is deliberately untouched by remote APIs. Local
      // orphan rows are pruned only when Empty Trash is explicitly invoked.
      try executeUnlocked("""
        DELETE FROM desktop_openclaw_cron_runs
        WHERE NOT EXISTS (
          SELECT 1 FROM desktop_openclaw_cron_jobs AS job
          WHERE job.agent_id = desktop_openclaw_cron_runs.agent_id
            AND job.remote_job_id = desktop_openclaw_cron_runs.remote_job_id
        )
        """)
    }
  }

  public func buzzLocalAgentLaunchSource(
    workspaceLinkID: UUID,
    agentID: String
  ) throws -> BuzzLocalAgentLaunchSource {
    guard let link = try buzzWorkspaceLinks().first(where: {
      $0.id == workspaceLinkID
    }) else {
      throw BuzzWorkspaceDatabaseError.workspaceNotFound
    }
    guard let enrollment = try buzzWorkspaceAgentEnrollments(
      workspaceLinkID: workspaceLinkID
    ).first(where: { $0.agentID == agentID }) else {
      throw BuzzWorkspaceDatabaseError.enrollmentNotFound
    }
    guard link.isEnabled,
          enrollment.runtimeKind != nil else {
      throw BuzzWorkspaceDatabaseError.localACPRequired
    }
    return BuzzLocalAgentLaunchSource(
      link: link,
      enrollment: enrollment
    )
  }

  public func buzzLocalAgentLaunchSource(
    conversationID: String
  ) throws -> BuzzLocalAgentLaunchSource {
    let descriptor = try localACPSession(conversationID: conversationID)
    guard let workspaceLinkID = descriptor.buzzWorkspaceLinkID,
          let buzzAgentID = descriptor.buzzAgentID else {
      throw BuzzWorkspaceDatabaseError.enrollmentNotFound
    }
    return try buzzLocalAgentLaunchSource(
      workspaceLinkID: workspaceLinkID,
      agentID: buzzAgentID
    )
  }

  public func buzzBoundLocalACPConversationIDs() throws -> Set<String> {
    try lock.withLock {
      let statement = try prepareUnlocked("""
        SELECT session.conversation_id
        FROM desktop_local_acp_sessions AS session
        JOIN desktop_buzz_workspace_links AS link
          ON link.id = session.buzz_workspace_link_id
        WHERE session.buzz_agent_id IS NOT NULL
        """)
      defer { sqlite3_finalize(statement) }
      var result: Set<String> = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return result }
        guard code == SQLITE_ROW else { throw stepError() }
        result.insert(try text(statement, column: 0))
      }
    }
  }

  private func buzzWorkspaceLink(
    from statement: OpaquePointer
  ) throws -> BuzzWorkspaceLink {
    guard let id = UUID(uuidString: try text(statement, column: 0)),
          let localWorkspaceURL = URL(string: try text(statement, column: 2)),
          let localAgentStoreURL = URL(string: try text(statement, column: 3)),
          let createdAt = Self.date(try text(statement, column: 5)),
          let updatedAt = Self.date(try text(statement, column: 6)) else {
      throw WorkspaceDatabaseError.corruptRow
    }
    return BuzzWorkspaceLink(
      id: id,
      displayName: try text(statement, column: 1),
      localWorkspaceURL: localWorkspaceURL,
      localAgentStoreURL: localAgentStoreURL,
      isEnabled: sqlite3_column_int(statement, 4) != 0,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  private func buzzWorkspaceAgentEnrollment(
    from statement: OpaquePointer
  ) throws -> BuzzWorkspaceAgentEnrollment {
    guard let id = UUID(uuidString: try text(statement, column: 0)),
          let workspaceLinkID = UUID(uuidString: try text(statement, column: 1)),
          let createdAt = Self.date(try text(statement, column: 7)),
          let updatedAt = Self.date(try text(statement, column: 8)) else {
      throw WorkspaceDatabaseError.corruptRow
    }
    let runtimeKind: AgentRuntimeKind?
    if let rawRuntime = optionalText(statement, column: 6) {
      guard let decoded = AgentRuntimeKind(rawValue: rawRuntime) else {
        throw WorkspaceDatabaseError.corruptRow
      }
      runtimeKind = decoded
    } else {
      runtimeKind = nil
    }
    return BuzzWorkspaceAgentEnrollment(
      id: id,
      workspaceLinkID: workspaceLinkID,
      agentID: try text(statement, column: 2),
      handleSnapshot: try text(statement, column: 3),
      displayNameSnapshot: try text(statement, column: 4),
      harnessIdentifier: try text(statement, column: 5),
      runtimeKind: runtimeKind,
      createdAt: createdAt,
      updatedAt: updatedAt
    )
  }

  public func bindDeviceOwnership(
    ownerDeviceID: UUID,
    boundAt: Date = Date()
  ) throws {
    try lock.withLock {
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
      guard sqlite3_changes(connection) == 1 else {
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

  public func dashboardRevision() throws -> Int64 {
    try lock.withLock {
      let statement = try prepareUnlocked(
        "SELECT revision FROM desktop_dashboard_revision WHERE singleton = 1"
      )
      defer { sqlite3_finalize(statement) }
      guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
      return sqlite3_column_int64(statement, 0)
    }
  }

  @discardableResult
  public func markConversationRead(id: String) throws -> Bool {
    try transaction {
      let update = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET unread = 0
        WHERE id = ? AND unread != 0 AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(update) }
      try bind(id, at: 1, to: update)
      try stepDone(update)
      return sqlite3_changes(connection) == 1
    }
  }

  @discardableResult
  public func updateConversationTitleIfCurrent(
    id: String,
    expectedTitle: String,
    title: String,
    updatedAt: Date = Date()
  ) throws -> Bool {
    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTitle.isEmpty else { return false }
    return try transaction {
      let authority = try prepareUnlocked("""
        SELECT 1
        FROM dashboard_conversations
        WHERE id = ? AND desktop_owned = 1 AND authority_kind = 'device_owned'
          AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(authority) }
      try bind(id, at: 1, to: authority)
      guard sqlite3_step(authority) == SQLITE_ROW else { return false }

      let timestamp = Self.timestamp(updatedAt)
      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET title = ?, updated_at = ?
        WHERE id = ? AND title = ? AND desktop_owned = 1
          AND authority_kind = 'device_owned' AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(cleanTitle, at: 1, to: conversation)
      try bind(timestamp, at: 2, to: conversation)
      try bind(id, at: 3, to: conversation)
      try bind(expectedTitle, at: 4, to: conversation)
      try stepDone(conversation)
      guard sqlite3_changes(connection) == 1 else { return false }

      let session = try prepareUnlocked("""
        UPDATE desktop_local_acp_sessions
        SET title = ?, updated_at = ? WHERE conversation_id = ?
        """)
      defer { sqlite3_finalize(session) }
      try bind(cleanTitle, at: 1, to: session)
      try bind(timestamp, at: 2, to: session)
      try bind(id, at: 3, to: session)
      try stepDone(session)

      return true
    }
  }

  @discardableResult
  public func moveConversation(
    id: String,
    toFolderID folderID: String?,
    operationID: UUID = UUID(),
    updatedAt: Date = Date()
  ) throws -> Bool {
    try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      try validateFolderUnlocked(id: folderID, operatorID: operatorID)

      let authority = try prepareUnlocked("""
        SELECT 1
        FROM dashboard_conversations
        WHERE id = ? AND desktop_owned = 1 AND authority_kind = 'device_owned'
          AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(authority) }
      try bind(id, at: 1, to: authority)
      guard sqlite3_step(authority) == SQLITE_ROW else { return false }

      let timestamp = Self.timestamp(updatedAt)
      let update = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET folder_id = ?, updated_at = ?
        WHERE id = ? AND desktop_owned = 1
          AND authority_kind = 'device_owned' AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(update) }
      try bindNullable(folderID, at: 1, to: update)
      try bind(timestamp, at: 2, to: update)
      try bind(id, at: 3, to: update)
      try stepDone(update)
      guard sqlite3_changes(connection) == 1 else { return false }

      return true
    }
  }

  private static func localCLIAgentID(
    for runtimeKind: AgentRuntimeKind,
    ownerDeviceID: UUID
  ) -> String? {
    guard LocalACPRuntimeCatalog.definition(for: runtimeKind) != nil else {
      return nil
    }
    let seed = Data(
      "wovenmatter.local-cli-agent.v1:\(ownerDeviceID.uuidString.lowercased()):\(runtimeKind.rawValue)".utf8
    )
    var bytes = Array(SHA256.hash(data: seed).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }
    return [
      hex[0..<4].joined(), hex[4..<6].joined(), hex[6..<8].joined(),
      hex[8..<10].joined(), hex[10..<16].joined(),
    ].joined(separator: "-")
  }

  private static func remoteHarnessAgentID(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    ownerDeviceID: UUID
  ) -> String? {
    guard LocalACPRuntimeCatalog.definition(for: runtimeKind) != nil else {
      return nil
    }
    let seed = Data(
      "wovenmatter.remote-harness-agent.v1:\(ownerDeviceID.uuidString.lowercased()):\(remoteWorkspaceID.uuidString.lowercased()):\(runtimeKind.rawValue)".utf8
    )
    var bytes = Array(SHA256.hash(data: seed).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }
    return [
      hex[0..<4].joined(), hex[4..<6].joined(), hex[6..<8].joined(),
      hex[8..<10].joined(), hex[10..<16].joined(),
    ].joined(separator: "-")
  }

  private func ensureRemoteHarnessAgentUnlocked(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    ownerDeviceID: UUID,
    operatorID: String,
    status: AgentRuntimeStatus,
    updatedAt: Date
  ) throws -> String {
    guard let id = Self.remoteHarnessAgentID(
      runtimeKind: runtimeKind,
      remoteWorkspaceID: remoteWorkspaceID,
      ownerDeviceID: ownerDeviceID
    ) else {
      throw LocalACPSessionDatabaseError.runtimeUnavailable
    }
    let workspaceID = remoteWorkspaceID.uuidString.lowercased()
    let cleanName = remoteWorkspaceName.trimmingCharacters(in: .whitespacesAndNewlines)
    let displayName = cleanName.isEmpty
      ? runtimeKind.displayName
      : "\(runtimeKind.displayName) · \(cleanName)"
    let codename = "remote-\(workspaceID.prefix(8))-\(runtimeKind.rawValue)"
    let platformCodename = "remote-workspace:\(workspaceID)"
    let timestamp = Self.timestamp(updatedAt)
    let statement = try prepareUnlocked("""
      INSERT INTO dashboard_agents (
        id, user_id, codename, display_name, icon, execution_location,
        agent_bucket, governing_plane, authority_kind, authority_device_id,
        authority_agent_id, runtime_kind, runtime_device_id, platform_codename,
        status, revision, created_at, updated_at, desktop_owned
      ) VALUES (?, ?, ?, ?, 'container', 'remote', 'remote_workspace',
        'remote_workspace', 'device_owned', ?, ?, ?, ?, ?, ?, 1, ?, ?, 1)
      ON CONFLICT(id) DO UPDATE SET
        user_id = excluded.user_id,
        codename = excluded.codename,
        display_name = excluded.display_name,
        icon = excluded.icon,
        execution_location = excluded.execution_location,
        agent_bucket = excluded.agent_bucket,
        governing_plane = excluded.governing_plane,
        authority_kind = excluded.authority_kind,
        authority_device_id = excluded.authority_device_id,
        authority_agent_id = excluded.authority_agent_id,
        runtime_kind = excluded.runtime_kind,
        runtime_device_id = excluded.runtime_device_id,
        platform_codename = excluded.platform_codename,
        status = excluded.status,
        revision = dashboard_agents.revision + 1,
        updated_at = excluded.updated_at,
        deleted_at = NULL,
        desktop_owned = 1
      WHERE dashboard_agents.authority_kind = 'device_owned'
        AND dashboard_agents.governing_plane = 'remote_workspace'
        AND dashboard_agents.runtime_device_id = excluded.runtime_device_id
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(operatorID, at: 2, to: statement)
    try bind(codename, at: 3, to: statement)
    try bind(displayName, at: 4, to: statement)
    try bind(ownerDeviceID.uuidString.lowercased(), at: 5, to: statement)
    try bind(id, at: 6, to: statement)
    try bind(runtimeKind.rawValue, at: 7, to: statement)
    try bind(workspaceID, at: 8, to: statement)
    try bind(platformCodename, at: 9, to: statement)
    try bind(status.rawValue, at: 10, to: statement)
    try bind(timestamp, at: 11, to: statement)
    try bind(timestamp, at: 12, to: statement)
    try stepDone(statement)
    guard sqlite3_changes(connection) == 1 else {
      throw WorkspaceDatabaseError.execute("Remote workspace agent identity collision")
    }
    return id
  }

  @discardableResult
  public func ensureRemoteHarnessAgent(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    ownerDeviceID: UUID,
    status: AgentRuntimeStatus = .ready,
    updatedAt: Date = Date()
  ) throws -> UUID {
    try transaction {
      let id = try ensureRemoteHarnessAgentUnlocked(
        runtimeKind: runtimeKind,
        remoteWorkspaceID: remoteWorkspaceID,
        remoteWorkspaceName: remoteWorkspaceName,
        ownerDeviceID: ownerDeviceID,
        operatorID: try localMutationOperatorIDUnlocked(),
        status: status,
        updatedAt: updatedAt
      )
      guard let value = UUID(uuidString: id) else {
        throw WorkspaceDatabaseError.corruptRow
      }
      return value
    }
  }

  private func ensureLocalCLIAgentUnlocked(
    runtimeKind: AgentRuntimeKind,
    ownerDeviceID: UUID,
    operatorID: String,
    status: AgentRuntimeStatus?,
    updatedAt: Date
  ) throws -> String {
    guard let id = Self.localCLIAgentID(
      for: runtimeKind,
      ownerDeviceID: ownerDeviceID
    ),
          let codename = LocalACPRuntimeCatalog.conversationCodename(for: runtimeKind) else {
      throw LocalACPSessionDatabaseError.runtimeUnavailable
    }
    let timestamp = Self.timestamp(updatedAt)
    let existedStatement = try prepareUnlocked("""
      SELECT status FROM dashboard_agents
      WHERE id = ? AND authority_kind = 'device_owned'
      """)
    try bind(id, at: 1, to: existedStatement)
    let existingCode = sqlite3_step(existedStatement)
    let agentAlreadyExisted = existingCode == SQLITE_ROW
    let existingStatus = agentAlreadyExisted
      ? optionalText(existedStatement, column: 0).flatMap(AgentRuntimeStatus.init(rawValue:))
      : nil
    sqlite3_finalize(existedStatement)
    guard existingCode == SQLITE_ROW || existingCode == SQLITE_DONE else {
      throw stepError()
    }
    let desiredStatus = status ?? existingStatus ?? .offline
    let statement = try prepareUnlocked("""
      INSERT INTO dashboard_agents (
        id, user_id, codename, display_name, icon, execution_location,
        agent_bucket, governing_plane, authority_kind, authority_device_id,
        authority_agent_id, runtime_kind, status, revision,
        created_at, updated_at, desktop_owned
      ) VALUES (?, ?, ?, ?, 'terminal', 'local', 'local_cli', 'wovenmatter_macos',
        'device_owned', ?, ?, ?, ?, 1, ?, ?, 1)
      ON CONFLICT(id) DO UPDATE SET
        user_id = excluded.user_id,
        codename = excluded.codename,
        display_name = dashboard_agents.display_name,
        icon = excluded.icon,
        execution_location = excluded.execution_location,
        agent_bucket = excluded.agent_bucket,
        governing_plane = excluded.governing_plane,
        authority_kind = excluded.authority_kind,
        authority_device_id = excluded.authority_device_id,
        authority_agent_id = excluded.authority_agent_id,
        runtime_kind = excluded.runtime_kind,
        status = excluded.status,
        revision = dashboard_agents.revision + 1,
        updated_at = excluded.updated_at,
        deleted_at = NULL,
        desktop_owned = 1
      WHERE dashboard_agents.authority_kind = 'device_owned'
        AND dashboard_agents.governing_plane = 'wovenmatter_macos'
        AND (
          dashboard_agents.user_id IS NOT excluded.user_id
          OR dashboard_agents.codename IS NOT excluded.codename
          OR dashboard_agents.icon IS NOT excluded.icon
          OR dashboard_agents.execution_location IS NOT excluded.execution_location
          OR dashboard_agents.agent_bucket IS NOT excluded.agent_bucket
          OR dashboard_agents.authority_device_id IS NOT excluded.authority_device_id
          OR dashboard_agents.authority_agent_id IS NOT excluded.authority_agent_id
          OR dashboard_agents.runtime_kind IS NOT excluded.runtime_kind
          OR dashboard_agents.status IS NOT excluded.status
          OR dashboard_agents.deleted_at IS NOT NULL
          OR dashboard_agents.desktop_owned != 1
        )
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(operatorID, at: 2, to: statement)
    try bind(codename, at: 3, to: statement)
    try bind(runtimeKind.displayName, at: 4, to: statement)
    try bind(ownerDeviceID.uuidString.lowercased(), at: 5, to: statement)
    try bind(id, at: 6, to: statement)
    try bind(runtimeKind.rawValue, at: 7, to: statement)
    try bind(desiredStatus.rawValue, at: 8, to: statement)
    try bind(timestamp, at: 9, to: statement)
    try bind(timestamp, at: 10, to: statement)
    try stepDone(statement)
    let changed = sqlite3_changes(connection) == 1
    guard changed || agentAlreadyExisted else {
      throw WorkspaceDatabaseError.execute("Local CLI agent identity collision")
    }
    if changed {
    }
    return id
  }

  private func reconcileBuzzWorkspaceAgentUnlocked(
    enrollment: BuzzWorkspaceAgentEnrollment,
    ownerDeviceID: UUID,
    operatorID: String,
    status: AgentRuntimeStatus,
    updatedAt: Date
  ) throws {
    guard let runtimeKind = enrollment.runtimeKind else {
      throw BuzzWorkspaceDatabaseError.localACPRequired
    }
    let rawID = enrollment.id.uuidString.lowercased()
    let platformCodename =
      "buzz-workspace:\(enrollment.workspaceLinkID.uuidString.lowercased())"
    let existing = try prepareUnlocked("""
      SELECT 1 FROM dashboard_agents
      WHERE id = ? AND authority_kind = 'device_owned'
        AND governing_plane = 'wovenmatter_macos'
        AND platform_codename = ?
      """)
    try bind(rawID, at: 1, to: existing)
    try bind(platformCodename, at: 2, to: existing)
    let existingCode = sqlite3_step(existing)
    let alreadyExisted = existingCode == SQLITE_ROW
    sqlite3_finalize(existing)
    guard existingCode == SQLITE_ROW || existingCode == SQLITE_DONE else {
      throw stepError()
    }

    let timestamp = Self.timestamp(updatedAt)
    let statement = try prepareUnlocked("""
      INSERT INTO dashboard_agents (
        id, user_id, codename, display_name, icon, execution_location,
        agent_bucket, governing_plane, authority_kind, authority_device_id,
        authority_agent_id, runtime_kind, platform_codename, status, revision,
        created_at, updated_at, desktop_owned
      ) VALUES (?, ?, ?, ?, 'terminal', 'local', 'local_cli',
        'wovenmatter_macos', 'device_owned', ?, ?, ?, ?, ?, 1, ?, ?, 1)
      ON CONFLICT(id) DO UPDATE SET
        user_id = excluded.user_id,
        codename = excluded.codename,
        display_name = dashboard_agents.display_name,
        icon = excluded.icon,
        execution_location = excluded.execution_location,
        agent_bucket = excluded.agent_bucket,
        governing_plane = excluded.governing_plane,
        authority_kind = excluded.authority_kind,
        authority_device_id = excluded.authority_device_id,
        authority_agent_id = excluded.authority_agent_id,
        runtime_kind = excluded.runtime_kind,
        platform_codename = excluded.platform_codename,
        status = excluded.status,
        revision = dashboard_agents.revision + 1,
        updated_at = excluded.updated_at,
        deleted_at = NULL,
        desktop_owned = 1
      WHERE dashboard_agents.authority_kind = 'device_owned'
        AND dashboard_agents.governing_plane = 'wovenmatter_macos'
        AND dashboard_agents.platform_codename IS excluded.platform_codename
        AND (
          dashboard_agents.user_id IS NOT excluded.user_id
          OR dashboard_agents.codename IS NOT excluded.codename
          OR dashboard_agents.icon IS NOT excluded.icon
          OR dashboard_agents.execution_location IS NOT excluded.execution_location
          OR dashboard_agents.agent_bucket IS NOT excluded.agent_bucket
          OR dashboard_agents.authority_device_id IS NOT excluded.authority_device_id
          OR dashboard_agents.authority_agent_id IS NOT excluded.authority_agent_id
          OR dashboard_agents.runtime_kind IS NOT excluded.runtime_kind
          OR dashboard_agents.platform_codename IS NOT excluded.platform_codename
          OR dashboard_agents.status IS NOT excluded.status
          OR dashboard_agents.deleted_at IS NOT NULL
          OR dashboard_agents.desktop_owned != 1
        )
      """)
    defer { sqlite3_finalize(statement) }
    try bind(rawID, at: 1, to: statement)
    try bind(operatorID, at: 2, to: statement)
    try bind(enrollment.handleSnapshot, at: 3, to: statement)
    try bind(enrollment.displayNameSnapshot, at: 4, to: statement)
    try bind(ownerDeviceID.uuidString.lowercased(), at: 5, to: statement)
    try bind(rawID, at: 6, to: statement)
    try bind(runtimeKind.rawValue, at: 7, to: statement)
    try bind(platformCodename, at: 8, to: statement)
    try bind(status.rawValue, at: 9, to: statement)
    try bind(Self.timestamp(enrollment.createdAt), at: 10, to: statement)
    try bind(timestamp, at: 11, to: statement)
    try stepDone(statement)
    let changed = sqlite3_changes(connection) == 1
    guard changed || alreadyExisted else {
      throw WorkspaceDatabaseError.execute("Buzz workspace agent identity collision")
    }
    if changed {
    }
  }

  public func reconcileBuzzWorkspaceAgent(
    enrollment: BuzzWorkspaceAgentEnrollment,
    ownerDeviceID: UUID,
    status: AgentRuntimeStatus,
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      try reconcileBuzzWorkspaceAgentUnlocked(
        enrollment: enrollment,
        ownerDeviceID: ownerDeviceID,
        operatorID: try localMutationOperatorIDUnlocked(),
        status: status,
        updatedAt: updatedAt
      )
    }
  }

  public func retireBuzzWorkspaceAgent(
    enrollmentID: UUID,
    ownerDeviceID: UUID,
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      let rawID = enrollmentID.uuidString.lowercased()
      let statement = try prepareUnlocked("""
        UPDATE dashboard_agents
        SET status = 'offline', deleted_at = ?, revision = revision + 1,
          updated_at = ?
        WHERE id = ? AND governing_plane = 'wovenmatter_macos'
          AND authority_kind = 'device_owned' AND authority_device_id = ?
          AND platform_codename LIKE 'buzz-workspace:%'
          AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(statement) }
      let timestamp = Self.timestamp(updatedAt)
      try bind(timestamp, at: 1, to: statement)
      try bind(timestamp, at: 2, to: statement)
      try bind(rawID, at: 3, to: statement)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 4, to: statement)
      try stepDone(statement)
      if sqlite3_changes(connection) == 1 {
      }
    }
  }

  public func reconcileLocalCLIAgentCatalog(
    ownerDeviceID: UUID,
    statuses: [AgentRuntimeKind: AgentRuntimeStatus] = [:],
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      for definition in LocalACPRuntimeCatalog.definitions {
        _ = try ensureLocalCLIAgentUnlocked(
          runtimeKind: definition.runtimeKind,
          ownerDeviceID: ownerDeviceID,
          operatorID: operatorID,
          status: statuses[definition.runtimeKind],
          updatedAt: updatedAt
        )
      }
    }
  }

  @discardableResult
  public func createLocalACPSession(
    runtimeKind: AgentRuntimeKind,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date()
  ) throws -> String {
    guard LocalACPRuntimeCatalog.definition(for: runtimeKind) != nil,
          let codename = LocalACPRuntimeCatalog.conversationCodename(
            for: runtimeKind
          ) else {
      throw LocalACPSessionDatabaseError.runtimeUnavailable
    }
    return try transaction {
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
      return conversationID
    }
  }

  @discardableResult
  public func createRemoteACPSession(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    title: String,
    ownerDeviceID: UUID,
    createdAt: Date = Date()
  ) throws -> String {
    guard LocalACPRuntimeCatalog.definition(for: runtimeKind) != nil else {
      throw LocalACPSessionDatabaseError.runtimeUnavailable
    }
    return try transaction {
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
      return conversationID
    }
  }

  @discardableResult
  public func createBuzzLocalACPSession(
    enrollmentID: UUID,
    title: String,
    ownerDeviceID: UUID,
    model: String? = nil,
    createdAt: Date = Date()
  ) throws -> String {
    let enrollment = try buzzWorkspaceAgentEnrollments().first(where: {
      $0.id == enrollmentID
    })
    guard let enrollment else {
      throw BuzzWorkspaceDatabaseError.enrollmentNotFound
    }
    let source = try buzzLocalAgentLaunchSource(
      workspaceLinkID: enrollment.workspaceLinkID,
      agentID: enrollment.agentID
    )
    guard let runtimeKind = enrollment.runtimeKind,
          source.link.isEnabled else {
      throw BuzzWorkspaceDatabaseError.localACPRequired
    }

    return try transaction {
      let operatorID = try localMutationOperatorIDUnlocked()
      try reconcileBuzzWorkspaceAgentUnlocked(
        enrollment: enrollment,
        ownerDeviceID: ownerDeviceID,
        operatorID: operatorID,
        status: .ready,
        updatedAt: createdAt
      )
      let rawAgentID = enrollment.id.uuidString.lowercased()
      let conversationID = UUID().uuidString.lowercased()
      let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
      let sessionTitle = cleanTitle.isEmpty
        ? "New \(enrollment.displayNameSnapshot) chat"
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
      try bind(rawAgentID, at: 3, to: conversation)
      try bind(enrollment.handleSnapshot, at: 4, to: conversation)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 5, to: conversation)
      try bind(rawAgentID, at: 6, to: conversation)
      try bind(sessionTitle, at: 7, to: conversation)
      try bind(timestamp, at: 8, to: conversation)
      try bind(timestamp, at: 9, to: conversation)
      try bind(timestamp, at: 10, to: conversation)
      try stepDone(conversation)

      let session = try prepareUnlocked("""
        INSERT INTO desktop_local_acp_sessions (
          conversation_id, agent_id, runtime_kind, governing_plane,
          authority_kind, authority_device_id, authority_agent_id, revision,
          title, model, buzz_workspace_link_id, buzz_agent_id,
          created_at, updated_at
        ) VALUES (?, ?, ?, 'wovenmatter_macos', 'device_owned', ?, ?, 1,
          ?, ?, ?, ?, ?, ?)
        """)
      defer { sqlite3_finalize(session) }
      try bind(conversationID, at: 1, to: session)
      try bind(rawAgentID, at: 2, to: session)
      try bind(runtimeKind.rawValue, at: 3, to: session)
      try bind(ownerDeviceID.uuidString.lowercased(), at: 4, to: session)
      try bind(rawAgentID, at: 5, to: session)
      try bind(sessionTitle, at: 6, to: session)
      try bindNullable(model, at: 7, to: session)
      try bind(enrollment.workspaceLinkID.uuidString.lowercased(), at: 8, to: session)
      try bind(enrollment.agentID, at: 9, to: session)
      try bind(timestamp, at: 10, to: session)
      try bind(timestamp, at: 11, to: session)
      try stepDone(session)

      return conversationID
    }
  }

  @discardableResult
  public func localACPSession(
    conversationID: String
  ) throws -> LocalACPSessionDescriptor {
    try lock.withLock {
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
      guard sqlite3_changes(connection) == 1 else {
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
        guard sqlite3_changes(connection) == 1 else {
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
      guard sqlite3_changes(connection) == 1 else {
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
    try transaction {
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
        SET last_message_preview = ?, last_message_at = ?, updated_at = ?
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
    try lock.withLock {
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
        guard sqlite3_changes(connection) == 1 else {
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
      guard sqlite3_changes(connection) == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, last_message_at = ?, updated_at = ?
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
      guard sqlite3_changes(connection) == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, last_message_at = ?, updated_at = ?
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
      guard sqlite3_changes(connection) == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, last_message_at = ?, updated_at = ?
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
      let authority = try localRunAuthorityUnlocked(runID: runID)
      let timestamp = Self.timestamp(updatedAt)
      let message = try prepareUnlocked("""
        UPDATE dashboard_messages
        SET content = content || ?, status = 'streaming', updated_at = ?
        WHERE id = ? AND run_id = ? AND role = 'assistant'
          AND desktop_owned = 1
          AND EXISTS (
            SELECT 1 FROM dashboard_runs
            WHERE id = ? AND desktop_owned = 1 AND status = 'running'
          )
        """)
      defer { sqlite3_finalize(message) }
      try bind(chunk, at: 1, to: message)
      try bind(timestamp, at: 2, to: message)
      try bind(assistantMessageID, at: 3, to: message)
      try bind(runID, at: 4, to: message)
      try bind(runID, at: 5, to: message)
      try stepDone(message)
      guard sqlite3_changes(connection) == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, last_message_at = ?, updated_at = ?
        WHERE id = ? AND desktop_owned = 1
          AND ? = (
            SELECT assistant_message_id FROM dashboard_runs WHERE id = ?
          )
      """)
      defer { sqlite3_finalize(conversation) }
      try bind(try localAssistantPreviewUnlocked(
        runID: runID,
        assistantMessageID: assistantMessageID
      ), at: 1, to: conversation)
      try bind(timestamp, at: 2, to: conversation)
      try bind(timestamp, at: 3, to: conversation)
      try bind(authority.conversationID, at: 4, to: conversation)
      try bind(assistantMessageID, at: 5, to: conversation)
      try bind(runID, at: 6, to: conversation)
      try stepDone(conversation)
      let updatedConversation = sqlite3_changes(connection) == 1
      if updatedConversation {
      }
    }
  }

  public func replaceLocalACPAssistantMessage(
    runID: String,
    assistantMessageID: String,
    content: String,
    updatedAt: Date = Date()
  ) throws {
    try transaction {
      let authority = try localRunAuthorityUnlocked(runID: runID)
      let timestamp = Self.timestamp(updatedAt)
      let message = try prepareUnlocked("""
        UPDATE dashboard_messages
        SET content = ?, status = 'streaming', updated_at = ?
        WHERE id = ? AND run_id = ? AND role = 'assistant'
          AND desktop_owned = 1
          AND EXISTS (
            SELECT 1 FROM dashboard_runs
            WHERE id = ? AND desktop_owned = 1 AND status = 'running'
          )
        """)
      defer { sqlite3_finalize(message) }
      try bind(content, at: 1, to: message)
      try bind(timestamp, at: 2, to: message)
      try bind(assistantMessageID, at: 3, to: message)
      try bind(runID, at: 4, to: message)
      try bind(runID, at: 5, to: message)
      try stepDone(message)
      guard sqlite3_changes(connection) == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, last_message_at = ?, updated_at = ?
        WHERE id = ? AND desktop_owned = 1
          AND ? = (
            SELECT assistant_message_id FROM dashboard_runs WHERE id = ?
          )
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(Self.localPreview(
        RemoteNoteEditEnvelope.redactingEnvelopes(in: content)
      ), at: 1, to: conversation)
      try bind(timestamp, at: 2, to: conversation)
      try bind(timestamp, at: 3, to: conversation)
      try bind(authority.conversationID, at: 4, to: conversation)
      try bind(assistantMessageID, at: 5, to: conversation)
      try bind(runID, at: 6, to: conversation)
      try stepDone(conversation)
      let updatedConversation = sqlite3_changes(connection) == 1
      if updatedConversation {
      }
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
          WHEN content = '' AND ? IS NULL THEN 'The local agent completed without a text response.'
          ELSE content
        END, status = ?, updated_at = ?
        WHERE id = ? AND run_id = ? AND role = 'assistant'
          AND desktop_owned = 1
        """)
      defer { sqlite3_finalize(message) }
      try bindNullable(error, at: 1, to: message)
      try bindNullable(error, at: 2, to: message)
      try bindNullable(error, at: 3, to: message)
      try bind(status, at: 4, to: message)
      try bind(timestamp, at: 5, to: message)
      try bind(assistantMessageID, at: 6, to: message)
      try bind(runID, at: 7, to: message)
      try stepDone(message)
      guard sqlite3_changes(connection) == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }
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
    eventName: String,
    sequence: Int,
    eventType: String,
    eventPhase: String?,
    toolName: String?,
    content: String?,
    rawEventJSON: String,
    createdAt: Date = Date()
  ) throws {
    try transaction {
      let recordID = "\(runID):gateway:\(eventName):\(sequence)"
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
      guard sqlite3_changes(connection) == 1 else { return }
    }
  }

  private func upsertDeviceOwnedRunActivityUnlocked(
    runID: String,
    activity update: AgentRunActivity,
    appendingContent: Bool,
    updatedAt: Date
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
      let activity = prior?.merging(update, appendingContent: appendingContent) ?? update
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
      guard sqlite3_changes(connection) == 1 else {
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
      guard sqlite3_changes(connection) == 1 else {
        throw LocalACPSessionDatabaseError.runNotFound
      }

      let message = try prepareUnlocked("""
        UPDATE dashboard_messages
        SET content = CASE
          WHEN content = '' AND ? IS NOT NULL THEN ?
          WHEN content = '' THEN 'The local agent completed without a text response.'
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
      guard sqlite3_changes(connection) == 1 else {
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
        """)
      defer { sqlite3_finalize(run) }
      try bind(timestamp, at: 1, to: run)
      try bind(timestamp, at: 2, to: run)
      try stepDone(run)
    }
  }

  private func insertNoteContextUnlocked(
    _ context: AgentNoteContext?,
    identifiers: LocalACPRunIdentifiers,
    conversationID: String,
    userID: String,
    governingPlane: String,
    authorityDeviceID: String?,
    authorityAgentID: String?,
    createdAt: Date
  ) throws {
    guard let context else { return }
    let timestamp = Self.timestamp(createdAt)
    let reference = try prepareUnlocked("""
      INSERT INTO dashboard_message_references (
        id, conversation_id, message_id, user_id, governing_plane,
        authority_kind, authority_device_id, authority_agent_id, desktop_owned,
        resource_type, resource_id, source, title_snapshot, folder_id_snapshot,
        revision_snapshot, created_at
      ) VALUES (?, ?, ?, ?, ?, 'device_owned', ?, ?, 1,
        'note', ?, 'open_note', ?, ?, ?, ?)
      """)
    defer { sqlite3_finalize(reference) }
    try bind(UUID().uuidString.lowercased(), at: 1, to: reference)
    try bind(conversationID, at: 2, to: reference)
    try bind(identifiers.userMessageID, at: 3, to: reference)
    try bind(userID, at: 4, to: reference)
    try bind(governingPlane, at: 5, to: reference)
    try bindNullable(authorityDeviceID, at: 6, to: reference)
    try bindNullable(authorityAgentID, at: 7, to: reference)
    try bind(context.noteID, at: 8, to: reference)
    try bind(context.title, at: 9, to: reference)
    try bindNullable(context.folderID, at: 10, to: reference)
    try bind(context.revision, at: 11, to: reference)
    try bind(timestamp, at: 12, to: reference)
    try stepDone(reference)

    let visibleContext = try prepareUnlocked("""
      INSERT INTO dashboard_run_visible_context (
        run_id, message_id, conversation_id, user_id, governing_plane,
        authority_kind, authority_device_id, authority_agent_id, desktop_owned,
        note_id, note_title_snapshot, folder_id_snapshot, revision_snapshot,
        created_at
      ) VALUES (?, ?, ?, ?, ?, 'device_owned', ?, ?, 1, ?, ?, ?, ?, ?)
      """)
    defer { sqlite3_finalize(visibleContext) }
    try bind(identifiers.runID, at: 1, to: visibleContext)
    try bind(identifiers.userMessageID, at: 2, to: visibleContext)
    try bind(conversationID, at: 3, to: visibleContext)
    try bind(userID, at: 4, to: visibleContext)
    try bind(governingPlane, at: 5, to: visibleContext)
    try bindNullable(authorityDeviceID, at: 6, to: visibleContext)
    try bindNullable(authorityAgentID, at: 7, to: visibleContext)
    try bind(context.noteID, at: 8, to: visibleContext)
    try bind(context.title, at: 9, to: visibleContext)
    try bindNullable(context.folderID, at: 10, to: visibleContext)
    try bind(context.revision, at: 11, to: visibleContext)
    try bind(timestamp, at: 12, to: visibleContext)
    try stepDone(visibleContext)

    if let nonce = context.remoteEditNonce,
       let kind = context.artifactKind {
      let pending = try prepareUnlocked("""
        INSERT INTO desktop_remote_note_edits (
          run_id, assistant_message_id, note_id, expected_revision,
          nonce, note_kind, state, created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?)
        """)
      defer { sqlite3_finalize(pending) }
      try bind(identifiers.runID, at: 1, to: pending)
      try bind(identifiers.assistantMessageID, at: 2, to: pending)
      try bind(context.noteID, at: 3, to: pending)
      try bind(context.revision, at: 4, to: pending)
      try bind(nonce, at: 5, to: pending)
      try bind(kind.rawValue, at: 6, to: pending)
      try bind(timestamp, at: 7, to: pending)
      try bind(timestamp, at: 8, to: pending)
      try stepDone(pending)
    }
  }

  public func pendingRemoteNoteEdits() throws -> [PendingRemoteNoteEdit] {
    try lock.withLock {
      let statement = try prepareUnlocked("""
        SELECT edit.run_id, edit.assistant_message_id, edit.note_id,
          edit.expected_revision, edit.nonce, edit.note_kind, message.content
        FROM desktop_remote_note_edits AS edit
        JOIN dashboard_runs AS run ON run.id = edit.run_id
        JOIN dashboard_messages AS message
          ON message.id = edit.assistant_message_id AND message.run_id = edit.run_id
        WHERE edit.state = 'pending' AND run.status = 'completed'
        ORDER BY edit.created_at, edit.run_id
        """)
      defer { sqlite3_finalize(statement) }
      var rows: [PendingRemoteNoteEdit] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let kind = try text(statement, column: 5)
        guard let noteKind = NoteArtifactKind(rawValue: kind) else { continue }
        rows.append(PendingRemoteNoteEdit(
          runID: try text(statement, column: 0),
          assistantMessageID: try text(statement, column: 1),
          noteID: try text(statement, column: 2),
          expectedRevision: try text(statement, column: 3),
          nonce: try text(statement, column: 4),
          noteKind: noteKind,
          assistantContent: try text(statement, column: 6)
        ))
      }
      return rows
    }
  }

  public func applyPendingRemoteNoteEdit(
    _ pending: PendingRemoteNoteEdit,
    envelope: RemoteNoteEditEnvelope,
    visibleAssistantContent: String
  ) throws -> NoteEditingResponse {
    try transaction {
      let authorization = try prepareUnlocked("""
        SELECT run.status
        FROM desktop_remote_note_edits AS edit
        JOIN dashboard_runs AS run ON run.id = edit.run_id
        JOIN dashboard_run_visible_context AS context ON context.run_id = edit.run_id
        WHERE edit.run_id = ? AND edit.state = 'pending'
          AND edit.assistant_message_id = ? AND edit.note_id = ?
          AND edit.expected_revision = ? AND edit.nonce = ? AND edit.note_kind = ?
          AND context.note_id = edit.note_id
          AND context.revision_snapshot = edit.expected_revision
        """)
      defer { sqlite3_finalize(authorization) }
      try bind(pending.runID, at: 1, to: authorization)
      try bind(pending.assistantMessageID, at: 2, to: authorization)
      try bind(pending.noteID, at: 3, to: authorization)
      try bind(pending.expectedRevision, at: 4, to: authorization)
      try bind(pending.nonce, at: 5, to: authorization)
      try bind(pending.noteKind.rawValue, at: 6, to: authorization)
      guard sqlite3_step(authorization) == SQLITE_ROW,
            try text(authorization, column: 0) == "completed",
            envelope.nonce == pending.nonce,
            envelope.noteID == pending.noteID,
            envelope.expectedRevision == pending.expectedRevision else {
        throw RemoteNoteEditError.invalidEnvelope
      }
      let operatorID = try localMutationOperatorIDUnlocked()
      let note = try noteForEditingUnlocked(id: pending.noteID, operatorID: operatorID)
      guard note.revision == pending.expectedRevision else {
        throw WorkspaceNoteMutationError.revisionConflict
      }
      try envelope.validateApplying(to: NoteDocument.decode(note.content))
      let response = try applyNoteEditsUnlocked(NoteEditingRequest(
        command: .apply,
        noteID: pending.noteID,
        expectedRevision: pending.expectedRevision,
        operations: envelope.operations
      ))
      let timestamp = Self.timestamp(Date())
      let message = try prepareUnlocked("""
        UPDATE dashboard_messages SET content = ?, updated_at = ?
        WHERE id = ? AND run_id = ? AND role = 'assistant'
        """)
      defer { sqlite3_finalize(message) }
      try bind(visibleAssistantContent, at: 1, to: message)
      try bind(timestamp, at: 2, to: message)
      try bind(pending.assistantMessageID, at: 3, to: message)
      try bind(pending.runID, at: 4, to: message)
      try stepDone(message)
      guard sqlite3_changes(connection) == 1 else {
        throw RemoteNoteEditError.invalidEnvelope
      }
      let conversation = try prepareUnlocked("""
        UPDATE dashboard_conversations
        SET last_message_preview = ?, updated_at = ?
        WHERE id = (
          SELECT conversation_id FROM dashboard_messages WHERE id = ?
        ) AND NOT EXISTS (
          SELECT 1 FROM dashboard_messages AS newer
          WHERE newer.conversation_id = dashboard_conversations.id
            AND newer.created_at > (
              SELECT created_at FROM dashboard_messages WHERE id = ?
            )
        )
        """)
      defer { sqlite3_finalize(conversation) }
      try bind(Self.localPreview(visibleAssistantContent), at: 1, to: conversation)
      try bind(timestamp, at: 2, to: conversation)
      try bind(pending.assistantMessageID, at: 3, to: conversation)
      try bind(pending.assistantMessageID, at: 4, to: conversation)
      try stepDone(conversation)
      let complete = try prepareUnlocked("""
        UPDATE desktop_remote_note_edits
        SET state = 'applied', updated_at = ?
        WHERE run_id = ? AND state = 'pending'
        """)
      defer { sqlite3_finalize(complete) }
      try bind(timestamp, at: 1, to: complete)
      try bind(pending.runID, at: 2, to: complete)
      try stepDone(complete)
      guard sqlite3_changes(connection) == 1 else {
        throw RemoteNoteEditError.invalidEnvelope
      }
      return response
    }
  }

  public func dismissPendingRemoteNoteEdit(runID: String) throws {
    try transaction {
      let lookup = try prepareUnlocked("""
        SELECT message.id, message.content
        FROM desktop_remote_note_edits AS edit
        JOIN dashboard_messages AS message
          ON message.id = edit.assistant_message_id AND message.run_id = edit.run_id
        WHERE edit.run_id = ? AND edit.state = 'pending'
        """)
      defer { sqlite3_finalize(lookup) }
      try bind(runID, at: 1, to: lookup)
      let timestamp = Self.timestamp(Date())
      if sqlite3_step(lookup) == SQLITE_ROW {
        let messageID = try text(lookup, column: 0)
        let visible = RemoteNoteEditEnvelope.redactingEnvelopes(
          in: try text(lookup, column: 1)
        )
        let message = try prepareUnlocked("""
          UPDATE dashboard_messages SET content = ?, updated_at = ? WHERE id = ?
          """)
        defer { sqlite3_finalize(message) }
        try bind(visible, at: 1, to: message)
        try bind(timestamp, at: 2, to: message)
        try bind(messageID, at: 3, to: message)
        try stepDone(message)
        let conversation = try prepareUnlocked("""
          UPDATE dashboard_conversations SET last_message_preview = ?, updated_at = ?
          WHERE id = (SELECT conversation_id FROM dashboard_messages WHERE id = ?)
            AND NOT EXISTS (
              SELECT 1 FROM dashboard_messages AS newer
              WHERE newer.conversation_id = dashboard_conversations.id
                AND newer.created_at > (
                  SELECT created_at FROM dashboard_messages WHERE id = ?
                )
            )
          """)
        defer { sqlite3_finalize(conversation) }
        try bind(Self.localPreview(visible), at: 1, to: conversation)
        try bind(timestamp, at: 2, to: conversation)
        try bind(messageID, at: 3, to: conversation)
        try bind(messageID, at: 4, to: conversation)
        try stepDone(conversation)
      }
      let statement = try prepareUnlocked("""
        UPDATE desktop_remote_note_edits SET state = 'dismissed', updated_at = ?
        WHERE run_id = ? AND state = 'pending'
        """)
      defer { sqlite3_finalize(statement) }
      try bind(timestamp, at: 1, to: statement)
      try bind(runID, at: 2, to: statement)
      try stepDone(statement)
    }
  }

  public func dismissTerminalRemoteNoteEdits() throws {
    let runIDs = try lock.withLock {
      let statement = try prepareUnlocked("""
        SELECT edit.run_id FROM desktop_remote_note_edits AS edit
        JOIN dashboard_runs AS run ON run.id = edit.run_id
        WHERE edit.state = 'pending' AND run.status IN ('failed', 'cancelled')
        """)
      defer { sqlite3_finalize(statement) }
      var values: [String] = []
      while sqlite3_step(statement) == SQLITE_ROW {
        values.append(try text(statement, column: 0))
      }
      return values
    }
    for runID in runIDs {
      try dismissPendingRemoteNoteEdit(runID: runID)
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

  private static func localPreview(_ content: String) -> String {
    let compact = content
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String(compact.prefix(240))
  }

  @discardableResult
  public func createFolder(
    id: UUID = UUID(),
    name: String,
    operationID: UUID = UUID(),
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
    operationID: UUID = UUID(),
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
      guard sqlite3_changes(connection) == 1 else {
        throw WorkspaceFolderMutationError.folderNotFound
      }

      return true
    }
  }

  @discardableResult
  public func setFolderPinned(
    id: String,
    isPinned: Bool,
    operationID: UUID = UUID(),
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
      guard sqlite3_changes(connection) == 1 else {
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
      var changedIDs: [String] = []
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
        guard sqlite3_changes(connection) == 1 else {
          throw WorkspaceFolderMutationError.folderNotFound
        }
        changedIDs.append(folder.id)
      }

      return !changedIDs.isEmpty
    }
  }

  @discardableResult
  public func deleteFolder(
    id: String,
    operationID: UUID = UUID(),
    deletedAt: Date = Date()
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
      guard sqlite3_changes(connection) == 1 else {
        throw WorkspaceFolderMutationError.folderNotFound
      }

      return true
    }
  }

  @discardableResult
  public func createNote(
    id: UUID = UUID(),
    folderID: String?,
    title: String = "Untitled Note",
    content: String = "",
    kind: NoteArtifactKind = .note,
    operationID: UUID = UUID(),
    createdAt: Date = Date()
  ) throws -> String {
    try transaction {
      let content = try (content.isEmpty
        ? NoteDocument(kind: kind)
        : NoteDocument.decode(content)).encoded()
      let noteID = id.uuidString.lowercased()
      let operatorID = try localMutationOperatorIDUnlocked()
      try validateFolderUnlocked(id: folderID, operatorID: operatorID)
      let timestamp = Self.timestamp(createdAt)
      let position = try nextNotePositionUnlocked(
        folderID: folderID,
        operatorID: operatorID
      )

      let note = try prepareUnlocked("""
        INSERT INTO notes (
          id, user_id, folder_id, title, content, snippet, is_pinned, position,
          created_at, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
        """)
      defer { sqlite3_finalize(note) }
      try bind(noteID, at: 1, to: note)
      try bind(operatorID, at: 2, to: note)
      try bindNullable(folderID, at: 3, to: note)
      try bind(title, at: 4, to: note)
      try bind(content, at: 5, to: note)
      try bind(Self.noteSnippet(content), at: 6, to: note)
      guard sqlite3_bind_int64(note, 7, Int64(position)) == SQLITE_OK else {
        throw bindError()
      }
      try bind(timestamp, at: 8, to: note)
      try bind(timestamp, at: 9, to: note)
      try stepDone(note)

      return noteID
    }
  }

  @discardableResult
  public func updateNote(
    id: String,
    title: String,
    content: String,
    operationID: UUID = UUID(),
    updatedAt: Date = Date()
  ) throws -> Bool {
    try transaction {
      let content = try NoteDocument.decode(content).encoded()
      let operatorID = try localMutationOperatorIDUnlocked()
      let update = try prepareUnlocked("""
        UPDATE notes
        SET title = ?, content = ?, snippet = ?, updated_at = ?
        WHERE id = ? AND user_id = ? AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(update) }
      try bind(title, at: 1, to: update)
      try bind(content, at: 2, to: update)
      try bind(Self.noteSnippet(content), at: 3, to: update)
      try bind(Self.timestamp(updatedAt), at: 4, to: update)
      try bind(id, at: 5, to: update)
      try bind(operatorID, at: 6, to: update)
      try stepDone(update)
      guard sqlite3_changes(connection) == 1 else {
        throw WorkspaceNoteMutationError.noteNotFound
      }

      return true
    }
  }

  @discardableResult
  public func persistNoteDraft(
    id: String,
    title: String,
    content: String,
    folderID: String? = nil,
    createdAt: String? = nil,
    operationID: UUID = UUID(),
    updatedAt: Date = Date()
  ) throws -> Bool {
    try transaction {
      let content = try NoteDocument.decode(content).encoded()
      let operatorID = try localMutationOperatorIDUnlocked()
      let timestamp = Self.timestamp(updatedAt)
      let update = try prepareUnlocked("""
        UPDATE notes
        SET title = ?, content = ?, snippet = ?, updated_at = ?
        WHERE id = ? AND user_id = ? AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(update) }
      try bind(title, at: 1, to: update)
      try bind(content, at: 2, to: update)
      try bind(Self.noteSnippet(content), at: 3, to: update)
      try bind(timestamp, at: 4, to: update)
      try bind(id, at: 5, to: update)
      try bind(operatorID, at: 6, to: update)
      try stepDone(update)

      let restoredMissingNote = sqlite3_changes(connection) != 1
      if restoredMissingNote {
        try validateFolderUnlocked(id: folderID, operatorID: operatorID)
        let position = try nextNotePositionUnlocked(
          folderID: folderID,
          operatorID: operatorID
        )
        let insert = try prepareUnlocked("""
          INSERT INTO notes (
            id, user_id, folder_id, title, content, snippet, is_pinned,
            position, created_at, updated_at
          ) VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?)
          """)
        defer { sqlite3_finalize(insert) }
        try bind(id, at: 1, to: insert)
        try bind(operatorID, at: 2, to: insert)
        try bindNullable(folderID, at: 3, to: insert)
        try bind(title, at: 4, to: insert)
        try bind(content, at: 5, to: insert)
        try bind(Self.noteSnippet(content), at: 6, to: insert)
        guard sqlite3_bind_int64(insert, 7, Int64(position)) == SQLITE_OK else {
          throw bindError()
        }
        try bind(createdAt ?? timestamp, at: 8, to: insert)
        try bind(timestamp, at: 9, to: insert)
        try stepDone(insert)
      }

      return true
    }
  }

  public func readNoteForEditing(id: String) throws -> NoteEditingResponse {
    try lock.withLock {
      let operatorID = try localMutationOperatorIDUnlocked()
      let note = try noteForEditingUnlocked(id: id, operatorID: operatorID)
      return NoteEditingResponse(
        success: true,
        noteID: id,
        title: note.title,
        revision: note.revision,
        document: NoteDocument.decode(note.content)
      )
    }
  }

  public func applyNoteEdits(_ request: NoteEditingRequest) throws -> NoteEditingResponse {
    try transaction {
      try applyNoteEditsUnlocked(request)
    }
  }

  private func applyNoteEditsUnlocked(
    _ request: NoteEditingRequest
  ) throws -> NoteEditingResponse {
    let operatorID = try localMutationOperatorIDUnlocked()
    let note = try noteForEditingUnlocked(id: request.noteID, operatorID: operatorID)
    if let expected = request.expectedRevision, expected != note.revision {
      throw WorkspaceNoteMutationError.revisionConflict
    }
    guard !request.operations.isEmpty else {
      return NoteEditingResponse(
        success: true, noteID: request.noteID, title: note.title,
        revision: note.revision, document: NoteDocument.decode(note.content)
      )
    }
    var document = NoteDocument.decode(note.content)
    if document.kind == .html,
       request.operations.contains(where: {
         if case .setTitle = $0 { true } else { false }
       }) {
      throw NoteEditError.artifactKindMismatch
    }
    let updatedTitle = try document.apply(request.operations) ?? note.title
    let content = try document.encoded()
    let revision = Self.timestamp(Date())
    let update = try prepareUnlocked("""
      UPDATE notes SET title = ?, content = ?, snippet = ?, updated_at = ?
      WHERE id = ? AND user_id = ? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(update) }
    try bind(updatedTitle, at: 1, to: update)
    try bind(content, at: 2, to: update)
    try bind(Self.noteSnippet(content), at: 3, to: update)
    try bind(revision, at: 4, to: update)
    try bind(request.noteID, at: 5, to: update)
    try bind(operatorID, at: 6, to: update)
    try stepDone(update)
    guard sqlite3_changes(connection) == 1 else {
      throw WorkspaceNoteMutationError.noteNotFound
    }
    return NoteEditingResponse(
      success: true, noteID: request.noteID, title: updatedTitle,
      revision: revision, document: document
    )
  }

  public func workspaceSnapshot() throws -> WorkspaceSnapshot {
    try workspaceSnapshot(includeConversationContent: true)
  }

  public func workspaceOverview() throws -> WorkspaceSnapshot {
    try workspaceSnapshot(includeConversationContent: false)
  }

  public func dashboardRecordCounts() throws -> DashboardRecordCounts {
    try lock.withLock {
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
        calendarItems: count("dashboard_calendar_items", where: scoped)
      )
    }
  }

  public func calendarItems() throws -> [WorkspaceCalendarItemRecord] {
    try lock.withLock {
      guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked() else { return [] }
      return try decodeCanonicalRowsUnlocked(
        """
        SELECT json_object(
          'id', id, 'user_id', user_id, 'kind', kind, 'title', title,
          'description', description, 'starts_at', starts_at,
          'ends_at', ends_at, 'all_day', all_day, 'status', status,
          'source', source, 'created_at', created_at, 'updated_at', updated_at
        )
        FROM dashboard_calendar_items
        WHERE user_id = ?
        ORDER BY starts_at, id
        """,
        operatorID: operatorID,
        as: WorkspaceCalendarItemRecord.self
      )
    }
  }

  @discardableResult
  public func createCalendarItem(
    id: UUID = UUID(),
    title: String,
    details: String? = nil,
    startsAt: Date,
    endsAt: Date?,
    allDay: Bool,
    operationID: UUID = UUID(),
    createdAt: Date = Date()
  ) throws -> String {
    let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedTitle.isEmpty else {
      throw WorkspaceCalendarMutationError.emptyTitle
    }
    if let endsAt, endsAt <= startsAt {
      throw WorkspaceCalendarMutationError.invalidDateRange
    }
    let normalizedDetails = details?.trimmingCharacters(in: .whitespacesAndNewlines)

    return try transaction {
      let itemID = id.uuidString.lowercased()
      let operatorID = try localMutationOperatorIDUnlocked()
      let timestamp = Self.timestamp(createdAt)
      let insert = try prepareUnlocked("""
        INSERT INTO dashboard_calendar_items (
          id, user_id, kind, title, description, starts_at, ends_at, all_day,
          status, source, created_at, updated_at
        ) VALUES (?, ?, 'event', ?, ?, ?, ?, ?, 'scheduled', 'user', ?, ?)
        """)
      defer { sqlite3_finalize(insert) }
      try bind(itemID, at: 1, to: insert)
      try bind(operatorID, at: 2, to: insert)
      try bind(normalizedTitle, at: 3, to: insert)
      try bindNullable(normalizedDetails?.isEmpty == true ? nil : normalizedDetails, at: 4, to: insert)
      try bind(Self.timestamp(startsAt), at: 5, to: insert)
      try bindNullable(endsAt.map(Self.timestamp), at: 6, to: insert)
      guard sqlite3_bind_int(insert, 7, allDay ? 1 : 0) == SQLITE_OK else {
        throw bindError()
      }
      try bind(timestamp, at: 8, to: insert)
      try bind(timestamp, at: 9, to: insert)
      try stepDone(insert)

      return itemID
    }
  }

  public func dashboardAgents() throws -> [WorkspaceAgent] {
    try lock.withLock {
      let operatorID = try canonicalWorkspaceOperatorIDUnlocked()
      let statement = try prepareUnlocked(operatorID == nil ? """
        SELECT id, user_id, codename, display_name, icon, execution_location,
          governing_plane, authority_kind, authority_device_id,
          runtime_kind, runtime_device_id, platform_codename, status,
          runtime_metadata_json, revision, created_at, updated_at, deleted_at
        FROM dashboard_agents
        WHERE deleted_at IS NULL
          AND (
            (governing_plane = 'wovenmatter_macos' AND runtime_device_id IS NULL)
            OR governing_plane = 'remote_workspace'
          )
        ORDER BY execution_location DESC, created_at, id
        """ : """
        SELECT id, user_id, codename, display_name, icon, execution_location,
          governing_plane, authority_kind, authority_device_id,
          runtime_kind, runtime_device_id, platform_codename, status,
          runtime_metadata_json, revision, created_at, updated_at, deleted_at
        FROM dashboard_agents
        WHERE (user_id = ? OR desktop_owned = 1) AND deleted_at IS NULL
          AND (
            (governing_plane = 'wovenmatter_macos' AND runtime_device_id IS NULL)
            OR governing_plane = 'remote_workspace'
          )
        ORDER BY execution_location DESC, created_at, id
        """)
      defer { sqlite3_finalize(statement) }
      if let operatorID {
        try bind(operatorID, at: 1, to: statement)
      }
      var agents: [WorkspaceAgent] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return agents }
        guard code == SQLITE_ROW else { throw stepError() }
        do {
          let rawID = try text(statement, column: 0)
          let rawLocation = try text(statement, column: 5)
          let rawPlane = try text(statement, column: 6)
          let rawAuthority = try text(statement, column: 7)
          let rawRuntime = try text(statement, column: 9)
          let rawStatus = try text(statement, column: 12)
          guard let location = AgentExecutionLocation(rawValue: rawLocation),
                let governingPlane = AgentGoverningPlane(rawValue: rawPlane),
                let authority = DataAuthorityKind(rawValue: rawAuthority),
                let runtime = AgentRuntimeKind(rawValue: rawRuntime),
                let status = AgentRuntimeStatus(rawValue: rawStatus) else {
            NSLog(
              "Ignoring incompatible dashboard agent projection id=%@ location=%@ runtime=%@ status=%@",
              rawID,
              rawLocation,
              rawRuntime,
              rawStatus
            )
            continue
          }
          guard let id = UUID(uuidString: rawID) else {
            NSLog("Ignoring local dashboard agent with invalid UUID id=%@", rawID)
            continue
          }
          let runtimeMetadata = Self.agentRuntimeMetadata(
            optionalText(statement, column: 13)
          )
          agents.append(WorkspaceAgent(
            id: id,
            userID: try text(statement, column: 1),
            codename: try text(statement, column: 2),
            displayName: try text(statement, column: 3),
            iconKey: try text(statement, column: 4),
            executionLocation: location,
            governingPlane: governingPlane,
            authorityKind: authority,
            authorityDeviceID: optionalText(statement, column: 8).flatMap(UUID.init(uuidString:)),
            runtimeKind: runtime,
            runtimeDeviceID: optionalText(statement, column: 10).flatMap(UUID.init(uuidString:)),
            platformCodename: optionalText(statement, column: 11),
            runtimeStatus: status,
            runtimeVersion: runtimeMetadata.runtimeVersion,
            imageDigest: runtimeMetadata.image,
            revision: sqlite3_column_int64(statement, 14),
            createdAt: Self.dashboardDate(optionalText(statement, column: 15)) ?? .distantPast,
            updatedAt: Self.dashboardDate(optionalText(statement, column: 16)) ?? .distantPast,
            deletedAt: Self.dashboardDate(optionalText(statement, column: 17))
          ))
        } catch WorkspaceDatabaseError.corruptRow {
          NSLog("Ignoring dashboard agent projection with missing required text")
        }
      }
    }
  }

  public func renameOpenClawAgent(
    id: UUID,
    displayName: String,
    updatedAt: Date = Date()
  ) throws {
    let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanName.isEmpty else {
      throw WorkspaceDatabaseError.execute("Enter a Woven Matter agent name.")
    }
    try transaction {
      let rawID = id.uuidString.lowercased()
      let ownership = try prepareUnlocked("""
        SELECT 1
        FROM dashboard_agents
        WHERE id = ? AND runtime_kind = 'openclaw'
          AND authority_kind = 'device_owned' AND desktop_owned = 1
          AND deleted_at IS NULL
        """)
      try bind(rawID, at: 1, to: ownership)
      let code = sqlite3_step(ownership)
      guard code == SQLITE_ROW else {
        sqlite3_finalize(ownership)
        throw code == SQLITE_DONE
          ? WorkspaceDatabaseError.execute("This OpenClaw is not owned by Woven Matter on this Mac.")
          : stepError()
      }
      sqlite3_finalize(ownership)

      let statement = try prepareUnlocked("""
        UPDATE dashboard_agents
        SET display_name = ?, revision = revision + 1, updated_at = ?
        WHERE id = ? AND display_name IS NOT ?
        """)
      defer { sqlite3_finalize(statement) }
      try bind(cleanName, at: 1, to: statement)
      try bind(Self.timestamp(updatedAt), at: 2, to: statement)
      try bind(rawID, at: 3, to: statement)
      try bind(cleanName, at: 4, to: statement)
      try stepDone(statement)
      guard sqlite3_changes(connection) == 1 else { return }
    }
  }

  private func workspaceSnapshot(includeConversationContent: Bool) throws -> WorkspaceSnapshot {
    try lock.withLock {
      var folders: [WorkspaceFolderRecord] = []
      var conversations: [WorkspaceConversationRecord] = []
      var messages: [WorkspaceMessageRecord] = []
      var notes: [WorkspaceNoteRecord] = []
      var runs: [WorkspaceRunRecord] = []
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
            'openclaw_session_key', openclaw_session_key,
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
        if includeConversationContent {
          messages = try decodeCanonicalRowsUnlocked(
            """
            SELECT json_object(
              'id', message.id, 'conversation_id', message.conversation_id,
              'client_message_id', message.client_message_id,
              'run_id', message.run_id, 'role', message.role,
              'governing_plane', message.governing_plane,
              'authority_device_id', message.authority_device_id,
              'content', message.content, 'status', message.status,
              'created_at', message.created_at, 'updated_at', message.updated_at
            )
            FROM dashboard_messages AS message
            JOIN dashboard_conversations AS conversation
              ON conversation.id = message.conversation_id
            WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
              AND conversation.deleted_at IS NULL
              AND conversation.is_archived = 0
              AND conversation.governing_plane = 'wovenmatter_macos'
            ORDER BY message.created_at, message.id
            """,
            operatorID: operatorID,
            as: WorkspaceMessageRecord.self
          )
        }
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
        if includeConversationContent {
          runs = try decodeCanonicalRowsUnlocked(
            """
            SELECT json_object(
              'id', run.id, 'conversation_id', run.conversation_id,
              'agent_id', run.agent_id,
              'governing_plane', run.governing_plane,
              'authority_device_id', run.authority_device_id,
              'user_message_id', run.user_message_id,
              'assistant_message_id', run.assistant_message_id,
              'status', run.status, 'error', run.error,
              'started_at', run.started_at, 'completed_at', run.completed_at,
              'created_at', run.created_at, 'updated_at', run.updated_at
            )
            FROM dashboard_runs AS run
            JOIN dashboard_conversations AS conversation
              ON conversation.id = run.conversation_id
            WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
              AND conversation.deleted_at IS NULL
              AND conversation.is_archived = 0
              AND conversation.governing_plane = 'wovenmatter_macos'
            ORDER BY run.created_at, run.id
            """,
            operatorID: operatorID,
            as: WorkspaceRunRecord.self
          )
        }
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
        messages: messages.sorted { $0.createdAt < $1.createdAt },
        notes: notes,
        runs: runs.sorted { ($0.createdAt ?? "") < ($1.createdAt ?? "") }
      )
    }
  }

  private static func dashboardDate(_ value: String?) -> Date? {
    guard let value, !value.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
  }

  private static func agentRuntimeMetadata(
    _ value: String?
  ) -> (runtimeVersion: String?, image: String?) {
    guard let value,
          let data = value.data(using: .utf8),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return (nil, nil)
    }
    return (
      object["runtimeVersion"] as? String ?? object["runtime_version"] as? String,
      object["image"] as? String
        ?? object["imageDigest"] as? String
        ?? object["image_digest"] as? String
    )
  }

  public func conversationContent(id: String) throws -> WorkspaceConversationContent {
    try lock.withLock {
      guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked() else {
        return WorkspaceConversationContent(conversationID: id, messages: [], runs: [])
      }
      let messages = try decodeCanonicalRowsUnlocked(
        """
        SELECT json_object(
          'id', message.id, 'conversation_id', message.conversation_id,
          'client_message_id', message.client_message_id,
          'run_id', message.run_id, 'role', message.role,
          'governing_plane', message.governing_plane,
          'authority_device_id', message.authority_device_id,
          'content', message.content, 'status', message.status,
          'created_at', message.created_at, 'updated_at', message.updated_at
        )
        FROM dashboard_messages AS message
        JOIN dashboard_conversations AS conversation
          ON conversation.id = message.conversation_id
        WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
          AND conversation.id = ?
          AND conversation.deleted_at IS NULL
          AND conversation.is_archived = 0
          AND conversation.governing_plane = 'wovenmatter_macos'
        ORDER BY message.created_at, message.id
        """,
        bindings: [operatorID, id],
        as: WorkspaceMessageRecord.self
      )
      let runs = try decodeCanonicalRowsUnlocked(
        """
        SELECT json_object(
          'id', run.id, 'conversation_id', run.conversation_id,
          'agent_id', run.agent_id,
          'governing_plane', run.governing_plane,
          'authority_device_id', run.authority_device_id,
          'user_message_id', run.user_message_id,
          'assistant_message_id', run.assistant_message_id,
          'status', run.status, 'error', run.error,
          'started_at', run.started_at, 'completed_at', run.completed_at,
          'created_at', run.created_at, 'updated_at', run.updated_at
        )
        FROM dashboard_runs AS run
        JOIN dashboard_conversations AS conversation
          ON conversation.id = run.conversation_id
        WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
          AND conversation.id = ?
          AND conversation.deleted_at IS NULL
          AND conversation.is_archived = 0
          AND conversation.governing_plane = 'wovenmatter_macos'
        ORDER BY run.created_at, run.id
        """,
        bindings: [operatorID, id],
        as: WorkspaceRunRecord.self
      )
      return WorkspaceConversationContent(
        conversationID: id,
        messages: messages,
        runs: runs,
        attachments: try messageAttachmentRecordsUnlocked(messageIDs: messages.map(\.id)),
        references: try messageReferenceRecordsUnlocked(messageIDs: messages.map(\.id))
      )
    }
  }

  public func conversationHistoryPage(
    id: String,
    before cursor: WorkspaceConversationHistoryCursor? = nil,
    limit: Int
  ) throws -> WorkspaceConversationHistoryPage {
    try lock.withLock {
      guard let operatorID = try canonicalWorkspaceOperatorIDUnlocked() else {
        return WorkspaceConversationHistoryPage(
          conversationID: id,
          messages: [],
          runs: [],
          hasOlderMessages: false
        )
      }
      let boundedLimit = min(max(limit, 1), 200)
      let cursorPredicate: String
      var bindings = [operatorID, id]
      if let cursor {
        cursorPredicate = """
          AND (
            message.created_at < ?
            OR (message.created_at = ? AND message.id < ?)
          )
          """
        bindings.append(contentsOf: [cursor.createdAt, cursor.createdAt, cursor.messageID])
      } else {
        cursorPredicate = ""
      }
      var newestFirst = try decodeCanonicalRowsUnlocked(
        """
        SELECT json_object(
          'id', message.id, 'conversation_id', message.conversation_id,
          'client_message_id', message.client_message_id,
          'run_id', message.run_id, 'role', message.role,
          'governing_plane', message.governing_plane,
          'authority_device_id', message.authority_device_id,
          'content', message.content, 'status', message.status,
          'created_at', message.created_at, 'updated_at', message.updated_at
        )
        FROM dashboard_messages AS message
        JOIN dashboard_conversations AS conversation
          ON conversation.id = message.conversation_id
        WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
          AND conversation.id = ?
          AND conversation.deleted_at IS NULL
          AND conversation.is_archived = 0
          \(cursorPredicate)
        ORDER BY message.created_at DESC, message.id DESC
        LIMIT \(boundedLimit + 1)
        """,
        bindings: bindings,
        as: WorkspaceMessageRecord.self
      )
      let hasOlderMessages = newestFirst.count > boundedLimit
      if hasOlderMessages {
        newestFirst.removeLast(newestFirst.count - boundedLimit)
      }
      let messages = Array(newestFirst.reversed())
      let messageIDs = messages.map(\.id)
      let runs: [WorkspaceRunRecord]
      let activities: [WorkspaceRunActivityRecord]
      let attachments: [WorkspaceMessageAttachmentRecord]
      let references: [WorkspaceMessageReferenceRecord]
      if messageIDs.isEmpty {
        runs = []
        activities = []
        attachments = []
        references = []
      } else {
        let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
        runs = try decodeCanonicalRowsUnlocked(
          """
          SELECT json_object(
            'id', run.id, 'conversation_id', run.conversation_id,
            'agent_id', run.agent_id,
            'governing_plane', run.governing_plane,
            'authority_device_id', run.authority_device_id,
            'user_message_id', run.user_message_id,
            'assistant_message_id', run.assistant_message_id,
            'status', run.status, 'error', run.error,
            'started_at', run.started_at, 'completed_at', run.completed_at,
            'created_at', run.created_at, 'updated_at', run.updated_at
          )
          FROM dashboard_runs AS run
          JOIN dashboard_conversations AS conversation
            ON conversation.id = run.conversation_id
          WHERE (conversation.user_id = ? OR conversation.desktop_owned = 1)
            AND conversation.id = ?
            AND conversation.deleted_at IS NULL
            AND conversation.is_archived = 0
            AND (
              run.user_message_id IN (\(placeholders))
              OR run.assistant_message_id IN (\(placeholders))
            )
          ORDER BY run.created_at, run.id
          """,
          bindings: [operatorID, id] + messageIDs + messageIDs,
          as: WorkspaceRunRecord.self
        )
        activities = try runActivityRecordsUnlocked(runIDs: runs.map(\.id))
        attachments = try messageAttachmentRecordsUnlocked(messageIDs: messageIDs)
        references = try messageReferenceRecordsUnlocked(messageIDs: messageIDs)
      }
      return WorkspaceConversationHistoryPage(
        conversationID: id,
        messages: messages,
        runs: runs,
        activities: activities,
        attachments: attachments,
        references: references,
        hasOlderMessages: hasOlderMessages
      )
    }
  }

  private func messageAttachmentRecordsUnlocked(
    messageIDs: [String]
  ) throws -> [WorkspaceMessageAttachmentRecord] {
    guard !messageIDs.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
    return try decodeCanonicalRowsUnlocked(
      """
      SELECT json_object(
        'id', id, 'conversation_id', conversation_id, 'message_id', message_id,
        'kind', kind, 'file_name', file_name, 'mime_type', mime_type,
        'size_bytes', size_bytes, 'content_hash', content_hash,
        'gateway_media_ref', gateway_media_ref, 'created_at', created_at
      )
      FROM dashboard_message_attachments
      WHERE message_id IN (\(placeholders))
      ORDER BY created_at, id
      """,
      bindings: messageIDs,
      as: WorkspaceMessageAttachmentRecord.self
    )
  }

  private func messageReferenceRecordsUnlocked(
    messageIDs: [String]
  ) throws -> [WorkspaceMessageReferenceRecord] {
    guard !messageIDs.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: messageIDs.count).joined(separator: ", ")
    return try decodeCanonicalRowsUnlocked(
      """
      SELECT json_object(
        'id', id, 'conversation_id', conversation_id, 'message_id', message_id,
        'resource_type', resource_type, 'resource_id', resource_id,
        'title_snapshot', title_snapshot, 'content_snapshot', content_snapshot,
        'revision_snapshot', revision_snapshot,
        'folder_id_snapshot', folder_id_snapshot,
        'folder_title_snapshot', folder_title_snapshot,
        'agent_codename_snapshot', agent_codename_snapshot,
        'created_at', created_at
      )
      FROM dashboard_message_references
      WHERE message_id IN (\(placeholders))
      ORDER BY created_at, id
      """,
      bindings: messageIDs,
      as: WorkspaceMessageReferenceRecord.self
    )
  }

  private func runActivityRecordsUnlocked(
    runIDs: [String]
  ) throws -> [WorkspaceRunActivityRecord] {
    guard !runIDs.isEmpty else { return [] }
    let placeholders = Array(repeating: "?", count: runIDs.count).joined(separator: ", ")
    var records: [WorkspaceRunActivityRecord] = []
    let events = try prepareUnlocked("""
      SELECT id, run_id, conversation_id, event_type, content, created_at
      FROM dashboard_run_events
      WHERE run_id IN (\(placeholders))
      ORDER BY created_at, id
      """)
    defer { sqlite3_finalize(events) }
    for (index, runID) in runIDs.enumerated() {
      try bind(runID, at: Int32(index + 1), to: events)
    }
    while true {
      let code = sqlite3_step(events)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let content = try text(events, column: 4)
      let activity: AgentRunActivity
      if let decoded = try? JSONDecoder().decode(
        AgentRunActivity.self,
        from: Data(content.utf8)
      ) {
        activity = decoded
      } else {
        activity = AgentRunActivity(
          id: try text(events, column: 0),
          kind: .progress,
          phase: "update",
          title: try text(events, column: 3),
          content: content
        )
      }
      records.append(WorkspaceRunActivityRecord(
        id: try text(events, column: 0),
        runID: try text(events, column: 1),
        conversationID: try text(events, column: 2),
        activity: activity,
        createdAt: try text(events, column: 5)
      ))
    }

    let traces = try prepareUnlocked("""
      SELECT id, run_id, conversation_id, event_type, event_name,
        event_phase, tool_name, content, raw_event_json, created_at
      FROM dashboard_run_trace_events
      WHERE run_id IN (\(placeholders))
        AND is_visible = 1
        AND event_type NOT IN ('assistant_delta', 'assistant_replace', 'done')
      ORDER BY created_at, seq, id
      """)
    defer { sqlite3_finalize(traces) }
    for (index, runID) in runIDs.enumerated() {
      try bind(runID, at: Int32(index + 1), to: traces)
    }
    while true {
      let code = sqlite3_step(traces)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let recordID = try text(traces, column: 0)
      let eventType = try text(traces, column: 3)
      let rawJSON = try text(traces, column: 8)
      let raw = (try? JSONSerialization.jsonObject(with: Data(rawJSON.utf8)))
      let payload = Self.tracePayload(raw)
      let data = Self.dictionary(payload?["data"])
      let activityID = Self.traceString(data?["itemId"])
        ?? Self.traceString(data?["toolCallId"])
        ?? recordID
      let kind: AgentRunActivity.Kind = switch eventType {
      case "reasoning": .thought
      case "tool_call", "tool_result": .tool
      case "plan": .plan
      case "file_change": .fileChange
      case "progress": .progress
      default: .activity
      }
      let content = optionalText(traces, column: 7)
      records.append(WorkspaceRunActivityRecord(
        id: "trace-\(recordID)",
        runID: try text(traces, column: 1),
        conversationID: try text(traces, column: 2),
        activity: AgentRunActivity(
          id: activityID,
          kind: kind,
          phase: optionalText(traces, column: 5),
          title: Self.traceString(data?["title"])
            ?? Self.traceString(data?["name"])
            ?? optionalText(traces, column: 4),
          detail: Self.traceDetail(data),
          status: Self.traceString(data?["status"]),
          toolName: optionalText(traces, column: 6),
          content: content,
          contentIsDelta: optionalText(traces, column: 4) == "reasoning.delta",
          locations: Self.traceLocations(data),
          changes: Self.traceFileChanges(data),
          planEntries: Self.tracePlanEntries(data),
          rawInputJSON: Self.traceJSONString(data?["rawInput"] ?? data?["args"]),
          rawOutputJSON: Self.traceJSONString(data?["rawOutput"] ?? data?["result"]),
          rawPayloadJSON: rawJSON
        ),
        createdAt: try text(traces, column: 9)
      ))
    }
    return records.sorted {
      if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
      return $0.id < $1.id
    }
  }

  private static func tracePayload(_ value: Any?) -> [String: Any]? {
    let object = dictionary(value)
    return dictionary(object?["payload"]) ?? object
  }

  private static func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  private static func traceString(_ value: Any?) -> String? {
    guard let value = value as? String else { return nil }
    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return clean.isEmpty ? nil : clean
  }

  private static func traceJSONString(_ value: Any?) -> String? {
    guard let value,
          JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func traceDetail(_ data: [String: Any]?) -> String? {
    let args = dictionary(data?["args"])
    let result = dictionary(data?["result"])
    let parts = [
      traceString(args?["command"]).map { "$ \($0)" },
      traceString(args?["cwd"]).map { "cwd: \($0)" },
      traceString(result?["status"]),
    ].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  private static func traceLocations(_ data: [String: Any]?) -> [AgentRunLocation] {
    (data?["locations"] as? [[String: Any]] ?? []).compactMap { location in
      guard let path = traceString(location["path"]) else { return nil }
      return AgentRunLocation(path: path, line: location["line"] as? Int)
    }
  }

  private static func traceFileChanges(_ data: [String: Any]?) -> [AgentRunFileChange] {
    let values = (data?["content"] as? [[String: Any]] ?? [])
      + (data?["changes"] as? [[String: Any]] ?? [])
      + ((data?["path"] != nil || data?["filename"] != nil) ? [data ?? [:]] : [])
    return values.compactMap { change in
      guard let path = traceString(change["path"]) ?? traceString(change["filename"])
      else { return nil }
      return AgentRunFileChange(
        path: path,
        oldText: (change["oldText"] as? String) ?? (change["old_text"] as? String),
        newText: (change["newText"] as? String) ?? (change["new_text"] as? String) ?? "",
        unifiedDiff: (change["unified_diff"] as? String) ?? (change["diff"] as? String)
      )
    }
  }

  private static func tracePlanEntries(_ data: [String: Any]?) -> [AgentRunPlanEntry] {
    (data?["entries"] as? [[String: Any]] ?? []).compactMap { entry in
      guard let content = traceString(entry["content"]),
            let status = traceString(entry["status"]) else { return nil }
      return AgentRunPlanEntry(
        content: content,
        priority: traceString(entry["priority"]),
        status: status
      )
    }
  }

  private func createWorkspaceCacheTablesUnlocked() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS profiles (
        id TEXT PRIMARY KEY, email TEXT, name TEXT, avatar_url TEXT, time_zone TEXT,
        theme TEXT, origin_device_id TEXT, created_at TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS surface_profiles (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '',
        surface TEXT NOT NULL CHECK (surface IN (
          'server_web', 'mac_native', 'web', 'mac'
        )),
        device_id TEXT, theme TEXT NOT NULL DEFAULT 'green',
        sidebar_style TEXT NOT NULL DEFAULT 'split',
        single_sidebar_side TEXT NOT NULL DEFAULT 'left',
        left_rail_visible INTEGER NOT NULL DEFAULT 1,
        right_rail_visible INTEGER NOT NULL DEFAULT 1,
        single_rail_visible INTEGER NOT NULL DEFAULT 1,
        chat_width_percent REAL NOT NULL DEFAULT 58,
        note_on_left INTEGER NOT NULL DEFAULT 0,
        workspace_mode TEXT NOT NULL DEFAULT 'chats',
        agent_order_json TEXT NOT NULL DEFAULT '[]',
        revision INTEGER NOT NULL DEFAULT 1,
        authority_kind TEXT NOT NULL DEFAULT 'device_owned',
        authority_device_id TEXT, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS folders (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '', name TEXT NOT NULL DEFAULT '',
        icon TEXT NOT NULL DEFAULT 'folder', position INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS notes (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '', folder_id TEXT,
        title TEXT NOT NULL DEFAULT 'Untitled Note', content TEXT NOT NULL DEFAULT '',
        snippet TEXT, is_favorite INTEGER NOT NULL DEFAULT 0,
        is_pinned INTEGER NOT NULL DEFAULT 0, position INTEGER NOT NULL DEFAULT 0,
        deleted_at TEXT, original_folder_id TEXT, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS dashboard_agents (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '', codename TEXT NOT NULL DEFAULT '',
        display_name TEXT NOT NULL DEFAULT '', role TEXT, description TEXT,
        icon TEXT NOT NULL DEFAULT 'bot', execution_location TEXT NOT NULL DEFAULT 'local',
        agent_bucket TEXT NOT NULL DEFAULT 'local_cli',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT,
        runtime_kind TEXT NOT NULL DEFAULT 'openclaw', runtime_device_id TEXT,
        platform_codename TEXT, model TEXT, fallback_model TEXT,
        status TEXT NOT NULL DEFAULT 'offline', is_primary INTEGER NOT NULL DEFAULT 0,
        runtime_metadata_json TEXT NOT NULL DEFAULT '{}', revision INTEGER NOT NULL DEFAULT 1,
        origin_device_id TEXT, deleted_at TEXT, created_at TEXT NOT NULL DEFAULT '',
        updated_at TEXT NOT NULL DEFAULT '', desktop_owned INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS dashboard_conversations (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '',
        agent_id TEXT, agent_codename TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, title TEXT NOT NULL DEFAULT 'New conversation',
        unread INTEGER NOT NULL DEFAULT 0, last_message_preview TEXT,
        openclaw_session_key TEXT, kind TEXT NOT NULL DEFAULT 'dashboard',
        is_deletable INTEGER NOT NULL DEFAULT 1,
        is_archived INTEGER NOT NULL DEFAULT 0, context_generation INTEGER NOT NULL DEFAULT 0,
        last_message_at TEXT NOT NULL DEFAULT '', folder_id TEXT, original_folder_id TEXT,
        is_pinned INTEGER NOT NULL DEFAULT 0, deleted_at TEXT, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
        desktop_owned INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS dashboard_messages (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '', client_message_id TEXT,
        run_id TEXT, role TEXT NOT NULL DEFAULT 'assistant',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT,
        message_source TEXT NOT NULL DEFAULT 'client_observed', content TEXT NOT NULL DEFAULT '',
        status TEXT NOT NULL DEFAULT 'completed', origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
        desktop_owned INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS dashboard_message_attachments (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
        message_id TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT 'file',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        file_name TEXT NOT NULL DEFAULT '', mime_type TEXT NOT NULL DEFAULT '',
        size_bytes INTEGER NOT NULL DEFAULT 0, content_hash TEXT, gateway_media_ref TEXT,
        origin_device_id TEXT, created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS dashboard_message_references (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
        message_id TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        resource_type TEXT NOT NULL DEFAULT 'note', resource_id TEXT NOT NULL DEFAULT '',
        source TEXT NOT NULL DEFAULT 'attached', title_snapshot TEXT NOT NULL DEFAULT '',
        content_snapshot TEXT NOT NULL DEFAULT '',
        folder_id_snapshot TEXT, folder_title_snapshot TEXT, agent_codename_snapshot TEXT,
        revision_snapshot TEXT NOT NULL DEFAULT '', origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS dashboard_runs (
        id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL DEFAULT '',
        user_id TEXT NOT NULL DEFAULT '', agent_id TEXT,
        agent_codename TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT,
        openclaw_session_key TEXT NOT NULL DEFAULT '', user_message_id TEXT,
        assistant_message_id TEXT, status TEXT NOT NULL DEFAULT 'queued', error TEXT,
        started_at TEXT, completed_at TEXT, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT '',
        desktop_owned INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS dashboard_run_visible_context (
        run_id TEXT PRIMARY KEY, message_id TEXT NOT NULL DEFAULT '',
        conversation_id TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        note_id TEXT NOT NULL DEFAULT '', note_title_snapshot TEXT NOT NULL DEFAULT '',
        folder_id_snapshot TEXT, folder_title_snapshot TEXT,
        revision_snapshot TEXT NOT NULL DEFAULT '', origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS desktop_remote_note_edits (
        run_id TEXT PRIMARY KEY, assistant_message_id TEXT NOT NULL,
        note_id TEXT NOT NULL, expected_revision TEXT NOT NULL,
        nonce TEXT NOT NULL, note_kind TEXT NOT NULL,
        state TEXT NOT NULL DEFAULT 'pending', error TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS dashboard_run_events (
        id TEXT PRIMARY KEY, run_id TEXT NOT NULL DEFAULT '',
        conversation_id TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        event_type TEXT NOT NULL DEFAULT '', content TEXT NOT NULL DEFAULT '',
        origin_device_id TEXT, created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS dashboard_run_trace_events (
        id TEXT PRIMARY KEY, run_id TEXT NOT NULL DEFAULT '',
        conversation_id TEXT NOT NULL DEFAULT '', user_id TEXT NOT NULL DEFAULT '',
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT, desktop_owned INTEGER NOT NULL DEFAULT 0,
        agent_codename TEXT NOT NULL DEFAULT '', openclaw_session_key TEXT NOT NULL DEFAULT '',
        seq INTEGER NOT NULL DEFAULT 0, event_source TEXT NOT NULL DEFAULT 'broker',
        event_type TEXT NOT NULL DEFAULT '', event_name TEXT, event_phase TEXT, tool_name TEXT,
        content TEXT, is_visible INTEGER NOT NULL DEFAULT 0,
        raw_event_json TEXT NOT NULL DEFAULT '{}', stream_event_json TEXT NOT NULL DEFAULT '[]',
        origin_device_id TEXT, created_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS dashboard_user_view_state (
        user_id TEXT PRIMARY KEY, selected_agent_codename TEXT,
        active_conversation_id TEXT, active_note_id TEXT, selected_folder_id TEXT,
        workspace_mode TEXT NOT NULL DEFAULT 'chats', pane_order TEXT NOT NULL DEFAULT 'chat-note',
        chat_width_percent REAL NOT NULL DEFAULT 58, agent_rail_collapsed INTEGER NOT NULL DEFAULT 0,
        inbox_collapsed INTEGER NOT NULL DEFAULT 0, origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE TABLE IF NOT EXISTS desktop_local_acp_sessions (
        conversation_id TEXT PRIMARY KEY, agent_id TEXT,
        runtime_kind TEXT NOT NULL,
        governing_plane TEXT NOT NULL DEFAULT 'wovenmatter_macos',
        authority_kind TEXT NOT NULL DEFAULT 'device_owned', authority_device_id TEXT,
        authority_agent_id TEXT,
        revision INTEGER NOT NULL DEFAULT 1,
        title TEXT NOT NULL,
        acp_session_id TEXT, model TEXT, thinking TEXT,
        buzz_workspace_link_id TEXT, buzz_agent_id TEXT,
        remote_workspace_id TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_local_identity (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        device_id TEXT NOT NULL,
        bound_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_buzz_workspace_links (
        id TEXT PRIMARY KEY,
        display_name TEXT NOT NULL,
        local_workspace_url TEXT NOT NULL,
        local_agent_store_url TEXT NOT NULL,
        is_enabled INTEGER NOT NULL DEFAULT 1
          CHECK (is_enabled IN (0, 1)),
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_buzz_agent_enrollments (
        id TEXT PRIMARY KEY,
        workspace_link_id TEXT NOT NULL,
        agent_id TEXT NOT NULL,
        handle_snapshot TEXT NOT NULL,
        display_name_snapshot TEXT NOT NULL,
        harness_identifier TEXT NOT NULL,
        runtime_kind TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        UNIQUE (workspace_link_id, agent_id),
        FOREIGN KEY (workspace_link_id)
          REFERENCES desktop_buzz_workspace_links(id) ON DELETE CASCADE
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_gateway_links (
        agent_id TEXT PRIMARY KEY,
        location TEXT NOT NULL CHECK (location IN (
          'buzz_local', 'local_agent_workspace', 'remote_workspace'
        )),
        endpoint_url TEXT NOT NULL,
        authorization TEXT NOT NULL CHECK (authorization IN (
          'localService', 'remoteWorkspace'
        )),
        status TEXT NOT NULL,
        openclaw_version TEXT,
        last_connected_at TEXT,
        last_error TEXT,
        linked_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_gateway_sessions (
        conversation_id TEXT PRIMARY KEY,
        agent_id TEXT NOT NULL,
        session_key TEXT NOT NULL,
        model TEXT,
        thinking_level TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (conversation_id) REFERENCES dashboard_conversations(id)
          ON DELETE CASCADE
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_cron_jobs (
        agent_id TEXT NOT NULL,
        remote_job_id TEXT NOT NULL,
        name TEXT NOT NULL,
        schedule TEXT NOT NULL,
        enabled INTEGER NOT NULL CHECK (enabled IN (0, 1)),
        native_session_id TEXT,
        native_session_key TEXT,
        archive_state TEXT NOT NULL CHECK (archive_state IN ('active', 'deleted')),
        remote_payload BLOB NOT NULL,
        updated_at TEXT NOT NULL,
        PRIMARY KEY (agent_id, remote_job_id)
      );
      CREATE TABLE IF NOT EXISTS desktop_openclaw_cron_runs (
        agent_id TEXT NOT NULL,
        remote_run_id TEXT NOT NULL,
        remote_job_id TEXT NOT NULL,
        status TEXT NOT NULL,
        output TEXT,
        native_session_id TEXT,
        native_session_key TEXT,
        started_at TEXT,
        completed_at TEXT,
        remote_payload BLOB NOT NULL,
        PRIMARY KEY (agent_id, remote_run_id)
      );
      CREATE TABLE IF NOT EXISTS dashboard_calendar_items (
        id TEXT PRIMARY KEY, user_id TEXT NOT NULL DEFAULT '', kind TEXT NOT NULL DEFAULT '',
        title TEXT NOT NULL DEFAULT '', description TEXT, starts_at TEXT NOT NULL DEFAULT '',
        ends_at TEXT, all_day INTEGER NOT NULL DEFAULT 0, agent_codename TEXT,
        pinned_folder_id TEXT, delivery_folder_id TEXT, status TEXT NOT NULL DEFAULT 'scheduled',
        schedule_label TEXT, source TEXT NOT NULL DEFAULT 'user', origin_device_id TEXT,
        created_at TEXT NOT NULL DEFAULT '', updated_at TEXT NOT NULL DEFAULT ''
      );
      CREATE INDEX IF NOT EXISTS desktop_cache_conversations_user_last
        ON dashboard_conversations(user_id, is_archived, deleted_at, last_message_at DESC);
      CREATE INDEX IF NOT EXISTS desktop_cache_messages_conversation_created
        ON dashboard_messages(conversation_id, created_at);
      CREATE INDEX IF NOT EXISTS desktop_cache_messages_conversation_created_id
        ON dashboard_messages(conversation_id, created_at, id);
      CREATE INDEX IF NOT EXISTS desktop_cache_runs_conversation_user_message
        ON dashboard_runs(conversation_id, user_message_id);
      CREATE INDEX IF NOT EXISTS desktop_cache_runs_conversation_assistant_message
        ON dashboard_runs(conversation_id, assistant_message_id);
      CREATE INDEX IF NOT EXISTS desktop_cache_notes_user_updated
        ON notes(user_id, deleted_at, updated_at DESC);
      CREATE INDEX IF NOT EXISTS desktop_buzz_workspace_links_name
        ON desktop_buzz_workspace_links(display_name);
      CREATE INDEX IF NOT EXISTS desktop_buzz_agent_enrollments_workspace
        ON desktop_buzz_agent_enrollments(workspace_link_id, display_name_snapshot);
      CREATE INDEX IF NOT EXISTS desktop_openclaw_gateway_sessions_agent
        ON desktop_openclaw_gateway_sessions(agent_id, updated_at DESC);
      CREATE INDEX IF NOT EXISTS desktop_openclaw_cron_jobs_state
        ON desktop_openclaw_cron_jobs(agent_id, archive_state, updated_at DESC);
      CREATE INDEX IF NOT EXISTS desktop_openclaw_cron_runs_job
        ON desktop_openclaw_cron_runs(agent_id, remote_job_id, started_at DESC);
      """)
  }

  private func migrate() throws {
    try transaction {
      try createWorkspaceCacheTablesUnlocked()
      try addCurrentColumnsUnlocked()
      try createDashboardRevisionTrackingUnlocked()
    }
  }

  private func addCurrentColumnsUnlocked() throws {
    let statement = try prepareUnlocked(
      "PRAGMA table_info(desktop_local_acp_sessions)"
    )
    defer { sqlite3_finalize(statement) }
    var columns: Set<String> = []
    while sqlite3_step(statement) == SQLITE_ROW {
      if let name = optionalText(statement, column: 1) { columns.insert(name) }
    }
    if !columns.contains("remote_workspace_id") {
      try executeUnlocked(
        "ALTER TABLE desktop_local_acp_sessions ADD COLUMN remote_workspace_id TEXT"
      )
    }
  }

  private func createDashboardRevisionTrackingUnlocked() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS desktop_dashboard_revision (
        singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
        revision INTEGER NOT NULL DEFAULT 0
      );
      INSERT OR IGNORE INTO desktop_dashboard_revision (singleton, revision)
      VALUES (1, 0);
      """)
    for table in [
      "folders",
      "surface_profiles",
      "dashboard_agents",
      "dashboard_conversations",
      "dashboard_messages",
      "notes",
      "dashboard_runs",
      "dashboard_calendar_items",
      "desktop_local_acp_sessions",
      "desktop_buzz_workspace_links",
      "desktop_buzz_agent_enrollments",
      "desktop_openclaw_gateway_links",
      "desktop_openclaw_gateway_sessions",
      "desktop_openclaw_cron_jobs",
      "desktop_openclaw_cron_runs",
    ] {
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        let trigger = "desktop_dashboard_revision_\(table)_\(operation.lowercased())"
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS \(trigger)
          AFTER \(operation) ON \(table)
          BEGIN
            UPDATE desktop_dashboard_revision
            SET revision = revision + 1
            WHERE singleton = 1;
          END
          """)
      }
    }
  }

  private func execute(_ sql: String) throws {
    try lock.withLock { try executeUnlocked(sql) }
  }

  private func executeUnlocked(_ sql: String) throws {
    guard let connection else { throw WorkspaceDatabaseError.execute("Database is closed") }
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(connection, sql, nil, nil, &errorMessage) == SQLITE_OK else {
      let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(connection))
      sqlite3_free(errorMessage)
      throw WorkspaceDatabaseError.execute(message)
    }
  }

  private func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
    guard let connection else { throw WorkspaceDatabaseError.prepare("Database is closed") }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
      throw WorkspaceDatabaseError.prepare(String(cString: sqlite3_errmsg(connection)))
    }
    return statement
  }

  private func canonicalWorkspaceOperatorIDUnlocked() throws -> String? {
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

  private func localMutationOperatorIDUnlocked() throws -> String {
    try canonicalWorkspaceOperatorIDUnlocked() ?? "local-operator"
  }

  private func validateFolderUnlocked(id: String?, operatorID: String) throws {
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

  private func nextNotePositionUnlocked(
    folderID: String?,
    operatorID: String
  ) throws -> Int {
    let statement = try prepareUnlocked(folderID == nil ? """
      SELECT COALESCE(MAX(position), -1) + 1
      FROM notes
      WHERE user_id = ? AND folder_id IS NULL AND deleted_at IS NULL
      """ : """
      SELECT COALESCE(MAX(position), -1) + 1
      FROM notes
      WHERE user_id = ? AND folder_id = ? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(statement) }
    try bind(operatorID, at: 1, to: statement)
    if let folderID {
      try bind(folderID, at: 2, to: statement)
    }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw stepError() }
    return Int(sqlite3_column_int64(statement, 0))
  }

  private func noteForEditingUnlocked(
    id: String,
    operatorID: String
  ) throws -> (title: String, content: String, revision: String) {
    let statement = try prepareUnlocked("""
      SELECT title, content, updated_at
      FROM notes
      WHERE id = ? AND user_id = ? AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(operatorID, at: 2, to: statement)
    guard sqlite3_step(statement) == SQLITE_ROW else {
      throw WorkspaceNoteMutationError.noteNotFound
    }
    return (
      try text(statement, column: 0),
      try text(statement, column: 1),
      try text(statement, column: 2)
    )
  }

  private static func noteSnippet(_ content: String) -> String {
    let content = NoteDocument.decode(content).plainText
    let replacements: [(String, String, String.CompareOptions)] = [
      (#"</p>\s*<p[^>]*>"#, " ", .regularExpression),
      (#"<br\s*/?>"#, " ", [.regularExpression, .caseInsensitive]),
      (#"</li>\s*<li[^>]*>"#, " ", [.regularExpression, .caseInsensitive]),
      (#"<[^>]+>"#, "", .regularExpression),
      ("&nbsp;", " ", []),
      ("&amp;", "&", []),
      ("&lt;", "<", []),
      ("&gt;", ">", []),
      ("&quot;", "\"", []),
      ("&#39;", "'", []),
      ("&#x27;", "'", [.caseInsensitive]),
    ]
    var text = content
    for (source, replacement, options) in replacements {
      text = text.replacingOccurrences(
        of: source,
        with: replacement,
        options: options
      )
    }
    text = text
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return text.count > 180 ? "\(text.prefix(177))..." : text
  }

  private func decodeCanonicalRowsUnlocked<Value: Decodable>(
    _ sql: String,
    operatorID: String,
    bindCount: Int = 1,
    as type: Value.Type
  ) throws -> [Value] {
    try decodeCanonicalRowsUnlocked(
      sql,
      bindings: Array(repeating: operatorID, count: bindCount),
      as: type
    )
  }

  private func decodeCanonicalRowsUnlocked<Value: Decodable>(
    _ sql: String,
    bindings: [String],
    as type: Value.Type
  ) throws -> [Value] {
    let statement = try prepareUnlocked(sql)
    defer { sqlite3_finalize(statement) }
    for (offset, value) in bindings.enumerated() {
      try bind(value, at: Int32(offset + 1), to: statement)
    }
    let decoder = JSONDecoder()
    var values: [Value] = []
    while true {
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return values }
      guard code == SQLITE_ROW else { throw stepError() }
      do {
        values.append(try decoder.decode(Value.self, from: blob(statement, column: 0)))
      } catch {
        NSLog(
          "Ignoring incompatible cached %@ projection: %@",
          String(reflecting: Value.self),
          String(describing: error)
        )
      }
    }
  }

  private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
    guard sqlite3_bind_text(statement, index, value, -1, SQLITE_TRANSIENT) == SQLITE_OK else {
      throw bindError()
    }
  }

  private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
    if value.isEmpty {
      guard sqlite3_bind_zeroblob(statement, index, 0) == SQLITE_OK else {
        throw bindError()
      }
      return
    }
    let result = value.withUnsafeBytes { bytes in
      sqlite3_bind_blob(
        statement,
        index,
        bytes.baseAddress,
        Int32(bytes.count),
        SQLITE_TRANSIENT
      )
    }
    guard result == SQLITE_OK else { throw bindError() }
  }

  private func bindNullable(
    _ value: String?,
    at index: Int32,
    to statement: OpaquePointer
  ) throws {
    if let value {
      try bind(value, at: index, to: statement)
    } else if sqlite3_bind_null(statement, index) != SQLITE_OK {
      throw bindError()
    }
  }

  private func text(_ statement: OpaquePointer, column: Int32) throws -> String {
    guard let value = sqlite3_column_text(statement, column) else { throw WorkspaceDatabaseError.corruptRow }
    return String(cString: value)
  }

  private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
    sqlite3_column_text(statement, column).map { String(cString: $0) }
  }

  private func blob(_ statement: OpaquePointer, column: Int32) throws -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0 else { return Data() }
    guard let bytes = sqlite3_column_blob(statement, column) else { throw WorkspaceDatabaseError.corruptRow }
    return Data(bytes: bytes, count: count)
  }

  private func stepDone(_ statement: OpaquePointer) throws {
    guard sqlite3_step(statement) == SQLITE_DONE else { throw stepError() }
  }

  private func bindError() -> WorkspaceDatabaseError {
    .bind(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
  }

  private func stepError() -> WorkspaceDatabaseError {
    .step(connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Database is closed")
  }

  private static func formatter(includingFractionalSeconds: Bool) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = includingFractionalSeconds
      ? [.withInternetDateTime, .withFractionalSeconds]
      : [.withInternetDateTime]
    return formatter
  }

  private static func timestamp(_ date: Date) -> String {
    formatter(includingFractionalSeconds: true).string(from: date)
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

  private static func date(_ value: String) -> Date? {
    formatter(includingFractionalSeconds: true).date(from: value)
      ?? formatter(includingFractionalSeconds: false).date(from: value)
  }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension NSLock {
  func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try operation()
  }
}
