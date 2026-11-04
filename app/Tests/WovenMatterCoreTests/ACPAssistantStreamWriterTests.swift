import WorkspaceFixtures
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
    let steering = try await fixture.database.reserveLocalACPSteeringTurn(
      runID: fixture.run.runID, input: .init(text: "Continue")
    ).identifiers
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

}

private struct WriterFixture {
  let persistence: PersistenceFixture
  let database: WorkspaceDatabase
  let conversationID: String
  let run: LocalACPRunIdentifiers
  let writer: LocalACPAssistantStreamWriter

  init(onPersistenceEvent: (@Sendable (LocalACPAssistantStreamWriter.PersistenceEvent) -> Void)? = nil) async throws {
    persistence = try PersistenceFixture()
    database = try await persistence.openDatabase()
    conversationID = try await database.createFixtureLocalACPSession(
      runtimeKind: .codex, title: "Writer", ownerDeviceID: UUID()
    )
    run = try await database.beginLocalACPRun(conversationID: conversationID, input: .init(text: "Start"))
    writer = LocalACPAssistantStreamWriter(
      database: database, runID: run.runID, assistantMessageID: run.assistantMessageID,
      conversationID: conversationID, onChange: nil, onPersistenceEvent: onPersistenceEvent
    )
  }

  func assistantText() async throws -> [String] {
    try await database.conversationContent(id: conversationID).messages
      .filter { $0.role == "assistant" }.map(\.content)
  }

  func remove() { persistence.remove() }
}
