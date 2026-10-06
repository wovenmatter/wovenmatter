import Foundation

/// Direct children of the conversation's lazy stack. Each response owns one
/// native text view so selection can span its complete formatted content.
struct ConversationMessageLayout {
    struct Row: Identifiable, Equatable, Sendable {
        enum Content: Equatable, Sendable {
            case message
            case fileChanges
            case media(index: Int)
        }

        let messageID: String
        let content: Content

        var id: String {
            switch content {
            case .message: messageID
            case .fileChanges: "\(messageID):files"
            case .media(let index): "\(messageID):media:\(index)"
            }
        }

        var isFirstMessagePart: Bool {
            switch content {
            case .message: true
            default: false
            }
        }

        var isLastMessagePart: Bool {
            switch content {
            case .message: true
            case .fileChanges, .media: false
            }
        }

        var spacingBefore: Double {
            // The card adds its own gap only when it has visible changes.
            if case .fileChanges = content { return 0 }
            return 32
        }
    }

    static func rows(
        messageID: String,
        role: String,
        mediaCount: Int
    ) -> [Row] {
        var rows = [Row(messageID: messageID, content: .message)]
        if role != "user", role != "system" {
            // Keep footer state stable while the response streams.
            // Empty cards remain zero-height lazy rows.
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

/// Running time and failures stay visible independently of the optional activity disclosure.
struct ConversationWorkTranscriptPresentation {
    let hasVisibleActivities: Bool
    let failureMessage: String?
    let isVisible: Bool

    init(runStatus: String, runError: String?, hasVisibleActivities: Bool) {
        self.hasVisibleActivities = hasVisibleActivities
        if runStatus == "failed" {
            let detail = runError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            failureMessage = detail.isEmpty ? "No error details were provided." : detail
        } else {
            failureMessage = nil
        }
        isVisible = runStatus == "running" || hasVisibleActivities || failureMessage != nil
    }
}
