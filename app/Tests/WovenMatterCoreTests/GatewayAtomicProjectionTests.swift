import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@Suite("Atomic Gateway projection persistence")
struct GatewayAtomicProjectionTests {
  @Test("duplicate replay is inert and failed projection rolls back its trace claim")
  func duplicateAndRollback() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try await WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let conversation = try await database.createFixtureLocalACPSession(runtimeKind: .codex,
      title: "Atomic", ownerDeviceID: UUID())
    let run = try await database.beginLocalACPRun(conversationID: conversation, content: "Hello")
    let raw = #"{"event":"agent","payload":{"runId":"run","seq":1}}"#

    await #expect(throws: LocalACPSessionDatabaseError.self) {
      try await database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
        eventName: "agent", sequence: 1, eventType: "assistant_delta",
        eventPhase: "update", toolName: nil, content: "lost", rawEventJSON: raw,
        assistantMessageID: "wrong-reply", assistantMutation: .append("lost"),
        activity: nil)
    }
    #expect(try await database.deviceOwnedGatewayTraceEvents(runID: run.runID).isEmpty)

    #expect(try await database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
      eventName: "agent", sequence: 1, eventType: "assistant_delta",
      eventPhase: "update", toolName: nil, content: "kept", rawEventJSON: raw,
      assistantMessageID: run.assistantMessageID, assistantMutation: .append("kept"),
      streamBoundary: true,
      activity: AgentRunActivity(id: "thinking", kind: .thought, content: "work")) == .applied)
    #expect(try await database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
      eventName: "agent", sequence: 1, eventType: "assistant_delta",
      eventPhase: "update", toolName: nil, content: "duplicate", rawEventJSON: raw,
      assistantMessageID: run.assistantMessageID, assistantMutation: .append("duplicate"),
      streamBoundary: true,
      activity: AgentRunActivity(id: "thinking", kind: .thought, content: "duplicate")) == .duplicate)

    let page = try await database.conversationHistoryPage(id: conversation, limit: 20)
    let reply = try #require(page.messages.first { $0.id == run.assistantMessageID })
    #expect(reply.content == "kept")
    #expect(page.activities.map(\.activity.kind) == [.assistant, .thought])
    let traceEvents = try await database.deviceOwnedGatewayTraceEvents(runID: run.runID)
    #expect(traceEvents.count == 1)
    #expect(traceEvents.first?.sequence == 1)
    #expect(traceEvents.first?.rawEventJSON == raw)

    try await database.appendDeviceOwnedGatewayTraceEvent(runID: run.runID,
      eventName: "agent", sequence: 2, eventType: "assistant_delta",
      eventPhase: "update", toolName: nil, content: "uncertain",
      rawEventJSON: "legacy")
    #expect(try await database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
      eventName: "agent", sequence: 2, eventType: "assistant_delta",
      eventPhase: "update", toolName: nil, content: "uncertain",
      rawEventJSON: "legacy", assistantMessageID: run.assistantMessageID,
      assistantMutation: .append("uncertain"), activity: nil) == .legacyUncertain)
    let afterLegacy = try await database.conversationHistoryPage(id: conversation, limit: 20)
    #expect(afterLegacy.messages.first { $0.id == run.assistantMessageID }?.content == "kept")
    #expect(try await database.deviceOwnedGatewayTraceEvents(runID: run.runID).map(\.sequence) == [1])
  }

}
