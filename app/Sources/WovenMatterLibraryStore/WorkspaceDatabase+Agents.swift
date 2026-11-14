#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterClient
import WovenMatterCore

// Agent identity, catalog reconciliation and display metadata.
extension WorkspaceDatabaseConnection {
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
      INSERT INTO agents (
        id, codename, display_name, icon, execution_location, owner_device_id,
        runtime_kind, runtime_device_id, platform_codename,
        status, revision, created_at, updated_at
      ) VALUES (?, ?, ?, 'container', 'remote', ?, ?, ?, ?, ?, 1, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        codename = excluded.codename,
        display_name = CASE WHEN excluded.runtime_kind = 'opencode' THEN agents.display_name ELSE excluded.display_name END,
        icon = excluded.icon,
        execution_location = excluded.execution_location,
        owner_device_id = excluded.owner_device_id,
        runtime_kind = excluded.runtime_kind,
        runtime_device_id = excluded.runtime_device_id,
        platform_codename = excluded.platform_codename,
        status = excluded.status,
        revision = agents.revision + 1,
        updated_at = excluded.updated_at,
        deleted_at = NULL
      WHERE agents.execution_location = 'remote'
        AND agents.runtime_device_id = excluded.runtime_device_id
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(codename, at: 2, to: statement)
    try bind(displayName, at: 3, to: statement)
    try bind(ownerDeviceID.uuidString.lowercased(), at: 4, to: statement)
    try bind(runtimeKind.rawValue, at: 5, to: statement)
    try bind(workspaceID, at: 6, to: statement)
    try bind(platformCodename, at: 7, to: statement)
    try bind(status.rawValue, at: 8, to: statement)
    try bind(timestamp, at: 9, to: statement)
    try bind(timestamp, at: 10, to: statement)
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
      SELECT status FROM agents WHERE id = ?
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
      INSERT INTO agents (
        id, codename, display_name, icon, execution_location, owner_device_id,
        runtime_kind, status, revision, created_at, updated_at
      ) VALUES (?, ?, ?, 'terminal', 'local', ?, ?, ?, 1, ?, ?)
      ON CONFLICT(id) DO UPDATE SET
        codename = excluded.codename,
        display_name = agents.display_name,
        icon = excluded.icon,
        execution_location = excluded.execution_location,
        owner_device_id = excluded.owner_device_id,
        runtime_kind = excluded.runtime_kind,
        status = excluded.status,
        revision = agents.revision + 1,
        updated_at = excluded.updated_at,
        deleted_at = NULL
      WHERE agents.execution_location = 'local'
        AND (
          agents.codename IS NOT excluded.codename
          OR agents.icon IS NOT excluded.icon
          OR agents.execution_location IS NOT excluded.execution_location
          OR agents.owner_device_id IS NOT excluded.owner_device_id
          OR agents.runtime_kind IS NOT excluded.runtime_kind
          OR agents.status IS NOT excluded.status
          OR agents.deleted_at IS NOT NULL
        )
      """)
    defer { sqlite3_finalize(statement) }
    try bind(id, at: 1, to: statement)
    try bind(codename, at: 2, to: statement)
    try bind(runtimeKind.displayName, at: 3, to: statement)
    try bind(ownerDeviceID.uuidString.lowercased(), at: 4, to: statement)
    try bind(runtimeKind.rawValue, at: 5, to: statement)
    try bind(desiredStatus.rawValue, at: 6, to: statement)
    try bind(timestamp, at: 7, to: statement)
    try bind(timestamp, at: 8, to: statement)
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
      for definition in LocalACPRuntimeCatalog.definitions {
        _ = try ensureLocalCLIAgentUnlocked(
          runtimeKind: definition.runtimeKind,
          ownerDeviceID: ownerDeviceID,
          status: statuses[definition.runtimeKind],
          updatedAt: updatedAt
        )
      }
    }
  }

  public func workspaceAgents() throws -> [WorkspaceAgent] {
    try withLock {
      let statement = try prepareUnlocked("""
        SELECT id, codename, display_name, icon, execution_location, owner_device_id,
          runtime_kind, runtime_device_id, platform_codename, status,
          revision, created_at, updated_at, deleted_at
        FROM agents
        WHERE deleted_at IS NULL
          AND ((execution_location = 'local' AND runtime_device_id IS NULL) OR execution_location = 'remote')
        ORDER BY execution_location DESC, created_at, id
        """)
      defer { sqlite3_finalize(statement) }
      var agents: [WorkspaceAgent] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return agents }
        guard code == SQLITE_ROW else { throw stepError() }
        do {
          let rawID = try text(statement, column: 0)
          let rawLocation = try text(statement, column: 4)
          let rawRuntime = try text(statement, column: 6)
          let rawStatus = try text(statement, column: 9)
          guard let location = AgentExecutionLocation(rawValue: rawLocation),
                let runtime = AgentRuntimeKind(rawValue: rawRuntime),
                let status = AgentRuntimeStatus(rawValue: rawStatus) else {
            NSLog(
              "Ignoring incompatible agent id=%@ location=%@ runtime=%@ status=%@",
              rawID,
              rawLocation,
              rawRuntime,
              rawStatus
            )
            continue
          }
          guard let id = UUID(uuidString: rawID) else {
            NSLog("Ignoring agent with invalid UUID id=%@", rawID)
            continue
          }
          agents.append(WorkspaceAgent(
            id: id,
            codename: try text(statement, column: 1),
            displayName: runtime == .defaultAgent ? runtime.displayName : try text(statement, column: 2),
            iconKey: try text(statement, column: 3),
            executionLocation: location,
            ownerDeviceID: optionalText(statement, column: 5).flatMap(UUID.init(uuidString:)),
            runtimeKind: runtime,
            runtimeDeviceID: optionalText(statement, column: 7).flatMap(UUID.init(uuidString:)),
            platformCodename: optionalText(statement, column: 8),
            runtimeStatus: status,
            revision: sqlite3_column_int64(statement, 10),
            createdAt: Self.storedDate(optionalText(statement, column: 11)) ?? .distantPast,
            updatedAt: Self.storedDate(optionalText(statement, column: 12)) ?? .distantPast,
            deletedAt: Self.storedDate(optionalText(statement, column: 13))
          ))
        } catch WorkspaceDatabaseError.corruptRow {
          NSLog("Ignoring agent row with missing required text")
        }
      }
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
        FROM agents
        WHERE id = ? AND runtime_kind = 'opencode' AND deleted_at IS NULL
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
        UPDATE agents
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

}

// MARK: - Async worker boundary

extension WorkspaceDatabase {
  @discardableResult
  public func ensureRemoteHarnessAgent(
    runtimeKind: AgentRuntimeKind,
    remoteWorkspaceID: UUID,
    remoteWorkspaceName: String,
    ownerDeviceID: UUID,
    status: AgentRuntimeStatus = .ready,
    updatedAt: Date = Date()
  ) async throws -> UUID {
    try await write { try $0.ensureRemoteHarnessAgent(runtimeKind: runtimeKind, remoteWorkspaceID: remoteWorkspaceID, remoteWorkspaceName: remoteWorkspaceName, ownerDeviceID: ownerDeviceID, status: status, updatedAt: updatedAt) }
  }

  public func reconcileLocalCLIAgentCatalog(
    ownerDeviceID: UUID,
    statuses: [AgentRuntimeKind: AgentRuntimeStatus] = [:],
    updatedAt: Date = Date()
  ) async throws {
    try await write { try $0.reconcileLocalCLIAgentCatalog(ownerDeviceID: ownerDeviceID, statuses: statuses, updatedAt: updatedAt) }
  }

  public func workspaceAgents() async throws -> [WorkspaceAgent] {
    try await read { try $0.workspaceAgents() }
  }



  public func renameOpenCodeAgent(
    id: UUID,
    displayName: String,
    updatedAt: Date = Date()
  ) async throws {
    try await write { try $0.renameOpenCodeAgent(id: id, displayName: displayName, updatedAt: updatedAt) }
  }
}
