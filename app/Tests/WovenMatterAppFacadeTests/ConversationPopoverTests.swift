import Testing
@testable import WovenMatterAppFacade

// The interactive popover motion fixture still runs through
// scripts/test-conversation-popover.sh; only the pure hover state lives here.
@MainActor struct ConversationPopoverTests {
    @Test func hoverOnlyState() {
        var details = ConversationDetailCardState()
        details.completePrimaryAction()
        #expect(details.presentedConversationID == nil, "primary activation without hover cannot present a preview")
        details.setHovered(true, conversationID: "a")
        details.completePrimaryAction()
        #expect(details.presentedConversationID == nil, "primary activation dismisses an existing hover preview")
        details.setHovered(true, conversationID: "b")
        details.setHovered(false, conversationID: "a")
        details.remove(conversationID: "a")
        #expect(details.presentedConversationID == "b", "old row exit and removal cannot dismiss the new preview")
        details.setHovered(false, conversationID: "b")
        #expect(details.presentedConversationID == nil, "hover exit clears presentation immediately")

        let hover = ScrollHoverCoordinator()
        var hoveredA = false
        var hoveredB = false
        hover.recordHover(true, token: "a") { hoveredA = $0 }
        #expect(hoveredA, "first hover enters its row")
        hover.recordHover(true, token: "b") { hoveredB = $0 }
        #expect(!hoveredA && hoveredB, "entry into a new row clears the old hover before its exit arrives")
        hover.recordHover(false, token: "a") { hoveredA = $0 }
        #expect(hoveredB && hover.hoveredToken == "b", "late old-row exit preserves the current hover")
        hover.setScrolling(true)
        #expect(!hoveredB, "scrolling immediately clears current hover")
        hover.setScrolling(false)
        #expect(hoveredB, "ending scroll restores hover for a fresh appearance delay")
        hover.setScrolling(true)
        hover.recordHover(false, token: "b") { hoveredB = $0 }
        hover.setScrolling(false)
        #expect(!hoveredB && hover.hoveredToken == nil, "leaving during scrolling cannot restore a stale hover")
        hover.recordHover(true, token: "a") { hoveredA = $0 }
        hover.setScrolling(true)
        hover.recordHover(true, token: "b") { hoveredB = $0 }
        hover.setScrolling(false)
        #expect(!hoveredA && hoveredB, "hover transfer during scrolling resumes only the current row")
        hover.recordHover(false, token: "b") { hoveredB = $0 }
        #expect(!hoveredB, "final exit clears the active row")
    }
}
