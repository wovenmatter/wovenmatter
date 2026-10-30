import Foundation
import CryptoKit
import SQLite3
import WovenMatterClient
import WorkspaceFixtures
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Equal paired Mac libraries", .serialized)
struct PairedLibraryTests {
  private struct Mac {
    let directory: URL
    let database: WorkspaceDatabase
    let id: String
    init() async throws {
      directory = FileManager.default.temporaryDirectory.appending(path: "paired-mac-" + UUID().uuidString)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
      id = try await database.companionLibraryIdentity().hostDeviceID
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    func note(_ id: String, title: String, revision: Int64? = nil) async throws {
      let content = try NoteDocument(blocks: [.richText(.init(text: title))]).encoded()
      let receipt = try await database.applyCompanionMutation(.init(deviceID: self.id,
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
    #expect(try await c.database.companionNote(id: first)?.title == "Air offline")
    #expect(try await c.database.companionNote(id: second)?.title == "Mini offline")
    try await c.note(first, title: "Third Mac edit", revision: c.database.companionNote(id: first)?.revision)
    try await c.send(to: a); try await a.send(to: b)
    #expect(try await a.database.companionNote(id: first)?.title == "Third Mac edit")
    #expect(try await b.database.companionNote(id: first)?.title == "Third Mac edit")
    #expect(try await a.database.companionLibraryIdentity().hostDeviceID == a.id)
    #expect(try await b.database.companionLibraryIdentity().hostDeviceID == b.id)
    #expect(try await a.database.companionWorkspaceID() != b.database.companionWorkspaceID())
  }

  @Test func concurrentWritingRetainsBothVersionsAndDeletionDoesNotResurrect() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let id = UUID().uuidString.lowercased()
    try await a.note(id, title: "Shared")
    try await a.send(to: b); try await b.send(to: a)
    try await a.note(id, title: "Air edit", revision: a.database.companionNote(id: id)?.revision)
    try await b.note(id, title: "Mini edit", revision: b.database.companionNote(id: id)?.revision)
    try await a.send(to: b); try await b.send(to: a)
    #expect(try await a.database.companionNote(id: id)?.title == b.database.companionNote(id: id)?.title)
    let versions = try await a.database.pairedLibraryConflicts().filter { $0.record.table == "notes" }
    #expect(versions.count == 1)
    #expect(try await b.database.pairedLibraryConflicts().filter { $0.record.table == "notes" }.count == 1)
    let revision = try #require(try await a.database.companionNote(id: id)?.revision)
    _ = try await a.database.applyCompanionMutation(.init(deviceID: a.id, kind: .deleteNote, resourceID: id, expectedRevision: revision))
    try await b.note(id, title: "Offline during deletion", revision: b.database.companionNote(id: id)?.revision)
    try await a.send(to: b); try await b.send(to: a); try await a.send(to: b)
    #expect(try await a.database.companionNote(id: id) == nil)
    #expect(try await b.database.companionNote(id: id) == nil)
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
    #expect(try await reopened.companionNote(id: id)?.title == "Durable unsent writing")
    #expect(try await reopened.companionLibraryIdentity().hostDeviceID == b.id)
  }

  @Test func runtimeQueuesAndPrivateCredentialsStayLocal() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let tables = try await a.database.pairedLibraryPage(after: 0).entries.map(\.table)
    #expect(!tables.contains("desktop_local_acp_sessions"))
    #expect(!tables.contains("workspace_session_deliveries"))
    #expect(!tables.contains("workspace_session_timers"))
    #expect(!tables.contains("companion_workspace_publishers"))
    try await a.database.backUpBeforePeerSync()
    #expect(FileManager.default.fileExists(atPath: a.directory.appending(path: "Paired Mac Backups/before-peer-sync.sqlite").path))
    let route = PairedMacRoute(deviceID: a.id, libraryID: try await a.database.companionWorkspaceID(), endpoint: URL(string: "https://air.example.ts.net:8443/wovenmatter")!, name: "Air")
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
    await #expect(throws: CompanionAPIError.self) {
      try await reopened.nextOffset(.init(store: "../", hash: hash, byteCount: Int64(bytes.count)))
    }
    let invalid = PairedLibraryFile(store: "library-files", hash: String(repeating: "0", count: 64), byteCount: 1)
    await #expect(throws: CompanionAPIError.self) {
      try await reopened.receive(.init(file: invalid, offset: 0, data: Data([1])))
    }
    #expect(try await reopened.nextOffset(invalid) == 0)
    let healthyBytes = Data([9])
    let healthyHash = try LibraryFileStore(supportDirectory: a.directory).retain(healthyBytes)
    let healthy = PairedLibraryFile(store: "library-files", hash: healthyHash, byteCount: 1)
    await #expect(throws: CompanionAPIError.self) {
      try await reopened.receive(.init(file: healthy, offset: 0, data: Data([1])))
    }
    try await reopened.receive(.init(file: healthy, offset: 0, data: healthyBytes))
    #expect(try await reopened.nextOffset(healthy) == nil)
  }

  @Test func credentialVerifiersPropagateWithPermanentRevocationAndFreshRepair() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let first = try CompanionAuthentication(fileURL: a.directory.appending(path: "devices.json"))
    let second = try CompanionAuthentication(fileURL: b.directory.appending(path: "devices.json"))
    let device = UUID().uuidString.lowercased(), old = String(repeating: "a", count: 43), new = String(repeating: "b", count: 43)
    try await first.enrollPeer(deviceID: device, name: "Mac", token: old)
    try await second.mergePeerDevices(first.peerDevices())
    #expect(try await second.authenticate(bearer: old).id == device)
    try await first.revoke(deviceID: device)
    try await first.enrollPeer(deviceID: device, name: "Mac", token: new)
    try await second.mergePeerDevices(first.peerDevices())
    await #expect(throws: CompanionAPIError.self) { try await second.authenticate(bearer: old) }
    #expect(try await second.authenticate(bearer: new).id == device)
    #expect(await second.devices().count == 1)
    let wire = String(decoding: try JSONEncoder().encode(await second.peerDevices()), as: UTF8.self)
    #expect(!wire.contains(old) && !wire.contains(new))
    let reopened = try CompanionAuthentication(fileURL: b.directory.appending(path: "devices.json"))
    await #expect(throws: CompanionAPIError.self) { try await reopened.authenticate(bearer: old) }
  }

  @Test func typedRowsKeepBinaryBytesAndIntegersBeyondJSONDoublePrecision() async throws {
    let a = try await Mac(), b = try await Mac(); defer { a.remove(); b.remove() }
    let bytes = Data([0, 255, 0, 1, 128]), offset: Int64 = 9_007_199_254_740_993
    try await a.database.write { connection in
      let query = try connection.prepareUnlocked("INSERT INTO companion_artifact_chunks VALUES('fixture',1,?,?)")
      defer { sqlite3_finalize(query) }
      sqlite3_bind_int64(query, 1, offset); try connection.bind(bytes, at: 2, to: query); try connection.stepDone(query)
    }
    try await a.send(to: b)
    let result = try await b.database.read { connection -> (Int64, Data) in
      let query = try connection.prepareUnlocked("SELECT offset,bytes FROM companion_artifact_chunks WHERE artifact_id='fixture'")
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
    #expect(try await b.database.companionNote(id: noteID)?.title == "Independent writing")
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
    #expect(try await full.database.companionNote(id: note)?.title == "Legacy writing")
    #expect(try await full.database.read { try $0.historyRowsUnlocked("SELECT conversation_id FROM desktop_local_acp_sessions WHERE conversation_id=?", values: [id]).count } == 1)
    #expect(try await old.database.read { try $0.historyRowsUnlocked("SELECT conversation_id FROM desktop_local_acp_sessions WHERE conversation_id=?", values: [id]).count } == 1)
    #expect(try await old.database.companionNote(id: note)?.title == "Legacy writing")
    #expect(try await full.database.companionLibraryIdentity().hostDeviceID == full.id)
  }
}


