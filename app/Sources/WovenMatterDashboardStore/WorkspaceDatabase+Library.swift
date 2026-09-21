import CryptoKit
import Foundation
import SQLite3
import WovenMatterClient
import WovenMatterCore

extension WorkspaceDatabase {
  func migrateLibrary() throws {
    try transaction {
      try executeUnlocked("""
        CREATE TABLE IF NOT EXISTS library_settings(key TEXT PRIMARY KEY,value TEXT NOT NULL);
        INSERT OR IGNORE INTO library_settings VALUES('activated_at',strftime('%Y-%m-%dT%H:%M:%fZ','now'));
        CREATE TABLE IF NOT EXISTS library_messages(
          message_id TEXT PRIMARY KEY REFERENCES dashboard_messages(id) ON DELETE CASCADE,
          dirty INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE IF NOT EXISTS library_items(
          id TEXT PRIMARY KEY, message_id TEXT NOT NULL REFERENCES library_messages(message_id) ON DELETE CASCADE,
          conversation_id TEXT NOT NULL, kind TEXT NOT NULL,title TEXT NOT NULL,source TEXT NOT NULL,
          content_hash TEXT,mime_type TEXT,size_bytes INTEGER,storage TEXT NOT NULL,error TEXT,
          retry_at TEXT, UNIQUE(message_id,source));
        CREATE INDEX IF NOT EXISTS library_message_items ON library_items(message_id);
        CREATE INDEX IF NOT EXISTS library_conversation_items ON library_items(conversation_id);
        CREATE INDEX IF NOT EXISTS library_pending_files ON library_items(storage,retry_at);
        CREATE TABLE IF NOT EXISTS library_locations(
          conversation_id TEXT PRIMARY KEY, workspace_name TEXT NOT NULL,root TEXT NOT NULL);
        CREATE TRIGGER IF NOT EXISTS library_new_message AFTER INSERT ON dashboard_messages
        WHEN NEW.role IN ('user','assistant') AND julianday(NEW.created_at) >=
          (SELECT julianday(value) FROM library_settings WHERE key='activated_at')
        BEGIN INSERT OR IGNORE INTO library_messages(message_id) VALUES(NEW.id); END;
        CREATE TRIGGER IF NOT EXISTS library_cleared_conversation AFTER UPDATE OF context_generation ON dashboard_conversations
        WHEN NEW.context_generation > OLD.context_generation
        BEGIN DELETE FROM library_messages WHERE message_id IN (SELECT id FROM dashboard_messages WHERE conversation_id=NEW.id); END;
        CREATE TRIGGER IF NOT EXISTS library_deleted_message AFTER DELETE ON dashboard_messages
        BEGIN DELETE FROM library_messages WHERE message_id=OLD.id; END;
        CREATE TRIGGER IF NOT EXISTS library_changed_message AFTER UPDATE OF content,status ON dashboard_messages
        WHEN NEW.content != OLD.content OR NEW.status != OLD.status
        BEGIN UPDATE library_messages SET dirty=1 WHERE message_id=NEW.id; END;
        CREATE TRIGGER IF NOT EXISTS library_new_attachment AFTER INSERT ON dashboard_message_attachments
        BEGIN UPDATE library_messages SET dirty=1 WHERE message_id=NEW.message_id; END;
        CREATE TRIGGER IF NOT EXISTS library_deleted_conversation AFTER DELETE ON dashboard_conversations
        BEGIN
          DELETE FROM library_messages WHERE message_id IN (SELECT message_id FROM library_items WHERE conversation_id=OLD.id)
            OR message_id IN (SELECT id FROM dashboard_messages WHERE conversation_id=OLD.id);
          DELETE FROM library_locations WHERE conversation_id=OLD.id;
        END;
        CREATE TRIGGER IF NOT EXISTS library_trashed_conversation AFTER UPDATE OF deleted_at ON dashboard_conversations
        WHEN NEW.deleted_at IS NOT NULL
        BEGIN
          DELETE FROM library_messages WHERE message_id IN (SELECT id FROM dashboard_messages WHERE conversation_id=NEW.id);
          DELETE FROM library_locations WHERE conversation_id=NEW.id;
        END;
        """)
      for operation in ["INSERT", "UPDATE", "DELETE"] {
        try executeUnlocked("""
          CREATE TRIGGER IF NOT EXISTS library_revision_\(operation) AFTER \(operation) ON library_items
          BEGIN UPDATE desktop_dashboard_revision SET revision=revision+1 WHERE singleton=1; END;
          """)
      }
    }
  }

