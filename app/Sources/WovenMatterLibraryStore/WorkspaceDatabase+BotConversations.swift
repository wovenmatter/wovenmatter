import Foundation
import WovenMatterCore

/// One mirror batch from a bots runtime (`POST /v1/bots-host/conversations/{botID}/entries`,
/// docs/architecture/WOVEN_EVERYWHERE.md). Entry ids are unique per bot and never reused,
/// so a resent batch never duplicates anything.
public struct BotConversationMirror: Codable, Equatable, Sendable {
  public struct Bot: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
  }
  public struct Conversation: Codable, Equatable, Sendable {
    public var conversationId: Int
    /// `main` or `thread`.
    public var kind: String
    public var parentConversationId: Int?
    public var forkedAt: Int?
    public var title: String?
    public var pinned: Bool?
    public var createdAt: String?
    public init(conversationId: Int, kind: String, parentConversationId: Int? = nil, forkedAt: Int? = nil,
                title: String? = nil, pinned: Bool? = nil, createdAt: String? = nil) {
      self.conversationId = conversationId; self.kind = kind; self.parentConversationId = parentConversationId
      self.forkedAt = forkedAt; self.title = title; self.pinned = pinned; self.createdAt = createdAt
    }
  }
  public struct Entry: Codable, Equatable, Sendable {
    public var id: Int
    public var conversationId: Int
    /// `user` or `assistant`.
    public var role: String
    public var text: String
    public var error: String?
    public var stopped: Bool?
    public var createdAt: String
    public init(id: Int, conversationId: Int, role: String, text: String, error: String? = nil, stopped: Bool? = nil, createdAt: String) {
      self.id = id; self.conversationId = conversationId; self.role = role; self.text = text
      self.error = error; self.stopped = stopped; self.createdAt = createdAt
    }
  }
  public var bot: Bot
  /// Always the bot's main channel and every thread, so a batch can carry only metadata.
  public var conversations: [Conversation]
  public var entries: [Entry]
  public init(bot: Bot, conversations: [Conversation], entries: [Entry]) {
    self.bot = bot; self.conversations = conversations; self.entries = entries
  }
}

public struct BotConversationRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let machineID: String
  public let botID: String
  public let botName: String
  public let conversationID: Int
  public let kind: String
  public let parentConversationID: Int?
  public let title: String?
  public let pinned: Bool
  public let updatedAt: String
}

public struct BotConversationEntryRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let entryID: Int
  public let role: String
  public let text: String
  public let error: String?
  public let stopped: Bool
  public let createdAt: String
}

