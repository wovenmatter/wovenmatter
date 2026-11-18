import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterAppFacade

@MainActor struct CanvasViewStateTests {
    @Test func undoKeepsLocalChangesAndIncomingWorkClearsHistory() throws {
        var state = CanvasViewState()
        let original = NoteDocument(kind: .canvas)
        let card = NoteRichTextBlock(id: "card", text: "Agent-created option")
        var agent = original
        _ = try agent.apply([.page(.init(action: .add, id: card.id, patch: .init(text: "Agent-created option")))])
        agent.stampBoardChanges(from: original, actor: .init(kind: .session, sessionID: "agent"))
        state.observe(original, agent)
        #expect(state.undoStack.isEmpty)
        var value = agent
        _ = try value.apply([.page(.init(action: .update, id: card.id,
            expectedRevision: value.boardItemRevision(for: card.id), patch: .init(status: .done)))])
        value.stampBoardChanges(from: agent, actor: .init(kind: .user))
        state.recordLocalChange(from: agent, to: value)
        state.observe(agent, value)
        state.undo(&value)
        #expect(value.blocks == agent.blocks)
        #expect(value.boardItems?[card.id]?.task == nil)
        #expect(value.boardItems?[card.id]?.updatedBy?.kind == .user)
        state.observe(agent, value)
        let undone = value
        state.redo(&value)
        #expect(value.boardItems?[card.id]?.task?.status == .done)
        state.observe(undone, value)
        var incoming = value
        _ = try incoming.apply([.page(.init(action: .update, id: card.id,
            expectedRevision: incoming.boardItemRevision(for: card.id), patch: .init(outcome: "New agent result")))])
        incoming.stampBoardChanges(from: value, actor: .init(kind: .session, sessionID: "agent"))
        state.observe(value, incoming)
        value = incoming
        state.undo(&value)
        #expect(value == incoming)
        #expect(state.redoStack.isEmpty)
        #expect(state.undoStack.isEmpty)
    }
    @Test func anUnobservedIncomingChangeAlsoFencesUndo() throws {
        var state = CanvasViewState()
        let original = NoteDocument(kind: .canvas)
        var local = original
        _ = try local.apply([.appendText("User work", .paragraph)])
        state.recordLocalChange(from: original, to: local)
        var incoming = local
        _ = try incoming.apply([.appendText("Incoming agent work", .paragraph)])
        state.undo(&incoming)
        #expect(incoming.blocks.count == 2)
        #expect(state.undoStack.isEmpty)
        #expect(state.error != nil)
    }
    @Test func normalizedTextTypingRetainsLocalUndoHistory() throws {
        var state = CanvasViewState()
        let block = NoteRichTextBlock(id: "text", text: "Before")
        let before = NoteDocument(kind: .canvas, blocks: [.richText(block)])
        var edited = before
        var text = block
        text.runs = [NoteTextRun(text: "Bef"), NoteTextRun(text: "ore typing")]
        edited.blocks = [.richText(text)]
        edited.stampBoardChanges(from: before, actor: .init(kind: .user))
        state.recordLocalChange(from: before, to: edited)
        var saved = edited.normalized()
        state.observe(before, saved)
        #expect(state.undoStack.count == 1)
        state.undo(&saved)
        #expect(saved.blocks[0].plainText == "Before")
        #expect(saved.boardItems?[block.id]?.updatedBy?.kind == .user)
    }
}
