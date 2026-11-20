import Foundation

/// Which kind of computer a machine is.
public enum MachinePlatform: String, Codable, Sendable, Hashable {
  case mac
  case linux

  /// The platform this code runs on.
  public static var current: MachinePlatform {
    #if os(Linux)
    .linux
    #else
    .mac
    #endif
  }
}

/// A Mac or Linux computer on the person's tailnet that runs the server.
public struct Machine: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var platform: MachinePlatform

  public init(id: String, name: String, platform: MachinePlatform = .current) {
    self.id = id
    self.name = name
    self.platform = platform
  }
}

/// A machine as one server sees it right now.
public struct MachineStatus: Codable, Sendable, Hashable {
  public var machine: Machine
  /// This is the machine of the server that answered.
  public var isThisMachine: Bool
  public var online: Bool
  /// The app release it last reported, when it has been reached.
  public var appVersion: String?

  public init(machine: Machine, isThisMachine: Bool, online: Bool, appVersion: String?) {
    self.machine = machine
    self.isThisMachine = isThisMachine
    self.online = online
    self.appVersion = appVersion
  }
}

/// Which runtime a session runs on.
public struct RuntimeKind: RawRepresentable, Codable, Sendable, Hashable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let codex = RuntimeKind(rawValue: "codex")
  public static let claudeCode = RuntimeKind(rawValue: "claudeCode")
  public static let grokBuild = RuntimeKind(rawValue: "grokBuild")
  public static let openCode = RuntimeKind(rawValue: "openCode")
  public static let piDurable = RuntimeKind(rawValue: "piDurable")
  public static let bots = RuntimeKind(rawValue: "bots")
}

/// One conversation with one runtime on one machine, which owns it for life.
public struct Session: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var machineID: String
  public var runtime: RuntimeKind
  public var title: String
  public var folderID: String?
  /// Where the runtime works on the owning machine: the folder's directory,
  /// or a scratch directory of the session's own.
  public var directory: String
  /// The model, thinking level and permission mode last chosen, by the
  /// runtime's own identifiers.
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var archived: Bool
  /// The goal the session works against until it is met or cleared.
  public var goal: String?
  public var createdAt: Date

  public init(id: String, machineID: String, runtime: RuntimeKind, title: String, folderID: String?,
              directory: String = "", model: String? = nil, thinking: String? = nil, permission: String? = nil,
              archived: Bool, goal: String?, createdAt: Date) {
    self.id = id
    self.machineID = machineID
    self.runtime = runtime
    self.title = title
    self.folderID = folderID
    self.directory = directory
    self.model = model
    self.thinking = thinking
    self.permission = permission
    self.archived = archived
    self.goal = goal
    self.createdAt = createdAt
  }
}

/// A finished item of a transcript, as stored once in the library.
public struct SessionItem: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var sessionID: String
  /// Position in the session, from 1, without gaps.
  public var sequence: Int
  public var createdAt: Date
  public var content: ItemContent

  public init(id: String, sessionID: String, sequence: Int, createdAt: Date, content: ItemContent) {
    self.id = id
    self.sessionID = sessionID
    self.sequence = sequence
    self.createdAt = createdAt
    self.content = content
  }
}

/// A file attached to a user message, stored in the content store by digest.
public struct Attachment: Codable, Sendable, Hashable {
  public var name: String
  public var mimeType: String
  public var digest: String
  public var size: Int64

  public init(name: String, mimeType: String, digest: String, size: Int64) {
    self.name = name
    self.mimeType = mimeType
    self.digest = digest
    self.size = size
  }
}

/// What sort of activity a tool call is, for showing it.
public struct ToolKind: RawRepresentable, Codable, Sendable, Hashable {
  public var rawValue: String
  public init(rawValue: String) { self.rawValue = rawValue }

  public init(from decoder: any Decoder) throws {
    rawValue = try decoder.singleValueContainer().decode(String.self)
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }

