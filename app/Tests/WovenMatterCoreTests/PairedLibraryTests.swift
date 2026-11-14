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
@testable import WovenMatterLibraryStore

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
      var cursor = try await other.database.peerSyncCursors(id).pulled
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
    let versions = try await a.database.peerSyncConflicts().filter { $0.record.table == "notes" }
    #expect(versions.count == 1)
    #expect(try await b.database.peerSyncConflicts().filter { $0.record.table == "notes" }.count == 1)
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
    #expect(try await reopened.peerSyncCursors(a.id).pulled == page.cursor)
    #expect(try await reopened.libraryNote(id: id)?.title == "Durable unsent writing")
    #expect(try await reopened.libraryIdentity().hostDeviceID == b.id)
  }

  @Test func runtimeQueuesAndPrivateCredentialsStayLocal() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let tables = try await a.database.pairedLibraryPage(after: 0).entries.map(\.table)
    #expect(!tables.contains("harness_sessions"))
    #expect(!tables.contains("session_deliveries"))
    #expect(!tables.contains("session_timers"))
    #expect(!tables.contains("execution_workspace_publishers"))
    a.database.prepareForPeerSync()
    _ = try await a.database.peerImportsReady()
    #expect(FileManager.default.fileExists(atPath: a.directory.appending(path: "Paired Mac Backups/before-peer-sync.sqlite").path))
    let route = PairedMacRoute(deviceID: a.id, libraryID: try await a.database.libraryID(), endpoint: URL(string: "https://air.example.ts.net:8443/wovenmatter")!, name: "Air")
    try await a.database.saveMacRoute(route)
    try await a.send(to: b)
    #expect(try await b.database.macRoutes() == [route])
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
    let bytes = Data([0, 255, 0, 1, 128]), size: Int64 = 9_007_199_254_740_993
    try await a.database.write { connection in
      let query = try connection.prepareUnlocked("INSERT INTO execution_retained_settlements VALUES('fixture','workspace',?)")
      defer { sqlite3_finalize(query) }
      try connection.bind(bytes, at: 1, to: query); try connection.stepDone(query)
      try connection.toolsExecuteUnlocked("""
        INSERT INTO execution_native_history(workspace_id,record_id,conversation_id,format,part_count,byte_count,sha256)
        VALUES('workspace','fixture','conversation','fixture',1,CAST(? AS INTEGER),'')
        """, [String(size)])
    }
    try await a.send(to: b)
    let result = try await b.database.read { connection -> (Int64, Data) in
      let query = try connection.prepareUnlocked("""
        SELECT n.byte_count,s.fingerprint FROM execution_native_history n, execution_retained_settlements s
        WHERE n.record_id='fixture' AND s.event_id='fixture'
        """)
      defer { sqlite3_finalize(query) }
      guard sqlite3_step(query) == SQLITE_ROW else { throw WorkspaceDatabaseError.corruptRow }
      return (sqlite3_column_int64(query, 0), try connection.blob(query, column: 1))
    }
    #expect(result.0 == size && result.1 == bytes)
  }

  /// A chunk's row names its bytes; a receiving Mac applies it once the file
  /// sync has brought that file, and serves the same bytes.
  @Test func artifactChunkRowsWaitForTheirFiles() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let bytes = Data((0..<1_500_000).map { UInt8(truncatingIfNeeded: $0 &* 31) }), id = UUID().uuidString.lowercased()
    let hash = SHA256.hash(data: bytes).hexString
    let manifest = LibraryArtifactManifest(id: id, workspaceID: "workspace", title: "Output.bin", mediaType: "application/octet-stream",
                                           byteCount: Int64(bytes.count), sha256: hash, revision: 1)
    try await a.database.write { connection in
      let first = Data(bytes.prefix(FederationProtocol.maximumArtifactChunkBytes))
      let chunks = [first, Data(bytes.dropFirst(first.count))]
      var offset: Int64 = 0
      for chunk in chunks {
        let hash = try connection.libraryFiles.retainChunk(chunk)
        try connection.toolsExecuteUnlocked("INSERT INTO artifact_chunks VALUES(?,1,CAST(? AS INTEGER),?,CAST(? AS INTEGER))",
                                            [id, String(offset), hash, String(chunk.count)])
        offset += Int64(chunk.count)
      }
      try connection.toolsExecuteUnlocked("INSERT INTO saved_artifacts VALUES(?,1,?)", [id, String(decoding: try JSONEncoder().encode(manifest), as: UTF8.self)])
    }
    #expect(try await a.database.libraryArtifactChunk(id: id, offset: 1_048_580).data == bytes.dropFirst(1_048_580))
    for record in try await journal(a.database) where record.table == "artifact_chunks" {
      #expect(record.row["bytes"] == nil && record.row["sha256"]?.type == "text" && record.row["byte_count"]?.type == "integer")
    }
    try await a.send(to: b)
    let waiting = try await b.database.read {
      try $0.historyRowsUnlocked("SELECT COUNT(*) AS count FROM peer_sync_versions WHERE pending_peer IS NOT NULL AND table_name='artifact_chunks'", values: [])
        .first?.objectValue?["count"]?.intValue
    }
    #expect(waiting == 2)
    await #expect(throws: (any Error).self) { try await b.database.libraryArtifactChunk(id: id, offset: 0) }
    let sender = PairedLibraryFiles(root: a.directory), receiver = PairedLibraryFiles(root: b.directory)
    for file in try await sender.page(after: "").files where file.store == "library-chunks" {
      while let offset = try await receiver.nextOffset(file) { try await receiver.receive(sender.chunk(.init(file: file, offset: offset))) }
    }
    try await b.database.materializePendingPeerRecords()
    var received = Data()
    while received.count < bytes.count { received.append(try await b.database.libraryArtifactChunk(id: id, offset: Int64(received.count)).data) }
    #expect(received == bytes)
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
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT id FROM history_events WHERE id=?", values: [eventID]).isEmpty })
    let files = PairedLibraryFiles(root: a.directory), receiver = PairedLibraryFiles(root: b.directory)
    let page = try await files.page(after: "")
    for file in page.files {
      while let offset = try await receiver.nextOffset(file) {
        try await receiver.receive(files.chunk(.init(file: file, offset: offset)))
      }
    }
    try await b.database.materializePendingPeerRecords()
    let result = try await b.database.read { try $0.historyRowsUnlocked("SELECT payload FROM history_events WHERE id=?", values: [eventID]).first?.objectValue?["payload"]?.stringValue }
    #expect(result == content)
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
    var cursor = try await observer.database.peerSyncCursors(linux.id).pulled
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
  /// Every version the database serves to peers, in cursor order.
  private func journal(_ database: WorkspaceDatabase) async throws -> [PairedLibraryRecord] {
    try await database.read { connection in
      try connection.historyRowsUnlocked("SELECT payload FROM peer_sync_versions ORDER BY cursor", values: [])
        .compactMap { $0.objectValue?["payload"]?.stringValue }
        .map { try JSONDecoder().decode(PairedLibraryRecord.self, from: Data($0.utf8)) }
    }
  }
  private func deliver(_ records: [PairedLibraryRecord], to database: WorkspaceDatabase, from peer: String) async throws {
    let schema = try await database.pairedLibraryPage(after: 0).schema
    try await database.receivePairedLibrary(.init(schema: schema, entries: records, cursor: 0, hasMore: true), from: peer)
  }
  private func lastChange(_ database: WorkspaceDatabase) async throws -> Int64 { try await database.peerSyncHead() }
  /// The vector of the winning applied version of one row, as sorted JSON.
  private func winnerVector(_ connection: WorkspaceDatabaseConnection, _ table: String, _ key: String) throws -> String? {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try PairedLibraryRecord.winner(connection.frontierMembersUnlocked(table: table, key: key))
      .map { String(decoding: try encoder.encode($0.vector), as: UTF8.self) }
  }
  private func noteState(_ database: WorkspaceDatabase, _ id: String) async throws -> String {
    try await database.read { connection in
      let row = try connection.historyRowsUnlocked("SELECT title,deleted_at FROM notes WHERE id=?", values: [id]).first?.objectValue
      let winner = try self.winnerVector(connection, "notes", "[\"\(id)\"]") ?? ""
      return (row?["deleted_at"]?.stringValue == nil ? (row?["title"]?.stringValue ?? "absent") : "deleted") + "|" + winner
    }
  }

  @Test func deletionLaterRestoreAndConcurrentEditConvergeInEveryArrivalOrder() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased(), key = "[\"\(id)\"]"
    // Each version supersedes the last, so it is read as it is written.
    let current = { try await self.journal(a.database).last { $0.table == "notes" && $0.key == key } }
    try await a.note(id, title: "Original")
    let create = try #require(try await current())
    try await a.send(to: b)
    try await b.note(id, title: "Mini edit", revision: b.database.libraryNote(id: id)?.revision)
    let revision = try #require(try await a.database.libraryNote(id: id)?.revision)
    _ = try await a.database.applyLibraryMutation(.init(deviceID: a.id, kind: .deleteNote, resourceID: id, expectedRevision: revision))
    let deletion = try #require(try await current())
    // An explicit later restore is a causal successor of the deletion.
    try await a.database.write { try $0.toolsExecuteUnlocked("UPDATE notes SET deleted_at=NULL,title='Restored' WHERE id=?", [id]) }
    let restore = try #require(try await current())
    #expect(deletion.deleted)
    #expect(try await journal(a.database).filter { $0.table == "notes" && $0.key == key } == [restore])
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
    #expect(try await reopened.activeLocalConversationIDs().isEmpty)
    #expect(try await !reopened.read { try $0.locallyOwnsConversationUnlocked(session) })
    let status = try await reopened.read { try $0.historyRowsUnlocked("SELECT status FROM runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
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
    let records = try await journal(a.database).filter { !$0.table.hasSuffix("_owners") }
    try await deliver(records, to: b.database, from: a.id)
    let reopened = try await WorkspaceDatabase(url: b.database.fileURL)
    let before = try await lastChange(reopened)
    try await reopened.recoverInterruptedLocalACPRuns()
    #expect(try await !reopened.read { try $0.locallyOwnsConversationUnlocked(session) })
    #expect(try await reopened.read { try $0.historyRowsUnlocked("SELECT id FROM conversation_owners WHERE id=?", values: [session]).isEmpty })
    #expect(try await lastChange(reopened) == before)
    let status = try await reopened.read { try $0.historyRowsUnlocked("SELECT status FROM runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
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
      func queue(_ record: PairedLibraryRecord) throws {
        try connection.toolsExecuteUnlocked("INSERT INTO peer_sync_versions(table_name,record_key,origin,clock,pending_peer,payload) VALUES(?,?,?,?,?,?)",
          [record.table, record.key, record.origin, String(record.clock), a.id, String(decoding: try encoder.encode(record), as: UTF8.self)])
      }
      // 120 distinct versions of the blocked note, each from its own origin, queued first.
      for index in 0..<120 {
        let blocked = referencing(waiting, hash: String(format: "%064x", index + 1)), origin = UUID().uuidString.lowercased()
        var vector = blocked.vector; vector[origin] = blocked.clock
        try queue(.init(table: blocked.table, key: blocked.key, row: blocked.row, deleted: false, clock: blocked.clock, origin: origin, vector: vector))
      }
      try queue(referencing(available, hash: hash))
    }
    try await b.database.materializePendingPeerRecords()
    #expect(try await b.database.libraryNote(id: ready)?.title == "Ready bytes")
    #expect(try await b.database.libraryNote(id: blocked) == nil)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT cursor FROM peer_sync_versions WHERE pending_peer IS NOT NULL", values: []).count } == 120)
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
      try await b.database.read { try $0.historyRowsUnlocked("SELECT json_extract(conversation,'$.title') AS title FROM execution_conversations WHERE id=?", values: [session]).first?.objectValue?["title"]?.stringValue }
    }
    try await b.database.write { connection in
      try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=1")
      try connection.toolsExecuteUnlocked("UPDATE execution_conversations SET conversation=json_set(conversation,'$.title','Untouched') WHERE id=?", [session])
      try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=0")
    }
    try await a.send(to: b)
    #expect(try await marker() == "Untouched")
    try await a.database.write { try $0.toolsExecuteUnlocked("UPDATE conversations SET title='Renamed by owner' WHERE id=?", [session]) }
    try await a.send(to: b)
    #expect(try await marker() == "Renamed by owner")
  }

  @Test func observersNeverCaptureWorkspaceFilesForAnotherMacsConversation() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Report", ownerDeviceID: UUID())
    _ = try await a.database.beginLocalACPRun(conversationID: session, input: .init(text: "Write reports/result.pdf"))
    try await a.database.write { connection in
      let message = try #require(try connection.historyRowsUnlocked("SELECT id FROM messages WHERE conversation_id=? LIMIT 1", values: [session]).first?.objectValue?["id"]?.stringValue)
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
    var row = base.row; row["position"] = .init(type: "integer", value: "not-a-number"); row["title"] = .init(type: "text", value: "Malformed")
    let bad = PairedLibraryRecord(table: "notes", key: base.key, row: row, deleted: false, clock: clock, origin: origin, vector: [origin: clock])
    let conflictsBefore = try await b.database.peerSyncConflicts().count
    try await deliver([bad, good], to: b.database, from: a.id)
    #expect(try await b.database.libraryNote(id: other)?.title == "Independent")
    #expect(try await b.database.libraryNote(id: shared)?.title == "Shared")
    #expect(try await b.database.peerSyncConflicts().count == conflictsBefore)
    #expect(try await b.database.peerSyncQuarantineCount() == 1)
    #expect(try await !b.database.librarySnapshot().notes.contains { $0.title.contains("Recovered edit") })
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

  @Test func theExecutionOwnersNativeRowsSurviveAStaleFederatedProjection() async throws {
    let node = try await Mac(), peer = try await Mac(); defer { node.remove(); peer.remove() }
    let session = try await node.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Native session", ownerDeviceID: UUID())
    let run = try await node.database.beginLocalACPRun(conversationID: session, input: .init(text: "Native input"))
    let native = try await node.database.read { connection in
      try #require(try connection.historyRowsUnlocked("SELECT agent_id,agent_codename FROM conversations WHERE id=?", values: [session]).first?.objectValue)
    }
    // Another member held a federated projection of the same chat and run.
    try await peer.database.write { connection in
      try connection.toolsExecuteUnlocked("INSERT INTO conversations(id,title,agent_codename,created_at,updated_at) VALUES(?,?,?,?,?)",
        [session, "Projected title", "projected", "2020-01-01T00:00:00Z", "2020-01-01T00:00:00Z"])
      try connection.toolsExecuteUnlocked("INSERT INTO runs(id,conversation_id,status,created_at) VALUES(?,?,'completed','2020-01-01T00:00:00Z')", [run.runID, session])
    }
    // Make the peer's copies win the deterministic order, as a busy peer would.
    try await peer.database.write { try $0.executeUnlocked("UPDATE peer_sync_clock SET tick=tick+1000000") }
    try await peer.database.write { try $0.toolsExecuteUnlocked("UPDATE conversations SET title='Projected title ' WHERE id=?", [session]) }
    try await peer.database.write { try $0.toolsExecuteUnlocked("UPDATE runs SET status='completed',error='projection' WHERE id=?", [run.runID]) }
    try await peer.send(to: node)
    let after = try await node.database.read { connection in
      try #require(try connection.historyRowsUnlocked("SELECT agent_id,agent_codename,title FROM conversations WHERE id=?", values: [session]).first?.objectValue)
    }
    // Native binding and run state are the owner's truth; the shared title edit applies.
    for key in ["agent_id", "agent_codename"] { #expect(after[key] == native[key]) }
    #expect(after["title"]?.stringValue == "Projected title ")
    #expect(try await node.database.activeRunID(conversationID: session) == run.runID)
    // The owner republishes its native rows, so the peer converges.
    try await node.send(to: peer)
    let converged = try await peer.database.read { connection in
      try #require(try connection.historyRowsUnlocked("SELECT agent_id,agent_codename FROM conversations WHERE id=?", values: [session]).first?.objectValue)
    }
    #expect(converged["agent_id"] == native["agent_id"] && converged["agent_codename"] == native["agent_codename"])
    let status = try await peer.database.read { try $0.historyRowsUnlocked("SELECT status FROM runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
    #expect(status == "running")
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
    try await mac.database.write { try $0.toolsExecuteUnlocked("INSERT INTO peer_sync_conflicts VALUES('losing','library_items','[\"item\"]',?,1,?)", [losing.origin, payload]) }
    try await mac.database.cleanupLibraryFiles()
    #expect(FileManager.default.fileExists(atPath: mac.directory.appending(path: "library-files/" + kept).path))
    #expect(!FileManager.default.fileExists(atPath: mac.directory.appending(path: "library-files/" + dropped).path))
  }
}


extension PairedLibraryTests {
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
      for id in [busy, idle] { try connection.toolsExecuteUnlocked("UPDATE conversations SET deleted_at='2026-10-30T00:00:00Z' WHERE id=?", [id]) }
    }
    try await b.send(to: a)
    let deleted = { (database: WorkspaceDatabase, id: String) in
      try await database.read { try $0.historyRowsUnlocked("SELECT deleted_at FROM conversations WHERE id=?", values: [id]).first?.objectValue?["deleted_at"]?.stringValue }
    }
    #expect(try await deleted(a.database, busy) == nil)
    #expect(try await a.database.activeRunID(conversationID: busy) != nil)
    // The idle chat is trashed by the owner, with the owner's goal pause.
    #expect(try await deleted(a.database, idle) != nil)
    // Trashed chats are hidden from the goal list, so read the stored goal.
    let goalStatus = { (database: WorkspaceDatabase) in
      try await database.read { try $0.historyRowsUnlocked("SELECT json_extract(value,'$.status') AS status FROM session_goals WHERE session_id=?", values: [idle]).first?.objectValue?["status"]?.stringValue }
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
    try await a.database.write { try $0.toolsExecuteUnlocked("UPDATE conversations SET last_message_preview='native update' WHERE id=?", [session]) }
    let override = try #require(try await journal(b.database).last { $0.table == "conversation_titles" })
    let native = try #require(try await journal(a.database).last { $0.table == "conversations" && $0.key == "[\"\(session)\"]" })
    let base = try await journal(a.database).filter { $0.table != "conversations" || $0.key != "[\"\(session)\"]" || $0.vector != native.vector }
    for (index, order) in [[override, native], [native, override]].enumerated() {
      let receiver = index == 0 ? c.database : try await Mac().database
      try await deliver(base, to: receiver, from: a.id)
      for record in order { try await deliver([record], to: receiver, from: record.origin) }
      #expect(try await receiver.read { try $0.historyRowsUnlocked("SELECT title FROM conversations WHERE id=?", values: [session]).first?.objectValue?["title"]?.stringValue } == "Renamed on B")
      let reopened = try await WorkspaceDatabase(url: receiver.fileURL)
      #expect(try await reopened.read { try $0.historyRowsUnlocked("SELECT title FROM conversations WHERE id=?", values: [session]).first?.objectValue?["title"]?.stringValue } == "Renamed on B")
    }
  }

  @Test func theOwnerReadsARenameMadeOnAnotherMac() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let session = try await a.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Original", ownerDeviceID: UUID())
    try await a.send(to: b)
    try await b.database.mutateConversation(id: session, mutation: .rename("Renamed on B"))
    try await b.send(to: a)
    // The session the owner runs carries the conversation's title, not the
    // one its local session row was created with.
    #expect(try await a.database.localACPSession(conversationID: session).title == "Renamed on B")
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
      try connection.toolsExecuteUnlocked("INSERT INTO execution_adoptions(conversation_id,workspace_id,payload) VALUES(?,?,'{}')", [session, linux.id])
      try connection.toolsExecuteUnlocked("INSERT OR REPLACE INTO execution_conversations(id,workspace_id,conversation) VALUES(?,?,'{}')", [session, linux.id])
    }
    try await a.send(to: b)
    // Runtime updates from the new executor's history, relayed by B, apply on A.
    try await b.database.write { try $0.toolsExecuteUnlocked("UPDATE runs SET status='completed',error=NULL WHERE id=?", [run.runID]) }
    try await b.send(to: a)
    let status = try await a.database.read { try $0.historyRowsUnlocked("SELECT status FROM runs WHERE id=?", values: [run.runID]).first?.objectValue?["status"]?.stringValue }
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
    let metadata = records.filter { ["conversation_owners", "execution_workspaces"].contains($0.table) }
    try await deliver(records.filter { !["conversation_owners", "execution_workspaces"].contains($0.table) }, to: b.database, from: a.id)
    let before = try await lastChange(b.database)
    let goalValue = { try await b.database.read { try $0.historyRowsUnlocked("SELECT value FROM session_goals WHERE session_id=?", values: [session]).first?.objectValue?["value"]?.stringValue } }
    let originalGoal = try await goalValue()
    await #expect(throws: WorkspaceConversationActionError.unavailable) { try await b.database.mutateConversation(id: session, mutation: .moveToTrash) }
    await #expect(throws: WorkspaceConversationActionError.unavailable) { try await b.database.mutateConversation(id: session, mutation: .restore) }
    await #expect(throws: (any Error).self) { _ = try await b.database.moveConversation(id: session, toFolderID: nil) }
    #expect(try await lastChange(b.database) == before)
    #expect(try await goalValue() == originalGoal)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT deleted_at FROM conversations WHERE id=?", values: [session]).first?.objectValue?["deleted_at"]?.stringValue } == nil)
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
      try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=1")
      try connection.toolsExecuteUnlocked("INSERT OR REPLACE INTO execution_conversations(id,workspace_id,conversation) VALUES(?,?,'{}')", [session, linux.id])
      try connection.toolsExecuteUnlocked("INSERT OR REPLACE INTO execution_adoptions(conversation_id,workspace_id,payload) VALUES(?,?,'{}')", [session, linux.id])
      try connection.executeUnlocked("UPDATE peer_sync_clock SET applying=0")
    }
    // Routing resolves to the independent Linux workspace, never the old Mac,
    // and trash/restore work as for any independent workspace projection.
    #expect(try await b.database.libraryConversationExecutionWorkspace(conversationID: session)?.kind == .linux)
    try await b.database.mutateConversation(id: session, mutation: .moveToTrash)
    try await b.database.mutateConversation(id: session, mutation: .restore)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT deleted_at FROM conversations WHERE id=?", values: [session]).first?.objectValue?["deleted_at"]?.stringValue } == nil)
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
    let valid = try #require(records.last { $0.table == "tool_settings" && $0.row["value"]?.type == "text" })
    // Each malformed version supersedes the receiver's own, so it must materialize.
    let local = try await b.database.read { try self.winnerVector($0, valid.table, valid.key) }
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
      #expect(try await b.database.peerSyncQuarantineCount() == index + 1)
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
    #expect(try await b.database.peerSyncQuarantineCount() == 1)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT cursor FROM peer_sync_versions WHERE pending_peer IS NOT NULL", values: []).isEmpty })
    #expect(try await lastChange(b.database) == before)
  }

  /// Several waiting versions of one note survive a restart, and an edit made
  /// after the restart stays concurrent with the latest of them.
  @Test func severalWaitingVersionsSurviveRestartAndStayConcurrentWithALocalEdit() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased(), later = UUID().uuidString.lowercased()
    try await a.note(id, title: "Shared")
    try await a.send(to: b); try await b.send(to: a)
    // Each version reaches the Mini before the next supersedes it on the Air.
    try await largeEdit(a, id, title: "Large Air edit 1")
    try await a.send(to: b)
    try await largeEdit(a, id, title: "Large Air edit 2")
    try await a.note(later, title: "Later Air writing")
    try await a.send(to: b)
    #expect(try await b.database.read { try $0.historyRowsUnlocked("SELECT cursor FROM peer_sync_versions WHERE pending_peer IS NOT NULL", values: []).count } >= 2)
    let restarted = try await WorkspaceDatabase(url: b.database.fileURL)
    let content = try NoteDocument(blocks: [.richText(.init(text: "Mini edit"))]).encoded()
    let receipt = try await restarted.applyLibraryMutation(.init(deviceID: b.id, kind: .updateNote, resourceID: id,
      expectedRevision: restarted.libraryNote(id: id)?.revision, title: "Mini edit", content: content))
    #expect(receipt.status == .accepted)
    try await copyRecordBytes(from: a, to: b)
    try await restarted.materializePendingPeerRecords()
    #expect(try await restarted.read { try $0.historyRowsUnlocked("SELECT cursor FROM peer_sync_versions WHERE pending_peer IS NOT NULL", values: []).isEmpty })
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

/// Peers agree on the exchange format (`PairedLibraryFormat`), and each
/// keeps what a newer one adds until it updates. The schema hash peers report
/// is derived from column names and declared types, never physical order, so
/// a library migrated over many releases and a freshly created one (a Linux
/// host's) report the same.
extension PairedLibraryTests {
  private func exchange(from sender: WorkspaceDatabase, _ senderID: String, to receiver: WorkspaceDatabase) async throws {
    var cursor = try await receiver.peerSyncCursors(senderID).pulled
    for _ in 0..<1000 {
      let page = try await sender.pairedLibraryPage(after: cursor)
      try await receiver.receivePairedLibrary(page, from: senderID)
      cursor = page.cursor
      if !page.hasMore { return }
    }
    Issue.record("Peer replay did not finish")
  }

  /// Adds a shared column the way a later release would: the column, then
  /// the capture triggers rebuilt for it.
  private func addShade(_ mac: Mac) async throws {
    try await mac.database.write { connection in
      try connection.executeUnlocked("ALTER TABLE notes ADD COLUMN shade TEXT")
      try connection.migratePeerSync()
    }
  }
  private func shade(_ mac: Mac, _ id: String) async throws -> String? {
    try await mac.database.read {
      try $0.historyRowsUnlocked("SELECT shade FROM notes WHERE id=?", values: [id]).first?.objectValue?["shade"]?.stringValue
    }
  }
  private func setShade(_ mac: Mac, _ id: String, _ value: String) async throws {
    try await mac.database.write { try $0.toolsExecuteUnlocked("UPDATE notes SET shade=? WHERE id=?", [value, id]) }
  }

  /// Peers agree on the exchange format, not on an identical schema. A page
  /// in another format, or from a build before the format, is refused whole:
  /// nothing applies and the cursor stays, so the exchange resumes after the
  /// update.
  @Test func aPageInAnotherExchangeFormatIsRefusedWhole() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased()
    try await a.note(id, title: "Shared")
    let page = try await a.database.pairedLibraryPage(after: 0)
    #expect(page.format == PairedLibraryFormat.exchange)
    for format in [nil, PairedLibraryFormat.exchange + 1] {
      let other = PairedLibraryPage(format: format, schema: page.schema, entries: page.entries, cursor: page.cursor, hasMore: page.hasMore)
      do {
        try await b.database.receivePairedLibrary(other, from: a.id)
        Issue.record("A page in format \(String(describing: format)) was accepted")
      } catch let error as LibraryAPIError { #expect(error.code == "update_required") }
    }
    #expect(try await b.database.libraryNote(id: id) == nil)
    #expect(try await b.database.peerSyncCursors(a.id).pulled == 0)
    // A build before the format sent no `format` at all.
    let old = try JSONDecoder().decode(PairedLibraryPage.self, from: Data(#"{"schema":"x","entries":[],"cursor":0,"hasMore":false}"#.utf8))
    #expect(old.format == nil)
    try await b.database.receivePairedLibrary(page, from: a.id)
    #expect(try await b.database.libraryNote(id: id)?.title == "Shared")
  }

  /// A later release adds a shared column. A device that has not updated
  /// keeps each record carrying it exactly as received, relays it to devices
  /// that have, keeps synchronizing everything else, and applies it once it
  /// updates. Nothing is rejected, and the new column's value is never cut off.
  @Test func aNewerPeersColumnWaitsIsRelayedAndAppliesAfterThisDeviceUpdates() async throws {
    let newer = try await Mac(), older = try await Mac(), other = try await Mac()
    defer { newer.remove(); older.remove(); other.remove() }
    try await addShade(newer); try await addShade(other)
    #expect(try await newer.database.pairedLibrarySchema() != older.database.pairedLibrarySchema())
    let id = UUID().uuidString.lowercased()
    try await newer.note(id, title: "Shaded")
    try await setShade(newer, id, "blue")
    var settings = try await newer.database.toolSettings(); settings.maximumManagedSessions = 5
    try await newer.database.saveToolSettings(settings)

    try await newer.send(to: older)
    // The note waits; a table whose shape both know applied in the same pages.
    #expect(try await older.database.libraryNote(id: id) == nil)
    #expect(try await older.database.toolSettings().maximumManagedSessions == 5)
    #expect(try await older.database.peerSyncWaitingForUpdate() == 1)
    #expect(try await older.database.peerSyncQuarantineCount() == 0)
    #expect(try await older.database.peerSyncCursors(newer.id).pulled == newer.database.peerSyncHead())
    // Retrying changes nothing while this build still lacks the column.
    try await older.database.materializePendingPeerRecords()
    #expect(try await older.database.peerSyncWaitingForUpdate() == 1)

    // Relayed through the device that cannot read it, the column survives.
    try await older.send(to: other)
    #expect(try await other.database.libraryNote(id: id)?.title == "Shaded")
    #expect(try await shade(other, id) == "blue")

    // The update arrives: the waiting record applies.
    try await addShade(older)
    try await older.database.materializePendingPeerRecords()
    #expect(try await older.database.libraryNote(id: id)?.title == "Shaded")
    #expect(try await shade(older, id) == "blue")
    #expect(try await older.database.peerSyncWaitingForUpdate() == 0)
  }

  /// A row a newer build keeps rewriting waits as its latest version only.
  @Test func supersededWaitingVersionsOfARowFromANewerBuildAreNotKept() async throws {
    let newer = try await Mac(), older = try await Mac(); defer { newer.remove(); older.remove() }
    try await addShade(newer)
    let id = UUID().uuidString.lowercased()
    try await newer.note(id, title: "Shaded")
    for value in ["blue", "green", "red"] {
      try await setShade(newer, id, value)
      try await newer.send(to: older)
    }
    #expect(try await older.database.peerSyncWaitingForUpdate() == 1)
    try await addShade(older)
    try await older.database.materializePendingPeerRecords()
    #expect(try await shade(older, id) == "red")
  }

  /// An edit made here while a newer build's version of the same row waits is
  /// concurrent with it: both survive once this device updates.
  @Test func aLocalEditWhileANewerBuildsVersionWaitsKeepsBothVersions() async throws {
    let newer = try await Mac(), older = try await Mac(); defer { newer.remove(); older.remove() }
    let id = UUID().uuidString.lowercased()
    try await newer.note(id, title: "Shared")
    try await newer.send(to: older); try await older.send(to: newer)
    try await addShade(newer)
    try await newer.note(id, title: "Newer edit", revision: newer.database.libraryNote(id: id)?.revision)
    try await newer.send(to: older)
    #expect(try await older.database.libraryNote(id: id)?.title == "Shared")
    try await older.note(id, title: "Older edit", revision: older.database.libraryNote(id: id)?.revision)
    try await addShade(older)
    try await older.database.materializePendingPeerRecords()
    try await older.send(to: newer); try await newer.send(to: older)
    #expect(try await newer.database.libraryNote(id: id)?.title == older.database.libraryNote(id: id)?.title)
    for mac in [newer, older] {
      let names = try await titles(mac)
      #expect(names.contains("Newer edit") || names.contains("Newer edit (Recovered edit)"))
      #expect(names.contains("Older edit") || names.contains("Older edit (Recovered edit)"))
    }
  }

  /// A device that knows more columns than a record carries applies the ones
  /// it has: a new row takes the column's default, and an existing row keeps
  /// the value this device holds.
  @Test func anOlderPeersRowsApplyAndKeepTheColumnsOnlyThisDeviceKnows() async throws {
    let newer = try await Mac(), older = try await Mac(); defer { newer.remove(); older.remove() }
    try await addShade(newer)
    let id = UUID().uuidString.lowercased()
    try await older.note(id, title: "From the older build")
    try await older.send(to: newer)
    #expect(try await newer.database.libraryNote(id: id)?.title == "From the older build")
    #expect(try await shade(newer, id) == nil)
    try await setShade(newer, id, "blue")
    // The older build has not seen that write; its later edits outrank it.
    for title in ["Second", "Third", "Latest from the older build"] {
      try await older.note(id, title: title, revision: older.database.libraryNote(id: id)?.revision)
    }
    try await older.send(to: newer)
    #expect(try await newer.database.libraryNote(id: id)?.title == "Latest from the older build")
    #expect(try await shade(newer, id) == "blue")
    #expect(try await newer.database.peerSyncQuarantineCount() == 0)

    // Every device arrives at that row, whatever order the versions came in:
    // one that received the older build's edits first, and the older device
    // itself once it updates and applies the write it had kept waiting.
    let other = try await Mac(); defer { other.remove() }
    try await addShade(other)
    try await older.send(to: other)
    #expect(try await shade(other, id) == nil)
    try await newer.send(to: other)
    try await newer.send(to: older)
    try await addShade(older)
    try await older.database.materializePendingPeerRecords()
    for mac in [newer, other, older] {
      #expect(try await mac.database.libraryNote(id: id)?.title == "Latest from the older build")
      #expect(try await shade(mac, id) == "blue")
    }
  }

  /// A record kept for an update is checked against the member that sent it
  /// when it is finally applied. A Linux host may write an owner row only for
  /// itself, also by way of a record this build could not read at first; a
  /// peer that is no longer a member is trusted with nothing it does not serve.
  @Test func aRecordKeptForAnUpdateIsCheckedAgainstItsSenderWhenApplied() async throws {
    let linux = UUID().uuidString.lowercased(), victim = UUID().uuidString.lowercased()
    func held(_ mac: Mac, conversation: String) async throws {
      let record = PairedLibraryRecord(table: "conversation_owners", key: "[\"\(conversation)\"]", row: [
        "id": .init(type: "text", value: conversation), "device_id": .init(type: "text", value: victim),
        "note": .init(type: "text", value: "from a later release")], deleted: false, clock: 5, origin: linux, vector: [linux: 5])
      let sender = PairedLibrarySender(deviceID: linux, kind: .linux, members: [.init(deviceID: linux, kind: .linux, endpoints: [], revoked: false)])
      let schema = try await mac.database.pairedLibrarySchema()
      try await mac.database.receivePairedLibrary(.init(schema: schema, entries: [record], cursor: 0, hasMore: true), from: linux, sender: sender)
      #expect(try await mac.database.peerSyncWaitingForUpdate() == 1)
      // The update that makes it readable.
      try await mac.database.write { connection in
        try connection.executeUnlocked("ALTER TABLE conversation_owners ADD COLUMN note TEXT")
        try connection.migratePeerSync()
      }
    }
    func owners(_ mac: Mac, _ conversation: String) async throws -> Int {
      try await mac.database.read { try $0.historyRowsUnlocked("SELECT 1 AS present FROM conversation_owners WHERE id=?", values: [conversation]).count }
    }
    let member = PairedLibrarySender(deviceID: linux, kind: .linux, members: [.init(deviceID: linux, kind: .linux, endpoints: [], revoked: false)])
    let mac = try await Mac(); defer { mac.remove() }
    let conversation = UUID().uuidString.lowercased()
    try await held(mac, conversation: conversation)
    func waiting() async throws -> Int {
      try await mac.database.read { try $0.historyRowsUnlocked("SELECT cursor FROM peer_sync_versions WHERE pending_peer IS NOT NULL", values: []).count }
    }
    // While its sender cannot be checked (the member list was unavailable, or
    // lacks that peer), the record neither applies nor is dropped.
    try await mac.database.materializePendingPeerRecords(senders: [:])
    #expect(try await owners(mac, conversation) == 0)
    #expect(try await waiting() == 1)
    // Checked against the Linux host that sent it, it is refused: the row names another device.
    try await mac.database.materializePendingPeerRecords(senders: [linux: member])
    #expect(try await owners(mac, conversation) == 0)
    #expect(try await waiting() == 0)
    #expect(try await mac.database.peerSyncWaitingForUpdate() == 0)
  }

  /// A record for a table this build does not have, or whose content needs a
  /// newer build (`PairedLibraryRecord.needs`), waits and is relayed with
  /// that marker intact; it is not quarantined.
  @Test func recordsForAnUnknownTableOrNewerContentWaitAndAreRelayedUnchanged() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased()
    try await a.note(id, title: "Shared")
    let valid = try #require(try await journal(a.database).last { $0.table == "notes" && $0.key == "[\"\(id)\"]" })
    var row = valid.row; row["title"] = .init(type: "text", value: "Needs a newer build")
    let content = PairedLibraryRecord(table: valid.table, key: valid.key, row: row, deleted: false, clock: valid.clock + 10,
      origin: a.id, vector: [a.id: valid.clock + 10], needs: PairedLibraryFormat.content + 1)
    let table = PairedLibraryRecord(table: "moods", key: "[\"m\"]", row: ["id": .init(type: "text", value: "m")], deleted: false,
      clock: valid.clock + 11, origin: a.id, vector: [a.id: valid.clock + 11])
    try await deliver([valid, content, table], to: b.database, from: a.id)
    #expect(try await b.database.libraryNote(id: id)?.title == "Shared")
    #expect(try await b.database.peerSyncQuarantineCount() == 0)
    #expect(try await b.database.peerSyncWaitingForUpdate() == 2)
    let relayed = try await journal(b.database)
    #expect(relayed.contains(content) && relayed.contains(table))
    // The marker survives a page built for the next peer.
    let page = try await b.database.pairedLibraryPage(after: 0)
    #expect(page.entries.first { $0.clock == content.clock && $0.origin == a.id }?.needs == PairedLibraryFormat.content + 1)
    // A record without the marker encodes without it, as every capture does.
    #expect(!String(decoding: try JSONEncoder().encode(valid), as: UTF8.self).contains("needs"))
  }

  /// The registry refresh saves remote workspace configurations every few
  /// seconds. An unchanged one is not rewritten, whatever key order an
  /// earlier build stored it in, so it never becomes a new shared change.
  @Test func anUnchangedRemoteWorkspaceConfigurationIsNotRewritten() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let remote = RemoteWorkspaceConfiguration(name: "Linux host", workspaceID: "fixture", hostName: "linux.example.ts.net", dataRoot: "/srv/woven")
    let id = remote.id.uuidString.lowercased()
    func stored(_ database: WorkspaceDatabase) async throws -> String? {
      try await database.read { try $0.historyRowsUnlocked("SELECT configuration FROM remote_workspace_configurations WHERE id=?", values: [id]).first?.objectValue?["configuration"]?.stringValue }
    }
    try await a.database.saveRemoteWorkspaceConfigurations([remote])
    let saved = try await lastChange(a.database)
    for _ in 0..<3 { try await a.database.saveRemoteWorkspaceConfigurations([remote]) }
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
    try await a.database.write { try $0.toolsExecuteUnlocked("UPDATE remote_workspace_configurations SET configuration=? WHERE id=?", [reversed, id]) }
    let reordered = try await lastChange(a.database)
    try await a.database.saveRemoteWorkspaceConfigurations([remote])
    #expect(try await lastChange(a.database) == reordered)
    #expect(try await stored(a.database) == reversed)

    // A real change is written once, in sorted form, and reaches peers.
    var renamed = remote; renamed.name = "Renamed host"
    try await a.database.saveRemoteWorkspaceConfigurations([renamed])
    #expect(try await lastChange(a.database) > reordered)
    #expect(try await stored(a.database) == String(decoding: try encoder.encode(renamed), as: UTF8.self))
    try await a.send(to: b)
    let received = try #require(try await stored(b.database))
    #expect(try JSONDecoder().decode(RemoteWorkspaceConfiguration.self, from: Data(received.utf8)) == renamed)
  }
}
