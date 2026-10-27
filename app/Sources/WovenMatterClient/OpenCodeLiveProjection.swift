import Foundation

/// The general event stream is volatile. Keep its text separate from HTTP
/// history so a refresh cannot append an already observed delta a second time.
/// Only a start event establishes a delta baseline; reconnects recover from
/// authoritative history or an ended event's complete text.
public struct OpenCodeLiveProjection: Sendable {
    private struct Block: Sendable {
        let messageID: String
        let kind: String
        let ordinal: Int
        let created: OpenCodeValue
        var text: String
        var streaming: Bool
        var tool: OpenCodeValue? = nil
    }
    private var blocks: [Block] = []
    private var settled = false
    public init() {}

    @discardableResult
    public mutating func receive(_ event: OpenCodeValue, sessionID: String, snapshot: OpenCodeSessionSnapshot? = nil) -> Bool {
        let data = event["data"], type = event["type"].text
        if type.hasPrefix("session.tool.") { return receiveTool(event, sessionID: sessionID, snapshot: snapshot) }
        guard data["sessionID"].text == sessionID,
              ["session.text.started", "session.text.delta", "session.text.ended",
               "session.reasoning.started", "session.reasoning.delta", "session.reasoning.ended"].contains(type),
              let messageID = data["assistantMessageID"].string, !messageID.isEmpty,
              let number = data["ordinal"].number, number >= 0, number < Double(Int.max), number.rounded() == number else { return false }
        let kind = type.hasPrefix("session.text.") ? "text" : "reasoning"
        let ordinal = Int(number)
        if settled && type.hasSuffix(".started") { blocks.removeAll(); settled = false }
        let existing = blocks.firstIndex { $0.messageID == messageID && $0.kind == kind && $0.ordinal == ordinal }
        if type.hasSuffix(".delta") {
            guard let existing, blocks[existing].streaming, let delta = data["delta"].string else { return false }
            blocks[existing].text += delta
        } else if type.hasSuffix(".ended") {
            guard let text = data["text"].string else { return false }
            if let existing { blocks[existing].text = text; blocks[existing].streaming = false }
            else { blocks.append(Block(messageID: messageID, kind: kind, ordinal: ordinal,
                created: event["created"], text: text, streaming: false)) }
        } else {
            // Duplicate starts cannot erase text already emitted for this block.
            guard existing == nil else { return false }
            blocks.append(Block(messageID: messageID, kind: kind, ordinal: ordinal,
                created: event["created"], text: "", streaming: true))
        }
        return true
    }

    public mutating func finish() {
        settled = true
        for index in blocks.indices {
            blocks[index].streaming = false
            if var tool = blocks[index].tool, ["streaming", "running"].contains(tool["state"]["status"].text) {
                tool["state"]["status"] = "interrupted"
                blocks[index].tool = tool
            }
        }
    }

    private mutating func receiveTool(_ event: OpenCodeValue, sessionID: String, snapshot: OpenCodeSessionSnapshot?) -> Bool {
        let data = event["data"], type = event["type"].text
        guard data["sessionID"].text == sessionID,
              let messageID = data["assistantMessageID"].string, !messageID.isEmpty,
              let id = data["id"].string, !id.isEmpty else { return false }
        var existing = blocks.firstIndex { $0.messageID == messageID && $0.tool?["id"].text == id }
        if type == "session.tool.input.started" {
            if settled { blocks.removeAll(); settled = false; existing = nil }
            guard existing == nil, let name = data["name"].string else { return false }
            let tool: OpenCodeValue = ["id": .string(id), "type": "tool", "name": .string(name),
                "time": ["created": event["created"]], "state": ["status": "streaming", "input": ""]]
            blocks.append(Block(messageID: messageID, kind: "tool", ordinal: 0, created: event["created"],
                text: "", streaming: true, tool: tool))
            return true
        }
        if existing == nil, type != "session.tool.input.delta",
           let message = snapshot?.messages.first(where: { $0["id"].text == messageID }),
           let tool = message["content"].array.first(where: { $0["type"].text == "tool" && $0["id"].text == id }) {
            existing = blocks.count
            blocks.append(Block(messageID: messageID, kind: "tool", ordinal: 0, created: message["time"]["created"],
                text: "", streaming: ["streaming", "running"].contains(tool["state"]["status"].text), tool: tool))
        }
        guard let existing, var tool = blocks[existing].tool else { return false }
        switch type {
        case "session.tool.input.delta":
            guard tool["state"]["status"].text == "streaming", let delta = data["delta"].string else { return false }
            tool["state"]["input"] = .string(tool["state"]["input"].text + delta)
        case "session.tool.input.ended":
            guard let text = data["text"].string else { return false }
            tool["state"]["input"] = .string(text)
        case "session.tool.called":
            tool["state"]["status"] = "running"
            tool["state"]["input"] = data["input"]
            tool["time"]["ran"] = event["created"]
        case "session.tool.progress":
            tool["state"]["metadata"] = data["metadata"]
        case "session.tool.success", "session.tool.failed":
            tool["state"]["status"] = type.hasSuffix("success") ? "completed" : "error"
            for key in ["content", "error", "metadata"] where !data[key].isNull { tool["state"][key] = data[key] }
            tool["time"]["completed"] = event["created"]
            blocks[existing].streaming = false
        default: return false
        }
        blocks[existing].tool = tool
        return true
    }

