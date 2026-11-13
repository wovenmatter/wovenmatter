import Foundation
#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
#if canImport(SQLite3)
import SQLite3
#else
import CSQLite
#endif
import WovenMatterClient
import WorkspaceFixtures
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Equal paired Mac libraries", .serialized)
struct PairedLibraryTests {
  private struct Mac {
    let persistence: PersistenceFixture
    let database: WorkspaceDatabase
    let id: String
    var directory: URL { persistence.directory }
    init() async throws {
      persistence = try PersistenceFixture()
      database = try await persistence.openDatabase()
      id = try await database.libraryIdentity().hostDeviceID
    }
    func remove() { persistence.remove() }
    func note(_ id: String, title: String, revision: Int64? = nil) async throws {
      let content = try NoteDocument(blocks: [.richText(.init(text: title))]).encoded()
      let receipt = try await database.applyLibraryMutation(.init(deviceID: self.id,
        kind: revision == nil ? .createNote : .updateNote, resourceID: id, expectedRevision: revision,
        title: title, content: content))
      #expect(receipt.status == .accepted)
    }
    func send(to other: Mac) async throws {
      var cursor = try await other.database.pairedLibraryCursors(id).pulled
      for _ in 0..<1000 {
        let page = try await database.pairedLibraryPage(after: cursor)
        try await other.database.receivePairedLibrary(page, from: id)
        cursor = page.cursor
        if !page.hasMore { return }
      }
      Issue.record("Peer replay did not finish")
    }
  }

  @Test func offlineEditsConvergeAcrossThreeMacsWithoutAnAuthority() async throws {
    let a = try await Mac(), b = try await Mac(), c = try await Mac()
    defer { a.remove(); b.remove(); c.remove() }
    let first = UUID().uuidString.lowercased(), second = UUID().uuidString.lowercased()
    try await a.note(first, title: "Air offline")
    try await b.note(second, title: "Mini offline")
    try await a.send(to: b); try await b.send(to: a)
    // The third Mac learns the Air's writing through the Mini, with the Air off.
    try await b.send(to: c)
    #expect(try await c.database.libraryNote(id: first)?.title == "Air offline")
    #expect(try await c.database.libraryNote(id: second)?.title == "Mini offline")
    try await c.note(first, title: "Third Mac edit", revision: c.database.libraryNote(id: first)?.revision)
    try await c.send(to: a); try await a.send(to: b)
    #expect(try await a.database.libraryNote(id: first)?.title == "Third Mac edit")
    #expect(try await b.database.libraryNote(id: first)?.title == "Third Mac edit")
    #expect(try await a.database.libraryIdentity().hostDeviceID == a.id)
    #expect(try await b.database.libraryIdentity().hostDeviceID == b.id)
    #expect(try await a.database.libraryID() != b.database.libraryID())
  }

  @Test func nestedPagesAndArtifactInputStateUseTheExistingPairedLibraryPath() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let artifact = try await a.database.createNote(folderID: nil, title: "Planner",
      content: NoteDocument(kind: .html, html: "<input id='title'>").encoded(), kind: .html)
    _ = try await a.database.applyArtifactStateEdit(noteID: artifact,
      edit: .init(action: .set, key: "form:text:title:0", value: .string("Trip plan")))
    let page = NoteDocument(kind: .canvas, blocks: [.richText(.init(id: "section", text: "Work")), .richText(.init(id: "embed", text: ""))],
      canvas: ["embed": .init(x: 0, y: 0, assetID: artifact)],
      pageNodes: ["section": .init(isSection: true), "embed": .init(parentID: "section")])
    let id = try await a.database.createNote(folderID: nil, title: "Page", content: page.encoded(), kind: .canvas)
    try await a.send(to: b); try await b.send(to: a)
    let received = try #require(try await b.database.readNoteForEditing(id: id).document)
    #expect(received.pageParentID(for: "embed") == "section")
    #expect(received.canvas?["embed"]?.assetID == artifact)
    #expect(try await b.database.artifactStateSnapshot(noteID: artifact).values["form:text:title:0"] == .string("Trip plan"))
    _ = try await b.database.applyArtifactStateEdit(noteID: artifact,
      edit: .init(action: .set, key: "form:text:title:0", value: .string("Revised trip"), expectedVersion: 1))
    try await b.send(to: a)
    #expect(try await a.database.artifactStateSnapshot(noteID: artifact).values["form:text:title:0"] == .string("Revised trip"))
  }

  @Test func boardsSyncOriginalReferencesAndPreserveConcurrentWholeDocumentEdits() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let asset = try await a.database.createNote(folderID: nil, title: "Shared reference",
      content: NoteDocument(blocks: [.richText(.init(text: "One original"))]).encoded())
    let task = NoteRichTextBlock(id: "task", text: "Investigate"), reference = NoteRichTextBlock(id: "reference", text: "Reference")
    let source = NoteDocument(kind: .canvas, blocks: [.richText(task), .richText(reference)],
      canvas: [reference.id: .init(x: 400, y: 0, assetID: asset)],
      boardPurpose: "Coordinate the project", boardItems: [task.id: BoardItem(task: .init())])
    let board = try await a.database.createNote(folderID: nil, title: "Project board", content: source.encoded(), kind: .canvas)
    try await a.send(to: b); try await b.send(to: a)
    let onB = try #require(try await b.database.readNoteForEditing(id: board).document)
    #expect(onB.boardPurpose == source.boardPurpose)
    #expect(onB.canvas?[reference.id]?.assetID == asset)
    #expect(try await b.database.libraryNote(id: asset)?.content == a.database.libraryNote(id: asset)?.content)
    _ = try await b.database.applyNoteEdits(.init(command: .apply, noteID: board, operations: [
      .page(.init(action: .update, id: task.id, expectedRevision: onB.boardItemRevision(for: task.id),
        patch: .init(status: .done, outcome: "Verified on the second Mac", review: .needed)))
    ]))
    try await b.send(to: a); try await a.send(to: b)
    let synchronized = try #require(try await a.database.readNoteForEditing(id: board).document)
    #expect(synchronized.boardItems?[task.id]?.task?.status == .done)
    #expect(synchronized.boardItems?[task.id]?.review == .needed)
    // Both Macs write the same task's outcome while apart. The Page merges: one outcome
    // stays on the task and the other on a copy beside it, marked for review.
    for (mac, outcome) in [(a, "Air offline outcome"), (b, "Mini offline outcome")] {
      let current = try #require(try await mac.database.readNoteForEditing(id: board).document)
      _ = try await mac.database.applyNoteEdits(.init(command: .apply, noteID: board, operations: [
        .page(.init(action: .update, id: task.id, expectedRevision: current.boardItemRevision(for: task.id),
          patch: .init(outcome: outcome)))
      ]))
    }
    try await a.send(to: b); try await b.send(to: a); try await a.send(to: b)
    let aNotes = try await a.database.librarySnapshot().notes.filter { $0.kind == .canvas }
    let bNotes = try await b.database.librarySnapshot().notes.filter { $0.kind == .canvas }
    #expect(Set(aNotes.map(\.id)) == Set(bNotes.map(\.id)))
    #expect(aNotes.count == 1)
    #expect(try await a.database.libraryNote(id: board)?.content == b.database.libraryNote(id: board)?.content)
    let merged = try NoteDocument.editableDocument(from: try #require(aNotes.first).content)
    #expect(Set(merged.boardItems?.values.compactMap { $0.task?.outcome } ?? []) == ["Air offline outcome", "Mini offline outcome"])
    #expect(merged.blocks.contains { $0.id.hasPrefix("conflict-") && merged.boardItems?[$0.id]?.review == .needed })
    #expect(!aNotes.contains { $0.title.contains("Recovered edit") })
    for note in aNotes {
      let document = try NoteDocument.editableDocument(from: note.content)
      #expect(document.canvas?[reference.id]?.assetID == asset)
    }
    let current = try #require(try await a.database.readNoteForEditing(id: board).document)
    _ = try await a.database.applyNoteEdits(.init(command: .apply, noteID: board, operations: [
      .page(.init(action: .remove, id: reference.id, expectedRevision: current.boardItemRevision(for: reference.id)))
    ]))
    try await a.send(to: b)
    #expect(try await a.database.libraryNote(id: asset) != nil)
    #expect(try await b.database.libraryNote(id: asset) != nil)
  }

  @Test func concurrentWritingRetainsBothVersionsAndDeletionDoesNotResurrect() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased()
    try await a.note(id, title: "Shared")
    try await a.send(to: b); try await b.send(to: a)
    try await a.note(id, title: "Air edit", revision: a.database.libraryNote(id: id)?.revision)
    try await b.note(id, title: "Mini edit", revision: b.database.libraryNote(id: id)?.revision)
    try await a.send(to: b); try await b.send(to: a)
    #expect(try await a.database.libraryNote(id: id)?.title == b.database.libraryNote(id: id)?.title)
    let versions = try await a.database.pairedLibraryConflicts().filter { $0.record.table == "notes" }
    #expect(versions.count == 1)
    #expect(try await b.database.pairedLibraryConflicts().filter { $0.record.table == "notes" }.count == 1)
    let revision = try #require(try await a.database.libraryNote(id: id)?.revision)
    _ = try await a.database.applyLibraryMutation(.init(deviceID: a.id, kind: .deleteNote, resourceID: id, expectedRevision: revision))
    try await b.note(id, title: "Offline during deletion", revision: b.database.libraryNote(id: id)?.revision)
    try await a.send(to: b); try await b.send(to: a); try await a.send(to: b)
    #expect(try await a.database.libraryNote(id: id) == nil)
    #expect(try await b.database.libraryNote(id: id) == nil)
  }

  @Test func replayIsIdempotentAndAReopenedMacKeepsCursorsAndUnsentWriting() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased()
    try await a.note(id, title: "Durable unsent writing")
    let page = try await a.database.pairedLibraryPage(after: 0)
    try await b.database.receivePairedLibrary(page, from: a.id)
    let before = try await b.database.pairedLibraryPage(after: 0).cursor
    try await b.database.receivePairedLibrary(page, from: a.id)
    #expect(try await b.database.pairedLibraryPage(after: 0).cursor == before)
    let reopened = try await WorkspaceDatabase(url: b.database.fileURL)
    #expect(try await reopened.pairedLibraryCursors(a.id).pulled == page.cursor)
    #expect(try await reopened.libraryNote(id: id)?.title == "Durable unsent writing")
    #expect(try await reopened.libraryIdentity().hostDeviceID == b.id)
  }

  @Test func runtimeQueuesAndPrivateCredentialsStayLocal() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let tables = try await a.database.pairedLibraryPage(after: 0).entries.map(\.table)
    #expect(!tables.contains("desktop_local_acp_sessions"))
    #expect(!tables.contains("workspace_session_deliveries"))
    #expect(!tables.contains("workspace_session_timers"))
    #expect(!tables.contains("execution_workspace_publishers"))
    try await a.database.backUpBeforePeerSync()
    #expect(FileManager.default.fileExists(atPath: a.directory.appending(path: "Paired Mac Backups/before-peer-sync.sqlite").path))
    let route = PairedMacRoute(deviceID: a.id, libraryID: try await a.database.libraryID(), endpoint: URL(string: "https://air.example.ts.net:8443/wovenmatter")!, name: "Air")
    try await a.database.savePairedMacRoute(route)
    try await a.send(to: b)
    #expect(try await b.database.pairedMacRoutes() == [route])
  }
}


