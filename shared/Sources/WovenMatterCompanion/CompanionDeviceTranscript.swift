import Foundation
import CryptoKit

/// Rebuilds display history from the native SDK snapshot, including conversations
/// saved before structured rendering existed. Tool results are never chat messages.
public enum CompanionDeviceTranscript {
  public static func project(snapshot: [String: Any], conversationID: String,
                             activeRunID: String? = nil, runStatus: String = "completed") -> CompanionTranscript {
    var messages: [CompanionMessage] = []
    var activities: [CompanionActivity] = []
    var runs: [CompanionTranscriptRun] = []
    var runID = stableRunID(conversationID + "-initial")
    var sequence: Int64 = 0
    var callIndexes: [String: Int] = [:]
    var removedMessageIDs: [String] = []

    func ensureRun(at date: String?) {
      if !runs.contains(where: { $0.id == runID }) {
        runs.append(.init(id: runID, status: "completed", startedAt: date))
      }
    }
    func activity(_ id: String, kind: String, name: String, content: String? = nil,
                  input: Any? = nil, output: Any? = nil, date: String?, status: String, transient: Bool = false) -> CompanionActivity {
      var projection: [String: Any] = ["id": id, "kind": kind, "title": name, "status": status,
        "position": sequence, "locations": [], "changes": [], "planEntries": []]
      if kind == "tool" { projection["toolName"] = name }
      projection["content"] = content
      projection["rawInputJSON"] = input.flatMap(json)
      projection["rawOutputJSON"] = output.flatMap(json)
      if name == "subagent", let input = input as? [String: Any] {
        projection["subagents"] = [["id": id, "name": input["name"] as? String ?? "Agent",
          "task": input["task"] as? String ?? "", "state": status]]
      }
      return .init(id: id, runID: runID, title: name, status: status,
        projectionJSON: json(projection), isTransient: transient ? true : nil, sequence: sequence, createdAt: date)
    }
    func updateResult(_ message: [String: Any], date: String?) {
      let callID = message["toolCallId"] as? String ?? message["toolCallID"] as? String ?? ""
      let key = runID + ":" + callID
      let status = message["isError"] as? Bool == true ? "failed" : "completed"
      let content = text(message["content"])
      if let index = callIndexes[key] {
        var value = activities[index]
        var projection = value.projectionJSON.flatMap(object) ?? [:]
        projection["rawOutputJSON"] = json(message)
        projection["content"] = content
        projection["status"] = status
        if let details = message["details"] as? [String: Any] {
          for field in ["changes", "locations", "planEntries", "subagents"] {
            if let value = details[field] as? [[String: Any]] { projection[field] = value }
          }
        }
        if var children = projection["subagents"] as? [[String: Any]], !children.isEmpty {
          children[0]["state"] = status; children[0]["result"] = content
          let detail = message["details"] as? [String: Any]
          children[0]["nativeConversationID"] = detail?["nativeConversationID"].map { String(describing: $0) }
          projection["subagents"] = children
        }
        // Rebuild published pages from their native call/result pair. This keeps
        // device-owned replies visible after reopening and journal replication.
        let toolName = projection["toolName"] as? String
        let response = object(content)
        let result = response?["htmlRender"] == nil ? response?["result"] as? [String: Any] : response
        let input = (projection["rawInputJSON"] as? String).flatMap(object)
        var authoredPage: [String: Any]?
        if toolName == "woven_html_render", var input { input["action"] = "render"; authoredPage = input }
        else if let arguments = input?["arguments"] as? [String],
                let command = try? WovenMatterToolCommand(["html"] + arguments), let raw = command.options["json"] { authoredPage = object(raw) }
        if status == "completed", ["wovenmatter_html", "woven_html_render"].contains(toolName ?? ""),
           response?["success"] as? Bool != false,
           let reference = result?["htmlRender"] as? [String: Any],
           let referenceID = reference["id"] as? String, UUID(uuidString: referenceID) != nil,
           let title = reference["title"] as? String, title.utf8.count <= 800,
           let height = reference["height"] as? Int, (80...2000).contains(height),
           let page = ((message["details"] as? [String: Any])?["wovenHTMLPage"] as? [String: Any]) ?? authoredPage,
           page["action"] as? String == "render", let html = page["html"] as? String, html.utf8.count <= ConversationHTMLResources.maximumPageBytes {
          projection["kind"] = "activity"; projection["toolName"] = "html_render"
          projection["title"] = title; projection["content"] = nil
          projection["htmlRender"] = reference
          projection["rawOutputJSON"] = json(["html": html, "title": title, "height": height])
          value.title = title
        }
        value.status = status; value.completedAt = date; value.projectionJSON = json(projection)
        activities[index] = value
      } else {
        // A paged/legacy snapshot can retain a result without its originating call.
        let id = key.isEmpty ? "orphan-\(sequence)" : key
        activities.append(activity(id, kind: "tool", name: message["toolName"] as? String ?? "Tool result",
          content: content, output: message, date: date, status: status))
      }
    }
    func append(_ message: [String: Any], id: String, streaming: Bool = false) {
      guard let role = message["role"] as? String else { return }
      let date = timestamp(message["timestamp"])
      if role == "user" {
        runID = stableRunID(conversationID + "-turn-" + id)
        ensureRun(at: date)
        messages.append(.init(id: id, conversationID: conversationID, runID: runID,
          role: role, content: WorkspaceGoal.displayPrompt(text(message["content"])), createdAt: date ?? "", sequence: sequence))
        sequence += 1
        return
      }
      ensureRun(at: date)
      if let index = runs.firstIndex(where: { $0.id == runID }), let date { runs[index].completedAt = date }
      if role == "toolResult" || role == "tool" {
        updateResult(message, date: date); sequence += 1
        removedMessageIDs.append(id)
        return
      }
      let blocks = (message["content"] as? [[String: Any]]) ?? (message["content"] as? String).map { [["type":"text", "text":$0]] } ?? []
      var textIndex = 0
      for (index, block) in blocks.enumerated() {
        let blockID = id + "-\(index)"
        switch block["type"] as? String {
        case "text":
          if let content = block["text"] as? String, !content.isEmpty {
            messages.append(.init(id: textIndex == 0 ? id : id + "-text-\(textIndex)", conversationID: conversationID, runID: runID, role: role,
              content: content, status: streaming ? "streaming" : (message["stopReason"] as? String ?? "completed"),
              createdAt: date ?? "", sequence: sequence))
            textIndex += 1
          }
        case "thinking":
          if let content = block["thinking"] as? String, !content.isEmpty {
            activities.append(activity(blockID, kind: "thought", name: "Thinking", content: content,
              date: date, status: streaming ? "running" : "completed", transient: streaming))
          }
        case "toolCall":
          let callID = block["id"] as? String ?? blockID
          let key = runID + ":" + callID
          callIndexes[key] = activities.count
          activities.append(activity(key, kind: "tool", name: block["name"] as? String ?? "Tool",
            input: block["arguments"], date: date, status: activeRunID == nil ? "interrupted" : "running", transient: streaming))
        default: break
        }
        sequence += 1
      }
      if textIndex == 0, blocks.contains(where: { $0["type"] as? String == "toolCall" }) {
        removedMessageIDs.append(id)
      }
    }

    for (entryIndex, entry) in (snapshot["entries"] as? [[String: Any]] ?? []).enumerated() {
      let nativeID = entry["id"].map { String(describing: $0) } ?? String(entryIndex)
      for (messageIndex, message) in (entry["model"] as? [[String: Any]] ?? []).enumerated() {
        append(message, id: "\(conversationID)-\(nativeID)-\(messageIndex)")
      }
    }
    if let generation = snapshot["generation"] as? [String: Any], let message = generation["message"] as? [String: Any] {
      append(message, id: conversationID + "-streaming", streaming: true)
    }
    // Live slot details survive an app reopen before a result entry is committed.
    for slot in snapshot["tools"] as? [[String: Any]] ?? [] {
      guard let callID = slot["callId"] as? String,
            let index = callIndexes[runID + ":" + callID], activities[index].completedAt == nil else { continue }
      var projection = activities[index].projectionJSON.flatMap(object) ?? [:]
      projection["rawPayloadJSON"] = json(slot)
      if let update = slot["update"] as? [String: Any] { projection["content"] = text(update["content"]) }
      activities[index].projectionJSON = json(projection)
    }
    for index in activities.indices where activities[index].status == "running" && activities[index].runID != runs.last?.id {
      activities[index].status = "interrupted"
      if var projection = activities[index].projectionJSON.flatMap(object) {
        projection["status"] = "interrupted"; activities[index].projectionJSON = json(projection)
      }
    }
    if !runs.isEmpty {
      runs[runs.count - 1].status = activeRunID != nil ? "running" : normalizedRunStatus(runStatus)
      if activeRunID != nil { runs[runs.count - 1].completedAt = nil }
    }
    return .init(conversationID: conversationID, messages: messages, activities: activities,
      activeRunID: activeRunID, runs: runs, removedMessageIDs: removedMessageIDs.isEmpty ? nil : removedMessageIDs)
  }

