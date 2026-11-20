import Foundation
import Synchronization
import WovenProtocol

// The Agent Client Protocol core: JSON-RPC over a runtime's stdio, shared by
// Codex, Claude Code, Grok Build and Pi Durable. Each differs only in its
// `ACPProfile`.

/// An error the agent answered a request with.
struct ACPError: Error, CustomStringConvertible {
  let code: Int
  let message: String
  var description: String { message }

  /// ACP's "resource not found".
  static let notFound = -32002
}

/// What makes one ACP runtime different from another.
struct ACPProfile: Sendable {
  var kind: RuntimeKind
  var executable: String
  var arguments: [String]
  var environment: [String: String]
  var protocolVersion: Int = 1
  /// The client capabilities sent with `initialize`. Forms (`elicitation/create`)
  /// reach the chat as prompts.
  var clientCapabilities: JSONValue = .object(["elicitation": .object(["form": .object([:])])])
  /// Whether an error from `session/load` means the native session is gone.
  var isMissingSession: @Sendable (ACPError) -> Bool = { $0.code == ACPError.notFound }
  /// Permission modes fixed when the process starts, for runtimes that take
  /// them as a launch flag rather than over ACP.
  var launchPermissions: [SessionOption] = []
  /// Answers a request the agent makes that ACP does not define; nil to
  /// refuse it.
  var handleRequest: (@Sendable (String, JSONValue) async throws -> JSONValue)?
  /// Receives a notification the agent sends that ACP does not define.
  var handleNotification: (@Sendable (String, JSONValue) async -> Void)?
  /// How a message reaches a turn while it runs.
  var steering: ACPSteering = .sessionSteering
  /// Where the process's standard error goes.
  var logFile: URL?
  /// The Woven MCP and instructions for the native session.
  var tools: ToolAccess?
}

/// The ACP extension a runtime takes mid-turn input through.
enum ACPSteering: Sendable {
  /// `_session/steering`, the ACP steering extension (Codex, Claude Code, Pi Durable).
  case sessionSteering
  /// Grok Build's `_x.ai/interject`, which takes text only.
  case interject
}

/// A runtime spoken to over ACP, one process per session.
struct ACPRuntime: Runtime {
  let kind: RuntimeKind
  let profile: @Sendable (RuntimeStart) async throws -> ACPProfile
  let statusCheck: @Sendable () async -> RuntimeStatus
  let installer: @Sendable () async throws -> Void

  func open(_ start: RuntimeStart) async throws -> any RuntimeSession {
    try await ACPSession.open(profile: try await profile(start), start: start)
  }

  func status() async -> RuntimeStatus { await statusCheck() }
  func install() async throws { try await installer() }
}