extension PairedLibraryTests {
  @Test func sharedFilesResumeAfterRestartAndRejectCorruptionOrPrivatePaths() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let bytes = Data(repeating: 173, count: 1_300_000)
    let hash = try LibraryFileStore(supportDirectory: a.directory).retain(bytes)
    try Data("provider-secret".utf8).write(to: a.directory.appending(path: "provider-credentials.json"))
    let sender = PairedLibraryFiles(root: a.directory), receiver = PairedLibraryFiles(root: b.directory)
    let page = try await sender.page(after: "")
    #expect(page.files.count == 1)
    let file = try #require(page.files.first)
    #expect(file.hash == hash)
    let first = try await sender.chunk(.init(file: file, offset: 0))
    try await receiver.receive(first)
    let reopened = PairedLibraryFiles(root: b.directory)
    #expect(try await reopened.nextOffset(file) == Int64(first.data.count))
    while let offset = try await reopened.nextOffset(file) {
      try await reopened.receive(sender.chunk(.init(file: file, offset: offset)))
    }
    #expect(try Data(contentsOf: b.directory.appending(path: "library-files/" + hash)) == bytes)
    await #expect(throws: LibraryAPIError.self) {
      try await reopened.nextOffset(.init(store: "../", hash: hash, byteCount: Int64(bytes.count)))
    }
    let invalid = PairedLibraryFile(store: "library-files", hash: String(repeating: "0", count: 64), byteCount: 1)
    await #expect(throws: LibraryAPIError.self) {
      try await reopened.receive(.init(file: invalid, offset: 0, data: Data([1])))
    }
    #expect(try await reopened.nextOffset(invalid) == 0)
    let healthyBytes = Data([9])
    let healthyHash = try LibraryFileStore(supportDirectory: a.directory).retain(healthyBytes)
    let healthy = PairedLibraryFile(store: "library-files", hash: healthyHash, byteCount: 1)
    await #expect(throws: LibraryAPIError.self) {
      try await reopened.receive(.init(file: healthy, offset: 0, data: Data([1])))
    }
    try await reopened.receive(.init(file: healthy, offset: 0, data: healthyBytes))
    #expect(try await reopened.nextOffset(healthy) == nil)
  }

  @Test func typedRowsKeepBinaryBytesAndIntegersBeyondJSONDoublePrecision() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let bytes = Data([0, 255, 0, 1, 128]), offset: Int64 = 9_007_199_254_740_993
    try await a.database.write { connection in
      let query = try connection.prepareUnlocked("INSERT INTO device_artifact_chunks VALUES('fixture',1,?,?)")
      defer { sqlite3_finalize(query) }
      sqlite3_bind_int64(query, 1, offset); try connection.bind(bytes, at: 2, to: query); try connection.stepDone(query)
    }
    try await a.send(to: b)
    let result = try await b.database.read { connection -> (Int64, Data) in
      let query = try connection.prepareUnlocked("SELECT offset,bytes FROM device_artifact_chunks WHERE artifact_id='fixture'")
      defer { sqlite3_finalize(query) }
      guard sqlite3_step(query) == SQLITE_ROW else { throw WorkspaceDatabaseError.corruptRow }
      return (sqlite3_column_int64(query, 0), try connection.blob(query, column: 1))
    }
    #expect(result.0 == offset && result.1 == bytes)
  }

  @Test func observedScheduledTasksDoNotRunOnOtherMacs() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let start = Date().addingTimeInterval(-30)
    let task = WorkspaceCalendarTask(prompt: "Fixture", configuration: .init(runtimeKind: .codex, title: "Fixture", model: "fixture", permission: "read-only"))
    _ = try await a.database.saveCalendarEvent(draft: .init(title: "Owner's task", startsAt: start, timeZoneID: "UTC", task: task), creating: true, now: start)
    try await a.send(to: b)
    #expect(try await b.database.calendarItems().count == 1)
    #expect(try await b.database.dueCalendarRuns().isEmpty)
    #expect(try await a.database.dueCalendarRuns().count == 1)
  }
}


extension PairedLibraryTests {
  @Test func largeRecordsWaitForTheirBytesWithoutBlockingOtherWriting() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let content = String(repeating: "Native archive bytes 🧵", count: 30_000)
    let eventID = UUID().uuidString.lowercased()
    try await a.database.recordHistory(.init(id: eventID, harness: "fixture", kind: "native.fixture", payload: content))
    let noteID = UUID().uuidString.lowercased()
    try await a.note(noteID, title: "Independent writing")
    try await a.send(to: b)
    #expect(try await b.database.libraryNote(id: noteID)?.title == "Independent writing")
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT id FROM workspace_history_events WHERE id=?", values: [eventID]).isEmpty })
    let files = PairedLibraryFiles(root: a.directory), receiver = PairedLibraryFiles(root: b.directory)
    let page = try await files.page(after: "")
    for file in page.files {
      while let offset = try await receiver.nextOffset(file) {
        try await receiver.receive(files.chunk(.init(file: file, offset: offset)))
      }
    }
    try await b.database.materializePendingPeerRecords()
    let result = try await b.database.read { try $0.historyRowsUnlocked("SELECT payload FROM workspace_history_events WHERE id=?", values: [eventID]).first?.objectValue?["payload"]?.stringValue }
    #expect(result == content)
  }

  @Test func legacyImportKeepsNativeRuntimeOnTheSameMacAndPreservesSource() async throws {
    let old = try await Mac(), full = try await Mac(); defer { old.remove(); full.remove() }
    let id = try await old.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Saved native session", ownerDeviceID: UUID())
    let note = UUID().uuidString.lowercased()
    try await old.note(note, title: "Legacy writing")
    try await full.database.importLegacyLocalMacWorkspace(from: old.database.fileURL)
    // Notes in a node's execution database are projections of the central
    // library; the upgrade preserves unreconciled ones under recovery IDs.
    #expect(try await full.database.libraryNote(id: note) == nil)
    #expect(try await full.database.read { try $0.historyRowsUnlocked("SELECT conversation_id FROM desktop_local_acp_sessions WHERE conversation_id=?", values: [id]).count } == 1)
    #expect(try await old.database.read { try $0.historyRowsUnlocked("SELECT conversation_id FROM desktop_local_acp_sessions WHERE conversation_id=?", values: [id]).count } == 1)
    #expect(try await old.database.libraryNote(id: note)?.title == "Legacy writing")
    #expect(try await full.database.libraryIdentity().hostDeviceID == full.id)
  }
}


extension PairedLibraryTests {
  /// History moves only by library sync: a Linux host writes its sessions
  /// into its own library copy (`/v1/publisher/journal` on its library
  /// socket), and that copy's peer sync carries them to every other Mac, with
  /// the Mac that added the host offline. A phone's federation journal is read
  /// from the same rows on whichever library host it reaches.
  @Test func aLinuxHostsHistoryReachesEveryMacByLibrarySyncAlone() async throws {
    let manager = try await Mac(), linux = try await Mac(), observer = try await Mac()
    defer { manager.remove(); linux.remove(); observer.remove() }
    let libraryID = try await manager.database.libraryID()
    let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: libraryID,
      ownerDeviceID: manager.id, kind: .linux, name: "Linux owner", endpoint: URL(string: "https://linux.fixture.ts.net/wovenmatter")!,
      capabilities: ["execution.v1", StreamProtocol.capability], executionDeviceID: linux.id)
    _ = try await manager.database.registerExecutionWorkspace(.init(workspace: workspace), deviceID: manager.id)
    try await manager.send(to: linux); try await manager.send(to: observer)
    let id = UUID().uuidString.lowercased()
    let creation = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 1, conversationID: id, kind: .conversation,
      conversation: .init(id: id, title: "Linux conversation", runtimeKind: "codex"))
    let output = ExecutionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: id, kind: .transcript,
      transcript: .init(conversationID: id, messages: [.init(id: UUID().uuidString.lowercased(), conversationID: id, role: "assistant", content: "Output while the managing Mac is offline")]))
    // The host's own Node server publishes into its library copy.
    let path = "/v1/publisher/journal"
    let published = try await DevicePublisherAPI.handleLocal(.init(method: "POST", target: path, headers: [:],
      body: try JSONEncoder().encode(ExecutionJournalBatch(libraryID: libraryID, entries: [creation, output]))), path: path, database: linux.database)
    #expect(published.status == 200)
    // The managing Mac is offline; the host's library copy syncs with another Mac as the Linux member it is.
    let sender = PairedLibrarySender(deviceID: linux.id, kind: .linux, members: [
      .init(deviceID: manager.id, kind: .mac, endpoints: [], revoked: false),
      .init(deviceID: linux.id, kind: .linux, endpoints: [], revoked: false)])
    var cursor = try await observer.database.pairedLibraryCursors(linux.id).pulled
    for _ in 0..<1000 {
      let page = try await linux.database.pairedLibraryPage(after: cursor)
      try await observer.database.receivePairedLibrary(page, from: linux.id, sender: sender)
      cursor = page.cursor
      if !page.hasMore { break }
    }
    #expect(try await observer.database.libraryFederatedTranscript(conversationID: id)?.messages.first?.content == "Output while the managing Mac is offline")
    #expect(try await observer.database.libraryConversationExecutionWorkspace(conversationID: id)?.id == workspace.id)
    #expect(try await observer.database.executionJournal(after: 0).entries.map(\.eventID) == [creation.eventID, output.eventID])
  }
}


