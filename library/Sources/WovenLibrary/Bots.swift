import Foundation
import WovenProtocol

/// One push of the bots runtime's finished entries, already mapped to the
/// library's shapes by the home machine's server. Saved in one transaction
/// with its checkpoint.
public struct BotMirror: Sendable {
  public struct Bot: Sendable {
    public var id: String
    public var name: String
    public var isAdmin: Bool
    public var manager: Bool
    public var managerID: String?
    public var orchestrator: Bool
    public var trashed: Bool
    public var createdAt: Date

    public init(id: String, name: String, isAdmin: Bool, manager: Bool, managerID: String?, orchestrator: Bool,
                trashed: Bool, createdAt: Date) {
      self.id = id
      self.name = name
      self.isAdmin = isAdmin
      self.manager = manager
      self.managerID = managerID
      self.orchestrator = orchestrator
      self.trashed = trashed
      self.createdAt = createdAt
    }
  }

  /// A bot conversation or Forum room, held by the session `sessionID`.
  public struct Chat: Sendable {
    public var sessionID: String
    /// Nil for a Forum room.
    public var botID: String?
    public var conversationID: Int
    public var kind: SavedBotChat.Kind
    /// A thread's parent conversation; for a Forum thread, the Forum's room
    /// (looked up when nil).
    public var parentConversationID: Int?
    /// Nil for a Forum thread whose title is the start of its parent post.
    public var title: String?
    /// The post a Forum thread starts from, for its title.
    public var parentPostID: Int?
    public var pinned: Bool
    public var createdAt: Date

    public init(sessionID: String, botID: String?, conversationID: Int, kind: SavedBotChat.Kind,
                parentConversationID: Int?, title: String?, parentPostID: Int? = nil, pinned: Bool, createdAt: Date) {
      self.sessionID = sessionID
      self.botID = botID
      self.conversationID = conversationID
      self.kind = kind
      self.parentConversationID = parentConversationID
      self.title = title
      self.parentPostID = parentPostID
      self.pinned = pinned
      self.createdAt = createdAt
    }
  }

  public struct Usage: Sendable {
    public var model: String
    public var input: Int64
    public var output: Int64
    public var cacheRead: Int64
    public var cacheWrite: Int64
    public var cost: Double

    public init(model: String, input: Int64, output: Int64, cacheRead: Int64, cacheWrite: Int64, cost: Double) {
      self.model = model
      self.input = input
      self.output = output
      self.cacheRead = cacheRead
      self.cacheWrite = cacheWrite
      self.cost = cost
    }
  }

  public struct Item: Sendable {
    /// Stable forever: a resend carries the same id and is skipped.
    public var id: String
    public var sessionID: String
    public var content: ItemContent
    public var author: ItemAuthor?
    public var createdAt: Date

    public init(id: String, sessionID: String, content: ItemContent, author: ItemAuthor? = nil, createdAt: Date) {
      self.id = id
      self.sessionID = sessionID
      self.content = content
      self.author = author
      self.createdAt = createdAt
    }
  }

  /// One model turn's usage. Its id is the bot's and the entry's, the same on
  /// every home machine, so a transfer never records a turn twice.
  public struct UsageRecord: Sendable {
    public var id: String
    public var sessionID: String
    public var createdAt: Date
    public var usage: Usage

    public init(id: String, sessionID: String, createdAt: Date, usage: Usage) {
      self.id = id
      self.sessionID = sessionID
      self.createdAt = createdAt
      self.usage = usage
    }
  }

  public var bot: Bot?
  public var chats: [Chat]
  /// In order; each session's items continue its sequence.
  public var items: [Item]
  public var usage: [UsageRecord]
  /// `bot:<botId>` or `forum`.
  public var checkpoint: String
  /// The runtime's entries through this one are covered.
  public var upTo: Int64

  public init(bot: Bot?, chats: [Chat], items: [Item], usage: [UsageRecord] = [], checkpoint: String, upTo: Int64) {
    self.bot = bot
    self.chats = chats
    self.items = items
    self.usage = usage
    self.checkpoint = checkpoint
    self.upTo = upTo
  }
}

