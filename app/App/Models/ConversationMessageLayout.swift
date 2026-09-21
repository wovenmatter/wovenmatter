import Foundation

/// Direct children of the conversation's lazy stack. A long formatted reply
/// must not be one large layout/accessibility subtree when it enters view.
struct ConversationMessageLayout {
    // Small groups bound layout/focus work while avoiding a lazy-row wrapper
    // for every short paragraph. Parsed lists, tables and code stay atomic.
    static let maximumMarkdownBlocksPerRow = 4

    struct Row: Identifiable, Equatable, Sendable {
        enum Content: Equatable, Sendable {
            case message
            case markdownBlocks(range: Range<Int>, totalCount: Int)
            case fileChanges
            case media(index: Int)
        }

        let messageID: String
        let content: Content

        var id: String {
            switch content {
            case .message: messageID
            case .markdownBlocks(let range, _):
                range.lowerBound == 0 ? messageID : "\(messageID):markdown:\(range.lowerBound)"
            case .fileChanges: "\(messageID):files"
            case .media(let index): "\(messageID):media:\(index)"
            }
        }

        var isFirstMessagePart: Bool {
            switch content {
            case .message: true
            case .markdownBlocks(let range, _): range.lowerBound == 0
            default: false
            }
        }

        var isLastMessagePart: Bool {
            switch content {
            case .message: true
            case .markdownBlocks(let range, let totalCount): range.upperBound == totalCount
            case .fileChanges, .media: false
            }
        }

        var spacingBefore: Double {
            // The card adds its own gap only when it has visible changes.
            if case .fileChanges = content { return 0 }
            if case .markdownBlocks(let range, _) = content, range.lowerBound > 0 { return 14 }
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
            // Anchor each group to its first block ordinal. Streaming grows
            // its tail in place, and older messages cannot renumber its IDs.
            let count = document.blocks.count
            rows = stride(from: 0, to: count, by: maximumMarkdownBlocksPerRow).map { start in
                Row(messageID: messageID, content: .markdownBlocks(
                    range: start..<min(start + maximumMarkdownBlocksPerRow, count), totalCount: count
                ))
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
