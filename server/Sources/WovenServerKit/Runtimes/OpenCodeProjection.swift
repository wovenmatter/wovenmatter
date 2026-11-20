import Foundation
import WovenProtocol

/// Turns one OpenCode session's events into runtime events: text deltas,
/// tool calls with their whole state, reasoning, to-dos and usage, and
/// closes whatever is open when the turn ends.
struct OpenCodeProjection: Sendable {
  private var texts: [String: String] = [:]
  private var openCalls: [String] = []
  private var calls: [String: ToolCall] = [:]
  private var usage: TokenUsage?
  private var model: String?
  private var stepFailure: String?

  /// The events `event` makes. It is one of this session's own.
  mutating func receive(_ event: OpenCodeJSON) -> [RuntimeEvent] {
    let data = event["data"]
    let message = data["assistantMessageID"].text
    switch event["type"].text {
    case "session.step.started":
      if let id = data["model"]["id"].string { model = data["model"]["providerID"].text + "/" + id }
      return []
    case "session.step.ended":
      addUsage(data)
      return []
    case "session.step.failed":
      addUsage(data)
      stepFailure = data["error"]["message"].string
      return []

    case "session.text.started":
      let key = textKey(data)
      if texts[key] == nil { texts[key] = "" }
      return []
    case "session.text.delta":
      let delta = data["delta"].text
      guard !delta.isEmpty else { return [] }
      texts[textKey(data), default: ""] += delta
      return [.text(delta)]
    case "session.text.ended":
      let seen = texts.removeValue(forKey: textKey(data)) ?? ""
      let final = data["text"].text
      var events: [RuntimeEvent] = []
      if final.hasPrefix(seen), final.count > seen.count { events.append(.text(String(final.dropFirst(seen.count)))) }
      if !seen.isEmpty || !final.isEmpty { events.append(.messageFinished) }
      return events

    case "session.reasoning.started":
      return update(reasoningID(data, message)) { _ in
        ToolCall(name: "reasoning", input: "", output: "", kind: .thinking)
      }
    case "session.reasoning.delta":
      return update(reasoningID(data, message)) { call in
        var call = call ?? ToolCall(name: "reasoning", input: "", output: "", kind: .thinking)
        call.output = (call.output ?? "") + data["delta"].text
        return call
      }
    case "session.reasoning.ended":
      return update(reasoningID(data, message), finished: true) { call in
        var call = call ?? ToolCall(name: "reasoning", input: "", kind: .thinking)
        call.output = data["text"].text
        return call
      }

    case "session.tool.input.started":
      let name = data["name"].text
      return update(data["id"].text) { _ in ToolCall(name: name, input: "", kind: Self.kind(name)) }
    case "session.tool.input.delta":
      return update(data["id"].text) { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        call.input += data["delta"].text
        return call
      }
    case "session.tool.input.ended":
      return update(data["id"].text) { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        call.input = data["text"].text
        return call
      }
    case "session.tool.called":
      return update(data["id"].text) { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        call.input = data["input"].jsonText
        call.title = Self.title(data["input"]) ?? call.title
        if call.kind == .plan { call.plan = Self.plan(data["input"]) }
        return call
      }
    case "session.tool.progress":
      return update(data["id"].text) { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        call.title = data["metadata"]["title"].string ?? call.title
        if let output = data["metadata"]["output"].string { call.output = output }
        return call
      }
    case "session.tool.success", "session.tool.failed":
      let failed = event["type"].text == "session.tool.failed"
      return update(data["id"].text, finished: true) { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        let content = Self.content(data["content"])
        call.output = failed ? [data["error"]["message"].text, content].filter { !$0.isEmpty }.joined(separator: "\n") : content
        call.failed = failed
        call.title = data["metadata"]["title"].string ?? call.title
        return call
      }

    case "session.execution.succeeded":
      return finishTurn(failure: stepFailure)
    case "session.execution.failed":
      return finishTurn(failure: data["error"]["message"].string ?? stepFailure ?? "OpenCode stopped the turn.")
    case "session.execution.interrupted":
      let reason = data["reason"].text
      return finishTurn(failure: reason == "user" ? nil : "OpenCode stopped the turn (\(reason)).", interrupted: true)
    default:
      return []
    }
  }

  /// Ends every open item, then the turn.
  mutating func finishTurn(failure: String?, interrupted: Bool = false) -> [RuntimeEvent] {
    var events: [RuntimeEvent] = []
    if texts.values.contains(where: { !$0.isEmpty }) { events.append(.messageFinished) }
    texts.removeAll()
    for id in openCalls {
      guard var call = calls[id] else { continue }
      if (interrupted || failure != nil) && call.kind != .thinking { call.failed = true }
      events.append(.tool(callID: id, call: call, finished: true))
    }
    openCalls.removeAll()
    calls.removeAll()
    events.append(.turnFinished(failure: failure, usage: usage))
    usage = nil
    stepFailure = nil
    return events
  }

  private mutating func update(_ id: String, finished: Bool = false, _ change: (ToolCall?) -> ToolCall) -> [RuntimeEvent] {
    guard !id.isEmpty else { return [] }
    let call = change(calls[id])
    if finished {
      calls[id] = nil
      openCalls.removeAll { $0 == id }
    } else {
      if calls[id] == nil { openCalls.append(id) }
      calls[id] = call
    }
    return [.tool(callID: id, call: call, finished: finished)]
  }

