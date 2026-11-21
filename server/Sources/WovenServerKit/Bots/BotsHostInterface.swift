import Foundation
import Synchronization
import WovenLibrary
import WovenProtocol

/// What the bots runtime asks of the server that runs it: the `host`
/// requests of `bots/src/protocol.ts`, implemented once, here. Each takes the
/// request's `params` and returns its `data`.
struct BotsHostInterface: Sendable {
  let library: Library
  let secrets: Secrets
  let tenure: BotsTenure
  /// Where the visual replies of chats that came with the bots are fetched from.
  let peers: PeerSync
  /// The Woven MCP, once the server has made it.
  let tools = ToolsLink()

  /// The host: this one.
  private var host: String { library.machineID }
  /// What the chats' session ids start with: this machine and its stint as the host.
  private var sessions: String { host + ":" + tenure.current }

  func handle(_ method: String, _ params: JSONValue) async throws -> JSONValue {
    switch method {
    case "credentials":
      guard let provider = params["provider"]?.string else { throw RuntimeError.failed("credentials needs a provider.") }
      return try await credentials(provider)
    case "credentials.update":
      // A subscription the runtime renewed: kept as Pi Durable's renewals are.
      guard let provider = params["provider"]?.string, PiDurableRuntime.subscriptions.contains(provider),
            let credential = params["credential"], credential != .null else {
        throw RuntimeError.failed("credentials.update needs a subscription provider and its credential.")
      }
      try await secrets.setSubscription(provider, credential)
      return .object([:])
    case "git.setup":
      guard let botID = params["botId"]?.string else { throw RuntimeError.failed("git.setup needs a botId.") }
      return try await gitSetup(botID)
    case "git.agent":
      guard let botID = params["botId"]?.string, let message = params["message"]?.string.flatMap({ Data(base64Encoded: $0) }) else {
        throw RuntimeError.failed("git.agent needs a botId and a base64 message.")
      }
      // Answered with this machine's GitHub key while the bot may use it, else refused.
      let reply = SSHAgent.reply(to: message, key: await gitKey(for: botID))
      return .object(["message": .string(reply.base64EncodedString())])
    case "tools.access":
      guard let botID = params["botId"]?.string else { throw RuntimeError.failed("tools.access needs a botId.") }
      return .object(["allowed": .bool(await toolsAllowed(botID))])
    case "tools.list":
      // Asked again on every connection, so a changed setting applies then.
      guard let botID = params["botId"]?.string else { throw RuntimeError.failed("tools.list needs a botId.") }
      guard await toolsAllowed(botID), let tools = tools.current else { return .object(["allowed": .bool(false)]) }
      return .object(["allowed": .bool(true), "tools": .array(tools.listing(forBots: true)),
                      "instructions": .string(WovenInstructions.forBots)])
    case "tools.call":
      guard let botID = params["botId"]?.string, let name = params["name"]?.string else {
        throw RuntimeError.failed("tools.call needs a botId and a name.")
      }
      guard await toolsAllowed(botID), let tools = tools.current else {
        return try JSONValue(encoding: ToolResult.error("Woven tools are turned off for this bot in Settings."))
      }
      // `forum`: the bot is answering in the Forum, not in one of its own chats.
      let caller = ToolCaller(machineID: host, botID: botID, inForum: params["forum"]?.bool == true ? true : nil)
      return try JSONValue(encoding: await tools.call(name, arguments: params["arguments"] ?? .object([:]), caller: caller))
    case "mirror.checkpoints":
      var bots: [String: JSONValue] = [:], seats: [String: JSONValue] = [:]
      var forum: Int64 = 0
      for (key, entry) in try await library.botCheckpoints() {
        if key == "forum" { forum = entry }
        else if key.hasPrefix("bot:") { bots[String(key.dropFirst(4))] = .integer(entry) }
        else if key.hasPrefix("seat:") { seats[String(key.dropFirst(5))] = .integer(entry) }
      }
      return .object(["bots": .object(bots), "forum": .integer(forum), "seats": .object(seats)])
    case "mirror.bot":
      let push = try params.decode(MirrorBot.self)
      try await library.saveBotMirror(BotsMirrorMapping.bot(push, host: sessions))
      fetchMissing(push.items.compactMap(\.visualReply?.digest))
      return .object([:])
    case "mirror.forum":
      let push = try params.decode(MirrorForum.self)
      try await library.saveBotMirror(BotsMirrorMapping.forum(push, host: sessions))
      fetchMissing(push.posts.compactMap(\.visualReply?.digest))
      return .object([:])
    case "mirror.purge":
      guard let botID = params["botId"]?.string else { throw RuntimeError.failed("mirror.purge needs a botId.") }
      try await library.purgeBot(botID)
      return .object([:])
    default:
      throw RuntimeError.failed("Woven Matter does not offer \(method).")
    }
  }

