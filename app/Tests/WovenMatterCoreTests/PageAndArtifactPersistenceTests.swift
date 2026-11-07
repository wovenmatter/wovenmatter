import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Page and Artifact persistence", .serialized)
struct PageAndArtifactPersistenceTests {
  private func text(_ id: String, _ value: String) -> NoteBlock { .richText(.init(id: id, text: value)) }
  private func set(_ key: String, _ value: GatewayJSONValue, expected: Int? = nil) -> ArtifactStateEdit {
    .init(action: .set, key: key, value: value, expectedVersion: expected)
  }
  private func legacyBoard() -> NoteDocument {
    var titled = CanvasCardPlacement(x: 0, y: 0); titled.title = "Heading"
    var grouped = CanvasCardPlacement(x: 0, y: 200); grouped.sectionID = "s"
    return NoteDocument(kind: .canvas, blocks: [text("a", "In section"), text("b", "")],
      canvas: ["a": grouped, "b": titled], canvasSections: [.init(id: "s", title: "Research", x: 0, y: 100)],
      canvasConnections: [.init(id: "c", from: "a", to: "b", label: "supports")], boardPurpose: "Plan",
      boardItems: ["b": .init(task: .init(status: .todo))])
  }
  private func page(_ blocks: [NoteBlock], nodes: [String: PageNode] = [:]) -> NoteDocument {
    NoteDocument(kind: .canvas, blocks: blocks, pageNodes: nodes)
  }
  private func document(_ response: NoteEditingResponse) throws -> NoteDocument { try #require(response.document) }

  // MARK: Migration

  @Test func anOlderBoardMigratesOnlyOnItsFirstWrite() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let id = try await db.createNote(folderID: nil, title: "Old", content: legacyBoard().encoded(), kind: .canvas)
    let opened = try await db.readNoteForEditing(id: id)
    #expect(try document(opened).pageNodes == nil)

    // Gating and repeating change nothing, so nobody else's revision goes stale.
    let gate = try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: [.page(.init(action: .requirePage))]))
    #expect(gate.revision == opened.revision)
    #expect(try await db.readNoteForEditing(id: id).document?.pageNodes == nil)
    let projected = try document(opened).materializedPage()
    let noop = try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: [.page(.init(action: .unlinkSession, id: "b", sessionID: "none"))]))
    #expect(noop.revision == opened.revision)

    // The token read from the projection is good for the write that migrates.
    let written = try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: [
      .page(.init(action: .update, id: "b", expectedRevision: projected.boardItemRevision(for: "b"), patch: .init(status: .doing)))]))
    let saved = try document(written)
    #expect(written.revision != opened.revision)
    #expect(saved.blocks.map(\.id) == ["b", "page-section:s", "a"])
    #expect(saved.blocks[0].plainText == "Heading")
    #expect(saved.pageParentID(for: "a") == "page-section:s")
    #expect(saved.canvasConnections == legacyBoard().canvasConnections)
    #expect(saved.canvasSections == legacyBoard().canvasSections)
    // Migration is attributed to nobody. Only the edit is stamped.
    #expect(saved.boardItems?["b"]?.updatedBy == BoardActor(kind: .user))
    #expect(saved.boardItems?["page-section:s"] == nil)
    #expect(saved.boardItems?["a"] == nil)
    #expect(try await db.readNoteForEditing(id: id).document == saved)
  }

  // MARK: Nesting

  @Test func nestedComponentsMoveAndRemoveWithoutTouchingOriginals() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let original = try await db.createNote(folderID: nil, title: "Spec", kind: .html)
    let originalBefore = try await db.readNoteForEditing(id: original)
    let id = try await db.createNote(folderID: nil, title: "Plan", content: page([]).encoded(), kind: .canvas)
    func apply(_ edits: PageEdit...) async throws -> NoteDocument {
      try document(try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: edits.map(NoteEditOperation.page))))
    }
    _ = try await apply(.init(action: .add, id: "outer", kind: .section, patch: .init(title: "Outer")),
                        .init(action: .add, id: "inner", kind: .section, patch: .init(title: "Inner"), position: .init(parentID: "outer")),
                        .init(action: .add, id: "task", kind: .task, patch: .init(text: "Do it", assignee: "Me"), position: .init(parentID: "inner")),
                        .init(action: .add, id: "link", patch: .init(title: "The spec"), assetID: original, position: .init(parentID: "inner")))
    var current = try #require(try await db.readNoteForEditing(id: id).document)
    #expect(current.pageSubtreeIDs(of: "outer") == ["outer", "inner", "task", "link"])
    #expect(current.boardItems?["task"]?.createdBy == BoardActor(kind: .user))
    let taskRevision = current.boardItemRevision(for: "task")

    current = try await apply(.init(action: .move, id: "inner", position: .init()))
    #expect(current.pageParentID(for: "inner") == nil && current.pageChildren(of: "outer") == [])
    #expect(current.boardItemRevision(for: "task") == taskRevision)

    // A link to a missing original is refused, and so is a link to the Page itself.
    await #expect(throws: WorkspaceToolError.self) {
      _ = try await apply(.init(action: .add, id: "ghost", assetID: UUID().uuidString.lowercased()))
    }
    await #expect(throws: WorkspaceToolError.self) {
      _ = try await apply(.init(action: .add, id: "self", assetID: id))
    }

    let subtree = current.pageSubtreeRevision(for: "inner")
    _ = try await apply(.init(action: .update, id: "task", expectedRevision: taskRevision, patch: .init(status: .done)))
    await #expect(throws: NoteEditError.self) {
      _ = try await apply(.init(action: .remove, id: "inner", expectedSubtreeRevision: subtree, removal: .removeSubtree))
    }
    let refreshed = try #require(try await db.readNoteForEditing(id: id).document)
    #expect(refreshed.boardItems?["task"]?.task?.status == .done)
    let finished = try await apply(.init(action: .remove, id: "inner", expectedSubtreeRevision: refreshed.pageSubtreeRevision(for: "inner"), removal: .removeSubtree))
    #expect(finished.blocks.map(\.id) == ["outer"])

    // The original is an independent record, untouched by linking or removal.
    let originalAfter = try await db.readNoteForEditing(id: original)
    #expect(originalAfter.revision == originalBefore.revision && originalAfter.document == originalBefore.document)
  }

  @Test func staleComponentAndSubtreeRevisionsChangeNothing() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let id = try await db.createNote(folderID: nil, title: "Plan", content: page([text("a", "A"), text("b", "B")]).encoded(), kind: .canvas)
    let start = try #require(try await db.readNoteForEditing(id: id).document)
    func update(_ component: String, _ revision: String, _ patch: BoardItemPatch) async throws -> NoteEditingResponse {
      try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: [.page(.init(action: .update, id: component, expectedRevision: revision, patch: patch))]))
    }
    // Both held the same document. Different components do not conflict.
    _ = try await update("a", start.boardItemRevision(for: "a"), .init(text: "A2"))
    _ = try await update("b", start.boardItemRevision(for: "b"), .init(text: "B2"))
    let current = try await db.readNoteForEditing(id: id)
    let latest = try document(current).boardItemRevision(for: "a")
    await #expect(throws: NoteEditError.boardItemConflict(id: "a", currentRevision: latest)) {
      _ = try await update("a", start.boardItemRevision(for: "a"), .init(text: "Lost"))
    }
    let after = try await db.readNoteForEditing(id: id)
    #expect(after.revision == current.revision)
    #expect(after.document?.blocks.map(\.plainText) == ["A2", "B2"])
  }

  // MARK: Artifact state

  @Test func stateAndCodeWriteIndependently() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let id = try await db.createNote(folderID: nil, title: "Form", content: NoteDocument(kind: .html, html: "<input id=a>").encoded(), kind: .html)
    let first = try await db.applyArtifactStateEdit(noteID: id, edit: set("form:a", .string("typed")))
    #expect(first.changed && first.version == 1 && first.snapshot.values["form:a"] == .string("typed"))

    // New code on the latest row keeps the state.
    let coded = try await db.applyNoteEdits(.init(command: .apply, noteID: id, expectedRevision: first.revision, operations: [.setHTML("<input id=a><input id=b>")]))
    #expect(coded.document?.artifactState?["form:a"]?.value == .string("typed"))
    // A write from a view that never saw that code cannot rewrite it.
    let second = try await db.applyArtifactStateEdit(noteID: id, edit: set("form:b", .bool(true)))
    #expect(second.changed)
    let row = try await db.readNoteForEditing(id: id)
    #expect(row.document?.html == "<input id=a><input id=b>")
    #expect(row.document?.artifactStateSnapshot.versions == ["form:a": 1, "form:b": 1])

    // A conflict reports the latest entry and writes nothing.
    await #expect(throws: ArtifactStateError.self) {
      _ = try await db.applyArtifactStateEdit(noteID: id, edit: set("form:a", .string("stale")))
    }
    do {
      _ = try await db.applyArtifactStateEdit(noteID: id, edit: set("form:a", .string("stale"), expected: 9))
      Issue.record("A stale version must fail.")
    } catch ArtifactStateError.conflict(let key, let current) {
      #expect(key == "form:a" && current?.value == .string("typed") && current?.version == 1)
    }
    #expect(try await db.readNoteForEditing(id: id).revision == row.revision)

    // Nor can a write pick up anything but state, or reach another kind of asset.
    let plain = try await db.createNote(folderID: nil, title: "Note")
    await #expect(throws: ArtifactStateError.notArtifact) {
      _ = try await db.applyArtifactStateEdit(noteID: plain, edit: set("app:x", .null))
    }
    await #expect(throws: ArtifactStateError.notArtifact) { _ = try await db.artifactStateSnapshot(noteID: plain) }
    await #expect(throws: WorkspaceNoteMutationError.noteNotFound) {
      _ = try await db.applyArtifactStateEdit(noteID: UUID().uuidString.lowercased(), edit: set("app:x", .null))
    }
  }

  @Test func noOpsWriteNothingAndCheckpointsCoalesce() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let id = try await db.createNote(folderID: nil, title: "Form", content: NoteDocument(kind: .html, html: "<input>").encoded(), kind: .html)
    let versionsAtStart = try await db.noteAssetVersions(id: id).count
    let written = try await db.applyArtifactStateEdit(noteID: id, edit: set("app:n", .number(0)))
    let row = try await db.readNoteForEditing(id: id)
    let retry = try await db.applyArtifactStateEdit(noteID: id, edit: set("app:n", .number(0)))
    #expect(!retry.changed && retry.version == 1 && retry.revision == written.revision)
    let absent = try await db.applyArtifactStateEdit(noteID: id, edit: .init(action: .remove, key: "app:absent"))
    #expect(!absent.changed && absent.version == 0)
    #expect(try await db.readNoteForEditing(id: id).revision == row.revision)

    var version = 1
    for value in 1...40 {
      let next = try await db.applyArtifactStateEdit(noteID: id, edit: set("app:n", .number(Double(value)), expected: version))
      version = next.version
    }
    #expect(version == 41)
    // Forty keystrokes cost at most a couple of history entries, not forty.
    let versions = try await db.noteAssetVersions(id: id)
    #expect(versions.count <= versionsAtStart + 2)

    // An agent's state write takes the same path, without a document revision.
    let agent = try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: [.artifactState([set("app:n", .number(99), expected: 41)])]))
    #expect(agent.document?.artifactState?["app:n"]?.version == 42)
    let repeated = try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: [.artifactState([set("app:n", .number(99), expected: 41)])]))
    #expect(repeated.revision == agent.revision)
  }

  @Test func stateSurvivesReopeningWithItsVersions() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let id = try await db.createNote(folderID: nil, title: "Form", content: NoteDocument(kind: .html, html: "<input>").encoded(), kind: .html)
    _ = try await db.applyArtifactStateEdit(noteID: id, edit: set("app:null", .null))
    _ = try await db.applyArtifactStateEdit(noteID: id, edit: set("app:fraction", .number(0.25)))
    _ = try await db.applyArtifactStateEdit(noteID: id, edit: set("app:gone", .string("x")))
    _ = try await db.applyArtifactStateEdit(noteID: id, edit: .init(action: .remove, key: "app:gone", expectedVersion: 1))
    let reopened = try await fixture.openDatabase()
    let snapshot = try await reopened.artifactStateSnapshot(noteID: id)
    #expect(snapshot.values == ["app:null": .null, "app:fraction": .number(0.25)])
    #expect(snapshot.versions == ["app:null": 1, "app:fraction": 1, "app:gone": 2])
    // Nothing about saved state makes the document read-only.
    let row = try await reopened.readNoteForEditing(id: id)
    #expect(row.document?.artifactState?["app:gone"]?.isTombstone == true)
    let back = try await reopened.applyArtifactStateEdit(noteID: id, edit: set("app:gone", .string("back"), expected: 2))
    #expect(back.version == 3)
    // History covers saved state, so a checkpoint can bring it back.
    try await reopened.write { try $0.checkpointNote(id: id) }
    let retained = try await reopened.noteAssetVersions(id: id)
    #expect(retained.contains { $0.content.contains("app:fraction") })
  }

  @Test func aStaleCodeDraftKeepsNewerState() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let base = try NoteDocument(kind: .html, html: "<input id=a>").encoded()
    let id = try await db.createNote(folderID: nil, title: "Form", content: base, kind: .html)
    let opened = try await db.readNoteForEditing(id: id)
    let baseContent = try await db.noteAssetVersions(id: id).first?.content ?? base
    let state = try await db.applyArtifactStateEdit(noteID: id, edit: set("form:a", .string("typed")))
    #expect(state.revision != opened.revision)

    let draft = try NoteDocument(kind: .html, html: "<input id=a><p>edited</p>").encoded()
    // Without knowing what the draft came from, nothing can be assumed.
    await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
      _ = try await db.persistNoteDraft(id: id, title: "Form", content: draft, expectedRevision: opened.revision)
    }
    #expect(try await db.persistNoteDraft(id: id, title: "Form", content: draft, expectedRevision: opened.revision, baseContent: baseContent, baseTitle: "Form"))
    let saved = try await db.readNoteForEditing(id: id)
    #expect(saved.document?.html == "<input id=a><p>edited</p>")
    #expect(saved.document?.artifactState?["form:a"]?.value == .string("typed"))
    #expect(saved.document?.artifactState?["form:a"]?.version == 1)

    // A current draft holding older state cannot rewind it either.
    _ = try await db.applyArtifactStateEdit(noteID: id, edit: set("form:a", .string("newer"), expected: 1))
    let latest = try await db.readNoteForEditing(id: id)
    let current = try #require(latest.document)
    var stale = current
    stale.html = "<input id=a><p>again</p>"
    stale.artifactState = saved.document?.artifactState
    let savedContent = try document(saved).encoded()
    #expect(try await db.persistNoteDraft(id: id, title: "Form", content: stale.encoded(), expectedRevision: saved.revision,
      baseContent: savedContent, baseTitle: "Form"))
    let kept = try await db.readNoteForEditing(id: id)
    #expect(kept.document?.artifactState?["form:a"]?.value == .string("newer"))
    #expect(kept.document?.html == "<input id=a><p>again</p>")
  }

  @Test func competingCodeStillGoesToRecovery() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let base = try NoteDocument(kind: .html, html: "<p>base</p>").encoded()
    let id = try await db.createNote(folderID: nil, title: "Form", content: base, kind: .html)
    let opened = try await db.readNoteForEditing(id: id)
    let baseContent = try document(opened).encoded()
    let revision = try #require(opened.revision)
    _ = try await db.applyNoteEdits(.init(command: .apply, noteID: id, expectedRevision: revision, operations: [.setHTML("<p>agent</p>")]))
    let before = try await db.readNoteForEditing(id: id)
    let mine = try NoteDocument(kind: .html, html: "<p>mine</p>").encoded()
    await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
      _ = try await db.persistNoteDraft(id: id, title: "Form", content: mine, expectedRevision: revision, baseContent: baseContent, baseTitle: "Form")
    }
    let after = try await db.readNoteForEditing(id: id)
    #expect(after.revision == before.revision && after.document?.html == "<p>agent</p>")
    // A draft that only renamed lands on the agent's code instead of failing.
    #expect(try await db.persistNoteDraft(id: id, title: "Renamed", content: baseContent, expectedRevision: revision, baseContent: baseContent, baseTitle: "Form"))
    let renamed = try await db.readNoteForEditing(id: id)
    #expect(renamed.title == "Renamed" && renamed.document?.html == "<p>agent</p>")
  }

  @Test func restoringCodeKeepsWhatPeopleEnteredSince() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let id = try await db.createNote(folderID: nil, title: "Form", content: NoteDocument(kind: .html, html: "<p>first</p>").encoded(), kind: .html)
    let first = try #require(try await db.noteAssetVersions(id: id).first)
    let revision = try #require(try await db.readNoteForEditing(id: id).revision)
    _ = try await db.applyNoteEdits(.init(command: .apply, noteID: id, expectedRevision: revision, operations: [.setHTML("<p>second</p>")]))
    _ = try await db.applyArtifactStateEdit(noteID: id, edit: set("app:x", .string("entered")))
    let current = try #require(try await db.readNoteForEditing(id: id).revision)
    let restored = try await db.restoreNoteAssetVersion(noteID: id, versionID: first.id, expectedRevision: current)
    #expect(restored.document?.html == "<p>first</p>")
    #expect(restored.document?.artifactState?["app:x"]?.value == .string("entered"))
    #expect(try await db.readNoteForEditing(id: id).document?.artifactState?["app:x"]?.version == 1)
  }

  // MARK: Page drafts

  @Test func autosaveCoexistsWithAnEditToAnotherComponent() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let start = page([text("typing", "Draft"), text("task", "Task")])
    let id = try await db.createNote(folderID: nil, title: "Plan", content: start.encoded(), kind: .canvas)
    let opened = try await db.readNoteForEditing(id: id)
    let base = try document(opened).encoded()
    let agent = try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: [
      .page(.init(action: .update, id: "task", expectedRevision: start.boardItemRevision(for: "task"), patch: .init(status: .done)))]))
    #expect(agent.revision != opened.revision)

    var typed = try document(opened)
    try typed.spliceFlow(["typing", "task"], with: [text("typing", "Draft and more"), text("task", "Task")], parentID: nil)
    // Without a base the save still conflicts, exactly as before.
    await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
      _ = try await db.persistNoteDraft(id: id, title: "Plan", content: typed.encoded(), expectedRevision: opened.revision)
    }
    let operation = UUID().uuidString.lowercased()
    #expect(try await db.persistNoteDraft(id: id, title: "Plan", content: typed.encoded(), expectedRevision: opened.revision, operationID: operation, baseContent: base, baseTitle: "Plan"))
    let merged = try #require(try await db.readNoteForEditing(id: id).document)
    #expect(merged.blocks[0].plainText == "Draft and more")
    #expect(merged.boardItems?["task"]?.task?.status == .done)
    #expect(merged.boardItems?["typing"]?.updatedBy == BoardActor(kind: .user))
    // Replaying the same save is acknowledged by its receipt, with no second write.
    let revision = try await db.readNoteForEditing(id: id).revision
    #expect(try await db.persistNoteDraft(id: id, title: "Plan", content: typed.encoded(), expectedRevision: opened.revision, operationID: operation, baseContent: base, baseTitle: "Plan"))
    #expect(try await db.readNoteForEditing(id: id).revision == revision)
    #expect(try await db.companionDraftRevision(operationID: operation) == revision)
  }

  @Test func aChainedAutosaveCannotDropAnEarlierMerge() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let start = page([text("typing", "One"), text("task", "Task")])
    let id = try await db.createNote(folderID: nil, title: "Plan", content: start.encoded(), kind: .canvas)
    let opened = try await db.readNoteForEditing(id: id)
    let base = try document(opened).encoded()
    _ = try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: [
      .page(.init(action: .update, id: "task", expectedRevision: start.boardItemRevision(for: "task"), patch: .init(status: .done)))]))
    let firstDraft = try page([text("typing", "One two"), text("task", "Task")]).encoded()
    _ = try await db.persistNoteDraft(id: id, title: "Plan", content: firstDraft, expectedRevision: opened.revision, baseContent: base, baseTitle: "Plan")
    let merged = try await db.readNoteForEditing(id: id)

    // Rebased by the write-behind: the current revision, whose text lacks the agent's task change.
    let secondDraft = try page([text("typing", "One two three"), text("task", "Task")]).encoded()
    _ = try await db.persistNoteDraft(id: id, title: "Plan", content: secondDraft, expectedRevision: merged.revision, baseContent: firstDraft, baseTitle: "Plan")
    let saved = try #require(try await db.readNoteForEditing(id: id).document)
    #expect(saved.blocks[0].plainText == "One two three")
    #expect(saved.boardItems?["task"]?.task?.status == .done)
  }

  @Test func theSameComponentRetainsBothVersions() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let start = page([text("shared", "Base")])
    let id = try await db.createNote(folderID: nil, title: "Plan", content: start.encoded(), kind: .canvas)
    let opened = try await db.readNoteForEditing(id: id)
    let base = try document(opened).encoded()
    _ = try await db.applyNoteEdits(.init(command: .apply, noteID: id, operations: [
      .page(.init(action: .update, id: "shared", expectedRevision: start.boardItemRevision(for: "shared"), patch: .init(text: "Agent version")))]))
    let draft = try page([text("shared", "My version")]).encoded()
    #expect(try await db.persistNoteDraft(id: id, title: "Plan", content: draft, expectedRevision: opened.revision, baseContent: base, baseTitle: "Plan"))
    let saved = try #require(try await db.readNoteForEditing(id: id).document)
    #expect(saved.blocks.map(\.plainText) == ["Agent version", "My version"])
    let copy = try #require(saved.blocks.last?.id)
    #expect(saved.boardItems?[copy]?.review == .needed)
    #expect(saved.boardItems?[copy]?.createdBy == BoardActor(kind: .user))

    // A title both sides changed differently still goes to recovery, with nothing written.
    let row = try await db.readNoteForEditing(id: id)
    try await db.mutateNote(id: id, mutation: .rename("Agent title"), expectedRevision: db.noteActionRevision(id: id))
    await #expect(throws: WorkspaceNoteMutationError.revisionConflict) {
      _ = try await db.persistNoteDraft(id: id, title: "My title", content: draft, expectedRevision: row.revision, baseContent: base, baseTitle: "Plan")
    }
    #expect(try await db.readNoteForEditing(id: id).title == "Agent title")
  }

  @Test func aFutureStateFieldStaysReadOnlyAndUntouched() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let db = try await fixture.openDatabase()
    let id = try await db.createNote(folderID: nil, title: "Form", content: NoteDocument(kind: .html, html: "<input>").encoded(), kind: .html)
    _ = try await db.applyArtifactStateEdit(noteID: id, edit: set("app:x", .number(1)))
    let future = #"{"artifactState":{"app:x":{"futureField":true,"updatedAt":"t","value":1,"version":1}},"blocks":[],"html":"<input>","kind":"html","version":2}"#
    try await db.write { try $0.toolsExecuteUnlocked("UPDATE notes SET content=? WHERE id=?", [future, id]) }
    await #expect(throws: NoteDocumentSafetyError.unsupportedFormat) {
      _ = try await db.applyArtifactStateEdit(noteID: id, edit: set("app:x", .number(2), expected: 1))
    }
    let raw = try await db.write { try $0.historyRowsUnlocked("SELECT content FROM notes WHERE id=?", values: [id]) }
    #expect(raw.first?.objectValue?["content"]?.stringValue == future)
  }
}
