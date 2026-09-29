import Foundation
import Testing
@testable import WovenMatterDashboardStore

struct DatabasePresentationReadTests {
  @Test func timestampCodecPreservesFractionalWholeAndOffsetDatesAcrossConcurrentReaders() async throws {
    let fractional = try #require(WorkspaceDatabaseConnection.date("2026-09-28T12:34:56.123Z"))
    let whole = try #require(WorkspaceDatabaseConnection.date("2026-09-28T12:34:56Z"))
    #expect(abs(fractional.timeIntervalSince(whole) - 0.123) < 0.000_01)
    #expect(WorkspaceDatabaseConnection.date("2026-09-28T08:34:56-04:00") == whole)
    #expect(WorkspaceDatabaseConnection.date("invalid") == nil)
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask {
          #expect(WorkspaceDatabaseConnection.timestamp(fractional) == "2026-09-28T12:34:56.123Z")
          #expect(WorkspaceDatabaseConnection.date("2026-09-28T12:34:56Z") == whole)
        }
      }
    }
  }

  @MainActor @Test(.timeLimit(.minutes(1)))
  func presentationReadsLeaveMainActorAndDiscardCancelledResults() async throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    let gate = PresentationReadGate()
    let task = Task {
      try await database.read { database in
        #expect(!Thread.isMainThread)
        gate.pause()
        return try database.dashboardRevision()
      }
    }
    for await _ in gate.entered { break }
    // This MainActor continuation runs while the database read is still queued
    // on its worker; cancellation must not resume with its eventual stale value.
    task.cancel()
    gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(try await database.read { try $0.dashboardRevision() } >= 0)
  }
}

private final class PresentationReadGate: @unchecked Sendable {
  let entered: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private let semaphore = DispatchSemaphore(value: 0)
  init() {
    let stream = AsyncStream<Void>.makeStream()
    entered = stream.stream
    continuation = stream.continuation
  }
  func pause() { continuation.yield(()); semaphore.wait() }
  func release() { semaphore.signal() }
}