extension Library {
  /// Saves one push of the bots runtime: the bot's row, a session (runtime
  /// `bots`, owned by this machine) and `bot_chats` row for each chat that
  /// lacks one, their titles and pinned flags, every item not stored yet with
  /// its usage, and the checkpoint, all in one transaction. A chat whose
  /// session the person deleted is left deleted, and its items are dropped.
  public func saveBotMirror(_ mirror: BotMirror) async throws {
    let machineID = machineID
    try await write { writer in
      if let bot = mirror.bot { try Self.saveBot(bot, machineID: machineID, writer) }
      for chat in mirror.chats { try Self.saveChat(chat, machineID: machineID, writer) }
      var last: [String: Int64] = [:]
      for item in mirror.items {
        guard let session = try writer.row("sessions", item.sessionID) else {
          throw LibraryError(.invalid, "Bot items for \(item.sessionID) came before its conversation.")
        }
        if session.bool("deleted") || session.text("machine_id") != machineID { continue }
        if try writer.row("session_items", item.id) != nil { continue }
        let sequence: Int64
        if let previous = last[item.sessionID] {
          sequence = previous + 1
        } else {
          sequence = (try writer.db.query("SELECT MAX(sequence) AS last FROM session_items WHERE session_id = ?",
                                          [.text(item.sessionID)]).first?.integer("last") ?? 0) + 1
        }
        last[item.sessionID] = sequence
        let created = Self.millis(item.createdAt)
        try writer.put("session_items", id: item.id, [
          "session_id": .text(item.sessionID), "sequence": .integer(sequence), "kind": .text(item.content.kindName),
          "body": .text(String(decoding: try Wire.encoder.encode(item.content), as: UTF8.self)),
          "author": try item.author.map { .text(String(decoding: try Wire.encoder.encode($0), as: UTF8.self)) } ?? .null,
          "created_at": .integer(created),
        ])
      }
      for record in mirror.usage where try writer.row("usage_records", record.id) == nil {
        let usage = record.usage
        try writer.put("usage_records", id: record.id, [
          "machine_id": .text(machineID), "session_id": .text(record.sessionID), "runtime": .text(RuntimeKind.bots.rawValue),
          "model": .text(usage.model), "input_tokens": .integer(usage.input), "output_tokens": .integer(usage.output),
          "cache_read_tokens": .integer(usage.cacheRead), "cache_write_tokens": .integer(usage.cacheWrite),
          "cost": .real(usage.cost), "recorded_at": .integer(Self.millis(record.createdAt)),
        ])
      }
      try writer.db.run("""
        INSERT INTO bot_checkpoints (key, entry) VALUES (?, ?)
        ON CONFLICT(key) DO UPDATE SET entry = MAX(entry, excluded.entry)
        """, [.text(mirror.checkpoint), .integer(mirror.upTo)])
    }
  }

  private static func saveBot(_ bot: BotMirror.Bot, machineID: String, _ writer: Writer) throws {
    let values: [String: SQLValue] = [
      "machine_id": .text(machineID), "name": .text(bot.name), "kind": .text(bot.isAdmin ? "admin" : "bot"),
      "manager": .integer(bot.manager ? 1 : 0), "manager_id": bot.managerID.map(SQLValue.text) ?? .null,
      "orchestrator": .integer(bot.orchestrator ? 1 : 0), "trashed": .integer(bot.trashed ? 1 : 0),
      "created_at": .integer(millis(bot.createdAt)),
    ]
    try putChanged("bots", id: bot.id, values, writer)
  }

  private static func saveChat(_ chat: BotMirror.Chat, machineID: String, _ writer: Writer) throws {
    if let row = try writer.row("sessions", chat.sessionID), row.bool("deleted") { return }
    let title = try chat.title ?? parentPostTitle(chat.parentPostID, machineID: machineID, writer) ?? "Untitled thread"
    var parent = chat.parentConversationID
    if parent == nil, chat.kind == .forumThread {
      parent = try writer.db.query("""
        SELECT c.conversation_id FROM bot_chats c JOIN sessions s ON s.id = c.session_id
        WHERE c.kind = 'forum' AND c.deleted = 0 AND s.machine_id = ? LIMIT 1
        """, [.text(machineID)]).first?.integer("conversation_id").map { Int($0) }
    }
    if try writer.row("sessions", chat.sessionID) == nil {
      try writer.put("sessions", id: chat.sessionID, [
        "machine_id": .text(machineID), "runtime": .text(RuntimeKind.bots.rawValue), "title": .text(title),
        "pinned": .integer(chat.pinned ? 1 : 0), "created_at": .integer(millis(chat.createdAt)),
      ])
    } else {
      try putChanged("sessions", id: chat.sessionID, ["title": .text(title), "pinned": .integer(chat.pinned ? 1 : 0)], writer)
    }
    try putChanged("bot_chats", id: chat.sessionID, [
      "session_id": .text(chat.sessionID), "bot_id": .text(chat.botID ?? ""),
      "conversation_id": .integer(Int64(chat.conversationID)), "kind": .text(chat.kind.rawValue),
      "parent_conversation_id": parent.map { .integer(Int64($0)) } ?? .null,
    ], writer)
  }