extension PairedLibraryTests {
  private func journal(_ database: WorkspaceDatabase) async throws -> [PairedLibraryRecord] {
    try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT payload FROM paired_library_changes ORDER BY cursor", values: [])
        .compactMap { $0.objectValue?["payload"]?.stringValue }
        .map { try JSONDecoder().decode(PairedLibraryRecord.self, from: Data($0.utf8)) }
    }
  }
  private func deliver(_ records: [PairedLibraryRecord], to database: WorkspaceDatabase, from peer: String) async throws {
    let schema = try await database.pairedLibraryPage(after: 0).schema
    try await database.receivePairedLibrary(.init(schema: schema, entries: records, cursor: 0, hasMore: true), from: peer)
  }
  private func lastChange(_ database: WorkspaceDatabase) async throws -> Int64 {
    try await database.read { try $0.historyRowsUnlocked("SELECT COALESCE(MAX(cursor),0) AS cursor FROM paired_library_changes", values: []).first?.objectValue?["cursor"]?.intValue.map(Int64.init) ?? 0 }
  }
  private func noteState(_ database: WorkspaceDatabase, _ id: String) async throws -> String {
    try await database.read { connection in
      let row = try connection.historyRowsUnlocked("SELECT title,deleted_at FROM notes WHERE id=?", values: [id]).first?.objectValue
      let winner = try connection.historyRowsUnlocked("SELECT json_extract(payload,'$.vector') AS vector FROM paired_library_rows WHERE table_name='notes' AND record_key=?", values: ["[\"\(id)\"]"]).first?.objectValue?["vector"]?.stringValue ?? ""
      return (row?["deleted_at"]?.stringValue == nil ? (row?["title"]?.stringValue ?? "absent") : "deleted") + "|" + winner
    }
  }

  @Test func deletionLaterRestoreAndConcurrentEditConvergeInEveryArrivalOrder() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased(), key = "[\"\(id)\"]"
    try await a.note(id, title: "Original")
    try await a.send(to: b)
    try await b.note(id, title: "Mini edit", revision: b.database.libraryNote(id: id)?.revision)
    let revision = try #require(try await a.database.libraryNote(id: id)?.revision)
    _ = try await a.database.applyLibraryMutation(.init(deviceID: a.id, kind: .deleteNote, resourceID: id, expectedRevision: revision))
    // An explicit later restore is a causal successor of the deletion.
    try await a.database.write { try $0.toolsExecuteUnlocked("UPDATE notes SET deleted_at=NULL,title='Restored' WHERE id=?", [id]) }
    let fromAir = try await journal(a.database).filter { $0.table == "notes" && $0.key == key }
    let create = try #require(fromAir.first), deletion = try #require(fromAir.first { $0.deleted }), restore = try #require(fromAir.last)
    let edit = try #require(try await journal(b.database).last { $0.table == "notes" && $0.key == key && $0.origin == b.id })
    #expect(!restore.deleted && restore.dominates(deletion))
    let orders = [[deletion, restore, edit], [deletion, edit, restore], [restore, deletion, edit],
                  [restore, edit, deletion], [edit, deletion, restore], [edit, restore, deletion]]
    var outcomes = Set<String>()
    for (index, order) in orders.enumerated() {
      let c = try await Mac(); defer { c.remove() }
      var database = c.database
      try await deliver([create], to: database, from: a.id)
      for record in order {
        try await deliver([record], to: database, from: record.origin)
        // One order also restarts between every page.
        if index == 1 { database = try await WorkspaceDatabase(url: c.database.fileURL) }
      }
      try await deliver(order, to: database, from: b.id)
      outcomes.insert(try await noteState(database, id))
    }
    #expect(outcomes.count == 1)
    let outcome = try #require(outcomes.first)
    #expect(!outcome.hasPrefix("deleted"))
    try await a.send(to: b); try await b.send(to: a)
    #expect(try await noteState(a.database, id) == outcome)
    #expect(try await noteState(b.database, id) == outcome)
    // The losing live writing remains recoverable as a visible note.
    let titles = try await a.database.librarySnapshot().notes.map(\.title)
    #expect(titles.contains { $0.hasSuffix("(Recovered edit)") })
  }

  @Test func anOlderStoreWithAnArrivalOrderWinnerRecomputesTheCanonicalWinner() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased(), key = "[\"\(id)\"]"
    try await a.note(id, title: "Shared")
    try await a.send(to: b); try await b.send(to: a)
    try await a.note(id, title: "Air edit", revision: a.database.libraryNote(id: id)?.revision)
    try await b.note(id, title: "Mini edit", revision: b.database.libraryNote(id: id)?.revision)
    try await a.send(to: b); try await b.send(to: a)
    let canonical = try await noteState(a.database, id)
    let (winner, loser) = try await a.database.read { connection -> (String, String) in
      let winner = try #require(try connection.historyRowsUnlocked("SELECT payload FROM paired_library_rows WHERE table_name='notes' AND record_key=?", values: [key]).first?.objectValue?["payload"]?.stringValue)
      let loser = try #require(try connection.historyRowsUnlocked("SELECT payload FROM paired_library_frontier WHERE table_name='notes' AND record_key=?", values: [key]).first?.objectValue?["payload"]?.stringValue)
      return (winner, loser)
    }
    let losing = try JSONDecoder().decode(PairedLibraryRecord.self, from: Data(loser.utf8))
    // Recreate what an earlier build left behind: the loser materialized as the
    // winner, the true winner only in conflicts, and no frontier at all.
    try await b.database.write { connection in
      try connection.executeUnlocked("UPDATE paired_library_clock SET applying=1")
      try connection.toolsExecuteUnlocked("UPDATE notes SET title=? WHERE id=?", [losing.row["title"]?.value, id])
      try connection.toolsExecuteUnlocked("UPDATE paired_library_rows SET payload=? WHERE table_name='notes' AND record_key=?", [loser, key])
      try connection.executeUnlocked("DELETE FROM paired_library_frontier; DELETE FROM paired_library_conflicts; DELETE FROM paired_library_state WHERE name LIKE 'frontier.%'")
      try connection.toolsExecuteUnlocked("INSERT INTO paired_library_conflicts VALUES('legacy',?)", [winner])
      try connection.executeUnlocked("UPDATE paired_library_clock SET applying=0")
    }
    #expect(try await noteState(b.database, id) != canonical)
    let upgraded = try await WorkspaceDatabase(url: b.database.fileURL)
    #expect(try await noteState(upgraded, id) == canonical)
    #expect(try await upgraded.libraryNote(id: id)?.title == a.database.libraryNote(id: id)?.title)
  }

  @Test func observersNeverRecoverPauseOrAccountForAnotherMacsActiveWork() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Owner's work", ownerDeviceID: UUID())
    let goal = try #require(try await a.database.mutateGoal(sessionID: session, mutation: .set(objective: "Keep working", tokenBudget: nil, turnBudget: nil)))
    let run = try await a.database.beginLocalACPRun(conversationID: session, input: .init(text: "Working on the owner"))
    try await a.send(to: b)
    let before = try await lastChange(b.database)
    // The observer restarts, schedules goals and pauses its own goals.
    try await b.database.recoverInterruptedLocalACPRuns()
    _ = try await b.database.dueGoalDeliveries(running: [])
    try await b.database.pauseActiveGoals()
    try await b.database.recordGoalUsage(runID: run.runID, tokens: 50)
    let reopened = try await WorkspaceDatabase(url: b.database.fileURL)
    try await reopened.recoverInterruptedLocalACPRuns()
    await #expect(throws: WorkspaceToolError.self) { try await reopened.mutateGoal(sessionID: session, mutation: .pause(id: goal.id)) }
    #expect(try await lastChange(reopened) == before)
    #expect(try await reopened.activeRunID(conversationID: session) == nil)
    #expect(try await reopened.activeDeviceOwnedConversationIDs().isEmpty)
    #expect(try await !reopened.read { try $0.locallyOwnsConversationUnlocked(session) })
    let status = try await reopened.read { try $0.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
    #expect(status == "running")
    try await b.send(to: a)
    #expect(try await a.database.activeRunID(conversationID: session) == run.runID)
    #expect(try await a.database.sessionGoals().first { $0.id == goal.id }?.status == .active)
    #expect(try await a.database.read { try $0.locallyOwnsConversationUnlocked(session) })
  }

  @Test func aConversationReceivedWithoutItsOwnerStaysReadOnlyAcrossRestart() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Partially received", ownerDeviceID: UUID())
    let run = try await a.database.beginLocalACPRun(conversationID: session, input: .init(text: "Running elsewhere"))
    let records = try await journal(a.database).filter { !$0.table.hasPrefix("paired_") }
    try await deliver(records, to: b.database, from: a.id)
    let reopened = try await WorkspaceDatabase(url: b.database.fileURL)
    let before = try await lastChange(reopened)
    try await reopened.recoverInterruptedLocalACPRuns()
    #expect(try await !reopened.read { try $0.locallyOwnsConversationUnlocked(session) })
    #expect(try await reopened.read { try $0.historyRowsUnlocked("SELECT id FROM paired_conversation_owners WHERE id=?", values: [session]).isEmpty })
    #expect(try await lastChange(reopened) == before)
    let status = try await reopened.read { try $0.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
    #expect(status == "running")
  }
}


