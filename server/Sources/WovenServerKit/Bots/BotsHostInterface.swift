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
  /// The Woven MCP, once the server has made it.
  let tools = ToolsLink()

  /// The home machine: this one.
  private var home: String { library.machineID }
  /// What the chats' session ids start with: this machine and its stint as the home.
  private var sessions: String { home + ":" + tenure.current }

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
                      "instructions": .string(WovenInstructions.text)])
    case "tools.call":
      guard let botID = params["botId"]?.string, let name = params["name"]?.string else {
        throw RuntimeError.failed("tools.call needs a botId and a name.")
      }
      guard await toolsAllowed(botID), let tools = tools.current else {
        return try JSONValue(encoding: ToolResult.error("Woven tools are turned off for this bot in Settings."))
      }
      // `forum`: the bot is answering in the Forum, not in one of its own chats.
      let caller = ToolCaller(machineID: home, botID: botID, inForum: params["forum"]?.bool == true ? true : nil)
      return try JSONValue(encoding: await tools.call(name, arguments: params["arguments"] ?? .object([:]), caller: caller))
    case "mirror.checkpoints":
      var bots: [String: JSONValue] = [:]
      var forum: Int64 = 0
      for (key, entry) in try await library.botCheckpoints() {
        if key == "forum" { forum = entry } else if key.hasPrefix("bot:") { bots[String(key.dropFirst(4))] = .integer(entry) }
      }
      return .object(["bots": .object(bots), "forum": .integer(forum)])
    case "mirror.bot":
      try await library.saveBotMirror(BotsMirrorMapping.bot(try params.decode(MirrorBot.self), home: sessions))
      return .object([:])
    case "mirror.forum":
      try await library.saveBotMirror(BotsMirrorMapping.forum(try params.decode(MirrorForum.self), home: sessions))
      return .object([:])
    case "mirror.purge":
      guard let botID = params["botId"]?.string else { throw RuntimeError.failed("mirror.purge needs a botId.") }
      try await library.purgeBot(botID)
      return .object([:])
    default:
      throw RuntimeError.failed("Woven Matter does not offer \(method).")
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
    /// A page the bot published with `render_html`.
    var page: HTMLPage?
    var usage: Usage?
  }

  /// The usage of turns in the bot's Forum seats, which are not mirrored.
  struct ForumUsage: Decodable, Sendable {
    var key: String
    var roomId: Int
    var createdAt: Double
    var usage: Item.Usage
  }

  var bot: Bot
  var conversations: [Conversation]
  var items: [Item]
  var forumUsage: [ForumUsage]?
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
    var createdAt: Double
  }

  var rooms: [Room]
  var posts: [Post]
  var upTo: Int64
}

/// This machine's stint as the bots' home, in `D/bots-runtime/tenure`: part
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
/// `home` is the session prefix: the home machine and its stint.
enum BotsMirrorMapping {
  static func botSession(home: String, botID: String, conversationID: Int) -> String {
    "bot:\(home):\(botID):\(conversationID)"
  }

  static func forumSession(home: String, roomID: Int) -> String {
    "forum:\(home):\(roomID)"
  }

