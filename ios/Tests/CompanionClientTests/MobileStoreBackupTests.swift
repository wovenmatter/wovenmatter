import XCTest
import CryptoKit
@testable import CompanionClient
import WovenMatterCompanion

/// Serves one remote artifact; uploads are accepted in full.
private actor BackupArtifactLibrary: FederationTransport {
  var remote: CompanionArtifactManifest?, remoteData = Data()
  var uploaded: [String: Data] = [:], uploadManifests: [String: CompanionArtifactManifest] = [:]
  func publish(_ data: Data, id: String) {
    remoteData = data
    remote = .init(id: id, workspaceID: "mac", title: "From the Mac", mediaType: "text/plain", byteCount: Int64(data.count),
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), revision: 1)
  }
  func libraryIdentity() throws -> CompanionLibraryIdentity { throw MobileConnectionError.offline }
  func executionWorkspaces() -> [CompanionExecutionWorkspace] { [] }
  func registerWorkspace(_ registration: CompanionWorkspaceRegistration) throws -> CompanionExecutionWorkspace { throw MobileConnectionError.offline }
  func journal(after: Int64) throws -> CompanionJournalPage { throw MobileConnectionError.offline }
  func importJournal(_ batch: CompanionJournalBatch) throws -> CompanionJournalBatchResult { throw MobileConnectionError.offline }
  /// Central now holds other content, at a later revision, under an existing ID.
  func replace(_ id: String, revision: Int64, with data: Data) {
    remote = .init(id: id, workspaceID: "phone", title: "Replaced", mediaType: "text/plain", byteCount: Int64(data.count),
      sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), revision: revision)
  }
  func artifactManifests() -> [CompanionArtifactManifest] { remote.map { [$0] } ?? [] }
  func registerArtifact(_ registration: CompanionArtifactRegistration) -> CompanionArtifactTransfer {
    var manifest = registration.manifest; manifest.revision = 1; uploadManifests[manifest.id] = manifest
    return .init(manifest: manifest, nextOffset: Int64(uploaded[manifest.id]?.count ?? 0), complete: false)
  }
  func artifactStatus(_ id: String) throws -> CompanionArtifactTransfer { throw MobileConnectionError.offline }
  func uploadArtifactChunk(_ chunk: CompanionArtifactChunk) throws -> CompanionArtifactTransfer {
    uploaded[chunk.id, default: Data()].append(chunk.data)
    return .init(manifest: uploadManifests[chunk.id]!, nextOffset: Int64(uploaded[chunk.id]!.count), complete: false)
  }
  func commitArtifact(_ commit: CompanionArtifactCommit) throws -> CompanionArtifactManifest { uploadManifests[commit.id]! }
  func downloadArtifactChunk(_ id: String, revision: Int64, offset: Int64) throws -> CompanionArtifactChunk {
    .init(id: id, revision: revision, offset: offset, data: remoteData.subdata(in: Int(offset)..<remoteData.count))
  }
}