extension PairedLibraryTests {
  @Test func readyWaitingRecordsAreNotStarvedByUnavailableOnes() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let blocked = UUID().uuidString.lowercased(), ready = UUID().uuidString.lowercased()
    try await a.note(blocked, title: "Waiting"); try await a.note(ready, title: "Ready bytes")
    let notes = try await journal(a.database).filter { $0.table == "notes" }
    let waiting = try #require(notes.last { $0.key == "[\"\(blocked)\"]" }), available = try #require(notes.last { $0.key == "[\"\(ready)\"]" })
    @Sendable func referencing(_ record: PairedLibraryRecord, hash: String) -> PairedLibraryRecord {
      var row = record.row; row["title"] = .init(type: "reference:text", value: hash)
      return .init(table: record.table, key: record.key, row: row, deleted: record.deleted, clock: record.clock, origin: record.origin, vector: record.vector)
    }
    let bytes = Data("Ready bytes".utf8), hash = SHA256.hash(data: bytes).hexString
    let records = b.directory.appending(path: "paired-records")
    try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
    try bytes.write(to: records.appending(path: hash))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    try await b.database.write { connection in
      for index in 0..<120 {
        let missing = String(format: "%064x", index + 1)
        let payload = String(decoding: try encoder.encode(referencing(waiting, hash: missing)), as: UTF8.self)
        try connection.toolsExecuteUnlocked("INSERT INTO paired_library_pending VALUES(?,?,?,1)", [String(format: "a%05d", index), payload, a.id])
      }
      let payload = String(decoding: try encoder.encode(referencing(available, hash: hash)), as: UTF8.self)
      try connection.toolsExecuteUnlocked("INSERT INTO paired_library_pending VALUES('z-ready',?,?,1)", [payload, a.id])
    }
    try await b.database.materializePendingPeerRecords()
    #expect(try await b.database.libraryNote(id: ready)?.title == "Ready bytes")
    #expect(try await b.database.libraryNote(id: blocked) == nil)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT id FROM paired_library_pending", values: []).count } == 120)
  }

  @Test func aCompleteDownloadInterruptedBeforeInstallFinishesOrRestarts() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let bytes = Data(repeating: 41, count: 700_000)
    let hash = try LibraryFileStore(supportDirectory: a.directory).retain(bytes)
    let file = PairedLibraryFile(store: "library-files", hash: hash, byteCount: Int64(bytes.count))
    let downloads = b.directory.appending(path: "paired-file-downloads")
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    // The final chunk was durable but the process stopped before installing it.
    try bytes.write(to: downloads.appending(path: "library-files-" + hash))
    let receiver = PairedLibraryFiles(root: b.directory)
    #expect(try await receiver.nextOffset(file) == nil)
    #expect(try Data(contentsOf: b.directory.appending(path: "library-files/" + hash)) == bytes)
    // A complete but corrupt partial is discarded and restarts from zero.
    let other = Data(repeating: 42, count: 600_000)
    let otherHash = try LibraryFileStore(supportDirectory: a.directory).retain(other)
    let corrupt = PairedLibraryFile(store: "library-files", hash: otherHash, byteCount: Int64(other.count))
    try Data(repeating: 7, count: other.count).write(to: downloads.appending(path: "library-files-" + otherHash))
    #expect(try await receiver.nextOffset(corrupt) == 0)
    let sender = PairedLibraryFiles(root: a.directory)
    while let offset = try await receiver.nextOffset(corrupt) { try await receiver.receive(sender.chunk(.init(file: corrupt, offset: offset))) }
    #expect(try Data(contentsOf: b.directory.appending(path: "library-files/" + otherHash)) == other)
  }

  @Test func theAnalyticsChoiceReachesEveryMacAndOptingOutWinsWhileApart() async throws {
    let a = try await Mac(), b = try await Mac(), c = try await Mac(); defer { a.remove(); b.remove(); c.remove() }
    // Each Mac starts with its own random ID; after syncing they share one library ID.
    try await a.send(to: b); try await b.send(to: a); try await b.send(to: c); try await c.send(to: a); try await a.send(to: b)
    let shared = try await a.database.productAnalyticsPreference().analyticsID
    #expect(try await b.database.productAnalyticsPreference().analyticsID == shared)
    #expect(try await c.database.productAnalyticsPreference().analyticsID == shared)
    // A choice made on one Mac reaches the others.
    let before = try await a.database.productAnalyticsPreference()
    _ = try await a.database.setProductAnalyticsPreference(.init(enabled: false, expectedRevision: before.revision))
    try await a.send(to: b); try await b.send(to: c)
    #expect(try await c.database.productAnalyticsPreference().enabled == false)
    // While apart, one Mac opts back in and another opts out again: opting out wins everywhere.
    let onB = try await b.database.productAnalyticsPreference()
    _ = try await b.database.setProductAnalyticsPreference(.init(enabled: true, expectedRevision: onB.revision))
    _ = try await c.database.setProductAnalyticsPreference(.init(enabled: false, expectedRevision: try await c.database.productAnalyticsPreference().revision))
    try await b.send(to: c); try await c.send(to: b); try await b.send(to: a)
    #expect(try await a.database.productAnalyticsPreference().enabled == false)
    #expect(try await b.database.productAnalyticsPreference().enabled == false)
    #expect(try await c.database.productAnalyticsPreference().enabled == false)
  }

  @Test func outsideMCPExposureStaysOnItsMacWhileToolChoicesSynchronize() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    try await a.database.updateExternalMCP(enabled: true)
    var settings = try await a.database.toolSettings(); settings.maximumManagedSessions = 5
    try await a.database.saveToolSettings(settings)
    try await a.send(to: b)
    #expect(try await b.database.toolSettings().externalMCP?.isEnabled != true)
    #expect(try await b.database.toolSettings().maximumManagedSessions == 5)
    #expect(try await a.database.toolSettings().externalMCP?.isEnabled == true)
  }

  @Test func formerNodeProjectionsNeverOverwriteTheCentralLibraryAndImportIsIdempotent() async throws {
    let central = try await Mac(), node = try await Mac(), full = try await Mac()
    defer { central.remove(); node.remove(); full.remove() }
    let id = UUID().uuidString.lowercased()
    try await central.note(id, title: "Current central writing")
    // The node's execution database held an older tool-facing copy of that note.
    try await node.note(id, title: "Stale projection")
    let session = try await node.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Node's native session", ownerDeviceID: UUID())
    try await full.database.importLegacyLocalMacWorkspace(from: node.database.fileURL)
    let count = { (database: WorkspaceDatabase) in try await database.read { try $0.historyRowsUnlocked("SELECT count(*) AS count FROM dashboard_messages", values: []).first?.objectValue?["count"]?.intValue ?? 0 } }
    let imported = try await count(full.database)
    try await full.database.importLegacyLocalMacWorkspace(from: node.database.fileURL)
    #expect(try await count(full.database) == imported)
    #expect(try await full.database.read { try $0.locallyOwnsConversationUnlocked(session) })
    try await central.send(to: full); try await full.send(to: central)
    #expect(try await full.database.libraryNote(id: id)?.title == "Current central writing")
    #expect(try await central.database.libraryNote(id: id)?.title == "Current central writing")
    #expect(try await !full.database.librarySnapshot().notes.contains { $0.title.contains("Recovered edit") })
  }

  @Test func emptyTurnsDoNotRewriteForeignProjectionsButTouchedConversationsDo() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: try await a.database.libraryID(),
      ownerDeviceID: a.id, kind: .mac, name: "Air", endpoint: URL(string: "https://air.fixture.ts.net/wovenmatter")!,
      capabilities: ["execution.v1"], executionDeviceID: a.id)
    _ = try await a.database.registerExecutionWorkspace(.init(workspace: workspace), deviceID: a.id)
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Owner's chat", ownerDeviceID: UUID())
    try await a.send(to: b)
    #expect(try await b.database.libraryExecutionOwner(conversationID: session) == workspace.id)
    let marker = { () async throws -> String? in
      try await b.database.read { try $0.historyRowsUnlocked("SELECT transcript FROM execution_conversations WHERE id=?", values: [session]).first?.objectValue?["transcript"]?.stringValue }
    }
    try await b.database.write { connection in
      try connection.executeUnlocked("UPDATE paired_library_clock SET applying=1")
      try connection.toolsExecuteUnlocked("UPDATE execution_conversations SET transcript=NULL WHERE id=?", [session])
      try connection.executeUnlocked("UPDATE paired_library_clock SET applying=0")
    }
    try await a.send(to: b)
    #expect(try await marker() == nil)
    try await a.database.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_conversations SET title='Renamed by owner' WHERE id=?", [session]) }
    try await a.send(to: b)
    #expect(try await marker() != nil)
  }

  @Test func observersNeverCaptureWorkspaceFilesForAnotherMacsConversation() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Report", ownerDeviceID: UUID())
    _ = try await a.database.beginLocalACPRun(conversationID: session, input: .init(text: "Write reports/result.pdf"))
    try await a.database.write { connection in
      let message = try #require(try connection.historyRowsUnlocked("SELECT id FROM dashboard_messages WHERE conversation_id=? LIMIT 1", values: [session]).first?.objectValue?["id"]?.stringValue)
      try connection.insertLibraryAssetUnlocked(.init(source: "reports/result.pdf", title: "result.pdf", kind: .file), messageID: message, conversationID: session)
    }
    let owned = try await a.database.pendingLibraryFiles()
    #expect(owned.map(\.conversationID) == [session])
    try await a.send(to: b)
    // The same relative path exists on the observer with different bytes.
    try await b.database.setLibraryLocation(conversationID: session, workspaceName: "Local workspace", root: b.directory.path)
    #expect(try await b.database.libraryRoot(conversationID: session) == nil)
    #expect(try await b.database.pendingLibraryFiles().isEmpty)
    let item = try #require(owned.first)
    try await b.database.finishLibraryFile(id: item.id, hash: String(repeating: "e", count: 64), size: 3)
    #expect(try await b.database.libraryItem(id: item.id)?.contentHash == nil)
  }

  @Test func aMalformedRecordIsQuarantinedWithoutPartialStateWhileOthersApply() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let shared = UUID().uuidString.lowercased(), other = UUID().uuidString.lowercased()
    try await a.note(shared, title: "Shared"); try await a.send(to: b)
    try await a.note(other, title: "Independent")
    let good = try #require(try await journal(a.database).last { $0.key == "[\"\(other)\"]" && $0.table == "notes" })
    let base = try #require(try await journal(a.database).last { $0.key == "[\"\(shared)\"]" && $0.table == "notes" })
    // A concurrent version that would win, but carries an invalid integer.
    let origin = UUID().uuidString.lowercased(), clock: Int64 = 50_000_000
    var row = base.row; row["revision"] = .init(type: "integer", value: "not-a-number"); row["title"] = .init(type: "text", value: "Malformed")
    let bad = PairedLibraryRecord(table: "notes", key: base.key, row: row, deleted: false, clock: clock, origin: origin, vector: [origin: clock])
    let conflictsBefore = try await b.database.pairedLibraryConflicts().count
    try await deliver([bad, good], to: b.database, from: a.id)
    #expect(try await b.database.libraryNote(id: other)?.title == "Independent")
    #expect(try await b.database.libraryNote(id: shared)?.title == "Shared")
    #expect(try await b.database.pairedLibraryConflicts().count == conflictsBefore)
    #expect(try await b.database.pairedLibraryQuarantineCount() == 1)
    #expect(try await !b.database.librarySnapshot().notes.contains { $0.title.contains("Recovered edit") })
  }

  @Test func schedulesOwnedByThisMacsExecutionContextStayLocalAfterUpgrade() async throws {
    let mac = try await Mac(); defer { mac.remove() }
    let start = Date().addingTimeInterval(-30)
    let task = WorkspaceCalendarTask(prompt: "Fixture", configuration: .init(runtimeKind: .codex, title: "Fixture", model: "fixture", permission: "read-only"))
    let local = try await mac.database.saveCalendarEvent(draft: .init(title: "Context schedule", startsAt: start, timeZoneID: "UTC", task: task), creating: true, now: start)
    let phone = try await mac.database.saveCalendarEvent(draft: .init(title: "Phone schedule", startsAt: start, timeZoneID: "UTC", task: task), creating: true, now: start)
    let context = UUID().uuidString.lowercased(), phoneID = UUID().uuidString.lowercased()
    // Recreate a database from before paired ownership existed.
    try await mac.database.write { connection in
      try connection.executeUnlocked("UPDATE paired_library_clock SET applying=1")
      try connection.executeUnlocked("DELETE FROM paired_calendar_owners; DELETE FROM paired_library_state WHERE name='owners.bootstrap'")
      try connection.toolsExecuteUnlocked("INSERT INTO calendar_replica_context(singleton,library_id,workspace_id) VALUES(1,?,?)", [try connection.libraryIDUnlocked(), context])
      try connection.toolsExecuteUnlocked("INSERT INTO calendar_task_executors(event_id,device_id) VALUES(?,?),(?,?)", [local, context, phone, phoneID])
      try connection.executeUnlocked("UPDATE paired_library_clock SET applying=0")
    }
    let upgraded = try await WorkspaceDatabase(url: mac.database.fileURL)
    let due = try await upgraded.dueCalendarRuns()
    #expect(due.map(\.eventID) == [local])
  }
}