  /// The start of the Forum post a thread starts from, as stored here.
  private static func parentPostTitle(_ postID: Int?, machineID: String, _ writer: Writer) throws -> String? {
    guard let postID else { return nil }
    let body = try writer.db.query("""
      SELECT body FROM session_items WHERE session_id LIKE ? AND id = session_id || ':' || ? AND deleted = 0 LIMIT 1
      """, [.text("forum:\(machineID):%"), .text(String(postID))]).first?.text("body")
    guard let body, let content = try? Wire.decoder.decode(ItemContent.self, from: Data(body.utf8)) else { return nil }
    switch content {
    case .userMessage(let text, _), .assistantMessage(let text): return threadTitle(fromPost: text)
    default: return nil
    }
  }

  /// A Forum thread's title from its parent post: the first line, shortened.
  public static func threadTitle(fromPost text: String) -> String? {
    let line = text.split(whereSeparator: \.isNewline).first.map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    guard let line, !line.isEmpty else { return nil }
    return line.count > 60 ? String(line.prefix(59)) + "…" : line
  }

  /// Writes only the columns that differ, so an unchanged resend writes nothing.
  /// A deleted row stays deleted.
  private static func putChanged(_ table: String, id: String, _ values: [String: SQLValue], _ writer: Writer) throws {
    let row = try writer.row(table, id)
    if row?.bool("deleted") == true { return }
    let changes = row.map { row in values.filter { row[$0.key] != $0.value } } ?? values
    if !changes.isEmpty { try writer.put(table, id: id, changes) }
  }

  /// How far the runtime's entries are saved here, by checkpoint key.
  public func botCheckpoints() async throws -> [String: Int64] {
    try await read { db in
      var checkpoints: [String: Int64] = [:]
      for row in try db.query("SELECT key, entry FROM bot_checkpoints") {
        if let key = row.text("key") { checkpoints[key] = row.integer("entry") ?? 0 }
      }
      return checkpoints
    }
  }

  /// A bot purged in the runtime: its chats (with their items), its row and
  /// its checkpoint go, in every library.
  public func purgeBot(_ botID: String) async throws {
    try await write { writer in
      let sessions = try writer.db.query("SELECT session_id FROM bot_chats WHERE bot_id = ? AND deleted = 0", [.text(botID)])
        .compactMap { $0.text("session_id") }
      for session in sessions { try writer.delete("sessions", id: session) }
      if try writer.row("bots", botID) != nil { try writer.delete("bots", id: botID) }
      try writer.db.run("DELETE FROM bot_checkpoints WHERE key = ?", [.text("bot:" + botID)])
    }
  }

  // MARK: Transfer

  /// What a transfer's target must hold before it becomes the home: the bots
  /// and chats this machine's library holds as their home, and its checkpoints.
  public func botsTransferExpected() async throws -> BotsTransferExpected {
    let machineID = machineID
    return try await read { db in
      let bots = try db.query("SELECT id FROM bots WHERE machine_id = ? AND deleted = 0", [.text(machineID)])
        .compactMap { $0.text("id") }
      let chats = try db.query("""
        SELECT c.bot_id, c.conversation_id FROM bot_chats c JOIN sessions s ON s.id = c.session_id
        WHERE s.machine_id = ? AND s.deleted = 0 AND c.deleted = 0
        """, [.text(machineID)]).map { row in
        let bot = row.text("bot_id") ?? ""
        return BotsTransferExpected.Chat(botID: bot.isEmpty ? nil : bot, conversationID: Int(row.integer("conversation_id") ?? 0))
      }
      var checkpoints: [String: Int64] = [:]
      for row in try db.query("SELECT key, entry FROM bot_checkpoints") {
        if let key = row.text("key") { checkpoints[key] = row.integer("entry") ?? 0 }
      }
      return BotsTransferExpected(bots: bots, chats: chats, checkpoints: checkpoints)
    }
  }