extension PairedLibraryTests {
  @Test func directOriginHistoryCanReachOtherPeersWhileItsManagingMacIsOffline() async throws {
    let manager = try await Mac(), observer = try await Mac(), third = try await Mac()
    defer { manager.remove(); observer.remove(); third.remove() }
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: try await manager.database.companionWorkspaceID(),
      ownerDeviceID: manager.id, kind: .linux, name: "Linux owner", endpoint: URL(string: "https://linux.fixture.ts.net/wovenmatter")!,
      capabilities: ["execution.v1"], executionDeviceID: UUID().uuidString.lowercased())
    _ = try await manager.database.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: manager.id)
    try await manager.send(to: observer)
    let id = UUID().uuidString.lowercased()
    let creation = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 1, conversationID: id, kind: .conversation,
      conversation: .init(id: id, title: "Linux conversation", runtimeKind: "codex"))
    let output = CompanionJournalEntry(workspaceID: workspace.id, originSequence: 2, conversationID: id, kind: .transcript,
      transcript: .init(conversationID: id, messages: [.init(id: UUID().uuidString.lowercased(), conversationID: id, role: "assistant", content: "Output while the managing Mac is offline")]))
    let page = CompanionJournalPage(libraryID: workspace.libraryID, cursor: 2, entries: [creation, output])
    try await observer.database.retainDirectPairedHistory(page, workspace: workspace)
    try await observer.database.retainDirectPairedHistory(page, workspace: workspace)
    try await observer.send(to: third)
    #expect(try await third.database.companionFederatedTranscript(conversationID: id)?.messages.first?.content == "Output while the managing Mac is offline")
    #expect(try await third.database.companionJournal(after: 0).entries.map(\.eventID) == [creation.eventID, output.eventID])
    #expect(try await observer.database.read { try $0.historyRowsUnlocked("SELECT id FROM workspace_session_deliveries", values: []).isEmpty })
  }
}
