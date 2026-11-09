import Foundation
import WovenMatterCore

/// One batch from a bots runtime (docs/architecture/WOVEN_EVERYWHERE.md,
/// "Runtime host API"): `{bot: {id, name}, conversations, entries}`.
/// Conversations and entries keep the runtime's own fields; they are stored
/// as shared library rows so every device sees them.
public struct BotEntriesBatch: Codable, Sendable {
  public struct Bot: Codable, Sendable { public let id: String; public let name: String }
  public let bot: Bot
  public let conversations: [GatewayJSONValue]
  public let entries: [GatewayJSONValue]
}

public struct BotEntriesResult: Codable, Equatable, Sendable {
  public let conversations: Int
  public let entries: Int
}

public struct BotConversationRecord: Codable, Equatable, Sendable {
  public let machineID: String
  public let botID: String
  public let botName: String
  public let conversation: GatewayJSONValue
}
public struct BotEntryRecord: Codable, Equatable, Sendable {
  public let machineID: String
  public let botID: String
  public let entry: GatewayJSONValue
}

extension WorkspaceDatabaseConnection {
  /// Shared rows keyed by the bot's machine, the bot and the runtime's own
  /// conversation or entry id. A resent batch changes nothing.
  func migrateBotConversations() throws {
    try executeUnlocked("""
      CREATE TABLE IF NOT EXISTS bot_conversations(machine_id TEXT NOT NULL, bot_id TEXT NOT NULL, conversation_id TEXT NOT NULL,
        bot_name TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(machine_id, bot_id, conversation_id));
      CREATE TABLE IF NOT EXISTS bot_conversation_entries(machine_id TEXT NOT NULL, bot_id TEXT NOT NULL, entry_id TEXT NOT NULL,
        conversation_id TEXT NOT NULL, payload TEXT NOT NULL, PRIMARY KEY(machine_id, bot_id, entry_id));
      CREATE INDEX IF NOT EXISTS bot_conversation_entries_by_conversation ON bot_conversation_entries(machine_id, bot_id, conversation_id);
      """)
  }
}

extension WorkspaceDatabase {
  /// Validates like the Node adapter (`remote/src/bots-library.mjs`) and
  /// upserts by `(machine, bot, id)`.
  public func writeBotEntries(machineID: String, botID: String, batch: BotEntriesBatch) async throws -> BotEntriesResult {
    func invalid(_ message: String) -> CompanionAPIError { .init(code: "invalid_request", message: message) }
    guard let bot = UUID(uuidString: botID)?.uuidString.lowercased(), batch.bot.id.lowercased() == bot,
          !batch.bot.name.isEmpty, batch.bot.name.count <= 256 else { throw invalid("The batch must name its bot.") }
    guard batch.conversations.count <= 10_000, batch.entries.count <= 200 else { throw invalid("Send at most 200 conversation entries per batch.") }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    var conversations: [(String, String)] = [], known = Set<String>()
    for item in batch.conversations {
      guard let object = item.objectValue, let id = object["conversationId"]?.stringValue, !id.isEmpty, id.count <= 128,
            let kind = object["kind"]?.stringValue, ["main", "thread"].contains(kind) else { throw invalid("Invalid bot conversations.") }
      known.insert(id); conversations.append((id, String(decoding: try encoder.encode(item), as: UTF8.self)))
    }
    var entries: [(String, String, String)] = []
    for item in batch.entries {
      guard let object = item.objectValue, let id = object["id"]?.stringValue, !id.isEmpty, id.count <= 128,
            let conversation = object["conversationId"]?.stringValue, known.contains(conversation),
            let role = object["role"]?.stringValue, ["user", "assistant"].contains(role), object["text"]?.stringValue != nil else {
        throw invalid("Every entry needs an id, a listed conversation, a role and text.")
      }
      entries.append((id, conversation, String(decoding: try encoder.encode(item), as: UTF8.self)))
    }
    guard try encoder.encode(batch).count <= 8 * 1_024 * 1_024 else { throw CompanionAPIError(code: "too_large", message: "The conversation batch is too large.") }
    let machine = machineID.lowercased(), name = batch.bot.name
    let conversationRows = conversations, entryRows = entries
    try await write { connection in
      try connection.transaction {
        for (id, payload) in conversationRows {
          try connection.toolsExecuteUnlocked("""
            INSERT INTO bot_conversations VALUES(?,?,?,?,?) ON CONFLICT(machine_id,bot_id,conversation_id) DO UPDATE SET
              bot_name=excluded.bot_name,payload=excluded.payload WHERE bot_name IS NOT excluded.bot_name OR payload IS NOT excluded.payload
            """, [machine, bot, id, name, payload])
        }
        for (id, conversation, payload) in entryRows {
          try connection.toolsExecuteUnlocked("""
            INSERT INTO bot_conversation_entries VALUES(?,?,?,?,?) ON CONFLICT(machine_id,bot_id,entry_id) DO UPDATE SET
              conversation_id=excluded.conversation_id,payload=excluded.payload
              WHERE conversation_id IS NOT excluded.conversation_id OR payload IS NOT excluded.payload
            """, [machine, bot, id, conversation, payload])
        }
      }
    }
    return .init(conversations: conversations.count, entries: entries.count)
  }

  public func botConversations(machineID: String? = nil) async throws -> [BotConversationRecord] {
    try await read { connection in
      try connection.historyRowsUnlocked("SELECT machine_id,bot_id,bot_name,payload FROM bot_conversations WHERE ?1 IS NULL OR machine_id=?1 ORDER BY machine_id,bot_id,conversation_id",
                                         values: [machineID?.lowercased()]).compactMap { row in
        guard let object = row.objectValue, let payload = object["payload"]?.stringValue,
              let value = try? JSONDecoder().decode(GatewayJSONValue.self, from: Data(payload.utf8)) else { return nil }
        return .init(machineID: object["machine_id"]?.stringValue ?? "", botID: object["bot_id"]?.stringValue ?? "",
                     botName: object["bot_name"]?.stringValue ?? "", conversation: value)
      }
    }
  }

  public func botEntries(machineID: String, botID: String, conversationID: String) async throws -> [BotEntryRecord] {
    try await read { connection in
      try connection.historyRowsUnlocked("SELECT payload FROM bot_conversation_entries WHERE machine_id=? AND bot_id=? AND conversation_id=? ORDER BY entry_id",
                                         values: [machineID.lowercased(), botID.lowercased(), conversationID]).compactMap { row in
        guard let payload = row.objectValue?["payload"]?.stringValue,
              let value = try? JSONDecoder().decode(GatewayJSONValue.self, from: Data(payload.utf8)) else { return nil }
        return .init(machineID: machineID.lowercased(), botID: botID.lowercased(), entry: value)
      }
    }
  }
}
