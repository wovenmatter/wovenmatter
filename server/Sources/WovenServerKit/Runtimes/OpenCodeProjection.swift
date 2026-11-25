import Foundation
import Synchronization
import WovenProtocol

/// Turns one OpenCode session's events into runtime events: text deltas,
/// tool calls, reasoning and to-dos, and closes whatever is open when the turn
/// ends. Its usage is counted from OpenCode's own history.
///
/// Reasoning and streamed output travel as deltas, as on the ACP runtimes.
/// OpenCode ends a step's reasoning only when the step's stream ends, after
/// the step's text and tool calls began, so the reasoning is ended as soon as
/// anything else of the step starts: it keeps its place before them.
struct OpenCodeProjection: Sendable {
  /// The OpenCode session, whose failed Woven calls fill in its scripts' failures.
  var session = ""
  private var texts: [String: String] = [:]
  private var openCalls: [String] = []
  private var calls: [String: ToolCall] = [:]
  private var stepFailure: String?
  /// The reasoning part being streamed now and the item it shows as, once
  /// it has text.
  private var thinking: (part: String, item: String)?
  /// How often each reasoning part was ended here. Its late end is ignored;
  /// reasoning it streams after all shows as an item of its own.
  private var endedThinking: [String: Int] = [:]
  /// The error of each failed call in a script, by the script's call and
  /// the call's place in it, once claimed.
  private var nestedErrors: [String: [Int: String]] = [:]

  /// The events `event` makes. It is one of this session's own.
  mutating func receive(_ event: JSONValue) -> [RuntimeEvent] {
    let type = event["type"]?.string ?? ""
    // What starts the step's text or a tool call. A tool's later events are
    // not: a tool running on can report while the next step reasons.
    let ending = type.hasPrefix("session.text.") || type == "session.tool.input.started" || type == "session.tool.called"
      || type == "session.step.ended"
    let ended = ending ? endThinking() : []
    return ended + project(type, event["data"] ?? .null)
  }

