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
  mutating func receive(_ event: JSONValue) -> [RuntimeEvent] {
    let data = event["data"] ?? .null
    let message = data["assistantMessageID"]?.string ?? ""
    switch event["type"]?.string {
    case "session.step.started":
      if let id = data["model"]?["id"]?.string { model = (data["model"]?["providerID"]?.string ?? "") + "/" + id }
      return []
    case "session.step.ended":
      addUsage(data)
      return []
    case "session.step.failed":
      addUsage(data)
      stepFailure = data["error"]?["message"]?.string
      return []

    case "session.text.started":
      let key = textKey(data)
      if texts[key] == nil { texts[key] = "" }
      return []
    case "session.text.delta":
      let delta = data["delta"]?.string ?? ""
      guard !delta.isEmpty else { return [] }
      texts[textKey(data), default: ""] += delta
      return [.text(delta)]
    case "session.text.ended":
      let seen = texts.removeValue(forKey: textKey(data)) ?? ""
      let final = data["text"]?.string ?? ""
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
        call.output = (call.output ?? "") + (data["delta"]?.string ?? "")
        return call
      }
    case "session.reasoning.ended":
      return update(reasoningID(data, message), finished: true) { call in
        var call = call ?? ToolCall(name: "reasoning", input: "", kind: .thinking)
        call.output = data["text"]?.string ?? ""
        return call
      }

    case "session.tool.input.started":
      let name = data["name"]?.string ?? ""
      return update(data["id"]?.string ?? "") { _ in ToolCall(name: name, input: "", kind: Self.kind(name)) }
    case "session.tool.input.delta":
      return update(data["id"]?.string ?? "") { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        call.input += data["delta"]?.string ?? ""
        return call
      }
    case "session.tool.input.ended":
      return update(data["id"]?.string ?? "") { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        call.input = data["text"]?.string ?? ""
        return call
      }
    case "session.tool.called":
      return update(data["id"]?.string ?? "") { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        let input = data["input"] ?? .null
        call.input = Self.compactText(input)
        call.title = Self.title(input) ?? call.title
        if call.kind == .plan { call.plan = Self.plan(input) }
        return call
      }
    case "session.tool.progress":
      return update(data["id"]?.string ?? "") { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        call.title = data["metadata"]?["title"]?.string ?? call.title
        if let output = data["metadata"]?["output"]?.string { call.output = output }
        return call
      }
    case "session.tool.success", "session.tool.failed":
      let failed = event["type"]?.string == "session.tool.failed"
      return update(data["id"]?.string ?? "", finished: true) { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        let content = Self.content(data["content"] ?? .null)
        call.output = failed ? [data["error"]?["message"]?.string ?? "", content].filter { !$0.isEmpty }.joined(separator: "\n") : content
        call.failed = failed
        call.title = data["metadata"]?["title"]?.string ?? call.title
        return call
      }

    case "session.execution.succeeded":
      return finishTurn(failure: stepFailure)
    case "session.execution.failed":
      return finishTurn(failure: data["error"]?["message"]?.string ?? stepFailure ?? "OpenCode stopped the turn.")
    case "session.execution.interrupted":
      let reason = data["reason"]?.string ?? ""
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

  private mutating func addUsage(_ data: JSONValue) {
    guard let tokens = data["tokens"], tokens != .null else { return }
    var total = usage ?? TokenUsage(model: model, input: 0, output: 0)
    total.model = model ?? total.model
    total.input += Self.count(tokens["input"])
    total.output += Self.count(tokens["output"]) + Self.count(tokens["reasoning"])
    total.cacheRead += Self.count(tokens["cache"]?["read"])
    total.cacheWrite += Self.count(tokens["cache"]?["write"])
    if let cost = data["cost"]?.double { total.cost = (total.cost ?? 0) + cost }
    usage = total
  }

  private func textKey(_ data: JSONValue) -> String {
    (data["assistantMessageID"]?.string ?? "") + ":" + String(Self.count(data["ordinal"]))
  }

  private func reasoningID(_ data: JSONValue, _ message: String) -> String {
    message + ":reasoning:" + String(Self.count(data["ordinal"]))
  }

  /// A count OpenCode sends, or zero.
  private static func count(_ value: JSONValue?) -> Int64 {
    Int64(value?.double ?? 0)
  }

  /// Compact JSON text with sorted keys, for tool input.
  private static func compactText(_ value: JSONValue) -> String {
    (try? Wire.encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
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

  private static func title(_ input: JSONValue) -> String? {
    for key in ["description", "filePath", "path", "command", "pattern", "url", "query"] {
      if let value = input[key]?.string, !value.isEmpty { return value }
    }
    return nil
  }

  private static func plan(_ input: JSONValue) -> [PlanEntry] {
    (input["todos"]?.array ?? []).map { todo in
      let status: PlanEntry.Status = switch todo["status"]?.string {
      case "in_progress": .inProgress
      case "completed", "cancelled": .completed
      default: .pending
      }
      return PlanEntry(text: todo["content"]?.string ?? todo["text"]?.string ?? "", status: status)
    }
  }

  private static func content(_ content: JSONValue) -> String {
    (content.array ?? []).map { part in
      part["type"]?.string == "file" ? (part["name"]?.string ?? part["uri"]?.string ?? "") : (part["text"]?.string ?? "")
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
  static func permissionPrompt(_ request: JSONValue) -> Prompt {
    let resources = (request["resources"]?.array ?? []).compactMap(\.string).joined(separator: ", ")
    let text = request["message"]?.string ?? [request["action"]?.string ?? "", resources].filter { !$0.isEmpty }.joined(separator: ": ")
    return Prompt(id: request["id"]?.string ?? "", kind: .approval, text: text, options: permissionOptions)
  }

  /// The body of a reply to a permission request.
  static func permissionReply(_ answer: PromptAnswer) -> JSONValue {
    switch answer {
    case .option(let id) where permissionOptions.contains(where: { $0.id == id }): .object(["decision": .string(id)])
    case .text(let text): .object(["decision": .string("reject"), "message": .string(text)])
    default: .object(["decision": .string("reject")])
    }
  }

  /// A form OpenCode asks the person to fill in, in the one prompt shape.
  static func formPrompt(_ form: JSONValue) -> Prompt {
    let fields = visibleFields(form).map { field -> PromptField in
      let options = (field["options"]?.array ?? []).map {
        PromptOption(id: $0["value"]?.string ?? "", name: $0["label"]?.string ?? $0["value"]?.string ?? "",
                     detail: $0["description"]?.string)
      }
      let kind: PromptField.Kind = switch field["type"]?.string {
      case "multiselect": .choices
      case "select", "radio": .choice
      case "number": .number
      case "integer": .integer
      case "boolean": .boolean
      default: options.isEmpty ? .text : .choice
      }
      let initial = field["default"]
      return PromptField(id: field["key"]?.string ?? "", title: field["title"]?.string ?? field["key"]?.string ?? "",
                         detail: field["description"]?.string, kind: kind, required: field["required"]?.bool ?? false,
                         options: options, initial: initial == .null ? nil : initial,
                         placeholder: field["placeholder"]?.string, multiline: field["type"]?.string == "textarea",
                         minimum: field["minimum"]?.double, maximum: field["maximum"]?.double)
    }
    return PromptForms.prompt(id: form["id"]?.string ?? "", message: form["title"]?.string ?? "", fields: fields)
  }

  /// The body of a reply to a form, from the answer for its fields.
  static func formReply(_ form: JSONValue, answer: PromptAnswer) throws -> JSONValue {
    let fields = formPrompt(form).fields
    let values: [String: JSONValue]
    switch answer {
    case .values(let given): values = given
    case .option(let id) where fields.count == 1: values = [fields[0].id: .string(id)]
    case .text(let text) where fields.count == 1: values = [fields[0].id: .string(text)]
    default: throw RuntimeError.failed("That answer does not fit what was asked.")
    }
    try PromptForms.check(values, against: fields)
    // Hidden fields keep their defaults.
    var answers: [String: JSONValue] = [:]
    for field in form["fields"]?.array ?? [] where field["hidden"]?.bool == true {
      if let value = field["default"], value != .null { answers[field["key"]?.string ?? ""] = value }
    }
    for (key, value) in values { answers[key] = value }
    return .object(["answer": .object(answers)])
  }

  private static func visibleFields(_ form: JSONValue) -> [JSONValue] {
    (form["fields"]?.array ?? []).filter { $0["hidden"]?.bool != true && $0["type"]?.string != "external" }
  }
}