  /// After a transfer the visual replies of the chats and the Forum are still
  /// on the old host: fetched now, so this host holds them before the old one
  /// goes away.
  private func fetchMissing(_ digests: [String]) {
    guard !digests.isEmpty else { return }
    Task { [library, peers] in
      for digest in digests where (try? await library.hasContent(digest)) == false { _ = await peers.fetchContent(digest) }
    }
  }

  /// One provider's credential in Pi Durable's shape, or null. `web-search`
  /// is the search provider chosen in Pi Durable's settings (else the first
  /// with a key), with its key.
  private func credentials(_ provider: String) async throws -> JSONValue {
    let all = await secrets.piCredentials(subscriptions: PiDurableRuntime.subscriptions)
    guard provider == "web-search" else { return .object(["credential": all[provider] ?? .null]) }
    let preferred = await secrets.piSettings()["searchProvider"]?.string
    let order = ["exa", "brave", "firecrawl"]
    let candidates = (preferred.map { [$0] } ?? []) + order.filter { $0 != preferred }
    guard let chosen = candidates.first(where: { order.contains($0) && all[$0] != nil }) else {
      return .object(["credential": .null])
    }
    return .object(["credential": all[chosen] ?? .null, "searchProvider": .string(chosen)])
  }

  /// Settings > GitHub for one bot: the key's public half while the bot may
  /// use it (the bot is a place of `github.access`), and the commit identity.
  private func gitSetup(_ botID: String) async throws -> JSONValue {
    let identity = (try? await library.setting(GitHub.identityKey)?.value.decode(GitHubIdentity.self)) ?? GitHubIdentity()
    let key = await gitKey(for: botID)
    return .object([
      "publicKey": key.map { .string($0.summary.publicKey) } ?? .null,
      "identity": identity.name.isEmpty && identity.email.isEmpty
        ? .null : .object(["name": .string(identity.name), "email": .string(identity.email)]),
    ])
  }

  private func gitKey(for botID: String) async -> OpenSSHKey? {
    let access = (try? await library.setting(GitHub.accessKey)?.value.decode(GitHubPlaces.self)) ?? GitHubPlaces()
    guard access.allows(botID), let stored = try? await secrets.secret(Secrets.gitHubKey) else { return nil }
    return try? OpenSSHKey(text: String(decoding: stored, as: UTF8.self))
  }

  /// The setting `bots.wovenTools`: allowed unless paused for all or denied for this bot.
  private func toolsAllowed(_ botID: String) async -> Bool {
    guard let value = (try? await library.setting(botsWovenToolsSetting))?.value else { return true }
    if value["paused"]?.bool == true { return false }
    return !(value["denied"]?.array ?? []).contains(.string(botID))
  }
}

// MARK: The runtime's mirror pushes

struct MirrorBot: Decodable, Sendable {
  struct Bot: Decodable, Sendable {
    var id: String
    var name: String
    var kind: String
    var manager: Bool
    var managerId: String?
    var orchestrator: Bool
    var deleted: Bool
    var createdAt: String
  }

  struct Conversation: Decodable, Sendable {
    var conversationId: Int
    var kind: String
    var parentConversationId: Int?
    var title: String?
    var pinned: Bool?
    var createdAt: String
  }

  struct Item: Decodable, Sendable {
    struct Tool: Decodable, Sendable {
      var name: String
      var input: String
      var output: String?
      var failed: Bool
    }

    struct Usage: Decodable, Sendable {
      var model: String
      var input: Int64
      var output: Int64
      var cacheRead: Int64
      var cacheWrite: Int64
      var cost: Double
    }

    var key: String
    var conversationId: Int
    var createdAt: Double
    var kind: String
    var text: String?
    var tool: Tool?
    /// A visual reply the bot published with `render_html`.
    var visualReply: VisualReply?
    /// A message an agent session sent (`message_bot`).
    var from: From?
    var usage: Usage?

    struct From: Decodable, Sendable {
      var name: String
      var sessionId: String
    }
  }

  var bot: Bot
  var conversations: [Conversation]
  var items: [Item]
  var upTo: Int64
}