  public static let read = ToolKind(rawValue: "read")
  public static let edit = ToolKind(rawValue: "edit")
  public static let delete = ToolKind(rawValue: "delete")
  public static let move = ToolKind(rawValue: "move")
  public static let search = ToolKind(rawValue: "search")
  public static let execute = ToolKind(rawValue: "execute")
  public static let fetch = ToolKind(rawValue: "fetch")
  /// The runtime's reasoning, shown as activity; `output` is its text.
  public static let thinking = ToolKind(rawValue: "thinking")
  /// A plan or to-do list; `plan` holds its entries.
  public static let plan = ToolKind(rawValue: "plan")
  /// A child task (subagent); `output` is its result.
  public static let task = ToolKind(rawValue: "task")
  public static let other = ToolKind(rawValue: "other")
}

/// One entry of a plan or to-do list.
public struct PlanEntry: Codable, Sendable, Hashable {
  public enum Status: String, Codable, Sendable, Hashable {
    case pending
    case inProgress
    case completed
  }

  public var text: String
  public var status: Status

  public init(text: String, status: Status) {
    self.text = text
    self.status = status
  }
}

/// A tool the runtime called, with its result once there is one.
public struct ToolCall: Codable, Sendable, Hashable {
  public var name: String
  /// The input as the runtime gave it, usually JSON text.
  public var input: String
  public var output: String?
  public var failed: Bool
  /// What the runtime calls this call, for people ("Read main.swift").
  public var title: String?
  public var kind: ToolKind?
  /// The entries, when this is a plan or to-do update.
  public var plan: [PlanEntry]?

  public init(name: String, input: String, output: String? = nil, failed: Bool = false, title: String? = nil,
              kind: ToolKind? = nil, plan: [PlanEntry]? = nil) {
    self.name = name
    self.input = input
    self.output = output
    self.failed = failed
    self.title = title
    self.kind = kind
    self.plan = plan
  }
}

/// Something the server says in a chat rather than the person or the runtime.
public struct Notice: Codable, Sendable, Hashable {
  public struct Kind: RawRepresentable, Codable, Sendable, Hashable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public init(from decoder: any Decoder) throws {
      rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
      var container = encoder.singleValueContainer()
      try container.encode(rawValue)
    }

    /// The runtime no longer has this chat's native session; offer a new session.
    public static let nativeSessionGone = Kind(rawValue: "nativeSessionGone")
    /// A turn failed.
    public static let failure = Kind(rawValue: "failure")
    /// The server stopped while a turn was running; its reply may be cut short.
    public static let interrupted = Kind(rawValue: "interrupted")
  }

  public var kind: Kind
  public var text: String

  public init(kind: Kind, text: String) {
    self.kind = kind
    self.text = text
  }
}

/// What a session item holds. Encoded with a `type` field.
public enum ItemContent: Codable, Sendable, Hashable {
  case userMessage(text: String, attachments: [Attachment] = [])
  case assistantMessage(text: String)
  case toolCall(ToolCall)
  case notice(Notice)

  private enum Key: String, CodingKey { case type, text, attachments, call, notice }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    switch try container.decode(String.self, forKey: .type) {
    case "userMessage":
      self = .userMessage(text: try container.decode(String.self, forKey: .text),
                          attachments: try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? [])
    case "assistantMessage": self = .assistantMessage(text: try container.decode(String.self, forKey: .text))
    case "toolCall": self = .toolCall(try container.decode(ToolCall.self, forKey: .call))
    case "notice": self = .notice(try container.decode(Notice.self, forKey: .notice))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown item type \(other)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    switch self {
    case .userMessage(let text, let attachments):
      try container.encode("userMessage", forKey: .type)
      try container.encode(text, forKey: .text)
      if !attachments.isEmpty { try container.encode(attachments, forKey: .attachments) }
    case .assistantMessage(let text):
      try container.encode("assistantMessage", forKey: .type)
      try container.encode(text, forKey: .text)
    case .toolCall(let call):
      try container.encode("toolCall", forKey: .type)
      try container.encode(call, forKey: .call)
    case .notice(let notice):
      try container.encode("notice", forKey: .type)
      try container.encode(notice, forKey: .notice)
    }
  }
}