extension PairedLibraryTests {
  private func registerMacWorkspace(_ mac: Mac) async throws -> ExecutionWorkspace {
    let workspace = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: try await mac.database.libraryID(),
      ownerDeviceID: mac.id, kind: .mac, name: "Mac", endpoint: URL(string: "https://m\(mac.id.prefix(6)).fixture.ts.net/wovenmatter")!,
      capabilities: ["execution.v1"], executionDeviceID: mac.id)
    return try await mac.database.registerExecutionWorkspace(.init(workspace: workspace), deviceID: mac.id)
  }
  private func projectedWorkspace(_ database: WorkspaceDatabase, _ id: String) async throws -> String? {
    try await database.read { try $0.historyRowsUnlocked("SELECT workspace_id FROM execution_conversations WHERE id=?", values: [id]).first?.objectValue?["workspace_id"]?.stringValue }
  }
  private func insertRun(_ database: WorkspaceDatabase, _ id: String, conversation: String) async throws {
    try await database.write { try $0.toolsExecuteUnlocked("INSERT INTO dashboard_runs(id,conversation_id,status,created_at) VALUES(?,?,'completed',?)",
      [id, conversation, WorkspaceDatabaseConnection.timestamp(Date())]) }
  }

  @Test func aSyntheticProjectionGuessedForTheWrongMacIsRepairedFromTheOwnerRecord() async throws {
    let a = try await Mac(), b = try await Mac(), c = try await Mac(); defer { a.remove(); b.remove(); c.remove() }
    let owner = try await registerMacWorkspace(a), wrong = try await registerMacWorkspace(c)
    try await c.send(to: b)
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Owner's chat", ownerDeviceID: UUID())
    try await a.send(to: b)
    #expect(try await projectedWorkspace(b.database, session) == owner.id)
    // An earlier build guessed routing from an editor's origin.
    try await b.database.write { connection in
      try connection.executeUnlocked("UPDATE paired_library_clock SET applying=1")
      try connection.toolsExecuteUnlocked("UPDATE execution_conversations SET workspace_id=? WHERE id=?", [wrong.id, session])
      try connection.executeUnlocked("DELETE FROM paired_library_state WHERE name='projection.v2'; UPDATE paired_library_clock SET applying=0")
    }
    #expect(try await projectedWorkspace(b.database, session) == wrong.id)
    let reopened = try await WorkspaceDatabase(url: b.database.fileURL)
    #expect(try await projectedWorkspace(reopened, session) == owner.id)
    // A later owner edit keeps it on the right Mac; the owner never routes to itself.
    try await a.database.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_conversations SET title='Renamed' WHERE id=?", [session]) }
    try await a.send(to: b)
    #expect(try await projectedWorkspace(b.database, session) == owner.id)
    try await b.send(to: a)
    #expect(try await projectedWorkspace(a.database, session) == nil)
  }

  @Test func theExecutionOwnersNativeRowsSurviveAStaleFederatedProjection() async throws {
    let node = try await Mac(), central = try await Mac(); defer { node.remove(); central.remove() }
    let session = try await node.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Native session", ownerDeviceID: UUID())
    let run = try await node.database.beginLocalACPRun(conversationID: session, input: .init(text: "Native input"))
    let native = try await node.database.read { connection in
      try #require(try connection.historyRowsUnlocked("SELECT agent_id,governing_plane,authority_kind,desktop_owned FROM dashboard_conversations WHERE id=?", values: [session]).first?.objectValue)
    }
    // The central library held a federated projection of the same chat and run.
    try await central.database.write { connection in
      try connection.toolsExecuteUnlocked("INSERT INTO dashboard_conversations(id,title,governing_plane,authority_kind,desktop_owned,created_at,updated_at) VALUES(?,?,?,?,1,?,?)",
        [session, "Projected title", "remote_workspace", "remote", "2020-01-01T00:00:00Z", "2020-01-01T00:00:00Z"])
      try connection.toolsExecuteUnlocked("INSERT INTO dashboard_runs(id,conversation_id,status,created_at) VALUES(?,?,'completed','2020-01-01T00:00:00Z')", [run.runID, session])
    }
    // Make the central copies win the deterministic order, as a busy central would.
    try await central.database.write { try $0.executeUnlocked("UPDATE paired_library_clock SET tick=tick+1000000") }
    try await central.database.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_conversations SET title='Projected title ' WHERE id=?", [session]) }
    try await central.database.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_runs SET status='completed',error='projection' WHERE id=?", [run.runID]) }
    try await central.send(to: node)
    let after = try await node.database.read { connection in
      try #require(try connection.historyRowsUnlocked("SELECT agent_id,governing_plane,authority_kind,desktop_owned,title FROM dashboard_conversations WHERE id=?", values: [session]).first?.objectValue)
    }
    // Native binding and run state are the owner's truth; the shared title edit applies.
    for key in ["agent_id", "governing_plane", "authority_kind", "desktop_owned"] { #expect(after[key] == native[key]) }
    #expect(after["title"]?.stringValue == "Projected title ")
    #expect(try await node.database.activeRunID(conversationID: session) == run.runID)
    // The owner republishes its native rows, so the central library converges.
    try await node.send(to: central)
    let converged = try await central.database.read { connection in
      try #require(try connection.historyRowsUnlocked("SELECT agent_id,governing_plane FROM dashboard_conversations WHERE id=?", values: [session]).first?.objectValue)
    }
    #expect(converged["agent_id"] == native["agent_id"] && converged["governing_plane"] == native["governing_plane"])
    let status = try await central.database.read { try $0.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
    #expect(status == "running")
  }

  @Test func importedGoalsKeepStableRunMembershipAndUsageAcrossRenumberedRuns() async throws {
    let old = try await Mac(), full = try await Mac(); defer { old.remove(); full.remove() }
    let session = try await old.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Goal chat", ownerDeviceID: UUID(),
      fixtureLocation: .init(workspaceID: "local", rootPath: old.directory.path, managed: false))
    // High, gapped source sequences.
    for index in 0..<40 { try await insertRun(old.database, "gap-\(index)", conversation: UUID().uuidString.lowercased()) }
    try await old.database.write { try $0.executeUnlocked("DELETE FROM dashboard_runs WHERE id LIKE 'gap-%'") }
    try await insertRun(old.database, "before-goal", conversation: session)
    let goal = try #require(try await old.database.mutateGoal(sessionID: session, mutation: .set(objective: "Finish", tokenBudget: 1000, turnBudget: nil)))
    // An enrolled turn with usage, and a later turn the source never enrolled.
    try await insertRun(old.database, "enrolled-turn", conversation: session)
    try await old.database.recordGoalUsage(runID: "enrolled-turn", tokens: 5)
    try await insertRun(old.database, "unenrolled-turn", conversation: session)
    // The destination already has runs, one of them a duplicate ID in another chat.
    let other = try await full.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Existing", ownerDeviceID: UUID())
    for index in 0..<5 { try await insertRun(full.database, "existing-\(index)", conversation: other) }
    try await insertRun(full.database, "before-goal", conversation: other)
    try await full.database.importLegacyLocalMacWorkspace(from: old.database.fileURL)
    let imported = try #require(try await full.database.sessionGoals().first { $0.id == goal.id })
    #expect(imported.status == .paused)
    let enrolled = { try await full.database.read { try $0.historyRowsUnlocked("SELECT run_id FROM workspace_goal_runs WHERE goal_id=?", values: [goal.id]).compactMap { $0.objectValue?["run_id"]?.stringValue } } }
    // The unenrolled source turn is enrolled before pausing; the pre-goal turn never is.
    #expect(Set(try await enrolled()) == ["enrolled-turn", "unenrolled-turn"])
    #expect(imported.tokensUsed == 5)
    // Late usage for an enrolled turn counts whatever its new row sequence.
    try await full.database.recordGoalUsage(runID: "unenrolled-turn", tokens: 3)
    #expect(try await full.database.sessionGoals().first { $0.id == goal.id }?.tokensUsed == 8)
    // Resumed, a new run enrolls; the pre-goal turn still does not.
    _ = try await full.database.mutateGoal(sessionID: session, mutation: .resume(id: goal.id))
    try await insertRun(full.database, "after-upgrade", conversation: session)
    try await full.database.recordGoalUsage(runID: "after-upgrade", tokens: 7)
    #expect(Set(try await enrolled()) == ["enrolled-turn", "unenrolled-turn", "after-upgrade"])
    #expect(try await full.database.sessionGoals().first { $0.id == goal.id }?.tokensUsed == 15)
  }

  @Test func anImportNeverRewritesAGoalThisLibraryAlreadyHad() async throws {
    let old = try await Mac(), full = try await Mac(); defer { old.remove(); full.remove() }
    let session = try await old.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Shared chat", ownerDeviceID: UUID(),
      fixtureLocation: .init(workspaceID: "local", rootPath: old.directory.path, managed: false))
    _ = try await old.database.mutateGoal(sessionID: session, mutation: .set(objective: "Source goal", tokenBudget: nil, turnBudget: nil))
    // This library already has the chat and its own goal for it.
    let existing = #"{"baselineRunSequence":999,"completedTurns":0,"createdAt":0,"enrolledRunSequence":999,"id":"existing-goal","objective":"Kept","observedRunSequence":999,"progressRevision":0,"sessionID":"\#(session)","status":"active","updatedAt":0}"#
    try await full.database.write { connection in
      try connection.toolsExecuteUnlocked("INSERT INTO dashboard_conversations(id,title) VALUES(?,'Shared chat')", [session])
      try connection.toolsExecuteUnlocked("INSERT INTO workspace_session_goals(session_id,value) VALUES(?,?)", [session, existing])
    }
    try await full.database.importLegacyLocalMacWorkspace(from: old.database.fileURL)
    let value = try await full.database.read { try $0.historyRowsUnlocked("SELECT value FROM workspace_session_goals WHERE session_id=?", values: [session]).first?.objectValue?["value"]?.stringValue }
    #expect(value == existing)
  }

  @Test func bytesOfALosingLibraryVersionSurviveCleanup() async throws {
    let mac = try await Mac(); defer { mac.remove() }
    let kept = try LibraryFileStore(supportDirectory: mac.directory).retain(Data("losing version bytes".utf8))
    let dropped = try LibraryFileStore(supportDirectory: mac.directory).retain(Data("unreferenced bytes".utf8))
    let old = Date().addingTimeInterval(-7200)
    for hash in [kept, dropped] {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: mac.directory.appending(path: "library-files/" + hash).path)
    }
    let losing = PairedLibraryRecord(table: "library_items", key: "[\"item\"]", row: [
      "id": .init(type: "text", value: "item"), "content_hash": .init(type: "text", value: kept), "storage": .init(type: "text", value: "retained")],
      deleted: false, clock: 1, origin: UUID().uuidString.lowercased(), vector: [:])
    let payload = String(decoding: try JSONEncoder().encode(losing), as: UTF8.self)
    try await mac.database.write { try $0.toolsExecuteUnlocked("INSERT INTO paired_library_conflicts VALUES('losing',?)", [payload]) }
    try await mac.database.cleanupLibraryFiles()
    #expect(FileManager.default.fileExists(atPath: mac.directory.appending(path: "library-files/" + kept).path))
    #expect(!FileManager.default.fileExists(atPath: mac.directory.appending(path: "library-files/" + dropped).path))
  }
}


extension PairedLibraryTests {
  @Test func legacyExecutionGrantsWithoutProvenanceAreRetiredOneByOne() async throws {
    let mac = try await Mac(); defer { mac.remove() }
    let file = mac.directory.appending(path: "execution-devices.json")
    let own = mac.id, phone = UUID().uuidString.lowercased(), library = UUID().uuidString.lowercased(), workspace = UUID().uuidString.lowercased()
    func grant(_ device: String) -> [String: Any] {
      ["scope": ["deviceID": device, "libraryID": library, "workspaceID": workspace], "digest": Data(SHA256.hash(data: Data(device.utf8))).base64EncodedString()]
    }
    try JSONSerialization.data(withJSONObject: ["version": 1, "grants": [grant(own), grant(phone)]]).write(to: file)
    let auth = try ExecutionAuthentication(fileURL: file)
    // A new grant issued before the sweep never exempts the older ones.
    let fresh = UUID().uuidString.lowercased()
    let token = try await auth.provision(deviceID: fresh, libraryID: library, workspaceID: workspace)
    try await auth.retireUnknownProvenance(keeping: own)
    await #expect(throws: LibraryAPIError.self) { try await auth.authenticate(bearer: phone) }
    #expect(try await auth.authenticate(bearer: own).deviceID == own)
    #expect(try await auth.authenticate(bearer: token).deviceID == fresh)
  }