struct MirrorForum: Decodable, Sendable {
  struct Room: Decodable, Sendable {
    var roomId: Int
    var parentPostId: Int?
    var title: String?
    var pinned: Bool?
    var createdAt: String
  }

  struct Post: Decodable, Sendable {
    var id: Int
    var roomId: Int
    var author: String
    var botId: String?
    var name: String
    var text: String
    /// A visual reply the bot published in the room with `render_html`.
    var visualReply: VisualReply?
    var createdAt: Double
  }

  /// What a bot did in its seat for a room: a tool call or its thinking.
  struct SeatItem: Decodable, Sendable {
    var botId: String
    var name: String
    var item: MirrorBot.Item
  }

  /// One model turn of a bot's seat.
  struct SeatUsage: Decodable, Sendable {
    var botId: String
    var key: String
    var roomId: Int
    var createdAt: Double
    var usage: MirrorBot.Item.Usage
  }

  var rooms: [Room]
  var posts: [Post]
  var seatItems: [SeatItem]?
  var seatUsage: [SeatUsage]?
  /// Each bot's seat entries through this one are covered.
  var seats: [String: Int64]?
  var upTo: Int64
}

/// This machine's stint as the bots' host, in `D/bots-runtime/tenure`: part
/// of the session ids it saves their chats under. It is new each time the
/// bots come here, so a machine they come back to never meets the sessions it
/// deleted when they left (a deletion is final).
final class BotsTenure: Sendable {
  let file: URL
  private let cached = Mutex<String?>(nil)

  init(file: URL) { self.file = file }

  /// The current stint, begun now if there is none.
  var current: String {
    cached.withLock { value in
      if let value { return value }
      let stored = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
      let id = stored.flatMap { $0.isEmpty ? nil : $0 } ?? String(UUID().uuidString.lowercased().prefix(8))
      if stored != id {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? id.write(to: file, atomically: true, encoding: .utf8)
      }
      value = id
      return id
    }
  }

  /// The bots left (or never came): the next stint is a new one.
  func end() {
    cached.withLock { value in
      value = nil
      try? FileManager.default.removeItem(at: file)
    }
  }
}

/// The contract's mapping of a push to the library's sessions and items.
/// `host` is the session prefix: the host and its stint.
enum BotsMirrorMapping {
  static func botSession(host: String, botID: String, conversationID: Int) -> String {
    "bot:\(host):\(botID):\(conversationID)"
  }

  static func forumSession(host: String, roomID: Int) -> String {
    "forum:\(host):\(roomID)"
  }

