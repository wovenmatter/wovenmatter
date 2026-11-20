import Foundation

// The Woven MCP on the wire: a tool call one server carries out for another,
// and the browser and computer-use calls a Mac's server asks its UI to do.
// The catalog itself is defined once, in the server.

/// One piece of a tool's result, as MCP has it.
public enum ToolContent: Codable, Sendable, Hashable {
  case text(String)
  /// Base64 data.
  case image(data: String, mimeType: String)

  private enum Key: String, CodingKey { case type, text, data, mimeType }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: Key.self)
    switch try container.decode(String.self, forKey: .type) {
    case "image":
      self = .image(data: try container.decode(String.self, forKey: .data),
                    mimeType: try container.decode(String.self, forKey: .mimeType))
    default:
      self = .text(try container.decodeIfPresent(String.self, forKey: .text) ?? "")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: Key.self)
    switch self {
    case .text(let text):
      try container.encode("text", forKey: .type)
      try container.encode(text, forKey: .text)
    case .image(let data, let mimeType):
      try container.encode("image", forKey: .type)
      try container.encode(data, forKey: .data)
      try container.encode(mimeType, forKey: .mimeType)
    }
  }
}

/// What a tool returns. `isError` results are for the agent to read and act on.
public struct ToolResult: Codable, Sendable, Hashable {
  public var content: [ToolContent]
  public var isError: Bool

  public init(content: [ToolContent], isError: Bool = false) {
    self.content = content
    self.isError = isError
  }

  public static func text(_ text: String) -> ToolResult { ToolResult(content: [.text(text)]) }
  public static func error(_ text: String) -> ToolResult { ToolResult(content: [.text(text)], isError: true) }
}

/// Who calls a Woven tool: a session, or a bot, on a machine.
public struct ToolCaller: Codable, Sendable, Hashable {
  public var machineID: String
  public var sessionID: String?
  public var botID: String?

  public init(machineID: String, sessionID: String? = nil, botID: String? = nil) {
    self.machineID = machineID
    self.sessionID = sessionID
    self.botID = botID
  }
}

/// A group of Woven tools a session may be allowed or refused. Tools in no
/// group (goals, places, bots) are always offered.
public enum ToolGroup: String, Codable, Sendable, Hashable, CaseIterable, Identifiable {
  case notes, history, sessions, timers, calendar, library, browser, computer

  public var id: String { rawValue }

  public var title: String {
    switch self {
    case .notes: "Notes"
    case .history: "Conversation history"
    case .sessions: "Session management"
    case .timers: "Timers"
    case .calendar: "Calendar"
    case .library: "Library"
    case .browser: "Browser Use"
    case .computer: "Computer Use"
    }
  }

  /// What a session may use when neither it nor any setting says otherwise.
  public static let standard: Set<ToolGroup> = Set(allCases).subtracting([.computer])

  /// The synced setting holding the groups new chats may use, as an array of names.
  public static let defaultsSetting = "tools.defaults"
}

/// Carries out one Woven tool on the machine asked, for a caller on another
/// machine: a tool that concerns this machine (a session it runs) is sent
/// here by the caller's own server. Only servers send it.
public struct CallTool: Request {
  public static let method = "tools.call"
  public typealias Reply = ToolResult
  public var name: String
  public var arguments: JSONValue
  public var caller: ToolCaller

  public init(name: String, arguments: JSONValue, caller: ToolCaller) {
    self.name = name
    self.arguments = arguments
    self.caller = caller
  }
}

/// For the UI on the server's own Mac: delivers each browser, computer-use or
/// page-preview call the server wants carried out. The UI answers each with `AnswerUITool`.
public struct SubscribeUITools: Subscription {
  public static let method = "tools.ui.subscribe"
  public typealias Reply = Done
  public typealias Event = UIToolCall
  public init() {}
}

/// One call for the UI to carry out.
public struct UIToolCall: Codable, Sendable, Hashable, Identifiable {
  public var id: String
  /// `browser`, `computer` or `preview_html`.
  public var tool: String
  public var arguments: JSONValue
  /// The session that made the call, when a session did.
  public var sessionID: String?

  public init(id: String, tool: String, arguments: JSONValue, sessionID: String?) {
    self.id = id
    self.tool = tool
    self.arguments = arguments
    self.sessionID = sessionID
  }
}

/// The UI's answer to a `UIToolCall`.
public struct AnswerUITool: Request {
  public static let method = "tools.ui.answer"
  public typealias Reply = Done
  public var id: String
  public var result: ToolResult

  public init(id: String, result: ToolResult) {
    self.id = id
    self.result = result
  }
}
