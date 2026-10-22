import Foundation
import Testing
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

@Suite("Assistant transcript projection")
struct AssistantTranscriptProjectionTests {

  @Test("final-only Gateway history preserves commentary without a full history sync", arguments: [false, true])
  func finalSegmentHistory(finalBoundary: Bool) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let conversation = try await database.createLocalACPSession(runtimeKind: .codex, title: "History", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Start")
    let commentary = "Checking…\n\n"
    try await database.appendLocalACPAssistantChunk(runID: run.runID, chunk: commentary)
    try await database.recordAssistantStreamBoundary(runID: run.runID)
    try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: AgentRunActivity(id: "tool", kind: .tool))
    if finalBoundary {
      try await database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "Draft final")
      try await database.recordAssistantStreamBoundary(runID: run.runID, finalSegment: true)
      try await database.upsertDeviceOwnedRunActivity(runID: run.runID,
        activity: AgentRunActivity(id: "late-reasoning", kind: .thought, content: "Late reasoning"))
    }
    // No full session-history synchronization occurs: this reply is the only
    // history repair available, and its delivery can be replayed.
    for _ in 0..<2 {
      try await database.replaceLocalACPAssistantMessage(runID: run.runID,
        assistantMessageID: run.assistantMessageID, content: "Final answer",
        preservingStreamCommentary: true)
      let page = try await database.conversationHistoryPage(id: conversation, limit: 20)
      let reply = try #require(page.messages.first { $0.role == "assistant" })
      let projection = AssistantTranscriptProjection(messageID: reply.id, content: reply.content,
        activities: page.activities.map(\.activity))
      #expect(reply.content == commentary + "Final answer")
      #expect(projection.body == "Final answer")
      #expect(projection.commentary.map(\.content) == [commentary])
    }
    // Whole-message snapshots retain their authoritative replacement contract.
    try await database.replaceLocalACPAssistantMessage(runID: run.runID,
      assistantMessageID: run.assistantMessageID, content: "Replacement")
    let page = try await database.conversationHistoryPage(id: conversation, limit: 20)
    let reply = try #require(page.messages.first { $0.role == "assistant" })
    let projection = AssistantTranscriptProjection(messageID: reply.id, content: reply.content,
      activities: page.activities.map(\.activity))
    #expect(projection.body == "Replacement")
    #expect(projection.commentary.isEmpty)
  }

}