  static func bot(_ push: MirrorBot, host: String) -> BotMirror {
    let bot = push.bot
    let chats = push.conversations.map { conversation in
      let thread = conversation.kind == "thread"
      return BotMirror.Chat(
        sessionID: botSession(host: host, botID: bot.id, conversationID: conversation.conversationId), botID: bot.id,
        conversationID: conversation.conversationId, kind: thread ? .thread : .main,
        parentConversationID: conversation.parentConversationId,
        title: thread ? (conversation.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled thread") : bot.name,
        pinned: conversation.pinned ?? false, createdAt: date(conversation.createdAt))
    }
    let items = push.items.map { item in
      let session = botSession(host: host, botID: bot.id, conversationID: item.conversationId)
      return BotMirror.Item(id: "\(session):\(item.key)", sessionID: session, content: content(item),
                            author: item.from.map { ItemAuthor(botID: nil, name: $0.name, sessionID: $0.sessionId) },
                            createdAt: Date(timeIntervalSince1970: item.createdAt / 1000))
    }
    let usage = push.items.compactMap { item in
      item.usage.map {
        record(bot: bot.id, key: item.key, botSession(host: host, botID: bot.id, conversationID: item.conversationId),
               item.createdAt, $0)
      }
    }
    return BotMirror(
      bot: BotMirror.Bot(id: bot.id, name: bot.name, isAdmin: bot.kind == "admin", manager: bot.manager,
                         managerID: bot.managerId, orchestrator: bot.orchestrator, trashed: bot.deleted,
                         createdAt: date(bot.createdAt)),
      chats: chats, items: items, usage: usage, checkpoint: "bot:" + bot.id, upTo: push.upTo)
  }

  /// One model turn's usage. Keyed by the bot and its entry, not the host:
  /// after a transfer the new host pushes the same turns again and
  /// records none twice.
  private static func record(bot: String, key: String, _ session: String, _ createdAt: Double,
                             _ usage: MirrorBot.Item.Usage) -> BotMirror.UsageRecord {
    BotMirror.UsageRecord(id: "bot:\(bot):\(key):usage", sessionID: session,
                          createdAt: Date(timeIntervalSince1970: createdAt / 1000),
                          usage: BotMirror.Usage(model: usage.model, input: usage.input, output: usage.output,
                                                 cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite, cost: usage.cost))
  }

  /// The rooms, their posts, and what bots did in their seats for them, in
  /// time order (a post before seat work of the same moment), each bot's
  /// work under its name.
  static func forum(_ push: MirrorForum, host: String) -> BotMirror {
    let main = push.rooms.first { $0.parentPostId == nil }?.roomId
    let chats = push.rooms.map { room in
      let session = forumSession(host: host, roomID: room.roomId)
      guard let parentPost = room.parentPostId else {
        return BotMirror.Chat(sessionID: session, botID: nil, conversationID: room.roomId, kind: .forum,
                              parentConversationID: nil, title: "Forum", pinned: room.pinned ?? false,
                              createdAt: date(room.createdAt))
      }
      let title = room.title.flatMap { $0.isEmpty ? nil : $0 }
        ?? push.posts.first { $0.id == parentPost }.flatMap { Library.threadTitle(fromPost: $0.visualReply?.title ?? $0.text) }
      return BotMirror.Chat(sessionID: session, botID: nil, conversationID: room.roomId, kind: .forumThread,
                            parentConversationID: main, title: title, parentPostID: parentPost,
                            pinned: room.pinned ?? false, createdAt: date(room.createdAt))
    }
    let posts = push.posts.map { post in
      let session = forumSession(host: host, roomID: post.roomId)
      // A bot speaks as itself.
      let bot = post.author == "bot"
      return BotMirror.Item(
        id: "\(session):\(post.id)", sessionID: session,
        content: post.visualReply.map(ItemContent.visualReply)
          ?? (bot ? .assistantMessage(text: post.text) : .userMessage(text: post.text)),
        author: bot ? ItemAuthor(botID: post.botId, name: post.name) : nil,
        createdAt: Date(timeIntervalSince1970: post.createdAt / 1000))
    }
    let work = (push.seatItems ?? []).map { seat in
      let session = forumSession(host: host, roomID: seat.item.conversationId)
      return BotMirror.Item(id: "\(session):\(seat.botId).\(seat.item.key)", sessionID: session, content: content(seat.item),
                            author: ItemAuthor(botID: seat.botId, name: seat.name),
                            createdAt: Date(timeIntervalSince1970: seat.item.createdAt / 1000))
    }
    let items = (posts.map { ($0, 0) } + work.map { ($0, 1) })
      .enumerated().sorted { ($0.element.0.createdAt, $0.element.1, $0.offset) < ($1.element.0.createdAt, $1.element.1, $1.offset) }
      .map(\.element.0)
    let usage = (push.seatUsage ?? []).map {
      record(bot: $0.botId, key: $0.key, forumSession(host: host, roomID: $0.roomId), $0.createdAt, $0.usage)
    }
    return BotMirror(bot: nil, chats: chats, items: items, usage: usage, checkpoint: "forum", upTo: push.upTo,
                     checkpoints: Dictionary(uniqueKeysWithValues: (push.seats ?? [:]).map { ("seat:" + $0.key, $0.value) }))
  }

  private static func content(_ item: MirrorBot.Item) -> ItemContent {
    if item.kind == "visualReply", let reply = item.visualReply { return .visualReply(reply) }
    switch item.kind {
    case "user": return .userMessage(text: item.text ?? "")
    case "assistant": return .assistantMessage(text: item.text ?? "")
    // Saved as sessions save the model's reasoning, and calls capped as theirs are.
    case "thinking":
      return .toolCall(ToolCall(name: "thinking", input: "", output: item.text ?? "", title: "Thinking", kind: .thinking))
    case "tool":
      let tool = item.tool ?? MirrorBot.Item.Tool(name: "tool", input: "", output: nil, failed: false)
      return .toolCall(ToolOutput.capped(VisualReplies.withoutVisualReply(ToolCall(
        name: tool.name, input: tool.input, output: tool.output, failed: tool.failed,
        kind: tool.name.lowercased() == "bash" ? .execute : OpenCodeProjection.kind(tool.name)))))
    case "stopped": return .notice(Notice(kind: .interrupted, text: "Stopped."))
    default: return .notice(Notice(kind: .failure, text: item.text ?? "Something went wrong."))
    }
  }

  private static func date(_ text: String) -> Date {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) ?? Date()
  }
}