/// Bot conversations live in their own two library tables rather than as chats:
/// the runtime owns them and they have no harness, runs or composer here. Both
/// tables are in the paired-library set, so every member's copy receives them.
extension WorkspaceDatabaseConnection {
  func migrateBotConversations() throws {
    try withLock { try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS bot_conversations(
        id TEXT PRIMARY KEY, machine_id TEXT NOT NULL, bot_id TEXT NOT NULL, bot_name TEXT NOT NULL,
        runtime_conversation_id INTEGER NOT NULL, kind TEXT NOT NULL, parent_runtime_conversation_id INTEGER, forked_at_entry_id INTEGER,
        title TEXT, is_pinned INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);
      CREATE TABLE IF NOT EXISTS bot_conversation_entries(
        id TEXT PRIMARY KEY, bot_conversation_id TEXT NOT NULL, entry_id INTEGER NOT NULL,
        role TEXT NOT NULL, text TEXT NOT NULL, error TEXT, stopped INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS bot_conversation_entries_conversation ON bot_conversation_entries(bot_conversation_id, entry_id);
      CREATE INDEX IF NOT EXISTS bot_conversations_machine ON bot_conversations(machine_id, bot_id);
      """) }
  }

  static func botKey(_ machineID: String, _ botID: String, _ value: Int) -> String {
    machineID.lowercased() + ":" + botID.lowercased() + ":" + String(value)
  }
}

extension WorkspaceDatabase {
  public static let maximumBotEntryCharacters = 1_000_000

  /// Upserts conversations by (bot, conversationId) and entries by (bot, id).
  /// Returns how many entries were new.
  @discardableResult
  public func recordBotConversation(machineID: String, _ batch: BotConversationMirror, now: Date = Date()) async throws -> Int {
    let botID = batch.bot.id
    guard WovenMCPCaller.isIdentifier(machineID), WovenMCPCaller.isIdentifier(botID) else {
      throw WorkspaceToolError.invalid("Invalid bot or machine ID.")
    }
    guard batch.entries.count <= 200 else { throw WorkspaceToolError.invalid("Send at most 200 entries at a time.") }
    for conversation in batch.conversations where !["main", "thread"].contains(conversation.kind) {
      throw WorkspaceToolError.invalid("Unknown conversation kind.")
    }
    let known = Set(batch.conversations.map(\.conversationId))
    for entry in batch.entries {
      guard ["user", "assistant"].contains(entry.role) else { throw WorkspaceToolError.invalid("Unknown entry role.") }
      guard entry.text.utf8.count <= Self.maximumBotEntryCharacters else { throw WorkspaceToolError.invalid("A bot entry exceeds its size limit.") }
      guard known.contains(entry.conversationId) else { throw WorkspaceToolError.invalid("An entry names a conversation the batch doesn't list.") }
    }
    let stamp = ISO8601DateFormatter().string(from: now)
    let machine = machineID.lowercased(), bot = botID.lowercased()
    let name = String(batch.bot.name.prefix(128))
    return try await write { connection in
      try connection.transaction {
        for conversation in batch.conversations {
          try connection.toolsExecuteUnlocked("""
            INSERT INTO bot_conversations(id,machine_id,bot_id,bot_name,runtime_conversation_id,kind,parent_runtime_conversation_id,forked_at_entry_id,title,is_pinned,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET bot_name=excluded.bot_name,kind=excluded.kind,
              parent_runtime_conversation_id=excluded.parent_runtime_conversation_id,forked_at_entry_id=excluded.forked_at_entry_id,title=excluded.title,
              is_pinned=excluded.is_pinned,updated_at=excluded.updated_at,deleted_at=NULL
            WHERE bot_name IS NOT excluded.bot_name OR kind IS NOT excluded.kind OR parent_runtime_conversation_id IS NOT excluded.parent_runtime_conversation_id
              OR forked_at_entry_id IS NOT excluded.forked_at_entry_id OR title IS NOT excluded.title OR is_pinned IS NOT excluded.is_pinned OR deleted_at IS NOT NULL
            """, [WorkspaceDatabaseConnection.botKey(machine, bot, conversation.conversationId), machine, bot, name,
                  String(conversation.conversationId), conversation.kind, conversation.parentConversationId.map { String($0) },
                  conversation.forkedAt.map { String($0) }, conversation.title.map { String($0.prefix(256)) },
                  conversation.pinned == true ? "1" : "0", conversation.createdAt ?? stamp, stamp])
        }
        var inserted = 0
        for entry in batch.entries {
          let id = WorkspaceDatabaseConnection.botKey(machine, bot, entry.id)
          let conversation = WorkspaceDatabaseConnection.botKey(machine, bot, entry.conversationId)
          let existing = try connection.historyRowsUnlocked("SELECT 1 FROM bot_conversation_entries WHERE id=?", values: [id]).first
          // Only a changed row is rewritten, so a resent batch adds no sync traffic.
          try connection.toolsExecuteUnlocked("""
            INSERT INTO bot_conversation_entries(id,bot_conversation_id,entry_id,role,text,error,stopped,created_at) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET bot_conversation_id=excluded.bot_conversation_id,role=excluded.role,text=excluded.text,
              error=excluded.error,stopped=excluded.stopped
            WHERE bot_conversation_id IS NOT excluded.bot_conversation_id OR role IS NOT excluded.role OR text IS NOT excluded.text
              OR error IS NOT excluded.error OR stopped IS NOT excluded.stopped
            """, [id, conversation, String(entry.id), entry.role, entry.text, entry.error, entry.stopped == true ? "1" : "0", entry.createdAt])
          if existing == nil { inserted += 1 }
        }
        return inserted
      }
    }
  }

  /// Marks a bot's conversations deleted. Entries stay for history.
  public func deleteBotConversations(machineID: String, botID: String, now: Date = Date()) async throws {
    let stamp = ISO8601DateFormatter().string(from: now)
    try await write { connection in
      try connection.transaction { try connection.toolsExecuteUnlocked("UPDATE bot_conversations SET deleted_at=?,updated_at=? WHERE machine_id=? AND bot_id=? AND deleted_at IS NULL",
        [stamp, stamp, machineID.lowercased(), botID.lowercased()]) }
    }
  }

  public func botConversations(machineID: String? = nil) async throws -> [BotConversationRecord] {
    try await read { connection in
      try connection.withLock {
        try connection.historyRowsUnlocked("""
          SELECT * FROM bot_conversations WHERE deleted_at IS NULL AND (? IS NULL OR machine_id=?) ORDER BY bot_name,bot_id,runtime_conversation_id
          """, values: [machineID?.lowercased(), machineID?.lowercased()]).compactMap { row in
          guard let o = row.objectValue, let id = o["id"]?.stringValue, let machine = o["machine_id"]?.stringValue,
                let bot = o["bot_id"]?.stringValue, let conversation = o["runtime_conversation_id"]?.intValue else { return nil }
          return BotConversationRecord(id: id, machineID: machine, botID: bot, botName: o["bot_name"]?.stringValue ?? "Bot",
            conversationID: conversation, kind: o["kind"]?.stringValue ?? "main",
            parentConversationID: o["parent_runtime_conversation_id"]?.intValue, title: o["title"]?.stringValue,
            pinned: o["is_pinned"]?.intValue == 1, updatedAt: o["updated_at"]?.stringValue ?? "")
        }
      }
    }
  }

  public func botConversationEntries(id: String, limit: Int = 200) async throws -> [BotConversationEntryRecord] {
    try await read { connection in
      try connection.withLock {
        try connection.historyRowsUnlocked("""
          SELECT * FROM (SELECT * FROM bot_conversation_entries WHERE bot_conversation_id=? ORDER BY entry_id DESC LIMIT ?) ORDER BY entry_id
          """, values: [id, String(max(1, min(limit, 1_000)))]).compactMap { row in
          guard let o = row.objectValue, let key = o["id"]?.stringValue, let entry = o["entry_id"]?.intValue else { return nil }
          return BotConversationEntryRecord(id: key, entryID: entry, role: o["role"]?.stringValue ?? "assistant",
            text: o["text"]?.stringValue ?? "", error: o["error"]?.stringValue, stopped: o["stopped"]?.intValue == 1,
            createdAt: o["created_at"]?.stringValue ?? "")
        }
      }
    }
  }
}
