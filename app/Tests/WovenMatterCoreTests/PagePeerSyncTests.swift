import Foundation
import WovenMatterClient
import WorkspaceFixtures
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

/// Pages and Artifacts edited at once on paired Macs and a Linux host, by people, agents and
/// phones, merge into one version on every replica.
@Suite("Page and Artifact sync between Macs and Linux", .serialized)
struct PagePeerSyncTests {
  private struct Replica {
    let persistence: PersistenceFixture
    let database: WorkspaceDatabase
    let id: String
    let isLinux: Bool
    init(linux: Bool = false) async throws {
      persistence = try PersistenceFixture()
      database = try await persistence.openDatabase()
      id = try await database.libraryIdentity().hostDeviceID
      isLinux = linux
    }
    func remove() { persistence.remove() }
    func send(to other: Replica, members: [Replica]) async throws {
      let sender = isLinux ? PairedLibrarySender(deviceID: id, kind: .linux,
        members: members.map { .init(deviceID: $0.id, kind: $0.isLinux ? .linux : .mac, endpoints: [], revoked: false) }) : nil
      var cursor = try await other.database.peerSyncCursors(id).pulled
      for _ in 0..<1000 {
        let page = try await database.pairedLibraryPage(after: cursor)
        try await other.database.receivePairedLibrary(page, from: id, sender: sender)
        cursor = page.cursor
        if !page.hasMore { return }
      }
      Issue.record("Peer replay did not finish")
    }
    func document(_ id: String) async throws -> NoteDocument { try #require(try await database.readNoteForEditing(id: id).document) }
    func texts(_ id: String) async throws -> [String] { try await document(id).blocks.map(\.plainText) }
    /// A person on a phone paired with this replica.
    func phoneUpdate(_ noteID: String, _ change: (inout NoteDocument) throws -> Void) async throws {
      let note = try #require(try await database.libraryNote(id: noteID))
      var page = try NoteDocument.editableDocument(from: note.content)
      try change(&page)
      let receipt = try await database.applyLibraryMutation(.init(deviceID: UUID().uuidString.lowercased(), kind: .updateNote,
        resourceID: noteID, expectedRevision: note.revision, folderID: note.folderID, title: note.title, content: page.encoded()))
      #expect(receipt.status == .accepted)
    }
    /// An agent's Page tool on this replica.
    func agentUpdate(_ noteID: String, _ component: String, _ text: String) async throws {
      let current = try await document(noteID)
      _ = try await database.applyNoteEdits(.init(command: .apply, noteID: noteID, operations: [
        .page(.init(action: .update, id: component, expectedRevision: current.boardItemRevision(for: component), patch: .init(text: text)))
      ]))
    }
    /// The person typing in this Mac's Page editor.
    func editorUpdate(_ noteID: String, _ change: (inout NoteDocument) throws -> Void) async throws {
      let note = try #require(try await database.workspaceOverview().notes.first { $0.id == noteID })
      var page = try NoteDocument.editableDocument(from: note.content)
      try change(&page)
      try await database.persistNoteDraft(id: noteID, title: note.title, content: page.encoded(), expectedRevision: note.revision)
    }
  }

  private func everyone(_ replicas: [Replica]) async throws {
    for _ in 0..<2 {
      for source in replicas { for target in replicas where target.id != source.id { try await source.send(to: target, members: replicas) } }
    }
  }

  private func update(_ id: String, _ text: String) -> (inout NoteDocument) throws -> Void {
    { page in try page.applyPageEdit(.init(action: .update, id: id, expectedRevision: page.boardItemRevision(for: id), patch: .init(text: text))) }
  }

  /// Every replica holds the same Page and nothing else, and no reader sees the clocks.
  private func expectConverged(_ replicas: [Replica], on id: String, sourceFile: String = #fileID, line: Int = #line) async throws {
    var contents = Set<String>()
    for replica in replicas {
      let snapshot = try await replica.database.librarySnapshot()
      #expect(!snapshot.notes.contains { $0.title.contains("Recovered edit") })
      let note = try #require(try await replica.database.libraryNote(id: id))
      #expect(!note.content.contains("~sync"))
      #expect(try await replica.database.workspaceOverview().notes.first { $0.id == id }?.content == note.content)
      contents.insert(note.content)
    }
    #expect(contents.count == 1)
  }

  private func makePage(on replica: Replica, _ texts: [(String, String)]) async throws -> String {
    let page = NoteDocument(kind: .canvas, blocks: texts.map { .richText(.init(id: $0.0, text: $0.1)) }, pageNodes: [:])
    return try await replica.database.createNote(folderID: nil, title: "Launch", content: page.encoded(), kind: .canvas)
  }

  @Test func concurrentEditsFromMacsLinuxPhonesAndAgentsAllStay() async throws {
    let air = try await Replica(), mini = try await Replica(), linux = try await Replica(linux: true)
    defer { air.remove(); mini.remove(); linux.remove() }
    let all = [air, mini, linux]
    let id = try await makePage(on: air, [("a", "one"), ("b", "two"), ("c", "three"), ("d", "four")])
    try await everyone(all)
    // Apart: an agent on the Air, a phone paired with the Mini, an agent on the Linux host
    // and a person in the Mini's editor each change a different component.
    try await air.agentUpdate(id, "a", "one, from an agent on the Air")
    try await mini.phoneUpdate(id, update("b", "two, from a phone"))
    try await linux.agentUpdate(id, "c", "three, from an agent on Linux")
    try await mini.editorUpdate(id, update("d", "four, typed on the Mini"))
    try await everyone(all)
    try await expectConverged(all, on: id)
    #expect(try await linux.texts(id) == ["one, from an agent on the Air", "two, from a phone", "three, from an agent on Linux", "four, typed on the Mini"])

    // Writing after the merge builds on it everywhere.
    try await linux.phoneUpdate(id, update("a", "one, revised on a phone paired with Linux"))
    try await air.editorUpdate(id, update("d", "four, revised on the Air"))
    try await everyone(all)
    try await expectConverged(all, on: id)
    #expect(try await mini.texts(id) == ["one, revised on a phone paired with Linux", "two, from a phone", "three, from an agent on Linux", "four, revised on the Air"])
  }

