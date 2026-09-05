import Foundation
import WovenMatterClient
import WovenMatterCore

/// Provider-neutral projection of the OpenClaw Gateway's ordered event stream.
/// The raw frame is persisted independently; this type supplies the live
/// transcript mutations consumed by the same UI as every other harness.
struct OpenClawGatewayEventProjection: Equatable, Sendable {
  enum AssistantUpdate: Equatable, Sendable {
    case append(String)
    case replace(String)
  }

  enum TerminalState: Equatable, Sendable {
    case completed
    case cancelled(String?)
    case failed(String)
  }

  struct Approval: Equatable, Sendable {
    let id: String
    let kind: String
    let sessionKey: String?
    let title: String
    let command: String?
    let allowedDecisions: [String]
    let resolvedDecision: String?
  }

  let runID: String?
  let sessionKey: String?
  let sequence: Int?
  let eventType: String
  let eventPhase: String?
  let toolName: String?
  let content: String?
  let assistantUpdate: AssistantUpdate?
  let activity: AgentRunActivity?
  let terminalState: TerminalState?
  let approval: Approval?

  static func project(_ event: OpenClawGatewayEvent) -> Self? {
    guard let payload = event.payload?.objectValue else { return nil }
    switch event.name {
    case "agent", "session.tool":
      return projectAgent(event: event, payload: payload)
    case "chat":
      return projectChat(event: event, payload: payload)
    case "exec.approval.requested", "exec.approval.resolved",
         "plugin.approval.requested", "plugin.approval.resolved":
      return projectApproval(event: event, payload: payload)
    default:
      return Self(
        runID: string(payload["runId"]),
        sessionKey: string(payload["sessionKey"]),
        sequence: sequence(event: event, payload: payload),
        eventType: "gateway_event",
        eventPhase: nil,
        toolName: nil,
        content: nil,
        assistantUpdate: nil,
        activity: nil,
        terminalState: nil,
        approval: nil
      )
    }
  }

