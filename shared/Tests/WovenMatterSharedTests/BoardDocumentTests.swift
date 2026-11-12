import Foundation
import Testing
@testable import WovenMatterShared

@Suite("Board collaboration metadata")
struct BoardDocumentTests {
  private func board() -> (NoteDocument, a: String, b: String) {
    let a = NoteRichTextBlock(id: "a", text: "First"), b = NoteRichTextBlock(id: "b", text: "Second")
    var placement = CanvasCardPlacement(x: 10, y: 20); placement.title = "Ship it"
    let document = NoteDocument(kind: .canvas, blocks: [.richText(a), .richText(b)],
      canvas: ["a": placement, "b": .init(x: 500, y: 20)], boardPurpose: "Launch",
      boardItems: ["a": .init(task: .init(status: .doing, assignee: "Codex")), "b": .init(review: .needed)])
    return (document, "a", "b")
  }
  private func update(_ id: String, in document: NoteDocument, _ patch: BoardItemPatch) -> NoteEditOperation {
    .board(.init(action: .updateItem, id: id, expectedRevision: document.boardItemRevision(for: id), patch: patch))
  }

  @Test func everyFieldSurvivesNormalizationAndRoundTrip() throws {
    var (document, a, _) = board()
    document.boardItems?[a] = .init(role: .instructions, task: .init(status: .blocked, assignee: "Me", outcome: "Waiting"),
      review: .approved, sessions: ["s1"], lastChange: "Blocked", createdBy: .init(kind: .user), createdAt: "2026-01-01T00:00:00Z",
      updatedBy: .init(kind: .session, sessionID: "s1", label: "Worker"), updatedAt: "2026-01-02T00:00:00Z")
    #expect(document.normalized() == document)
    let decoded = try NoteDocument.editableDocument(from: document.encoded())
    #expect(decoded == document)
    #expect(decoded.boardPurpose == "Launch")
    #expect(decoded.boardItems?[a]?.updatedBy?.label == "Worker")
  }

  @Test func sparseStoredItemsUseDefaults() throws {
    let raw = #"{"version":2,"kind":"canvas","blocks":[{"type":"richText","value":{"id":"a","style":"paragraph","runs":[]}}],"html":"","boardItems":{"a":{"task":{"status":"done"}}}}"#
    let document = try NoteDocument.editableDocument(from: raw)
    #expect(document.boardItems?["a"] == .init(task: .init(status: .done)))
    #expect(document.boardItems?["a"]?.sessions == [])
  }

  @Test func boundsAndFutureFieldsAreReadOnly() throws {
    func rejected(_ change: (inout NoteDocument) -> Void) {
      var (document, _, _) = board(); change(&document)
      #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try document.validateEditableShape() }
    }
    rejected { $0.boardPurpose = String(repeating: "x", count: NoteDocument.maximumBoardPurposeBytes + 1) }
    rejected { $0.boardItems?["missing"] = .init() }
    rejected { $0.boardItems?["a"]?.sessions = (0...BoardItem.maximumSessions).map { "s\($0)" } }
    rejected { $0.boardItems?["a"]?.sessions = ["same", "same"] }
    rejected { $0.boardItems?["a"]?.lastChange = String(repeating: "x", count: BoardItem.maximumLastChangeBytes + 1) }
    rejected { $0.boardItems?["a"]?.task?.outcome = String(repeating: "x", count: BoardTask.maximumOutcomeBytes + 1) }
    let plain = NoteDocument(blocks: [.richText(.init(id: "a", text: "Note"))], boardPurpose: "Not a Board")
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try plain.validateEditableShape() }

