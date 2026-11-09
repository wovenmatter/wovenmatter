import Foundation
import WovenMatterCore

/// What a bots runtime reports about one bot's conversation. Entry IDs are the
/// runtime's own, unique per bot, so a repeated report never duplicates a row.
public struct BotConversationReport: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var id: Int
    /// The conversation the entry was said in; defaults to the report's.
    public var conversationId: Int?
    public var role: String
    public var text: String
    public var error: String?
    public var createdAt: String?
    public init(id: Int, conversationId: Int? = nil, role: String, text: String, error: String? = nil, createdAt: String? = nil) {
      self.id = id; self.conversationId = conversationId; self.role = role; self.text = text; self.error = error; self.createdAt = createdAt
    }
  }
  public var botName: String
  public var conversationId: Int
  /// The bot's main channel; equal to `conversationId` unless this is a thread.
  public var mainConversationId: Int?
  public var title: String?
  public var entries: [Entry]
  public init(botName: String, conversationId: Int, mainConversationId: Int? = nil, title: String? = nil, entries: [Entry]) {
    self.botName = botName; self.conversationId = conversationId; self.mainConversationId = mainConversationId
    self.title = title; self.entries = entries
  }
}

public struct BotConversationRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let machineID: String
  public let botID: String
  public let botName: String
  public let conversationID: Int
  public let mainConversationID: Int?
  public let title: String?
  public let updatedAt: String
}

public struct BotConversationEntryRecord: Codable, Equatable, Sendable, Identifiable {
  public let id: String
  public let entryID: Int
  public let role: String
  public let text: String
  public let error: String?
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
        conversation_id INTEGER NOT NULL, main_conversation_id INTEGER, title TEXT,
        created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT);
      CREATE TABLE IF NOT EXISTS bot_conversation_entries(
        id TEXT PRIMARY KEY, conversation TEXT NOT NULL, entry_id INTEGER NOT NULL,
        role TEXT NOT NULL, text TEXT NOT NULL, error TEXT, created_at TEXT NOT NULL);
      CREATE INDEX IF NOT EXISTS bot_conversation_entries_conversation ON bot_conversation_entries(conversation, entry_id);
      """) }
  }

  static func botConversationKey(machineID: String, botID: String, conversationID: Int) -> String {
    machineID.lowercased() + ":" + botID.lowercased() + ":" + String(conversationID)
  }
}

extension WorkspaceDatabase {
  public static let maximumBotReportEntries = 500
  public static let maximumBotEntryCharacters = 1_000_000

  /// Records a runtime's report. Returns how many entries were new.
  @discardableResult
  public func recordBotConversation(machineID: String, botID: String, _ report: BotConversationReport,
                                    now: Date = Date()) async throws -> Int {
    guard WovenMCPCaller.isIdentifier(machineID), WovenMCPCaller.isIdentifier(botID) else {
      throw WorkspaceToolError.invalid("Invalid bot or machine ID.")
    }
    guard report.entries.count <= Self.maximumBotReportEntries else {
      throw WorkspaceToolError.invalid("Report at most \(Self.maximumBotReportEntries) entries at a time.")
    }
    for entry in report.entries {
      guard ["user", "assistant", "system", "tool"].contains(entry.role) else { throw WorkspaceToolError.invalid("Unknown entry role.") }
      guard entry.text.utf8.count <= Self.maximumBotEntryCharacters else { throw WorkspaceToolError.invalid("A bot entry exceeds its size limit.") }
    }
    let stamp = ISO8601DateFormatter().string(from: now)
    let name = String(report.botName.prefix(128))
    let title = report.title.map { String($0.prefix(256)) }
    return try await write { connection in
      try connection.transaction {
        func ensure(_ conversationID: Int) throws -> String {
          let key = WorkspaceDatabaseConnection.botConversationKey(machineID: machineID, botID: botID, conversationID: conversationID)
          let isReported = conversationID == report.conversationId
          try connection.toolsExecuteUnlocked("""
            INSERT INTO bot_conversations(id,machine_id,bot_id,bot_name,conversation_id,main_conversation_id,title,created_at,updated_at)
            VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET bot_name=excluded.bot_name,updated_at=excluded.updated_at,
              main_conversation_id=coalesce(excluded.main_conversation_id,main_conversation_id),
              title=coalesce(excluded.title,title),deleted_at=NULL
            """, [key, machineID.lowercased(), botID.lowercased(), name, String(conversationID),
                  (isReported ? report.mainConversationId : nil).map { String($0) },
                  isReported ? title : nil, stamp, stamp])
          return key
        }
        _ = try ensure(report.conversationId)
        var inserted = 0
        for entry in report.entries {
          let conversation = try ensure(entry.conversationId ?? report.conversationId)
          let id = machineID.lowercased() + ":" + botID.lowercased() + ":" + String(entry.id)
          let existing = try connection.historyRowsUnlocked("SELECT text,error FROM bot_conversation_entries WHERE id=?", values: [id]).first?.objectValue
          if let existing {
            // A runtime may finish an entry it reported partially; never rewrite an unchanged row.
            guard existing["text"]?.stringValue != entry.text || existing["error"]?.stringValue != entry.error else { continue }
            try connection.toolsExecuteUnlocked("UPDATE bot_conversation_entries SET text=?,error=? WHERE id=?", [entry.text, entry.error, id])
          } else {
            try connection.toolsExecuteUnlocked("""
              INSERT INTO bot_conversation_entries(id,conversation,entry_id,role,text,error,created_at) VALUES(?,?,?,?,?,?,?)
              """, [id, conversation, String(entry.id), entry.role, entry.text, entry.error, entry.createdAt ?? stamp])
            inserted += 1
          }
        }
        return inserted
      }
    }
  }

  /// Marks a bot's conversations deleted, as its runtime did. Entries stay for history.
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
          SELECT * FROM bot_conversations WHERE deleted_at IS NULL AND (? IS NULL OR machine_id=?) ORDER BY bot_name,bot_id,conversation_id
          """, values: [machineID?.lowercased(), machineID?.lowercased()]).compactMap { row in
          guard let o = row.objectValue, let id = o["id"]?.stringValue, let machine = o["machine_id"]?.stringValue,
                let bot = o["bot_id"]?.stringValue, let conversation = o["conversation_id"]?.intValue else { return nil }
          return BotConversationRecord(id: id, machineID: machine, botID: bot, botName: o["bot_name"]?.stringValue ?? "Bot",
            conversationID: conversation, mainConversationID: o["main_conversation_id"]?.intValue,
            title: o["title"]?.stringValue, updatedAt: o["updated_at"]?.stringValue ?? "")
        }
      }
    }
  }

  public func botConversationEntries(id: String, limit: Int = 200) async throws -> [BotConversationEntryRecord] {
    try await read { connection in
      try connection.withLock {
        try connection.historyRowsUnlocked("""
          SELECT * FROM (SELECT * FROM bot_conversation_entries WHERE conversation=? ORDER BY entry_id DESC LIMIT ?) ORDER BY entry_id
          """, values: [id, String(max(1, min(limit, 1_000)))]).compactMap { row in
          guard let o = row.objectValue, let key = o["id"]?.stringValue, let entry = o["entry_id"]?.intValue else { return nil }
          return BotConversationEntryRecord(id: key, entryID: entry, role: o["role"]?.stringValue ?? "assistant",
            text: o["text"]?.stringValue ?? "", error: o["error"]?.stringValue, createdAt: o["created_at"]?.stringValue ?? "")
        }
      }
    }
  }
}
