import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Page client merge")
struct PageClientMergeTests {
  @Test func eachKeptChangeKeepsTheAttributionOfWhoMadeIt() throws {
    let base = NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "a", text: "one")), .richText(.init(id: "b", text: "two"))], pageNodes: [:])
    let phoneChat = BoardActor(kind: .session, sessionID: "phone-chat", label: "Planning")
    let macAgent = BoardActor(kind: .session, sessionID: "mac-chat", label: "Review")
    var local = base
    try local.applyPageEdit(.init(action: .update, id: "a", expectedRevision: base.boardItemRevision(for: "a"), patch: .init(text: "one from the phone")))
    local.stampBoardChanges(from: base, actor: phoneChat, at: "2026-11-12T10:00:00Z")
    try local.applyPageEdit(.init(action: .add, id: "c", kind: .task, patch: .init(text: "New task"), position: .init(afterID: "b")))
    local.stampBoardChanges(from: base, actor: phoneChat, at: "2026-11-12T10:01:00Z")
    var remote = base
    try remote.applyPageEdit(.init(action: .update, id: "b", expectedRevision: base.boardItemRevision(for: "b"), patch: .init(text: "two from the Mac")))
    remote.stampBoardChanges(from: base, actor: macAgent, at: "2026-11-12T10:02:00Z")

    let merged = try NoteDocument.mergeClientPage(base: base, local: local, remote: remote)
    #expect(merged.blocks.map(\.plainText) == ["one from the phone", "two from the Mac", "New task"])
    #expect(merged.boardItems?["a"]?.updatedBy == phoneChat)
    #expect(merged.boardItems?["b"]?.updatedBy == macAgent)
    #expect(merged.boardItems?["c"]?.createdBy == phoneChat && merged.boardItems?["c"]?.updatedBy == phoneChat)
  }
}
