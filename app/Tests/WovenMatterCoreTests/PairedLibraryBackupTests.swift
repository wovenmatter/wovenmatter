import Foundation
import Testing
import WovenMatterClient
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterDashboardStore

/// The recovery backup taken before a library's first peer import. A real
/// library of several gigabytes takes minutes to copy and verify; it once ran
/// as one job on the writer lane, so pairing waited for it and every other
/// database job queued behind it failed with "The workspace database
/// operation timed out."
@Suite("Recovery backup before the first peer import", .serialized)
struct PairedLibraryBackupTests {
  /// About 128 MB: enough that copying and checking it outlasts a small write
  /// many times over, on any machine.
  private static func largeLibrary() async throws -> (PersistenceFixture, WorkspaceDatabase) {
    let fixture = try PersistenceFixture()
    let database = try await fixture.openDatabase()
    try await database.write { try $0.executeUnlocked("""
      CREATE TABLE test_padding(bytes BLOB);
      WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i+1 FROM n WHERE i<128)
      INSERT INTO test_padding SELECT randomblob(1048576) FROM n;
      """) }
    return (fixture, database)
  }

  private static func backupStarted(_ directory: URL) async throws -> Bool {
    let backups = directory.appending(path: "Paired Mac Backups")
    return try await pollUntil(attempts: 10_000, interval: .milliseconds(1)) {
      ((try? FileManager.default.contentsOfDirectory(atPath: backups.path)) ?? []).contains { $0.hasSuffix(".partial") }
    }
  }

  @Test func otherDatabaseWorkNeverWaitsForTheBackup() async throws {
    let (fixture, database) = try await Self.largeLibrary(); defer { fixture.remove() }
    let file = fixture.directory.appending(path: "Paired Mac Backups/before-peer-sync.sqlite")
    let backup = Task { try await database.backUpBeforePeerSync() }
    #expect(try await Self.backupStarted(fixture.directory))
    let route = PairedMacRoute(deviceID: UUID().uuidString, libraryID: UUID().uuidString,
      endpoint: URL(string: "https://mini.example.ts.net:8443/wovenmatter")!, name: "Mini")
    try await database.savePairedMacRoute(route)
    #expect(try await database.pairedMacRoutes().contains(route))
    // A write and a read both finished while the backup was still running.
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try await backup.value
    #expect(FileManager.default.fileExists(atPath: file.path))
    let copy = try await WorkspaceDatabase(url: file, readOnlyProjection: true)
    #expect(try await copy.libraryIdentity().libraryID == database.libraryIdentity().libraryID)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
      .filter { $0.contains(".partial") }
    #expect(leftovers.isEmpty)
  }

  @Test func pairingStartsTheBackupAndOnlyPeerImportsWaitForIt() async throws {
    let source = try PersistenceFixture(); defer { source.remove() }
    let peer = try await source.openDatabase()
    let peerID = try await peer.libraryIdentity().hostDeviceID
    let content = try NoteDocument(blocks: [.richText(.init(text: "From the other Mac"))]).encoded()
    let note = UUID().uuidString.lowercased()
    _ = try await peer.applyLibraryMutation(.init(deviceID: peerID, kind: .createNote, resourceID: note,
      title: "From the other Mac", content: content))
    let page = try await peer.pairedLibraryPage(after: 0)

    let (fixture, database) = try await Self.largeLibrary(); defer { fixture.remove() }
    // A library that never paired a Mac (a Linux host) imports without one.
    #expect(database.acceptsPeerImports)
    database.prepareForPeerSync()
    #expect(try await Self.backupStarted(fixture.directory))
    #expect(!database.acceptsPeerImports)
    await #expect(throws: LibraryAPIError.self) { try await database.receivePairedLibrary(page, from: peerID) }
    #expect(try await database.libraryNote(id: note) == nil)
    #expect(try await database.peerImportsReady())
    try await database.receivePairedLibrary(page, from: peerID)
    #expect(try await database.libraryNote(id: note)?.title == "From the other Mac")
    // Another handle on the same file shares the finished backup.
    let reopened = try await WorkspaceDatabase(url: fixture.databaseURL)
    reopened.prepareForPeerSync()
    #expect(reopened.acceptsPeerImports)
  }
}
