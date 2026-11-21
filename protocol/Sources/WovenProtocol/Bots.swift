import Foundation

// The bots and the Forum. There is one set of bots, on one host (the
// synced setting `bots.host`, a machine identifier); only that machine's
// server runs the bots runtime. Any server answers these: the host's server
// itself, every other one by asking the host's server.
//
// The runtime's own requests and messages are defined once, in
// `bots/src/protocol.ts`. They pass through `BotsCall` and `SubscribeBots`
// as JSON; `BotsWire.swift` decodes what the UI shows.

/// The setting that names the bots' host.
public let botsHostSetting = "bots.host"
/// The setting that says which bots may use the Woven tools:
/// `{"paused": Bool, "denied": [bot identifier]}`.
public let botsWovenToolsSetting = "bots.wovenTools"

/// What the bots runtime on the host is doing.
public enum BotsState: String, Codable, Sendable, Hashable {
  /// No host is chosen.
  case off
  case starting
  case ready
  /// The host's server cannot be reached.
  case unreachable
  /// The runtime or its container engine failed; `message` says why.
  case failed
  /// The bots are stopped here while they move to another machine; `transfer` says how far.
  case transferring
}

/// The host's memory and disk, for Settings > Bots > Resources.
public struct BotsCapacity: Codable, Sendable, Hashable {
  public var memoryBytes: Int64
  public var diskTotalBytes: Int64
  public var diskFreeBytes: Int64
  /// What the bots already store.
  public var diskUsedByBotsBytes: Int64?

  public init(memoryBytes: Int64, diskTotalBytes: Int64, diskFreeBytes: Int64, diskUsedByBotsBytes: Int64? = nil) {
    self.memoryBytes = memoryBytes
    self.diskTotalBytes = diskTotalBytes
    self.diskFreeBytes = diskFreeBytes
    self.diskUsedByBotsBytes = diskUsedByBotsBytes
  }
}

/// The bots' host and the state of its runtime.
public struct BotsStatus: Codable, Sendable, Hashable {
  public var hostMachineID: String?
  public var state: BotsState
  public var message: String?
  /// The container engine: "mac-vm" or "linux-dockerd".
  public var engine: String?
  public var capacity: BotsCapacity?
  /// A transfer to another machine, while one runs.
  public var transfer: BotsTransferProgress?

  public init(hostMachineID: String?, state: BotsState, message: String? = nil, engine: String? = nil,
              capacity: BotsCapacity? = nil, transfer: BotsTransferProgress? = nil) {
    self.hostMachineID = hostMachineID
    self.state = state
    self.message = message
    self.engine = engine
    self.capacity = capacity
    self.transfer = transfer
  }
}

/// Passes one request through to the bots runtime: `request` is a request of
/// `bots/src/protocol.ts` without its `id`. Replies with the runtime's result.
/// `conversation.open` and `forum.open` go through `SubscribeBots` instead.
public struct BotsCall: Request {
  public static let method = "bots.call"
  public typealias Reply = JSONValue
  public var request: JSONValue
  public init(request: JSONValue) { self.request = request }
}

/// The bots runtime's messages. Without `open`, the messages for everyone
/// (`bots.changed`, `forum.changed`, `runtime.update`…). With `open` (a
/// `conversation.open` or `forum.open` request), that conversation or room:
/// the reply carries its snapshot and the events are its `event`,
/// `forum.post` and `forum.thinking` messages; ending the subscription closes
/// it in the runtime. Every subscription also hears status changes.
public struct SubscribeBots: Subscription {
  public static let method = "bots.subscribe"
  public typealias Reply = BotsOpened
  public typealias Event = BotsEvent
  public var open: JSONValue?
  public init(open: JSONValue? = nil) { self.open = open }
}

public struct BotsOpened: Codable, Sendable, Hashable {
  public var status: BotsStatus
  /// The runtime's reply to `open`, when the runtime is ready.
  public var opened: JSONValue?

