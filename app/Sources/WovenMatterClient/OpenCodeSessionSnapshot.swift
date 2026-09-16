import Foundation
import WovenMatterCore

/// Adapt the native service catalog to the same model/thinking controls used
/// by the other harnesses. Provider identity remains part of each model key.
public enum OpenCodeComposerMetadata {
    public static func modelKey(_ model: OpenCodeValue) -> String {
        let id = model["id"].text
        return model["providerID"].text.isEmpty ? id : model["providerID"].text + "/" + id
    }

    public static func metadata(session: OpenCodeValue, models: [OpenCodeValue], defaultModel: OpenCodeValue = .null, hiddenModels: Set<String> = [], commands: [OpenCodeValue] = []) -> LocalACPSessionMetadata {
        let selected = modelKey(session["model"]).isEmpty ? defaultModel : session["model"]
        let key = modelKey(selected)
        let option = models.first { modelKey($0) == key }
        let variants = option?["variants"].array.compactMap { $0["id"].string } ?? []
        var modelMetadata: [String: SessionOptionMetadata] = [:]
        for model in models {
            modelMetadata[modelKey(model)] = SessionOptionMetadata(
                name: model["name"].string,
                description: model["description"].string
            )
        }
        var thinkingMetadata: [String: SessionOptionMetadata] = [:]
        for variant in option?["variants"].array ?? [] {
            guard let id = variant["id"].string else { continue }
            thinkingMetadata[id] = SessionOptionMetadata(
                name: variant["name"].string,
                description: variant["description"].string
            )
        }
        return LocalACPSessionMetadata(sessionKey: session["id"].text,
            model: key.isEmpty ? nil : key,
            thinking: selected["variant"].string ?? (variants.isEmpty ? nil : "default"),
            modelOptions: models.map(modelKey),
            excludedModels: hiddenModels.sorted(),
            thinkingLevels: variants.isEmpty ? [] : ["default"] + variants,
            slashCommands: slashCommands(commands),
            modelOptionMetadata: modelMetadata,
            thinkingOptionMetadata: thinkingMetadata)
    }

    public static func slashCommands(_ commands: [OpenCodeValue]) -> [LocalACPSlashCommand] {
        var seen: Set<String> = []
        return commands.compactMap { command in
            let name = command["name"].text
            guard !name.isEmpty, !name.contains(where: { $0.isWhitespace }),
                  seen.insert(name).inserted else { return nil }
            return LocalACPSlashCommand(name: name, detail: command["description"].string)
        }
    }

    public static func invocation(_ text: String, commands: [OpenCodeValue]) -> (name: String, arguments: String)? {
        guard text.first == "/" else { return nil }
        let body = text.dropFirst()
        let name = String(body.prefix { !$0.isWhitespace })
        guard slashCommands(commands).contains(where: { $0.name == name }) else { return nil }
        return (name, String(body.dropFirst(name.count).drop(while: { $0.isWhitespace })))
    }

    public static func matchesSelection(_ actual: OpenCodeValue, _ expected: OpenCodeValue) -> Bool {
        modelKey(actual) == modelKey(expected)
            && (actual["variant"].string ?? "default") == (expected["variant"].string ?? "default")
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
    public static func activities(_ message: OpenCodeValue, assistantMessageID: String? = nil) -> [AgentRunActivity] {
        let parts = message["content"].array
        let finalTextIndex = parts.lastIndex { $0["type"].text == "text" }
        var cumulativeText = ""
        return parts.enumerated().compactMap { index, part in
            let id = message["id"].text + ":" + (part["id"].string ?? String(index))
            if part["type"].text == "text" {
                let separator = index == finalTextIndex ? "" : "\n\n"
                let segment = part["text"].text + separator
                cumulativeText += segment
                return AgentRunActivity(id: id, kind: .assistant, phase: "boundary", title: "Assistant",
                                        status: "completed", content: segment, contentIsDelta: false,
                                        assistantMessageID: assistantMessageID,
                                        assistantCheckpoint: AssistantTextCheckpoint(cumulativeText), position: index)
            }
            if part["type"].text == "reasoning" {
                return AgentRunActivity(id: id, kind: .thought, title: "Reasoning", content: part["text"].text, position: index)
            }
            guard part["type"].text == "tool" else { return nil }
            let state = part["state"]
            let output = state["output"].string ?? state["content"].array.compactMap { $0["text"].string }.joined(separator: "\n")
            return AgentRunActivity(id: id, kind: .tool, title: state["title"].string ?? part["name"].text,
                                    status: state["status"].string ?? state["type"].string,
                                    toolName: part["name"].text, content: output,
                                    position: index,
                                    rawInputJSON: state["input"].isNull ? nil : state["input"].json,
                                    rawOutputJSON: state.json, rawPayloadJSON: part.json)
        }
    }
}

/// Form conditions follow OpenCode's ordered, cascading visibility rules.
public enum OpenCodeFormAnswers {
    /// Build only active answers. External steps require explicit user
    /// acknowledgement; the server rejects replies that omit that true value.
    public static func reply(fields: [OpenCodeValue], answers: [String: OpenCodeValue]) throws -> OpenCodeValue {
        var result: [String: OpenCodeValue] = [:]
        for field in activeFields(fields, answers: answers) {
            let key = field["key"].text
            let title = field["title"].string ?? key
            var value = answers[key] ?? field["default"]
            if field["type"].text == "external" {
                guard value == .bool(true) else { throw OpenCodeError.message("Complete and confirm \(title).") }
            } else if field["type"].text == "boolean", value.isNull {
                value = .bool(false)
            }
            if ["number", "integer"].contains(field["type"].text), value == .string("") { value = .null }
            if ["number", "integer"].contains(field["type"].text), !value.isNull {
                guard let parsed = value.number ?? Double(value.text), parsed.isFinite else {
                    throw OpenCodeError.message("Enter a number for \(title).")
                }
                guard field["type"].text != "integer" || parsed.rounded() == parsed else {
                    throw OpenCodeError.message("Enter a whole number for \(title).")
                }
                if let minimum = field["minimum"].number, parsed < minimum { throw OpenCodeError.message("\(title) must be at least \(minimum).") }
                if let maximum = field["maximum"].number, parsed > maximum { throw OpenCodeError.message("\(title) must be at most \(maximum).") }
                value = .number(parsed)
            }
            if field["required"].bool && (value.isNull || value == .string("") || value == .array([])) {
                throw OpenCodeError.message("Complete \(title).")
            }
            if !value.isNull { result[key] = value }
        }
        return .object(result)
    }

    public static func activeFields(_ fields: [OpenCodeValue], answers: [String: OpenCodeValue]) -> [OpenCodeValue] {
        var activeAnswers: [String: OpenCodeValue] = [:]
        return fields.filter { field in
            let visible = field["when"].array.allSatisfy { condition in
                guard let answer = activeAnswers[condition["key"].text], !answer.isNull else { return false }
                let matches: Bool
                if case .array(let values) = answer { matches = values.contains(condition["value"]) }
                else { matches = answer == condition["value"] }
                return condition["op"].text == "neq" ? !matches : matches
            }
            if visible {
                let key = field["key"].text
                var value = answers[key] ?? field["default"]
                if value.isNull, field["type"].text == "boolean" { value = .bool(false) }
                if ["number", "integer"].contains(field["type"].text), let text = value.string {
                    if let number = Double(text), number.isFinite { value = .number(number) }
                    else { value = .null }
                }
                if !value.isNull { activeAnswers[key] = value }
            }
            return visible
        }
    }
}