/// An item that has started but not finished. It is never stored; when it
/// finishes it becomes the `SessionItem` with the same `id`.
public struct LiveItem: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var content: ItemContent

  public init(id: String, content: ItemContent) {
    self.id = id
    self.content = content
  }
}

/// Whether a turn is running. Live state on the owning server only.
public enum RunState: String, Codable, Sendable, Hashable {
  case idle
  case running
  /// The native session is gone; the chat can only be read.
  case nativeSessionGone
}

/// One answer a prompt offers.
public struct PromptOption: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String

  public init(id: String, name: String) {
    self.id = id
    self.name = name
  }
}

/// A question or an approval the runtime is waiting on.
public struct Prompt: Codable, Sendable, Hashable, Identifiable {
  public enum Kind: String, Codable, Sendable, Hashable {
    case question
    case approval
  }

  public var id: String
  public var kind: Kind
  public var text: String
  /// The answers offered, when the runtime offers a fixed set; the answer is
  /// an option's `id`. With none, the answer is free text.
  public var options: [PromptOption]

  public init(id: String, kind: Kind, text: String, options: [PromptOption] = []) {
    self.id = id
    self.kind = kind
    self.text = text
    self.options = options
  }
}

/// One value a session setting can take, as the runtime reports it.
public struct SessionOption: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var detail: String?

  public init(id: String, name: String, detail: String? = nil) {
    self.id = id
    self.name = name
    self.detail = detail
  }
}

/// A slash command the runtime offers in the composer.
public struct SessionCommand: Codable, Sendable, Hashable {
  public var name: String
  public var detail: String?
  public var hint: String?

  public init(name: String, detail: String? = nil, hint: String? = nil) {
    self.name = name
    self.detail = detail
    self.hint = hint
  }
}

/// A session's model, thinking level and permission mode, what each can be,
/// and its slash commands: one shape for every runtime. The lists are what
/// the runtime reports while its process runs; they are empty otherwise.
public struct SessionConfiguration: Codable, Sendable, Hashable {
  public var model: String?
  public var thinking: String?
  public var permission: String?
  public var models: [SessionOption]
  public var thinkingLevels: [SessionOption]
  public var permissionModes: [SessionOption]
  public var commands: [SessionCommand]

  public init(model: String? = nil, thinking: String? = nil, permission: String? = nil, models: [SessionOption] = [],
              thinkingLevels: [SessionOption] = [], permissionModes: [SessionOption] = [], commands: [SessionCommand] = []) {
    self.model = model
    self.thinking = thinking
    self.permission = permission
    self.models = models
    self.thinkingLevels = thinkingLevels
    self.permissionModes = permissionModes
    self.commands = commands
  }
}

/// Everything a subscriber needs before live events: the finished items, the
/// items in progress, run state, open prompts and the configuration, all
/// taken at one instant.
public struct SessionSnapshot: Codable, Sendable, Hashable {
  public var session: Session
  public var items: [SessionItem]
  public var inProgress: [LiveItem]
  public var run: RunState
  public var prompts: [Prompt]
  public var configuration: SessionConfiguration

  public init(session: Session, items: [SessionItem], inProgress: [LiveItem], run: RunState, prompts: [Prompt],
              configuration: SessionConfiguration = SessionConfiguration()) {
    self.session = session
    self.items = items
    self.inProgress = inProgress
    self.run = run
    self.prompts = prompts
    self.configuration = configuration
  }
}

