import Foundation
import WovenMatterCore

/// Wire requests carry no caller/session authority. The owning app binds that to
/// the private endpoint when it is created and checks current settings per call.
public struct WovenMatterToolRequest: Codable, Sendable {
  public var schemaVersion: Int
  public var requestID: String
  public var arguments: [String]
  public var noteEdit: NoteEditingRequest?
  public init(arguments: [String], requestID: String = UUID().uuidString.lowercased(), noteEdit: NoteEditingRequest? = nil) {
    self.schemaVersion = 1
    self.requestID = requestID
    self.arguments = arguments
    self.noteEdit = noteEdit
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
  public let silent: Bool
  public let requestID: String?
  public init(success: Bool = true, result: GatewayJSONValue? = nil, error: String? = nil, silent: Bool = false, requestID: String? = nil) {
    self.success = success; self.result = result; self.error = error; self.silent = silent; self.requestID = requestID
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

  public init(_ arguments: [String]) throws {
    var args = arguments
    if args.isEmpty || ["help", "--help", "-h"].contains(args[0]) {
      self.group = nil; self.action = "help"; self.positional = []; self.options = [:]; self.optionIndices = [:]; self.operationArguments = arguments; self.wantsHelp = true
      return
    }
    let domain = args.removeFirst()
    guard let group = WorkspaceToolGroup(rawValue: domain) else {
      throw WorkspaceToolError.invalid("Unknown tool group '\(domain)'. Run wovenmatter help.")
    }
    self.group = group
    if args.isEmpty || [["help"], ["--help"], ["-h"]].contains(args) {
      self.action = "help"; self.wantsHelp = true
      self.positional = []; self.options = [:]; self.optionIndices = [:]; self.operationArguments = arguments; return
    }
    self.action = args.removeFirst()
    let allowedActions: [WorkspaceToolGroup: Set<String>] = [
      .notes: ["list", "create", "read", "append", "insert", "replace-block", "delete-block", "format", "set-title", "table", "set-html", "link", "unlink", "apply", "versions", "version", "restore"],
      .history: ["search", "conversations", "conversation", "message", "runs", "trace", "events", "event"],
      .sessions: ["list", "status", "create", "send", "manage", "release", "notifications", "receipts", "folders", "harnesses"],
      .timers: ["list", "create", "update", "pause", "resume", "remove"],
      .usage: ["read"], .calendar: ["list", "create", "update", "remove"], .library: ["list", "read"]
    ]
    guard allowedActions[group]?.contains(action) == true else { throw WorkspaceToolError.invalid("Unknown \(domain) command '\(action)'.") }
    let booleanFlags: Set<String> = ["all-workspace", "independent", "no-notify", "paused", "all-day", "json", "header"]
    let valueFlags: Set<String> = ["id", "session", "conversation", "note-id", "folder", "workspace", "directory", "harness", "model", "thinking", "title", "text", "purpose", "request-id", "search", "run", "kind", "sender", "since", "until", "after", "before", "limit", "offset", "characters", "at", "every", "starts-at", "ends-at", "description", "enabled", "revision", "version", "file", "html", "style", "block-id", "table-id", "row", "column", "rows", "columns", "source-id", "database-id", "path", "query"]
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
    self.positional = positional
    self.options = options
    self.optionIndices = indices
    self.wantsHelp = wantsHelp
    self.operationArguments = operationArguments
  }

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
    Usage: wovenmatter GROUP COMMAND [OPTIONS]

      notes       Discover, read and edit notes, spreadsheets and HTML; recover versions
      history     Search conversations and read observed transcripts and traces
      sessions    Create, message and coordinate ordinary Woven Matter sessions
      timers      Save one-time or recurring instructions for a session
      usage       Read recorded usage
      calendar    Read and maintain calendar events
      library     Inspect available retained Library items

    Run wovenmatter GROUP help for details. Tools must be enabled for this session.
    Commands are scoped to the session that supplied WOVENMATTER_SOCKET.
    Choose --request-id UUID before a mutation; reuse it with the same command after a lost response.
    """ + "\n"

  public static func help(for group: WorkspaceToolGroup) -> String {
    let body: String = switch group {
    case .notes: """
      list [--search TEXT] [--folder ID]
      create --title TITLE [--kind note|spreadsheet|html] [--folder ID]
      read --note-id ID
      append --note-id ID --text TEXT [--revision REVISION]
      apply --note-id ID --json OPERATIONS_JSON [--revision REVISION]
      set-html --note-id ID --file PATH [--revision REVISION]
      table create|set-cell|add-row|remove-row|add-column|remove-column [OPTIONS]
      versions NOTE_ID | version VERSION_ID [--offset N --characters N]
      restore NOTE_ID --version VERSION_ID --revision CURRENT_REVISION
      Note edits also support insert, replace-block, delete-block, format, set-title, link and unlink.
      Use read to obtain the current document, block/table IDs and revision before editing.
      Mutation retries accept --request-id UUID. A replayed edit/restore acknowledges its
      original revision without old content; read again for the current document.
      """
    case .history: """
      search TEXT [--all-workspace] [--conversation ID]
      conversations [--search TEXT] | conversation ID | message ID
      runs [--conversation ID] | trace RUN_ID | events [--conversation ID] | event ID
      Pagination: --after CURSOR --limit 1...200; body chunks: --offset N --characters 1...65536
      Filters: --harness NAME --kind TYPE --since ISO8601 --until ISO8601
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
      release SESSION_ID | notifications SESSION_ID --enabled true|false | receipts [--before RECEIPT_ID] [--limit N]
      Creation inherits the harness, workspace, directory and folder unless overridden.
      Model and thinking accept explicit arguments. Remaining selections use the user's
      destination workspace/harness defaults, harness defaults, then native defaults.
      Permissions and tools are selected only through user controls; agents cannot
      override them. Choices are frozen for retries. Creation starts
      coordination unless --independent is used. Status and one-off sends do not begin coordination.
      Only one coordinator may manage a destination. Existing unattached sessions require
      user access approval when history is off. A request awaiting approval returns
      state=pending immediately. Wait for the user; retry the same command with the returned
      request ID to inspect its outcome without creating another prompt. App shutdown
      cancels pending approvals. Messages steer busy sessions or queue when
      steering is unsupported. Use release when the assignment is complete.
      """
    case .timers: """
      list [--session ID]
      create --text INSTRUCTION --at ISO8601 [--every SECONDS] [--session ID]
      update TIMER_ID --text INSTRUCTION --at ISO8601 [--every SECONDS] [--paused]
      pause TIMER_ID | resume TIMER_ID | remove TIMER_ID
      Timers persist but execute only while Woven Matter runs. Missed recurring firings
      coalesce into one. You may set a timer in this session or a session you coordinate.
      Mutation retries accept --request-id UUID and acknowledge the original operation;
      use list for the current state. A retry never reactivates a paused or removed timer.
      """
    case .usage: "read [--since ISO8601 --until ISO8601 --offset N --limit 1...200]\nRead recorded usage. This tool cannot change usage or credentials."
    case .calendar: """
      list [--since ISO8601 --until ISO8601]
      create --title TITLE --starts-at ISO8601 [--ends-at ISO8601 --description TEXT --all-day]
      update EVENT_ID --title TITLE --starts-at ISO8601 [--ends-at ISO8601 --description TEXT --all-day]
      remove EVENT_ID
      Calendar access is set in General settings; read-only mode rejects mutations.
      Mutation retries accept --request-id UUID and preserve later edits or removal.
      """
    case .library: "list [--search TEXT --workspace ID[,ID] --harness NAME[,NAME] --kind file|link|photo --sender me|agent --since ISO8601 --until ISO8601 --offset N --limit 1...200] | read ITEM_ID\nFiles, links, and photos from new exchanges. Results include source message IDs, original locations, and retention status. File contents are kept on disk; remote original paths belong to their source workspace."
    }
    return "Usage: wovenmatter \(group.rawValue) COMMAND [OPTIONS]\n\n" + body + "\n"
  }
}
