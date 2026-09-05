import Foundation
import WovenMatterCore

/// The same transcript prefix used for attached chats, without rendering history
/// after the prefix is full or retaining a complete concatenated transcript.
enum DashboardConversationReferencePreview {
    static func make(messages: [WorkspaceMessageRecord], limit: Int) -> String {
        guard limit > 0 else { return "" }
        let prefixLimit = limit == Int.max ? limit : limit + 1
        var result = ""
        for (index, message) in messages.enumerated() {
            if index > 0 { result.append("\n\n") }
            result.append(message.role.capitalized)
            result.append(": ")
            let value = message.role == "assistant"
                ? RemoteNoteEditEnvelope.redactingEnvelopes(in: message.content)
                : message.content
            // One extra character lets the complete result account for grapheme
            // boundaries, including a combining mark after the role separator.
            result.append(contentsOf: value.prefix(prefixLimit))
            // Keep an exactly full prefix until the next separator is appended:
            // a final CR can combine with that separator's first LF.
            if result.count > limit { return String(result.prefix(limit)) }
        }
        return String(result.prefix(limit))
    }
}
