import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

// Agent identity, catalog reconciliation and display metadata.
extension WorkspaceDatabase {
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
    return deterministicAgentID(seed: seed)
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
    return deterministicAgentID(seed: seed)
  }

  private static func deterministicAgentID(seed: Data) -> String {
    var bytes = Array(SHA256.hash(data: seed).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x50
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let hex = bytes.map { String(format: "%02x", $0) }
    return [
      hex[0..<4].joined(), hex[4..<6].joined(), hex[6..<8].joined(),
      hex[8..<10].joined(), hex[10..<16].joined(),
    ].joined(separator: "-")
  }

  func ensureRemoteHarnessAgentUnlocked(
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
        display_name = CASE WHEN excluded.runtime_kind = 'opencode' THEN dashboard_agents.display_name ELSE excluded.display_name END,
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
    guard changedRowCountUnlocked == 1 else {
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

  func ensureLocalCLIAgentUnlocked(
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
    let changed = changedRowCountUnlocked == 1
    guard changed || agentAlreadyExisted else {
      throw WorkspaceDatabaseError.execute("Local CLI agent identity collision")
    }
    return id
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

  public func dashboardAgents() throws -> [WorkspaceAgent] {
    try withLock {
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
    }
  }

  public func renameHermesAgent(
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
        WHERE id = ? AND runtime_kind = 'hermes'
          AND authority_kind = 'device_owned' AND desktop_owned = 1
          AND deleted_at IS NULL
        """)
      try bind(rawID, at: 1, to: ownership)
      let code = sqlite3_step(ownership)
      guard code == SQLITE_ROW else {
        sqlite3_finalize(ownership)
        throw code == SQLITE_DONE
          ? WorkspaceDatabaseError.execute("This Hermes agent is not owned by Woven Matter on this Mac.")
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
    }
  }

  public func renameOpenCodeAgent(
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
        WHERE id = ? AND runtime_kind = 'opencode'
          AND authority_kind = 'device_owned' AND desktop_owned = 1
          AND deleted_at IS NULL
        """)
      defer { sqlite3_finalize(ownership) }
      try bind(rawID, at: 1, to: ownership)
      let code = sqlite3_step(ownership)
      guard code == SQLITE_ROW else {
        throw code == SQLITE_DONE
          ? WorkspaceDatabaseError.execute("This OpenCode is not owned by Woven Matter on this Mac.")
          : stepError()
      }

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
    }
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
}
