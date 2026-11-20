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
  /// Where its server listens on the tailnet, once this server has reached it;
  /// a UI connects there directly for what runs on that machine.
  public var address: String?
  public var port: Int?

  public init(machine: Machine, isThisMachine: Bool, online: Bool, appVersion: String?,
              address: String? = nil, port: Int? = nil) {
    self.machine = machine
    self.isThisMachine = isThisMachine
    self.online = online
    self.appVersion = appVersion
    self.address = address
    self.port = port
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
  /// The Pi coding agent's own CLI. Woven Matter does not run it; only its
  /// usage is read, from its session files.
  public static let piCLI = RuntimeKind(rawValue: "piCLI")
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
  /// When it was last moved to Trash.
  public var archivedAt: Date?
  public var pinned: Bool
  /// The goal the session works against until it is met or cleared.
  public var goal: String?
  public var createdAt: Date
  /// When its newest item was saved, or when it was created.
  public var lastActivityAt: Date
  /// The start of its last user or assistant message.
  public var preview: String?
  /// Its newest item is not the person's own message and came after they
  /// last read it.
  public var unread: Bool
  /// The groups of Woven tools it may use; nil follows the defaults for new chats.
  public var tools: Set<ToolGroup>?

  public init(id: String, machineID: String, runtime: RuntimeKind, title: String, folderID: String?,
              directory: String = "", model: String? = nil, thinking: String? = nil, permission: String? = nil,
              archived: Bool, pinned: Bool = false, goal: String?, createdAt: Date, lastActivityAt: Date? = nil,
              preview: String? = nil, unread: Bool = false, tools: Set<ToolGroup>? = nil, archivedAt: Date? = nil) {
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
    self.archivedAt = archivedAt
    self.pinned = pinned
    self.goal = goal
    self.createdAt = createdAt
    self.lastActivityAt = lastActivityAt ?? createdAt
    self.preview = preview
    self.unread = unread
    self.tools = tools
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
  /// Who said it, in a chat with more than one speaker (the Forum). Nil is
  /// the person, or the session's own runtime.
  public var author: ItemAuthor?

  public init(id: String, sessionID: String, sequence: Int, createdAt: Date, content: ItemContent,
              author: ItemAuthor? = nil) {
    self.id = id
    self.sessionID = sessionID
    self.sequence = sequence
    self.createdAt = createdAt
    self.content = content
    self.author = author
  }
}

/// The speaker of an item in a chat with several: a bot by its identifier,
/// or another session that sent it through the Woven MCP, with the name it
/// had when it spoke. A message the server sent for a goal, a timer, a
/// wake-up or a scheduled task names that as its `source`.
public struct ItemAuthor: Codable, Sendable, Hashable {
  public var botID: String?
  public var name: String
  public var sessionID: String?
  public var source: ItemSource?

  public init(botID: String?, name: String, sessionID: String? = nil, source: ItemSource? = nil) {
    self.botID = botID
    self.name = name
    self.sessionID = sessionID
    self.source = source
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
  /// Woven's `render_html`: the visual reply it published is its own item
  /// (`ItemContent.visualReply`), and the call does not carry it.
  public static let visualReply = ToolKind(rawValue: "visualReply")
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

/// A visual reply: self-contained HTML an agent published in the chat with
/// `render_html`. It is not a Page artifact. Its HTML is stored once, in the
/// content store by digest; another machine fetches it when it is opened.
public struct VisualReply: Codable, Sendable, Hashable {
  public var title: String
  /// The height it starts at, in points, before it has measured itself.
  public var height: Int
  public var digest: String
  public var size: Int64

  public init(title: String, height: Int, digest: String, size: Int64) {
    self.title = title
    self.height = height
    self.digest = digest
    self.size = size
  }
}

/// What a session item holds. Encoded with a `type` field.
public enum ItemContent: Codable, Sendable, Hashable {
  case userMessage(text: String, attachments: [Attachment] = [])
  case assistantMessage(text: String)
  case toolCall(ToolCall)
  case notice(Notice)
  case visualReply(VisualReply)

  private enum Key: String, CodingKey { case type, text, attachments, call, notice, visualReply }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    switch try container.decode(String.self, forKey: .type) {
    case "userMessage":
      self = .userMessage(text: try container.decode(String.self, forKey: .text),
                          attachments: try container.decodeIfPresent([Attachment].self, forKey: .attachments) ?? [])
    case "assistantMessage": self = .assistantMessage(text: try container.decode(String.self, forKey: .text))
    case "toolCall": self = .toolCall(try container.decode(ToolCall.self, forKey: .call))
    case "notice": self = .notice(try container.decode(Notice.self, forKey: .notice))
    case "visualReply": self = .visualReply(try container.decode(VisualReply.self, forKey: .visualReply))
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
    case .visualReply(let reply):
      try container.encode("visualReply", forKey: .type)
      try container.encode(reply, forKey: .visualReply)
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

/// What one session on the server asked is doing now. Live state.
public struct SessionRunState: Codable, Sendable, Hashable {
  public var sessionID: String
  public var run: RunState
  /// The turn waits on the person: an approval, a question or a form.
  public var awaiting: Bool

  public init(sessionID: String, run: RunState, awaiting: Bool = false) {
    self.sessionID = sessionID
    self.run = run
    self.awaiting = awaiting
  }
}

/// One answer a prompt offers.
public struct PromptOption: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  public var name: String
  public var detail: String?
  /// For an approval, the option that allows this one request only.
  public var allowsOnce: Bool

  public init(id: String, name: String, detail: String? = nil, allowsOnce: Bool = false) {
    self.id = id
    self.name = name
    self.detail = detail
    self.allowsOnce = allowsOnce
  }

}

/// One field of a form a runtime asks the person to fill in.
public struct PromptField: Codable, Sendable, Hashable, Identifiable {
  public enum Kind: String, Codable, Sendable, Hashable {
    case text
    /// One of `options`; the value is an option's `id`.
    case choice
    /// Any of `options`; the value is an array of option ids.
    case choices
    case number
    case integer
    case boolean
  }

  /// The key the answer gives this field's value under.
  public var id: String
  public var title: String
  public var detail: String?
  public var kind: Kind
  public var required: Bool
  public var options: [PromptOption]
  /// The value the field starts with.
  public var initial: JSONValue?
  public var placeholder: String?
  public var multiline: Bool
  /// Bounds of a number, or of a text's length or a choice count.
  public var minimum: Double?
  public var maximum: Double?

  public init(id: String, title: String, detail: String? = nil, kind: Kind = .text, required: Bool = true,
              options: [PromptOption] = [], initial: JSONValue? = nil, placeholder: String? = nil, multiline: Bool = false,
              minimum: Double? = nil, maximum: Double? = nil) {
    self.id = id
    self.title = title
    self.detail = detail
    self.kind = kind
    self.required = required
    self.options = options
    self.initial = initial
    self.placeholder = placeholder
    self.multiline = multiline
    self.minimum = minimum
    self.maximum = maximum
  }
}

/// Something the runtime waits on the person for, in one shape for every
/// runtime: an approval (pick one of `options`), a question (pick one of
/// `options`, or answer in text when there are none), or a form (fill in
/// `fields`).
public struct Prompt: Codable, Sendable, Hashable, Identifiable {
  public enum Kind: String, Codable, Sendable, Hashable {
    case approval
    case question
    case form
  }

  public var id: String
  public var kind: Kind
  public var text: String
  public var options: [PromptOption]
  public var fields: [PromptField]

  public init(id: String, kind: Kind, text: String, options: [PromptOption] = [], fields: [PromptField] = []) {
    self.id = id
    self.kind = kind
    self.text = text
    self.options = options
    self.fields = fields
  }
}

/// The person's answer to a prompt. Encoded with a `type` field.
public enum PromptAnswer: Codable, Sendable, Hashable {
  /// One of the prompt's options, by `id`.
  case option(String)
  /// Free text, for a question without options.
  case text(String)
  /// A form's values, by field `id`.
  case values([String: JSONValue])
  /// The person declined to answer.
  case declined

  private enum Key: String, CodingKey { case type, id, text, values }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    switch try container.decode(String.self, forKey: .type) {
    case "option": self = .option(try container.decode(String.self, forKey: .id))
    case "text": self = .text(try container.decode(String.self, forKey: .text))
    case "values": self = .values(try container.decode([String: JSONValue].self, forKey: .values))
    case "declined": self = .declined
    case let other:
      throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown answer type \(other)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    switch self {
    case .option(let id):
      try container.encode("option", forKey: .type)
      try container.encode(id, forKey: .id)
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .values(let values):
      try container.encode("values", forKey: .type)
      try container.encode(values, forKey: .values)
    case .declined:
      try container.encode("declined", forKey: .type)
    }
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
  /// The session's goal, so a goal set or cleared from any UI reaches every
  /// open view at once.
  public var goal: String?

  public init(model: String? = nil, thinking: String? = nil, permission: String? = nil, models: [SessionOption] = [],
              thinkingLevels: [SessionOption] = [], permissionModes: [SessionOption] = [], commands: [SessionCommand] = [],
              goal: String? = nil) {
    self.model = model
    self.thinking = thinking
    self.permission = permission
    self.models = models
    self.thinkingLevels = thinkingLevels
    self.permissionModes = permissionModes
    self.commands = commands
    self.goal = goal
  }
}

/// Everything a subscriber needs before live events: the newest finished
/// items (older ones come from `SessionItems` with `beforeSequence`), the
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
  /// A tool call in progress changed. Output it had keeps unless this one has some.
  case toolActivity(itemID: String, call: ToolCall)
  /// More output for a tool call in progress.
  case toolOutput(itemID: String, delta: String)
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
    case "toolOutput": self = .toolOutput(itemID: try container.decode(String.self, forKey: .itemID),
                                          delta: try container.decode(String.self, forKey: .delta))
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
    case .toolOutput(let itemID, let delta):
      try container.encode("toolOutput", forKey: .type)
      try container.encode(itemID, forKey: .itemID)
      try container.encode(delta, forKey: .delta)
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
  public var pinned: Bool
  /// Order in the sidebar among the machine's folders, lowest first.
  public var position: Int
  /// The server made the directory (rather than the person linking one), so
  /// deleting the folder may delete the directory too.
  public var managed: Bool
  /// Other directories on the machine its agents may use.
  public var references: [String]
  public var createdAt: Date

  public init(id: String, machineID: String, name: String, path: String, pinned: Bool = false, position: Int = 0,
              managed: Bool = false, references: [String] = [], createdAt: Date) {
    self.id = id
    self.machineID = machineID
    self.name = name
    self.path = path
    self.pinned = pinned
    self.position = position
    self.managed = managed
    self.references = references
    self.createdAt = createdAt
  }
}

/// One directory on a machine and the directories directly inside it.
public struct DirectoryListing: Codable, Sendable, Hashable {
  public struct Entry: Codable, Sendable, Hashable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
      self.name = name
      self.path = path
    }
  }

  public var path: String
  /// Nil at the root.
  public var parent: String?
  /// Sorted by name; hidden ones are left out.
  public var directories: [Entry]
  /// More directories exist than were listed.
  public var truncated: Bool

  public init(path: String, parent: String?, directories: [Entry], truncated: Bool) {
    self.path = path
    self.parent = parent
    self.directories = directories
    self.truncated = truncated
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
  /// The synced tables written since the previous event; every table in the
  /// subscription's first reply.
  public var tables: [String]

  public init(changed: Int64, tables: [String]) {
    self.changed = changed
    self.tables = tables
  }
}