  private static func projectAgent(
    event: OpenClawGatewayEvent,
    payload: [String: GatewayJSONValue]
  ) -> Self {
    let data = payload["data"]?.objectValue ?? [:]
    let stream = string(payload["stream"]) ?? "activity"
    let runID = string(payload["runId"])
    let sessionKey = string(payload["sessionKey"])
    let sequence = sequence(event: event, payload: payload)

    if stream == "assistant" {
      let snapshot = text(data["text"])
      let delta = text(data["delta"])
      let update: AssistantUpdate? = if let snapshot {
        .replace(snapshot)
      } else if let delta {
        .append(delta)
      } else {
        nil
      }
      return Self(
        runID: runID,
        sessionKey: sessionKey,
        sequence: sequence,
        eventType: snapshot == nil ? "assistant_delta" : "assistant_replace",
        eventPhase: "update",
        toolName: nil,
        content: snapshot ?? delta,
        assistantUpdate: update,
        activity: nil,
        terminalState: nil,
        approval: nil
      )
    }

    if stream == "tool" {
      let phase = string(data["phase"]) ?? "update"
      let toolName = string(data["name"]) ?? "tool"
      let toolCallID = string(data["toolCallId"]) ?? "tool-\(sequence ?? 0)"
      let input = data["args"]
      let output = data["result"] ?? data["partialResult"]
      let failed = data["isError"]?.boolValue == true
      let status: String = switch phase {
      case "start", "update": "running"
      case "result": failed ? "failed" : "completed"
      default: phase
      }
      let activity = AgentRunActivity(
        id: toolCallID,
        kind: .tool,
        phase: phase,
        title: toolTitle(name: toolName),
        detail: toolDetail(input: input),
        status: status,
        toolName: toolName,
        content: displayText(output),
        contentIsDelta: false,
        locations: locations(in: [input, output]),
        changes: fileChanges(in: [input, output]),
        rawInputJSON: json(input),
        rawOutputJSON: json(output),
        rawPayloadJSON: json(.object(payload))
      )
      return Self(
        runID: runID,
        sessionKey: sessionKey,
        sequence: sequence,
        eventType: phase == "result" ? "tool_result" : "tool_call",
        eventPhase: phase,
        toolName: toolName,
        content: activity.content,
        assistantUpdate: nil,
        activity: activity,
        terminalState: nil,
        approval: nil
      )
    }

    if stream == "thinking" || stream == "reasoning" {
      let delta = text(data["delta"])
      let snapshot = text(data["text"]) ?? text(data["thinking"])
      let content = delta ?? snapshot
      let phase = string(data["phase"]) ?? "update"
      return Self(
        runID: runID,
        sessionKey: sessionKey,
        sequence: sequence,
        eventType: "reasoning",
        eventPhase: phase,
        toolName: nil,
        content: content,
        assistantUpdate: nil,
        activity: content.map {
          AgentRunActivity(
            id: "thinking",
            kind: .thought,
            phase: phase,
            title: "Thinking",
            status: phase == "end" ? "completed" : "running",
            content: $0,
            contentIsDelta: delta != nil && data["replace"]?.boolValue != true,
            rawPayloadJSON: json(.object(payload))
          )
        },
        terminalState: nil,
        approval: nil
      )
    }

    if stream == "approval",
       let approvalID = string(data["approvalId"]) {
      let phase = string(data["phase"]) ?? "requested"
      let kind = string(data["kind"]) ?? "exec"
      let status = string(data["status"])
      let command = string(data["command"])
        ?? string(data["message"])
        ?? string(data["reason"])
      let title = string(data["title"]) ?? "Command approval requested"
      let approval = Approval(
        id: approvalID,
        kind: kind,
        sessionKey: sessionKey,
        title: title,
        command: command,
        allowedDecisions: [],
        resolvedDecision: phase == "requested"
          ? nil
          : (status == "denied" ? "deny" : status ?? "resolved")
      )
      return Self(
        runID: runID,
        sessionKey: sessionKey,
        sequence: sequence,
        eventType: "approval",
        eventPhase: phase,
        toolName: kind,
        content: command,
        assistantUpdate: nil,
        activity: approvalActivity(approval),
        terminalState: nil,
        approval: approval
      )
    }

    let phase = string(data["phase"]) ?? "update"
    let activity: AgentRunActivity?
    let eventType: String
    let content: String?
    let toolName: String?
    switch stream {
    case "item" where data["hideFromChannelProgress"]?.boolValue != true:
      let kind = string(data["kind"])
      let isThought = kind == "analysis" || kind == "preamble"
      content = string(data["error"])
        ?? string(data["summary"])
        ?? string(data["progressText"])
      toolName = isThought ? nil : string(data["name"]) ?? kind
      eventType = isThought
        ? "reasoning"
        : (phase == "end" ? "tool_result" : "tool_call")
      activity = AgentRunActivity(
        id: string(data["toolCallId"])
          ?? string(data["itemId"])
          ?? "item-\(sequence ?? 0)",
        kind: isThought ? .thought : .tool,
        phase: phase,
        title: string(data["title"]) ?? (isThought ? "Working" : "Agent activity"),
        detail: string(data["meta"]),
        status: string(data["status"])
          ?? (phase == "end" ? "completed" : "running"),
        toolName: toolName,
        content: content,
        contentIsDelta: false,
        locations: locations(in: [.object(data)]),
        rawPayloadJSON: json(.object(payload))
      )
    case "plan":
      content = string(data["explanation"])
      toolName = nil
      eventType = "plan"
      activity = AgentRunActivity(
        id: "plan",
        kind: .plan,
        phase: phase,
        title: string(data["title"]) ?? "Updated the plan",
        detail: string(data["source"]),
        status: phase == "end" ? "completed" : "running",
        content: content,
        planEntries: planEntries(in: data["steps"]),
        rawPayloadJSON: json(.object(payload))
      )
    case "command_output":
      let exitCode = data["exitCode"]?.intValue
      content = text(data["output"])
      toolName = string(data["name"]) ?? "exec"
      eventType = phase == "end" ? "tool_result" : "tool_call"
      activity = AgentRunActivity(
        id: string(data["toolCallId"])
          ?? string(data["itemId"])
          ?? "command-\(sequence ?? 0)",
        kind: .tool,
        phase: phase,
        title: string(data["title"]) ?? "Ran command",
        detail: string(data["cwd"]),
        status: string(data["status"])
          ?? (phase == "end"
            ? (exitCode == nil || exitCode == 0 ? "completed" : "failed")
            : "running"),
        toolName: toolName,
        content: content,
        contentIsDelta: false,
        rawOutputJSON: json(data["output"]),
        rawPayloadJSON: json(.object(payload))
      )
    case "patch":
      content = string(data["summary"])
      toolName = string(data["name"]) ?? "apply_patch"
      eventType = "tool_result"
      activity = AgentRunActivity(
        id: string(data["toolCallId"])
          ?? string(data["itemId"])
          ?? "patch-\(sequence ?? 0)",
        kind: .tool,
        phase: phase,
        title: string(data["title"]) ?? "Edited files",
        detail: content,
        status: "completed",
        toolName: toolName,
        locations: patchLocations(in: data),
        rawPayloadJSON: json(.object(payload))
      )
    case "compaction":
      let completed = data["completed"]?.boolValue
      content = nil
      toolName = nil
      eventType = "progress"
      activity = AgentRunActivity(
        id: "compaction",
        kind: .progress,
        phase: phase,
        title: phase == "end" && completed == false
          ? "Context compaction failed"
          : "Compacting context",
        detail: data["willRetry"]?.boolValue == true ? "Retrying" : nil,
        status: phase == "end"
          ? (completed == false ? "failed" : "completed")
          : "running",
        rawPayloadJSON: json(.object(payload))
      )
    default:
      content = nil
      toolName = nil
      eventType = stream
      activity = nil
    }
    return Self(
      runID: runID,
      sessionKey: sessionKey,
      sequence: sequence,
      eventType: eventType,
      eventPhase: phase,
      toolName: toolName,
      content: content,
      assistantUpdate: nil,
      activity: activity,
      terminalState: nil,
      approval: nil
    )
  }

