import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Async internal database workers", .serialized)
struct AsyncDatabaseWorkerTests {
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

  @Test func connectionClosesOnlyOnItsWorkerAfterCallerReleasesIt() async throws {
    final class Probe {
      let queue: DispatchQueue
      let closed: AsyncStream<Void>.Continuation
      init(queue: DispatchQueue, closed: AsyncStream<Void>.Continuation) {
        self.queue = queue; self.closed = closed
      }
      deinit {
        dispatchPrecondition(condition: .onQueue(queue))
        closed.yield(())
      }
    }
    let worker = DatabaseWorker(label: "wm.test.connection-lifetime")
    let closed = AsyncStream<Void>.makeStream()
    for _ in 0..<500 {
      let box = try await worker.perform { _ in
        DatabaseConnectionBox(worker: worker, connection: Probe(queue: worker.queue, closed: closed.continuation))
      }
      withExtendedLifetime(box) {}
    }
    var iterator = closed.stream.makeAsyncIterator()
    for _ in 0..<500 { await iterator.next() }
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

  @Test func blockedWriterDoesNotBlockReadersOrMainActor() async throws {
    let (database, root, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocked = Task {
      try await database.write { connection in
        try connection.transaction {
          entered.continuation.yield(())
          #expect(release.wait(timeout: .now() + 60) == .success)
        }
      }
    }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    _ = try await database.workspaceOverview()
    await MainActor.run { #expect(Thread.isMainThread) }
    // Verify progress while the writer is still held, without depending on
    // wall-clock scheduling when other suites share a small CI runner.
    #expect(database.workerMetrics[0].pending == 1)
    release.signal()
    try await blocked.value
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

  @Test func expiredQueuedJobIsRemovedWithoutWaitingForTheWriter() async throws {
    let worker = DatabaseWorker(label: "wm.test.deadline")
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let first = Task { try await worker.perform { _ in
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 60) == .success)
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    await #expect(throws: DatabaseWorkerError.timedOut) {
      try await worker.perform(timeout: 0.01) { _ in Issue.record("Expired job executed") }
    }
    #expect(worker.metrics.pending == 1)
    release.signal()
    try await first.value
  }

  @Test func expensiveReadTimesOutAndConnectionRemainsUsable() async throws {
    let (database, root, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    await #expect(throws: DatabaseWorkerError.timedOut) {
      try await database.read(timeout: 0.01) { connection in
        try connection.historyRowsUnlocked("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n", values: [])
      }
    }
    _ = try await database.workspaceOverview()
    await #expect(throws: (any Error).self) {
      try await database.read { try $0.executeUnlocked("DELETE FROM dashboard_conversations") }
    }
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

  @Test func multipleQueriesKeepOneSnapshotAcrossConcurrentCommit() async throws {
    let (database, root, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let snapshot = Task { try await database.read { connection in
      let before = try connection.workspaceOverview().folders.count
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 60) == .success)
      return (before, try connection.workspaceOverview().folders.count)
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    _ = try await database.createFolder(name: "Committed while reader was active")
    release.signal()
    let counts = try await snapshot.value
    #expect(counts.0 == counts.1)
    #expect(try await database.workspaceOverview().folders.count == counts.0 + 1)
  }

  @Test func policySnapshotDoesNotLoadUnobservedReceiptPages() async throws {
    let (database, root, owner) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try await database.createLocalACPSession(runtimeKind: .codex, title: "Policy", ownerDeviceID: owner)
    let snapshot = try await database.toolStateSnapshot(sessionIDs: [id], oldestReceipts: [:], receiptSessionIDs: [])
    #expect(snapshot.policies[id] != nil)
    #expect(snapshot.receipts.isEmpty)
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

  @Test func usageAndWorkspaceShareTheWriterButHaveIndependentReaders() async throws {
    let (database, root, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let usage = try await AsyncUsageStore(databaseURL: root.appending(path: "workspace.sqlite"))
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocked = Task { try await database.write { _ in
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 60) == .success)
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    let date = Date(timeIntervalSince1970: 1234)
    let update = Task { try await usage.setMetadataDate(date, for: "async-fixture") }
    try await waitUntil { database.workerMetrics[0].pending == 2 }
    #expect(try await usage.metadataDate("async-fixture") == nil)
    release.signal()
    try await blocked.value
    try await update.value
    #expect(try await usage.metadataDate("async-fixture") == date)
  }

  @Test func concurrentToolTogglesDoNotOverwriteEachOther() async throws {
    let (database, root, owner) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try await database.createLocalACPSession(runtimeKind: .codex, title: "Tools", ownerDeviceID: owner)
    try await database.setSessionTools(.init(enabled: []), sessionID: id)
    async let first = database.setSessionToolEnabled(.calendar, enabled: true, sessionID: id)
    async let second = database.setSessionToolEnabled(.timers, enabled: true, sessionID: id)
    _ = try await (first, second)
    #expect(try await database.sessionTools(id).enabled == [.calendar, .timers])
  }

  @Test func cancelledRunStillFlushesItsTailAndPersistsTerminalState() async throws {
    let (database, root, owner) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = try await database.createLocalACPSession(runtimeKind: .codex, title: "Cancel", ownerDeviceID: owner)
    let run = try await database.beginLocalACPRun(conversationID: id, content: "Start")
    let stream = LocalACPAssistantStreamWriter(database: database, runID: run.runID,
      assistantMessageID: run.assistantMessageID, conversationID: id, onChange: nil)
    try await stream.append("Unflushed tail")
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      try await stream.finish()
      try await database.cancelLocalACPRun(runID: run.runID)
    }
    try await task.value
    #expect(try await database.conversationContent(id: id).messages.last?.content == "Unflushed tail")
    #expect(try await database.activeDeviceOwnedConversationIDs().isEmpty)
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

  @Test func cancellingExecutingReadInterruptsSQLite() async throws {
    let (database, root, _) = try await fixture()
    defer { try? FileManager.default.removeItem(at: root) }
    let entered = AsyncStream<Void>.makeStream()
    let query = Task { try await database.read { connection in
      entered.continuation.yield(())
      return try connection.historyRowsUnlocked("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT sum(x) FROM n", values: [])
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    query.cancel()
    await #expect(throws: CancellationError.self) { try await query.value }
    _ = try await database.workspaceOverview()
  }
}
