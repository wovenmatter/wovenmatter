import WorkspaceFixtures
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
      return try connection.createFolder(name: "Committed", location: .init(workspaceID: "device:test", rootPath: "/tmp", managed: false))
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
    let id = try await database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Stream", ownerDeviceID: owner)
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

}
