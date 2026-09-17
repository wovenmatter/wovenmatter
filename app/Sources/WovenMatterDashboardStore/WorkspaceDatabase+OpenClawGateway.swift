import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore


extension WorkspaceDatabase {
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

  public func openClawGatewaySessions(agentID: UUID) throws -> [(conversationID: String, sessionKey: String)] {
    try lock.withLock {
      let statement = try prepareUnlocked("""
        SELECT s.conversation_id, s.session_key FROM desktop_openclaw_gateway_sessions s
        JOIN dashboard_conversations c ON c.id = s.conversation_id
        WHERE s.agent_id = ? AND c.deleted_at IS NULL AND c.is_archived = 0
        """)
      defer { sqlite3_finalize(statement) }
      try bind(agentID.uuidString.lowercased(), at: 1, to: statement)
      var rows: [(String, String)] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return rows }
        guard code == SQLITE_ROW else { throw stepError() }
        rows.append((try text(statement, column: 0), try text(statement, column: 1)))
      }
    }
  }

  /// Import the native session key directly; never synthesize a new upstream chat.
  public func importOpenClawGatewaySession(agentID: UUID, session: OpenClawGatewaySession) throws -> String {
    try transaction {
      let id = try importOpenClawGatewaySessionUnlocked(agentID: agentID, session: session)
      try markOpenClawImportActivityUnlocked(conversationID: id)
      return id
    }
  }

  /// All pages have already been fetched. Commit the complete import atomically;
  /// a failed page decode/database write leaves no partial imported conversation.
  func importOpenClawGatewaySession(agentID: UUID, session: OpenClawGatewaySession,
                                   historyPages: [URL], liveRunIDs: Set<String>) throws -> String {
    try transaction {
      let id = try importOpenClawGatewaySessionUnlocked(agentID: agentID, session: session)
      for page in historyPages {
        try Task.checkCancellation()
        let history = try JSONDecoder().decode(OpenClawGatewayHistory.self, from: Data(contentsOf: page))
        try synchronizeOpenClawHistoryUnlocked(conversationID: id, history: history, liveRunIDs: liveRunIDs)
      }
      try markOpenClawImportActivityUnlocked(conversationID: id)
      return id
    }
  }

  public func knownOpenClawSessionKeys(agentID: UUID) throws -> Set<String> {
    try knownSessionIDs(sql: "SELECT session_key FROM desktop_openclaw_gateway_sessions WHERE agent_id = ?", scope: agentID.uuidString.lowercased())
  }

  public func knownOpenCodeSessionIDs(connectionID: String) throws -> Set<String> {
    try knownSessionIDs(sql: "SELECT session_id FROM desktop_opencode_sessions WHERE connection_id = ?", scope: connectionID)
  }

  private func knownSessionIDs(sql: String, scope: String) throws -> Set<String> {
    try lock.withLock {
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

  private func markOpenClawImportActivityUnlocked(conversationID: String) throws {
    try markSessionImportedUnlocked(conversationID: conversationID)
    let timestamp = Self.timestamp(Date())
    let marker = try prepareUnlocked("INSERT INTO desktop_openclaw_import_activity (conversation_id, imported_at) VALUES (?, ?) ON CONFLICT(conversation_id) DO UPDATE SET imported_at = excluded.imported_at")
    defer { sqlite3_finalize(marker) }
    try bind(conversationID, at: 1, to: marker)
    try bind(timestamp, at: 2, to: marker)
    try stepDone(marker)
    let touch = try prepareUnlocked("UPDATE dashboard_conversations SET last_message_at = MAX(COALESCE(last_message_at, ''), ?), updated_at = ? WHERE id = ?")
    defer { sqlite3_finalize(touch) }
    try bind(timestamp, at: 1, to: touch)
    try bind(timestamp, at: 2, to: touch)
    try bind(conversationID, at: 3, to: touch)
    try stepDone(touch)
  }

  private func importOpenClawGatewaySessionUnlocked(agentID: UUID, session: OpenClawGatewaySession) throws -> String {
    let existing = try prepareUnlocked("""
      SELECT s.conversation_id FROM desktop_openclaw_gateway_sessions s
      JOIN dashboard_conversations c ON c.id = s.conversation_id
      WHERE s.agent_id = ? AND s.session_key = ? AND c.deleted_at IS NULL LIMIT 1
      """)
    defer { sqlite3_finalize(existing) }
    try bind(agentID.uuidString.lowercased(), at: 1, to: existing)
    try bind(session.key, at: 2, to: existing)
    let code = sqlite3_step(existing)
    if code == SQLITE_ROW {
      let id = try text(existing, column: 0)
      let restore = try prepareUnlocked("UPDATE dashboard_conversations SET is_archived = 0 WHERE id = ?")
      defer { sqlite3_finalize(restore) }
      try bind(id, at: 1, to: restore)
      try stepDone(restore)
      return id
    }
    guard code == SQLITE_DONE else { throw stepError() }
    let id = UUID().uuidString.lowercased()
    let timestamp = Self.timestamp(Date())
    let conversation = try prepareUnlocked("""
      INSERT INTO dashboard_conversations (
        id, user_id, agent_id, agent_codename, governing_plane, authority_kind,
        authority_device_id, authority_agent_id, title, kind, is_deletable,
        created_at, updated_at, last_message_at, desktop_owned
      ) SELECT ?, user_id, id, codename, 'wovenmatter_macos', 'device_owned',
        authority_device_id, id, ?, 'local_acp', 1, ?, ?, ?, 1
      FROM dashboard_agents WHERE id = ? AND desktop_owned = 1 AND deleted_at IS NULL
      """)
    defer { sqlite3_finalize(conversation) }
    for (index, value) in [id, session.title, timestamp, timestamp, timestamp, agentID.uuidString.lowercased()].enumerated() {
      try bind(value, at: Int32(index + 1), to: conversation)
    }
    try stepDone(conversation)
    guard sqlite3_changes(connection) == 1 else { throw LocalACPSessionDatabaseError.sessionNotFound }
    let local = try prepareUnlocked("""
      INSERT INTO desktop_local_acp_sessions (
        conversation_id, agent_id, runtime_kind, governing_plane, authority_kind,
        authority_device_id, authority_agent_id, title, acp_session_id, created_at, updated_at
      ) SELECT id, agent_id, 'openclaw', governing_plane, authority_kind,
        authority_device_id, authority_agent_id, title, ?, ?, ?
      FROM dashboard_conversations WHERE id = ?
      """)
    defer { sqlite3_finalize(local) }
    for (index, value) in [session.key, timestamp, timestamp, id].enumerated() {
      try bind(value, at: Int32(index + 1), to: local)
    }
    try stepDone(local)
    let gateway = try prepareUnlocked("""
      INSERT INTO desktop_openclaw_gateway_sessions
        (conversation_id, agent_id, session_key, created_at, updated_at) VALUES (?, ?, ?, ?, ?)
      """)
    defer { sqlite3_finalize(gateway) }
    for (index, value) in [id, agentID.uuidString.lowercased(), session.key, timestamp, timestamp].enumerated() {
      try bind(value, at: Int32(index + 1), to: gateway)
    }
    try stepDone(gateway)
    return id
  }

  public func openClawToolActivityIDs(runID: String) throws -> Set<String> {
    try lock.withLock {
      let query = try prepareUnlocked("SELECT json_extract(content, '$.id') FROM dashboard_run_events WHERE run_id = ? AND event_type = 'tool' AND json_valid(content)")
      defer { sqlite3_finalize(query) }
      try bind(runID, at: 1, to: query)
      var ids: Set<String> = []
      while true {
        let code = sqlite3_step(query)
        if code == SQLITE_DONE { return ids }
        guard code == SQLITE_ROW else { throw stepError() }
        if let id = optionalText(query, column: 0) { ids.insert(id) }
      }
    }
  }

  /// Audit results can settle live starts, but must not discard richer native
  /// payloads or turn a known failure into success.
  public func reconcileOpenClawAuditTool(runID: String, activity: AgentRunActivity) throws {
    try transaction {
      let query = try prepareUnlocked("SELECT content FROM dashboard_run_events WHERE id = ? AND run_id = ?")
      defer { sqlite3_finalize(query) }
      try bind("\(runID):activity:\(activity.id)", at: 1, to: query)
      try bind(runID, at: 2, to: query)
      let code = sqlite3_step(query)
      let merged: AgentRunActivity
      if code == SQLITE_ROW {
        let content = try text(query, column: 0)
        let native = try JSONDecoder().decode(AgentRunActivity.self, from: Data(content.utf8))
        if native.status == "failed" || (native.status == "completed" && activity.status != "failed") {
          merged = activity.merging(native)
        } else { merged = native.merging(activity) }
      } else if code == SQLITE_DONE { merged = activity }
      else { throw stepError() }
      try upsertDeviceOwnedRunActivityUnlocked(runID: runID, activity: merged,
        appendingContent: false, updatedAt: Date(), replacingActivity: true)
    }
  }

  /// Remove legacy mirrors only with a native call digest or commentary item ID
  /// match. Raw trace rows remain available for inspection.
  private func reconcileOpenClawActivityMirrorsUnlocked(
    runID: String, toolAliases: [String: Set<String>], commentaryAliases: [String: String]
  ) throws {
    let query = try prepareUnlocked("SELECT id, content FROM dashboard_run_events WHERE run_id = ?")
    defer { sqlite3_finalize(query) }
    try bind(runID, at: 1, to: query)
    var records: [String: (rowID: String, activity: AgentRunActivity)] = [:]
    while true {
      let code = sqlite3_step(query)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let content = try text(query, column: 1)
      guard let activity = try? JSONDecoder().decode(AgentRunActivity.self, from: Data(content.utf8)) else { continue }
      records[activity.id] = (try text(query, column: 0), activity)
    }
    var aliases = toolAliases.compactMapValues { $0.count == 1 ? $0.first : nil }
    for (legacy, canonical) in commentaryAliases { aliases[legacy] = canonical }
    for (legacyID, canonicalID) in aliases {
      guard legacyID != canonicalID, let legacy = records[legacyID], let canonical = records[canonicalID] else { continue }
      if commentaryAliases[legacyID] != nil {
        guard legacy.activity.kind == .thought, canonical.activity.kind == .assistant,
              legacy.activity.content == canonical.activity.content,
              let raw = legacy.activity.rawPayloadJSON,
              let payload = try? JSONDecoder().decode(GatewayJSONValue.self, from: Data(raw.utf8)),
              payload.objectValue?["data"]?.objectValue?["kind"]?.stringValue == "preamble" else { continue }
      } else {
        guard legacy.activity.kind == .tool, canonical.activity.kind == .tool else { continue }
      }
      // Fill absent detail from the mirror, preserving canonical identity,
      // checkpoints, ordering and rich native payloads. Terminal native state
      // wins; a result can settle a canonical call whose outcome is unknown.
      var value = try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(canonical.activity)).objectValue ?? [:]
      let fallback = try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(legacy.activity)).objectValue ?? [:]
      for key in ["title", "detail", "content", "rawInputJSON", "rawOutputJSON", "rawPayloadJSON"] where value[key] == nil || value[key] == .null {
        value[key] = fallback[key]
      }
      if canonical.activity.kind == .tool,
         (legacy.activity.status == "failed" || !["completed", "failed", "cancelled", "canceled"].contains(canonical.activity.status ?? "")),
         ["completed", "failed", "cancelled", "canceled"].contains(legacy.activity.status ?? "") {
        value["status"] = fallback["status"]
        value["phase"] = fallback["phase"]
      }
      for key in ["locations", "changes", "planEntries"] where value[key]?.arrayValue?.isEmpty == true {
        if fallback[key]?.arrayValue?.isEmpty == false { value[key] = fallback[key] }
      }
      let content = String(decoding: try JSONEncoder().encode(GatewayJSONValue.object(value)), as: UTF8.self)
      let update = try prepareUnlocked("UPDATE dashboard_run_events SET content = ? WHERE id = ? AND run_id = ?")
      defer { sqlite3_finalize(update) }
      try bind(content, at: 1, to: update); try bind(canonical.rowID, at: 2, to: update); try bind(runID, at: 3, to: update)
      try stepDone(update)
      let remove = try prepareUnlocked("DELETE FROM dashboard_run_events WHERE id = ? AND run_id = ?")
      defer { sqlite3_finalize(remove) }
      try bind(legacy.rowID, at: 1, to: remove); try bind(runID, at: 2, to: remove); try stepDone(remove)
    }
  }

  /// Native commentary and tool records share a reply owner, while their raw
  /// transcript anchors remain distinct. Never infer ownership from text alone.
  private func reconcileOpenClawActivitiesUnlocked(conversationID: String, changed: [OpenClawGatewayHistoryMessage], liveRunIDs: Set<String>) throws {
    struct Entry {
      let messageID: String
      let value: OpenClawGatewayHistoryMessage
      let tools: [AgentRunActivity]
      let isCommentary: Bool
      let isFinal: Bool
      let sequence: Int?
    }
    func hasRow(_ statement: OpaquePointer) throws -> Bool {
      let code = sqlite3_step(statement)
      if code == SQLITE_ROW { return true }
      if code == SQLITE_DONE { return false }
      throw stepError()
    }
    let inputs = try prepareUnlocked("SELECT remote_run_id FROM desktop_openclaw_run_inputs WHERE conversation_id = ?")
    defer { sqlite3_finalize(inputs) }
    try bind(conversationID, at: 1, to: inputs)
    var knownInputIDs: Set<String> = []
    while try hasRow(inputs) { knownInputIDs.insert(try text(inputs, column: 0)) }
    let affected = Set(changed.compactMap { $0.correlatedRunID(knownInputIDs: knownInputIDs) })
    let query = try prepareUnlocked("SELECT message_id, payload FROM desktop_openclaw_transcript_entries WHERE conversation_id = ?")
    defer { sqlite3_finalize(query) }
    try bind(conversationID, at: 1, to: query)
    var groups: [String: [Entry]] = [:]
    while try hasRow(query) {
      let payload = try JSONDecoder().decode(GatewayJSONValue.self, from: blob(query, column: 1))
      guard let value = OpenClawGatewayHistoryMessage(payload: payload), value.nativeRole != "user",
            let remoteID = value.correlatedRunID(knownInputIDs: knownInputIDs), affected.contains(remoteID) else { continue }
      groups[remoteID, default: []].append(Entry(messageID: try text(query, column: 0), value: value,
        tools: value.toolActivities, isCommentary: value.isCommentary,
        isFinal: value.isFinalOnlyAssistantTranscript, sequence: value.transcriptSequence))
    }
    for (remoteID, unsorted) in groups where !liveRunIDs.contains(remoteID) {
      // Choose one ordering for the whole group. Pairwise fallback between
      // sequence and date can form a cycle when older records lack a sequence.
      let hasCompleteSequence = unsorted.allSatisfy { $0.sequence != nil }
      let entries = unsorted.sorted {
        if hasCompleteSequence, let left = $0.sequence, let right = $1.sequence, left != right { return left < right }
        if $0.value.date != $1.value.date { return $0.value.date < $1.value.date }
        return $0.value.id < $1.value.id
      }
      // Explicit final identity is needed before collapsing commentary. Distinct
      // ordinary assistant messages in one remote run keep their own rows.
      let finals = entries.filter { $0.isFinal && !$0.isCommentary }
      guard finals.count <= 1 else { continue }
      let hasFinal = finals.count == 1
      guard let final = finals.first ?? entries.last(where: { !$0.tools.isEmpty }),
            !final.value.isTruncated else { continue }
      let members = entries.filter {
        (hasFinal && $0.isCommentary) || !$0.tools.isEmpty || $0.value.id == final.value.id
      }
      guard !members.isEmpty, (!hasFinal || members.count > 1),
            !members.contains(where: { $0.value.nativeRole == "assistant" && $0.value.isTruncated }) else { continue }
      let ownerQuery = try prepareUnlocked("""
        SELECT m.id, m.run_id FROM dashboard_messages m WHERE m.conversation_id = ? AND m.role = 'assistant'
          AND m.message_source = 'local_acp' AND m.id = COALESCE(
            (SELECT assistant_message_id FROM desktop_openclaw_run_inputs WHERE conversation_id = ? AND remote_run_id = ?),
            (SELECT id FROM dashboard_messages WHERE conversation_id = m.conversation_id AND run_id = ?
              AND role = 'assistant' ORDER BY created_at DESC LIMIT 1)) LIMIT 1
        """)
      defer { sqlite3_finalize(ownerQuery) }
      for (index, value) in [conversationID, conversationID, remoteID, remoteID].enumerated() {
        try bind(value, at: Int32(index + 1), to: ownerQuery)
      }
      let hasOwner = try hasRow(ownerQuery)
      let runID = hasOwner ? try text(ownerQuery, column: 1) : "openclaw-history:\(conversationID):\(remoteID)"
      let savedOwner = try prepareUnlocked("SELECT assistant_message_id FROM dashboard_runs WHERE id = ?")
      defer { sqlite3_finalize(savedOwner) }
      try bind(runID, at: 1, to: savedOwner)
      let previousOwner = try hasRow(savedOwner) ? try text(savedOwner, column: 0) : nil
      let ownerID = hasOwner ? try text(ownerQuery, column: 0) : previousOwner ?? final.messageID
      if !hasOwner {
        let run = try prepareUnlocked("""
          INSERT INTO dashboard_runs(id, conversation_id, user_id, agent_id, agent_codename,
            governing_plane, authority_kind, authority_device_id, authority_agent_id,
            assistant_message_id, status, started_at, completed_at, created_at, updated_at, desktop_owned)
          SELECT ?, c.id, c.user_id, c.agent_id, c.agent_codename, c.governing_plane, c.authority_kind,
            c.authority_device_id, c.authority_agent_id, ?, 'completed', ?, ?, ?, ?, 1
          FROM dashboard_conversations c WHERE c.id = ? ON CONFLICT(id) DO NOTHING
          """)
        defer { sqlite3_finalize(run) }
        for (index, value) in [runID, ownerID, Self.timestamp(members[0].value.date), Self.timestamp(final.value.date),
                                Self.timestamp(members[0].value.date), Self.timestamp(final.value.date), conversationID].enumerated() {
          try bind(value, at: Int32(index + 1), to: run)
        }
        try stepDone(run)
      }
      var body = ""
      var activities: [AgentRunActivity] = []
      var activityDates: [String: Date] = [:]
      for entry in members {
        if entry.value.nativeRole == "assistant", entry.value.id != final.value.id || !hasFinal, !entry.value.isTruncated, !entry.value.text.isEmpty {
          body += entry.value.text
          activities.append(AgentRunActivity(id: "history:\(entry.value.transcriptIdentity ?? entry.value.id)",
            kind: .assistant, phase: "commentary", content: entry.value.text,
            assistantMessageID: ownerID, assistantCheckpoint: AssistantTextCheckpoint(body)))
        }
        activities += entry.tools
        for tool in entry.tools where activityDates[tool.id] == nil { activityDates[tool.id] = entry.value.date }
        activityDates["history:\(entry.value.transcriptIdentity ?? entry.value.id)"] = entry.value.date
      }
      if hasFinal { body += final.value.text }
      else if hasOwner {
        let current = try prepareUnlocked("SELECT content FROM dashboard_messages WHERE id = ?")
        defer { sqlite3_finalize(current) }
        try bind(ownerID, at: 1, to: current)
        if try hasRow(current) { body = try text(current, column: 0) }
      }
      // Replace only the assistant segments owned by this reply. Other queued
      // inputs in the same local run keep their checkpoints and references.
      let oldSegments = try runActivityRecordsUnlocked(runIDs: [runID], assistantOnly: true)
      let retainedSegmentIDs = Set(activities.filter { $0.kind == .assistant }.map(\.id))
      for segment in oldSegments where hasFinal && segment.activity.assistantMessageID == ownerID
        && !retainedSegmentIDs.contains(segment.activity.id) {
        let remove = try prepareUnlocked("DELETE FROM dashboard_run_events WHERE id = ?")
        defer { sqlite3_finalize(remove) }
        try bind(segment.id, at: 1, to: remove); try stepDone(remove)
      }
      for activity in activities {
        let event = try prepareUnlocked("""
          INSERT INTO dashboard_run_events(id, run_id, conversation_id, user_id, governing_plane,
            authority_kind, authority_device_id, authority_agent_id, desktop_owned, event_type, content, created_at)
          SELECT ?, r.id, r.conversation_id, r.user_id, r.governing_plane, r.authority_kind,
            r.authority_device_id, r.authority_agent_id, 1, ?, ?, ? FROM dashboard_runs r WHERE r.id = ?
          ON CONFLICT(id) DO UPDATE SET content = excluded.content
          """)
        defer { sqlite3_finalize(event) }
        // Merge tool call/result payloads with existing live activity identities.
        let priorQuery = try prepareUnlocked("SELECT content FROM dashboard_run_events WHERE id = ?")
        defer { sqlite3_finalize(priorQuery) }
        let eventID = "\(runID):activity:\(activity.id)"
        try bind(eventID, at: 1, to: priorQuery)
        let prior: AgentRunActivity?
        if try hasRow(priorQuery) {
          let storedContent = try text(priorQuery, column: 0)
          prior = try? JSONDecoder().decode(AgentRunActivity.self, from: Data(storedContent.utf8))
        } else { prior = nil }
        let merged: AgentRunActivity
        if let prior, activity.phase == "start", ["result", "end"].contains(prior.phase ?? "") {
          merged = activity.merging(prior)
        } else { merged = prior?.merging(activity) ?? activity }
        var storedValue = try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(merged))
        if activity.kind == .tool, prior?.status == "failed", var object = storedValue.objectValue {
          object["status"] = .string("failed")
          object["phase"] = .string(prior?.phase ?? "result")
          storedValue = .object(object)
        }
        let content = String(decoding: try JSONEncoder().encode(storedValue), as: UTF8.self)
        let date = activityDates[activity.id] ?? final.value.date
        for (index, value) in [eventID, activity.kind.rawValue, content, Self.timestamp(date), runID].enumerated() {
          try bind(value, at: Int32(index + 1), to: event)
        }
        try stepDone(event)
      }
      var toolAliases: [String: Set<String>] = [:]
      var commentaryAliases: [String: String] = [:]
      for member in members {
        let nativeRunID = member.value.gatewayRunID ?? member.value.runID ?? member.value.id
        let prefix = nativeRunID + ":"
        for tool in member.tools where tool.id.hasPrefix(prefix) {
          let callID = String(tool.id.dropFirst(prefix.count))
          toolAliases[GatewayAuditToolIdentity.ledgerID(nativeCallID: callID), default: []].insert(tool.id)
        }
        if let itemID = member.value.commentaryItemID {
          commentaryAliases[nativeRunID + ":" + itemID] = "history:\(member.value.transcriptIdentity ?? member.value.id)"
        }
      }
      try reconcileOpenClawActivityMirrorsUnlocked(runID: runID, toolAliases: toolAliases, commentaryAliases: commentaryAliases)
      let update = try prepareUnlocked("UPDATE dashboard_messages SET content = ?, run_id = ? WHERE id = ? AND conversation_id = ?")
      defer { sqlite3_finalize(update) }
      for (index, value) in [body, runID, ownerID, conversationID].enumerated() { try bind(value, at: Int32(index + 1), to: update) }
      try stepDone(update)
      for member in members {
        let anchor = try prepareUnlocked("UPDATE desktop_openclaw_transcript_entries SET message_id = ? WHERE conversation_id = ? AND entry_id = ?")
        defer { sqlite3_finalize(anchor) }
        for (index, value) in [ownerID, conversationID, member.value.id].enumerated() { try bind(value, at: Int32(index + 1), to: anchor) }
        try stepDone(anchor)
        guard member.messageID != ownerID else { continue }
        for table in ["dashboard_message_references", "dashboard_message_attachments"] {
          let reference = try prepareUnlocked("UPDATE OR IGNORE \(table) SET message_id = ? WHERE message_id = ?")
          defer { sqlite3_finalize(reference) }
          try bind(ownerID, at: 1, to: reference); try bind(member.messageID, at: 2, to: reference); try stepDone(reference)
        }
        let remove = try prepareUnlocked("""
          DELETE FROM dashboard_messages WHERE id = ? AND conversation_id = ? AND message_source = 'openclaw_history'
            AND id NOT IN (SELECT message_id FROM desktop_openclaw_transcript_entries)
            AND id NOT IN (SELECT message_id FROM dashboard_message_references)
            AND id NOT IN (SELECT message_id FROM dashboard_message_attachments)
            AND NOT EXISTS (SELECT 1 FROM dashboard_runs WHERE assistant_message_id = dashboard_messages.id OR user_message_id = dashboard_messages.id)
          """)
        defer { sqlite3_finalize(remove) }
        try bind(member.messageID, at: 1, to: remove); try bind(conversationID, at: 2, to: remove); try stepDone(remove)
      }
    }
  }

  /// Upsert transcript anchors and reconcile optimistic local rows by idempotency key.
  /// A tail-page refresh never deletes earlier pages or unconfirmed local input.
  public func synchronizeOpenClawHistory(
    conversationID: String, history: OpenClawGatewayHistory,
    liveRunIDs: Set<String> = []
  ) throws {
    try transaction {
      try synchronizeOpenClawHistoryUnlocked(conversationID: conversationID, history: history, liveRunIDs: liveRunIDs)
    }
  }

  private func synchronizeOpenClawHistoryUnlocked(
    conversationID: String, history: OpenClawGatewayHistory,
    liveRunIDs: Set<String> = []
  ) throws {
    let now = Self.timestamp(Date())
    var claimedLocalMessages: Set<String> = []
    var anchors: [(entry: String, message: String, history: OpenClawGatewayHistoryMessage)] = []
    let stored = try prepareUnlocked("SELECT entry_id, message_id, payload FROM desktop_openclaw_transcript_entries WHERE conversation_id = ?")
    defer { sqlite3_finalize(stored) }
    try bind(conversationID, at: 1, to: stored)
    while true {
      let code = sqlite3_step(stored)
      if code == SQLITE_DONE { break }
      guard code == SQLITE_ROW else { throw stepError() }
      let payload = try JSONDecoder().decode(GatewayJSONValue.self, from: blob(stored, column: 2))
      if let history = OpenClawGatewayHistoryMessage(payload: payload) {
        anchors.append((try text(stored, column: 0), try text(stored, column: 1), history))
      }
    }
    let identities = Dictionary(grouping: history.messages.compactMap { message in
      message.transcriptIdentity.map { ($0, message.id) }
    }, by: { $0.0 })
    for message in history.messages.reversed() {
      let digest = SHA256.hash(data: Data((conversationID + ":" + message.id).utf8))
        .map { String(format: "%02x", $0) }.joined()
      // Only a unique native record projection can supersede earlier content.
      let uniqueIdentity = message.transcriptIdentity.flatMap { identity in
        Set(identities[identity, default: []].map { $0.1 }).count == 1 ? identity : nil
      }
      let exact = anchors.filter { $0.entry == message.id }
      let revisions = anchors.filter {
        uniqueIdentity != nil && $0.history.transcriptIdentity == uniqueIdentity
          && message.gatewayRunID != nil && $0.history.gatewayRunID == message.gatewayRunID
          && $0.history.runID == message.runID
      }
      // An exact projected sibling must never absorb another sibling, including
      // when a later byte-bounded page contains only one of them.
      let matching = !exact.isEmpty ? exact : (revisions.count == 1 ? revisions : [])
      // A projected preview cannot supersede a complete native record.
      if message.isTruncated, matching.contains(where: { !$0.history.isTruncated }) { continue }
      var id = matching.first?.message ?? "gateway:" + digest
      if message.nativeRole == "user" || message.isAssistantResponse {
        // An exact persisted input key wins (including steering). Provider keys
        // that do not name an input fall back to the explicit Gateway run ID.
        for remoteRunID in [message.runID, message.gatewayRunID].compactMap({ $0 }) {
          let existing = try prepareUnlocked("""
            SELECT id FROM dashboard_messages WHERE conversation_id = ? AND role = ?
              AND message_source = 'local_acp' AND id = COALESCE(
                (SELECT CASE WHEN ? = 'user' THEN user_message_id ELSE assistant_message_id END
                 FROM desktop_openclaw_run_inputs WHERE conversation_id = ? AND remote_run_id = ?),
                (SELECT id FROM dashboard_messages WHERE conversation_id = ? AND run_id = ? AND role = ?
                 AND message_source = 'local_acp' ORDER BY created_at DESC LIMIT 1))
            """)
          defer { sqlite3_finalize(existing) }
          for (index, value) in [conversationID, message.role, message.role, conversationID, remoteRunID,
                                conversationID, remoteRunID, message.role].enumerated() {
            try bind(value, at: Int32(index + 1), to: existing)
          }
          let code = sqlite3_step(existing)
          if code == SQLITE_DONE { continue }
          guard code == SQLITE_ROW else { throw stepError() }
          let candidate = try text(existing, column: 0)
          let previous = anchors.filter { $0.message == candidate }
          if !claimedLocalMessages.contains(candidate), previous.allSatisfy({ anchor in
            matching.contains { $0.entry == anchor.entry }
          }) { id = candidate }
          // A known input must not fall through to another execution's row.
          break
        }
      }
      claimedLocalMessages.insert(id)
      for old in matching where old.message != id || old.entry != message.id {
        let remap = try prepareUnlocked("DELETE FROM desktop_openclaw_transcript_entries WHERE conversation_id = ? AND entry_id = ?")
        defer { sqlite3_finalize(remap) }
        try bind(conversationID, at: 1, to: remap); try bind(old.entry, at: 2, to: remap)
        try stepDone(remap)
        if old.message != id {
          // Never delete the optimistic row or any run/trace-owned message.
          let remove = try prepareUnlocked("""
            DELETE FROM dashboard_messages WHERE id = ? AND conversation_id = ?
              AND message_source = 'openclaw_history' AND run_id IS NULL
              AND id NOT IN (SELECT message_id FROM desktop_openclaw_transcript_entries)
              AND id NOT IN (SELECT message_id FROM dashboard_message_attachments)
              AND id NOT IN (SELECT message_id FROM dashboard_message_references)
              AND NOT EXISTS (SELECT 1 FROM dashboard_runs WHERE user_message_id = dashboard_messages.id OR assistant_message_id = dashboard_messages.id)
              AND NOT EXISTS (SELECT 1 FROM desktop_openclaw_run_inputs WHERE user_message_id = dashboard_messages.id OR assistant_message_id = dashboard_messages.id)
            """)
          defer { sqlite3_finalize(remove) }
          try bind(old.message, at: 1, to: remove); try bind(conversationID, at: 2, to: remove)
          try stepDone(remove)
        }
      }
      anchors.removeAll { anchor in matching.contains { $0.entry == anchor.entry } }
      anchors.append((message.id, id, message))
      let retained = try prepareUnlocked("""
        INSERT INTO desktop_openclaw_transcript_entries (conversation_id, entry_id, message_id, payload)
        VALUES (?, ?, ?, ?) ON CONFLICT(conversation_id, entry_id)
        DO UPDATE SET payload = excluded.payload, message_id = excluded.message_id
        """)
      defer { sqlite3_finalize(retained) }
      try bind(conversationID, at: 1, to: retained)
      try bind(message.id, at: 2, to: retained)
      try bind(id, at: 3, to: retained)
      try bind(message.raw, at: 4, to: retained)
      try stepDone(retained)
      // A history snapshot may lag a live streamed item. Do not rewind it.
      if message.role == "assistant", [message.runID, message.gatewayRunID].compactMap({ $0 }).contains(where: liveRunIDs.contains) { continue }
      let row = try prepareUnlocked("""
        INSERT INTO dashboard_messages (
          id, conversation_id, role, message_source, content, status, governing_plane,
          authority_kind, authority_device_id, authority_agent_id, created_at, updated_at, desktop_owned
        ) SELECT ?, id, ?, 'openclaw_history', ?, ?, governing_plane,
          authority_kind, authority_device_id, authority_agent_id, ?, ?, 1
        FROM dashboard_conversations WHERE id = ? AND deleted_at IS NULL
        ON CONFLICT(id) DO UPDATE SET content = excluded.content,
          status = CASE WHEN dashboard_messages.status = 'streaming' THEN dashboard_messages.status ELSE excluded.status END,
          updated_at = excluded.updated_at
        """)
      defer { sqlite3_finalize(row) }
      var content = message.text.isEmpty ? (message.terminalError ?? "") : message.text
      if message.isTruncated || message.isCommentary || !message.toolActivities.isEmpty {
        let existing = try prepareUnlocked("SELECT content FROM dashboard_messages WHERE id = ?")
        defer { sqlite3_finalize(existing) }
        try bind(id, at: 1, to: existing)
        let existingCode = sqlite3_step(existing)
        if existingCode == SQLITE_ROW {
          if !(try text(existing, column: 0)).isEmpty { continue }
        } else if existingCode != SQLITE_DONE { throw stepError() }
      }
      if message.isFinalOnlyAssistantTranscript, !message.text.isEmpty {
        // Native final-only history remains a tail replacement after completion
        // and relaunch. Other history records remain whole-message snapshots.
        let owner = try prepareUnlocked("SELECT run_id FROM dashboard_messages WHERE id = ? AND message_source = 'local_acp' AND run_id IS NOT NULL")
        defer { sqlite3_finalize(owner) }
        try bind(id, at: 1, to: owner)
        let ownerCode = sqlite3_step(owner)
        if ownerCode == SQLITE_ROW {
          content = try assistantContentReplacingFinalSegmentUnlocked(
            runID: text(owner, column: 0), assistantMessageID: id, content: content)
        } else if ownerCode != SQLITE_DONE {
          throw stepError()
        }
      }
      for (index, value) in [id, message.role, content, message.terminalError == nil ? "completed" : "failed", Self.timestamp(message.date), now, conversationID].enumerated() {
        try bind(value, at: Int32(index + 1), to: row)
      }
      try stepDone(row)
    }
    try reconcileOpenClawActivitiesUnlocked(conversationID: conversationID, changed: history.messages, liveRunIDs: liveRunIDs)
    let touch = try prepareUnlocked("""
      UPDATE dashboard_conversations SET last_message_at = MAX(
        COALESCE((SELECT imported_at FROM desktop_openclaw_import_activity WHERE conversation_id = dashboard_conversations.id), ''),
        COALESCE((SELECT MAX(created_at) FROM dashboard_messages WHERE conversation_id = ?), last_message_at)
      ), updated_at = ? WHERE id = ?
      """)
    defer { sqlite3_finalize(touch) }
    try bind(conversationID, at: 1, to: touch)
    try bind(now, at: 2, to: touch)
    try bind(conversationID, at: 3, to: touch)
    try stepDone(touch)
  }

  public func interruptedOpenClawRuns(conversationID: String) throws -> [LocalACPRunIdentifiers] {
    try lock.withLock {
      let statement = try prepareUnlocked("""
        SELECT id, user_message_id, assistant_message_id FROM dashboard_runs
        WHERE conversation_id = ? AND desktop_owned = 1 AND status = 'running'
        """)
      defer { sqlite3_finalize(statement) }
      try bind(conversationID, at: 1, to: statement)
      var rows: [LocalACPRunIdentifiers] = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return rows }
        guard code == SQLITE_ROW else { throw stepError() }
        rows.append(LocalACPRunIdentifiers(runID: try text(statement, column: 0),
          userMessageID: try text(statement, column: 1), assistantMessageID: try text(statement, column: 2)))
      }
    }
  }

  public func openClawRunAssistantIDs(runID: String) throws -> [String: String] {
    try lock.withLock {
      let statement = try prepareUnlocked("SELECT remote_run_id, assistant_message_id FROM desktop_openclaw_run_inputs WHERE local_run_id = ?")
      defer { sqlite3_finalize(statement) }
      try bind(runID, at: 1, to: statement)
      var result: [String: String] = [:]
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return result }
        guard code == SQLITE_ROW else { throw stepError() }
        result[try text(statement, column: 0)] = try text(statement, column: 1)
      }
    }
  }

  func recordOpenClawInputUnlocked(conversationID: String, localRunID: String, remoteRunID: String,
                                          userMessageID: String, assistantMessageID: String) throws {
    let statement = try prepareUnlocked("""
      INSERT INTO desktop_openclaw_run_inputs (conversation_id, local_run_id, remote_run_id, user_message_id, assistant_message_id)
      SELECT ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM desktop_openclaw_gateway_sessions WHERE conversation_id = ?)
      """)
    defer { sqlite3_finalize(statement) }
    for (index, value) in [conversationID, localRunID, remoteRunID, userMessageID, assistantMessageID, conversationID].enumerated() {
      try bind(value, at: Int32(index + 1), to: statement)
    }
    try stepDone(statement)
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

  /// Routes and receipts are local delivery state, separate from scheduler execution.
  /// A missing route leaves results in the cron library until the user chooses a destination.
  public func openClawResultRoutes(agentID: UUID) throws -> [String: String] {
    try lock.withLock {
      let statement = try prepareUnlocked("SELECT job_id, destination FROM desktop_scheduled_result_routes WHERE provider = 'openclaw' AND agent_id = ?")
      defer { sqlite3_finalize(statement) }
      try bind(agentID.uuidString.lowercased(), at: 1, to: statement)
      var routes: [String: String] = [:]
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return routes }
        guard code == SQLITE_ROW else { throw stepError() }
        routes[try text(statement, column: 0)] = try text(statement, column: 1)
      }
    }
  }

  public func setOpenClawResultRoute(agentID: UUID, jobID: String, destination: String) throws {
    try transaction {
      if !destination.isEmpty && destination != "new" {
        try validateScheduledResultDestinationUnlocked(agentID: agentID, conversationID: destination)
      }
      let statement = try prepareUnlocked("""
        INSERT INTO desktop_scheduled_result_routes(provider, agent_id, job_id, destination)
        VALUES ('openclaw', ?, ?, ?) ON CONFLICT(provider, agent_id, job_id)
        DO UPDATE SET destination = excluded.destination
        """)
      defer { sqlite3_finalize(statement) }
      for (index, value) in [agentID.uuidString.lowercased(), jobID, destination].enumerated() {
        try bind(value, at: Int32(index + 1), to: statement)
      }
      try stepDone(statement)
    }
  }

  public func collectedOpenClawResultIDs(agentID: UUID, jobID: String) throws -> Set<String> {
    try lock.withLock {
      let statement = try prepareUnlocked("SELECT run_id FROM desktop_scheduled_result_receipts WHERE provider = 'openclaw' AND agent_id = ? AND job_id = ?")
      defer { sqlite3_finalize(statement) }
      try bind(agentID.uuidString.lowercased(), at: 1, to: statement)
      try bind(jobID, at: 2, to: statement)
      var ids: Set<String> = []
      while true {
        let code = sqlite3_step(statement)
        if code == SQLITE_DONE { return ids }
        guard code == SQLITE_ROW else { throw stepError() }
        ids.insert(try text(statement, column: 0))
      }
    }
  }

  private func validateScheduledResultDestinationUnlocked(agentID: UUID, conversationID: String) throws {
    let statement = try prepareUnlocked("""
      SELECT 1 FROM dashboard_conversations c
      JOIN desktop_openclaw_gateway_sessions s ON s.conversation_id = c.id
      WHERE c.id = ? AND s.agent_id = ? AND c.deleted_at IS NULL
        AND c.is_archived = 0 AND c.desktop_owned = 1
      """)
    defer { sqlite3_finalize(statement) }
    try bind(conversationID, at: 1, to: statement)
    try bind(agentID.uuidString.lowercased(), at: 2, to: statement)
    let code = sqlite3_step(statement)
    if code == SQLITE_DONE {
      throw OpenClawGatewayClientError.rejected("The scheduled-result conversation is unavailable. Choose another destination in Cron Jobs.")
    }
    guard code == SQLITE_ROW else { throw stepError() }
  }

  /// The receipt, message and unread state commit together. A retry, route change,
  /// app restart or deleted conversation cannot cause an acknowledged run to reappear.
  @discardableResult
  public func collectOpenClawResult(_ run: OpenClawCronRun, title: String, output: String,
                                   destination: String, collectedAt: Date = Date()) throws -> String? {
    try transaction {
      let agent = run.agentID.uuidString.lowercased()
      let receipt = try prepareUnlocked("SELECT 1 FROM desktop_scheduled_result_receipts WHERE provider = 'openclaw' AND agent_id = ? AND job_id = ? AND run_id = ?")
      defer { sqlite3_finalize(receipt) }
      for (index, value) in [agent, run.jobID, run.id].enumerated() {
        try bind(value, at: Int32(index + 1), to: receipt)
      }
      let code = sqlite3_step(receipt)
      if code == SQLITE_ROW { return nil }
      guard code == SQLITE_DONE else { throw stepError() }
      // Recheck routing inside the transaction after any asynchronous history fetch.
      let route = try prepareUnlocked("SELECT destination FROM desktop_scheduled_result_routes WHERE provider = 'openclaw' AND agent_id = ? AND job_id = ?")
      defer { sqlite3_finalize(route) }
      try bind(agent, at: 1, to: route)
      try bind(run.jobID, at: 2, to: route)
      let routeCode = sqlite3_step(route)
      if routeCode == SQLITE_DONE { return nil }
      guard routeCode == SQLITE_ROW else { throw stepError() }
      guard !destination.isEmpty, try text(route, column: 0) == destination else { return nil }
      let conversationID: String
      if destination == "new" {
        guard let nativeAgent = run.nativeSessionKey.flatMap(OpenClawGatewaySession.agentID(for:)) else {
          throw OpenClawGatewayClientError.rejected("This run has no native agent identity for a new conversation. Choose an existing conversation.")
        }
        let key = "agent:\(nativeAgent):wovenmatter:scheduled:\(UUID().uuidString.lowercased())"
        guard let session = OpenClawGatewaySession(payload: .object(["key": .string(key), "title": .string(title)])) else {
          throw WorkspaceDatabaseError.corruptRow
        }
        conversationID = try importOpenClawGatewaySessionUnlocked(agentID: run.agentID, session: session)
      } else {
        conversationID = destination
        try validateScheduledResultDestinationUnlocked(agentID: run.agentID, conversationID: conversationID)
      }
      let messageID = UUID().uuidString.lowercased()
      let now = Self.timestamp(collectedAt)
      let message = try prepareUnlocked("""
        INSERT INTO dashboard_messages(id, conversation_id, role, message_source, content,
          status, governing_plane, authority_kind, authority_device_id, authority_agent_id,
          created_at, updated_at, desktop_owned)
        SELECT ?, id, 'assistant', 'scheduled_result', ?, 'completed', governing_plane,
          authority_kind, authority_device_id, authority_agent_id, ?, ?, 1
        FROM dashboard_conversations WHERE id = ?
        """)
      defer { sqlite3_finalize(message) }
      let body = "**\(title)**\n\n\(output)\n\nJob: \(run.jobID) · Run: \(run.id) · \(run.status)"
      for (index, value) in [messageID, body, now, now, conversationID].enumerated() {
        try bind(value, at: Int32(index + 1), to: message)
      }
      try stepDone(message)
      let touch = try prepareUnlocked("UPDATE dashboard_conversations SET unread = 1, last_message_at = MAX(COALESCE(last_message_at, ''), ?), last_message_preview = ?, updated_at = ? WHERE id = ?")
      defer { sqlite3_finalize(touch) }
      for (index, value) in [now, String(output.prefix(240)), now, conversationID].enumerated() {
        try bind(value, at: Int32(index + 1), to: touch)
      }
      try stepDone(touch)
      let ack = try prepareUnlocked("INSERT INTO desktop_scheduled_result_receipts(provider, agent_id, job_id, run_id, conversation_id, message_id, collected_at) VALUES ('openclaw', ?, ?, ?, ?, ?, ?)")
      defer { sqlite3_finalize(ack) }
      for (index, value) in [agent, run.jobID, run.id, conversationID, messageID, now].enumerated() {
        try bind(value, at: Int32(index + 1), to: ack)
      }
      try stepDone(ack)
      return conversationID
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
      try saveOpenClawRunsUnlocked(runs)
    }
  }

  private func saveOpenClawRunsUnlocked(_ runs: [OpenClawCronRun], fullOutput: Bool = false) throws {
    let runStatement = try prepareUnlocked("""
      INSERT INTO desktop_openclaw_cron_runs (
        agent_id, remote_run_id, remote_job_id, status, output,
        native_session_id, native_session_key, started_at, completed_at,
        remote_payload, full_output
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(agent_id, remote_run_id) DO UPDATE SET
        remote_job_id = excluded.remote_job_id, status = excluded.status,
        output = CASE WHEN full_output = 1 AND excluded.full_output = 0 THEN output ELSE excluded.output END,
        full_output = MAX(full_output, excluded.full_output),
        native_session_id = excluded.native_session_id,
        native_session_key = excluded.native_session_key,
        started_at = excluded.started_at, completed_at = excluded.completed_at,
        remote_payload = excluded.remote_payload
      """)
    defer { sqlite3_finalize(runStatement) }
    for run in runs {
      let rawAgentID = run.agentID.uuidString.lowercased()
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
      guard sqlite3_bind_int(runStatement, 11, fullOutput ? 1 : 0) == SQLITE_OK else { throw bindError() }
      try stepDone(runStatement)
    }
  }

  public func retainedOpenClawResult(agentID: UUID, runID: String) throws -> String? {
    try lock.withLock {
      let statement = try prepareUnlocked("SELECT output FROM desktop_openclaw_cron_runs WHERE agent_id = ? AND remote_run_id = ? AND full_output = 1")
      defer { sqlite3_finalize(statement) }
      try bind(agentID.uuidString.lowercased(), at: 1, to: statement)
      try bind(runID, at: 2, to: statement)
      let code = sqlite3_step(statement)
      if code == SQLITE_DONE { return nil }
      guard code == SQLITE_ROW else { throw stepError() }
      return optionalText(statement, column: 0)
    }
  }

  public func retainOpenClawResult(_ run: OpenClawCronRun, title: String, output: String) throws {
    try transaction {
      // Deleted native jobs still need a visible home for pending results.
      let job = try prepareUnlocked("""
        INSERT OR IGNORE INTO desktop_openclaw_cron_jobs
          (agent_id, remote_job_id, name, schedule, enabled, archive_state, remote_payload, updated_at)
        VALUES (?, ?, ?, 'Schedule unavailable', 0, 'deleted', ?, ?)
        """)
      defer { sqlite3_finalize(job) }
      try bind(run.agentID.uuidString.lowercased(), at: 1, to: job)
      try bind(run.jobID, at: 2, to: job)
      try bind(title, at: 3, to: job)
      try bind(Data("{}".utf8), at: 4, to: job)
      try bind(Self.timestamp(Date()), at: 5, to: job)
      try stepDone(job)
      var retained = run
      retained.output = output
      try saveOpenClawRunsUnlocked([retained], fullOutput: true)
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

}
