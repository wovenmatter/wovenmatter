import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Rebuilds display history from the native SDK snapshot. Tool results are
/// never chat messages.
public enum DeviceTranscript {
  /// The run IDs a conversation's stored history already uses: the run each
  /// user message started, and the run of anything before the first user
  /// message. A turn's run ID is derived once, the first time the turn is
  /// projected. From then on the stored ID is the turn's identity: it names
  /// the run's row and is part of its tool activities' IDs on every device,
  /// so a projection is given it back and never works it out again.
  public struct StoredRuns: Equatable, Sendable {
    /// The run of rows that precede the first user message, if any are stored.
    public var initial: String?
    /// User message ID → the run that message started.
    public var turns: [String: String]
    public init(initial: String? = nil, turns: [String: String] = [:]) { self.initial = initial; self.turns = turns }

    /// Reads them from the transcript stored for the conversation; nil is a
    /// conversation with nothing stored yet.
    public init(_ stored: LibraryTranscript?) {
      self.init()
      guard let stored else { return }
      for message in stored.messages where message.role == "user" {
        if let runID = message.runID { turns[message.id] = runID }
      }
      let started = Set(turns.values)
      initial = stored.runs?.first { !started.contains($0.id) }?.id
        ?? stored.messages.lazy.compactMap(\.runID).first { !started.contains($0) }
        ?? stored.activities.first { !started.contains($0.runID) }?.runID
    }

    /// These runs, with any turn they do not hold taken from `other`: a second
    /// stored copy of the same conversation.
    public func filling(from other: StoredRuns) -> StoredRuns {
      StoredRuns(initial: initial ?? other.initial, turns: turns.merging(other.turns) { own, _ in own })
    }
  }

  /// `storedRuns` is what the conversation's stored history already holds
  /// (`StoredRuns(storedTranscript)`). Its turns keep their run IDs; only a
  /// turn that is not stored yet gets a new one.
  public static func project(snapshot: [String: Any], conversationID: String, storedRuns: StoredRuns,
                             activeRunID: String? = nil, runStatus: String = "completed") -> LibraryTranscript {
    var messages: [LibraryMessage] = []
    var activities: [LibraryActivity] = []
    var runs: [LibraryTranscriptRun] = []
    var runID = storedRuns.initial ?? newRunID(conversationID + "-initial")
    var sequence: Int64 = 0
    var callIndexes: [String: Int] = [:]
    var removedMessageIDs: [String] = []

    func ensureRun(at date: String?) {
      if !runs.contains(where: { $0.id == runID }) {
        runs.append(.init(id: runID, status: "completed", startedAt: date))
      }
    }
    func activity(_ id: String, kind: String, name: String, content: String? = nil,
                  input: Any? = nil, output: Any? = nil, date: String?, status: String, transient: Bool = false) -> LibraryActivity {
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
        var authoredPage = (projection["rawInputJSON"] as? String).flatMap(object)
        authoredPage?["action"] = "render"
        if status == "completed", projection["toolName"] as? String == "woven_html_render",
           let reference = object(content)?["htmlRender"] as? [String: Any],
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
        // A paged snapshot can hold a result without the call that started it.
        let id = key.isEmpty ? "orphan-\(sequence)" : key
        activities.append(activity(id, kind: "tool", name: message["toolName"] as? String ?? "Tool result",
          content: content, output: message, date: date, status: status))
      }
    }
    func append(_ message: [String: Any], id: String, streaming: Bool = false) {
      guard let role = message["role"] as? String else { return }
      let date = timestamp(message["timestamp"])
      if role == "user" {
        runID = storedRuns.turns[id] ?? newRunID(conversationID + "-turn-" + id)
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

  // Run identities are UUIDs. A turn that is not stored yet gets one from a
  // digest of its conversation and user message, so two projections of the
  // same new turn before either is stored still agree.
  private static func newRunID(_ key: String) -> String {
    var bytes = Array(SHA256.hash(data: Data(("wovenmatter.native-turn:" + key).utf8)).prefix(16))
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
