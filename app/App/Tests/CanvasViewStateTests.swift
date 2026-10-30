import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor struct CanvasViewStateTests {
    @Test func undoIncludesAgentChangesAndNewWorkInvalidatesRedo() throws {
        var state = DashboardCanvasViewState()
        let original = NoteDocument(kind: .canvas)
        let card = NoteRichTextBlock(text: "Agent-created option")
        var agent = original
        _ = try agent.apply([.canvas(.init(action: .add, block: .richText(card), placement: .init(x: -500, y: 300)))])
        state.observe(original, agent)
        var value = agent
        state.undo(&value)
        #expect(value == original)
        state.observe(agent, value)
        state.redo(&value)
        #expect(value == agent)
        state.observe(original, value)
        let before = value
        _ = try value.apply([.appendText("User follow-up", .paragraph)])
        state.observe(before, value)
        #expect(state.redoStack.isEmpty)
        #expect(state.undoStack.count == 2)
    }
    @Test func zoomKeepsViewportCenterAndFitFindsNegativeCoordinates() {
        var state = DashboardCanvasViewState()
        state.viewport = CGSize(width: 800, height: 600)
        let centerX = state.origin.x + state.viewport.width / state.zoom / 2
        state.setZoom(0.25)
        #expect(abs(state.origin.x + state.viewport.width / state.zoom / 2 - centerX) < 0.001)
        let card = NoteRichTextBlock(text: "Far away")
        let document = NoteDocument(kind: .canvas, blocks: [.richText(card)], canvas: [card.id: .init(x: -500_000, y: 400_000)])
        state.fit(document)
        #expect(state.visibleRect.contains(document.canvasPlacement(for: card.id).rect))
    }
}