  @Test func theOwnerValidatesAnotherMacsTrashAndAppliesItsOwnEffects() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let busy = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Busy", ownerDeviceID: UUID())
    let idle = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Idle", ownerDeviceID: UUID())
    let goal = try #require(try await a.database.mutateGoal(sessionID: idle, mutation: .set(objective: "Keep going", tokenBudget: nil, turnBudget: nil)))
    try await a.send(to: b)
    // The observer cannot trash another Mac's chat locally, and its copy of the goal is untouched.
    await #expect(throws: WorkspaceConversationActionError.ownedByAnotherMac) { try await b.database.mutateConversation(id: idle, mutation: .moveToTrash) }
    #expect(try await b.database.sessionGoals().first { $0.id == goal.id }?.status == .active)
    // A starts work after B last saw it idle; a stale trash from B still arrives.
    _ = try await a.database.beginLocalACPRun(conversationID: busy, input: .init(text: "Started after B looked"))
    try await b.database.write { connection in
      for id in [busy, idle] { try connection.toolsExecuteUnlocked("UPDATE dashboard_conversations SET deleted_at='2026-10-30T00:00:00Z' WHERE id=?", [id]) }
    }
    try await b.send(to: a)
    let deleted = { (database: WorkspaceDatabase, id: String) in
      try await database.read { try $0.historyRowsUnlocked("SELECT deleted_at FROM dashboard_conversations WHERE id=?", values: [id]).first?.objectValue?["deleted_at"]?.stringValue }
    }
    #expect(try await deleted(a.database, busy) == nil)
    #expect(try await a.database.activeRunID(conversationID: busy) != nil)
    // The idle chat is trashed by the owner, with the owner's goal pause.
    #expect(try await deleted(a.database, idle) != nil)
    // Trashed chats are hidden from the goal list, so read the stored goal.
    let goalStatus = { (database: WorkspaceDatabase) in
      try await database.read { try $0.historyRowsUnlocked("SELECT json_extract(value,'$.status') AS status FROM workspace_session_goals WHERE session_id=?", values: [idle]).first?.objectValue?["status"]?.stringValue }
    }
    #expect(try await goalStatus(a.database) == "paused")
    // The owner's decision converges back to the observer.
    try await a.send(to: b)
    #expect(try await deleted(b.database, busy) == nil)
    #expect(try await deleted(b.database, idle) != nil)
    #expect(try await goalStatus(b.database) == "paused")
  }

  @Test func aTitleOverrideAppliesWhicheverRowArrivesLastAndAfterRestart() async throws {
    let a = try await Mac(), b = try await Mac(), c = try await Mac(); defer { a.remove(); b.remove(); c.remove() }
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Original", ownerDeviceID: UUID())
    try await a.send(to: b)
    try await b.database.mutateConversation(id: session, mutation: .rename("Renamed on B"))
    // The owner's later native update carries its own, older title.
    try await a.database.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_conversations SET last_message_preview='native update' WHERE id=?", [session]) }
    let override = try #require(try await journal(b.database).last { $0.table == "desktop_conversation_titles" })
    let native = try #require(try await journal(a.database).last { $0.table == "dashboard_conversations" && $0.key == "[\"\(session)\"]" })
    let base = try await journal(a.database).filter { $0.table != "dashboard_conversations" || $0.key != "[\"\(session)\"]" || $0.vector != native.vector }
    for (index, order) in [[override, native], [native, override]].enumerated() {
      let receiver = index == 0 ? c.database : try await Mac().database
      try await deliver(base, to: receiver, from: a.id)
      for record in order { try await deliver([record], to: receiver, from: record.origin) }
      #expect(try await receiver.read { try $0.historyRowsUnlocked("SELECT title FROM dashboard_conversations WHERE id=?", values: [session]).first?.objectValue?["title"]?.stringValue } == "Renamed on B")
      let reopened = try await WorkspaceDatabase(url: receiver.fileURL)
      #expect(try await reopened.read { try $0.historyRowsUnlocked("SELECT title FROM dashboard_conversations WHERE id=?", values: [session]).first?.objectValue?["title"]?.stringValue } == "Renamed on B")
    }
  }

  @Test func aChatAdoptedIntoAnotherWorkspaceAcceptsItsNewExecutorsUpdates() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Moved to Linux", ownerDeviceID: UUID())
    let run = try await a.database.beginLocalACPRun(conversationID: session, input: .init(text: "Before adoption"))
    let linux = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: try await a.database.libraryID(),
      ownerDeviceID: a.id, kind: .linux, name: "Linux", endpoint: URL(string: "https://linux.fixture.ts.net/wovenmatter")!,
      capabilities: ["execution.v1"], executionDeviceID: UUID().uuidString.lowercased())
    _ = try await a.database.registerExecutionWorkspace(.init(workspace: linux), deviceID: a.id)
    // The chat is adopted into the Linux workspace on A.
    try await a.database.write { connection in
      try connection.toolsExecuteUnlocked("INSERT INTO execution_adoptions(conversation_id,workspace_id,payload) VALUES(?,?,x'7B7D')", [session, linux.id])
      try connection.toolsExecuteUnlocked("INSERT OR REPLACE INTO execution_conversations(id,workspace_id,conversation) VALUES(?,?,x'7B7D')", [session, linux.id])
    }
    try await a.send(to: b)
    // Runtime updates from the new executor's history, relayed by B, apply on A.
    try await b.database.write { try $0.toolsExecuteUnlocked("UPDATE dashboard_runs SET status='completed',error=NULL WHERE id=?", [run.runID]) }
    try await b.send(to: a)
    let status = try await a.database.read { try $0.historyRowsUnlocked("SELECT status FROM dashboard_runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
    #expect(status == "completed")
  }
}


extension PairedLibraryTests {
  @Test func protectedChatActionsNeedPositiveAuthorityEvenOnASplitSyncPage() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let workspace = try await registerMacWorkspace(a)
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Owner's chat", ownerDeviceID: UUID())
    _ = try #require(try await a.database.mutateGoal(sessionID: session, mutation: .set(objective: "Continue", tokenBudget: nil, turnBudget: nil)))
    // The chat and its goal arrive before its owner record and workspace.
    let records = try await journal(a.database)
    let metadata = records.filter { ["paired_conversation_owners", "execution_workspaces"].contains($0.table) }
    try await deliver(records.filter { !["paired_conversation_owners", "execution_workspaces"].contains($0.table) }, to: b.database, from: a.id)
    let before = try await lastChange(b.database)
    let goalValue = { try await b.database.read { try $0.historyRowsUnlocked("SELECT value FROM workspace_session_goals WHERE session_id=?", values: [session]).first?.objectValue?["value"]?.stringValue } }
    let originalGoal = try await goalValue()
    await #expect(throws: WorkspaceConversationActionError.unavailable) { try await b.database.mutateConversation(id: session, mutation: .moveToTrash) }
    await #expect(throws: WorkspaceConversationActionError.unavailable) { try await b.database.mutateConversation(id: session, mutation: .restore) }
    await #expect(throws: (any Error).self) { _ = try await b.database.moveConversation(id: session, toFolderID: nil) }
    #expect(try await lastChange(b.database) == before)
    #expect(try await goalValue() == originalGoal)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT deleted_at FROM dashboard_conversations WHERE id=?", values: [session]).first?.objectValue?["deleted_at"]?.stringValue } == nil)
    // Once the owner metadata arrives, the chat routes to its owner instead.
    try await deliver(metadata, to: b.database, from: a.id)
    await #expect(throws: WorkspaceConversationActionError.ownedByAnotherMac) { try await b.database.mutateConversation(id: session, mutation: .moveToTrash) }
    #expect(try await b.database.libraryConversationExecutionWorkspace(conversationID: session)?.id == workspace.id)
    #expect(try await goalValue() == originalGoal)
  }

  @Test func aChatAdoptedIntoLinuxIsManagedThroughItsIndependentWorkspaceNotItsOldMac() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    _ = try await registerMacWorkspace(a)
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Moved to Linux", ownerDeviceID: UUID())
    let linux = ExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: try await a.database.libraryID(),
      ownerDeviceID: a.id, kind: .linux, name: "Linux", endpoint: URL(string: "https://linux.fixture.ts.net/wovenmatter")!,
      capabilities: ["execution.v1"], executionDeviceID: UUID().uuidString.lowercased())
    _ = try await a.database.registerExecutionWorkspace(.init(workspace: linux), deviceID: a.id)
    try await a.send(to: b)
    await #expect(throws: WorkspaceConversationActionError.ownedByAnotherMac) { try await b.database.mutateConversation(id: session, mutation: .moveToTrash) }
    // The chat is adopted into the Linux workspace; B's copy follows it there.
    try await b.database.write { connection in
      try connection.executeUnlocked("UPDATE paired_library_clock SET applying=1")
      try connection.toolsExecuteUnlocked("INSERT OR REPLACE INTO execution_conversations(id,workspace_id,conversation) VALUES(?,?,x'7B7D')", [session, linux.id])
      try connection.toolsExecuteUnlocked("INSERT OR REPLACE INTO execution_adoptions(conversation_id,workspace_id,payload) VALUES(?,?,x'7B7D')", [session, linux.id])
      try connection.executeUnlocked("UPDATE paired_library_clock SET applying=0")
    }
    // Routing resolves to the independent Linux workspace, never the old Mac,
    // and trash/restore work as for any independent workspace projection.
    #expect(try await b.database.libraryConversationExecutionWorkspace(conversationID: session)?.kind == .linux)
    try await b.database.mutateConversation(id: session, mutation: .moveToTrash)
    try await b.database.mutateConversation(id: session, mutation: .restore)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT deleted_at FROM dashboard_conversations WHERE id=?", values: [session]).first?.objectValue?["deleted_at"]?.stringValue } == nil)
  }

  @Test func reimportingAGoalThisLibraryAlreadyHasNeverDuplicatesItsAccounting() async throws {
    let old = try await Mac(), full = try await Mac(); defer { old.remove(); full.remove() }
    let session = try await old.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Goal chat", ownerDeviceID: UUID(),
      fixtureLocation: .init(workspaceID: "local", rootPath: old.directory.path, managed: false))
    let goal = try #require(try await old.database.mutateGoal(sessionID: session, mutation: .set(objective: "Finish", tokenBudget: 1000, turnBudget: nil)))
    try await insertRun(old.database, "shared-run", conversation: session)
    try await old.database.recordGoalUsage(runID: "shared-run", tokens: 20)
    let first = old.directory.appending(path: "first-copy.sqlite")
    try WorkspaceDatabase.snapshotDatabase(from: old.database.fileURL, to: first)
    try await full.database.importLegacyLocalMacWorkspace(from: first)
    let total = { try await full.database.read { try $0.historyRowsUnlocked("SELECT json_extract(value,'$.tokensUsed') AS used FROM workspace_session_goals WHERE session_id=?", values: [session]).first?.objectValue?["used"]?.intValue } }
    let usage = { (run: String) in try await full.database.read { try $0.historyRowsUnlocked("SELECT tokens FROM workspace_goal_usage WHERE goal_id=? AND run_id=?", values: [goal.id, run]).first?.objectValue?["tokens"]?.intValue } }
    #expect(try await total() == 20)
    // The node kept working: more usage on the same run, and a new run.
    try await old.database.recordGoalUsage(runID: "shared-run", tokens: 80)
    try await insertRun(old.database, "new-run", conversation: session)
    try await old.database.recordGoalUsage(runID: "new-run", tokens: 5)
    let second = old.directory.appending(path: "second-copy.sqlite")
    try WorkspaceDatabase.snapshotDatabase(from: old.database.fileURL, to: second)
    for _ in 0..<2 { try await full.database.importLegacyLocalMacWorkspace(from: second) }
    // The same goal ID already exists here: its accounting is not overwritten
    // or partially duplicated by the later import.
    #expect(try await total() == 20)
    #expect(try await usage("shared-run") == 20)
    #expect(try await usage("new-run") == nil)
    // Future cumulative usage stays consistent with the stored total.
    _ = try await full.database.mutateGoal(sessionID: session, mutation: .resume(id: goal.id))
    try await full.database.recordGoalUsage(runID: "shared-run", tokens: 30)
    #expect(try await total() == 30)
    // The node's later run happened while this library's goal was paused, so
    // resuming does not enroll it; a run after resuming counts normally.
    try await full.database.recordGoalUsage(runID: "new-run", tokens: 5)
    #expect(try await total() == 30)
    try await insertRun(full.database, "after-resume", conversation: session)
    try await full.database.recordGoalUsage(runID: "after-resume", tokens: 4)
    #expect(try await total() == 34)
  }
}


extension PairedLibraryTests {
  private func copyRecordBytes(from source: Mac, to target: Mac) async throws {
    let sender = PairedLibraryFiles(root: source.directory), receiver = PairedLibraryFiles(root: target.directory)
    for file in try await sender.page(after: "").files where file.store == "paired-records" {
      while let offset = try await receiver.nextOffset(file) { try await receiver.receive(sender.chunk(.init(file: file, offset: offset))) }
    }
  }
  private func largeEdit(_ mac: Mac, _ id: String, title: String) async throws {
    let text = String(repeating: "Large offline writing 🧵 ", count: 20_000)
    let content = try NoteDocument(blocks: [.richText(.init(text: text))]).encoded()
    let receipt = try await mac.database.applyLibraryMutation(.init(deviceID: mac.id, kind: .updateNote, resourceID: id,
      expectedRevision: mac.database.libraryNote(id: id)?.revision, title: title, content: content))
    #expect(receipt.status == .accepted)
  }
  private func titles(_ mac: Mac) async throws -> Set<String> { Set(try await mac.database.librarySnapshot().notes.map(\.title)) }

