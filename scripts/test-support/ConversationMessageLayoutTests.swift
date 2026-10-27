import Foundation

@main
struct ConversationMessageLayoutTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func main() throws {
        let layout = ConversationMessageLayout.rows(messageID: "reply", role: "assistant", mediaCount: 2)
        try require(layout.map(\.content) == [.message, .fileChanges, .media(index: 0), .media(index: 1)],
            "Each response needs one selectable body, one files footer and ordered media")
        try require(layout.map(\.id) == ["reply", "reply:files", "reply:media:0", "reply:media:1"],
            "Message, files or media anchors changed")
        try require(layout.map(\.spacingBefore) == [32, 0, 32, 32],
            "Message/media spacing changed or the empty files footer would add a gap")
        for role in ["user", "system"] {
            let rows = ConversationMessageLayout.rows(messageID: "other", role: role, mediaCount: 0)
            try require(rows.count == 1 && rows[0].content == .message,
                "\(role) rendering acquired an assistant footer")
        }
        // Failure visibility must not depend on activity records or disclosure
        // state; the view renders this detail before its expandable work history.
        for hasActivities in [false, true] {
            let failure = ConversationWorkTranscriptPresentation(
                runStatus: "failed", runError: "  Request failed\n", hasVisibleActivities: hasActivities
            )
            try require(failure.isVisible && failure.failureMessage == "Request failed",
                "A failed run lost its error when activity visibility changed")
            try require(failure.hasVisibleActivities == hasActivities,
                "A failure invented an empty activity disclosure")
            try require(!ConversationMessageLayout.showsAssistantBody(
                content: "  Request failed\n", displayedBody: "Request failed", failedRunError: failure.failureMessage
            ), "The error would be repeated in the assistant body")
            try require(ConversationMessageLayout.showsAssistantBody(
                content: "Partial reply", displayedBody: "Partial reply", failedRunError: failure.failureMessage
            ), "A failed run hid its useful partial reply")

            let missingErrors: [String?] = [nil, "", " \n\t"]
            for missingError in missingErrors {
                let fallback = ConversationWorkTranscriptPresentation(
                    runStatus: "failed", runError: missingError, hasVisibleActivities: hasActivities
                )
                try require(fallback.isVisible && fallback.failureMessage == "No error details were provided.",
                    "A failed run without saved error details became invisible")
            }
            for status in ["running", "completed", "cancelled"] {
                let other = ConversationWorkTranscriptPresentation(
                    runStatus: status, runError: "Old error", hasVisibleActivities: hasActivities
                )
                try require(other.failureMessage == nil
                    && other.isVisible == (status == "running" || hasActivities),
                    "The running timer was hidden or an inactive run acquired an empty work transcript")
            }
        }

        try require(!ConversationMessageLayout.showsAssistantBody(content: "ignored", displayedBody: "", failedRunError: nil),
            "An empty projected reply became visible")
        var scroll = DashboardConversationScrollState()
        scroll.conversationChanged(to: "first")
        try require(scroll.contentChanged(conversationID: "first", hasMessages: true, isPrependingHistory: false) == .jumpToBottom,
            "Opening a populated chat must initially position at its latest reply")
        let before = DashboardConversationGeometry(contentHeight: 800, isNearBottom: true, viewportHeight: 500)
        let toolGrowth = DashboardConversationGeometry(contentHeight: 1100, isNearBottom: false, viewportHeight: 500)
        try require(scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: false, transcriptOwnsScroll: false, isPrependingHistory: false),
            "Tool-only growth stopped following a transcript that was already at the bottom")
        scroll.setNearBottom(false)
        try require(scroll.contentChanged(conversationID: "first", hasMessages: true, isPrependingHistory: false) == .none,
            "A new message pulled the reader away from earlier work")
        try require(!scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: false, transcriptOwnsScroll: false, isPrependingHistory: false),
            "Tool growth pulled the reader away from earlier work")
        scroll.setNearBottom(true)
        try require(!scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: false, transcriptOwnsScroll: true, isPrependingHistory: false),
            "Opening old work unexpectedly followed the enlarged content to the bottom")
        scroll.setNearBottom(true)
        try require(!scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: true, transcriptOwnsScroll: false, isPrependingHistory: false),
            "An active user scroll lost ownership to streaming output")
        scroll.setNearBottom(true)
        try require(!scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: false, transcriptOwnsScroll: false, isPrependingHistory: true),
            "Loading earlier history jumped to the latest reply")
        scroll.setNearBottom(true)
        let keyboard = DashboardConversationGeometry(contentHeight: 800, isNearBottom: false, viewportHeight: 280)
        try require(scroll.geometryChanged(from: before, to: keyboard, isUserScrolling: false, transcriptOwnsScroll: false, isPrependingHistory: false),
            "Keyboard resizing lost bottom positioning")
        scroll.conversationChanged(to: "second")
        try require(scroll.contentChanged(conversationID: "second", hasMessages: true, isPrependingHistory: false) == .jumpToBottom,
            "Switching chats retained another conversation's reading position")
        var workScroll = ConversationWorkScrollState()
        try require(workScroll.shouldFollowAppend(from: ["thought", "read"], to: ["thought", "read", "command"]),
            "A new live work row did not follow from the live edge")
        try require(!workScroll.shouldFollowAppend(from: ["thought", "read"], to: ["thought", "read"]),
            "A tool status/detail update moved the work list")
        try require(!workScroll.shouldFollowAppend(from: ["thought", "read"], to: ["thought", "replacement", "command"]),
            "A work correction was treated as a new append")
        workScroll.setAtBottom(false)
        try require(!workScroll.shouldFollowTextAppend(from: "A trace.", to: "A trace.\n\nNext thought."),
            "Growing reasoning interrupted a reader above the live edge")
        try require(!workScroll.shouldFollowAppend(from: ["read"], to: ["read", "command"]),
            "Streaming work interrupted a reader inspecting earlier calls")
        workScroll.setAtBottom(true)
        try require(workScroll.shouldFollowTextAppend(from: "A trace.", to: "A trace.\n\nNext thought."),
            "Growing reasoning did not follow from its live edge")
        try require(!workScroll.shouldFollowTextAppend(from: "Old trace.", to: "Corrected trace."),
            "A reasoning replacement unexpectedly moved reading position")
        try require(workScroll.shouldFollowAppend(from: ["read"], to: ["read", "command"]),
            "Returning to the live edge did not resume following new work")
        print("PASS: response rows, anchors, spacing, failure visibility and shared transcript/work scroll policy")
    }
}
