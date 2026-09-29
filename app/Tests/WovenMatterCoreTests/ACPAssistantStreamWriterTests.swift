import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

struct ACPAssistantStreamWriterTests {
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

private struct WriterFixture {
  let root: URL
  let database: WorkspaceDatabase
  let conversationID: String
  let run: LocalACPRunIdentifiers
  let writer: LocalACPAssistantStreamWriter

  init() async throws {
    root = FileManager.default.temporaryDirectory.appending(path: "acp-writer-\(UUID())")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    database = try await WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
    conversationID = try await database.createLocalACPSession(
      runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID()
    )
    run = try await database.beginLocalACPRun(conversationID: conversationID, content: "Start")
    writer = LocalACPAssistantStreamWriter(
      database: database, runID: run.runID, assistantMessageID: run.assistantMessageID,
      conversationID: conversationID, onChange: nil
    )
  }

  func assistantText() async throws -> [String] {
    try await database.conversationContent(id: conversationID).messages
      .filter { $0.role == "assistant" }.map(\.content)
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}