/// A live event of a session. Encoded with a `type` field.
public enum SessionEvent: Codable, Sendable, Hashable {
  /// An item started: assistant text that will arrive, or a tool call underway.
  case itemStarted(LiveItem)
  /// More text for an assistant item in progress.
  case text(itemID: String, delta: String)
  /// A tool call in progress changed.
  case toolActivity(itemID: String, call: ToolCall)
  /// An item finished and is now stored in the library.
  case itemFinished(SessionItem)
  /// An item in progress ended without being saved; forget it.
  case itemDropped(itemID: String)
  case runState(RunState)
  /// The runtime is waiting for an answer.
  case awaiting(Prompt)
  /// A prompt was answered or withdrawn.
  case answered(promptID: String)
  /// The model, thinking level, permission mode or what they can be changed.
  case configuration(SessionConfiguration)

  private enum Key: String, CodingKey { case type, item, itemID, delta, call, run, prompt, promptID, configuration }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    switch try container.decode(String.self, forKey: .type) {
    case "itemStarted": self = .itemStarted(try container.decode(LiveItem.self, forKey: .item))
    case "text": self = .text(itemID: try container.decode(String.self, forKey: .itemID),
                              delta: try container.decode(String.self, forKey: .delta))
    case "toolActivity": self = .toolActivity(itemID: try container.decode(String.self, forKey: .itemID),
                                              call: try container.decode(ToolCall.self, forKey: .call))
    case "itemFinished": self = .itemFinished(try container.decode(SessionItem.self, forKey: .item))
    case "itemDropped": self = .itemDropped(itemID: try container.decode(String.self, forKey: .itemID))
    case "runState": self = .runState(try container.decode(RunState.self, forKey: .run))
    case "awaiting": self = .awaiting(try container.decode(Prompt.self, forKey: .prompt))
    case "answered": self = .answered(promptID: try container.decode(String.self, forKey: .promptID))
    case "configuration": self = .configuration(try container.decode(SessionConfiguration.self, forKey: .configuration))
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown event type \(other)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    switch self {
    case .itemStarted(let item):
      try container.encode("itemStarted", forKey: .type)
      try container.encode(item, forKey: .item)
    case .text(let itemID, let delta):
      try container.encode("text", forKey: .type)
      try container.encode(itemID, forKey: .itemID)
      try container.encode(delta, forKey: .delta)
    case .toolActivity(let itemID, let call):
      try container.encode("toolActivity", forKey: .type)
      try container.encode(itemID, forKey: .itemID)
      try container.encode(call, forKey: .call)
    case .itemFinished(let item):
      try container.encode("itemFinished", forKey: .type)
      try container.encode(item, forKey: .item)
    case .itemDropped(let itemID):
      try container.encode("itemDropped", forKey: .type)
      try container.encode(itemID, forKey: .itemID)
    case .runState(let run):
      try container.encode("runState", forKey: .type)
      try container.encode(run, forKey: .run)
    case .awaiting(let prompt):
      try container.encode("awaiting", forKey: .type)
      try container.encode(prompt, forKey: .prompt)
    case .answered(let promptID):
      try container.encode("answered", forKey: .type)
      try container.encode(promptID, forKey: .promptID)
    case .configuration(let configuration):
      try container.encode("configuration", forKey: .type)
      try container.encode(configuration, forKey: .configuration)
    }
  }
}

/// A name plus a directory on one machine, which owns it.
public struct Folder: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var machineID: String
  public var name: String
  public var path: String
  public var createdAt: Date

  public init(id: String, machineID: String, name: String, path: String, createdAt: Date) {
    self.id = id
    self.machineID = machineID
    self.name = name
    self.path = path
    self.createdAt = createdAt
  }
}

/// A synced setting. The newest write of a key wins.
public struct Setting: Codable, Sendable, Hashable {
  public var key: String
  public var value: JSONValue

  public init(key: String, value: JSONValue) {
    self.key = key
    self.value = value
  }
}

/// A change to the library this server holds: its `changed` counter moved.
public struct LibraryEvent: Codable, Sendable, Hashable {
  public var changed: Int64

  public init(changed: Int64) {
    self.changed = changed
  }
}
