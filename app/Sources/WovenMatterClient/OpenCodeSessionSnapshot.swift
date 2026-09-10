import Foundation
import WovenMatterCore

/// Adapt the native service catalog to the same model/thinking controls used
/// by the other harnesses. Provider identity remains part of each model key.
public enum OpenCodeComposerMetadata {
    public static func modelKey(_ model: OpenCodeValue) -> String {
        let id = model["id"].text
        return model["providerID"].text.isEmpty ? id : model["providerID"].text + "/" + id
    }

    public static func metadata(session: OpenCodeValue, models: [OpenCodeValue]) -> LocalACPSessionMetadata {
        let selected = session["model"]
        let key = modelKey(selected)
        let option = models.first { modelKey($0) == key }
        let variants = option?["variants"].array.compactMap { $0["id"].string } ?? []
        return LocalACPSessionMetadata(sessionKey: session["id"].text,
            model: key.isEmpty ? nil : key,
            thinking: selected["variant"].string ?? (variants.isEmpty ? nil : "default"),
            modelOptions: models.map(modelKey),
            thinkingLevels: variants.isEmpty ? [] : ["default"] + variants)
    }

    public static func selection(model key: String, thinking: String? = nil, models: [OpenCodeValue]) throws -> OpenCodeValue {
        guard let option = models.first(where: { modelKey($0) == key }) else {
            throw OpenCodeError.message("This OpenCode model is no longer available. Refresh the conversation and choose another model.")
        }
        var selected: OpenCodeValue = ["id": option["id"], "providerID": option["providerID"]]
        if let thinking, thinking != "default" {
            guard option["variants"].array.contains(where: { $0["id"].string == thinking }) else {
                throw OpenCodeError.message("This thinking level is not available for the selected OpenCode model.")
            }
            selected["variant"] = .string(thinking)
        }
        return ["model": selected]
    }
}

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
    public static func presentsMessage(_ message: OpenCodeValue) -> Bool {
        // Configuration events remain in the recovery snapshot, but are not
        // empty system bubbles in the conversation. Assistant placeholders
        // remain visible while text or tool activity is arriving.
        message["type"].text == "assistant" || !text(message).isEmpty || !message["files"].array.isEmpty
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