/// JSON-RPC over one child process: requests with replies, and everything
/// else the agent sends handed to `receive`. Messages are handled one at a
/// time in the order the agent wrote them, replies included: a reply is only
/// returned once every message before it has been received, so a turn never
/// ends before its last update, and a resumed session's replay is over
/// before `session/load` returns.
actor ACPConnection {
  enum Incoming: Sendable {
    case notification(method: String, params: JSONValue)
    case request(id: JSONValue, method: String, params: JSONValue)
  }

  private let child: ChildProcess
  private var nextID = 0
  private var pending: [Int: CheckedContinuation<JSONValue, any Error>] = [:]
  private var closed = false

  init(child: ChildProcess) {
    self.child = child
  }

  func start(receive: @escaping @Sendable (Incoming) async -> Void, ended: @escaping @Sendable () async -> Void) {
    let lines = child.lines
    Task {
      for await line in lines { await self.handle(line, receive: receive) }
      self.ended()
      await ended()
    }
  }

  func request(_ method: String, _ params: JSONValue) async throws -> JSONValue {
    if closed { throw RuntimeError.failed("The runtime's process has ended.") }
    nextID += 1
    let id = nextID
    let message = JSONValue.object(["jsonrpc": .string("2.0"), "id": .integer(Int64(id)), "method": .string(method), "params": params])
    return try await withCheckedThrowingContinuation { continuation in
      pending[id] = continuation
      child.send(Self.text(message))
    }
  }

  func notify(_ method: String, _ params: JSONValue) {
    child.send(Self.text(.object(["jsonrpc": .string("2.0"), "method": .string(method), "params": params])))
  }

  func respond(_ id: JSONValue, result: JSONValue) {
    child.send(Self.text(.object(["jsonrpc": .string("2.0"), "id": id, "result": result])))
  }

  func respond(_ id: JSONValue, error message: String, code: Int = -32603) {
    child.send(Self.text(.object(["jsonrpc": .string("2.0"), "id": id,
                                  "error": .object(["code": .integer(Int64(code)), "message": .string(message)])])))
  }

  var isClosed: Bool { closed }

  func stop() async {
    await child.stop()
  }

  private func handle(_ line: String, receive: @Sendable (Incoming) async -> Void) async {
    guard let message = try? Wire.decoder.decode(JSONValue.self, from: Data(line.utf8)), case .object(let body) = message else { return }
    let method = body["method"]?.string
    let params = body["params"] ?? .object([:])
    if let method {
      if let id = body["id"], id != .null {
        await receive(.request(id: id, method: method, params: params))
      } else {
        await receive(.notification(method: method, params: params))
      }
      return
    }
    guard let id = body["id"]?.int, let continuation = pending.removeValue(forKey: id) else { return }
    if case .object(let error)? = body["error"] {
      var text = error["message"]?.string ?? "The runtime failed."
      if let detail = error["data"]?["message"]?.string ?? error["data"]?["details"]?.string, !text.contains(detail) {
        text += ": " + detail
      }
      continuation.resume(throwing: ACPError(code: error["code"]?.int ?? -32603, message: text))
    } else {
      continuation.resume(returning: body["result"] ?? .null)
    }
  }

  private func ended() {
    closed = true
    for continuation in pending.values { continuation.resume(throwing: RuntimeError.failed("The runtime's process ended.")) }
    pending.removeAll()
  }

  private static func text(_ value: JSONValue) -> String {
    (try? String(decoding: Wire.encoder.encode(value), as: UTF8.self)) ?? "{}"
  }
}

/// One ACP native session and its process, kept alive between turns.
final class ACPSession: RuntimeSession, @unchecked Sendable {
  let nativeHandle: String
  let events: AsyncStream<RuntimeEvent>
  private let emit: AsyncStream<RuntimeEvent>.Continuation
  private let connection: ACPConnection
  private let profile: ACPProfile
  private let state: ACPState

  var configuration: SessionConfiguration {
    get async { await state.configuration }
  }

  private init(nativeHandle: String, connection: ACPConnection, profile: ACPProfile, state: ACPState,
               events: AsyncStream<RuntimeEvent>, emit: AsyncStream<RuntimeEvent>.Continuation) {
    self.nativeHandle = nativeHandle
    self.connection = connection
    self.profile = profile
    self.state = state
    self.events = events
    self.emit = emit
  }

