import Foundation
import WovenMatterCore

private func + (lhs: [String], rhs: Set<String>) -> Set<String> { Set(lhs).union(rhs) }
private func + (lhs: Set<String>, rhs: Set<String>) -> Set<String> { lhs.union(rhs) }
private func + (lhs: Set<String>, rhs: [String]) -> Set<String> { lhs.union(rhs) }

/// Wire requests carry no caller/session authority. The owning app binds that to
/// the private endpoint when it is created and checks current settings per call.
public struct WovenMatterToolRequest: Codable, Sendable {
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
  /// The transport's request ID is not part of the operation's arguments. A
  /// retry may add the returned ID without changing the original operation.
  public var operationArguments: [String] {
    (try? WovenMatterToolCommand(arguments).operationArguments) ?? arguments
  }
}

public struct WovenMatterToolResponse: Codable, Sendable {
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
        error: "The response exceeds 1 MiB. Retry reads with a smaller --limit or --characters value.",
        code: "response_too_large", requestID: UUID(uuidString: requestID ?? "")?.uuidString.lowercased())
    }
    return self
  }

  public static func note(_ response: NoteEditingResponse) throws -> Self {
    let encoded = try value(response)
    return Self(success: response.success, result: encoded.result, error: response.error)
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

  public var subaction: String? { group == .notes && action == "table" ? positional.first : nil }
  public var commandPath: String {
    [group?.rawValue, action == "help" ? nil : action, subaction].compactMap { $0 }.joined(separator: " ")
  }
  public var isMutation: Bool {
    switch group {
    case .notes: return !["list", "folders", "read", "versions", "version"].contains(action)
    case .history, .usage, .library: return false
    case .sessions: return ["create", "send", "manage", "release", "notifications"].contains(action)
    case .executor: return action == "execute" || action == "cancel"
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
    if args.isEmpty || ["help", "--help", "-h"].contains(args[0]) {
      self.group = nil; self.action = "help"; self.positional = []; self.options = [:]; self.optionIndices = [:]; self.operationArguments = arguments; self.wantsHelp = true
      return
    }
    let domain = args.removeFirst()
    if domain == "context" {
      guard args.isEmpty || [["help"], ["--help"], ["-h"]].contains(Array(args)) else {
        throw WorkspaceToolError.invalid("Usage: wovenmatter context")
      }
      self.group = nil; self.action = "context"; self.positional = []; self.options = [:]
      self.optionIndices = [:]; self.operationArguments = arguments; self.wantsHelp = !args.isEmpty
      return
    }
    guard let group = WorkspaceToolGroup(rawValue: domain) else {
      throw WorkspaceToolError.invalid("Unknown tool group '\(domain)'. Run wovenmatter help.")
    }
    self.group = group
    if args.isEmpty || [["help"], ["--help"], ["-h"]].contains(Array(args)) {
      self.action = "help"; self.wantsHelp = true
      self.positional = []; self.options = [:]; self.optionIndices = [:]; self.operationArguments = arguments; return
    }
    self.action = args.removeFirst()
    let allowedActions: [WorkspaceToolGroup: Set<String>] = [
      .notes: ["list", "folders", "create", "read", "append", "insert", "replace-block", "delete-block", "format", "set-title", "table", "set-html", "link", "unlink", "apply", "versions", "version", "restore"],
      .history: ["search", "conversations", "conversation", "message", "runs", "trace", "events", "event"],
      .sessions: ["list", "status", "create", "send", "manage", "release", "notifications", "receipts", "folders", "harnesses"],
      .timers: ["list", "create", "update", "pause", "resume", "remove"],
      .executor: ["execute", "search", "skills", "status", "cancel"],
      .usage: ["read"], .calendar: ["list", "read", "occurrences", "create", "update", "remove", "copy", "detach"], .library: ["list", "read"]
    ]
    guard allowedActions[group]?.contains(action) == true else { throw WorkspaceToolError.invalid("Unknown \(domain) command '\(action)'.") }
    let booleanFlags: Set<String> = ["all-workspace", "independent", "no-notify", "paused", "all-day", "timed", "no-repeat", "regular-event", "json", "header"]
    let valueFlags: Set<String> = ["id", "session", "conversation", "note-id", "folder", "workspace", "directory", "harness", "model", "thinking", "title", "text", "purpose", "request-id", "search", "run", "kind", "sender", "since", "until", "after", "before", "limit", "offset", "characters", "sort", "epoch", "at", "every", "starts-at", "ends-at", "description", "prompt", "time-zone", "repeat-unit", "repeat-interval", "session-mode", "occurrence", "enabled", "revision", "version", "file", "html", "style", "block-id", "table-id", "row", "column", "rows", "columns", "source-id", "native-session-id", "native-record-id", "database-id", "path", "query", "code"]
    var positional: [String] = [], options: [String: String] = [:]
    var indices: [String: Int] = [:], operationArguments = Array(arguments.prefix(2))
    var wantsHelp = false
    while !args.isEmpty {
      let item = args.removeFirst()
      if ["--help", "-h"].contains(item) { wantsHelp = true; continue }
      if !item.hasPrefix("--") { positional.append(item); operationArguments.append(item); continue }
      let key = String(item.dropFirst(2))
      guard booleanFlags.contains(key) || valueFlags.contains(key), options[key] == nil else {
        throw WorkspaceToolError.invalid("Unknown or repeated option '\(item)'.")
      }
      indices[key] = arguments.count - args.count - 1
      if booleanFlags.contains(key) && !(group == .notes && key == "json") {
        options[key] = "true"; operationArguments.append(item)
      } else {
        guard !args.isEmpty else { throw WorkspaceToolError.invalid("\(item) requires a value.") }
        let value = args.removeFirst()
        options[key] = value
        if key != "request-id" { operationArguments += [item, value] }
      }
    }
    if group == .notes, action == "table", positional.first == "help" {
      positional.removeFirst()
      wantsHelp = true
    }
    try Self.validate(group: group, action: action, positional: positional, options: options,
      wantsHelp: wantsHelp)
    self.positional = positional
    self.options = options
    self.optionIndices = indices
    self.wantsHelp = wantsHelp
    self.operationArguments = operationArguments
  }

  private static func validate(group: WorkspaceToolGroup, action: String,
                               positional: [String], options: [String: String],
                               wantsHelp: Bool) throws {
    let request = Set(["request-id"])
    let revision = Set(["revision"])
    let pagination = Set(["after", "limit"])
    let bodyChunk = Set(["offset", "characters"])
    let allowed: Set<String>
    let maximumPositionals: Int
    switch (group, action) {
    case (.executor, "execute"): allowed = ["code", "file"] + request; maximumPositionals = 0
    case (.executor, "search"): allowed = ["query", "limit"] + request; maximumPositionals = 0
    case (.executor, "skills"): allowed = request; maximumPositionals = 0
    case (.executor, "status"), (.executor, "cancel"): allowed = ["id"] + request; maximumPositionals = 1
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
    case (.notes, "set-html"): allowed = ["note-id", "html", "file"] + revision + request; maximumPositionals = 0
    case (.notes, "link"): allowed = ["note-id", "source-id", "database-id", "path", "query", "table-id"] + revision + request; maximumPositionals = 0
    case (.notes, "unlink"): allowed = ["note-id", "table-id"] + revision + request; maximumPositionals = 0
    case (.notes, "apply"): allowed = ["note-id", "json", "file"] + revision + request; maximumPositionals = 0
    case (.notes, "versions"): allowed = pagination + ["note-id"]; maximumPositionals = 1
    case (.notes, "version"): allowed = bodyChunk + ["id", "version"]; maximumPositionals = 1
    case (.notes, "restore"): allowed = ["note-id", "version", "revision"] + request; maximumPositionals = 1
    case (.notes, "table"):
      if wantsHelp, positional.isEmpty {
        allowed = []; maximumPositionals = 0
        break
      }
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
    case (.history, "search"): allowed = ["search", "all-workspace", "conversation", "run", "harness", "folder", "kind", "since", "until", "source-id", "native-session-id", "native-record-id"] + pagination; maximumPositionals = 1
    case (.history, "events"): allowed = ["conversation", "run", "harness", "folder", "kind", "search", "since", "until", "source-id", "native-session-id", "native-record-id"] + pagination; maximumPositionals = 0
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
    if group == .notes, ["apply", "set-html"].contains(action),
       options["file"] != nil, options[action == "apply" ? "json" : "html"] != nil {
      throw WorkspaceToolError.invalid("Pass inline content or --file, not both.")
    }
    if group == .executor, action == "execute", options["file"] != nil, options["code"] != nil {
      throw WorkspaceToolError.invalid("Pass --code or --file, not both.")
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

  public static let usage = """
    Use the WovenMatter CLI to access the tools below and get the most out of WovenMatter.

      context     Read the open asset ID captured for the message being processed
      notes       Discover, read and edit notes, spreadsheets and HTML; recover versions
      history     Search conversations and read observed transcripts and traces
      sessions    Create, message and coordinate ordinary Woven Matter sessions
      timers      Wake an agent at a set time or interval to carry out instructions
      usage       Read recorded usage analytics and available account usage limits
      calendar    Read, create and maintain calendar events
      library     Inspect available retained Library items
      executor    Search selected apps and execute scoped JavaScript programs

    Tools must be enabled for this session. Commands run on behalf of this session
    and use the permissions set by the user.
    For commands that make changes, supply a UUID with --request-id.
    If a response is lost, retry the same command in the same session with the same UUID.
    """ + "\n"

  public static func help(for group: WorkspaceToolGroup) -> String {
    let body: String = switch group {
    case .notes: """
      list [--search TEXT] [--folder ID] [--sort newest|oldest] [--after CURSOR --limit N]
      folders [--after CURSOR --limit N]
      create --title TITLE [--kind note|spreadsheet|html] [--folder ID]
      read --note-id ID [--offset N --characters 1...65536]
      append --note-id ID --text TEXT [--revision REVISION]
      apply --note-id ID (--json OPERATIONS_JSON | --file PATH) [--revision REVISION]
      set-html --note-id ID --file PATH --revision REVISION
      table create|set-cell|add-row|remove-row|add-column|remove-column [OPTIONS]
      versions NOTE_ID | version VERSION_ID [--offset N --characters N]
      restore NOTE_ID --version VERSION_ID --revision CURRENT_REVISION
      Note edits also support insert, replace-block, delete-block, format, set-title, link and unlink.
      Use read to obtain the current document, block/table IDs and revision before editing.
      Changes to existing content, titles, formatting or links require --revision.
      Adding table rows or columns with --after also requires --revision.
      Appending rows or columns without --after is revision-optional.
      Mutation retries accept --request-id UUID. A replayed edit/restore acknowledges its
      original revision without old content; read again for the current document.
      """
    case .history: """
      search TEXT [--all-workspace] [--conversation ID]
      conversations [--search TEXT] | conversation ID | message ID
      runs [--conversation ID] | trace RUN_ID | events [--conversation ID] | event ID
      Pagination: --after CURSOR --limit 1...200; body chunks: --offset N --characters 1...65536
      Filters: --harness NAME --kind TYPE --since ISO8601 --until ISO8601
      Native identity: --source-id SOURCE --native-session-id SESSION --native-record-id RECORD
      Search starts in this folder and broadens if nothing matches. Results are references;
      read only relevant records. Old transcripts can be partial. Attached/managed sessions
      remain readable when general history is off; an arbitrary ID does not grant access.
      """
    case .sessions: """
      list [--search TEXT] [--all-workspace] | status SESSION_ID | folders | harnesses
      create --title TITLE --text INSTRUCTION --purpose INTENT [--independent]
        [--harness NAME --model MODEL --thinking LEVEL --folder ID --workspace ID --directory ABSOLUTE_PATH]
      send SESSION_ID --text MESSAGE [--request-id UUID]
      manage SESSION_ID --purpose INTENT [--no-notify] [--request-id UUID]
      release SESSION_ID --epoch EPOCH | notifications SESSION_ID --epoch EPOCH --enabled true|false
      receipts [--before RECEIPT_ID] [--limit N]
      Creation inherits the harness, workspace, directory and folder unless overridden.
      Model and thinking accept explicit arguments. Remaining selections use the user's
      destination workspace/harness defaults, harness defaults, then native defaults.
      Permissions and tools are selected only through user controls; agents cannot
      override them. Choices are frozen for retries. Creation starts
      coordination unless --independent is used. Status and one-off sends do not begin coordination.
      Only one coordinator may manage a destination. Existing unattached sessions require
      user access approval when history is off. A request awaiting approval returns
      state=pending immediately. Wait for the user; retry the same command with the returned
      request ID to inspect its outcome without creating another prompt. Server shutdown
      or restart cancels pending approvals. Messages steer busy sessions or queue when
      steering is unsupported. Use release when the assignment is complete.
      """
    case .timers: """
      list [--session ID]
      create --text INSTRUCTION --at ISO8601 [--every SECONDS] [--session ID]
      update TIMER_ID --text INSTRUCTION --at ISO8601 [--every SECONDS] [--paused]
      pause TIMER_ID | resume TIMER_ID | remove TIMER_ID
      Timers persist and run when the Woven Matter server is running. Missed recurring
      firings coalesce into one. You may set a timer in this session or a session you coordinate.
      Mutation retries accept --request-id UUID and acknowledge the original operation;
      use list for the current state. A retry never reactivates a paused or removed timer.
      """
    case .usage: """
      read [--since ISO8601 --until ISO8601 --offset N --limit 1...200]
      Read recorded usage analytics and available account usage limits.
      Date filters and pagination apply to recorded usage.
      This tool cannot change usage, limits or credentials.
      """
    case .calendar: """
      list [--since ISO8601 --until ISO8601 --after CURSOR --limit 1...200]
      read EVENT_ID | occurrences EVENT_ID --since ISO8601 --until ISO8601
      create --title TITLE --starts-at ISO8601 [--ends-at ISO8601 --description TEXT --all-day]
      update EVENT_ID --revision N [--title TITLE --starts-at ISO8601 --ends-at ISO8601 --description TEXT]
      detach EVENT_ID --occurrence INDEX --revision N [event changes] | copy EVENT_ID --starts-at ISO8601
      remove EVENT_ID --revision N [--occurrence INDEX]
      Repetition: --repeat-unit day|week|month --repeat-interval N --time-zone IANA_ZONE; --no-repeat clears it.
      Tasks: --prompt TEXT [--harness NAME --model MODEL --thinking LEVEL --workspace local|ID --directory ABSOLUTE_PATH --folder all|ID]
        [--session-mode same|new]. Permissions and tools use user-controlled session defaults; edit them in Calendar.
      --regular-event removes the task; --timed clears all-day. Tasks require a time and Session management access.
      Update changes the series. Detach retains the occurrence's settings as an independent one-time event.
      Copy creates an independent event. Each overdue one-time task runs; recurring tasks catch up once.
      Scheduled tasks run when the Woven Matter server is running.
      Read returns attribution, revision, and session links.
      Read-only mode rejects mutations.
      Mutation retries accept --request-id UUID and preserve later edits or removal.
      """
    case .executor: """
      search [--query TEXT --limit 1...100 --request-id UUID]
      skills [--request-id UUID]
      execute --code JAVASCRIPT | --file PATH [--request-id UUID]
      status JOB_ID | cancel JOB_ID
      Execute is available whenever Executor is enabled for this conversation.
      Only selected app profiles are callable, including dynamic tool names.
      Search returns exact paths and signatures. Use those paths in Execute.
      Start returns a job ID immediately. Poll status until completed, cancelled or interrupted.
      Completed means the program finished; inspect result.execution.ok for success.
      Approvals and input appear in the conversation. Resume is managed by Woven Matter.
      Reuse --request-id with identical code after a lost receipt. Never replay an interrupted
      program automatically: earlier external effects may already have completed.
      No imports, fetch, process or filesystem globals exist in Executor's sandbox.
      """
    case .library: "list [--search TEXT --workspace ID[,ID] --harness NAME[,NAME] --kind file|link|photo --sender me|agent --since ISO8601 --until ISO8601 --offset N --limit 1...200] | read ITEM_ID\nFiles, links, and photos from new exchanges. Results include source message IDs, original locations, and retention status. File contents are kept on disk; remote original paths belong to their source workspace."
    }
    return "Usage: wovenmatter \(group.rawValue) COMMAND [OPTIONS]\n\n" + body + "\n"
  }

  public static let contextHelp = """
    Usage: wovenmatter context

    Read the ID of the note, spreadsheet or HTML asset that was open when the user
    sent the message being processed. Each user message has its own captured ID.
    Switching assets afterward does not change that message's capture.
    No asset is returned if none was open, or if another session or a schedule sent the message.
    Only the ID is returned. Use wovenmatter notes read --note-id ID to read its contents.
    Requires Notes access for this session.
    """ + "\n"

  public static func help(for command: WovenMatterToolCommand) -> String {
    if command.action == "context" { return contextHelp }
    guard let group = command.group, command.action != "help" else {
      return command.group.map(help) ?? usage
    }
    let detail: String? = switch (group, command.action, command.subaction) {
    case (.notes, "apply", _): "Usage: wovenmatter notes apply --note-id ID (--json OPERATIONS_JSON | --file PATH) [--revision REVISION]\n\nOperations are a JSON array. Each object needs a type such as appendText, setTitle, setHTML, or createTable. Destructive operations require --revision. At most 128 operations and 1 MiB of resulting document data are accepted."
    case (.notes, "table", "create"): "Usage: wovenmatter notes table create --note-id ID [--after BLOCK_ID --rows 1...1000 --columns 1...128 --header --revision REVISION]\n\nCreate a table, optionally after an existing block. Defaults to 3 rows and 3 columns.\nUse --header to make the first row a header. A document can contain at most 100,000 table cells."
    case (.notes, "table", "set-cell"): "Usage: wovenmatter notes table set-cell --note-id ID --table-id ID --row N --column N --text TEXT --revision REVISION\n\nReplace a cell's contents with text. Row and column numbers start at 0.\nUse notes read to obtain the current table ID and revision."
    case (.notes, "table", "add-row"): "Usage: wovenmatter notes table add-row --note-id ID --table-id ID [--after N] [--revision REVISION]\n\nAppend a row, or insert one after row N. Row numbers start at 0; --after -1 inserts first.\nUsing --after requires --revision. Appending without --after does not."
    case (.notes, "table", "remove-row"): "Usage: wovenmatter notes table remove-row --note-id ID --table-id ID --row N --revision REVISION\n\nRemove row N. Row numbers start at 0. A table must retain at least one row."
    case (.notes, "table", "add-column"): "Usage: wovenmatter notes table add-column --note-id ID --table-id ID [--after N] [--revision REVISION]\n\nAppend a column, or insert one after column N. Column numbers start at 0; --after -1 inserts first.\nUsing --after requires --revision. Appending without --after does not."
    case (.notes, "table", "remove-column"): "Usage: wovenmatter notes table remove-column --note-id ID --table-id ID --column N --revision REVISION\n\nRemove column N. Column numbers start at 0. A table must retain at least one column."
    case (.notes, "link", _): "Usage: wovenmatter notes link --note-id ID --source-id ID --database-id ID --path RELATIVE_PATH --revision REVISION [--query READ_ONLY_SQL --table-id ID]\n\nSet the note's database link, or a table's link when --table-id is supplied.\nUse notes read to obtain the current revision."
    case (.notes, "unlink", _): "Usage: wovenmatter notes unlink --note-id ID [--table-id ID] --revision REVISION\n\nRemove the note's database link, or a table's link when --table-id is supplied.\nUse notes read to obtain the current revision."
    case (.sessions, "release", _): "Usage: wovenmatter sessions release SESSION_ID --epoch EPOCH [--request-id UUID]\n\nEnd your coordination of this session. This does not stop or delete the session.\nRead wovenmatter sessions status SESSION_ID and use its coordinationEpoch for --epoch.\nA retry can only release that assignment."
    case (.sessions, "notifications", _): "Usage: wovenmatter sessions notifications SESSION_ID --epoch EPOCH --enabled true|false [--request-id UUID]\n\nEnable or disable automatic updates from a session you coordinate.\nRead wovenmatter sessions status SESSION_ID and use its coordinationEpoch for --epoch."
    default: nil
    }
    return detail.map { $0 + "\n" } ?? help(for: group)
  }
}
