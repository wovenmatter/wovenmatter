import XCTest
import WovenMatterCompanion
@testable import CompanionClient

final class MobilePairingTests: XCTestCase {
  private func file() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("store.json") }

  func testDetachAndSameDatabaseReconnectPreserveExactOutboxAndHistory() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MobileStore(file: url)
    try await store.bindWorkspace("old")
    _ = try await store.createNote(folderID: nil, title: "Local", content: "Writing")
    let before = await store.snapshot()
    try await store.detachWorkspace()
    let reopened = try MobileStore(file: url)
    let detached = await reopened.snapshot()
    XCTAssertNil(detached.workspaceID); XCTAssertEqual(detached.detachedWorkspaceID, "old")
    do { try await reopened.apply(CompanionSnapshot(workspaceID: "other", cursor: 0)); XCTFail("Sync changed the library") }
    catch MobileStore.Failure.wrongWorkspace {}
    try await reopened.prepareForPairing("old")
    let after = await reopened.snapshot()
    XCTAssertEqual(after, before)
    XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Pairing Recovery").path))
  }

  func testExplicitDatabaseChangePreservesWritingAndOnlyPublishesOwnedHistory() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MobileStore(file: url)
    try await store.bindWorkspace("old")
    let device = await store.snapshot().deviceID
    let folder = try await store.createFolder(name: "Ideas")
    let note = try await store.createNote(folderID: folder.id, title: "Local", content: "Local writing")
    try await store.journal.upsertWorkspace(.init(id: device, libraryID: "old", ownerDeviceID: device, kind: .ios, name: "Phone"))
    try await store.journal.upsertWorkspace(.init(id: "linux", libraryID: "old", ownerDeviceID: "server", kind: .linux, name: "Linux"), pending: false)
    _ = try await store.journal.append(workspaceID: device, conversation: .init(id: "local-chat", title: "Phone"),
      transcript: .init(conversationID: "local-chat", messages: [.init(id: "message", conversationID: "local-chat", role: "user", content: "Retain me")]))
    _ = try await store.journal.append(workspaceID: "linux", conversation: .init(id: "remote-chat", title: "Remote"))
    let ownEntries = await store.journal.snapshot().pendingEntries.filter { $0.workspaceID == device }
    let artifact = try await store.artifacts.save(data: Data("saved artifact".utf8), workspaceID: device, title: "Saved", mediaType: "text/plain")
    try await store.restoreExecutionProjection()
    try await store.detachWorkspace()
    try await store.prepareForPairing("new")
    let reopened = try MobileStore(file: url), state = await reopened.snapshot()
    XCTAssertEqual(state.workspaceID, "new"); XCTAssertNil(state.detachedWorkspaceID)
    XCTAssertNil(state.pairingTransitionWorkspaceID)
    XCTAssertEqual(state.notes[note.id]?.content, "Local writing")
    XCTAssertEqual(state.outbox.map(\.mutation.kind), [.createFolder, .createNote])
    XCTAssertEqual(Set(state.conversations.keys), ["local-chat"])
    XCTAssertEqual(state.transcripts["local-chat"]?.messages.first?.content, "Retain me")
    let journal = await reopened.journal.snapshot()
    XCTAssertEqual(journal.libraryID, "new")
    XCTAssertEqual(journal.pendingEntries, ownEntries)
    XCTAssertEqual(Set(journal.workspaces.keys), [device])
    XCTAssertEqual(journal.workspaces[device]?.libraryID, "new")
    let artifactURL = await reopened.artifacts.localURL(id: artifact.id)
    XCTAssertEqual(try artifactURL.map { try Data(contentsOf: $0) }, Data("saved artifact".utf8))
    let backups = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent().appendingPathComponent("Pairing Recovery"), includingPropertiesForKeys: nil)
    XCTAssertEqual(backups.count, 1)
    let original = try MobileStore(file: backups[0].appendingPathComponent("store.json"))
    let originalState = await original.snapshot()
    XCTAssertEqual(originalState.detachedWorkspaceID, "old")
    XCTAssertEqual(originalState.notes[note.id]?.content, "Local writing")
    XCTAssertNotNil(originalState.conversations["remote-chat"])
    try await reopened.prepareForPairing("new")
    let repeated = await reopened.snapshot()
    XCTAssertEqual(repeated, state)
  }

  func testCalendarMoveKeepsOwnReceiptsWithoutRunningTasksAgain() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MobileStore(file: url)
    try await store.bindWorkspace("old")
    let device = await store.snapshot().deviceID
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let event = try await store.calendar.save(expectedRevision: nil, draft: .init(title: "Event", startsAt: start))
    let task = try await store.calendar.save(expectedRevision: nil,
      draft: .init(title: "Own task", startsAt: start, task: .init(prompt: "Review")), ownerDeviceID: device)
    _ = try await store.calendar.save(expectedRevision: nil,
      draft: .init(title: "Remote task", startsAt: start, task: .init(prompt: "Review")), ownerDeviceID: "remote")
    let runs = try await store.calendar.dueRuns(deviceID: device, now: start.addingTimeInterval(60))
    for run in runs { _ = try await store.calendar.beginRun(run.id); try await store.calendar.updateRun(run.id, status: "completed") }
    try await store.prepareForPairing("new")
    let reopened = try MobileStore(file: url)
    let records = await reopened.calendar.records()
    XCTAssertEqual(Set(records.map(\.id)), [event.id, task.id])
    let due = try await reopened.calendar.dueRuns(deviceID: device, now: start.addingTimeInterval(120))
    XCTAssertTrue(due.isEmpty)
    let pending = try await reopened.calendar.nextMutation()
    XCTAssertNil(pending?.expectedRevision)
    try await reopened.calendar.verifyWorkspace("new")
  }

  @MainActor func testPendingCommitSurvivesLostConfirmationAndKeychainWriteFailure() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MobileStore(file: url)
    try await store.bindWorkspace("old")
    _ = try await store.createNote(folderID: nil, title: "Local", content: "Writing")
    let pending = MobileCredential(endpoint: URL(string: "https://fixture.test.ts.net/wovenmatter")!, workspaceID: "new",
      deviceID: await store.snapshot().deviceID, token: "synthetic-test-token", confirmationPending: true)
    var saved: MobileCredential?, confirmations = 0
    do {
      _ = try await MobilePairingCommit.complete(pending, store: store, allowingLibraryChange: true,
        saveCredential: { _ in throw MobileConnectionError.offline }, confirm: { confirmations += 1 })
      XCTFail("Keychain failure was ignored")
    } catch MobileConnectionError.offline {}
    let unchanged = await store.snapshot()
    XCTAssertEqual(unchanged.workspaceID, "old"); XCTAssertEqual(confirmations, 0)
    do {
      _ = try await MobilePairingCommit.complete(pending, store: store, allowingLibraryChange: true,
        saveCredential: { saved = $0 }, confirm: { confirmations += 1; throw MobileConnectionError.offline })
      XCTFail("Lost confirmation was ignored")
    } catch MobileConnectionError.offline {}
    XCTAssertEqual(saved, pending)
    let localCommit = await store.snapshot()
    XCTAssertEqual(localCommit.workspaceID, "new")
    let restarted = try MobileStore(file: url)
    let committed = try await MobilePairingCommit.complete(try XCTUnwrap(saved), store: restarted, allowingLibraryChange: true,
      saveCredential: { saved = $0 }, confirm: { confirmations += 1 })
    XCTAssertNil(committed.confirmationPending); XCTAssertEqual(saved, committed)
    XCTAssertEqual(confirmations, 2)
    let final = await restarted.snapshot()
    XCTAssertEqual(final, localCommit, "A confirmation retry must not duplicate local mutations")
  }

  func testInterruptedCrossStoreTransitionResumesBeforeSync() async throws {
    let url = file(); defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try MobileStore(file: url)
    try await store.bindWorkspace("old")
    let note = try await store.createNote(folderID: nil, title: "Local", content: "Writing")
    let device = await store.snapshot().deviceID
    try await store.journal.upsertWorkspace(.init(id: device, libraryID: "old", ownerDeviceID: device, kind: .ios, name: "Phone"))
    // Simulate interruption after the journal committed and before the main index.
    try await store.journal.moveDeviceWorkspace(to: "new", deviceID: device)
    var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    var index = try XCTUnwrap(document["state"] as? [String: Any])
    index["pairingTransitionWorkspaceID"] = "new"
    document["state"] = index
    try JSONSerialization.data(withJSONObject: document).write(to: url, options: .atomic)
    let restarted = try MobileStore(file: url)
    do { try await restarted.verifyWorkspace("old"); XCTFail("An incomplete transition allowed sync") }
    catch MobileStore.Failure.wrongWorkspace {}
    try await restarted.recoverPairingTransition()
    let final = await restarted.snapshot()
    XCTAssertEqual(final.workspaceID, "new"); XCTAssertNil(final.pairingTransitionWorkspaceID)
    XCTAssertEqual(final.notes[note.id]?.content, "Writing")
    XCTAssertEqual(final.outbox.count, 1)
  }
}