  private mutating func project(_ type: String, _ data: JSONValue) -> [RuntimeEvent] {
    let message = data["assistantMessageID"]?.string ?? ""
    switch type {
    case "session.step.failed":
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
      return startThinking(reasoningID(data, message))
    case "session.reasoning.delta":
      let delta = data["delta"]?.string ?? ""
      guard !delta.isEmpty else { return [] }
      var events = startThinking(reasoningID(data, message))
      guard let item = thinking?.item else { return events }
      if calls[item] == nil { events += update(item) { _ in Self.thought("") } }
      let streamed = calls[item]?.output ?? ""
      calls[item]?.output = streamed + delta
      return events + [.toolOutput(callID: item, delta: delta)]
    case "session.reasoning.ended":
      let part = reasoningID(data, message)
      guard let current = thinking, current.part == part else {
        // Ended here already, or never streamed: its whole text shows once.
        guard endedThinking[part] == nil, let text = data["text"]?.string, !text.isEmpty else { return [] }
        endedThinking[part] = 1
        return update(part, finished: true) { _ in Self.thought(text) }
      }
      thinking = nil
      endedThinking[part, default: 0] += 1
      // The part's whole text, unless only a later stretch of it shows here.
      let final = data["text"]?.string ?? ""
      let text = current.item == part && !final.isEmpty ? final : calls[current.item]?.output ?? ""
      guard calls[current.item] != nil || !text.isEmpty else { return [] }
      return update(current.item, finished: true) { _ in Self.thought(text) }

    case "session.tool.input.started":
      let name = data["name"]?.string ?? ""
      return update(data["id"]?.string ?? "") { _ in ToolCall(name: name, input: "", kind: Self.kind(name)) }
    case "session.tool.input.delta":
      // The input shows whole once it is complete, as on the ACP runtimes,
      // rather than resending the call for every piece of it.
      guard let id = data["id"]?.string, calls[id] != nil else { return [] }
      calls[id]?.input += data["delta"]?.string ?? ""
      return []
    case "session.tool.input.ended":
      return update(data["id"]?.string ?? "") { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        let text = data["text"]?.string ?? ""
        // A script's input is its source, sent as `{code}` or, by a freeform
        // provider, as the code itself.
        call.input = call.kind == .code ? Self.script(text) : text
        return call
      }
    case "session.tool.called":
      return update(data["id"]?.string ?? "") { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        let input = data["input"] ?? .null
        if call.kind == .code {
          call.input = Self.script(input)
          return call
        }
        call.input = Self.compactText(input)
        if call.kind == .question {
          call.questions = Self.questions(input)
          return call
        }
        call.title = Self.title(input) ?? call.title
        if call.kind == .plan { call.plan = Self.plan(input) }
        return call
      }
    case "session.tool.progress":
      let id = data["id"]?.string ?? ""
      // A script reports the tool calls it has made so far, all of them
      // each time, often unchanged.
      if let made = nested(data["metadata"]?["toolCalls"], in: id) {
        // Progress may come after the end; it never reopens a call.
        guard let open = calls[id], open.calls != made else { return [] }
        return update(id) { _ in
          var call = Self.asScript(open)
          call.calls = made
          return call
        }
      }
      let title = data["metadata"]?["title"]?.string
      let output = data["metadata"]?["output"]?.string
      // Output that grows travels as what is new.
      if let call = calls[id], title == nil || title == call.title, let output, output.hasPrefix(call.output ?? "") {
        let delta = String(output.dropFirst((call.output ?? "").count))
        calls[id]?.output = output
        return delta.isEmpty ? [] : [.toolOutput(callID: id, delta: delta)]
      }
      return update(id) { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        call.title = title ?? call.title
        if let output { call.output = output }
        return call
      }
    case "session.tool.success", "session.tool.failed":
      let failed = type == "session.tool.failed"
      let id = data["id"]?.string ?? ""
      let metadata = data["metadata"] ?? .null
      let made = nested(metadata["toolCalls"], in: id)
      return update(id, finished: true) { call in
        var call = call ?? ToolCall(name: "tool", input: "")
        if let made {
          call = Self.asScript(call)
          call.calls = made
        }
        var content = Self.content(data["content"] ?? .null)
        if metadata["truncated"]?.bool == true, let path = metadata["outputPath"]?.string {
          content += "\n(OpenCode cut this output short; the whole of it is in \(path).)"
        }
        call.output = failed ? [data["error"]?["message"]?.string ?? "", content].filter { !$0.isEmpty }.joined(separator: "\n") : content
        // A tool that reports its own failure, or a script that failed,
        // succeeds with `metadata.error`.
        call.failed = failed || metadata["error"]?.bool == true
        call.title = call.kind == .code ? call.title : metadata["title"]?.string ?? call.title
        // OpenCode's answers, one list per question in the order asked.
        if call.kind == .question, !failed, let answers = metadata["answers"]?.array {
          call.questions = call.questions?.enumerated().map { index, question in
            var question = question
            question.answer = (answers[safe: index]?.array ?? []).compactMap(\.string)
            return question
          }
        }
        return call
      }

    case "session.execution.succeeded":
      return finishTurn(failure: stepFailure)
    case "session.execution.failed":
      return finishTurn(failure: data["error"]?["message"]?.string ?? stepFailure ?? "OpenCode stopped the turn.")
    case "session.execution.interrupted":
      let reason = data["reason"]?.string ?? ""
      // OpenCode reports an interruption it gives no reason for as
      // "shutdown", as when the person dismisses a question, and its own
      // clients show nothing for it; nor is the person stopping it a failure.
      let quiet = reason == "user" || reason == "shutdown"
      return finishTurn(failure: quiet ? nil : "OpenCode stopped the turn (\(reason)).", interrupted: true)
    default:
      return []
    }
  }

  /// Ends every open item, then the turn.
  mutating func finishTurn(failure: String?, interrupted: Bool = false) -> [RuntimeEvent] {
    var events = endThinking()
    endedThinking.removeAll()
    if texts.values.contains(where: { !$0.isEmpty }) { events.append(.messageFinished) }
    texts.removeAll()
    for id in openCalls {
      guard var call = calls[id] else { continue }
      if (interrupted || failure != nil) && call.kind != .thinking {
        call.failed = true
        // A script's calls still out ended with it.
        call.calls = call.calls?.map { nested in
          guard nested.output == nil else { return nested }
          var nested = nested
          nested.output = "It stopped with the turn."
          nested.failed = true
          return nested
        }
      }
      events.append(.tool(callID: id, call: call, finished: true))
    }
    openCalls.removeAll()
    calls.removeAll()
    nestedErrors.removeAll()
    OpenCodeToolFailures.shared.forget(session: session)
    events.append(.turnFinished(failure: failure, usage: nil))
    stepFailure = nil
    return events
  }