  @Test func bothVersionsOfOneComponentStayOnThePageUntilReviewed() async throws {
    let air = try await Replica(), linux = try await Replica(linux: true)
    defer { air.remove(); linux.remove() }
    let id = try await makePage(on: air, [("a", "one"), ("b", "two")])
    try await everyone([air, linux])
    try await air.editorUpdate(id, update("a", "Air wording"))
    try await linux.agentUpdate(id, "a", "Linux wording")
    try await everyone([air, linux])
    try await expectConverged([air, linux], on: id)
    let merged = try await air.document(id)
    #expect(Set(merged.blocks.map(\.plainText)) == ["Air wording", "Linux wording", "two"])
    let copy = try #require(merged.blocks.first { $0.id.hasPrefix("conflict-") })
    #expect(merged.boardItems?[copy.id]?.review == .needed)

    // Reviewing on one replica removes the copy everywhere.
    try await linux.editorUpdate(id) { page in
      try page.applyPageEdit(.init(action: .remove, id: copy.id, expectedRevision: page.boardItemRevision(for: copy.id)))
    }
    try await everyone([air, linux])
    try await expectConverged([air, linux], on: id)
    #expect(try await air.document(id).blocks.count == 2)
  }

  @Test func reviewingACopyWhileAnotherReplicaWritesStillRemovesIt() async throws {
    let air = try await Replica(), linux = try await Replica(linux: true)
    defer { air.remove(); linux.remove() }
    let id = try await makePage(on: air, [("a", "one"), ("b", "two")])
    try await everyone([air, linux])
    try await air.editorUpdate(id, update("a", "Air wording"))
    try await linux.agentUpdate(id, "a", "Linux wording")
    try await everyone([air, linux])
    let copy = try #require(try await air.document(id).blocks.first { $0.id.hasPrefix("conflict-") })
    // At once: the Air reviews the copy away while an agent on Linux edits another component.
    try await air.editorUpdate(id) { page in
      try page.applyPageEdit(.init(action: .remove, id: copy.id, expectedRevision: page.boardItemRevision(for: copy.id)))
    }
    try await linux.agentUpdate(id, "b", "two, from Linux")
    try await everyone([air, linux])
    try await expectConverged([air, linux], on: id)
    let texts = try await linux.texts(id)
    #expect(texts.count == 2 && texts.contains("two, from Linux"))
    #expect(!(try await air.document(id).blocks.contains { $0.id == copy.id }))
  }

  @Test func artifactInputsTypedOnTwoReplicasAtOnceBothStay() async throws {
    let air = try await Replica(), linux = try await Replica(linux: true)
    defer { air.remove(); linux.remove() }
    let id = try await air.database.createNote(folderID: nil, title: "Trip",
      content: NoteDocument(kind: .html, html: "<input id='from'><input id='to'>").encoded(), kind: .html)
    try await everyone([air, linux])
    _ = try await air.database.applyArtifactStateEdit(noteID: id, edit: .init(action: .set, key: "form:text:from:0", value: .string("Lisbon")))
    _ = try await linux.database.applyArtifactStateEdit(noteID: id, edit: .init(action: .set, key: "form:text:to:0", value: .string("Porto")))
    try await everyone([air, linux])
    try await expectConverged([air, linux], on: id)
    for replica in [air, linux] {
      let values = try await replica.database.artifactStateSnapshot(noteID: id).values
      #expect(values["form:text:from:0"] == .string("Lisbon") && values["form:text:to:0"] == .string("Porto"))
    }
  }

  @Test func renamesAndMovesMergeWithContentEdits() async throws {
    let air = try await Replica(), mini = try await Replica()
    defer { air.remove(); mini.remove() }
    let id = try await makePage(on: air, [("a", "one")])
    try await everyone([air, mini])
    try await air.database.mutateNote(id: id, mutation: .rename("Launch plan"), expectedRevision: air.database.noteActionRevision(id: id))
    try await mini.agentUpdate(id, "a", "one, edited")
    try await everyone([air, mini])
    try await expectConverged([air, mini], on: id)
    #expect(try await mini.database.libraryNote(id: id)?.title == "Launch plan")
    #expect(try await air.texts(id) == ["one, edited"])
  }

  @Test func notesStillKeepARecoveredCopy() async throws {
    let air = try await Replica(), mini = try await Replica()
    defer { air.remove(); mini.remove() }
    let id = try await air.database.createNote(folderID: nil, title: "Note",
      content: NoteDocument(blocks: [.richText(.init(id: "a", text: "one"))]).encoded())
    try await everyone([air, mini])
    try await air.phoneUpdate(id) { $0.blocks = [.richText(.init(id: "a", text: "Air"))] }
    try await mini.phoneUpdate(id) { $0.blocks = [.richText(.init(id: "a", text: "Mini"))] }
    try await everyone([air, mini])
    #expect(try await air.database.librarySnapshot().notes.contains { $0.title.contains("Recovered edit") })
  }
}