  private static func projectChat(
    event: OpenClawGatewayEvent,
    payload: [String: GatewayJSONValue]
  ) -> Self {
    let state = string(payload["state"]) ?? "delta"
    let message = payload["message"]?.objectValue
    let fullText = messageText(message, types: ["text"], fields: ["text"])
    let thought = messageText(
      message,
      types: ["thinking", "reasoning"],
      fields: ["thinking", "text", "content"]
    )
    let deltaText = text(payload["deltaText"])
    let assistantUpdate: AssistantUpdate?
    if let fullText {
      assistantUpdate = .replace(fullText)
    } else if let deltaText, !deltaText.isEmpty {
      assistantUpdate = payload["replace"]?.boolValue == true
        ? .replace(deltaText) : .append(deltaText)
    } else {
      assistantUpdate = nil
    }
    let terminal: TerminalState? = switch state {
    case "final": .completed
    case "aborted": .cancelled(string(payload["errorMessage"]))
    case "error": .failed(
      string(payload["errorMessage"]) ?? "OpenClaw Gateway run failed."
    )
    default: nil
    }
    return Self(
      runID: string(payload["runId"]),
      sessionKey: string(payload["sessionKey"]),
      sequence: sequence(event: event, payload: payload),
      eventType: terminal == nil ? "assistant_delta" : "done",
      eventPhase: state,
      toolName: nil,
      content: fullText ?? deltaText,
      assistantUpdate: assistantUpdate,
      activity: thought.map {
        AgentRunActivity(
          id: "thinking",
          kind: .thought,
          phase: state,
          title: "Thinking",
          status: terminal == nil ? "running" : "completed",
          content: $0,
          contentIsDelta: false,
          rawPayloadJSON: json(.object(payload))
        )
      },
      terminalState: terminal,
      approval: nil
    )
  }