/// Backups must keep writing that exists only on this device and may skip
/// caches that central can provide again. A restore omits those caches.
final class MobileStoreBackupTests: XCTestCase {
  private var roots: [URL] = []
  override func tearDown() {
    MobileStorePersistence.backupFlagFailure = nil
    for root in roots { try? FileManager.default.removeItem(at: root) }; super.tearDown()
  }
  private func file() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-" + UUID().uuidString, isDirectory: true)
    roots.append(root)
    return root.appendingPathComponent("library.json")
  }
  /// Reads the flag from disk. Resource-value reads can be served from a
  /// per-process cache after another URL changed the same file.
  private func excluded(_ url: URL) throws -> Bool {
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
    return getxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", nil, 0, 0, 0) >= 0
  }
  private func body(_ content: String, in file: URL) -> URL {
    let digest = SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    return file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".bodies").appendingPathComponent(digest)
  }
  private func document(_ text: String) throws -> String { try NoteDocument(blocks: [.richText(.init(text: text))]).encoded() }
  /// What a device restored from backup receives: excluded files are absent.
  private func restore(_ file: URL) throws {
    let root = file.deletingLastPathComponent()
    for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isExcludedFromBackupKey])! {
      if try excluded(url) { try FileManager.default.removeItem(at: url) }
    }
    MobileStorePersistence.forgetAppliedBackups()
  }

  func testOfflineWritingDraftsAndPendingSendsAreBackedUp() async throws {
    let file = file(), store = try MobileStore(file: file)
    let content = try document("Unpaired writing exists only here")
    _ = try await store.createNote(folderID: nil, title: "Offline", content: content)
    try await store.saveChatDraft(key: "new-chat", draft: .init(text: "An unsent message"))
    XCTAssertFalse(try excluded(file))
    XCTAssertFalse(try excluded(body(content, in: file)))
    XCTAssertFalse(try excluded(body("An unsent message", in: file)))
    try restore(file)
    let restored = try await MobileStore(file: file).snapshot()
    XCTAssertEqual(restored.notes.values.first?.content, content)
    XCTAssertEqual(restored.chatDrafts["new-chat"]?.text, "An unsent message")
  }

  func testCentralCacheIsExcludedAndRestoreFetchesItAgainWithoutLosingEdits() async throws {
    let file = file(), store = try MobileStore(file: file)
    let cached = CompanionNote(id: "cached", title: "From the Mac", content: try document("Central copy"), revision: 3)
    let edited = CompanionNote(id: "edited", title: "Being edited", content: try document("Server version"), revision: 2)
    try await store.apply(CompanionSnapshot(workspaceID: "central", cursor: 1, notes: [cached, edited]))
    XCTAssertTrue(try excluded(body(edited.content, in: file)), "Before the edit the server version is a rebuildable cache")
    let edit = try document("Offline edit waiting to sync")
    try await store.editNote(id: edited.id, title: edited.title, content: edit, folderID: nil, base: edited)
    try await store.cache(.init(conversationID: "central-chat", messages: [.init(id: "m", conversationID: "central-chat", role: "assistant", content: "Mac reply")]))

    XCTAssertTrue(try excluded(body(cached.content, in: file)), "Unchanged central notes are a rebuildable cache")
    XCTAssertTrue(try excluded(body("Mac reply", in: file)), "Central transcripts are a rebuildable cache")
    XCTAssertFalse(try excluded(body(edit, in: file)), "Unsynced edits must survive a restore")
    XCTAssertFalse(try excluded(body(edited.content, in: file)), "The edit's base is needed to detect a conflict")
    XCTAssertFalse(try excluded(file))

    try restore(file)
    let reopened = try MobileStore(file: file)
    let state = await reopened.snapshot()
    XCTAssertEqual(state.notes["cached"]?.title, "From the Mac", "Metadata stays discoverable")
    XCTAssertEqual(state.notes["cached"]?.contentIncluded, false)
    XCTAssertTrue(state.uncachedNoteIDs.contains("cached"))
    let refetch = await reopened.notesToCache()
    XCTAssertTrue(refetch.contains("cached"))
    XCTAssertNil(state.transcripts["central-chat"], "The transcript is fetched again")
    XCTAssertEqual(state.notes["edited"]?.content, edit)
    XCTAssertTrue(state.isDirty("edited"))
    XCTAssertEqual(state.bases["edited"]?.content, edited.content)

    // Missing local writing is still corruption, never silently treated as cache.
    try FileManager.default.removeItem(at: body(edit, in: file))
    XCTAssertThrowsError(try MobileStore(file: file))
  }

  /// The platform boundary itself: excluding a just-replaced file through Foundation and
  /// including it again in the same process settles asynchronously. On disk the flag may
  /// read excluded, or briefly flip back to excluded, after setResourceValues returns.
  /// The include is never lost: within a bounded time it settles included and stays so.
  func testIncludeAfterSameProcessExclusionOfAReplacedFileSettlesWithinADeadline() async throws {
    let directory = file().deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for index in 0..<50 {
      let url = directory.appendingPathComponent("replaced-\(index).json")
      try Data("first".utf8).write(to: url)
      try MobileStorePersistence.writeDurably(Data("second".utf8), at: url, backup: .include)
      try MobileStorePersistence.applyBackup(.exclude, at: url)
      try MobileStorePersistence.applyBackup(.include, at: url)
      // Settled means included continuously for 250 ms, reached within 3 s.
      let deadline = ContinuousClock.now + .seconds(3)
      var includedSince: ContinuousClock.Instant?
      while ContinuousClock.now < deadline {
        if try excluded(url) { includedSince = nil }
        else if let since = includedSince { if since.duration(to: .now) >= .milliseconds(250) { break } }
        else { includedSince = .now }
        try await Task.sleep(for: .milliseconds(5))
      }
      let settled = includedSince.map { $0.duration(to: .now) >= .milliseconds(250) } ?? false
      XCTAssertTrue(settled, "File \(index): the include did not settle; the exclusion persisted")
      XCTAssertFalse(try excluded(url)); XCTAssertFalse(try foundationExcluded(url))
    }
  }

  func testEarlierBuildsExcludedLocalWritingIsIncludedOnLaunch() async throws {
    let file = file(), store = try MobileStore(file: file)
    let content = try document("Written before this fix")
    _ = try await store.createNote(folderID: nil, title: "Earlier build", content: content)
    let note = body(content, in: file)
    // The save just replaced the index file. An earlier build's exclusion of it was
    // set in an earlier launch, so it is already on disk; write that state directly.
    // (Excluding a just-replaced file through Foundation and including it again in the
    // same process settles asynchronously; see the deadline test above. Indexes are
    // only ever written included, so only a test creates that sequence for them.)
    try markExcludedByEarlierLaunch(file)
    // The body is written once and never replaced; cover the in-process Foundation
    // exclude → include transition on it.
    try MobileStorePersistence.applyBackup(.exclude, at: note)
    XCTAssertTrue(try excluded(file)); XCTAssertTrue(try excluded(note))
    MobileStorePersistence.forgetAppliedBackups()
    _ = try MobileStore(file: file)
    XCTAssertFalse(try excluded(file))
    XCTAssertFalse(try excluded(note))
    XCTAssertFalse(try foundationExcluded(file)); XCTAssertFalse(try foundationExcluded(note))
    try restore(file)
    let restored = try await MobileStore(file: file).snapshot()
    XCTAssertEqual(restored.notes.values.first?.content, content)
  }

  func testPhoneHistoryCalendarAndSavedFilesAreBackedUp() async throws {
    let file = file(), store = try MobileStore(file: file)
    let device = await store.snapshot().deviceID
    let transcript = CompanionTranscript(conversationID: "quick-chat", messages: [.init(id: "m", conversationID: "quick-chat", role: "user", content: "Asked on this phone")])
    try await store.adoptExecution(conversation: .init(id: "quick-chat", title: "Quick Chat"), transcript: transcript)
    XCTAssertFalse(try excluded(body("Asked on this phone", in: file)), "Phone Quick Chat history has no central copy yet")
    try await store.journal.appendNativeRecord(workspaceID: device, conversationID: "quick-chat", recordID: "r", format: "pi-durable.entry.v1", data: Data("native".utf8))
    XCTAssertFalse(try excluded(file.appendingPathExtension("execution")))
    _ = try await store.calendar.save(expectedRevision: nil, draft: .init(title: "Offline event", startsAt: Date()))
    XCTAssertFalse(try excluded(file.appendingPathExtension("calendar")))
    let saved = try await store.artifacts.save(data: Data("saved here".utf8), workspaceID: device, title: "Scan", mediaType: "text/plain")
    let artifacts = file.appendingPathExtension("artifacts")
    XCTAssertFalse(try excluded(artifacts.appendingPathComponent(saved.sha256 + ".blob")))
    XCTAssertFalse(try excluded(artifacts.appendingPathComponent("index.json")))
  }

  /// What Foundation reads, from a fresh URL with no cached resource values.
  private func foundationExcluded(_ url: URL) throws -> Bool {
    var fresh = URL(fileURLWithPath: url.path); fresh.removeAllCachedResourceValues()
    return try fresh.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
  }
  /// The backup exclusion an earlier launch completed, written directly to disk with
  /// the exact payload Foundation itself writes: a binary property list naming backupd.
  private func markExcludedByEarlierLaunch(_ url: URL) throws {
    let payload = [UInt8](try PropertyListSerialization.data(fromPropertyList: "com.apple.backupd", format: .binary, options: 0))
    XCTAssertEqual(setxattr(url.path, "com.apple.metadata:com_apple_backup_excludeItem", payload, payload.count, 0, 0), 0)
    XCTAssertTrue(try excluded(url))
    XCTAssertTrue(try foundationExcluded(url), "Foundation reads the earlier launch's exclusion")
  }
  /// Every file an earlier build wrote, excluded as that build did (files only).
  private func excludeEverything(under root: URL) throws {
    for case let url as URL in FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
      where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true && url.pathExtension != "sqlite" {
      try markExcludedByEarlierLaunch(url)
    }
    MobileStorePersistence.forgetAppliedBackups()
  }

  /// Upgrading must protect existing phone history, calendar changes and saved
  /// files as soon as they are opened, not only after their next edit.
  func testEarlierBuildsExcludedHistoryCalendarAndSavedFilesAreIncludedOnOpenWithoutEdits() async throws {
    let file = file(), root = file.deletingLastPathComponent()
    var store: MobileStore? = try MobileStore(file: file)
    let device = await store!.snapshot().deviceID
    let transcript = CompanionTranscript(conversationID: "quick-chat", messages: [.init(id: "m", conversationID: "quick-chat", role: "user", content: "Asked before upgrading")])
    try await store!.adoptExecution(conversation: .init(id: "quick-chat", title: "Quick Chat"), transcript: transcript)
    try await store!.journal.appendNativeRecord(workspaceID: device, conversationID: "quick-chat", recordID: "r", format: "pi-durable.entry.v1", data: Data("native before upgrading".utf8))
    let event = try await store!.calendar.save(expectedRevision: nil, draft: .init(title: "Offline event", startsAt: Date(timeIntervalSince1970: 1_800_000_000)))
    let saved = try await store!.artifacts.save(data: Data("scanned before upgrading".utf8), workspaceID: device, title: "Scan", mediaType: "text/plain")
    store = nil
    try excludeEverything(under: root)

    _ = try MobileStore(file: file) // Open only; no edit.
    let journalBodies = file.appendingPathExtension("execution.bodies")
    for url in [file.appendingPathExtension("execution"), file.appendingPathExtension("calendar"),
                file.appendingPathExtension("artifacts").appendingPathComponent("index.json"),
                file.appendingPathExtension("artifacts").appendingPathComponent(saved.sha256 + ".blob")]
      + (try FileManager.default.contentsOfDirectory(at: journalBodies, includingPropertiesForKeys: nil)) {
      XCTAssertFalse(try excluded(url), url.lastPathComponent)
    }

    try restore(file)
    let restored = try MobileStore(file: file)
    let journal = await restored.journal.snapshot()
    XCTAssertTrue(journal.entries.values.contains { $0.nativeRecord?.data == Data("native before upgrading".utf8) })
    let restoredState = await restored.snapshot()
    XCTAssertEqual(restoredState.transcripts["quick-chat"]?.messages.first?.content, "Asked before upgrading")
    let calendarRecord = await restored.calendar.record(id: event.id)
    XCTAssertEqual(calendarRecord?.event.draft.title, "Offline event")
    let pendingCalendar = await restored.calendar.pendingCount()
    XCTAssertEqual(pendingCalendar, 1, "The unsent calendar change still waits to upload")
    let local = await restored.artifacts.localURL(id: saved.id)
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(local)), Data("scanned before upgrading".utf8))
    let uploads = await restored.artifacts.pendingUploadCount()
    XCTAssertEqual(uploads, 1)
  }

  /// Identical bytes share one blob. Downloading a central copy of the same bytes
  /// must not exclude the source of a file saved here that has not uploaded yet.
  func testDownloadedCopyOfIdenticalBytesKeepsAPendingLocalSourceInBackups() async throws {
    let root = file().deletingLastPathComponent().appendingPathComponent("artifacts")
    let bytes = Data("the same scan on both devices".utf8)
    let store = try SavedArtifactStore(directory: root)
    let local = try await store.save(data: bytes, workspaceID: "phone", title: "Scan", mediaType: "text/plain")
    let library = BackupArtifactLibrary(); await library.publish(bytes, id: "remote-copy")
    try await store.refreshManifests(using: library)
    let downloaded = try await store.download(id: "remote-copy", using: library)
    XCTAssertEqual(downloaded.lastPathComponent, local.sha256 + ".blob", "Both records share one blob")
    XCTAssertFalse(try excluded(downloaded), "A pending local file still needs these bytes")

    try restore(root.appendingPathComponent("index.json"))
    let restored = try SavedArtifactStore(directory: root)
    let source = await restored.localURL(id: local.id)
    XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(source)), bytes)
    let pending = await restored.pendingUploadCount()
    XCTAssertEqual(pending, 1)
    let fresh = BackupArtifactLibrary()
    try await restored.synchronize(using: fresh)
    let received = await fresh.uploaded[local.id]
    XCTAssertEqual(received, bytes, "The restored queued upload sends the original bytes")

    // With no local record left needing it, the shared blob becomes a cache again.
    let onlyRemote = try SavedArtifactStore(directory: root.deletingLastPathComponent().appendingPathComponent("remote-only"))
    try await onlyRemote.refreshManifests(using: library)
    let cached = try await onlyRemote.download(id: "remote-copy", using: library)
    XCTAssertTrue(try excluded(cached))
  }

  /// A metadata failure is reported before the commit, so disk and memory agree:
  /// the previous file stays in place and the next save starts from it.
  func testBackupFlagFailureLeavesThePreviousCommittedFileAndState() async throws {
    let calendarFile = file().deletingLastPathComponent().appendingPathComponent("calendar.json")
    let calendar = try MobileCalendarStore(file: calendarFile, deviceID: "phone")
    let first = try await calendar.save(expectedRevision: nil, draft: .init(title: "Kept", startsAt: Date(timeIntervalSince1970: 1_800_000_000)))
    let before = try Data(contentsOf: calendarFile)
    MobileStorePersistence.backupFlagFailure = { url, backup in url.lastPathComponent.hasPrefix(".write-") && backup == .include }
    do { _ = try await calendar.save(expectedRevision: nil, draft: .init(title: "Not saved", startsAt: Date())); XCTFail("The failure must be reported") } catch {}
    XCTAssertEqual(try Data(contentsOf: calendarFile), before, "Nothing was committed")
    XCTAssertFalse(try excluded(calendarFile))
    let inMemory = await calendar.allRecords().map(\.id)
    XCTAssertEqual(inMemory, [first.id], "The actor did not adopt an uncommitted state")
    MobileStorePersistence.backupFlagFailure = nil
    let second = try await calendar.save(expectedRevision: nil, draft: .init(title: "Saved", startsAt: Date()))
    let reopened = try MobileCalendarStore(file: calendarFile, deviceID: "phone")
    let reopenedIDs = await reopened.allRecords().map(\.id)
    XCTAssertEqual(Set(reopenedIDs), [first.id, second.id])
  }

  /// When writing becomes a rebuildable cache it is not excluded again in place, so a
  /// failed commit leaves the old index and its body included, and so does a later one.
  func testFailedIndexCommitKeepsTheBodyThePreviousIndexNeedsInBackups() throws {
    let file = file()
    let content = try document("Local writing that later syncs")
    let note = CompanionNote(id: "note", title: "Note", content: content, revision: 2)
    var state = MobileStoreState(); state.workspaceID = "central"; state.notes[note.id] = note
    _ = try MobileStorePersistence.persist(state, at: file)
    XCTAssertFalse(try excluded(body(content, in: file)), "Unsynced writing is in backups")
    let committed = try Data(contentsOf: file)
    var synced = state; synced.bases[note.id] = note
    MobileStorePersistence.backupFlagFailure = { url, _ in url.lastPathComponent.hasPrefix(".write-") }
    XCTAssertThrowsError(try MobileStorePersistence.persist(synced, at: file))
    MobileStorePersistence.backupFlagFailure = nil
    XCTAssertEqual(try Data(contentsOf: file), committed)
    XCTAssertFalse(try excluded(body(content, in: file)), "The previous index still needs this body")
    _ = try MobileStorePersistence.persist(synced, at: file)
    XCTAssertFalse(try excluded(body(content, in: file)), "Writing once needed here is never excluded again in place")
    // A body that was only ever a cache is still written excluded.
    let cachedOnly = CompanionNote(id: "cached", title: "Cached", content: try document("Central copy only"), revision: 1)
    var withCache = synced; withCache.notes[cachedOnly.id] = cachedOnly; withCache.bases[cachedOnly.id] = cachedOnly
    _ = try MobileStorePersistence.persist(withCache, at: file)
    XCTAssertTrue(try excluded(body(cachedOnly.content, in: file)))
  }

  private struct UnsettledBackupFlag: Error {}
  /// The settled backup flag: unchanged for 250 ms, reached within 3 s. Failing to
  /// settle is itself a failure, never reported as whichever value was seen last.
  private func settledExcluded(_ url: URL) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(3)
    var value = try excluded(url), since = ContinuousClock.now
    while ContinuousClock.now < deadline {
      if since.duration(to: .now) >= .milliseconds(250) { return value }
      try await Task.sleep(for: .milliseconds(5))
      let now = try excluded(url)
      if now != value { value = now; since = .now }
    }
    XCTFail("The backup flag of \(url.lastPathComponent) did not settle within the deadline")
    throw UnsettledBackupFlag()
  }

  /// Uploaded bytes whose ID central later gives other content, then saved again here
  /// under a new ID: the reused blob path must end up in backups, as the only copy.
  func testBytesSavedAgainAfterTheirFirstUseLeftStayInBackups() async throws {
    for iteration in 0..<20 {
      let root = file().deletingLastPathComponent().appendingPathComponent("artifacts-\(iteration)")
      let store = try SavedArtifactStore(directory: root)
      let bytes = Data("locally captured scan".utf8)
      let library = BackupArtifactLibrary()
      let first = try await store.save(data: bytes, workspaceID: "phone", title: "First", mediaType: "text/plain")
      try await store.synchronize(using: library)
      await library.replace(first.id, revision: 2, with: Data("other".utf8))
      try await store.refreshManifests(using: library)
      // No record needs these bytes now, but they are not excluded again in place:
      // an in-place exclusion can land late on bytes saved again at this path.
      XCTAssertFalse(try excluded(root.appendingPathComponent(first.sha256 + ".blob")), "Iteration \(iteration): bytes once local were excluded in place")
      let second = try await store.save(data: bytes, workspaceID: "phone", title: "Second", mediaType: "text/plain")
      let blob = root.appendingPathComponent(second.sha256 + ".blob")
      let pending = await store.pendingUploadCount()
      XCTAssertEqual(pending, 1, "The new save exists only here")
      let stillExcluded = try await settledExcluded(blob)
      XCTAssertFalse(stillExcluded, "Iteration \(iteration): the only copy of saved bytes left backups")
      XCTAssertFalse(try foundationExcluded(blob))
    }
  }

  /// The earliest stores kept everything inline in one excluded file. Opening one
  /// that holds only unsent drafts includes it at once, with no edit forcing a save.
  func testEarliestInlineStoreWithOnlyDraftsIsIncludedOnOpenWithoutEdits() async throws {
    let file = file()
    var state = MobileStoreState()
    state.chatDrafts["new-chat"] = .init(text: "Unsent before upgrading")
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(state).write(to: file)
    try excludeEverything(under: file.deletingLastPathComponent())
    XCTAssertTrue(try excluded(file))

    _ = try MobileStore(file: file) // Open only; no edit.
    XCTAssertFalse(try excluded(file))
    try restore(file)
    let restored = try await MobileStore(file: file).snapshot()
    XCTAssertEqual(restored.chatDrafts["new-chat"]?.text, "Unsent before upgrading")
  }
}
