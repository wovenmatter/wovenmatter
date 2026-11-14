import Foundation
import Testing
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterLibraryStore

/// `peer_sync_versions` keeps, per shared row, only the versions that still
/// matter, each at the cursor it was last written or kept under. Paging by
/// cursor therefore delivers each row's current versions once, and peers
/// converge on the same winners and conflicts as when every version was sent.
@Suite("Peer sync versions", .serialized)
struct PeerSyncVersionsTests {
  private struct Mac {
    let persistence: PersistenceFixture
    let database: WorkspaceDatabase
    let id: String
    init() async throws {
      persistence = try PersistenceFixture()
      database = try await persistence.openDatabase()
      id = try await database.libraryIdentity().hostDeviceID
    }
    func remove() { persistence.remove() }
    func note(_ id: String, title: String) async throws {
      let content = try NoteDocument(blocks: [.richText(.init(text: title))]).encoded()
      let revision = try await database.libraryNote(id: id)?.revision
      let receipt = try await database.applyLibraryMutation(.init(deviceID: self.id,
        kind: revision == nil ? .createNote : .updateNote, resourceID: id, expectedRevision: revision, title: title, content: content))
      #expect(receipt.status == .accepted)
    }
    /// Pages after `other`'s receive cursor until done, `limit` records at a time.
    func send(to other: Mac, limit: Int = 100, pages: Int = 1000) async throws {
      for _ in 0..<pages {
        let cursor = try await other.database.peerSyncCursors(id).pulled
        let page = try await database.read { try $0.pairedLibraryPage(after: cursor, limit: limit) }
        try await other.database.receivePairedLibrary(page, from: id)
        if !page.hasMore { return }
      }
    }
    func versions(_ table: String, _ key: String) async throws -> [[String: JSONValue]] {
      try await database.read {
        try $0.historyRowsUnlocked("SELECT cursor,origin,clock,pending_peer,payload FROM peer_sync_versions WHERE table_name=? AND record_key=? ORDER BY origin,clock",
                                   values: [table, key]).compactMap(\.objectValue)
      }
    }
  }
  private func identities(_ rows: [[String: JSONValue]]) -> [String] {
    rows.map { ($0["origin"]?.stringValue ?? "") + ":" + String($0["clock"]?.intValue ?? 0) }
  }

  @Test func aRowUpdatedManyTimesKeepsOneVersion() async throws {
    let a = try await Mac(); defer { a.remove() }
    let id = UUID().uuidString.lowercased()
    try await a.note(id, title: "Draft 0")
    let first = try await a.database.peerSyncHead()
    for revision in 1..<20 { try await a.note(id, title: "Draft \(revision)") }
    let kept = try await a.versions("notes", "[\"\(id)\"]")
    #expect(kept.count == 1)
    let record = try #require(try kept.first?["payload"]?.stringValue.map { try JSONDecoder().decode(PairedLibraryRecord.self, from: Data($0.utf8)) })
    #expect(record.row["title"]?.value == "Draft 19")
    // The version moved to a cursor after every earlier one.
    #expect((kept.first?["cursor"]?.intValue).map(Int64.init) ?? 0 > first)
  }