  /// What of `expected` this machine's library does not hold yet as the bots'
  /// home: a bot, a chat (under session ids starting `sessions`), or a live
  /// bot's or the Forum's entries up to the old home's checkpoint. Nil when it
  /// holds everything.
  public func botsTransferMissing(_ expected: BotsTransferExpected, sessions: String) async throws -> String? {
    let machineID = machineID
    return try await read { db in
      var live: Set<String> = []
      for id in expected.bots {
        guard let row = try db.query("SELECT machine_id, trashed FROM bots WHERE id = ? AND deleted = 0", [.text(id)]).first,
              row.text("machine_id") == machineID else { return "bot \(id)" }
        if !row.bool("trashed") { live.insert(id) }
      }
      for chat in expected.chats {
        let session = chat.botID.map { "bot:\(sessions):\($0):\(chat.conversationID)" } ?? "forum:\(sessions):\(chat.conversationID)"
        if try db.query("SELECT id FROM bot_chats WHERE id = ? AND deleted = 0", [.text(session)]).isEmpty { return "chat \(session)" }
      }
      var held: [String: Int64] = [:]
      for row in try db.query("SELECT key, entry FROM bot_checkpoints") {
        if let key = row.text("key") { held[key] = row.integer("entry") ?? 0 }
      }
      for (key, entry) in expected.checkpoints where key == "forum" || live.contains(String(key.dropFirst(4))) {
        if (held[key] ?? 0) < entry { return "the entries of \(key)" }
      }
      return nil
    }
  }

  /// After a transfer away: the bot chats and Forum rooms this machine owned
  /// are deleted in every library (the new home saved them under its own),
  /// and its checkpoints go. The bots' rows stay: the new home writes them.
  public func removeBotChats() async throws {
    let machineID = machineID
    try await write { writer in
      let sessions = try writer.db.query("SELECT id FROM sessions WHERE machine_id = ? AND runtime = ? AND deleted = 0",
                                         [.text(machineID), .text(RuntimeKind.bots.rawValue)]).compactMap { $0.text("id") }
      for session in sessions { try writer.delete("sessions", id: session) }
      try writer.db.run("DELETE FROM bot_checkpoints")
    }
  }

  /// The bots and their chats as stored here, for reading while the home
  /// machine is away.
  public func savedBots() async throws -> SavedBots {
    let rows = try await read { db in
      (try db.query("SELECT * FROM bots WHERE deleted = 0 ORDER BY kind = 'admin' DESC, created_at, id"),
       try db.query("SELECT * FROM bot_chats WHERE deleted = 0"))
    }
    let bots = rows.0.map { row in
      SavedBot(id: row.text("id") ?? "", homeMachineID: row.text("machine_id") ?? "", name: row.text("name") ?? "",
               isAdmin: row.text("kind") == "admin", manager: row.bool("manager"), managerID: row.text("manager_id"),
               orchestrator: row.bool("orchestrator"), trashed: row.bool("trashed"), createdAt: row.date("created_at"))
    }
    let sessions = Dictionary(try await self.sessions(includeArchived: true).filter { $0.runtime == .bots }.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
    let chats = rows.1.compactMap { row -> SavedBotChat? in
      guard let session = sessions[row.text("session_id") ?? ""],
            let kind = SavedBotChat.Kind(rawValue: row.text("kind") ?? "") else { return nil }
      let botID = row.text("bot_id") ?? ""
      return SavedBotChat(session: session, botID: botID.isEmpty ? nil : botID,
                          conversationID: Int(row.integer("conversation_id") ?? 0), kind: kind,
                          parentConversationID: row.integer("parent_conversation_id").map { Int($0) })
    }.sorted { $0.session.createdAt == $1.session.createdAt ? $0.session.id < $1.session.id : $0.session.createdAt < $1.session.createdAt }
    return SavedBots(bots: bots, chats: chats)
  }
}