    let (document, a, _) = board()
    var object = try #require(JSONSerialization.jsonObject(with: Data(document.encoded().utf8)) as? [String: Any])
    var items = try #require(object["boardItems"] as? [String: Any])
    var item = try #require(items[a] as? [String: Any]); item["futureField"] = "preserve"
    items[a] = item; object["boardItems"] = items
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try NoteDocument.editableDocument(from: raw) }
  }

  @Test func boardsCannotGrowPastTheSharedEnvelope() throws {
    let (document, _, _) = board()
    let text = String(repeating: "x", count: 200 * 1_024)
    var operations: [NoteEditOperation] = (0..<6).map { .board(.init(action: .addItem, id: "large-\($0)", patch: .init(text: text))) }
    #expect(throws: RemoteNoteEditError.operationTooLarge) { try RemoteNoteEditEnvelope.validate(operations: operations, applyingTo: document) }
    operations.removeLast(3)
    try RemoteNoteEditEnvelope.validate(operations: operations, applyingTo: document)
  }

  @Test func deletingACardCleansItsMetadataAndChangingItsIDIsRejected() throws {
    var (document, a, b) = board()
    document.canvasConnections = [.init(id: "link", from: a, to: b)]
    var removed = document
    _ = try removed.apply([.deleteBlock(id: a)])
    #expect(removed.boardItems?[a] == nil)
    #expect(removed.canvasConnections?.isEmpty == true)
    removed = document
    _ = try removed.apply([.canvas(.init(action: .remove, id: a))])
    #expect(removed.boardItems?[a] == nil)
    removed = document
    _ = try removed.apply([.board(.init(action: .removeItem, id: a, expectedRevision: document.boardItemRevision(for: a)))])
    #expect(removed.boardItems?[a] == nil && removed.canvas?[a] == nil && removed.blocks.count == 1)
    #expect(removed.boardItems?[b] == document.boardItems?[b])

    #expect(throws: NoteEditError.boardCardIDChanged(a)) {
      var copy = document
      _ = try copy.apply([.replaceBlock(id: a, block: .richText(.init(id: "renamed", text: "New")))])
    }
    var replaced = document
    _ = try replaced.apply([.replaceBlock(id: a, block: .richText(.init(id: a, text: "New")))])
    #expect(replaced.boardItems?[a] == document.boardItems?[a])
    #expect(replaced.canvas?[a] == document.canvas?[a])
  }

  @Test func itemRevisionIgnoresLayoutAndTracksContent() throws {
    let (document, a, b) = board()
    let before = document.boardItemRevision(for: a)
    #expect(before.count == 32)
    #expect(document.boardItemRevision(for: "missing") == "")
    #expect(try NoteDocument.editableDocument(from: document.encoded()).boardItemRevision(for: a) == before)

    var moved = document
    var placement = moved.canvasPlacement(for: a); placement.x = 900; placement.width = 700; placement.color = "blue"
    let section = CanvasSection(id: "group", title: "Group", x: -400, y: -400)
    _ = try moved.apply([.canvas(.init(action: .place, id: a, placement: placement)),
      .canvas(.init(action: .section, section: section, ids: [a])), .canvas(.init(action: .arrange, layout: "row"))])
    #expect(moved.boardItemRevision(for: a) == before)
    #expect(moved.boardItems == document.boardItems)

    var edited = document
    _ = try edited.apply([update(a, in: document, .init(outcome: "Done"))])
    #expect(edited.boardItemRevision(for: a) != before)
    #expect(edited.boardItemRevision(for: b) == document.boardItemRevision(for: b))
    var retitled = document
    _ = try retitled.apply([update(a, in: document, .init(title: "Renamed"))])
    #expect(retitled.boardItemRevision(for: a) != before)
    var linked = document
    linked.canvas?[a]?.assetID = "asset"
    #expect(linked.boardItemRevision(for: a) != before)
  }

  @Test func layoutCannotDropATitleOrLinkedAsset() throws {
    var (document, a, _) = board()
    document.canvas?[a]?.assetID = "original"
    _ = try document.apply([.canvas(.init(action: .place, id: a, placement: .init(x: 1, y: 2)))])
    #expect(document.canvas?[a]?.title == "Ship it")
    #expect(document.canvas?[a]?.assetID == "original")
    var cleared = document.canvasPlacement(for: a); cleared.title = ""
    _ = try document.apply([.canvas(.init(action: .place, id: a, placement: cleared))])
    #expect(document.canvas?[a]?.title == "")
  }

  @Test func patchesChangeOnlySuppliedFields() throws {
    var (document, a, _) = board()
    _ = try document.apply([update(a, in: document, .init(outcome: "Shipped", lastChange: "Finished"))])
    let item = try #require(document.boardItems?[a])
    #expect(item.task == .init(status: .doing, assignee: "Codex", outcome: "Shipped"))
    #expect(item.lastChange == "Finished")
    #expect(document.canvas?[a]?.title == "Ship it")
    #expect(document.blocks[0].plainText == "First")

    _ = try document.apply([update(a, in: document, .init(text: "Rewritten", status: .done))])
    #expect(document.blocks[0].plainText == "Rewritten")
    #expect(document.boardItems?[a]?.task?.status == .done)
    _ = try document.apply([update(a, in: document, .init(clearTask: true, review: .needed))])
    #expect(document.boardItems?[a]?.task == nil)
    #expect(document.boardItems?[a]?.review == .needed)
    _ = try document.apply([update(a, in: document, .init(clearReview: true))])
    #expect(document.boardItems?[a]?.review == nil)
    #expect(throws: NoteEditError.self) {
      var copy = document
      _ = try copy.apply([update(a, in: document, .init(status: .todo, clearTask: true))])
    }
  }

  @Test func staleAndMissingItemRevisionsAreRejected() throws {
    let (document, a, b) = board()
    let stale = document.boardItemRevision(for: a)
    var current = document
    _ = try current.apply([.board(.init(action: .updateItem, id: a, expectedRevision: stale, patch: .init(status: .done)))])
    let fresh = current.boardItemRevision(for: a)
    #expect(throws: NoteEditError.boardItemConflict(id: a, currentRevision: fresh)) {
      var copy = current
      _ = try copy.apply([.board(.init(action: .updateItem, id: a, expectedRevision: stale, patch: .init(status: .blocked)))])
    }
    #expect(throws: NoteEditError.boardItemConflict(id: a, currentRevision: fresh)) {
      var copy = current
      _ = try copy.apply([.board(.init(action: .removeItem, id: a, expectedRevision: stale))])
    }
    #expect(throws: WorkspaceToolError.self) {
      var copy = current
      _ = try copy.apply([.board(.init(action: .updateItem, id: a, patch: .init(status: .done)))])
    }
    // A held revision means the card existed when read, so its removal is a conflict.
    for action in [BoardEdit.Action.updateItem, .removeItem] {
      #expect(throws: NoteEditError.boardItemConflict(id: "gone", currentRevision: "")) {
        var copy = current
        _ = try copy.apply([.board(.init(action: action, id: "gone", expectedRevision: stale, patch: .init(status: .done)))])
      }
    }
    #expect(throws: NoteEditError.blockNotFound("gone")) {
      var copy = current
      _ = try copy.apply([.board(.init(action: .linkSession, id: "gone", sessionID: "s"))])
    }
    // The other card was read before this change and is still current.
    _ = try current.apply([.board(.init(action: .updateItem, id: b, expectedRevision: document.boardItemRevision(for: b), patch: .init(review: .approved)))])
    #expect(current.boardItems?[b]?.review == .approved)
  }

  @Test func addingKeepsOriginalsAndRefusesCopies() throws {
    var (document, a, _) = board()
    _ = try document.apply([.board(.init(action: .addItem, id: "link", patch: .init(title: "Spec", status: .todo), assetID: "asset-1"))])
    #expect(document.canvas?["link"]?.assetID == "asset-1")
    #expect(document.canvas?["link"]?.title == "Spec")
    #expect(document.boardItems?["link"]?.task?.status == .todo)
    #expect(throws: NoteEditError.boardLinkedAssetText("copy")) {
      var copy = document
      _ = try copy.apply([.board(.init(action: .addItem, id: "copy", patch: .init(text: "Copied"), assetID: "asset-1"))])
    }
    #expect(throws: NoteEditError.boardLinkedAssetText("link")) {
      var copy = document
      _ = try copy.apply([update("link", in: document, .init(text: "Copied"))])
    }
    #expect(throws: NoteEditError.boardItemExists(a)) {
      var copy = document
      _ = try copy.apply([.board(.init(action: .addItem, id: a))])
    }
    let placements = Array(document.canvasPlacements.values)
    #expect(Set(placements.map { "\($0.x),\($0.y)" }).count == placements.count)
    for (index, first) in placements.enumerated() {
      for second in placements[(index + 1)...] {
        #expect(!(first.x < second.x + second.width && second.x < first.x + first.width && first.y < second.y + second.height && second.y < first.y + first.height))
      }
    }
    #expect(throws: NoteEditError.boardItemNotText("grid")) {
      var copy = document
      copy.blocks.append(.table(.init(id: "grid", columns: [.init(id: "c")], rows: [.init(id: "r", cells: [.init(id: "x")])])))
      _ = try copy.apply([update("grid", in: copy, .init(text: "Nope"))])
    }
  }

  @Test func sessionLinksAreIdempotentAndBounded() throws {
    var (document, a, _) = board()
    let link = BoardEdit(action: .linkSession, id: a, sessionID: "s1")
    _ = try document.apply([.board(link), .board(link)])
    #expect(document.boardItems?[a]?.sessions == ["s1"])
    _ = try document.apply([.board(.init(action: .unlinkSession, id: a, sessionID: "s1")), .board(.init(action: .unlinkSession, id: a, sessionID: "s1"))])
    #expect(document.boardItems?[a]?.sessions == [])
    document.boardItems?[a]?.sessions = (0..<BoardItem.maximumSessions).map { "s\($0)" }
    #expect(throws: NoteEditError.boardSessionLimit(a)) {
      _ = try document.apply([.board(.init(action: .linkSession, id: a, sessionID: "one-more"))])
    }
  }

  @Test func stampingFollowsContentNotLayoutAndCannotBeForged() throws {
    let user = BoardActor(kind: .user), agent = BoardActor(kind: .session, sessionID: "s1", label: "Worker")
    var (old, a, b) = board()
    old.boardItems?[a]?.createdBy = user; old.boardItems?[a]?.createdAt = "2026-01-01T00:00:00Z"
    old.boardItems?[a]?.lastChange = "Earlier"

    var moved = old
    moved.canvas?[a]?.x = 4_000; moved.canvas?[a]?.color = "pink"
    moved.stampBoardChanges(from: old, actor: agent, at: "2026-02-02T00:00:00Z")
    #expect(moved.boardItems == old.boardItems)

    var edited = old
    edited.boardItems?[a]?.task?.status = .done
    edited.boardItems?[b]?.updatedBy = .init(kind: .user, label: "Forged")
    edited.boardItems?[a]?.createdBy = .init(kind: .outside, label: "Forged")
    edited.blocks.append(.richText(.init(id: "new", text: "Added")))
    edited.stampBoardChanges(from: old, actor: agent, at: "2026-02-02T00:00:00Z")
    #expect(edited.boardItems?[a]?.updatedBy == agent)
    #expect(edited.boardItems?[a]?.updatedAt == "2026-02-02T00:00:00Z")
    #expect(edited.boardItems?[a]?.createdBy == user)
    #expect(edited.boardItems?[a]?.lastChange == nil)
    #expect(edited.boardItems?[b]?.updatedBy == nil)
    #expect(edited.boardItems?["new"]?.createdBy == agent)
    #expect(edited.boardItems?["new"]?.updatedBy == agent)

    var summarized = old
    summarized.boardItems?[a]?.lastChange = "Newer"
    summarized.stampBoardChanges(from: old, actor: agent, at: "2026-02-02T00:00:00Z")
    #expect(summarized.boardItems?[a]?.lastChange == "Newer")

    var ordinary = NoteDocument(blocks: [.richText(.init(id: "n", text: "Note"))])
    let copy = ordinary
    ordinary.stampBoardChanges(from: .init(), actor: agent)
    #expect(ordinary == copy)
  }

  @Test func aSummaryFollowsItsParticipantAndAttributionStaysTruthful() throws {
    let user = BoardActor(kind: .user)
    let worker = BoardActor(kind: .session, sessionID: "s1", label: "Worker")
    let reviewer = BoardActor(kind: .session, sessionID: "s2", label: "Reviewer")
    let outside = BoardActor(kind: .outside)
    var (start, a, _) = board()
    start.boardItems?[a]?.lastChange = nil
    /// One write: applies the change, then stamps it as the given participant.
    func write(_ document: NoteDocument, as actor: BoardActor, at time: String, _ change: (inout BoardItem) -> Void) -> NoteDocument {
      var value = document
      change(&value.boardItems![a]!)
      value.stampBoardChanges(from: document, actor: actor, at: time)
      return value
    }

    // The inspector commits per keystroke: a summary survives editing the next field.
    let summarized = write(start, as: user, at: "T1") { $0.lastChange = "Investigated" }
    let continued = write(summarized, as: user, at: "T2") { $0.task?.outcome = "O" }
    #expect(continued.boardItems?[a]?.lastChange == "Investigated")
    #expect(continued.boardItems?[a]?.updatedBy == user)
    #expect(continued.boardItems?[a]?.updatedAt == "T2")
    let typing = write(continued, as: user, at: "T3") { $0.task?.outcome = "Ou" }
    #expect(typing.boardItems?[a]?.lastChange == "Investigated")

    // The same conversation is one participant even after its title changes.
    let byWorker = write(start, as: worker, at: "T1") { $0.lastChange = "Started" }
    let renamed = BoardActor(kind: .session, sessionID: "s1", label: "Renamed worker")
    let workerAgain = write(byWorker, as: renamed, at: "T2") { $0.task?.status = .blocked }
    #expect(workerAgain.boardItems?[a]?.lastChange == "Started")
    #expect(workerAgain.boardItems?[a]?.updatedBy == renamed)

    // A different participant never appears to have written the earlier summary.
    for other in [reviewer, user, outside] {
      let changed = write(byWorker, as: other, at: "T2") { $0.task?.status = .done }
      #expect(changed.boardItems?[a]?.lastChange == nil)
      #expect(changed.boardItems?[a]?.updatedBy == other)
      let explained = write(byWorker, as: other, at: "T2") { $0.task?.status = .done; $0.lastChange = "Finished" }
      #expect(explained.boardItems?[a]?.lastChange == "Finished")
      #expect(explained.boardItems?[a]?.updatedBy == other)
    }
    #expect(write(summarized, as: worker, at: "T2") { $0.review = .approved }.boardItems?[a]?.lastChange == nil)

    // Outside agents share one identity, so continuity cannot be shown between them.
    let byOutside = write(start, as: outside, at: "T1") { $0.lastChange = "External note" }
    #expect(write(byOutside, as: outside, at: "T2") { $0.task?.status = .done }.boardItems?[a]?.lastChange == nil)

    // A summary with no known author is not continued by anyone.
    var unattributed = start
    unattributed.boardItems?[a]?.lastChange = "Legacy"
    #expect(write(unattributed, as: user, at: "T1") { $0.task?.status = .done }.boardItems?[a]?.lastChange == nil)

    // The same participant can still clear it, and layout changes nothing at all.
    #expect(write(byWorker, as: worker, at: "T2") { $0.lastChange = nil }.boardItems?[a]?.lastChange == nil)
    var moved = byWorker
    moved.canvas?[a]?.x += 500
    moved.stampBoardChanges(from: byWorker, actor: reviewer, at: "T2")
    #expect(moved.boardItems?[a] == byWorker.boardItems?[a])
  }

  @Test func stampingAtBoardScaleTouchesOnlyChangedCards() throws {
    let actor = BoardActor(kind: .user)
    let cards = (0..<5_000).map { NoteBlock.richText(.init(id: "card-\($0)", text: "Card \($0)")) }
    let old = NoteDocument(kind: .canvas, blocks: cards, boardItems: ["card-10": .init(lastChange: "Keep")])
    // Reordering cards with automatic placements is layout, not content.
    var reordered = old
    reordered.blocks.reverse()
    reordered.stampBoardChanges(from: old, actor: actor, at: "T1")
    #expect(reordered.boardItems == old.boardItems)

    var edited = old
    edited.blocks[4_999] = .richText(.init(id: "card-4999", text: "Changed"))
    edited.boardItems?["card-20"] = .init(task: .init())
    edited.stampBoardChanges(from: old, actor: actor, at: "T1")
    #expect(Set(edited.boardItems?.keys.map { $0 } ?? []) == ["card-10", "card-20", "card-4999"])
    #expect(edited.boardItems?["card-4999"]?.updatedBy == actor)
    #expect(edited.boardItems?["card-20"]?.updatedBy == actor)
    #expect(edited.boardItems?["card-10"] == old.boardItems?["card-10"])

    // A document that would fail validation still reaches validation instead of trapping.
    var duplicated = old
    duplicated.blocks.append(cards[0])
    duplicated.stampBoardChanges(from: old, actor: actor, at: "T1")
    #expect(throws: NoteDocumentSafetyError.unsupportedFormat) { try duplicated.validateEditableShape() }
  }

  @Test func onlyThePurposeNeedsTheDocumentRevision() throws {
    let (document, a, _) = board()
    #expect(RemoteNoteEditEnvelope.requiresRevision([.board(.init(action: .setPurpose, purpose: "New"))]))
    #expect(!RemoteNoteEditEnvelope.requiresRevision([update(a, in: document, .init(status: .done))]))
    #expect(!RemoteNoteEditEnvelope.requiresRevision([.board(.init(action: .addItem, id: "n"))]))
    #expect(!RemoteNoteEditEnvelope.requiresRevision([.board(.init(action: .linkSession, id: a, sessionID: "s"))]))
    #expect(!RemoteNoteEditEnvelope.requiresRevision([.board(.init(action: .requireBoard))]))
    #expect(RemoteNoteEditEnvelope.requiresRevision([.board(.init(action: .requireBoard)), .setTitle("New")]))
    var unchanged = document
    _ = try unchanged.apply([.board(.init(action: .requireBoard))])
    #expect(unchanged == document)
    #expect(throws: NoteEditError.artifactKindMismatch) {
      var note = NoteDocument()
      _ = try note.apply([.board(.init(action: .requireBoard)), .setTitle("Renamed")])
    }
    #expect(RemoteNoteEditEnvelope.requiresRevision([.canvas(.init(action: .arrange))]))
    #expect(throws: RemoteNoteEditError.operationNotAllowed) {
      try RemoteNoteEditEnvelope.validate(operations: [.board(.init(action: .addItem, id: "n"))], noteKind: .note)
    }
    let operation = update(a, in: document, .init(status: .done))
    #expect(try JSONDecoder().decode(NoteEditOperation.self, from: JSONEncoder().encode(operation)) == operation)
    var cleared = document
    _ = try cleared.apply([.board(.init(action: .setPurpose, purpose: ""))])
    #expect(cleared.boardPurpose == nil)
    #expect(throws: NoteDocumentSafetyError.tooLarge) {
      var copy = document
      _ = try copy.apply([.board(.init(action: .setPurpose, purpose: String(repeating: "x", count: NoteDocument.maximumBoardPurposeBytes + 1)))])
    }
  }

  @Test func readsFilterPageAndReportMissingOriginals() throws {
    var (document, a, b) = board()
    document.canvas?[b]?.assetID = "gone"
    document.canvas?["c"] = .init(x: 900, y: 0, assetID: "present")
    document.blocks.append(.richText(.init(id: "c", text: "Label")))
    document.boardItems?["c"] = .init(role: .instructions, updatedAt: "2026-03-01T00:00:00Z")
    let assets = ["present": BoardAssetSummary(id: "present", available: true, title: "Guide", kind: "note", revision: "7")]
    func components(_ configure: (inout BoardReadFilter) -> Void) throws -> [[String: GatewayJSONValue]] {
      var filter = BoardReadFilter(); configure(&filter)
      let value = try document.pageReadValue(id: "page", title: "Plan", revision: "4", filter: filter, assets: assets)
      #expect(value.objectValue?["purpose"]?.stringValue == "Launch")
      #expect(value.objectValue?["revision"]?.stringValue == "4")
      #expect(value.objectValue?["kind"]?.stringValue == "page")
      #expect(value.objectValue?["notice"]?.stringValue?.contains("does not authorize") == true)
      return try #require(value.objectValue?["components"]?.arrayValue).compactMap(\.objectValue)
    }
    // An unwritten Board reads as its migrated reading order, top to bottom. A titled
    // card with text gets a heading before it, so nothing it showed is lost.
    let all = try components { _ in }
    let titleID = "page-title:\(a)"
    #expect(all.map { $0["componentID"]?.stringValue } == ["c", titleID, a, b])
    let materialized = document.materializedPage()
    #expect(all[0]["asset"]?.objectValue?["title"]?.stringValue == "Guide")
    #expect(all[1]["text"]?.stringValue == "Ship it" && all[1]["style"]?.stringValue == "heading3")
    #expect(all[2]["componentRevision"]?.stringValue == materialized.boardItemRevision(for: a))
    #expect(all[2]["text"]?.stringValue == "First" && all[2]["kind"]?.stringValue == "task")
    #expect(all[3]["text"] == nil && all[3]["kind"]?.stringValue == "asset")
    #expect(all[3]["asset"]?.objectValue?["available"]?.boolValue == false)
    #expect(try components { $0.status = .doing }.map { $0["componentID"]?.stringValue } == [a])
    #expect(try components { $0.needsReview = true }.map { $0["componentID"]?.stringValue } == [b])
    #expect(try components { $0.role = .instructions }.map { $0["componentID"]?.stringValue } == ["c"])
    #expect(try components { $0.changedSince = BoardReadFilter.date("2026-02-01T00:00:00Z") }.map { $0["componentID"]?.stringValue } == ["c"])
    #expect(try components { $0.offset = 1; $0.limit = 1 }.map { $0["componentID"]?.stringValue } == [titleID])
    #expect(try components { $0.offset = Int.max }.isEmpty)
    #expect(all[0]["legacyPlacement"] == nil)
    #expect(try components { $0.includeLayout = true }[0]["legacyPlacement"] != nil)
    var page = BoardReadFilter(); page.limit = 2
    #expect(document.boardAssetIDs(filter: page) == ["present"])
    #expect(document.boardAssetIDs == ["gone", "present"])
  }
}