  /// Malformed shared tool settings are quarantined on their own; the rest of
  /// the page, and every later page, still applies.
  @Test func malformedSharedToolSettingsAreQuarantinedWithoutStallingThePage() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    var settings = try await a.database.toolSettings(); settings.maximumManagedSessions = 5
    try await a.database.saveToolSettings(settings)
    let id = UUID().uuidString.lowercased()
    try await a.note(id, title: "Writing beside bad settings")
    let records = try await journal(a.database)
    let valid = try #require(records.last { $0.table == "workspace_tool_settings" && $0.row["value"]?.type == "text" })
    // Each malformed version supersedes the receiver's own, so it must materialize.
    let local = try await b.database.read {
      try $0.historyRowsUnlocked("SELECT json_extract(payload,'$.vector') AS vector FROM paired_library_rows WHERE table_name=? AND record_key=?",
        values: [valid.table, valid.key]).first?.objectValue?["vector"]?.stringValue
    }
    var vector = try local.map { try JSONDecoder().decode([String: Int64].self, from: Data($0.utf8)) } ?? [:]
    vector.merge(valid.vector, uniquingKeysWith: max)
    let validValue = try #require(valid.row["value"]?.value)
    let parsedShape = try JSONSerialization.jsonObject(with: Data(validValue.utf8))
    var shape = try #require(parsedShape as? [String: Any])
    shape["maximumManagedSessions"] = "five"
    let incompatible = String(decoding: try JSONSerialization.data(withJSONObject: shape, options: [.sortedKeys]), as: UTF8.self)
    let note = try #require(records.last { $0.table == "notes" && $0.key == "[\"\(id)\"]" })
    for (index, value) in ["{not json", "[]", incompatible].enumerated() {
      var row = valid.row; row["value"] = .init(type: "text", value: value)
      let clock = (vector.values.max() ?? 0) + 1_000
      vector[a.id] = clock
      let malformed = PairedLibraryRecord(table: valid.table, key: valid.key, row: row, deleted: valid.deleted,
        clock: clock, origin: a.id, vector: vector)
      try await deliver(index == 0 ? [malformed, note] : [malformed], to: b.database, from: a.id)
      #expect(try await b.database.pairedLibraryQuarantineCount() == index + 1)
    }
    #expect(try await b.database.libraryNote(id: id)?.title == "Writing beside bad settings")
    // The receiver's settings still load; nothing unreadable was stored.
    _ = try await b.database.toolSettings()
  }

  /// A version waiting for its bytes has not been seen here. Later writing from
  /// the same Mac applies meanwhile, but a local edit of the waiting note must
  /// stay concurrent with it, never silently supersede it on every Mac.
  @Test func aLocalEditWhileALargeVersionWaitsForItsBytesKeepsBothVersions() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased(), later = UUID().uuidString.lowercased()
    try await a.note(id, title: "Shared")
    try await a.send(to: b); try await b.send(to: a)
    try await largeEdit(a, id, title: "Large Air edit")
    try await a.note(later, title: "Later Air writing")
    try await a.send(to: b)
    #expect(try await b.database.libraryNote(id: later)?.title == "Later Air writing")
    #expect(try await b.database.libraryNote(id: id)?.title == "Shared")
    try await b.note(id, title: "Mini edit", revision: b.database.libraryNote(id: id)?.revision)
    try await copyRecordBytes(from: a, to: b)
    try await b.database.materializePendingPeerRecords()
    try await b.send(to: a); try await a.send(to: b)
    #expect(try await a.database.libraryNote(id: id)?.title == b.database.libraryNote(id: id)?.title)
    for mac in [a, b] {
      let names = try await titles(mac)
      #expect(names.contains("Mini edit") || names.contains("Mini edit (Recovered edit)"))
      #expect(names.contains("Large Air edit") || names.contains("Large Air edit (Recovered edit)"))
    }
  }

  /// A record whose envelope is invalid is quarantined even while its bytes are
  /// unavailable: it is never queued, relayed or retried.
  @Test func aMalformedWaitingRecordIsQuarantinedNotQueuedOrRelayed() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased()
    try await a.note(id, title: "Shared")
    let valid = try #require(try await journal(a.database).last { $0.table == "notes" && $0.key == "[\"\(id)\"]" })
    var row = valid.row; row["content"] = .init(type: "reference:text", value: String(repeating: "a", count: 64))
    // The origin's own entry disagrees with the record's clock.
    var vector = valid.vector; vector[a.id] = valid.clock + 1
    let malformed = PairedLibraryRecord(table: valid.table, key: valid.key, row: row, deleted: false, clock: valid.clock, origin: a.id, vector: vector)
    let before = try await lastChange(b.database)
    try await deliver([malformed], to: b.database, from: a.id)
    #expect(try await b.database.pairedLibraryQuarantineCount() == 1)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT id FROM paired_library_pending", values: []).isEmpty })
    #expect(try await lastChange(b.database) == before)
  }

  /// Several waiting versions of one note survive a restart, and an edit made
  /// after the restart stays concurrent with the latest of them.
  @Test func severalWaitingVersionsSurviveRestartAndStayConcurrentWithALocalEdit() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased(), later = UUID().uuidString.lowercased()
    try await a.note(id, title: "Shared")
    try await a.send(to: b); try await b.send(to: a)
    try await largeEdit(a, id, title: "Large Air edit 1")
    try await largeEdit(a, id, title: "Large Air edit 2")
    try await a.note(later, title: "Later Air writing")
    try await a.send(to: b)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT id FROM paired_library_pending", values: []).count } >= 2)
    let restarted = try await WorkspaceDatabase(url: b.database.fileURL)
    let content = try NoteDocument(blocks: [.richText(.init(text: "Mini edit"))]).encoded()
    let receipt = try await restarted.applyLibraryMutation(.init(deviceID: b.id, kind: .updateNote, resourceID: id,
      expectedRevision: restarted.libraryNote(id: id)?.revision, title: "Mini edit", content: content))
    #expect(receipt.status == .accepted)
    try await copyRecordBytes(from: a, to: b)
    try await restarted.materializePendingPeerRecords()
    #expect(try await restarted.read { try $0.historyRowsUnlocked("SELECT id FROM paired_library_pending", values: []).isEmpty })
    let names = Set(try await restarted.librarySnapshot().notes.map(\.title))
    #expect(names.contains("Mini edit") || names.contains("Mini edit (Recovered edit)"))
    #expect(names.contains("Large Air edit 2") || names.contains("Large Air edit 2 (Recovered edit)"))
  }

  /// A relaying Mac forwards a waiting version before any later writing that
  /// covers it, so a third Mac that edits the note meanwhile cannot claim to
  /// have seen the waiting version either.
  @Test func aRelayedLaterWriteNeverLetsAThirdMacSupersedeAWaitingVersion() async throws {
    let a = try await Mac(), b = try await Mac(), c = try await Mac(); defer { a.remove(); b.remove(); c.remove() }
    let id = UUID().uuidString.lowercased(), later = UUID().uuidString.lowercased()
    try await a.note(id, title: "Shared")
    try await a.send(to: b); try await b.send(to: c)
    try await largeEdit(a, id, title: "Large Air edit")
    try await a.note(later, title: "Later Air writing")
    // The Mini lacks the bytes and relays the Air's later writing to a third Mac.
    try await a.send(to: b); try await b.send(to: c)
    #expect(try await c.database.libraryNote(id: later)?.title == "Later Air writing")
    try await c.note(id, title: "Third Mac edit", revision: c.database.libraryNote(id: id)?.revision)
    try await c.send(to: b); try await c.send(to: a)
    try await copyRecordBytes(from: a, to: b); try await copyRecordBytes(from: a, to: c)
    for mac in [b, c] { try await mac.database.materializePendingPeerRecords() }
    for _ in 0..<2 {
      try await a.send(to: b); try await b.send(to: c); try await c.send(to: a)
      try await b.send(to: a); try await c.send(to: b); try await a.send(to: c)
    }
    let winner = try await a.database.libraryNote(id: id)?.title
    #expect(try await b.database.libraryNote(id: id)?.title == winner)
    #expect(try await c.database.libraryNote(id: id)?.title == winner)
    for mac in [a, b, c] {
      let names = try await titles(mac)
      #expect(names.contains("Third Mac edit") || names.contains("Third Mac edit (Recovered edit)"))
      #expect(names.contains("Large Air edit") || names.contains("Large Air edit (Recovered edit)"))
    }
  }
}

/// The shared schema is what every peer must agree on before rows move. It is
/// derived from column names and declared types, never physical order, so a
/// library migrated over many releases and a freshly created one (a Linux
/// host's) agree.
extension PairedLibraryTests {
  private func exchange(from sender: WorkspaceDatabase, _ senderID: String, to receiver: WorkspaceDatabase) async throws {
    var cursor = try await receiver.pairedLibraryCursors(senderID).pulled
    for _ in 0..<1000 {
      let page = try await sender.pairedLibraryPage(after: cursor)
      try await receiver.receivePairedLibrary(page, from: senderID)
      cursor = page.cursor
      if !page.hasMore { return }
    }
    Issue.record("Peer replay did not finish")
  }

