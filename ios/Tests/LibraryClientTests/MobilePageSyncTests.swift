import Foundation
import Testing
import WovenMatterShared
@testable import LibraryClient

/// A Page edited on this device while another device changed it combines on sync,
/// so neither person has to choose between whole versions.
@Suite("Mobile Page sync")
struct MobilePageSyncTests {
  private func page(_ first: String, _ second: String) throws -> String {
    try NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "a", text: first)), .richText(.init(id: "b", text: second))], pageNodes: [:]).encoded()
  }

  private func store() throws -> (MobileStore, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("wm-page-sync-" + UUID().uuidString)
    return (try MobileStore(file: root.appendingPathComponent("library.json")), root)
  }

  /// Edits the phone's copy as the editor does, then lets the Mac refuse the stale
  /// save. The refusal carries no body; the phone fetches it next.
  private func conflict(local: String, remote: String) async throws -> (MobileStore, URL, LibraryNote) {
    let (store, root) = try store()
    let synced = LibraryNote(id: UUID().uuidString.lowercased(), title: "Plan", content: try page("one", "two"), revision: 1, kind: .canvas)
    try await store.apply(LibrarySnapshot(workspaceID: "library", cursor: 1, notes: [synced]))
    try await store.editNote(id: synced.id, title: "Plan", content: local, folderID: nil, base: synced)
    let sent = try #require(try await store.nextMutation())
    var stored = synced; stored.revision = 2; stored.content = remote
    var withoutBody = stored; withoutBody.content = ""; withoutBody.contentIncluded = false
    try await store.acknowledge(.init(operationID: sent.operationID, status: .conflict, note: withoutBody))
    #expect(await store.snapshot().conflicts[synced.id] != nil, "Nothing merges before the stored body arrives")
    try await store.cacheNote(stored)
    return (store, root, stored)
  }

  @Test func editsToDifferentComponentsCombineAndResync() async throws {
    let (store, root, stored) = try await conflict(local: try page("one, edited on the phone", "two"), remote: try page("one", "two, edited on the Mac"))
    defer { try? FileManager.default.removeItem(at: root) }
    let state = await store.snapshot()
    #expect(state.conflicts[stored.id] == nil)
    let merged = try #require(state.notes[stored.id])
    #expect(merged.revision == 2)
    let texts = try NoteDocument.editableDocument(from: merged.content).blocks.map(\.plainText)
    #expect(texts == ["one, edited on the phone", "two, edited on the Mac"])
    let resend = try #require(state.outbox.last?.mutation)
    #expect(resend.kind == .updateNote && resend.expectedRevision == 2 && resend.content == merged.content)
  }

  @Test func bothVersionsOfOneComponentStayOnThePage() async throws {
    let (store, root, stored) = try await conflict(local: try page("phone wording", "two"), remote: try page("Mac wording", "two"))
    defer { try? FileManager.default.removeItem(at: root) }
    let state = await store.snapshot()
    #expect(state.conflicts[stored.id] == nil)
    let texts = try NoteDocument.editableDocument(from: try #require(state.notes[stored.id]).content).blocks.map(\.plainText)
    #expect(texts.contains("phone wording") && texts.contains("Mac wording") && texts.contains("two"))
  }

  /// An editor still showing the earlier version saves into the merged copy without
  /// losing the merge, and the base stays the Mac's last version.
  @Test func aStaleEditorSaveAfterAMergeKeepsBothChanges() async throws {
    let (store, root, stored) = try await conflict(local: try page("one, edited on the phone", "two"), remote: try page("one", "two, edited on the Mac"))
    defer { try? FileManager.default.removeItem(at: root) }
    var editorBase = stored; editorBase.revision = 1; editorBase.content = try page("one", "two")
    try await store.editNote(id: stored.id, title: "Plan", content: try page("one, edited on the phone, again", "two"), folderID: nil, base: editorBase)
    let state = await store.snapshot()
    #expect(state.conflicts[stored.id] == nil)
    let texts = try NoteDocument.editableDocument(from: try #require(state.notes[stored.id]).content).blocks.map(\.plainText)
    #expect(texts == ["one, edited on the phone, again", "two, edited on the Mac"])
    #expect(state.bases[stored.id] == stored)
    #expect(state.outbox.filter { $0.mutation.resourceID == stored.id }.map(\.mutation.expectedRevision) == [2])
  }

  /// Quick Chat changes a Page while it is open; the next keystroke keeps that change.
  @Test func typingAfterAQuickChatEditKeepsTheChatsChange() async throws {
    let (store, root) = try store()
    defer { try? FileManager.default.removeItem(at: root) }
    let opened = try await store.createNote(folderID: nil, title: "Plan", content: try page("one", "two"))
    try await store.editNote(id: opened.id, title: "Plan", content: try page("one typed", "two"), folderID: nil, base: opened)
    let chat = MobileToolContext(sessionID: "chat", workspaceID: "phone")
    let read = await store.executeLocalTool(.init(arguments: ["pages", "read", "--note-id", opened.id], requestID: UUID().uuidString.lowercased()), context: chat)
    let revision = try #require(read.result?.objectValue?["components"]?.arrayValue?[1].objectValue?["componentRevision"]?.stringValue)
    let edit = await store.executeLocalTool(.init(arguments: ["pages", "update-component", "--note-id", opened.id, "--id", "b", "--component-revision", revision, "--text", "two from the chat"], requestID: UUID().uuidString.lowercased()), context: chat)
    #expect(edit.success, "\(edit.error ?? "")")
    try await store.editNote(id: opened.id, title: "Plan", content: try page("one typed more", "two"), folderID: nil, base: opened)
    let saved = try #require(await store.snapshot().notes[opened.id])
    let document = try NoteDocument.editableDocument(from: saved.content)
    #expect(document.blocks.map(\.plainText) == ["one typed more", "two from the chat"])
    #expect(document.boardItems?["b"]?.updatedBy?.sessionID == "chat")
  }

  @Test func anOrdinaryNoteStillAsksWhichVersionToKeep() async throws {
    let (store, root) = try store()
    defer { try? FileManager.default.removeItem(at: root) }
    let synced = LibraryNote(id: UUID().uuidString.lowercased(), title: "Note", content: try NoteDocument(blocks: [.richText(.init(id: "a", text: "one"))]).encoded(), revision: 1)
    try await store.apply(LibrarySnapshot(workspaceID: "library", cursor: 1, notes: [synced]))
    try await store.editNote(id: synced.id, title: "Note", content: try NoteDocument(blocks: [.richText(.init(id: "a", text: "phone"))]).encoded(), folderID: nil, base: synced)
    let sent = try #require(try await store.nextMutation())
    var stored = synced; stored.revision = 2; stored.content = try NoteDocument(blocks: [.richText(.init(id: "a", text: "Mac"))]).encoded()
    try await store.acknowledge(.init(operationID: sent.operationID, status: .conflict, note: stored))
    #expect(await store.snapshot().conflicts[synced.id] != nil)
  }
}
