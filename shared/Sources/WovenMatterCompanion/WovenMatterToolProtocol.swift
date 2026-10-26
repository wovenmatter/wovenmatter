import Foundation

private func + (lhs: [String], rhs: Set<String>) -> Set<String> { Set(lhs).union(rhs) }
private func + (lhs: Set<String>, rhs: Set<String>) -> Set<String> { lhs.union(rhs) }
private func + (lhs: Set<String>, rhs: [String]) -> Set<String> { lhs.union(rhs) }

/// Wire requests carry no caller/session authority. The owning app binds that to
/// the private endpoint when it is created and checks current settings per call.
public struct WovenMatterToolRequest: Codable, Sendable {
  public static let maximumHTMLRequestBytes = 40 * 1_024 * 1_024
  public var maximumEncodedBytes: Int {
    (try? WovenMatterToolCommand(arguments).group) == .html ? Self.maximumHTMLRequestBytes : 4 * 1_024 * 1_024
  }
  public var schemaVersion: Int
  public var requestID: String
  public var arguments: [String]
  public var noteEdit: NoteEditingRequest?
  /// Immutable input binding supplied by the native tool integration.
  public var contextID: String?
  public init(arguments: [String], requestID: String = UUID().uuidString.lowercased(), noteEdit: NoteEditingRequest? = nil, contextID: String? = nil) {
    self.schemaVersion = 1
    self.requestID = UUID(uuidString: requestID)?.uuidString.lowercased() ?? requestID
    self.arguments = arguments
    self.noteEdit = noteEdit
    self.contextID = contextID
  }
  /// The transport request ID is separate from the normalized operation.
  /// The internal dispatch representation never grants caller authority.
  public var operationArguments: [String] {
    (try? WovenMatterToolCommand(arguments).operationArguments) ?? arguments
  }
}

public struct WovenMatterToolResponse: Codable, Equatable, Sendable {
  public let success: Bool
  public let result: GatewayJSONValue?
  public let error: String?
  public let code: String?
  public let silent: Bool
  public let requestID: String?
  public init(success: Bool = true, result: GatewayJSONValue? = nil, error: String? = nil,
              code: String? = nil, silent: Bool = false, requestID: String? = nil) {
    self.success = success; self.result = result; self.error = error; self.code = code
    self.silent = silent; self.requestID = requestID
  }
  public static let maximumResponseBytes = 1_048_576

  /// Apply the same encoded-byte ceiling to local and relayed tool responses.
  /// A caller can retry large reads with a smaller page or character window.
  public func bounded() -> Self {
    guard let encoded = try? JSONEncoder().encode(self) else {
      return Self(success: false, error: "The tool response could not be encoded.",
        code: "response_encoding_failed", requestID: UUID(uuidString: requestID ?? "")?.uuidString.lowercased())
    }
    guard encoded.count <= Self.maximumResponseBytes else {
      return Self(success: false,
        error: "The response exceeds 1 MiB. Retry reads with a smaller limit or characters value.",
        code: "response_too_large", requestID: UUID(uuidString: requestID ?? "")?.uuidString.lowercased())
    }
    return self
  }

  public static func value<T: Encodable>(_ value: T) throws -> Self {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return Self(result: try JSONDecoder().decode(GatewayJSONValue.self, from: encoder.encode(value)))
  }
}

public struct WovenMatterToolCommand: Sendable {
  public let group: WorkspaceToolGroup?
  public let action: String
  public let positional: [String]
  public let options: [String: String]
  public let optionIndices: [String: Int]
  public let operationArguments: [String]
  public let wantsHelp: Bool

  public var isDatabaseCommand: Bool { operationArguments.first == "databases" }

  public var subaction: String? { group == .notes && action == "table" ? positional.first : nil }
  public var commandPath: String {
    [group?.rawValue, action == "help" ? nil : action, subaction].compactMap { $0 }.joined(separator: " ")
  }
  public var isMutation: Bool {
    switch group {
    case .notes: return !["database-list", "database-query", "list", "folders", "read", "versions", "version"].contains(action)
    case .history, .usage, .library: return false
    case .sessions: return ["create", "send", "manage", "release", "notifications"].contains(action)
    case .executor: return action == "execute" || action == "cancel"
    case .goals: return action != "get"
    case .browser, .computer, .html: return action == "call"
    case .timers: return action != "list"
    case .calendar: return !["list", "read", "occurrences"].contains(action)
    case nil: return false
    }
  }