  private static func projectApproval(
    event: OpenClawGatewayEvent,
    payload: [String: GatewayJSONValue]
  ) -> Self? {
    guard let id = string(payload["id"]) else { return nil }
    let request = payload["request"]?.objectValue ?? [:]
    let resolvedDecision = string(payload["decision"])
    let kind = event.name.hasPrefix("plugin.") ? "plugin" : "exec"
    let title = string(request["title"])
      ?? (resolvedDecision == nil
        ? (kind == "plugin" ? "Plugin approval requested" : "Command approval requested")
        : (kind == "plugin" ? "Plugin approval resolved" : "Command approval resolved"))
    let detail = string(request["command"])
      ?? string(request["commandPreview"])
      ?? string(request["description"])
    let approval = Approval(
      id: id,
      kind: kind,
      sessionKey: string(request["sessionKey"]),
      title: title,
      command: detail,
      allowedDecisions: request["allowedDecisions"]?.arrayValue?.compactMap(\.stringValue) ?? [],
      resolvedDecision: resolvedDecision
    )
    return Self(
      runID: string(payload["runId"]),
      sessionKey: approval.sessionKey,
      sequence: sequence(event: event, payload: payload),
      eventType: "approval",
      eventPhase: resolvedDecision == nil ? "requested" : "resolved",
      toolName: kind == "plugin" ? string(request["toolName"]) ?? "plugin" : "exec",
      content: approval.command,
      assistantUpdate: nil,
      activity: approvalActivity(approval),
      terminalState: nil,
      approval: approval
    )
  }

  private static func approvalActivity(_ approval: Approval) -> AgentRunActivity {
    let status: String = switch approval.resolvedDecision {
    case nil: "pending"
    case "deny", "denied", "failed", "unavailable": "failed"
    default: "completed"
    }
    return AgentRunActivity(
      id: "approval:\(approval.id)",
      kind: .tool,
      phase: approval.resolvedDecision == nil ? "approval" : "result",
      title: approval.title,
      detail: approval.command,
      status: status,
      toolName: approval.kind,
      rawInputJSON: approval.command.flatMap { json(.object(["command": .string($0)])) },
      rawOutputJSON: approval.resolvedDecision.flatMap {
        json(.object(["decision": .string($0)]))
      }
    )
  }

  private static func sequence(
    event: OpenClawGatewayEvent,
    payload: [String: GatewayJSONValue]
  ) -> Int? {
    payload["seq"]?.intValue ?? event.sequence
  }

  // Content is lossless; identifiers and labels still use normalized string().
  private static func text(_ value: GatewayJSONValue?) -> String? {
    value?.stringValue
  }

  private static func string(_ value: GatewayJSONValue?) -> String? {
    guard let value = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
          !value.isEmpty else { return nil }
    return value
  }

  private static func messageText(
    _ message: [String: GatewayJSONValue]?,
    types: Set<String>,
    fields: [String]
  ) -> String? {
    if types.contains("text"), let text = text(message?["text"]) { return text }
    let parts = message?["content"]?.arrayValue ?? []
    let text = parts.compactMap { part -> String? in
      guard let object = part.objectValue,
            let type = string(object["type"]), types.contains(type) else { return nil }
      return fields.lazy.compactMap { text(object[$0]) }.first
    }.joined(separator: "\n")
    return text.isEmpty ? nil : text
  }

