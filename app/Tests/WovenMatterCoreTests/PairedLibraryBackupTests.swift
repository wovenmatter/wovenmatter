import Foundation
import Testing
import WovenMatterClient
import WorkspaceFixtures
import WovenMatterCore
@testable import WovenMatterLibraryStore

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
    let refusal = await #expect(throws: LibraryAPIError.self) { try await database.receivePairedLibrary(page, from: peerID) }
    #expect(refusal?.code == "peer_unavailable")
    #expect(try await database.libraryNote(id: note) == nil)
    #expect(try await database.peerImportsReady())
    try await database.receivePairedLibrary(page, from: peerID)
    #expect(try await database.libraryNote(id: note)?.title == "From the other Mac")
    // Another handle on the same file shares the finished backup.
    let reopened = try await WorkspaceDatabase(url: fixture.databaseURL)
    reopened.prepareForPeerSync()
    #expect(reopened.acceptsPeerImports)
  }

  /// A copy that fails keeps failing for the same reason (usually too little
  /// free space for a second copy of the library), so it is retried after one
  /// minute, then two, never on every health check or incoming page.
  @Test func aFailedBackupIsRetriedOnlyAfterABackoff() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let clock = TestClock()
    let fence = PeerBackupFence(file: fixture.directory.appending(path: "Paired Mac Backups/before-peer-sync.sqlite"), now: clock.now)
    let attempts = AttemptCounter()
    let failing: @Sendable () throws -> Void = { attempts.add(); throw BackupFailure() }
    await #expect(throws: BackupFailure.self) { _ = try await fence.wait(timeout: nil, failing) }
    #expect(attempts.value == 1)
    #expect(!fence.isOpen, "A failed backup keeps imports fenced")
    // Within the delay every caller gets the last error at once.
    for _ in 0..<5 { fence.start(failing) }
    await #expect(throws: BackupFailure.self) { _ = try await fence.wait(timeout: 5, failing) }
    #expect(attempts.value == 1)
    clock.advance(61)
    await #expect(throws: BackupFailure.self) { _ = try await fence.wait(timeout: nil, failing) }
    #expect(attempts.value == 2)
    // The delay doubles.
    clock.advance(61)
    fence.start(failing)
    #expect(attempts.value == 2)
    clock.advance(60)
    let file = fence.file
    #expect(try await fence.wait(timeout: nil) { attempts.add(); FileManager.default.createFile(atPath: file.path, contents: Data()) })
    #expect(attempts.value == 3)
    #expect(fence.isOpen)
    #expect(!FileManager.default.fileExists(atPath: fence.marker.path))
  }

  /// A waiter with a timeout gives up while the copy runs, a cancelled waiter
  /// ends, and both leave the copy running for the next waiter.
  @Test func waitersTimeOutAndCancelWithoutEndingTheBackup() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let fence = PeerBackupFence(file: fixture.directory.appending(path: "Paired Mac Backups/before-peer-sync.sqlite"))
    let gate = DispatchSemaphore(value: 0), file = fence.file
    let backup: @Sendable () throws -> Void = { gate.wait(); FileManager.default.createFile(atPath: file.path, contents: Data()) }
    #expect(try await fence.wait(timeout: 0.05, backup) == false)
    let cancelled = Task { try await fence.wait(timeout: nil, backup) }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
    #expect(!fence.isOpen)
    let waiting = Task { try await fence.wait(timeout: nil, backup) }
    gate.signal()
    #expect(try await waiting.value)
    #expect(fence.isOpen)
  }

  /// Arming survives a quit or crash mid-copy: the next launch's fence keeps
  /// imports out until its own copy finishes, even before anything restarts it.
  @Test func anInterruptedBackupStillFencesImportsAfterRelaunch() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let file = fixture.directory.appending(path: "Paired Mac Backups/before-peer-sync.sqlite")
    let interrupted = PeerBackupFence(file: file)
    let gate = DispatchSemaphore(value: 0)
    interrupted.start { gate.wait() }
    #expect(FileManager.default.fileExists(atPath: interrupted.marker.path))
    let relaunched = PeerBackupFence(file: file)
    #expect(!relaunched.isOpen)
    #expect(try await relaunched.wait(timeout: nil) { FileManager.default.createFile(atPath: file.path, contents: Data()) })
    #expect(relaunched.isOpen)
    #expect(!FileManager.default.fileExists(atPath: relaunched.marker.path))
    gate.signal()
  }

  /// A partial copy left by an interrupted backup is as large as the library;
  /// the next copy removes it.
  @Test func theNextBackupClearsAnInterruptedPartialCopy() async throws {
    let fixture = try PersistenceFixture(); defer { fixture.remove() }
    let database = try await fixture.openDatabase()
    let file = fixture.directory.appending(path: "Paired Mac Backups/before-peer-sync.sqlite")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    for suffix in ["", "-journal"] {
      FileManager.default.createFile(atPath: file.path + ".partial" + suffix, contents: Data(repeating: 7, count: 4096))
    }
    try await database.backUpBeforePeerSync()
    #expect(FileManager.default.fileExists(atPath: file.path))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path)
      .filter { $0.contains(".partial") }
    #expect(leftovers.isEmpty)
    let copy = try await WorkspaceDatabase(url: file, readOnlyProjection: true)
    #expect(try await copy.libraryIdentity().libraryID == database.libraryIdentity().libraryID)
  }
}

private struct BackupFailure: Error {}

private final class TestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSinceReferenceDate: 0)
  var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }
  func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private final class AttemptCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0
  var value: Int { lock.withLock { count } }
  func add() { lock.withLock { count += 1 } }
}
