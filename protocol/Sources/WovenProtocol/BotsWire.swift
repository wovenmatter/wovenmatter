import Foundation

// Swift copies of the `bots/src/protocol.ts` shapes the UI decodes. That file
// is the one definition; these follow it field for field, with its names.
// `bots/test/fixtures/wire.json` holds one example of each, and
// `BotsWireTests` decodes every one of them with these types.

public enum BotsWire {
  // MARK: Bots

  public struct ModelLimitSummary: Codable, Sendable, Hashable {
    public var model: String
    public var account: String
    /// "five_hour", "weekly", "usage" or "credits".
    public var kind: String
    /// Epoch ms, only when the provider returned it.
    public var resetsAt: Double?
    /// Epoch ms: when it is tried again.
    public var retryAt: Double
  }

  public struct ModelStatusSummary: Codable, Sendable, Hashable {
    /// "fallback", "paused" or "returned".
    public var kind: String
    /// Epoch ms of the change.
    public var at: Double
    public var primary: String
    public var active: String
    public var limits: [ModelLimitSummary]
  }

  public struct BotSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: String
    /// "admin" or "bot".
    public var kind: String
    public var manager: Bool
    public var managerId: String?
    public var groupId: String?
    public var orchestrator: Bool
    public var profileId: String
    public var profileName: String
    public var defaultProfile: Bool
    public var modelStatus: ModelStatusSummary?
  }

  public struct DeletedBotSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var createdAt: String
    public var kind: String
    public var manager: Bool
    public var managerId: String?
    public var groupId: String?
    public var orchestrator: Bool
    public var profileId: String
    public var profileName: String
    public var defaultProfile: Bool
    public var modelStatus: ModelStatusSummary?
    public var deletedAt: String
  }

  public struct ThreadSummary: Codable, Sendable, Hashable {
    public var pinned: Bool?
    public var conversationId: Int
    public var parentConversationId: Int
    public var forkedAt: Int
    public var title: String?
    public var createdAt: String
  }

  public struct Group: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var position: Int
  }

  /// `groups.create`.
  public struct GroupResult: Codable, Sendable, Hashable {
    public var group: Group
  }

  /// `groups.list`.
  public struct GroupsList: Codable, Sendable, Hashable {
    public var groups: [Group]
  }

  /// `bots.list`.
  public struct BotsList: Codable, Sendable, Hashable {
    public var bots: [BotSummary]
  }

  /// `bots.listDeleted`.
  public struct DeletedBotsList: Codable, Sendable, Hashable {
    public var bots: [DeletedBotSummary]
  }

  /// `bots.create`, `bots.rename` and the other changes of one bot.
  public struct BotResult: Codable, Sendable, Hashable {
    public var bot: BotSummary
  }

  /// `threads.list`.
  public struct ThreadsList: Codable, Sendable, Hashable {
    public var threads: [ThreadSummary]
  }

  /// `thread.fork`, `thread.setPinned`.
  public struct ThreadResult: Codable, Sendable, Hashable {
    public var thread: ThreadSummary
  }

  /// `bots.purge`.
  public struct PurgeResult: Codable, Sendable, Hashable {
    public struct Environment: Codable, Sendable, Hashable {
      public var removed: Bool
      public var error: String?
    }
    public var purged: Bool
    public var tables: Int
    public var environment: Environment?
  }

  /// `user.get`, `user.setName`.
  public struct UserName: Codable, Sendable, Hashable {
    public var name: String
  }

  /// `memory.list` and each memory change: the bot's facts after it.
  public struct MemoryList: Codable, Sendable, Hashable {
    public var facts: [String]
  }

  // MARK: Profiles and models

  public struct PoolModelSummary: Codable, Sendable, Hashable {
    public var model: String
    public var useFor: String
  }

  public struct ProfileSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var main: String
    public var fallbacks: [String]?
    public var memoryModel: String?
    public var guidance: String?
    public var pool: [PoolModelSummary]
    public var `default`: Bool?
  }

  public struct ProfilesList: Codable, Sendable, Hashable {
    public var defaultId: String
    public var profiles: [ProfileSummary]
  }

  public struct OnboardingStatus: Codable, Sendable, Hashable {
    public var adminId: String
    public var profileId: String
    public var mainModel: String
    public var mainModelAvailable: Bool
    public var signedIn: Bool
    public var needed: Bool
  }

  /// USD per million tokens.
  public struct PriceRates: Codable, Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
  }

  public struct PriceTier: Codable, Sendable, Hashable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double
    public var cacheWrite: Double
    public var inputTokensAbove: Double
  }

  public struct ModelPricing: Codable, Sendable, Hashable {
    /// "listed", "zero" or "unknown".
    public var status: String
    public var rates: PriceRates?
    public var tiers: [PriceTier]?
    public var source: String?
  }

  public struct ModelAccess: Codable, Sendable, Hashable {
    /// "subscription", "api_key" or "unknown".
    public var kind: String
    public var label: String
  }

  public struct ModelOption: Codable, Sendable, Hashable, Identifiable {
    public struct Limit: Codable, Sendable, Hashable {
      public var kind: String
      public var label: String
      public var account: String
      public var resetsAt: Double?
    }
    public var id: String
    public var name: String
    public var reasoning: Bool
    public var contextWindow: Double
    public var maxTokens: Double?
    public var input: [String]?
    public var unsupportedReasoning: [String]?
    public var pricing: ModelPricing
    public var limit: Limit?
  }

  public struct ProviderModels: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var access: ModelAccess
    public var models: [ModelOption]
  }

  public struct Roles: Codable, Sendable, Hashable {
    public var titles: String
    public var titlesReasoning: String
  }

  /// `models.catalog`.
  public struct ModelCatalog: Codable, Sendable, Hashable {
    public var providers: [ProviderModels]
    public var roles: Roles
    public var reasoningLevels: [String]
  }

  /// `models.setRoles`.
  public struct RolesResult: Codable, Sendable, Hashable {
    public var roles: Roles
    public var restartRequired: Bool
  }

  /// `runtime.status`, only what the UI reads: its `image` also carries a key per tool in the
  /// bots' image, so it has no fixed shape to copy.
  public struct RuntimeStatus: Decodable, Sendable, Hashable {
    public struct Image: Decodable, Sendable, Hashable {
      /// Bots an update moves to a new base image.
      public var staleBots: Int
    }
    public var image: Image?
  }

  // MARK: Containers

  public struct EnvironmentSummary: Codable, Sendable, Hashable {
    public var botId: String
    /// "missing", "running", "stopped" or "unavailable".
    public var state: String
    public var busy: String?
    public var lastActivity: Double?
    /// The bot's restart list; the UI does not show it.
    public var services: [JSONValue]?
  }

  /// `bots.environment`.
  public struct EnvironmentResult: Codable, Sendable, Hashable {
    public var environment: EnvironmentSummary
  }

  // MARK: Conversations

  public struct DisplayEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: Int
    /// The conversation that owns the entry; differs from the viewed one for inherited entries.
    public var conversationId: Int
    /// "user" or "assistant".
    public var role: String
    public var text: String
    public var error: String?
    /// "signIn" or "limit".
    public var issue: String?
    public var stopped: Bool?
  }

  public struct ConversationSnapshot: Codable, Sendable, Hashable {
    public var subscriptionId: JSONValue?
    public var botId: String
    public var conversationId: Int
    public var mainConversationId: Int
    public var threadOrigin: DisplayEntry?
    public var entries: [DisplayEntry]
    public var running: Bool
    public var streaming: String?
  }

  public enum StreamEvent: Codable, Sendable, Hashable {
    case run(started: Bool)
    case assistantStart(text: String)
    case delta(text: String)
    case entry(DisplayEntry)
    case error(message: String)

    private enum Key: String, CodingKey { case kind, state, text, entry, message }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: Key.self)
      switch try container.decode(String.self, forKey: .kind) {
      case "run":
        let state = try container.decode(String.self, forKey: .state)
        guard state == "start" || state == "end" else {
          throw DecodingError.dataCorruptedError(forKey: .state, in: container, debugDescription: "Unknown run state \(state)")
        }
        self = .run(started: state == "start")
      case "assistant_start": self = .assistantStart(text: try container.decode(String.self, forKey: .text))
      case "delta": self = .delta(text: try container.decode(String.self, forKey: .text))
      case "entry": self = .entry(try container.decode(DisplayEntry.self, forKey: .entry))
      case "error": self = .error(message: try container.decode(String.self, forKey: .message))
      case let other:
        throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown stream event \(other)")
      }
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: Key.self)
      switch self {
      case .run(let started):
        try container.encode("run", forKey: .kind)
        try container.encode(started ? "start" : "end", forKey: .state)
      case .assistantStart(let text):
        try container.encode("assistant_start", forKey: .kind)
        try container.encode(text, forKey: .text)
      case .delta(let text):
        try container.encode("delta", forKey: .kind)
        try container.encode(text, forKey: .text)
      case .entry(let entry):
        try container.encode("entry", forKey: .kind)
        try container.encode(entry, forKey: .entry)
      case .error(let message):
        try container.encode("error", forKey: .kind)
        try container.encode(message, forKey: .message)
      }
    }
  }

  // MARK: The Forum

  public struct ForumPost: Codable, Sendable, Hashable, Identifiable {
    public struct Thread: Codable, Sendable, Hashable {
      public var roomId: Int
      public var replies: Int
    }
    public struct Unanswered: Codable, Sendable, Hashable {
      public var botId: String
      public var name: String
      public var reason: String
      /// "signIn" or "limit".
      public var issue: String?
    }
    public var id: Int
    public var roomId: Int
    /// "user", "bot", or "agent" (an agent session posted for the person; `name` is its name).
    public var author: String
    public var botId: String?
    public var name: String
    public var text: String
    public var mentions: [String]?
    public var scheduled: Bool?
    public var auto: Bool?
    public var createdAt: String
    public var thread: Thread?
    public var unanswered: [Unanswered]?
  }

  public struct ForumThreadSummary: Codable, Sendable, Hashable {
    public var roomId: Int
    public var parentPostId: Int
    public var title: String?
    public var preview: String
    public var createdAt: String
    public var pinned: Bool?
    public var replies: Int
    public var botIds: [String]
  }

  public struct ForumState: Codable, Sendable, Hashable {
    public struct Member: Codable, Sendable, Hashable {
      public var botId: String
      public var active: Bool
    }
    public var mainRoomId: Int
    public var paused: Bool
    public var latestPostId: Int
    public var bots: [Member]
    public var threads: [ForumThreadSummary]
  }

  public struct ForumRoomSnapshot: Codable, Sendable, Hashable {
    public var subscriptionId: JSONValue?
    public var roomId: Int
    public var mainRoomId: Int
    public var parent: ForumPost?
    public var posts: [ForumPost]
    public var hasEarlier: Bool
    public var thinking: [String]
  }

  /// `forum.posts`.
  public struct ForumPostsPage: Codable, Sendable, Hashable {
    public var posts: [ForumPost]
    public var hasEarlier: Bool
  }

  /// `forum.post`.
  public struct ForumPostResult: Codable, Sendable, Hashable {
    public var post: ForumPost
  }

  /// `forum.thread.create`, `forum.thread.setPinned`.
  public struct ForumThreadResult: Codable, Sendable, Hashable {
    public var thread: ForumThreadSummary
  }

  public struct ForumScheduleSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var text: String
    public var mentions: [String]?
    public var everyone: Bool?
    /// "once", "daily", "weekdays" or "weekly".
    public var `repeat`: String
    public var time: String?
    public var weekday: Int?
    public var at: Double?
    public var timeZone: String
    public var nextAt: Double?
  }

  /// `forum.schedules.list`, `.save` and `.delete`.
  public struct ForumSchedulesList: Codable, Sendable, Hashable {
    public var schedules: [ForumScheduleSummary]
  }

  // MARK: Pushes

  /// A message the runtime pushes, as `SubscribeBots` delivers it.
  public enum Message: Codable, Sendable, Hashable {
    case event(botId: String, conversationId: Int, event: StreamEvent)
    case botsChanged
    case groupsChanged
    case threadsChanged(botId: String)
    case memoryChanged(botId: String)
    case forumPost(ForumPost)
    case forumThinking(roomId: Int, botIds: [String])
    case forumChanged
    case userChanged
    /// `state`: "missing", "running", "stopped" or "unavailable".
    case environmentChanged(botId: String, state: String)
    /// `phase`: "stopping", "updating", "updated", "rolledBack", "skipped" or "done".
    case runtimeUpdate(botId: String?, phase: String, error: String?)

    private enum Key: String, CodingKey { case type, botId, conversationId, event, post, roomId, botIds, state, phase, error }

    public init(from decoder: any Decoder) throws {
      let container = try decoder.container(keyedBy: Key.self)
      switch try container.decode(String.self, forKey: .type) {
      case "event":
        self = .event(botId: try container.decode(String.self, forKey: .botId),
                      conversationId: try container.decode(Int.self, forKey: .conversationId),
                      event: try container.decode(StreamEvent.self, forKey: .event))
      case "bots.changed": self = .botsChanged
      case "groups.changed": self = .groupsChanged
      case "threads.changed": self = .threadsChanged(botId: try container.decode(String.self, forKey: .botId))
      case "memory.changed": self = .memoryChanged(botId: try container.decode(String.self, forKey: .botId))
      case "forum.post": self = .forumPost(try container.decode(ForumPost.self, forKey: .post))
      case "forum.thinking":
        self = .forumThinking(roomId: try container.decode(Int.self, forKey: .roomId),
                              botIds: try container.decode([String].self, forKey: .botIds))
      case "forum.changed": self = .forumChanged
      case "user.changed": self = .userChanged
      case "bots.environment.changed":
        self = .environmentChanged(botId: try container.decode(String.self, forKey: .botId),
                                   state: try container.decode(String.self, forKey: .state))
      case "runtime.update":
        self = .runtimeUpdate(botId: try container.decodeIfPresent(String.self, forKey: .botId),
                              phase: try container.decode(String.self, forKey: .phase),
                              error: try container.decodeIfPresent(String.self, forKey: .error))
      case let other:
        throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown bots message \(other)")
      }
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.container(keyedBy: Key.self)
      switch self {
      case .event(let botId, let conversationId, let event):
        try container.encode("event", forKey: .type)
        try container.encode(botId, forKey: .botId)
        try container.encode(conversationId, forKey: .conversationId)
        try container.encode(event, forKey: .event)
      case .botsChanged: try container.encode("bots.changed", forKey: .type)
      case .groupsChanged: try container.encode("groups.changed", forKey: .type)
      case .threadsChanged(let botId):
        try container.encode("threads.changed", forKey: .type)
        try container.encode(botId, forKey: .botId)
      case .memoryChanged(let botId):
        try container.encode("memory.changed", forKey: .type)
        try container.encode(botId, forKey: .botId)
      case .forumPost(let post):
        try container.encode("forum.post", forKey: .type)
        try container.encode(post, forKey: .post)
      case .forumThinking(let roomId, let botIds):
        try container.encode("forum.thinking", forKey: .type)
        try container.encode(roomId, forKey: .roomId)
        try container.encode(botIds, forKey: .botIds)
      case .forumChanged: try container.encode("forum.changed", forKey: .type)
      case .userChanged: try container.encode("user.changed", forKey: .type)
      case .environmentChanged(let botId, let state):
        try container.encode("bots.environment.changed", forKey: .type)
        try container.encode(botId, forKey: .botId)
        try container.encode(state, forKey: .state)
      case .runtimeUpdate(let botId, let phase, let error):
        try container.encode("runtime.update", forKey: .type)
        try container.encodeIfPresent(botId, forKey: .botId)
        try container.encode(phase, forKey: .phase)
        try container.encodeIfPresent(error, forKey: .error)
      }
    }
  }
}