  static func open(profile: ACPProfile, start: RuntimeStart) async throws -> ACPSession {
    let child = try ChildProcess(executable: profile.executable, arguments: profile.arguments, directory: start.directory,
                                 environment: profile.environment, logFile: profile.logFile)
    let connection = ACPConnection(child: child)
    let (events, emit) = AsyncStream<RuntimeEvent>.makeStream()
    let state = ACPState(connection: connection, profile: profile, emit: emit, directory: start.directory)
    // Everything the agent says goes through `state`, in order, from the start.
    await connection.start(receive: { await state.receive($0) }, ended: { await state.processEnded() })
    do {
      let initialized = try await connection.request("initialize", .object([
        "protocolVersion": .integer(Int64(profile.protocolVersion)),
        "clientCapabilities": profile.clientCapabilities,
        "clientInfo": .object(["name": .string("Woven Matter"), "version": .string("1")]),
      ]))
      // The Woven MCP as a stdio server, and Woven's instructions as ACP's
      // system prompt addition, or Grok's rules where that is not offered.
      var sessionParams: [String: JSONValue] = [
        "cwd": .string(start.directory), "mcpServers": .array(profile.tools.map { [$0.acpServer] } ?? []),
      ]
      if let instructions = profile.tools?.instructions {
        if initialized["agentCapabilities"]?["sessionCapabilities"]?["systemPrompt"] != nil {
          sessionParams["systemPrompt"] = .object(["mode": .string("append"),
                                                   "content": .array([.object(["type": .string("text"), "text": .string(instructions)])])])
        } else if profile.kind == .grokBuild {
          sessionParams["_meta"] = .object(["rules": .string(instructions)])
        }
      }
      let handle: String
      if let existing = start.nativeHandle {
        guard initialized["agentCapabilities"]?["loadSession"]?.bool == true else {
          throw RuntimeError.failed("\(profile.kind.rawValue) cannot resume a session.")
        }
        await state.setReplaying(true)
        do {
          var params = sessionParams
          params["sessionId"] = .string(existing)
          let loaded = try await connection.request("session/load", .object(params))
          await state.setReplaying(false)
          await state.capture(loaded)
        } catch let error as ACPError where profile.isMissingSession(error) {
          throw RuntimeError.nativeSessionGone
        }
        handle = existing
      } else {
        let created = try await connection.request("session/new", .object(sessionParams))
        guard let id = created["sessionId"]?.string, !id.isEmpty else {
          throw RuntimeError.failed("\(profile.kind.rawValue) did not start a session.")
        }
        handle = id
        await state.capture(created)
      }
      await state.setSession(handle)
      let session = ACPSession(nativeHandle: handle, connection: connection, profile: profile, state: state,
                               events: events, emit: emit)
      if !start.choices.isEmpty { _ = try? await session.configure(start.choices) }
      return session
    } catch {
      await connection.stop()
      throw error
    }
  }

  func send(_ turn: Turn) async throws {
    try await state.prompt(turn)
  }

  func steer(_ turn: Turn) async throws -> Bool {
    try await state.steer(turn)
  }

  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration {
    try await state.configure(choices)
  }

  func answer(promptID: String, with answer: PromptAnswer) async throws {
    try await state.answer(promptID: promptID, with: answer)
  }

  func interrupt() async throws {
    await state.cancel()
  }

  func stop() async {
    await state.cancel()
    await connection.stop()
  }
}

