import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

extension WorkspaceDatabase {
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

  func reconcileBuzzWorkspaceAgentUnlocked(
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
    }
  }

}