  @Test func aPeerThatPulledBeforeTheUpdatesReceivesOnlyTheLatestVersion() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased(), key = "[\"\(id)\"]"
    try await a.note(id, title: "First")
    try await a.send(to: b)
    let pulled = try await b.database.peerSyncCursors(a.id).pulled
    for revision in 0..<10 { try await a.note(id, title: "Edit \(revision)") }
    let page = try await a.database.pairedLibraryPage(after: pulled)
    let delivered = page.entries.filter { $0.table == "notes" && $0.key == key }
    #expect(delivered.count == 1 && delivered.first?.row["title"]?.value == "Edit 9")
    try await b.database.receivePairedLibrary(page, from: a.id)
    #expect(try await b.database.libraryNote(id: id)?.title == "Edit 9")
    #expect(try await identities(b.versions("notes", key)) == identities(a.versions("notes", key)))
  }

  /// Writing continues between the pages of one catch-up; each later version
  /// takes a cursor beyond the receiver's, so nothing is skipped.
  @Test func aPeerThatPulledMidwayConverges() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let notes = (0..<4).map { _ in UUID().uuidString.lowercased() }
    for note in notes { try await a.note(note, title: "Start") }
    for round in 0..<6 {
      try await a.send(to: b, limit: 1, pages: 2)
      for note in notes where round % 2 == 0 || note == notes[0] { try await a.note(note, title: "Round \(round)") }
    }
    try await a.send(to: b)
    for note in notes {
      #expect(try await b.database.libraryNote(id: note)?.title == a.database.libraryNote(id: note)?.title)
      #expect(try await identities(b.versions("notes", "[\"\(note)\"]")) == identities(a.versions("notes", "[\"\(note)\"]")))
    }
    #expect(try await a.database.pairedLibraryPage(after: b.database.peerSyncCursors(a.id).pulled).entries.isEmpty)
  }

  /// Concurrent edits keep both versions, the same winner and the same
  /// conflict on both Macs. A later edit made with both in hand supersedes
  /// them: one version is left, the conflict is settled, and the recovered
  /// copy of the losing note stays.
  @Test func concurrentVersionsKeepTheSameWinnerAndConflictUntilALaterEditSettlesThem() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased(), key = "[\"\(id)\"]"
    try await a.note(id, title: "Shared")
    try await a.send(to: b); try await b.send(to: a)
    try await a.note(id, title: "Air edit")
    try await b.note(id, title: "Mini edit")
    try await a.send(to: b); try await b.send(to: a)
    #expect(try await a.database.libraryNote(id: id)?.title == b.database.libraryNote(id: id)?.title)
    let both = try await identities(a.versions("notes", key)), onB = try await identities(b.versions("notes", key))
    #expect(both.count == 2 && both == onB)
    let conflicts = try await a.database.peerSyncConflicts().filter { $0.record.table == "notes" }.map(\.id)
    let conflictsOnB = try await b.database.peerSyncConflicts().filter { $0.record.table == "notes" }.map(\.id)
    #expect(conflicts.count == 1 && conflicts == conflictsOnB)
    try await a.note(id, title: "Resolved on the Air")
    try await a.send(to: b); try await b.send(to: a)
    for mac in [a, b] {
      #expect(try await mac.versions("notes", key).count == 1)
      #expect(try await mac.database.libraryNote(id: id)?.title == "Resolved on the Air")
      #expect(try await mac.database.peerSyncConflicts().filter { $0.record.table == "notes" }.isEmpty)
      #expect(try await mac.database.librarySnapshot().notes.contains { $0.title.hasSuffix("(Recovered edit)") })
    }
  }

  /// A deletion records the key and the conversation, and removes the row on
  /// a peer that already had it and on one that never did.
  @Test func tombstonesCarryOnlyTheKeyAndApply() async throws {
    let a = try await Mac(), b = try await Mac(), c = try await Mac(); defer { a.remove(); b.remove(); c.remove() }
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Owner's chat", ownerDeviceID: UUID())
    _ = try await a.database.beginLocalACPRun(conversationID: session, input: .init(text: "Hello"))
    try await a.send(to: b)
    let message = try #require(try await a.database.read {
      try $0.historyRowsUnlocked("SELECT id FROM messages WHERE conversation_id=? AND role='user'", values: [session]).first?.objectValue?["id"]?.stringValue
    })
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT id FROM messages WHERE id=?", values: [message]).isEmpty } == false)
    try await a.database.write { try $0.toolsExecuteUnlocked("DELETE FROM messages WHERE id=?", [message]) }
    let kept = try await a.versions("messages", "[\"\(message)\"]")
    #expect(kept.count == 1)
    let tombstone = try #require(try kept.first?["payload"]?.stringValue.map { try JSONDecoder().decode(PairedLibraryRecord.self, from: Data($0.utf8)) })
    #expect(tombstone.deleted && tombstone.row == ["id": .init(type: "text", value: message), "conversation_id": .init(type: "text", value: session)])
    try await a.send(to: b); try await a.send(to: c)
    for mac in [b, c] {
      #expect(try await mac.database.read { try $0.historyRowsUnlocked("SELECT id FROM messages WHERE id=?", values: [message]).isEmpty })
      #expect(try await identities(mac.versions("messages", "[\"\(message)\"]")) == identities(kept))
    }
  }

  /// A version waiting for its bytes is relayed under one cursor and applies
  /// in place under that cursor once they arrive.
  @Test func aWaitingVersionMaterializesUnderTheCursorItWasRelayedWith() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let content = String(repeating: "Native archive bytes 🧵", count: 30_000), eventID = UUID().uuidString.lowercased()
    try await a.database.recordHistory(.init(id: eventID, harness: "fixture", kind: "native.fixture", payload: content))
    try await a.send(to: b)
    let waiting = try #require(try await b.versions("history_events", "[\"\(eventID)\"]").first)
    #expect(waiting["pending_peer"]?.stringValue == a.id)
    let files = PairedLibraryFiles(root: a.persistence.directory), receiver = PairedLibraryFiles(root: b.persistence.directory)
    for file in try await files.page(after: "").files {
      while let offset = try await receiver.nextOffset(file) { try await receiver.receive(files.chunk(.init(file: file, offset: offset))) }
    }
    try await b.database.materializePendingPeerRecords()
    let applied = try #require(try await b.versions("history_events", "[\"\(eventID)\"]").first)
    #expect(applied["cursor"] == waiting["cursor"] && applied["pending_peer"]?.stringValue == nil)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT payload FROM history_events WHERE id=?", values: [eventID]).first?.objectValue?["payload"]?.stringValue } == content)
  }
}