  // Device lifecycle labels are private runtime state. Display/sync uses the
  // same terminal run vocabulary as the desktop, including after a stop.
  private static func normalizedRunStatus(_ value: String) -> String {
    switch value {
    case "ready", "idle", "completed": "completed"
    case "stopping", "stopped", "cancelled": "cancelled"
    case "queued", "running", "failed", "interrupted": value
    default: "interrupted"
    }
  }

  // The federation protocol requires UUID run identities. A stable digest keeps
  // the same native turn identity across reopen, replay, and library sync.
  private static func stableRunID(_ key: String) -> String {
    var bytes = Array(SHA256.hash(data: Data(("wovenmatter.native-turn.v1:" + key).utf8)).prefix(16))
    bytes[6] = (bytes[6] & 0x0f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
      bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString.lowercased()
  }

  private static func text(_ value: Any?) -> String {
    if let text = value as? String { return text }
    return (value as? [[String: Any]] ?? []).compactMap { block in
      block["type"] as? String == "text" ? block["text"] as? String : nil
    }.joined(separator: "\n")
  }
  private static func timestamp(_ value: Any?) -> String? {
    if let value = value as? String { return value }
    guard let value = (value as? NSNumber)?.doubleValue else { return nil }
    let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
    return formatter.string(from: Date(timeIntervalSince1970: value / 1000))
  }
  private static func json(_ value: Any) -> String? {
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }
  private static func object(_ value: String) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: Data(value.utf8))) as? [String: Any]
  }
}