  /// Runs only on messages registered by the forward-only insertion trigger.
  @discardableResult
  public func indexLibraryMessages(limit: Int = 50) throws -> Int {
    try transaction {
      let rows = try historyRowsUnlocked("""
        SELECT m.id,m.conversation_id,m.content FROM library_messages q
        JOIN dashboard_messages m ON m.id=q.message_id
        JOIN dashboard_conversations c ON c.id=m.conversation_id
        WHERE q.dirty=1 AND m.status NOT IN ('streaming','pending','queued') AND c.deleted_at IS NULL
        ORDER BY m.created_at,m.id LIMIT ?
        """, values: [String(max(1, min(limit, 200)))])
      for row in rows {
        guard let fields = row.objectValue, let id = fields["id"]?.stringValue,
              let conversationID = fields["conversation_id"]?.stringValue else { continue }
        for asset in LibraryLinkDiscovery.links(in: fields["content"]?.stringValue ?? "") {
          try insertLibraryAssetUnlocked(asset, messageID: id, conversationID: conversationID)
        }
        for attachment in try historyRowsUnlocked("SELECT * FROM dashboard_message_attachments WHERE message_id=?", values: [id]) {
          guard let value = attachment.objectValue, let hash = value["content_hash"]?.stringValue else { continue }
          let name = value["file_name"]?.stringValue ?? "Attachment"
          let mime = value["mime_type"]?.stringValue
          try insertLibraryAssetUnlocked(.init(source: "attachment:" + (value["id"]?.stringValue ?? hash), title: name,
            kind: value["kind"]?.stringValue == "image" ? .photo : .file, mimeType: mime),
            messageID: id, conversationID: conversationID, hash: hash,
            size: value["size_bytes"]?.intValue.map(Int64.init), storage: "attachment")
        }
        try toolsExecuteUnlocked("UPDATE library_messages SET dirty=0 WHERE message_id=?", [id])
      }
      return rows.count
    }
  }

  func insertLibraryAssetUnlocked(_ asset: LibraryAsset, messageID: String, conversationID: String,
                                 hash: String? = nil, size: Int64? = nil, storage: String? = nil, error: String? = nil) throws {
    guard asset.source.utf8.count <= 8192,
          !(try historyRowsUnlocked("SELECT 1 FROM library_messages WHERE message_id=?", values: [messageID])).isEmpty else { return }
    let key = SHA256.hash(data: Data((messageID + "\u{0}" + asset.source).utf8)).map { String(format: "%02x", $0) }.joined()
    let state = storage ?? (LibraryLinkDiscovery.isFileReference(asset.source) ? "pending" : "link")
    try toolsExecuteUnlocked("""
      INSERT OR IGNORE INTO library_items(id,message_id,conversation_id,kind,title,source,content_hash,mime_type,size_bytes,storage,error)
      VALUES(?,?,?,?,?,?,?,?,?,?,?)
      """, [key, messageID, conversationID, asset.kind.rawValue, String(asset.title.prefix(512)), asset.source,
             hash, asset.mimeType, size.map(String.init), state, error])
  }

  private func retainLibraryAssetUnlocked(_ asset: LibraryAsset, data: Data, messageID: String, conversationID: String) throws {
    let identity = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    let normalized = LibraryAsset(source: asset.source.isEmpty ? "embedded:" + identity : asset.source,
      title: asset.title, kind: asset.kind, mimeType: asset.mimeType)
    let hash: String?
    let failure: String?
    do { hash = try libraryFiles.retain(data); failure = nil }
    catch { hash = nil; failure = String(error.localizedDescription.prefix(512)) }
    // Saving an attachment must never roll back the conversation's message.
    try insertLibraryAssetUnlocked(normalized, messageID: messageID, conversationID: conversationID,
      hash: hash, size: Int64(data.count), storage: hash == nil ? "unsupported" : "retained", error: failure)
  }