  private static func json(_ value: GatewayJSONValue?) -> String? {
    guard let value,
          let data = try? JSONEncoder().encode(value) else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static func displayText(_ value: GatewayJSONValue?) -> String? {
    guard let value else { return nil }
    if let text = text(value) { return text }
    if let object = value.objectValue {
      for key in ["content", "text", "message", "output", "summary"] {
        if let result = displayText(object[key]) { return result }
      }
    }
    if let array = value.arrayValue {
      let result = array.compactMap(displayText).joined(separator: "\n")
      if !result.isEmpty { return result }
    }
    return json(value)
  }

  static func toolTitle(
    name: String
  ) -> String {
    let lower = name.lowercased()
    if lower.contains("websearch") || lower == "web_search" { return "Searched the web" }
    if lower.contains("webfetch") || lower.contains("fetch") { return "Read webpage" }
    if lower.contains("toolsearch") { return "Searched for tools" }
    if lower == "read" || lower.contains("readfile") { return "Read file" }
    if lower == "write" || lower.contains("writefile") { return "Wrote file" }
    if lower.contains("edit") || lower.contains("patch") { return "Edited file" }
    if lower.contains("grep") || lower.contains("search") { return "Searched code" }
    if lower.contains("glob") || lower.contains("find") { return "Found files" }
    if lower.contains("bash") || lower.contains("shell") || lower == "exec" { return "Ran command" }
    if lower.contains("task") || lower.contains("agent") { return "Delegated work" }
    return name.replacingOccurrences(of: "_", with: " ").capitalized
  }

  private static func toolDetail(input: GatewayJSONValue?) -> String? {
    guard let object = input?.objectValue else { return displayText(input) }
    for key in ["command", "query", "path", "file_path", "url", "pattern", "description"] {
      if let value = string(object[key]) { return value }
    }
    return nil
  }

  private static func locations(in values: [GatewayJSONValue?]) -> [AgentRunLocation] {
    var paths: [String] = []
    var seen: Set<String> = []
    func collect(_ value: GatewayJSONValue?, depth: Int = 0) {
      guard paths.count < 50, depth < 8, let value else { return }
      if let object = value.objectValue {
        for (key, nested) in object {
          guard paths.count < 50 else { return }
          let lower = key.lowercased()
          if ["path", "file", "file_path", "filepath"].contains(lower),
             let path = string(nested), seen.insert(path).inserted {
            paths.append(path)
          }
          collect(nested, depth: depth + 1)
        }
      } else if let array = value.arrayValue {
        for nested in array {
          guard paths.count < 50 else { return }
          collect(nested, depth: depth + 1)
        }
      }
    }
    values.forEach { collect($0) }
    return paths.map { AgentRunLocation(path: $0) }
  }

  private static func fileChanges(
    in values: [GatewayJSONValue?]
  ) -> [AgentRunFileChange] {
    var order: [String] = []
    var changes: [String: AgentRunFileChange] = [:]
    for value in values {
      guard let value else { continue }
      let container = value.objectValue
      let inheritedPath = string(
        container?["path"] ?? container?["filePath"] ?? container?["file_path"]
      )
      let candidates = container?["changes"]?.arrayValue
        ?? container?["edits"]?.arrayValue
        ?? value.arrayValue
        ?? [value]
      for candidate in candidates {
        guard let object = candidate.objectValue,
              let path = string(
                object["path"] ?? object["filePath"] ?? object["file_path"]
              ) ?? inheritedPath,
              let newText = (object["newText"] ?? object["content"])?.stringValue else {
          continue
        }
        if changes[path] == nil { order.append(path) }
        changes[path] = AgentRunFileChange(
          path: path,
          oldText: object["oldText"]?.stringValue,
          newText: newText,
          unifiedDiff: string(object["unifiedDiff"] ?? object["diff"])
        )
      }
    }
    return order.compactMap { changes[$0] }
  }

  private static func patchLocations(
    in data: [String: GatewayJSONValue]
  ) -> [AgentRunLocation] {
    var seen: Set<String> = []
    return ["added", "modified", "deleted"].flatMap { key in
      data[key]?.arrayValue?.compactMap(\.stringValue) ?? []
    }.filter { seen.insert($0).inserted }.map { AgentRunLocation(path: $0) }
  }

  private static func planEntries(in value: GatewayJSONValue?) -> [AgentRunPlanEntry] {
    (value?.arrayValue ?? []).compactMap(\.stringValue).map {
      AgentRunPlanEntry(content: $0, status: "pending")
    }
  }
}