/// The state of one ACP session: its configuration, the turn in progress
/// and what the agent is waiting on. Every message from the agent is handled
/// here in the order it arrived.
private actor ACPState {
  private let connection: ACPConnection
  private let profile: ACPProfile
  private let emit: AsyncStream<RuntimeEvent>.Continuation
  private let directory: String
  private var sessionID: String?
  private var replaying = false
  private(set) var configuration = SessionConfiguration()

  /// How each setting is changed: an ACP config option, or the older method.
  private var modelOption: String?
  private var thinkingOption: String?
  private var permissionOption: String?
  private var usesSetModel = false
  private var usesSetMode = false

  private var turnRunning = false
  private var turnNumber = 0
  /// The session's cost so far in US dollars, as `usage_update` reports it,
  /// and what it was when the running turn began.
  private var sessionCost: Double?
  private var costBeforeTurn: Double?
  private var tools: [String: ToolCall] = [:]
  private var thinkingID: String?
  private var thinkingCount = 0
  private var planID: String?
  /// What the agent waits on, by prompt id: a permission request's options,
  /// or a form's fields.
  private enum Waiting {
    case permission(id: JSONValue, options: [PromptOption])
    case form(id: JSONValue, fields: [PromptField])

    var requestID: JSONValue {
      switch self {
      case .permission(let id, _), .form(let id, _): id
      }
    }
  }

  private var waiting: [String: Waiting] = [:]

  init(connection: ACPConnection, profile: ACPProfile, emit: AsyncStream<RuntimeEvent>.Continuation, directory: String) {
    self.connection = connection
    self.profile = profile
    self.emit = emit
    self.directory = directory
    if !profile.launchPermissions.isEmpty {
      configuration.permissionModes = profile.launchPermissions
    }
  }

  func setSession(_ id: String) { sessionID = id }
  func setReplaying(_ value: Bool) { replaying = value }

  // MARK: Turns

  func prompt(_ turn: Turn) throws {
    guard let sessionID else { throw RuntimeError.failed("The session is not open.") }
    guard !turnRunning else { throw RuntimeError.failed("A turn is already running.") }
    turnRunning = true
    turnNumber += 1
    costBeforeTurn = sessionCost
    let blocks = try Self.blocks(turn)
    let connection = connection
    Task {
      let result: Result<JSONValue, any Error>
      do {
        result = .success(try await connection.request("session/prompt", .object([
          "sessionId": .string(sessionID), "prompt": .array(blocks),
        ])))
      } catch {
        result = .failure(error)
      }
      self.promptEnded(result)
    }
  }

  /// Hands the running turn a message. The turn's own `session/prompt` goes
  /// on and ends once, with the message's work in it.
  func steer(_ turn: Turn) async throws -> Bool {
    guard let sessionID, turnRunning else { return false }
    switch profile.steering {
    case .interject:
      _ = try await connection.request("_x.ai/interject", .object([
        "sessionId": .string(sessionID), "text": .string(Self.textWithFiles(turn)),
      ]))
      return true
    case .sessionSteering:
      // `promptRequired`: when the turn has just ended, the agent takes
      // nothing, rather than starting a turn of its own.
      let reply = try await connection.request("_session/steering", .object([
        "sessionId": .string(sessionID), "prompt": .array(try Self.blocks(turn)),
        "_meta": .object(["steering": .object(["idleBehavior": .string("promptRequired")])]),
      ]))
      switch reply["outcome"]?.string {
      case "injected": return true
      case "promptRequired": return false
      default: throw RuntimeError.failed("\(profile.kind.rawValue) did not take the message.")
      }
    }
  }

  private func promptEnded(_ result: Result<JSONValue, any Error>) {
    guard turnRunning else { return }
    turnRunning = false
    endActivity(planToo: true)
    for (callID, var call) in tools {
      if call.output == nil { call.failed = true }
      emit.yield(.tool(callID: callID, call: call, finished: true))
    }
    tools.removeAll()
    withdrawPermissions()
    emit.yield(.messageFinished)
    switch result {
    case .success(let value):
      let reason = value["stopReason"]?.string ?? "end_turn"
      let failure: String? = switch reason {
      case "max_tokens": "The reply reached its length limit."
      case "max_turn_requests": "The turn reached its limit of model requests."
      case "refusal": "The model declined to answer."
      default: nil
      }
      var usage = Self.usage(value, model: configuration.model)
      if usage?.cost == nil, let sessionCost { usage?.cost = max(0, sessionCost - (costBeforeTurn ?? 0)) }
      emit.yield(.turnFinished(failure: failure, usage: usage))
    case .failure(let error as ACPError) where profile.isMissingSession(error):
      emit.yield(.nativeSessionGone)
    case .failure(let error):
      emit.yield(.turnFinished(failure: "\(error)", usage: nil))
    }
  }

  func cancel() async {
    withdrawPermissions()
    guard let sessionID, turnRunning else { return }
    await connection.notify("session/cancel", .object(["sessionId": .string(sessionID)]))
  }

  func answer(promptID: String, with answer: PromptAnswer) async throws {
    guard let request = waiting[promptID] else { throw RuntimeError.failed("Nothing is waiting for that answer.") }
    let result: JSONValue
    switch (request, answer) {
    case (.permission(_, let options), .option(let optionID)):
      guard options.contains(where: { $0.id == optionID }) else { throw RuntimeError.failed("That is not one of the answers offered.") }
      result = .object(["outcome": .object(["outcome": .string("selected"), "optionId": .string(optionID)])])
    case (.permission, .declined):
      result = .object(["outcome": .object(["outcome": .string("cancelled")])])
    case (.form(_, let fields), .values(let values)):
      try PromptForms.check(values, against: fields)
      result = .object(["action": .string("accept"), "content": .object(values)])
    case (.form(_, let fields), .option(let value)) where fields.count == 1:
      try PromptForms.check([fields[0].id: .string(value)], against: fields)
      result = .object(["action": .string("accept"), "content": .object([fields[0].id: .string(value)])])
    case (.form(_, let fields), .text(let text)) where fields.count == 1 && fields[0].kind == .text:
      result = .object(["action": .string("accept"), "content": .object([fields[0].id: .string(text)])])
    case (.form, .declined):
      result = .object(["action": .string("decline")])
    default:
      throw RuntimeError.failed("That answer does not fit what was asked.")
    }
    waiting[promptID] = nil
    await connection.respond(request.requestID, result: result)
    emit.yield(.promptResolved(id: promptID))
  }

  private func withdrawPermissions() {
    let open = waiting
    waiting.removeAll()
    for (promptID, request) in open {
      let result: JSONValue = switch request {
      case .permission: .object(["outcome": .object(["outcome": .string("cancelled")])])
      case .form: .object(["action": .string("cancel")])
      }
      Task { await connection.respond(request.requestID, result: result) }
      emit.yield(.promptResolved(id: promptID))
    }
  }

  func processEnded() {
    if turnRunning { promptEnded(.failure(RuntimeError.failed("The runtime's process ended during the turn."))) }
    emit.yield(.exited)
    emit.finish()
  }

  // MARK: Configuration

  func configure(_ choices: SessionChoices) async throws -> SessionConfiguration {
    guard let sessionID else { throw RuntimeError.failed("The session is not open.") }
    if let model = choices.model, model != configuration.model {
      if let id = modelOption {
        capture(try await connection.request("session/set_config_option", .object([
          "sessionId": .string(sessionID), "configId": .string(id), "value": .string(model)])))
      } else if usesSetModel {
        capture(try await connection.request("session/set_model", .object(["sessionId": .string(sessionID), "modelId": .string(model)])))
        configuration.model = model
      } else {
        throw RuntimeError.failed("\(profile.kind.rawValue) does not let the model be chosen.")
      }
    }
    if let thinking = choices.thinking, thinking != configuration.thinking {
      guard let id = thinkingOption else { throw RuntimeError.failed("This model has no thinking levels to choose from.") }
      capture(try await connection.request("session/set_config_option", .object([
        "sessionId": .string(sessionID), "configId": .string(id), "value": .string(thinking)])))
    }
    if let permission = choices.permission, permission != configuration.permission {
      if let id = permissionOption {
        capture(try await connection.request("session/set_config_option", .object([
          "sessionId": .string(sessionID), "configId": .string(id), "value": .string(permission)])))
      } else if usesSetMode {
        capture(try await connection.request("session/set_mode", .object(["sessionId": .string(sessionID), "modeId": .string(permission)])))
        configuration.permission = permission
      } else if profile.launchPermissions.contains(where: { $0.id == permission }) {
        throw RuntimeError.failed("\(profile.kind.rawValue) takes its permission mode when it starts; start a new session for this one.")
      } else {
        throw RuntimeError.failed("\(profile.kind.rawValue) has no permission modes to choose from.")
      }
    }
    return configuration
  }

  /// Takes in whatever configuration a response or update carries.
  func capture(_ value: JSONValue) {
    let before = configuration
    if let options = value["configOptions"]?.array {
      modelOption = nil
      thinkingOption = nil
      permissionOption = nil
      for option in options {
        guard let id = option["id"]?.string else { continue }
        let current = option["currentValue"]?.string
        let values = Self.choices(option["options"])
        switch option["category"]?.string ?? id {
        case "model":
          modelOption = id
          configuration.model = current
          configuration.models = values
        case "thought_level", "reasoning", "effort", "thinking":
          thinkingOption = id
          configuration.thinking = current
          configuration.thinkingLevels = values
        case "mode", "permission":
          permissionOption = id
          configuration.permission = current
          configuration.permissionModes = values
        default: continue
        }
      }
      if thinkingOption == nil {
        configuration.thinking = nil
        configuration.thinkingLevels = []
      }
    }
    if modelOption == nil, let models = value["models"], case .array(let available)? = models["availableModels"] {
      usesSetModel = true
      configuration.model = models["currentModelId"]?.string
      configuration.models = available.compactMap { model in
        model["modelId"]?.string.map { SessionOption(id: $0, name: model["name"]?.string ?? $0, detail: model["description"]?.string) }
      }
    }
    if permissionOption == nil, let modes = value["modes"], case .array(let available)? = modes["availableModes"] {
      usesSetMode = true
      configuration.permission = modes["currentModeId"]?.string
      configuration.permissionModes = Self.choices(.array(available), key: "id")
    }
    if permissionOption == nil, let current = value["currentModeId"]?.string { configuration.permission = current }
    if let commands = value["availableCommands"]?.array {
      configuration.commands = commands.compactMap { command in
        command["name"]?.string.map { SessionCommand(name: $0, detail: command["description"]?.string, hint: command["input"]?["hint"]?.string) }
      }
    }
    if configuration != before && sessionID != nil { emit.yield(.configuration(configuration)) }
  }

  // MARK: Messages from the agent

  func receive(_ message: ACPConnection.Incoming) async {
    switch message {
    case .notification("session/update", let params):
      update(params["update"] ?? .null)
    case .notification("$/cancel_request", let params):
      // The agent withdrew a request it made; forget the prompt it became.
      guard let requestID = params["requestId"] ?? params["id"],
            let (promptID, request) = waiting.first(where: { $0.value.requestID == requestID }) else { return }
      waiting[promptID] = nil
      let result: JSONValue = if case .form = request { .object(["action": .string("cancel")]) }
        else { .object(["outcome": .object(["outcome": .string("cancelled")])]) }
      await connection.respond(requestID, result: result)
      emit.yield(.promptResolved(id: promptID))
    case .notification(let method, let params):
      await profile.handleNotification?(method, params)
    case .request(let id, "session/request_permission", let params):
      permissionRequest(id: id, params)
    case .request(let id, "elicitation/create", let params):
      await elicitation(id: id, params)
    case .request(let id, let method, let params):
      if let handle = profile.handleRequest {
        do {
          await connection.respond(id, result: try await handle(method, params))
        } catch {
          await connection.respond(id, error: "\(error)")
        }
      } else {
        await connection.respond(id, error: "Woven Matter does not offer \(method).", code: -32601)
      }
    }
  }

  private func update(_ update: JSONValue) {
    guard let kind = update["sessionUpdate"]?.string else { return }
    switch kind {
    case "config_option_update", "current_mode_update", "available_commands_update":
      capture(update)
      return
    case "usage_update":
      if let cost = update["cost"], cost["currency"]?.string?.uppercased() ?? "USD" == "USD", let amount = cost["amount"]?.double {
        sessionCost = amount
      }
      return
    default:
      break
    }
    // A resumed session replays its history; the library already has it.
    guard !replaying else { return }
    switch kind {
    case "agent_message_chunk":
      guard let text = update["content"]?["text"]?.string else { return }
      endActivity(planToo: false)
      emit.yield(.text(text))
    case "agent_thought_chunk":
      guard let text = update["content"]?["text"]?.string else { return }
      let id: String
      if let thinkingID {
        id = thinkingID
      } else {
        emit.yield(.messageFinished)
        thinkingCount += 1
        id = "thinking-\(turnNumber)-\(thinkingCount)"
        thinkingID = id
        let call = ToolCall(name: "thinking", input: "", output: "", title: "Thinking", kind: .thinking)
        tools[id] = call
        emit.yield(.tool(callID: id, call: call, finished: false))
      }
      // Only what is new travels; the server keeps the whole.
      emit.yield(.toolOutput(callID: id, delta: text))
    case "tool_call", "tool_call_update":
      guard let callID = update["toolCallId"]?.string else { return }
      endActivity(planToo: false)
      let before = tools[callID]
      var call = before ?? ToolCall(name: update["kind"]?.string ?? "tool", input: "")
      let streamed = Self.merge(update, into: &call)
      let status = update["status"]?.string
      let finished = status == "completed" || status == "failed"
      if status == "failed" { call.failed = true }
      // Streamed output travels as deltas, so a report that only adds output
      // does not resend the call.
      if call != before && (!finished || before == nil && streamed != nil) {
        emit.yield(.tool(callID: callID, call: call, finished: false))
      }
      if let streamed { emit.yield(.toolOutput(callID: callID, delta: streamed)) }
      if finished {
        if call.output == nil { call.output = "" }
        tools[callID] = nil
        emit.yield(.tool(callID: callID, call: call, finished: true))
      } else {
        tools[callID] = call
      }
    case "plan":
      let entries = (update["entries"]?.array ?? []).compactMap { entry -> PlanEntry? in
        guard let text = entry["content"]?.string else { return nil }
        let status: PlanEntry.Status = switch entry["status"]?.string {
        case "completed": .completed
        case "in_progress": .inProgress
        default: .pending
        }
        return PlanEntry(text: text, status: status)
      }
      let id = planID ?? "plan-\(turnNumber)"
      planID = id
      let input = (try? String(decoding: Wire.encoder.encode(update["entries"] ?? .array([])), as: UTF8.self)) ?? "[]"
      let call = ToolCall(name: "plan", input: input, output: "", title: "Plan", kind: .plan, plan: entries)
      tools[id] = call
      emit.yield(.tool(callID: id, call: call, finished: false))
    default:
      return
    }
  }

  /// Ends the reasoning in progress, and the plan when the turn ends.
  private func endActivity(planToo: Bool) {
    if let id = thinkingID, let call = tools.removeValue(forKey: id) {
      emit.yield(.tool(callID: id, call: call, finished: true))
    }
    thinkingID = nil
    if planToo, let id = planID, let call = tools.removeValue(forKey: id) {
      emit.yield(.tool(callID: id, call: call, finished: true))
      planID = nil
    }
  }

  private func permissionRequest(id: JSONValue, _ params: JSONValue) {
    let options = (params["options"]?.array ?? []).compactMap { option -> PromptOption? in
      guard let optionID = option["optionId"]?.string else { return nil }
      return PromptOption(id: optionID, name: option["name"]?.string ?? optionID,
                          allowsOnce: option["kind"]?.string == "allow_once")
    }
    guard !options.isEmpty else {
      Task { await connection.respond(id, result: .object(["outcome": .object(["outcome": .string("cancelled")])])) }
      return
    }
    let promptID = UUID().uuidString.lowercased()
    waiting[promptID] = .permission(id: id, options: options)
    let title = params["toolCall"]?["title"]?.string ?? "The agent asks for permission."
    emit.yield(.prompt(Prompt(id: promptID, kind: .approval, text: title, options: options)))
  }

  /// A form the agent asks the person to fill in (MCP-style elicitation).
  /// One the chat cannot show is declined.
  private func elicitation(id: JSONValue, _ params: JSONValue) async {
    guard params["mode"]?.string ?? "form" == "form", let schema = params["requestedSchema"],
          let fields = PromptForms.fields(schema), !fields.isEmpty else {
      await connection.respond(id, result: .object(["action": .string("decline")]))
      return
    }
    let promptID = UUID().uuidString.lowercased()
    waiting[promptID] = .form(id: id, fields: fields)
    emit.yield(.prompt(PromptForms.prompt(id: promptID, message: params["message"]?.string ?? "", fields: fields)))
  }

  // MARK: Shapes

  private static func choices(_ value: JSONValue?, key: String = "value") -> [SessionOption] {
    var result: [SessionOption] = []
    for option in value?.array ?? [] {
      // Options may come grouped.
      if let group = option["options"]?.array {
        result += choices(.array(group), key: key)
        continue
      }
      guard let id = option[key]?.string ?? option["id"]?.string else { continue }
      result.append(SessionOption(id: id, name: option["name"]?.string ?? id, detail: option["description"]?.string))
    }
    return result
  }

  /// Takes what an update says about a tool call. Returns output streamed
  /// a piece at a time, which is not added to the call.
  private static func merge(_ update: JSONValue, into call: inout ToolCall) -> String? {
    if let title = update["title"]?.string { call.title = title }
    if let kind = update["kind"]?.string {
      call.name = kind
      call.kind = switch kind {
      case "read": .read
      case "edit": .edit
      case "delete": .delete
      case "move": .move
      case "search": .search
      case "execute": .execute
      case "fetch": .fetch
      case "think": .thinking
      default: .other
      }
    }
    if update["_meta"]?["wovenKind"]?.string == "task" { call.kind = .task }
    if let input = update["rawInput"], input != .null { call.input = ToolOutput.capped(text(input)) }
    var parts: [String] = []
    for item in update["content"]?.array ?? [] {
      switch item["type"]?.string {
      case "content":
        if let text = item["content"]?["text"]?.string { parts.append(text) }
      case "diff":
        if let path = item["path"]?.string { parts.append("Edited \(path)") }
      case "terminal":
        if let id = item["terminalId"]?.string { parts.append("Terminal \(id)") }
      default: break
      }
    }
    // Codex streams a command's output in metadata, a piece at a time.
    let streamed = update["_meta"]?["terminal_output_delta"]?["data"]?.string ?? update["_meta"]?["mcp_output_delta"]?["data"]?.string
    if !parts.isEmpty {
      call.output = ToolOutput.capped(parts.joined(separator: "\n\n"))
    } else if let streamed {
      return streamed
    } else if let output = update["rawOutput"], output != .null {
      let readable = ["formatted_output", "aggregated_output", "stdout", "output"].lazy.compactMap { output[$0]?.string }.first
      if let readable { call.output = ToolOutput.capped(readable) } else if call.output?.isEmpty ?? true {
        call.output = ToolOutput.capped(text(output))
      }
    }
    return nil
  }

  private static func text(_ value: JSONValue) -> String {
    if case .string(let text) = value { return text }
    return (try? String(decoding: Wire.encoder.encode(value), as: UTF8.self)) ?? ""
  }

  private static func usage(_ result: JSONValue, model: String?) -> TokenUsage? {
    let usage = result["usage"] ?? result["_meta"]?["usage"]
    guard let usage, let input = usage["inputTokens"]?.int, let output = usage["outputTokens"]?.int else { return nil }
    return TokenUsage(model: result["_meta"]?["model"]?.string ?? model, input: Int64(input), output: Int64(output),
                      cacheRead: Int64(usage["cachedReadTokens"]?.int ?? 0), cacheWrite: Int64(usage["cachedWriteTokens"]?.int ?? 0),
                      cost: usage["cost"]?.double)
  }

  /// A turn as ACP content blocks: images inline, text files embedded, other
  /// files linked by path (and named in the text, since some adapters reduce
  /// a link to a mention).
  private static func blocks(_ turn: Turn) throws -> [JSONValue] {
    var files: [JSONValue] = []
    var linked: [String] = []
    for attachment in turn.attachments {
      let uri = attachment.file.absoluteString
      if attachment.mimeType.hasPrefix("image/") {
        let data = try Data(contentsOf: attachment.file)
        files.append(.object(["type": .string("image"), "mimeType": .string(attachment.mimeType),
                              "data": .string(data.base64EncodedString())]))
      } else if attachment.mimeType.hasPrefix("text/"), attachment.size < 1 << 20,
                let text = String(data: try Data(contentsOf: attachment.file), encoding: .utf8) {
        files.append(.object(["type": .string("resource"), "resource": .object([
          "uri": .string(uri), "mimeType": .string(attachment.mimeType), "text": .string(text)])]))
      } else {
        linked.append("\(attachment.name): \(attachment.file.path)")
        files.append(.object(["type": .string("resource_link"), "uri": .string(uri), "name": .string(attachment.name),
                              "mimeType": .string(attachment.mimeType), "size": .integer(attachment.size)]))
      }
    }
    let text = withFiles(turn.text, linked)
    return (text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]) + files
  }

  /// A turn as text alone, its files named by path.
  private static func textWithFiles(_ turn: Turn) -> String {
    withFiles(turn.text, turn.attachments.map { "\($0.name): \($0.file.path)" })
  }

  private static func withFiles(_ text: String, _ linked: [String]) -> String {
    guard !linked.isEmpty else { return text }
    return text + (text.isEmpty ? "" : "\n\n") + "Attached files:\n" + linked.map { "- " + $0 }.joined(separator: "\n")
  }
}