  func captureNativeLibraryFileUnlocked(source: String, title: String, mime: String?, base64: String?, messageID: String, conversationID: String) throws {
    guard !(try historyRowsUnlocked("SELECT 1 FROM library_messages WHERE message_id=?", values: [messageID])).isEmpty else { return }
    var encoded = base64
    var mime = mime
    if source.hasPrefix("data:"), let comma = source.firstIndex(of: ",") {
      let header = source[..<comma]
      guard header.hasSuffix(";base64") else { return }
      encoded = String(source[source.index(after: comma)...])
      mime = String(header.dropFirst(5).dropLast(7))
    }
    let maximum = Int(AgentMessageAttachmentLimits.maximumFileBytes * 4 / 3 + 8)
    if let encoded, encoded.utf8.count <= maximum, let data = Data(base64Encoded: encoded) {
      try retainLibraryAssetUnlocked(.init(source: source.hasPrefix("data:") ? "" : source, title: title,
        kind: LibraryLinkDiscovery.kind(source: title, mimeType: mime), mimeType: mime), data: data,
        messageID: messageID, conversationID: conversationID)
    } else if !source.isEmpty, !source.hasPrefix("data:") {
      try insertLibraryAssetUnlocked(.init(source: source, title: title, kind: LibraryLinkDiscovery.kind(source: source, mimeType: mime), mimeType: mime),
        messageID: messageID, conversationID: conversationID)
    } else if let encoded {
      let identity = SHA256.hash(data: Data(encoded.utf8)).map { String(format: "%02x", $0) }.joined()
      try insertLibraryAssetUnlocked(.init(source: "embedded:" + identity, title: title,
        kind: LibraryLinkDiscovery.kind(source: title, mimeType: mime), mimeType: mime), messageID: messageID,
        conversationID: conversationID, storage: "unsupported", error: "This attachment could not be saved. Ask the agent for a file link or an attachment under 25 MB.")
    }
  }

  func captureGatewayLibraryFilesUnlocked(_ payload: GatewayJSONValue, messageID: String, conversationID: String) throws {
    let body = payload.objectValue?["message"] ?? payload
    let blocks = body.objectValue?["content"]?.arrayValue ?? []
    for block in blocks.prefix(LibraryLinkDiscovery.maximumItemsPerMessage) {
      guard let fields = block.objectValue, let type = fields["type"]?.stringValue,
            ["image", "audio", "video", "file"].contains(type) else { continue }
      let nested = fields["source"]?.objectValue
      let source = fields["url"]?.stringValue ?? fields["path"]?.stringValue ?? nested?["url"]?.stringValue ?? ""
      let title = fields["fileName"]?.stringValue ?? fields["alt"]?.stringValue ?? URL(string: source)?.lastPathComponent ?? "Attachment"
      let mime = fields["mimeType"]?.stringValue ?? nested?["media_type"]?.stringValue
      try captureNativeLibraryFileUnlocked(source: source, title: title, mime: mime,
        base64: fields["data"]?.stringValue ?? nested?["data"]?.stringValue, messageID: messageID, conversationID: conversationID)
    }
  }
  public func captureGatewayLibraryFiles(_ payload: GatewayJSONValue, messageID: String, conversationID: String) throws {
    try transaction { try captureGatewayLibraryFilesUnlocked(payload, messageID: messageID, conversationID: conversationID) }
  }

  public func recordLibraryAsset(_ asset: LibraryAsset, messageID: String, conversationID: String,
                                hash: String? = nil, size: Int64? = nil) throws {
    try transaction {
      try insertLibraryAssetUnlocked(asset, messageID: messageID, conversationID: conversationID,
        hash: hash, size: size, storage: hash == nil ? nil : "retained")
    }
  }

  public func setLibraryLocation(conversationID: String, workspaceName: String, root: String) throws {
    try transaction {
      try toolsExecuteUnlocked("""
        INSERT INTO library_locations VALUES(?,?,?) ON CONFLICT(conversation_id) DO UPDATE
        SET workspace_name=excluded.workspace_name,root=excluded.root
        WHERE workspace_name!=excluded.workspace_name OR root!=excluded.root
        """, [conversationID, workspaceName, root])
    }
  }

  public func libraryRoot(conversationID: String) throws -> String? {
    try withLock {
      try historyRowsUnlocked("SELECT root FROM library_locations WHERE conversation_id=?", values: [conversationID])
        .first?.objectValue?["root"]?.stringValue
    }
  }