  public init(_ arguments: [String]) throws {
    guard arguments.count <= 1_024 else {
      throw WorkspaceToolError.invalid("A tool command must contain at most 1,024 arguments.")
    }
    // ArraySlice removes from the front in constant time, even for malformed input.
    var args = arguments[...]
    guard !args.isEmpty else { throw WorkspaceToolError.invalid("Choose a Woven tool operation.") }
    let domain = args.removeFirst()
    if domain == "context" {
      guard args.isEmpty else { throw WorkspaceToolError.invalid("Context does not accept caller-selected assets or messages.") }
      self.group = nil; self.action = "context"; self.positional = []; self.options = [:]
      self.optionIndices = [:]; self.operationArguments = arguments; self.wantsHelp = false
      return
    }
    guard let group = WorkspaceToolGroup(rawValue: domain == "databases" ? "notes" : domain) else {
      throw WorkspaceToolError.invalid("Unknown Woven tool group '\(domain)'.")
    }
    self.group = group
    guard !args.isEmpty else { throw WorkspaceToolError.invalid("Choose a \(domain) operation.") }
    self.action = (domain == "databases" ? "database-" : "") + args.removeFirst()
    let allowedActions: [WorkspaceToolGroup: Set<String>] = [
      .notes: ["database-list", "database-create", "database-query", "database-execute", "list", "folders", "create", "read", "append", "insert", "replace-block", "delete-block", "format", "set-title", "table", "set-html", "link", "unlink", "apply", "versions", "version", "restore"],
      .history: ["search", "conversations", "conversation", "message", "runs", "trace", "events", "event"],
      .sessions: ["list", "status", "create", "send", "manage", "release", "notifications", "receipts", "folders", "harnesses"],
      .goals: ["get", "set", "pause", "resume", "clear", "complete", "block", "checkpoint"],
      .timers: ["list", "create", "update", "pause", "resume", "remove"],
      .executor: ["execute", "search", "skills", "status", "cancel"],
      .browser: ["call", "cancel"], .computer: ["call", "cancel"], .html: ["call", "cancel"],
      .usage: ["read"], .calendar: ["list", "read", "occurrences", "create", "update", "remove", "copy", "detach"], .library: ["list", "read"]
    ]
    guard allowedActions[group]?.contains(action) == true else { throw WorkspaceToolError.invalid("Unknown \(domain) command '\(action)'.") }
    let booleanFlags: Set<String> = ["all-workspace", "independent", "no-notify", "paused", "all-day", "timed", "no-repeat", "regular-event", "json", "header"]
    let valueFlags: Set<String> = ["id", "session", "conversation", "note-id", "folder", "workspace", "directory", "harness", "model", "thinking", "title", "text", "purpose", "request-id", "search", "run", "kind", "sender", "since", "until", "after", "before", "limit", "offset", "characters", "sort", "epoch", "at", "every", "starts-at", "ends-at", "description", "prompt", "time-zone", "repeat-unit", "repeat-interval", "session-mode", "occurrence", "enabled", "revision", "version", "html", "style", "block-id", "table-id", "row", "column", "rows", "columns", "source-id", "native-session-id", "native-record-id", "native-conversation-id", "database-id", "path", "query", "code", "objective", "evidence", "token-budget", "turn-budget"]
    var positional: [String] = [], options: [String: String] = [:]
    var indices: [String: Int] = [:], operationArguments = Array(arguments.prefix(2))
    while !args.isEmpty {
      let item = args.removeFirst()
      if ["--help", "-h"].contains(item) { throw WorkspaceToolError.invalid("Discover Woven tool schemas through MCP tools/list.") }
      if !item.hasPrefix("--") { positional.append(item); operationArguments.append(item); continue }
      let key = String(item.dropFirst(2))
      guard booleanFlags.contains(key) || valueFlags.contains(key), options[key] == nil else {
        throw WorkspaceToolError.invalid("Unknown or repeated option '\(item)'.")
      }
      indices[key] = arguments.count - args.count - 1
      if booleanFlags.contains(key) && !([.notes, .browser, .computer, .html].contains(group) && key == "json") {
        options[key] = "true"; operationArguments.append(item)
      } else {
        guard !args.isEmpty else { throw WorkspaceToolError.invalid("\(item) requires a value.") }
        let value = args.removeFirst()
        options[key] = value
        if key != "request-id" { operationArguments += [item, value] }
      }
    }
    try Self.validate(group: group, action: action, positional: positional, options: options)
    self.positional = positional
    self.options = options
    self.optionIndices = indices
    self.wantsHelp = false
    self.operationArguments = operationArguments
  }