  /// Makes `part` the reasoning being streamed, ending any other.
  private mutating func startThinking(_ part: String) -> [RuntimeEvent] {
    guard thinking?.part != part else { return [] }
    let ended = endThinking()
    let times = endedThinking[part] ?? 0
    thinking = (part, times == 0 ? part : part + ":again:" + String(times))
    return ended
  }

  /// Ends the reasoning being streamed, with the text it has so far.
  private mutating func endThinking() -> [RuntimeEvent] {
    guard let current = thinking else { return [] }
    thinking = nil
    endedThinking[current.part, default: 0] += 1
    guard let call = calls[current.item] else { return [] }
    return update(current.item, finished: true) { _ in call }
  }

  private static func thought(_ text: String) -> ToolCall {
    ToolCall(name: "thinking", input: "", output: text, title: "Thinking", kind: .thinking)
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
    // Code Mode's tool: a script that calls MCP tools.
    case "execute": .code
    case "grep", "glob", "list", "find", "codesearch", "websearch": .search
    case "webfetch", "fetch": .fetch
    case "todowrite", "todoread", "todo": .plan
    case "task", "subagent": .task
    case "question": .question
    default: .other
    }
  }

  private static func title(_ input: JSONValue) -> String? {
    for key in ["description", "filePath", "path", "command", "pattern", "url", "query"] {
      if let value = input[key]?.string, !value.isEmpty { return value }
    }
    return nil
  }

  /// The questions OpenCode's question tool asks: `header`, `question` and
  /// `options` with their `label`s.
  private static func questions(_ input: JSONValue) -> [ToolQuestion] {
    (input["questions"]?.array ?? []).map { question in
      ToolQuestion(title: question["header"]?.string, text: question["question"]?.string ?? "",
                   options: (question["options"]?.array ?? []).compactMap { $0["label"]?.string })
    }
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

  /// A result's text. A file part (an image a tool returned, which reaches
  /// the model) shows as its name or type; its data is never kept.
  private static func content(_ content: JSONValue) -> String {
    (content.array ?? []).map { part in
      guard part["type"]?.string == "file" else { return part["text"]?.string ?? "" }
      if let name = part["name"]?.string, !name.isEmpty { return "[\(name)]" }
      if let uri = part["uri"]?.string, !uri.hasPrefix("data:") { return "[\(uri)]" }
      return "[\(part["mime"]?.string ?? "file")]"
    }.joined(separator: "\n")
  }

  /// A Code Mode script's source from its input: `{code}`, as JSON text or
  /// a value, or the code itself.
  private static func script(_ input: JSONValue) -> String {
    if let code = input["code"]?.string { return code }
    return input.string ?? compactText(input)
  }

  private static func script(_ text: String) -> String {
    guard text.hasPrefix("{"), let input = try? OpenCodeSSEParser.decode(Data(text.utf8)), let code = input["code"]?.string else {
      return text
    }
    return code
  }

  /// A call that turned out to be a script, from what it reported.
  private static func asScript(_ call: ToolCall) -> ToolCall {
    guard call.kind != .code else { return call }
    var call = call
    call.kind = .code
    call.input = script(call.input)
    call.title = nil
    return call
  }

  /// What a failed call in a script says when Woven did not answer it.
  /// OpenCode reports only that it failed; the script's output often has
  /// its error.
  static let nestedFailure = "OpenCode did not say why it failed."
  /// What a failed call of a Woven tool says when Woven never got it:
  /// OpenCode refused it first, as for arguments its schema does not allow.
  static let refusedByOpenCode = "OpenCode refused this call before it reached Woven Matter, as for arguments that do not fit the tool. The script's output says why."

  /// The tool calls a script made, from Code Mode's `metadata.toolCalls`:
  /// each `{tool, status, input?}`, in order. Nil when there are none to read.
  /// A failed call of a Woven tool says the error Woven answered it with.
  mutating func nested(_ value: JSONValue?, in callID: String) -> [ToolCall]? {
    guard let entries = value?.array else { return nil }
    return entries.enumerated().map { index, entry in
      let status = entry["status"]?.string
      let failed = status == "error"
      let name = entry["tool"]?.string ?? "tool"
      var output: String? = status == "completed" ? "" : nil
      if failed {
        if let known = nestedErrors[callID]?[index] {
          output = known
        } else {
          let claimed = name.hasPrefix("woven.")
            ? OpenCodeToolFailures.shared.claim(session: session, tool: String(name.dropFirst(6)), input: entry["input"]) : nil
          if let claimed { nestedErrors[callID, default: [:]][index] = claimed }
          output = claimed ?? (name.hasPrefix("woven.") ? Self.refusedByOpenCode : Self.nestedFailure)
        }
      }
      return ToolCall(name: name, input: CodeCalls.input(entry["input"] ?? .object([:])), output: output, failed: failed)
    }
  }
}

