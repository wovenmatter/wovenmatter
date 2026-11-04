import Foundation
import Testing
@testable import WovenMatterAppFacade

struct ConversationMessageLayoutTests {
    @Test func responseRowsAnchorsSpacingFailureVisibilityAndSharedScrollPolicy() {
        let layout = ConversationMessageLayout.rows(messageID: "reply", role: "assistant", mediaCount: 2)
        #expect(layout.map(\.content) == [.message, .fileChanges, .media(index: 0), .media(index: 1)],
            "Each response needs one selectable body, one files footer and ordered media")
        #expect(layout.map(\.id) == ["reply", "reply:files", "reply:media:0", "reply:media:1"],
            "Message, files or media anchors changed")
        #expect(layout.map(\.spacingBefore) == [32, 0, 32, 32],
            "Message/media spacing changed or the empty files footer would add a gap")
        for role in ["user", "system"] {
            let rows = ConversationMessageLayout.rows(messageID: "other", role: role, mediaCount: 0)
            #expect(rows.count == 1 && rows[0].content == .message,
                "\(role) rendering acquired an assistant footer")
        }
        // Failure visibility must not depend on activity records or disclosure
        // state; the view renders this detail before its expandable work history.
        for hasActivities in [false, true] {
            let failure = ConversationWorkTranscriptPresentation(
                runStatus: "failed", runError: "  Request failed\n", hasVisibleActivities: hasActivities
            )
            #expect(failure.isVisible && failure.failureMessage == "Request failed",
                "A failed run lost its error when activity visibility changed")
            #expect(failure.hasVisibleActivities == hasActivities,
                "A failure invented an empty activity disclosure")
            #expect(!ConversationMessageLayout.showsAssistantBody(
                content: "  Request failed\n", displayedBody: "Request failed", failedRunError: failure.failureMessage
            ), "The error would be repeated in the assistant body")
            #expect(ConversationMessageLayout.showsAssistantBody(
                content: "Partial reply", displayedBody: "Partial reply", failedRunError: failure.failureMessage
            ), "A failed run hid its useful partial reply")

            let missingErrors: [String?] = [nil, "", " \n\t"]
            for missingError in missingErrors {
                let fallback = ConversationWorkTranscriptPresentation(
                    runStatus: "failed", runError: missingError, hasVisibleActivities: hasActivities
                )
                #expect(fallback.isVisible && fallback.failureMessage == "No error details were provided.",
                    "A failed run without saved error details became invisible")
            }
            for status in ["running", "completed", "cancelled"] {
                let other = ConversationWorkTranscriptPresentation(
                    runStatus: status, runError: "Old error", hasVisibleActivities: hasActivities
                )
                #expect(other.failureMessage == nil
                    && other.isVisible == (status == "running" || hasActivities),
                    "The running timer was hidden or an inactive run acquired an empty work transcript")
            }
        }

        #expect(!ConversationMessageLayout.showsAssistantBody(content: "ignored", displayedBody: "", failedRunError: nil),
            "An empty projected reply became visible")
        var scroll = DashboardConversationScrollState()
        scroll.conversationChanged(to: "first")
        let opened = scroll.contentChanged(conversationID: "first", hasMessages: true, isPrependingHistory: false)
        #expect(opened == .jumpToBottom, "Opening a populated chat must initially position at its latest reply")
        let before = DashboardConversationGeometry(contentHeight: 800, isNearBottom: true, viewportHeight: 500)
        let toolGrowth = DashboardConversationGeometry(contentHeight: 1100, isNearBottom: false, viewportHeight: 500)
        let followedToolGrowth = scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: false, transcriptOwnsScroll: false, isPrependingHistory: false)
        #expect(followedToolGrowth, "Tool-only growth stopped following a transcript that was already at the bottom")
        scroll.setNearBottom(false)
        let newMessage = scroll.contentChanged(conversationID: "first", hasMessages: true, isPrependingHistory: false)
        #expect(newMessage == .none, "A new message pulled the reader away from earlier work")
        let pulledByToolGrowth = scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: false, transcriptOwnsScroll: false, isPrependingHistory: false)
        #expect(!pulledByToolGrowth, "Tool growth pulled the reader away from earlier work")
        scroll.setNearBottom(true)
        let followedOldWork = scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: false, transcriptOwnsScroll: true, isPrependingHistory: false)
        #expect(!followedOldWork, "Opening old work unexpectedly followed the enlarged content to the bottom")
        scroll.setNearBottom(true)
        let lostUserScroll = scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: true, transcriptOwnsScroll: false, isPrependingHistory: false)
        #expect(!lostUserScroll, "An active user scroll lost ownership to streaming output")
        scroll.setNearBottom(true)
        let jumpedWhilePrepending = scroll.geometryChanged(from: before, to: toolGrowth, isUserScrolling: false, transcriptOwnsScroll: false, isPrependingHistory: true)
        #expect(!jumpedWhilePrepending, "Loading earlier history jumped to the latest reply")
        scroll.setNearBottom(true)
        let keyboard = DashboardConversationGeometry(contentHeight: 800, isNearBottom: false, viewportHeight: 280)
        let keptBottomForKeyboard = scroll.geometryChanged(from: before, to: keyboard, isUserScrolling: false, transcriptOwnsScroll: false, isPrependingHistory: false)
        #expect(keptBottomForKeyboard, "Keyboard resizing lost bottom positioning")
        scroll.conversationChanged(to: "second")
        let switched = scroll.contentChanged(conversationID: "second", hasMessages: true, isPrependingHistory: false)
        #expect(switched == .jumpToBottom, "Switching chats retained another conversation's reading position")
        var workScroll = ConversationWorkScrollState()
        #expect(workScroll.shouldFollowAppend(from: ["thought", "read"], to: ["thought", "read", "command"]),
            "A new live work row did not follow from the live edge")
        #expect(!workScroll.shouldFollowAppend(from: ["thought", "read"], to: ["thought", "read"]),
            "A tool status/detail update moved the work list")
        #expect(!workScroll.shouldFollowAppend(from: ["thought", "read"], to: ["thought", "replacement", "command"]),
            "A work correction was treated as a new append")
        workScroll.setAtBottom(false)
        #expect(workScroll.shouldFollowAppend(from: ["read"], to: ["read", "command"], wasAtBottom: true),
            "Post-layout geometry lost the pre-append live edge")
        #expect(!workScroll.shouldFollowTextAppend(from: "A trace.", to: "A trace.\n\nNext thought."),
            "Growing reasoning interrupted a reader above the live edge")
        #expect(!workScroll.shouldFollowAppend(from: ["read"], to: ["read", "command"]),
            "Streaming work interrupted a reader inspecting earlier calls")
        workScroll.setAtBottom(true)
        #expect(workScroll.shouldFollowTextAppend(from: "A trace.", to: "A trace.\n\nNext thought."),
            "Growing reasoning did not follow from its live edge")
        for (before, after) in [("e", "e\u{301}"), ("👩", "👩‍💻"), ("क", "कि")] {
            #expect(workScroll.shouldFollowTextAppend(from: before, to: after),
                "Appending to an existing grapheme did not follow the live edge")
            #expect(!workScroll.shouldFollowTextAppend(from: before, to: after, wasAtBottom: false),
                "Appending to a grapheme moved a reader above the live edge")
        }
        #expect(!workScroll.shouldFollowTextAppend(from: "Old trace.", to: "Corrected trace."),
            "A reasoning replacement unexpectedly moved reading position")
        #expect(workScroll.shouldFollowAppend(from: ["read"], to: ["read", "command"]),
            "Returning to the live edge did not resume following new work")
    }
}
