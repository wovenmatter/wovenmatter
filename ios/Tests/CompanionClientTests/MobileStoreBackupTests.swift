import XCTest
import CryptoKit
@testable import CompanionClient
import WovenMatterCompanion

/// Backups must keep writing that exists only on this device and may skip
/// caches that central can provide again. A restore omits those caches.
final class MobileStoreBackupTests: XCTestCase {
  private var roots: [URL] = []
  override func tearDown() { for root in roots { try? FileManager.default.removeItem(at: root) }; super.tearDown() }
  private func file() -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("backup-" + UUID().uuidString, isDirectory: true)
    roots.append(root)
    return root.appendingPathComponent("library.json")
  }
  private func excluded(_ url: URL) throws -> Bool {
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), url.lastPathComponent)
    return try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup ?? false
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
      if try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true { try FileManager.default.removeItem(at: url) }
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
    let cached = CompanionNote(id: "cached", title: "From the Mac", content: try document("Central copy"), revision: 3, workspaceID: "mac")
    let edited = CompanionNote(id: "edited", title: "Being edited", content: try document("Server version"), revision: 2, workspaceID: "mac")
    try await store.apply(CompanionSnapshot(workspaceID: "central", cursor: 1, notes: [cached, edited]))
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

  func testEarlierBuildsExcludedLocalWritingIsIncludedOnLaunch() async throws {
    let file = file(), store = try MobileStore(file: file)
    let content = try document("Written before this fix")
    _ = try await store.createNote(folderID: nil, title: "Earlier build", content: content)
    for url in [file, body(content, in: file)] { try MobileStorePersistence.applyBackup(.exclude, at: url) }
    MobileStorePersistence.forgetAppliedBackups()
    _ = try MobileStore(file: file)
    XCTAssertFalse(try excluded(file))
    XCTAssertFalse(try excluded(body(content, in: file)))
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
}