  private mutating func addUsage(_ data: OpenCodeJSON) {
    let tokens = data["tokens"]
    guard !tokens.isNull else { return }
    var total = usage ?? TokenUsage(model: model, input: 0, output: 0)
    total.model = model ?? total.model
    total.input += tokens["input"].int
    total.output += tokens["output"].int + tokens["reasoning"].int
    total.cacheRead += tokens["cache"]["read"].int
    total.cacheWrite += tokens["cache"]["write"].int
    if let cost = data["cost"].number { total.cost = (total.cost ?? 0) + cost }
    usage = total
  }

  private func textKey(_ data: OpenCodeJSON) -> String {
    data["assistantMessageID"].text + ":" + String(data["ordinal"].int)
  }

  private func reasoningID(_ data: OpenCodeJSON, _ message: String) -> String {
    message + ":reasoning:" + String(data["ordinal"].int)
  }

  static func kind(_ name: String) -> ToolKind {
    switch name.lowercased() {
    case "read": .read
    case "edit", "write", "patch", "apply_patch", "multiedit": .edit
    case "bash", "shell": .execute
    case "grep", "glob", "list", "find", "codesearch", "websearch": .search
    case "webfetch", "fetch": .fetch
    case "todowrite", "todoread", "todo": .plan
    case "task", "subagent": .task
    default: .other
    }
  }

  private static func title(_ input: OpenCodeJSON) -> String? {
    for key in ["description", "filePath", "path", "command", "pattern", "url", "query"] {
      if let value = input[key].string, !value.isEmpty { return value }
    }
    return nil
  }

  private static func plan(_ input: OpenCodeJSON) -> [PlanEntry] {
    input["todos"].array.map { todo in
      let status: PlanEntry.Status = switch todo["status"].text {
      case "in_progress": .inProgress
      case "completed", "cancelled": .completed
      default: .pending
      }
      return PlanEntry(text: todo["content"].string ?? todo["text"].text, status: status)
    }
  }

  private static func content(_ content: OpenCodeJSON) -> String {
    content.array.map { part in
      part["type"].text == "file" ? (part["name"].string ?? part["uri"].text) : part["text"].text
    }.joined(separator: "\n")
  }
}

// MARK: Prompts

extension OpenCodeProjection {
  static let permissionOptions = [
    PromptOption(id: "once", name: "Allow once"),
    PromptOption(id: "always", name: "Always allow"),
    PromptOption(id: "reject", name: "Reject"),
  ]

  /// A `permission.asked` event's request as a prompt.
  static func permissionPrompt(_ request: OpenCodeJSON) -> Prompt {
    let resources = request["resources"].array.compactMap(\.string).joined(separator: ", ")
    let text = request["message"].string ?? [request["action"].text, resources].filter { !$0.isEmpty }.joined(separator: ": ")
    return Prompt(id: request["id"].text, kind: .approval, text: text, options: permissionOptions)
  }

  /// The body of a reply to a permission request.
  static func permissionReply(_ answer: String) -> OpenCodeJSON {
    if permissionOptions.contains(where: { $0.id == answer }) { return ["decision": .string(answer)] }
    return ["decision": "reject", "message": .string(answer)]
  }

  /// A form OpenCode asks the person to fill in, as a prompt. A form of one
  /// field with fixed choices offers them as options.
  static func formPrompt(_ form: OpenCodeJSON) -> Prompt {
    let fields = visibleFields(form)
    let lines = [form["title"].text] + fields.compactMap { field -> String? in
      let text = [field["title"].string, field["description"].string].compactMap { $0 }.joined(separator: ": ")
      return text.isEmpty || fields.count == 1 && text == form["title"].text ? nil : text
    }
    var options: [PromptOption] = []
    if fields.count == 1 {
      let field = fields[0]
      options = field["options"].array.map { PromptOption(id: $0["value"].text, name: $0["label"].string ?? $0["value"].text) }
      if options.isEmpty, field["type"].text == "boolean" {
        options = [PromptOption(id: "true", name: "Yes"), PromptOption(id: "false", name: "No")]
      }
    }
    return Prompt(id: form["id"].text, kind: .question, text: lines.filter { !$0.isEmpty }.joined(separator: "\n"),
                  options: options)
  }

  /// The body of a reply to a form: the answer for its one field, or a JSON
  /// object of answers by field key.
  static func formReply(_ form: OpenCodeJSON, answer: String) -> OpenCodeJSON {
    if case .object(let answers)? = try? OpenCodeJSON.decode(Data(answer.utf8)) {
      return ["answer": .object(answers)]
    }
    guard let field = visibleFields(form).first else { return ["answer": [:]] }
    let value: OpenCodeJSON = switch field["type"].text {
    case "multiselect": .array([.string(answer)])
    case "number", "integer": Double(answer).map(OpenCodeJSON.number) ?? .string(answer)
    case "boolean": .bool(["true", "yes", "y", "1"].contains(answer.lowercased()))
    default: .string(answer)
    }
    return ["answer": .object([field["key"].text: value])]
  }

  private static func visibleFields(_ form: OpenCodeJSON) -> [OpenCodeJSON] {
    form["fields"].array.filter { $0["hidden"].bool != true && $0["type"].text != "external" }
  }
}
