import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPAssistantStreamWriterTests {
  @Test func decisionQueuedDuringBoundaryPersistenceDoesNotWaitForResume() async throws {
    let acquired = AsyncStream<Void>.makeStream()
    let queued = AsyncStream<Void>.makeStream()
    let fixture = try await WriterFixture(onPersistenceEvent: { event in
      switch event {
      case .acquired: acquired.continuation.yield(())
      case .queued: queued.continuation.yield(())
      }
    })
    defer { fixture.remove() }
    let entered = AsyncStream<Void>.makeStream()
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }
    let blocked = Task { try await fixture.database.write { _ in
      entered.continuation.yield(())
      #expect(release.wait(timeout: .now() + 60) == .success)
    } }
    var iterator = entered.stream.makeAsyncIterator()
    await iterator.next()
    let boundary = Task { try await fixture.writer.finishSegmentAndPause() }
    #expect(await receiveWriterSignal(acquired.stream))
    let completed = AsyncStream<Void>.makeStream()
    let decision = Task {
      try await fixture.writer.finishSegmentForDecision()
      completed.continuation.yield(())
    }
    // Prove the decision is queued behind the boundary before releasing SQLite;
    // no scheduler delay or polling interval is used to establish this ordering.
    #expect(await receiveWriterSignal(queued.stream))
    release.signal()
    try await blocked.value
    try await boundary.value
    let finishedBeforeResume = await receiveWriterSignal(completed.stream)
    // Always release a regressed waiter, so a failure does not hang the suite.
    await fixture.writer.resumeAfterSegmentBoundary()
    try await decision.value
    #expect(finishedBeforeResume)
  }

  @Test func boundariesAndSnapshotPreserveCanonicalSteeringPrefix() async throws {
    let fixture = try await WriterFixture()
    defer { fixture.remove() }
    let writer = fixture.writer

    try await writer.append("First  \n")
    try await writer.finishSegment()
    try await writer.finishSegment() // Empty/repeated boundaries are no-ops.
    try await writer.finishSegmentAndPause()
    let steering = try await fixture.database.beginLocalACPSteeringTurn(
      runID: fixture.run.runID, content: "Continue"
    )
    await writer.resumeAfterSegmentBoundary(assistantMessageID: steering.assistantMessageID)
    try await writer.append("draft")
    try await writer.replace("First  \nFinal  \n")
    try await writer.finish()

    await #expect(try fixture.assistantText() == ["First  \n", "Final  \n"])
    let assistantActivities = try await fixture.database.conversationHistoryPage(id: fixture.conversationID, limit: 20).activities
      .filter { $0.runID == fixture.run.runID }
      .filter { $0.activity.kind == .assistant }
    #expect(assistantActivities.count == 1)
    #expect(assistantActivities[0].activity.content == "First  \n")
  }

  @Test func lateReasoningDeltaDoesNotSplitAnswerPrefix() async throws {
    let fixture = try await WriterFixture()
    defer { fixture.remove() }
    let thought = AgentRunActivity(id: "built-in-1-0", kind: .thought, phase: "update", title: "Thinking", status: "running", content: "Reasoning")
    try await fixture.writer.finishSegment(for: thought)
    try await fixture.writer.append("T")
    try await fixture.writer.finishSegment(for: thought)
    try await fixture.writer.append("iananmen Square")
    try await fixture.writer.finish()
    await #expect(try fixture.assistantText() == ["Tiananmen Square"])
    let activities = try await fixture.database.conversationHistoryPage(id: fixture.conversationID, limit: 20).activities
    #expect(!activities.contains { $0.activity.kind == .assistant })
  }

  @Test func finishFlushesFailureTailAndIsIdempotent() async throws {
    let fixture = try await WriterFixture()
    defer { fixture.remove() }
    try await fixture.writer.append("tail with space ")
    try await fixture.writer.finish()
    try await fixture.writer.finish()
    try await fixture.database.completeLocalACPRun(runID: fixture.run.runID, error: "fixture")
    await #expect(try fixture.assistantText() == ["tail with space "])
    try await fixture.writer.append("ignored")
    await #expect(try fixture.assistantText() == ["tail with space "])
  }
}

private func receiveWriterSignal(_ stream: AsyncStream<Void>) async -> Bool {
  await withTaskGroup(of: Bool.self) { group in
    group.addTask {
      var iterator = stream.makeAsyncIterator()
      return await iterator.next() != nil
    }
    group.addTask {
      try? await Task.sleep(for: .seconds(10))
      return false
    }
    let received = await group.next() ?? false
    group.cancelAll()
    return received
  }
}

private struct WriterFixture {
  let root: URL
  let database: WorkspaceDatabase
  let conversationID: String
  let run: LocalACPRunIdentifiers
  let writer: LocalACPAssistantStreamWriter

  init(onPersistenceEvent: (@Sendable (LocalACPAssistantStreamWriter.PersistenceEvent) -> Void)? = nil) async throws {
    root = FileManager.default.temporaryDirectory.appending(path: "acp-writer-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    conversationID = try await database.createLocalACPSession(
      runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID()
    )
    run = try await database.beginLocalACPRun(conversationID: conversationID, content: "Start")
    writer = LocalACPAssistantStreamWriter(
      database: database, runID: run.runID, assistantMessageID: run.assistantMessageID,
      conversationID: conversationID, onChange: nil, onPersistenceEvent: onPersistenceEvent
    )
  }

  func assistantText() async throws -> [String] {
    try await database.conversationContent(id: conversationID).messages
      .filter { $0.role == "assistant" }.map(\.content)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
