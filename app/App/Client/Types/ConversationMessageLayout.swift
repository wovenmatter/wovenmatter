import Foundation

/// Direct children of the conversation's lazy stack. Each response owns one
/// native text view so selection can span its complete formatted content.
struct ConversationMessageLayout {
    struct Row: Identifiable, Equatable, Sendable {
        enum Content: Equatable, Sendable {
            case message
            case fileChanges
        }

        let messageID: String
        let role: MessageRole
        let content: Content

        var id: String {
            switch content {
            case .message: messageID
            case .fileChanges: "\(messageID):files"
            }
        }

        var spacingBefore: CGFloat {
            // The card adds its own gap only when it has visible changes.
            if case .fileChanges = content { return 0 }
            // A reply sits closer to the message it answers than to the turn before it.
            return role == .assistant ? ConversationMetrics.replyGap : ConversationMetrics.turnGap
        }
    }

    static func rows(messageID: String, role: MessageRole) -> [Row] {
        var rows = [Row(messageID: messageID, role: role, content: .message)]
        if role == .assistant {
            // Keep footer state stable while the response streams.
            // Empty cards remain zero-height lazy rows.
            rows.append(Row(messageID: messageID, role: role, content: .fileChanges))
        }
        return rows
    }

    static func showsAssistantBody(content: String, displayedBody: String, failedRunError: String?) -> Bool {
        guard !displayedBody.isEmpty else { return false }
        guard let failedRunError else { return true }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
            != failedRunError.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Every turn shows how long it ran, and a failure, whether or not it has work to show.
struct ConversationWorkTranscriptPresentation {
    let failureMessage: String?

    init(runStatus: RunStatus, runError: String?) {
        if runStatus == .failed {
            let detail = runError?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            failureMessage = detail.isEmpty ? "No error details were provided." : detail
        } else {
            failureMessage = nil
        }
    }
}

// Shared desktop/mobile transcript scroll policy.
enum ConversationScrollAction: Equatable {
    case none
    case jumpToBottom
    case followBottom
}

struct ConversationGeometry: Equatable {
    let contentHeight: CGFloat
    let isNearBottom: Bool
    var viewportHeight: CGFloat? = nil
}

struct ConversationScrollState: Equatable {
    private(set) var positionedConversationID: String?
    private(set) var isNearBottom = true

    mutating func conversationChanged(to conversationID: String?) {
        guard positionedConversationID != conversationID else { return }
        positionedConversationID = nil
        isNearBottom = true
    }

    mutating func contentChanged(
        conversationID: String?,
        hasMessages: Bool,
        isPrependingHistory: Bool
    ) -> ConversationScrollAction {
        guard let conversationID, hasMessages else { return .none }
        if positionedConversationID != conversationID {
            positionedConversationID = conversationID
            isNearBottom = true
            return .jumpToBottom
        }
        guard !isPrependingHistory, isNearBottom else { return .none }
        return .followBottom
    }

    mutating func setNearBottom(_ isNearBottom: Bool) {
        self.isNearBottom = isNearBottom
    }

    /// Content-only tool updates and keyboard resizing follow the same bottom
    /// policy as message growth. Opening work or reading history owns the view.
    mutating func geometryChanged(from previous: ConversationGeometry,
                                  to current: ConversationGeometry,
                                  isUserScrolling: Bool, transcriptOwnsScroll: Bool,
                                  isPrependingHistory: Bool) -> Bool {
        let resized = previous.contentHeight != current.contentHeight || previous.viewportHeight != current.viewportHeight
        let follow = resized && isNearBottom && !isUserScrolling && !transcriptOwnsScroll && !isPrependingHistory
        setNearBottom(current.isNearBottom && !transcriptOwnsScroll)
        return follow
    }

    mutating func sourceMessagePositioned(in conversationID: String) {
        positionedConversationID = conversationID
        isNearBottom = false
    }
}

/// Work groups follow new rows only from their existing live edge. Replacing
/// content, settling a tool, or opening its details must preserve reading position.
struct ConversationWorkScrollState: Equatable {
    private(set) var isAtBottom = true

    mutating func setAtBottom(_ value: Bool) { isAtBottom = value }

    func shouldFollowAppend(from before: [String], to after: [String], wasAtBottom: Bool? = nil) -> Bool {
        (wasAtBottom ?? isAtBottom) && after.count > before.count && after.starts(with: before)
    }

    func shouldFollowTextAppend(from before: String, to after: String, wasAtBottom: Bool? = nil) -> Bool {
        (wasAtBottom ?? isAtBottom) && after.utf16.count > before.utf16.count && after.utf16.starts(with: before.utf16)
    }
}

struct ConversationWorkScrollGeometry: Equatable {
    let contentHeight: CGFloat
    let offset: CGFloat
    let viewportHeight: CGFloat

    var isAtBottom: Bool { contentHeight - offset - viewportHeight <= 4 }
}