  public init(status: BotsStatus, opened: JSONValue? = nil) {
    self.status = status
    self.opened = opened
  }
}

/// An event of `SubscribeBots`. Encoded with a `type` field.
public enum BotsEvent: Codable, Sendable, Hashable {
  case status(BotsStatus)
  /// One message of the runtime, as `bots/src/protocol.ts` defines it.
  case message(JSONValue)

  private enum Key: String, CodingKey { case type, status, message }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    switch try container.decode(String.self, forKey: .type) {
    case "status": self = .status(try container.decode(BotsStatus.self, forKey: .status))
    case "message": self = .message(try container.decode(JSONValue.self, forKey: .message))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown bots event \(other)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    switch self {
    case .status(let status):
      try container.encode("status", forKey: .type)
      try container.encode(status, forKey: .status)
    case .message(let message):
      try container.encode("message", forKey: .type)
      try container.encode(message, forKey: .message)
    }
  }
}

/// A bot as the library holds it.
public struct SavedBot: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var hostMachineID: String
  public var name: String
  public var isAdmin: Bool
  public var manager: Bool
  public var managerID: String?
  public var orchestrator: Bool
  public var trashed: Bool
  public var createdAt: Date

  public init(id: String, hostMachineID: String, name: String, isAdmin: Bool, manager: Bool, managerID: String?,
              orchestrator: Bool, trashed: Bool, createdAt: Date) {
    self.id = id
    self.hostMachineID = hostMachineID
    self.name = name
    self.isAdmin = isAdmin
    self.manager = manager
    self.managerID = managerID
    self.orchestrator = orchestrator
    self.trashed = trashed
    self.createdAt = createdAt
  }
}

/// A session that holds a bot conversation or a Forum room.
public struct SavedBotChat: Codable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable, Hashable {
    case main
    case thread
    /// The Forum itself.
    case forum
    case forumThread
  }

  public var session: Session
  /// Nil for a Forum room.
  public var botID: String?
  /// The runtime's conversation, or the Forum room.
  public var conversationID: Int
  public var kind: Kind
  public var parentConversationID: Int?

  public init(session: Session, botID: String?, conversationID: Int, kind: Kind, parentConversationID: Int?) {
    self.session = session
    self.botID = botID
    self.conversationID = conversationID
    self.kind = kind
    self.parentConversationID = parentConversationID
  }
}

/// The bots and their chats as the library holds them, for reading while
/// the host is away. Their items come from `SessionItems`.
public struct ListSavedBots: Request {
  public static let method = "bots.saved"
  public typealias Reply = SavedBots
  public init() {}
}

public struct SavedBots: Codable, Sendable, Hashable {
  public var bots: [SavedBot]
  public var chats: [SavedBotChat]

  public init(bots: [SavedBot], chats: [SavedBotChat]) {
    self.bots = bots
    self.chats = chats
  }
}

/// Makes `machineID` the bots' first host. `bots.host` is never written as an
/// ordinary setting: a server accepts this only while its library names no
/// host and holds no bots, and once every machine it reaches has answered
/// that it knows none either. Moving the bots later is a transfer.
public struct ChooseBotsHost: Request {
  public static let method = "bots.chooseHost"
  public typealias Reply = Done
  public var machineID: String
  public init(machineID: String) { self.machineID = machineID }
}

/// Between servers, before a first host is chosen: what this machine knows of the bots.
public struct BotsPresence: Request {
  public static let method = "bots.presence"
  public typealias Reply = BotsPresenceReply
  public init() {}
}

public struct BotsPresenceReply: Codable, Sendable, Hashable {
  /// The host this machine's library names.
  public var hostMachineID: String?
  /// This machine's library holds bots, or a transfer is under way here.
  public var hasBots: Bool
  public init(hostMachineID: String?, hasBots: Bool) {
    self.hostMachineID = hostMachineID
    self.hasBots = hasBots
  }
}
