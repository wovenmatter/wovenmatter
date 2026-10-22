import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Async internal database workers", .serialized)
struct AsyncDatabaseWorkerTests {

  @Test func startedWriteReportsCommitEvenAfterCallerCancels() async throws {
    let (database, root, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let task = Task { try await database.write { connection in
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 60) == .success)
      return try connection.createFolder(name: "Committed")
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    task.cancel()
    release.signal()
    let id = try await task.value
    #expect(try await database.workspaceOverview().folders.contains { $0.id == id })
  }

  @Test func streamFlushDoesNotLoseChunksAcrossDatabaseSuspension() async throws {
    let (database, root, owner) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try await database.createLocalACPSession(runtimeKind: .codex, title: "Stream", ownerDeviceID: owner)
    let run = try await database.beginLocalACPRun(conversationID: id, content: "Start")
    let stream = LocalACPAssistantStreamWriter(database: database, runID: run.runID,
      assistantMessageID: run.assistantMessageID, conversationID: id, onChange: nil)
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocked = Task { try await database.write { _ in
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 60) == .success)
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    let prefix = String(repeating: "A", count: 4096)
    let first = Task { try await stream.append(prefix) }
    try await waitUntil { database.workerMetrics[0].pending == 2 }
    let second = Task { try await stream.append("B"); try await stream.finish() }
    release.signal()
    try await blocked.value
    try await first.value
    try await second.value
    #expect(try await database.conversationContent(id: id).messages.last?.content == prefix + "B")
  }

  private func fixture() async throws -> (WorkspaceDatabase, URL, UUID) {
    let root = FileManager.default.temporaryDirectory.appending(path: "wm-async-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    let owner = UUID()
    try await database.bindDeviceOwnership(ownerDeviceID: owner)
    return (database, root, owner)
  }

  private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(60)
    while !condition() {
      guard ContinuousClock.now < deadline else { throw DatabaseWorkerError.timedOut }
      try await Task.sleep(for: .milliseconds(1))
    }
  }

  @Test func fiftySessionsPersistWhileSnapshotsAndMainActorRemainResponsive() async throws {
    let (database, root, owner) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let start = ContinuousClock.now
    let ids = try await withThrowingTaskGroup(of: String.self) { group in
      for index in 0..<50 {
        group.addTask {
          let id = try await database.createLocalACPSession(runtimeKind: .codex,
            title: "Concurrent \(index)", ownerDeviceID: owner)
          let run = try await database.beginLocalACPRun(conversationID: id, content: "Fixture prompt")
          for chunk in 0..<10 {
            try await database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "\(chunk),")
          }
          try await database.completeLocalACPRun(runID: run.runID)
          return id
        }
      }
      group.addTask {
        for _ in 0..<30 {
          _ = try await database.workspaceOverview()
          await MainActor.run { #expect(!Task.isCancelled) }
        }
        return "reader"
      }
      var ids: [String] = []
      for try await id in group where id != "reader" { ids.append(id) }
      return ids
    }
    #expect(ids.count == 50)
    for id in ids {
      let content = try await database.conversationContent(id: id)
      // This fixture verifies persistence, not timestamp/UUID ordering when
      // the prompt and reply happen to share the same timestamp.
      #expect(content.messages.filter { $0.role == "assistant" }.map(\.content)
              == ["0,1,2,3,4,5,6,7,8,9,"])
    }
    let reopened = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"), readOnlyProjection: true)
    #expect(try await reopened.workspaceOverview().conversations.count == 50)
    #expect(try await database.activeDeviceOwnedConversationIDs().isEmpty)
    #expect(database.workerMetrics.allSatisfy { $0.rejected == 0 })
    print("Async database fixture: 50 sessions, 500 chunks, 30 snapshots; elapsed \(start.duration(to: .now)); worker metrics \(database.workerMetrics)")
  }

  @Test func cancelledQueuedWriteNeverRunsAndCapacityIsBounded() async throws {
    let worker = DatabaseWorker(label: "wm.test.bounded", capacity: 2)
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let first = Task { try await worker.perform { _ in
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 60) == .success)
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    let queued = Task { try await worker.perform { _ in Issue.record("Cancelled job executed") } }
    try await waitUntil { worker.metrics.pending == 2 }
    await #expect(throws: DatabaseWorkerError.atCapacity) { try await worker.perform { _ in 1 } }
    queued.cancel()
    await #expect(throws: CancellationError.self) { try await queued.value }
    #expect(worker.metrics.pending == 1)
    #expect(worker.metrics.highWaterMark == 2)
    release.signal()
    try await first.value
  }

  @Test func failedTransactionRollsBackAsOneWorkerOperation() async throws {
    let (database, root, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    try await database.write { try $0.executeUnlocked("CREATE TABLE async_transaction_probe(value TEXT)") }
    await #expect(throws: (any Error).self) {
      try await database.write { connection in
        try connection.transaction {
          try connection.executeUnlocked("INSERT INTO async_transaction_probe VALUES('rolled back')")
          try connection.executeUnlocked("INSERT INTO table_that_does_not_exist VALUES(1)")
        }
      }
    }
    let rows = try await database.read { try $0.historyRowsUnlocked("SELECT count(*) AS n FROM async_transaction_probe", values: []) }
    #expect(rows.first?.objectValue?["n"]?.intValue == 0)
  }

  @Test func cancelledDriverStillRecordsConfirmedSubmissionAndDelivery() async throws {
    let (database, root, owner) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let source = try await database.createLocalACPSession(runtimeKind: .codex, title: "Source", ownerDeviceID: owner)
    let target = try await database.createLocalACPSession(runtimeKind: .opencode, title: "Target", ownerDeviceID: owner,
      openCodeAssociation: ("fixture", "session"))
    let delivery = try await database.reserveToolDelivery(sourceID: source, targetID: target, text: "Hello", requestID: UUID().uuidString)
    _ = try await database.claimToolDelivery(id: delivery.id)
    try await database.saveOpenCodeSubmission(conversationID: target, id: "input", payload: [:], status: "sending")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await database.saveOpenCodeSubmission(conversationID: target, id: "input", payload: [:], status: "accepted")
      try await database.setToolDeliveryStatus(id: delivery.id, status: "accepted")
    }
    try await task.value
    #expect(try await database.openCodeUncertainSubmissions(conversationID: target).isEmpty)
    #expect(try await database.toolDelivery(id: delivery.id)?.status == "accepted")
  }

}
