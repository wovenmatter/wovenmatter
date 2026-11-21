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
  /// The Woven MCP and Woven's instructions, which the runtime hands its
  /// native session in its own way; nil when this machine cannot offer them.
  public var tools: ToolAccess?
  /// Where the host has no bridge (a device), the Woven tools this session
  /// is offered, for a runtime in this process to take as its own tools.
  public var sessionTools: SessionTools?

  public init(sessionID: String, directory: String, nativeHandle: String?, choices: SessionChoices = SessionChoices(),
              tools: ToolAccess? = nil, sessionTools: SessionTools? = nil) {
    self.sessionID = sessionID
    self.directory = directory
    self.nativeHandle = nativeHandle
    self.choices = choices
    self.tools = tools
    self.sessionTools = sessionTools
  }
}

/// The Woven tools one session is offered, for a runtime that runs in this
/// process and gives them to its model as its own tools. A call goes the way
/// a call through the bridge goes: the same groups, the session as its
/// author, visual replies saved in its chat.
public struct SessionTools: Sendable {
  /// One tool as the model is shown it.
  public struct Definition: Sendable, Hashable {
    public var name: String
    public var description: String
    /// The JSON Schema of its arguments.
    public var input: JSONValue
    /// It changes nothing.
    public var readOnly: Bool
  }

  public let sessionID: String
  private let catalog: WovenTools

  package init(_ catalog: WovenTools, sessionID: String) {
    self.catalog = catalog
    self.sessionID = sessionID
  }

  /// The tools this session may use now. The groups it may use can change
  /// between turns, so ask before each turn.
  public func definitions() async -> [Definition] {
    catalog.offered(enabled: await catalog.enabledGroups(sessionID: sessionID)).map {
      Definition(name: $0.name, description: $0.description, input: $0.input, readOnly: $0.readOnly)
    }
  }

  /// Carries out one call as this session. A failure comes back as an error result.
  public func call(_ name: String, arguments: JSONValue) async -> ToolResult {
    await catalog.call(name, arguments: arguments, caller: ToolCaller(machineID: catalog.machineID, sessionID: sessionID))
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

/// Tokens a turn used, as a runtime without a history of its own (Pi
/// Durable) reports them. Harnesses with one are counted from it instead.
public struct TokenUsage: Sendable, Hashable {
  public var model: String?
  public var input: Int64
  public var output: Int64
  public var cacheRead: Int64
  public var cacheWrite: Int64

  public init(model: String? = nil, input: Int64, output: Int64, cacheRead: Int64 = 0, cacheWrite: Int64 = 0) {
    self.model = model
    self.input = input
    self.output = output
    self.cacheRead = cacheRead
    self.cacheWrite = cacheWrite
  }
}

/// What a runtime reports while its process runs. Events come in order on
/// one stream for the life of the process, across turns. Output while no turn
/// runs begins a turn the runtime started by itself, which the runtime ends
/// with `turnFinished` like any other.
public enum RuntimeEvent: Sendable {
  /// More text of the assistant message in progress (one is started if none is).
  case text(String)
  /// The assistant message in progress is complete.
  case messageFinished
  /// A tool call's whole state now: the first report for `callID` starts it,
  /// later ones replace it, and `finished` ends it. Plans, to-do updates,
  /// reasoning and child tasks are tool calls too (`ToolCall.kind`). A later
  /// report without output keeps the output streamed so far.
  case tool(callID: String, call: ToolCall, finished: Bool)
  /// More output of a tool call in progress, as it streams.
  case toolOutput(callID: String, delta: String)
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

/// How much of one tool call's input or output is kept, in characters: the start and the
/// end, with a plain line saying how much was left out between them.
package enum ToolOutput {
  package static let limit = 256 << 10

  package static func capped(_ text: String) -> String {
    let scalars = text.unicodeScalars
    guard text.utf8.count > limit, scalars.count > limit else { return text }
    let keep = limit / 2
    return joined(head: String(scalars.prefix(keep)), tail: String(scalars.suffix(keep)), omitted: scalars.count - 2 * keep)
  }

  package static func joined(head: String, tail: String, omitted: Int) -> String {
    head + "\n\n[\(omitted) characters left out]\n\n" + tail
  }

  package static func capped(_ call: ToolCall) -> ToolCall {
    var call = call
    call.input = capped(call.input)
    call.output = call.output.map(capped)
    return call
  }
}

public enum RuntimeError: Error, Sendable, CustomStringConvertible {
  /// The native session asked for no longer exists. A runtime never starts a
  /// fresh one in its place.
  case nativeSessionGone
  case failed(String)
  /// It cannot run now, for a reason the person can act on, said for them
  /// (for example that nothing is signed in). The chat shows it as said.
  case unavailable(String)

  public var description: String {
    switch self {
    case .nativeSessionGone: "The runtime no longer has this session."
    case .failed(let message), .unavailable(let message): message
    }
  }
}

/// How a runtime reaches the Woven MCP: a stdio MCP server it starts, which is
/// a bridge to this server's tool socket, and Woven's instructions for its
/// own instruction mechanism.
public struct ToolAccess: Sendable, Hashable {
  public var command: String
  public var arguments: [String]
  public var environment: [String: String]
  public var instructions: String

  package init(command: String, arguments: [String], environment: [String: String], instructions: String) {
    self.command = command
    self.arguments = arguments
    self.environment = environment
    self.instructions = instructions
  }

  /// As ACP's `mcpServers` lists a stdio server.
  package var acpServer: JSONValue {
    .object(["name": .string("woven"), "command": .string(command), "args": .array(arguments.map(JSONValue.string)),
             "env": .array(environment.sorted { $0.key < $1.key }.map {
               .object(["name": .string($0.key), "value": .string($0.value)])
             })])
  }
}

/// Who a connection to the tool socket speaks for. A bridge says its key
/// first; the key was given only to that runtime, in memory, by this server.
package enum ToolGrant: Sendable, Hashable {
  /// One session.
  case session(String)
  /// A runtime that serves several sessions through one bridge (OpenCode),
  /// naming the native session in each call.
  case runtime(RuntimeKind)
  /// An agent outside Woven Matter on this machine; its bridge says no key.
  /// It is answered only while outside agents are turned on.
  case outside
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
  /// One Woven MCP bridge serves all its sessions, and it names the session
  /// in each call (OpenCode), rather than one bridge per session.
  var sharesToolBridge: Bool { get }
}

extension Runtime {
  public func status() async -> RuntimeStatus {
    RuntimeStatus(runtime: kind, name: kind.rawValue, installed: true)
  }

  public func install() async throws {}
  public var sharesToolBridge: Bool { false }
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
  /// Steers the turn running now, also one the runtime started by itself:
  /// hands it a message through the runtime's own mid-turn input, which the
  /// turn takes in and goes on, still ending once. Returns once the runtime
  /// has taken it. Returns false, having taken nothing, when the runtime's
  /// turn has already ended; that end is then on its way in `events`.
  func steer(_ turn: Turn) async throws -> Bool
  /// Changes the model, thinking level or permission mode; replies with what
  /// the runtime confirmed.
  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration
  /// Answers a prompt the runtime asked.
  func answer(promptID: String, with answer: PromptAnswer) async throws
  func interrupt() async throws
  /// Ends the process. The native session stays for a later resume.
  func stop() async
}

extension RuntimeKind {
  /// The harness keeps its own history, and its usage is counted only from
  /// there, inside Woven Matter or not. A turn Woven Matter runs with it
  /// writes no usage record of its own.
  package var usageFromHistory: Bool { [.codex, .claudeCode, .grokBuild, .openCode, .piCLI].contains(self) }
}