  /// Nothing runs a chat over SSH, so the durable-run table that path kept is
  /// gone: a library that still has it, with rows, drops it when it opens,
  /// and its chats' runs stay as they were.
  @Test func aLibraryWithTheSSHDurableRunTableDropsItOnOpening() async throws {
    let legacy = try await Mac(); defer { legacy.remove() }
    let session = try await legacy.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Ran over SSH", ownerDeviceID: UUID())
    try await legacy.database.write { connection in
      try connection.executeUnlocked("""
        CREATE TABLE desktop_local_acp_durable_runs (run_id TEXT PRIMARY KEY, remote_workspace_id TEXT NOT NULL, native_session_id TEXT NOT NULL);
        CREATE TRIGGER desktop_local_acp_durable_runs_delete AFTER DELETE ON dashboard_runs BEGIN
          DELETE FROM desktop_local_acp_durable_runs WHERE run_id=OLD.id;
        END;
        INSERT INTO desktop_local_acp_durable_runs VALUES ('run', 'workspace', 'native');
        """)
    }
    let upgraded = try await WorkspaceDatabase(url: legacy.database.fileURL)
    #expect(try await upgraded.read { try $0.historyRowsUnlocked(
      "SELECT name FROM sqlite_master WHERE name LIKE 'desktop_local_acp_durable_runs%'", values: []) }.isEmpty)
    #expect(try await upgraded.read { try $0.historyRowsUnlocked("SELECT title FROM dashboard_conversations WHERE id=?", values: [session])
      .first?.objectValue?["title"]?.stringValue } == "Ran over SSH")
  }

  @Test func aMigratedLibraryAndAFreshOneShareOneSchemaAndExchangeRowsByName() async throws {
    let legacy = try await Mac(), fresh = try await Mac(); defer { legacy.remove(); fresh.remove() }
    let session = try await legacy.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Written before the upgrade", ownerDeviceID: UUID())
    // Older releases added projection_applied with ALTER TABLE, so it sits last.
    try await legacy.database.write { connection in
      let sql = try #require(try connection.historyRowsUnlocked("SELECT sql FROM sqlite_master WHERE name='dashboard_run_trace_events'", values: [])
        .first?.objectValue?["sql"]?.stringValue)
      #expect(sql.contains("projection_applied INTEGER NOT NULL DEFAULT 0,"))
      try connection.executeUnlocked("DROP TABLE dashboard_run_trace_events")
      try connection.executeUnlocked(sql.replacingOccurrences(of: "projection_applied INTEGER NOT NULL DEFAULT 0,", with: ""))
      try connection.executeUnlocked("ALTER TABLE dashboard_run_trace_events ADD COLUMN projection_applied INTEGER NOT NULL DEFAULT 0")
    }
    #expect(try await legacy.database.pairedLibrarySchema() == fresh.database.pairedLibrarySchema())
    // Libraries from before September 2026 also keep the unused is_main, and
    // their recorded versions of each chat carry it.
    try await legacy.database.write { connection in
      try connection.executeUnlocked("ALTER TABLE dashboard_conversations ADD COLUMN is_main INTEGER NOT NULL DEFAULT 0")
      let value = #"json('{"type":"integer","value":"0"}')"#
      try connection.executeUnlocked("""
        UPDATE paired_library_changes SET payload=json_set(payload,'$.row.is_main',\(value)) WHERE json_extract(payload,'$.table')='dashboard_conversations';
        UPDATE paired_library_rows SET payload=json_set(payload,'$.row.is_main',\(value)) WHERE table_name='dashboard_conversations';
        """)
    }
    #expect(try await legacy.database.pairedLibrarySchema() != fresh.database.pairedLibrarySchema())

    // Opening the library with this version drops the column and its traces.
    let upgraded = try await WorkspaceDatabase(url: legacy.database.fileURL)
    #expect(try await upgraded.read { try $0.historyRowsUnlocked("SELECT name FROM pragma_table_info('dashboard_conversations') WHERE name='is_main'", values: []) }.isEmpty)
    #expect(try await upgraded.read { try $0.historyRowsUnlocked("SELECT 1 AS present FROM paired_library_changes WHERE json_type(payload,'$.row.is_main') IS NOT NULL", values: []) }.isEmpty)
    #expect(try await upgraded.pairedLibrarySchema() == fresh.database.pairedLibrarySchema())

    let event = UUID().uuidString.lowercased()
    try await upgraded.write { try $0.toolsExecuteUnlocked("INSERT INTO dashboard_run_trace_events(id,conversation_id,content,projection_applied) VALUES(?,?,'step',1)", [event, session]) }
    try await exchange(from: upgraded, legacy.id, to: fresh.database)
    #expect(try await fresh.database.read { try $0.historyRowsUnlocked("SELECT title FROM dashboard_conversations WHERE id=?", values: [session]).first?.objectValue?["title"]?.stringValue } == "Written before the upgrade")
    #expect(try await fresh.database.read { try $0.historyRowsUnlocked("SELECT projection_applied FROM dashboard_run_trace_events WHERE id=?", values: [event]).first?.objectValue?["projection_applied"]?.intValue } == 1)
    #expect(try await fresh.database.pairedLibraryQuarantineCount() == 0)

    let note = UUID().uuidString.lowercased()
    try await fresh.note(note, title: "Written on the fresh library")
    try await exchange(from: fresh.database, fresh.id, to: upgraded)
    try await exchange(from: upgraded, legacy.id, to: fresh.database)
    #expect(try await upgraded.libraryNote(id: note)?.title == "Written on the fresh library")
    #expect(try await upgraded.pairedLibraryQuarantineCount() == 0)
    #expect(try await fresh.database.pairedLibraryQuarantineCount() == 0)
  }

  /// A library from before November 2026 keeps its device state in
  /// companion_* tables, its library ID in companion_workspace, sync
  /// bookkeeping that names those tables, and an owner trigger that reads one.
  /// Opening it renames everything in place: the library ID, a phone's
  /// schedule, an execution chat and the sync history all survive, and new
  /// chats and notes still save.
  @Test func aLibraryWithCompanionTablesKeepsItsIDAndDeviceStateWhenRenamed() async throws {
    let mac = try await Mac(), fresh = try await Mac(); defer { mac.remove(); fresh.remove() }
    let libraryID = try await mac.database.libraryID()
    try await mac.database.write { connection in
      try connection.executeUnlocked("""
        INSERT INTO calendar_task_executors(event_id,device_id) VALUES('event','phone');
        INSERT INTO execution_conversations(id,workspace_id,conversation) VALUES('chat','linux',x'7b7d');
        """)
    }
    #expect(try await mac.database.read { try $0.historyRowsUnlocked("SELECT 1 AS present FROM paired_library_rows WHERE table_name='calendar_task_executors'", values: []) }.count == 1)
    // Turn it back into the old layout, as origin/main wrote it.
    try await mac.database.write { connection in
      try connection.executeUnlocked("""
        CREATE TABLE companion_workspace(singleton INTEGER PRIMARY KEY CHECK(singleton = 1), workspace_id TEXT NOT NULL);
        INSERT INTO companion_workspace SELECT 1,library_id FROM library_identity;
        ALTER TABLE library_identity DROP COLUMN library_id;
        """)
      let present = Set(try connection.historyRowsUnlocked("SELECT name FROM sqlite_master WHERE type='table'", values: [])
        .compactMap { $0.objectValue?["name"]?.stringValue })
      for (old, new) in WorkspaceDatabaseConnection.legacyCompanionTables where present.contains(new) {
        try connection.executeUnlocked("ALTER TABLE \(new) RENAME TO \(old)")
        try connection.toolsExecuteUnlocked("UPDATE paired_library_rows SET table_name=?,payload=json_set(payload,'$.table',?) WHERE table_name=?", [old, old, new])
        try connection.toolsExecuteUnlocked("UPDATE paired_library_changes SET payload=json_set(payload,'$.table',?) WHERE json_extract(payload,'$.table')=?", [old, new])
      }
      try connection.executeUnlocked("""
        DROP TRIGGER paired_conversation_owner;
        CREATE TRIGGER paired_conversation_owner_v2 AFTER INSERT ON dashboard_conversations
        WHEN NOT EXISTS(SELECT 1 FROM companion_execution_conversations c WHERE c.id=NEW.id) BEGIN SELECT 1; END;
        CREATE TRIGGER companion_folder_detach BEFORE DELETE ON folders BEGIN SELECT 1; END;
        """)
    }

    let upgraded = try await WorkspaceDatabase(url: mac.database.fileURL)
    #expect(try await upgraded.libraryID() == libraryID)
    #expect(try await upgraded.read { try $0.historyRowsUnlocked("SELECT name FROM sqlite_master WHERE name LIKE 'companion%' OR sql LIKE '%companion\\_%' ESCAPE '\\'", values: []) }.isEmpty)
    #expect(try await upgraded.read { try $0.historyRowsUnlocked("SELECT device_id FROM calendar_task_executors WHERE event_id='event'", values: []).first?.objectValue?["device_id"]?.stringValue } == "phone")
    #expect(try await upgraded.read { try $0.historyRowsUnlocked("SELECT workspace_id FROM execution_conversations WHERE id='chat'", values: []).first?.objectValue?["workspace_id"]?.stringValue } == "linux")
    #expect(try await upgraded.read { try $0.historyRowsUnlocked("SELECT 1 AS present FROM paired_library_rows WHERE table_name='calendar_task_executors' AND json_extract(payload,'$.table')='calendar_task_executors'", values: []) }.count == 1)
    #expect(try await upgraded.read { try $0.historyRowsUnlocked("SELECT 1 AS present FROM paired_library_changes WHERE payload LIKE '%companion%' UNION ALL SELECT 1 FROM paired_library_rows WHERE table_name LIKE 'companion%'", values: []) }.isEmpty)
    #expect(try await upgraded.pairedLibrarySchema() == fresh.database.pairedLibrarySchema())

    let session = try await upgraded.createFixtureLocalACPSession(runtimeKind: .codex, title: "After the upgrade", ownerDeviceID: UUID())
    #expect(try await upgraded.read { try $0.historyRowsUnlocked("SELECT device_id FROM paired_conversation_owners WHERE id=?", values: [session]) }.count == 1)
    try await mac.note(UUID().uuidString.lowercased(), title: "Still saves")
    try await exchange(from: upgraded, mac.id, to: fresh.database)
    #expect(try await fresh.database.read { try $0.historyRowsUnlocked("SELECT device_id FROM calendar_task_executors WHERE event_id='event'", values: []).first?.objectValue?["device_id"]?.stringValue } == "phone")
    #expect(try await fresh.database.pairedLibraryQuarantineCount() == 0)
  }

  @Test func aTrulyDifferentSchemaStillMismatches() async throws {
    let a = try await Mac(), extra = try await Mac(), retyped = try await Mac()
    defer { a.remove(); extra.remove(); retyped.remove() }
    try await a.note(UUID().uuidString.lowercased(), title: "Shared")
    try await extra.database.write { try $0.executeUnlocked("ALTER TABLE notes ADD COLUMN shade TEXT") }
    try await retyped.database.write { connection in
      try connection.executeUnlocked("""
        DROP TABLE paired_mac_routes;
        CREATE TABLE paired_mac_routes(device_id TEXT PRIMARY KEY,library_id TEXT NOT NULL,endpoint TEXT NOT NULL,name BLOB NOT NULL);
        """)
    }
    let schema = try await a.database.pairedLibrarySchema()
    #expect(try await extra.database.pairedLibrarySchema() != schema)
    #expect(try await retyped.database.pairedLibrarySchema() != schema)
    let page = try await a.database.pairedLibraryPage(after: 0)
    await #expect(throws: LibraryAPIError.self) { try await extra.database.receivePairedLibrary(page, from: a.id) }
    await #expect(throws: LibraryAPIError.self) { try await retyped.database.receivePairedLibrary(page, from: a.id) }
  }

  /// The registry refresh saves remote workspace configurations every few
  /// seconds. An unchanged one is not rewritten, whatever key order an
  /// earlier build stored it in, so it never becomes a new shared change.
  @Test func anUnchangedRemoteWorkspaceConfigurationIsNotRewritten() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let remote = RemoteWorkspaceConfiguration(name: "Linux host", workspaceID: "fixture", hostName: "linux.example.ts.net", dataRoot: "/srv/woven")
    let id = remote.id.uuidString.lowercased()
    func stored(_ database: WorkspaceDatabase) async throws -> String? {
      try await database.read { try $0.historyRowsUnlocked("SELECT configuration FROM paired_remote_workspaces WHERE id=?", values: [id]).first?.objectValue?["configuration"]?.stringValue }
    }
    try await a.database.savePairedRemoteWorkspaces([remote])
    let saved = try await lastChange(a.database)
    for _ in 0..<3 { try await a.database.savePairedRemoteWorkspaces([remote]) }
    #expect(try await lastChange(a.database) == saved)

    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let sorted = String(decoding: try encoder.encode(remote), as: UTF8.self)
    #expect(try await stored(a.database) == sorted)
    // The same value in another key order, as an earlier build wrote it.
    let object = try #require(try JSONSerialization.jsonObject(with: Data(sorted.utf8)) as? [String: Any])
    let reversed = "{" + (try object.keys.sorted(by: >).map { key in
      "\"\(key)\":" + String(decoding: try JSONSerialization.data(withJSONObject: object[key]!, options: [.fragmentsAllowed]), as: UTF8.self)
    }).joined(separator: ",") + "}"
    #expect(reversed != sorted)
    #expect(try JSONDecoder().decode(RemoteWorkspaceConfiguration.self, from: Data(reversed.utf8)) == remote)
    try await a.database.write { try $0.toolsExecuteUnlocked("UPDATE paired_remote_workspaces SET configuration=? WHERE id=?", [reversed, id]) }
    let reordered = try await lastChange(a.database)
    try await a.database.savePairedRemoteWorkspaces([remote])
    #expect(try await lastChange(a.database) == reordered)
    #expect(try await stored(a.database) == reversed)

    // A real change is written once, in sorted form, and reaches peers.
    var renamed = remote; renamed.name = "Renamed host"
    try await a.database.savePairedRemoteWorkspaces([renamed])
    #expect(try await lastChange(a.database) > reordered)
    #expect(try await stored(a.database) == String(decoding: try encoder.encode(renamed), as: UTF8.self))
    try await a.send(to: b)
    let received = try #require(try await stored(b.database))
    #expect(try JSONDecoder().decode(RemoteWorkspaceConfiguration.self, from: Data(received.utf8)) == renamed)
  }
}
