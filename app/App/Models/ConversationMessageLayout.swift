import Foundation

/// Direct children of the conversation's lazy stack. A long formatted reply
/// must not be one large layout/accessibility subtree when it enters view.
struct ConversationMessageLayout {
    struct Row: Identifiable, Equatable, Sendable {
        enum Content: Equatable, Sendable {
            case message
            case markdownBlock(index: Int, count: Int)
            case fileChanges
            case media(index: Int)
        }

        let messageID: String
        let content: Content

        var id: String {
            switch content {
            case .message, .markdownBlock(index: 0, count: _): messageID
            case .markdownBlock(let index, _): "\(messageID):markdown:\(index)"
            case .fileChanges: "\(messageID):files"
            case .media(let index): "\(messageID):media:\(index)"
            }
        }

        var isFirstMessagePart: Bool {
            switch content {
            case .message, .markdownBlock(index: 0, count: _): true
            default: false
            }
        }

        var isLastMessagePart: Bool {
            switch content {
            case .message: true
            case .markdownBlock(let index, let count): index == count - 1
            case .fileChanges, .media: false
            }
        }

        var spacingBefore: Double {
            // The card adds its own gap only when it has visible changes.
            if case .fileChanges = content { return 0 }
            if case .markdownBlock(let index, _) = content, index > 0 { return 14 }
            return 32
        }
    }

    static func rows(
        messageID: String,
        role: String,
        content: String,
        displayedBody: String,
        failedRunError: String?,
        document: ConversationMarkdownDocument?,
        mediaCount: Int
    ) -> [Row] {
        var rows: [Row]
        if role != "user", role != "system", let document, !document.blocks.isEmpty,
           showsAssistantBody(content: content, displayedBody: displayedBody, failedRunError: failedRunError) {
            // Ordinals preserve the existing Markdown block identity policy.
            // Streaming edits replace the tail in place; prepending older
            // messages cannot renumber any existing message's blocks.
            rows = document.blocks.indices.map {
                Row(messageID: messageID, content: .markdownBlock(index: $0, count: document.blocks.count))
            }
        } else {
            rows = [Row(messageID: messageID, content: .message)]
        }
        if role != "user", role != "system" {
            // Keep footer state attached to the message, never its streaming
            // last block. Empty cards remain zero-height lazy rows.
            rows.append(Row(messageID: messageID, content: .fileChanges))
        }
        rows += (0..<max(0, mediaCount)).map { Row(messageID: messageID, content: .media(index: $0)) }
        return rows
    }

    static func showsAssistantBody(content: String, displayedBody: String, failedRunError: String?) -> Bool {
        guard !displayedBody.isEmpty else { return false }
        guard let failedRunError else { return true }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
            != failedRunError.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