  static func bot(_ push: MirrorBot, home: String) -> BotMirror {
    let bot = push.bot
    let chats = push.conversations.map { conversation in
      let thread = conversation.kind == "thread"
      return BotMirror.Chat(
        sessionID: botSession(home: home, botID: bot.id, conversationID: conversation.conversationId), botID: bot.id,
        conversationID: conversation.conversationId, kind: thread ? .thread : .main,
        parentConversationID: conversation.parentConversationId,
        title: thread ? (conversation.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled thread") : bot.name,
        pinned: conversation.pinned ?? false, createdAt: date(conversation.createdAt))
    }
    let items = push.items.map { item in
      let session = botSession(home: home, botID: bot.id, conversationID: item.conversationId)
      return BotMirror.Item(id: "\(session):\(item.key)", sessionID: session, content: content(item),
                            createdAt: Date(timeIntervalSince1970: item.createdAt / 1000))
    }
    // Keyed by the bot and its entry, not the home machine: after a transfer
    // the new home pushes the same turns again and records none twice.
    func record(_ key: String, _ session: String, _ createdAt: Double, _ usage: MirrorBot.Item.Usage) -> BotMirror.UsageRecord {
      BotMirror.UsageRecord(id: "bot:\(bot.id):\(key):usage", sessionID: session,
                            createdAt: Date(timeIntervalSince1970: createdAt / 1000),
                            usage: BotMirror.Usage(model: usage.model, input: usage.input, output: usage.output,
                                                   cacheRead: usage.cacheRead, cacheWrite: usage.cacheWrite, cost: usage.cost))
    }
    let usage = push.items.compactMap { item in
      item.usage.map { record(item.key, botSession(home: home, botID: bot.id, conversationID: item.conversationId), item.createdAt, $0) }
    } + (push.forumUsage ?? []).map { record($0.key, forumSession(home: home, roomID: $0.roomId), $0.createdAt, $0.usage) }
    return BotMirror(
      bot: BotMirror.Bot(id: bot.id, name: bot.name, isAdmin: bot.kind == "admin", manager: bot.manager,
                         managerID: bot.managerId, orchestrator: bot.orchestrator, trashed: bot.deleted,
                         createdAt: date(bot.createdAt)),
      chats: chats, items: items, usage: usage, checkpoint: "bot:" + bot.id, upTo: push.upTo)
  }

  static func forum(_ push: MirrorForum, home: String) -> BotMirror {
    let main = push.rooms.first { $0.parentPostId == nil }?.roomId
    let chats = push.rooms.map { room in
      let session = forumSession(home: home, roomID: room.roomId)
      guard let parentPost = room.parentPostId else {
        return BotMirror.Chat(sessionID: session, botID: nil, conversationID: room.roomId, kind: .forum,
                              parentConversationID: nil, title: "Forum", pinned: room.pinned ?? false,
                              createdAt: date(room.createdAt))
      }
      let title = room.title.flatMap { $0.isEmpty ? nil : $0 }
        ?? push.posts.first { $0.id == parentPost }.flatMap { Library.threadTitle(fromPost: $0.text) }
      return BotMirror.Chat(sessionID: session, botID: nil, conversationID: room.roomId, kind: .forumThread,
                            parentConversationID: main, title: title, parentPostID: parentPost,
                            pinned: room.pinned ?? false, createdAt: date(room.createdAt))
    }
    let items = push.posts.map { post in
      let session = forumSession(home: home, roomID: post.roomId)
      // A bot speaks as itself; an agent session posts for the person, under its own name.
      let author: ItemAuthor? = switch post.author {
      case "bot": ItemAuthor(botID: post.botId, name: post.name)
      case "agent": ItemAuthor(botID: nil, name: post.name)
      default: nil
      }
      return BotMirror.Item(
        id: "\(session):\(post.id)", sessionID: session,
        content: post.author == "bot" ? .assistantMessage(text: post.text) : .userMessage(text: post.text),
        author: author, createdAt: Date(timeIntervalSince1970: post.createdAt / 1000))
    }
    return BotMirror(bot: nil, chats: chats, items: items, checkpoint: "forum", upTo: push.upTo)
  }

  private static func content(_ item: MirrorBot.Item) -> ItemContent {
    if item.kind == "page", let page = item.page { return .htmlPage(page) }
    switch item.kind {
    case "user": return .userMessage(text: item.text ?? "")
    case "assistant": return .assistantMessage(text: item.text ?? "")
    case "tool":
      let tool = item.tool ?? MirrorBot.Item.Tool(name: "tool", input: "", output: nil, failed: false)
      return .toolCall(HTMLPages.withoutPage(ToolCall(
        name: tool.name, input: tool.input, output: tool.output, failed: tool.failed,
        kind: tool.name.lowercased() == "bash" ? .execute : OpenCodeProjection.kind(tool.name))))
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
