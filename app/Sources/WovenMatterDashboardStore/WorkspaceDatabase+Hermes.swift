import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

// Hermes session discovery and scheduled-result delivery.
extension WorkspaceDatabase {
  public func hermesResultConversation(agentID: UUID, jobID: String, runID: String) throws -> String? {
    try withLock {
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
    try withLock {
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
    try withLock {
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
}
