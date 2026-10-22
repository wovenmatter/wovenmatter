import Foundation
import Testing
import WovenMatterCompanion
@testable import CompanionClient

struct MobileDictationStoreTests {
  @Test func offlineHistorySurvivesRestartAndLostAcknowledgement() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appending(path: "history.sqlite")
    let store = try MobileDictationStore(file: file)
    let local = DictationRecord(text: "Offline 🪡\nFull text")
    try await store.save(local); try await store.save(local)
    let reopened = try MobileDictationStore(file: file)
    #expect(try await reopened.records() == [local])
    #expect(try await reopened.pending() == [local])
    try await reopened.bindWorkspace("central")
    try await reopened.apply(.init(workspaceID: "central", cursor: 1, records: [local], hasMore: false), after: 0)
    #expect(try await reopened.pending() == [local], "Downloaded replay does not discard an unacknowledged upload")
    try await reopened.acknowledge(local, workspaceID: "central")
    #expect(try await reopened.pendingCount() == 0)
    #expect(try await reopened.cursor() == 1)
    #expect(try await reopened.records() == [local])
    await #expect(throws: DictationHistoryError.self) { try await reopened.bindWorkspace("other") }
    let backup = directory.appending(path: "backup.sqlite")
    try await reopened.backup(to: backup)
    try await reopened.moveLocalWriting(to: "other")
    #expect(try await reopened.cursor() == 0)
    #expect(try await reopened.pending() == [local])
    await #expect(throws: DictationHistoryError.self) { try await reopened.acknowledge(local, workspaceID: "central") }
    await #expect(throws: DictationHistoryError.self) { _ = try await reopened.pending(workspaceID: "central") }
    try await reopened.acknowledge(local, workspaceID: "other")
    try await reopened.moveLocalWriting(to: "other")
    #expect(try await reopened.pendingCount() == 0, "Recovery of the same pairing transition is idempotent")
    let restored = try MobileDictationStore(file: backup)
    #expect(try await restored.records() == [local])
    #expect(try await restored.cursor() == 1)
    var forged = local; forged.text = "Other content"
    await #expect(throws: DictationHistoryError.self) { try await reopened.save(forged) }
  }
  @Test func invalidSyncPageRollsBackRecordsAndCursor() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try MobileDictationStore(file: directory.appending(path: "history.sqlite"))
    try await store.bindWorkspace("central")
    let valid = DictationRecord(text: "Keep transaction atomic")
    let invalid = DictationRecord(id: "invalid", text: "Invalid identity")
    await #expect(throws: DictationHistoryError.self) {
      try await store.apply(.init(workspaceID: "central", cursor: 2, records: [valid, invalid], hasMore: false), after: 0)
    }
    #expect(try await store.records().isEmpty)
    #expect(try await store.cursor() == 0)
    await #expect(throws: DictationHistoryError.self) {
      try await store.apply(.init(workspaceID: "other", cursor: 1, records: [valid], hasMore: false), after: 0)
    }
  }
}
