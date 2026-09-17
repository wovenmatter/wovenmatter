import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore


extension WorkspaceDatabase {
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
    let changed = sqlite3_changes(connection) == 1
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



  public func hermesResultConversation(agentID: UUID, jobID: String, runID: String) throws -> String? {
    try lock.withLock {
      let query=try prepareUnlocked("SELECT r.conversation_id FROM desktop_scheduled_result_receipts r JOIN dashboard_conversations c ON c.id=r.conversation_id WHERE r.provider='hermes' AND r.agent_id=? AND r.job_id=? AND r.run_id=? AND c.deleted_at IS NULL AND c.is_archived=0")
      defer { sqlite3_finalize(query) }
      for (index,value) in [agentID.uuidString.lowercased(),jobID,runID].enumerated() { try bind(value,at:Int32(index+1),to:query) }
      let code=sqlite3_step(query)
      if code == SQLITE_DONE { return nil }
      guard code == SQLITE_ROW else { throw stepError() }
      return try text(query,column:0)
    }
  }

  public func hermesResultRoutes(agentID: UUID) throws -> [String: String] {
    try lock.withLock {
      let query = try prepareUnlocked("SELECT job_id, destination FROM desktop_scheduled_result_routes WHERE provider='hermes' AND agent_id=?")
      defer { sqlite3_finalize(query) }
      try bind(agentID.uuidString.lowercased(), at: 1, to: query)
      var result: [String: String] = [:]
      while true {
        let code = sqlite3_step(query)
        if code == SQLITE_DONE { return result }
        guard code == SQLITE_ROW else { throw stepError() }
        result[try text(query, column: 0)] = try text(query, column: 1)
      }
    }
  }

  public func setHermesResultRoute(agentID: UUID, jobID: String, destination: String) throws {
    try transaction {
      if !destination.isEmpty && destination != "new" { try validateHermesResultDestinationUnlocked(agentID: agentID, conversationID: destination) }
      let query = try prepareUnlocked("INSERT INTO desktop_scheduled_result_routes VALUES('hermes',?,?,?) ON CONFLICT(provider,agent_id,job_id) DO UPDATE SET destination=excluded.destination")
      defer { sqlite3_finalize(query) }
      for (index, value) in [agentID.uuidString.lowercased(), jobID, destination].enumerated() { try bind(value, at: Int32(index+1), to: query) }
      try stepDone(query)
    }
  }

  private func validateHermesResultDestinationUnlocked(agentID: UUID, conversationID: String) throws {
    let query = try prepareUnlocked("SELECT 1 FROM dashboard_conversations c JOIN desktop_local_acp_sessions s ON s.conversation_id=c.id WHERE c.id=? AND s.agent_id=? AND s.runtime_kind='hermes' AND c.deleted_at IS NULL AND c.is_archived=0 AND c.desktop_owned=1")
    defer { sqlite3_finalize(query) }
    try bind(conversationID, at: 1, to: query); try bind(agentID.uuidString.lowercased(), at: 2, to: query)
    let code = sqlite3_step(query)
    if code == SQLITE_DONE { throw HermesGatewayError.message("Choose an available Hermes conversation in Cron Jobs.") }
    guard code == SQLITE_ROW else { throw stepError() }
  }

  @discardableResult
  public func collectHermesResult(agentID: UUID, jobID: String, runID: String, title: String, output: String,
                                 ownerDeviceID: UUID, remoteWorkspaceID: UUID? = nil, remoteWorkspaceName: String = "") throws -> String? {
    try transaction {
      let agent = agentID.uuidString.lowercased()
      let receipt = try prepareUnlocked("SELECT 1 FROM desktop_scheduled_result_receipts WHERE provider='hermes' AND agent_id=? AND job_id=? AND run_id=?")
      defer { sqlite3_finalize(receipt) }
      for (index, value) in [agent,jobID,runID].enumerated() { try bind(value, at: Int32(index+1), to: receipt) }
      let code = sqlite3_step(receipt)
      if code == SQLITE_ROW { return nil }
      guard code == SQLITE_DONE else { throw stepError() }
      let route = try prepareUnlocked("SELECT destination FROM desktop_scheduled_result_routes WHERE provider='hermes' AND agent_id=? AND job_id=?")
      defer { sqlite3_finalize(route) }
      try bind(agent, at: 1, to: route); try bind(jobID, at: 2, to: route)
      let routeCode = sqlite3_step(route)
      if routeCode == SQLITE_DONE { return nil }
      guard routeCode == SQLITE_ROW else { throw stepError() }
      let destination = try text(route,column:0)
      guard !destination.isEmpty else { return nil }
      let conversationID: String
      if destination == "new" {
        if let remoteWorkspaceID {
          conversationID = try createRemoteACPSessionUnlocked(runtimeKind:.hermes, remoteWorkspaceID:remoteWorkspaceID, remoteWorkspaceName:remoteWorkspaceName,title:title,ownerDeviceID:ownerDeviceID)
        } else {
          conversationID = try createLocalACPSessionUnlocked(runtimeKind:.hermes,title:title,ownerDeviceID:ownerDeviceID)
        }
      } else { conversationID = destination }
      try validateHermesResultDestinationUnlocked(agentID:agentID,conversationID:conversationID)
      let messageID = UUID().uuidString.lowercased()
      let now = Self.timestamp(Date())
      let message = try prepareUnlocked("""
        INSERT INTO dashboard_messages(id,conversation_id,role,message_source,content,status,governing_plane,authority_kind,authority_device_id,authority_agent_id,created_at,updated_at,desktop_owned)
        SELECT ?,id,'assistant','scheduled_result',?,'completed',governing_plane,authority_kind,authority_device_id,authority_agent_id,?,?,1 FROM dashboard_conversations WHERE id=?
        """)
      defer { sqlite3_finalize(message) }
      for (index,value) in [messageID,output,now,now,conversationID].enumerated() { try bind(value,at:Int32(index+1),to:message) }
      try stepDone(message)
      let touch = try prepareUnlocked("UPDATE dashboard_conversations SET unread=1,last_message_at=MAX(last_message_at,?),last_message_preview=?,updated_at=? WHERE id=?")
      defer { sqlite3_finalize(touch) }
      for (index,value) in [now,String(output.prefix(240)),now,conversationID].enumerated() { try bind(value,at:Int32(index+1),to:touch) }
      try stepDone(touch)
      let ack = try prepareUnlocked("INSERT INTO desktop_scheduled_result_receipts VALUES('hermes',?,?,?,?,?,?)")
      defer { sqlite3_finalize(ack) }
      for (index,value) in [agent,jobID,runID,conversationID,messageID,now].enumerated() { try bind(value,at:Int32(index+1),to:ack) }
      try stepDone(ack)
      return conversationID
    }
  }

  public func knownHermesSessionIDs(home: String) throws -> Set<String> {
    try lock.withLock {
      let statement = try prepareUnlocked("SELECT acp_session_id FROM desktop_local_acp_sessions WHERE runtime_kind='hermes' AND acp_session_id IS NOT NULL")
      defer { sqlite3_finalize(statement) }
      var result: Set<String> = []
      while sqlite3_step(statement) == SQLITE_ROW {
        let parsed = HermesGatewayClient.parseIdentity(try text(statement, column: 0))
        if parsed.home == nil || parsed.home == home { result.insert(parsed.storedID) }
      }
      return result
    }
  }

  @discardableResult
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

}