  private static func validate(group: WorkspaceToolGroup, action: String,
                               positional: [String], options: [String: String]) throws {
    let request = Set(["request-id"])
    let revision = Set(["revision"])
    let pagination = Set(["after", "limit"])
    let bodyChunk = Set(["offset", "characters"])
    let allowed: Set<String>
    let maximumPositionals: Int
    switch (group, action) {
    case (.browser, "call"), (.computer, "call"), (.html, "call"): allowed = ["json"] + request; maximumPositionals = 0
    case (.browser, "cancel"), (.computer, "cancel"), (.html, "cancel"): allowed = ["id"] + request; maximumPositionals = 0
    case (.executor, "execute"): allowed = ["code"] + request; maximumPositionals = 0
    case (.executor, "search"): allowed = ["query", "limit"] + request; maximumPositionals = 0
    case (.executor, "skills"): allowed = request; maximumPositionals = 0
    case (.executor, "status"), (.executor, "cancel"): allowed = ["id"] + request; maximumPositionals = 1
    case (.notes, "database-list"): allowed = []; maximumPositionals = 0
    case (.notes, "database-create"): allowed = ["title"] + request; maximumPositionals = 0
    case (.notes, "database-query"), (.notes, "database-execute"): allowed = ["database-id", "query"] + request; maximumPositionals = 0
    case (.notes, "list"): allowed = ["search", "folder", "sort"] + pagination; maximumPositionals = 0
    case (.notes, "folders"): allowed = pagination; maximumPositionals = 0
    case (.notes, "create"): allowed = ["title", "kind", "folder"] + request; maximumPositionals = 0
    case (.notes, "read"): allowed = ["note-id"] + bodyChunk; maximumPositionals = 1
    case (.notes, "append"): allowed = ["note-id", "text", "style"] + revision + request; maximumPositionals = 0
    case (.notes, "insert"): allowed = ["note-id", "text", "after", "style"] + revision + request; maximumPositionals = 0
    case (.notes, "replace-block"): allowed = ["note-id", "id", "json"] + revision + request; maximumPositionals = 0
    case (.notes, "delete-block"): allowed = ["note-id", "id"] + revision + request; maximumPositionals = 0
    case (.notes, "format"): allowed = ["note-id", "block-id", "style"] + revision + request; maximumPositionals = 0
    case (.notes, "set-title"): allowed = ["note-id", "title"] + revision + request; maximumPositionals = 0
    case (.notes, "set-html"): allowed = ["note-id", "html"] + revision + request; maximumPositionals = 0
    case (.notes, "link"): allowed = ["note-id", "source-id", "database-id", "path", "query", "table-id"] + revision + request; maximumPositionals = 0
    case (.notes, "unlink"): allowed = ["note-id", "table-id"] + revision + request; maximumPositionals = 0
    case (.notes, "apply"): allowed = ["note-id", "json"] + revision + request; maximumPositionals = 0
    case (.notes, "versions"): allowed = pagination + ["note-id"]; maximumPositionals = 1
    case (.notes, "version"): allowed = bodyChunk + ["id", "version"]; maximumPositionals = 1
    case (.notes, "restore"): allowed = ["note-id", "version", "revision"] + request; maximumPositionals = 1
    case (.notes, "table"):
      guard let subaction = positional.first,
            ["create", "set-cell", "add-row", "remove-row", "add-column", "remove-column"].contains(subaction) else {
        throw WorkspaceToolError.invalid("Choose a table action: create, set-cell, add-row, remove-row, add-column, or remove-column.")
      }
      switch subaction {
      case "create": allowed = ["note-id", "after", "rows", "columns", "header"] + revision + request
      case "set-cell": allowed = ["note-id", "table-id", "row", "column", "text"] + revision + request
      case "add-row", "add-column": allowed = ["note-id", "table-id", "after"] + revision + request
      case "remove-row": allowed = ["note-id", "table-id", "row"] + revision + request
      default: allowed = ["note-id", "table-id", "column"] + revision + request
      }
      maximumPositionals = 1
    case (.history, "search"): allowed = ["search", "all-workspace", "conversation", "run", "harness", "folder", "kind", "since", "until", "source-id", "native-session-id", "native-record-id", "native-conversation-id"] + pagination; maximumPositionals = 1
    case (.history, "events"): allowed = ["conversation", "run", "harness", "folder", "kind", "search", "since", "until", "source-id", "native-session-id", "native-record-id", "native-conversation-id"] + pagination; maximumPositionals = 0
    case (.history, "trace"): allowed = ["id", "run", "kind", "since", "until"] + pagination; maximumPositionals = 1
    case (.history, "event"): allowed = ["id"] + bodyChunk; maximumPositionals = 1
    case (.history, "conversations"): allowed = ["search", "folder", "all-workspace", "sort"] + pagination; maximumPositionals = 0
    case (.history, "conversation"): allowed = ["id"] + pagination + bodyChunk; maximumPositionals = 1
    case (.history, "message"): allowed = ["id"] + bodyChunk; maximumPositionals = 1
    case (.history, "runs"): allowed = ["conversation"] + pagination; maximumPositionals = 0
    case (.sessions, "list"): allowed = ["search", "folder", "all-workspace", "sort"] + pagination; maximumPositionals = 0
    case (.sessions, "status"): allowed = ["id"]; maximumPositionals = 1
    case (.sessions, "create"): allowed = ["title", "text", "purpose", "independent", "harness", "model", "thinking", "folder", "workspace", "directory"] + request; maximumPositionals = 0
    case (.sessions, "send"): allowed = ["id", "text"] + request; maximumPositionals = 1
    case (.sessions, "manage"): allowed = ["id", "purpose", "no-notify"] + request; maximumPositionals = 1
    case (.sessions, "release"): allowed = ["id", "epoch"] + request; maximumPositionals = 1
    case (.sessions, "notifications"): allowed = ["id", "epoch", "enabled"] + request; maximumPositionals = 1
    case (.sessions, "receipts"): allowed = ["before", "limit"]; maximumPositionals = 0
    case (.sessions, "folders"): allowed = pagination; maximumPositionals = 0
    case (.sessions, "harnesses"): allowed = ["offset", "limit"]; maximumPositionals = 0
    case (.goals, "get"): allowed = []; maximumPositionals = 0
    case (.goals, "set"): allowed = ["objective", "token-budget", "turn-budget"] + request; maximumPositionals = 0
    case (.goals, "pause"), (.goals, "resume"), (.goals, "clear"): allowed = ["id"] + request; maximumPositionals = 0
    case (.goals, "complete"), (.goals, "block"), (.goals, "checkpoint"): allowed = ["id", "evidence"] + request; maximumPositionals = 0
    case (.timers, "list"): allowed = ["session"] + pagination; maximumPositionals = 0
    case (.timers, "create"): allowed = ["text", "at", "every", "session", "paused"] + request; maximumPositionals = 0
    case (.timers, "update"): allowed = ["id", "text", "at", "every", "paused"] + request; maximumPositionals = 1
    case (.timers, "pause"), (.timers, "resume"), (.timers, "remove"): allowed = ["id"] + request; maximumPositionals = 1
    case (.usage, "read"): allowed = ["since", "until", "offset", "limit"]; maximumPositionals = 0
    case (.calendar, "list"): allowed = ["since", "until"] + pagination; maximumPositionals = 0
    case (.calendar, "read"): allowed = ["id"] + pagination; maximumPositionals = 1
    case (.calendar, "occurrences"): allowed = ["id", "since", "until"] + pagination; maximumPositionals = 1
    case (.calendar, "create"): allowed = calendarWriteOptions + ["title", "starts-at"] + request; maximumPositionals = 0
    case (.calendar, "update"): allowed = calendarWriteOptions + ["id", "revision"] + request; maximumPositionals = 1
    case (.calendar, "remove"): allowed = ["id", "occurrence", "revision"] + request; maximumPositionals = 1
    case (.calendar, "copy"): allowed = calendarWriteOptions + ["id", "starts-at"] + request; maximumPositionals = 1
    case (.calendar, "detach"): allowed = calendarWriteOptions + ["id", "occurrence", "revision"] + request; maximumPositionals = 1
    case (.library, "list"): allowed = ["search", "workspace", "harness", "kind", "sender", "since", "until", "offset", "limit"]; maximumPositionals = 0
    case (.library, "read"): allowed = ["id"]; maximumPositionals = 1
    default: allowed = []; maximumPositionals = 0
    }
    if let unsupported = options.keys.sorted().first(where: { !allowed.contains($0) }) {
      throw WorkspaceToolError.invalid("--\(unsupported) is not supported by \(group.rawValue) \(action).")
    }
    guard positional.count <= maximumPositionals else {
      throw WorkspaceToolError.invalid("Too many positional arguments for \(group.rawValue) \(action).")
    }
    let positionalAliases: [String]
    switch (group, action) {
    case (.notes, "read"), (.notes, "versions"), (.notes, "restore"): positionalAliases = ["note-id"]
    case (.notes, "version"): positionalAliases = ["id", "version"]
    case (.history, "search"): positionalAliases = ["search"]
    case (.history, "trace"): positionalAliases = ["id", "run"]
    case (.history, "event"), (.history, "conversation"), (.history, "message"),
         (.sessions, "status"), (.sessions, "send"), (.sessions, "manage"),
         (.sessions, "release"), (.sessions, "notifications"),
         (.timers, "update"), (.timers, "pause"), (.timers, "resume"), (.timers, "remove"),
         (.calendar, "read"), (.calendar, "occurrences"), (.calendar, "update"),
         (.calendar, "remove"), (.calendar, "copy"), (.calendar, "detach"),
         (.library, "read"), (.executor, "status"), (.executor, "cancel"):
      positionalAliases = ["id"]
    default: positionalAliases = []
    }
    if !positional.isEmpty, let duplicate = positionalAliases.first(where: { options[$0] != nil }) {
      throw WorkspaceToolError.invalid("Pass the positional value or --\(duplicate), not both.")
    }
    if group == .calendar {
      for pair in [("all-day", "timed"), ("no-repeat", "repeat-unit"), ("no-repeat", "repeat-interval"), ("regular-event", "prompt")] {
        if options[pair.0] != nil, options[pair.1] != nil {
          throw WorkspaceToolError.invalid("--\(pair.0) cannot be combined with --\(pair.1).")
        }
      }
      let taskOptions = ["prompt", "harness", "model", "thinking", "workspace", "directory", "folder", "session-mode"]
      if options["regular-event"] != nil,
         let taskOption = taskOptions.first(where: { options[$0] != nil }) {
        throw WorkspaceToolError.invalid("--regular-event cannot be combined with --\(taskOption).")
      }
    }
    if let sort = options["sort"], !["newest", "oldest"].contains(sort) {
      throw WorkspaceToolError.invalid("--sort must be newest or oldest.")
    }
  }

  private static let calendarWriteOptions: Set<String> = [
    "title", "starts-at", "ends-at", "description", "all-day", "timed", "time-zone",
    "repeat-unit", "repeat-interval", "no-repeat", "prompt", "regular-event", "harness",
    "model", "thinking", "workspace", "directory", "folder", "session-mode"
  ]

  public func required(_ key: String, allowPositional: Bool = false) throws -> String {
    guard let value = options[key] ?? (allowPositional ? positional.first : nil), !value.isEmpty else {
      throw WorkspaceToolError.invalid("--\(key) is required.")
    }
    return value
  }
  public func integer(_ key: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
    guard let raw = options[key] else { return fallback }
    guard let value = Int(raw), range.contains(value) else { throw WorkspaceToolError.invalid("--\(key) must be between \(range.lowerBound) and \(range.upperBound).") }
    return value
  }

}