    /// Completed native messages supersede volatile content, including edits or
    /// corrections. A live block otherwise replaces its matching native part.
    public mutating func reconcile(_ snapshot: OpenCodeSessionSnapshot, canSettle: Bool = true) {
        if settled && !snapshot.active && canSettle { blocks.removeAll(); settled = false; return }
        let completed = Set(snapshot.messages.filter { !$0["time"]["completed"].isNull }.map { $0["id"].text })
        blocks.removeAll { block in
            if completed.contains(block.messageID) { return true }
            guard let tool = block.tool,
                  let message = snapshot.messages.first(where: { $0["id"].text == block.messageID }),
                  let canonical = message["content"].array.first(where: { $0["type"].text == "tool" && $0["id"] == tool["id"] }) else { return false }
            return ["completed", "error"].contains(canonical["state"]["status"].text)
        }
    }

    public func applying(to snapshot: OpenCodeSessionSnapshot) -> OpenCodeSessionSnapshot {
        var result = snapshot
        if settled { result.active = false }
        for (blockOffset, block) in blocks.enumerated() {
            let messageIndex: Int
            if let index = result.messages.firstIndex(where: { $0["id"].text == block.messageID }) { messageIndex = index }
            else {
                messageIndex = result.messages.count
                result.messages.append(["id": .string(block.messageID), "type": "assistant",
                    "time": ["created": block.created], "content": .array([])])
            }
            var message = result.messages[messageIndex], parts = message["content"].array
            // A canonical snapshot may expose a later tool before an earlier
            // text block is committed. Anchor missing live parts before the
            // next known native part instead of reversing their event order.
            let insertion = blocks.dropFirst(blockOffset + 1).lazy.filter { $0.messageID == block.messageID }.compactMap { next -> Int? in
                if let tool = next.tool { return parts.firstIndex { $0["type"].text == "tool" && $0["id"] == tool["id"] } }
                let matches = parts.indices.filter { parts[$0]["type"].text == next.kind }
                return next.ordinal < matches.count ? matches[next.ordinal] : nil
            }.first ?? parts.count
            if let tool = block.tool {
                if let index = parts.firstIndex(where: { $0["type"].text == "tool" && $0["id"] == tool["id"] }) { parts[index] = tool }
                else { parts.insert(tool, at: insertion) }
                message["content"] = .array(parts)
                result.messages[messageIndex] = message
                if block.streaming { result.active = true }
                continue
            }
            let matching = parts.indices.filter { parts[$0]["type"].text == block.kind }
            let index: Int
            if block.ordinal < matching.count { index = matching[block.ordinal] }
            else {
                // Do not guess placement when reconnecting in the middle of a
                // message whose earlier same-kind parts are not available yet.
                guard block.ordinal == matching.count else { continue }
                index = insertion
                parts.insert(["type": .string(block.kind)], at: insertion)
            }
            parts[index]["text"] = .string(block.text)
            parts[index]["_wovenStreaming"] = .bool(block.streaming)
            message["content"] = .array(parts)
            result.messages[messageIndex] = message
            if block.streaming { result.active = true }
        }
        return result
    }
}
