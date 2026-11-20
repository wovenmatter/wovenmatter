import Foundation
import WovenProtocol

// The one adapter interface. Codex, Claude Code, Grok Build, OpenCode, Pi
// Durable and bots each implement it and are treated alike.

/// The model, thinking level and permission mode a session asks for, by the
/// runtime's own identifiers. Nil leaves one as it is.
public struct SessionChoices: Sendable, Hashable {
  public var model: String?
  public var thinking: String?
  public var permission: String?

  public init(model: String? = nil, thinking: String? = nil, permission: String? = nil) {
    self.model = model
    self.thinking = thinking
    self.permission = permission
  }

  public var isEmpty: Bool { model == nil && thinking == nil && permission == nil }
}

/// What the server tells a runtime when it opens a session.
public struct RuntimeStart: Sendable {
  /// The Woven session this native session serves.
  public var sessionID: String
  /// Where the runtime works: the folder's directory, or the session's own
  /// scratch directory. It exists.
  public var directory: String
  /// The native session to resume, or nil to start a new one.
  public var nativeHandle: String?
  /// What the session last chose; the runtime applies what it can.
  public var choices: SessionChoices

  public init(sessionID: String, directory: String, nativeHandle: String?, choices: SessionChoices = SessionChoices()) {
    self.sessionID = sessionID
    self.directory = directory
    self.nativeHandle = nativeHandle
    self.choices = choices
  }
}

/// A file attached to a turn, already in this machine's content store.
public struct TurnAttachment: Sendable, Hashable {
  public var name: String
  public var mimeType: String
  public var size: Int64
  /// The stored file, on this machine.
  public var file: URL

  public init(name: String, mimeType: String, size: Int64, file: URL) {
    self.name = name
    self.mimeType = mimeType
    self.size = size
    self.file = file
  }
}

/// One turn the person sends.
public struct Turn: Sendable, Hashable {
  public var text: String
  public var attachments: [TurnAttachment]

  public init(text: String, attachments: [TurnAttachment] = []) {
    self.text = text
    self.attachments = attachments
  }
}

/// Tokens a turn used, as the runtime reports them.
public struct TokenUsage: Sendable, Hashable {
  public var model: String?
  public var input: Int64
  public var output: Int64
  public var cacheRead: Int64
  public var cacheWrite: Int64
  /// In US dollars, when the runtime reports a cost.
  public var cost: Double?

  public init(model: String? = nil, input: Int64, output: Int64, cacheRead: Int64 = 0, cacheWrite: Int64 = 0, cost: Double? = nil) {
    self.model = model
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
    self.cost = cost
  }
}

/// What a runtime reports while its process runs. Events come in order on
/// one stream for the life of the process, across turns.
public enum RuntimeEvent: Sendable {
  /// More text of the assistant message in progress (one is started if none is).
  case text(String)
  /// The assistant message in progress is complete.
  case messageFinished
  /// A tool call's whole state now: the first report for `callID` starts it,
  /// later ones replace it, and `finished` ends it. Plans, to-do updates,
  /// reasoning and child tasks are tool calls too (`ToolCall.kind`).
  case tool(callID: String, call: ToolCall, finished: Bool)
  /// The runtime waits for an answer to a question or approval.
  case prompt(Prompt)
  /// A prompt was answered or withdrawn.
  case promptResolved(id: String)
  /// The configuration changed (a model switch, new options, a mode change).
  case configuration(SessionConfiguration)
  /// The turn ended; `failure` says why when it failed.
  case turnFinished(failure: String?, usage: TokenUsage?)
  /// The runtime lost the native session behind this chat.
  case nativeSessionGone
  /// The process ended. The next turn opens the session again.
  case exited
}

public enum RuntimeError: Error, Sendable, CustomStringConvertible {
  /// The native session asked for no longer exists. A runtime never starts a
  /// fresh one in its place.
  case nativeSessionGone
  case failed(String)

  public var description: String {
    switch self {
    case .nativeSessionGone: "The runtime no longer has this session."
    case .failed(let message): message
    }
  }
}

public protocol Runtime: Sendable {
  var kind: RuntimeKind { get }
  /// Starts a native session, or resumes `start.nativeHandle`. Throws
  /// `RuntimeError.nativeSessionGone` when that one is gone.
  func open(_ start: RuntimeStart) async throws -> any RuntimeSession
  /// Whether it is installed and signed in on this machine.
  func status() async -> RuntimeStatus
  /// Installs it, or updates it to the latest release.
  func install() async throws
}

extension Runtime {
  public func status() async -> RuntimeStatus {
    RuntimeStatus(runtime: kind, name: kind.rawValue, installed: true)
  }

  public func install() async throws {}
}

/// One native session with its process, kept alive between turns.
public protocol RuntimeSession: Sendable {
  /// The runtime's own identifier for the native session, for resuming it.
  var nativeHandle: String { get }
  /// The configuration when the session opened; changes arrive as events.
  var configuration: SessionConfiguration { get async }
  /// Every event of the process's life, across turns.
  var events: AsyncStream<RuntimeEvent> { get }
  /// Starts a turn. Returns once the runtime has taken it, not when it ends.
  func send(_ turn: Turn) async throws
  /// Changes the model, thinking level or permission mode; replies with what
  /// the runtime confirmed.
  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration
  /// Answers a prompt with an option's `id`, or free text.
  func answer(promptID: String, with answer: String) async throws
  func interrupt() async throws
  /// Ends the process. The native session stays for a later resume.
  func stop() async
}
