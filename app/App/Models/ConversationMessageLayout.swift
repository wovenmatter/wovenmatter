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

// Shared desktop/mobile transcript scroll policy.
enum DashboardConversationScrollAction: Equatable {
    case none
    case jumpToBottom
    case followBottom
}

struct DashboardConversationGeometry: Equatable {
    let contentHeight: CGFloat
    let isNearBottom: Bool
    var viewportHeight: CGFloat? = nil
}

struct DashboardConversationScrollState: Equatable {
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
    ) -> DashboardConversationScrollAction {
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
    mutating func geometryChanged(from previous: DashboardConversationGeometry,
                                  to current: DashboardConversationGeometry,
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