  private static let libraryJoins = """
    FROM library_items i JOIN dashboard_messages m ON m.id=i.message_id
    JOIN dashboard_conversations c ON c.id=i.conversation_id
    LEFT JOIN desktop_local_acp_sessions s ON s.conversation_id=c.id
    LEFT JOIN dashboard_agents a ON a.id=c.agent_id
    LEFT JOIN library_locations l ON l.conversation_id=c.id
    """
  private static let libraryWorkspace = "coalesce(lower(s.remote_workspace_id),'local')"
  private static let librarySender = "CASE WHEN m.role='user' AND NOT EXISTS(SELECT 1 FROM workspace_session_deliveries d WHERE d.message_id=m.id) THEN 'me' ELSE 'agent' END"
  private static let libraryProjection = """
    SELECT json_object('id',i.id,'conversationID',c.id,'messageID',m.id,'conversationTitle',c.title,
      'workspaceID',\(libraryWorkspace),'workspaceName',coalesce(l.workspace_name,CASE WHEN s.remote_workspace_id IS NULL THEN 'Local workspace' ELSE 'Remote workspace' END),
      'harness',coalesce(s.runtime_kind,''),'agentID',coalesce(c.agent_id,''),
      'agentName',coalesce(nullif(a.display_name,''),nullif(c.agent_codename,''),'Agent'),
      'sender',\(librarySender),'kind',i.kind,'title',i.title,'source',i.source,'sentAt',m.created_at,
      'contentHash',i.content_hash,'mimeType',i.mime_type,'sizeBytes',i.size_bytes,'storage',i.storage,'error',i.error)
    """

  public func libraryItems(query: LibraryQuery = .init(), limit: Int = 100, offset: Int = 0) throws -> [WorkspaceLibraryItem] {
    try withLock { try libraryItemsUnlocked(query: query, limit: limit, offset: offset) }
  }
  private func libraryItemsUnlocked(query: LibraryQuery, limit: Int, offset: Int) throws -> [WorkspaceLibraryItem] {
    var sql = Self.libraryProjection + Self.libraryJoins + " WHERE c.deleted_at IS NULL"
    var values: [String] = []
    func selection(_ selection: Set<String>?, _ column: String) {
      guard let selection else { return }
      let sorted = selection.sorted()
      sql += " AND \(column) IN (\(Array(repeating: "?", count: sorted.count).joined(separator: ",")))"
      values += sorted
    }
    selection(query.workspaces, Self.libraryWorkspace); selection(query.harnesses, "s.runtime_kind"); selection(query.agents, "c.agent_id")
    if let sender = query.sender { sql += " AND \(Self.librarySender)=?"; values.append(sender.rawValue) }
    if let kind = query.kind { sql += " AND i.kind=?"; values.append(kind.rawValue) }
    if let since = query.since { sql += " AND julianday(m.created_at)>=julianday(?)"; values.append(Self.timestamp(since)) }
    if let until = query.until { sql += " AND julianday(m.created_at)<julianday(?)"; values.append(Self.timestamp(until)) }
    if !query.search.isEmpty {
      sql += " AND (instr(lower(i.title),lower(?))>0 OR instr(lower(i.source),lower(?))>0 OR instr(lower(c.title),lower(?))>0)"
      values += Array(repeating: String(query.search.prefix(512)), count: 3)
    }
    let direction = query.oldestFirst ? "ASC" : "DESC"
    sql += " ORDER BY m.created_at \(direction),i.id \(direction) LIMIT ? OFFSET ?"
    values += [String(max(1, min(limit, 201))), String(max(0, offset))]
    return try decodeCanonicalRowsUnlocked(sql, bindings: values, as: WorkspaceLibraryItem.self)
  }

  public func libraryItem(id: String) throws -> WorkspaceLibraryItem? {
    try withLock { try libraryItemUnlocked(id: id) }
  }
  private func libraryItemUnlocked(id: String) throws -> WorkspaceLibraryItem? {
    try decodeCanonicalRowsUnlocked(Self.libraryProjection + Self.libraryJoins + " WHERE i.id=? AND c.deleted_at IS NULL",
      bindings: [id], as: WorkspaceLibraryItem.self).first
  }
  public func libraryFacets() throws -> [LibraryFacet] {
    try withLock {
      try decodeCanonicalRowsUnlocked("""
        SELECT DISTINCT json_object('workspaceID',\(Self.libraryWorkspace),
          'workspaceName',coalesce(l.workspace_name,CASE WHEN s.remote_workspace_id IS NULL THEN 'Local workspace' ELSE 'Remote workspace' END),
          'harness',coalesce(s.runtime_kind,''),'agentID',coalesce(c.agent_id,''),
          'agentName',coalesce(nullif(a.display_name,''),nullif(c.agent_codename,''),'Agent'))
        \(Self.libraryJoins) WHERE c.deleted_at IS NULL
        """, bindings: [], as: LibraryFacet.self)
    }
  }

