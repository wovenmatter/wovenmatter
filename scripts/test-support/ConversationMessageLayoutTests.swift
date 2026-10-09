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
        print("PASS: single response rows, stable message/file/media anchors, spacing and failure visibility")
    }
}