/// The errors Woven answered OpenCode's calls with, by OpenCode session,
/// until that session's projection shows them. OpenCode's Code Mode says
/// only that a call in a script failed; Woven answered the call, so it
/// knows why. A turn's end forgets the session's.
final class OpenCodeToolFailures: Sendable {
  static let shared = OpenCodeToolFailures()
  private struct Failure { var tool: String; var input: JSONValue; var message: String }
  private let recorded = Mutex<[String: [Failure]]>([:])

  func record(session: String, tool: String, input: JSONValue, message: String) {
    recorded.withLock { all in
      var failures = all[session, default: []]
      failures.append(Failure(tool: tool, input: input, message: message))
      all[session] = Array(failures.suffix(100))
    }
  }

  /// The oldest failure of `tool`, with this input when OpenCode said it.
  func claim(session: String, tool: String, input: JSONValue?) -> String? {
    recorded.withLock { all in
      guard var failures = all[session],
            let index = failures.firstIndex(where: { $0.tool == tool && $0.input == input })
              ?? failures.firstIndex(where: { $0.tool == tool }) else { return nil }
      let message = failures.remove(at: index).message
      all[session] = failures.isEmpty ? nil : failures
      return message
    }
  }

  func forget(session: String) { _ = recorded.withLock { $0.removeValue(forKey: session) } }
}

// MARK: Prompts

extension OpenCodeProjection {
  static let permissionOptions = [
    PromptOption(id: "once", name: "Allow once", allowsOnce: true),
    PromptOption(id: "always", name: "Always allow"),
    PromptOption(id: "reject", name: "Reject"),
  ]

  /// A `permission.asked` event's request as a prompt. A tool a script
  /// calls asks as itself (`woven_render_html`), for any resource (`*`).
  static func permissionPrompt(_ request: JSONValue) -> Prompt {
    let resources = (request["resources"]?.array ?? []).compactMap(\.string).filter { $0 != "*" }.joined(separator: ", ")
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
                         options: options, ownAnswer: field["custom"]?.bool ?? false, initial: initial == .null ? nil : initial,
                         placeholder: field["placeholder"]?.string, multiline: field["type"]?.string == "textarea",
                         minimum: field["minimum"]?.double, maximum: field["maximum"]?.double)
    }
    return PromptForms.prompt(id: form["id"]?.string ?? "", message: form["title"]?.string ?? "", fields: fields)
  }

  /// The request that answers a form of a session: a reply with the
  /// person's values, or a cancel when they declined.
  static func formAnswer(sessionID: String, form: JSONValue, answer: PromptAnswer) throws
    -> (method: String, path: String, body: JSONValue?)
  {
    let path = "/api/session/" + OpenCodeClient.segment(sessionID) + "/form/" + OpenCodeClient.segment(form["id"]?.string ?? "")
    if answer == .declined { return ("DELETE", path, nil) }
    return ("POST", path + "/reply", try formReply(form, answer: answer))
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