  public func pendingLibraryFiles(limit: Int = 8, now: Date = Date()) throws -> [WorkspaceLibraryItem] {
    try withLock {
      try decodeCanonicalRowsUnlocked(Self.libraryProjection + Self.libraryJoins + """
         WHERE c.deleted_at IS NULL AND i.storage IN ('pending','unavailable')
         AND (i.retry_at IS NULL OR i.retry_at<=?) ORDER BY m.created_at LIMIT ?
        """, bindings: [Self.timestamp(now), String(max(1, min(limit, 20)))], as: WorkspaceLibraryItem.self)
    }
  }
  public func finishLibraryFile(id: String, hash: String?, size: Int64? = nil, error: String? = nil) throws {
    try transaction {
      try toolsExecuteUnlocked("""
        UPDATE library_items SET content_hash=?,size_bytes=?,storage=?,error=?,retry_at=? WHERE id=?
        """, [hash, size.map(String.init), hash == nil ? "unavailable" : "retained", error,
               hash == nil ? Self.timestamp(Date().addingTimeInterval(300)) : nil, id])
    }
  }
  public func retryLibraryFile(id: String) throws {
    try transaction { try toolsExecuteUnlocked("UPDATE library_items SET retry_at=NULL WHERE id=? AND storage='unavailable'", [id]) }
  }
  public func visibleLibraryHashes() throws -> Set<String> {
    try withLock {
      Set(try historyRowsUnlocked("SELECT DISTINCT content_hash FROM library_items WHERE content_hash IS NOT NULL", values: [])
        .compactMap { $0.objectValue?["content_hash"]?.stringValue })
    }
  }

  public func recordLibraryOutput(runID: String, asset: LibraryAsset) throws {
    let identity = try withLock {
      try historyRowsUnlocked("SELECT conversation_id,assistant_message_id FROM dashboard_runs WHERE id=?", values: [runID]).first?.objectValue
    }
    guard let conversation = identity?["conversation_id"]?.stringValue,
          let message = identity?["assistant_message_id"]?.stringValue else { return }
    try transaction {
      if let data = asset.data {
        try retainLibraryAssetUnlocked(asset, data: data, messageID: message, conversationID: conversation)
      } else if !asset.source.isEmpty {
        try insertLibraryAssetUnlocked(asset, messageID: message, conversationID: conversation)
      }
    }
  }

  public func retainedLibraryHashes() throws -> Set<String> {
    try withLock {
      Set(try historyRowsUnlocked("SELECT DISTINCT content_hash FROM library_items WHERE storage='retained' AND content_hash IS NOT NULL", values: [])
        .compactMap { $0.objectValue?["content_hash"]?.stringValue })
    }
  }

  public func librarySourceMessage(id: String) throws -> String {
    try withLock {
      guard let row = try historyRowsUnlocked("SELECT m.content FROM library_items i JOIN dashboard_messages m ON m.id=i.message_id JOIN dashboard_conversations c ON c.id=i.conversation_id WHERE i.id=? AND c.deleted_at IS NULL", values: [id]).first?.objectValue,
            let content = row["content"]?.stringValue else { throw WorkspaceToolError.invalid("This source message is no longer available.") }
      return content
    }
  }

  public func queryAgentLibrary(callerID: String, id: String? = nil, query: LibraryQuery = .init(), limit: Int = 100, offset: Int = 0) throws -> GatewayJSONValue {
    try withLock {
      try requireToolUnlocked(.library, sessionID: callerID)
      if let id {
        guard let item = try libraryItemUnlocked(id: id) else { throw WorkspaceToolError.invalid("Library item not found.") }
        return try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(item))
      }
      let rows = try libraryItemsUnlocked(query: query, limit: max(1, min(limit, 200)) + 1, offset: offset)
      let page = Array(rows.prefix(max(1, min(limit, 200))))
      return .object(["available": .bool(true), "items": try JSONDecoder().decode(GatewayJSONValue.self, from: JSONEncoder().encode(page)),
        "hasMore": .bool(rows.count > page.count), "nextOffset": .number(Double(offset + page.count))])
    }
  }
}
