import Foundation
import WovenMatterCore

public struct OpenCodeSessionLink: Codable, Equatable, Sendable {
    public let conversationID: String
    public let connectionID: String
    public let sessionID: String
    public init(conversationID: String, connectionID: String, sessionID: String) {
        self.conversationID = conversationID; self.connectionID = connectionID; self.sessionID = sessionID
    }
}

public struct OpenCodeSessionSnapshot: Codable, Equatable, Sendable {
    public var info: OpenCodeValue = .null
    public var messages: [OpenCodeValue] = []
    public var permissions: [OpenCodeValue] = []
    public var forms: [OpenCodeValue] = []
    public var inbox: [OpenCodeValue] = []
    public var active = false
    public var cursor: Int64?
    public var olderCursor: String?
    public init() {}

    /// Inputs are in server sequence order. Timestamps and IDs are not ordering keys.
    /// A refreshed tail replaces everything after its first overlapping message,
    /// including messages removed by a revert from another client.
    public mutating func mergeMessages(_ incoming: [OpenCodeValue], replace: Bool = false, older: Bool = false) {
        let incomingIDs = Set(incoming.map { $0["id"].text })
        var prefix: [OpenCodeValue] = []
        if !replace, !older, let anchor = messages.firstIndex(where: { incomingIDs.contains($0["id"].text) }) {
            prefix = Array(messages.prefix(anchor))
        }
        let combined = older ? incoming + messages : prefix + incoming
        var seen: Set<String> = []
        messages = combined.filter { !$0["id"].text.isEmpty && seen.insert($0["id"].text).inserted }
    }
    public func containsInput(_ id: String) -> Bool {
        messages.contains { $0["id"].text == id } || inbox.contains { $0["id"].text == id }
    }
    public static func text(_ message: OpenCodeValue) -> String {
        switch message["type"].text {
        case "assistant":
            let text = message["content"].array.filter { $0["type"].text == "text" }.map { $0["text"].text }.joined(separator: "\n\n")
            if !message["error"].isNull { return text + "\n\n" + (message["error"]["message"].string ?? "OpenCode reported an execution error.") }
            return text
        case "user", "synthetic", "system": return message["text"].text
        case "shell": return "$ " + message["command"].text + "\n" + (message["output"]["output"].string ?? message["output"].text)
        case "skill": return "Activated skill: " + message["skill"].text
        case "compaction": return "Context compacted\n" + message["summary"].text
        case "agent": return "Agent: " + message["agent"].text
        case "model": return "Model: " + message["model"]["id"].text
        case "location": return "Workspace: " + message["location"]["directory"].text
        default: return ""
        }
    }
    public static func activities(_ message: OpenCodeValue) -> [AgentRunActivity] {
        message["content"].array.enumerated().compactMap { index, part in
            let id = message["id"].text + ":" + (part["id"].string ?? String(index))
            if part["type"].text == "reasoning" {
                return AgentRunActivity(id: id, kind: .thought, title: "Reasoning", content: part["text"].text)
            }
            guard part["type"].text == "tool" else { return nil }
            let state = part["state"]
            let output = state["output"].string ?? state["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
            return AgentRunActivity(id: id, kind: .tool, title: state["title"].string ?? part["name"].text,
                                    status: state["status"].string ?? state["type"].string,
                                    toolName: part["name"].text, content: output,
                                    rawInputJSON: state["input"].isNull ? nil : state["input"].json,
                                    rawOutputJSON: state.json, rawPayloadJSON: part.json)
        }
    }
}
