import Foundation
import Testing
import WovenMatterCore
import WovenMatterDashboardStore

@Suite("Atomic Gateway projection persistence")
struct GatewayAtomicProjectionTests {
  @Test("duplicate replay is inert and failed projection rolls back its trace claim")
  func duplicateAndRollback() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let database = try WorkspaceDatabase(url: directory.appendingPathComponent("workspace.sqlite"))
    let conversation = try database.createLocalACPSession(runtimeKind: .openclaw,
      title: "Atomic", ownerDeviceID: UUID())
    let run = try database.beginLocalACPRun(conversationID: conversation, content: "Hello")
    let raw = #"{"event":"agent","payload":{"runId":"run","seq":1}}"#

    #expect(throws: LocalACPSessionDatabaseError.self) {
      try database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
        eventName: "agent", sequence: 1, eventType: "assistant_delta",
        eventPhase: "update", toolName: nil, content: "lost", rawEventJSON: raw,
        assistantMessageID: "wrong-reply", assistantMutation: .append("lost"),
        activity: nil)
    }
    #expect(try database.deviceOwnedGatewayTraceEvents(runID: run.runID).isEmpty)

    #expect(try database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
      eventName: "agent", sequence: 1, eventType: "assistant_delta",
      eventPhase: "update", toolName: nil, content: "kept", rawEventJSON: raw,
      assistantMessageID: run.assistantMessageID, assistantMutation: .append("kept"),
      streamBoundary: true,
      activity: AgentRunActivity(id: "thinking", kind: .thought, content: "work")) == .applied)
    #expect(try database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
      eventName: "agent", sequence: 1, eventType: "assistant_delta",
      eventPhase: "update", toolName: nil, content: "duplicate", rawEventJSON: raw,
      assistantMessageID: run.assistantMessageID, assistantMutation: .append("duplicate"),
      streamBoundary: true,
      activity: AgentRunActivity(id: "thinking", kind: .thought, content: "duplicate")) == .duplicate)

    let page = try database.conversationHistoryPage(id: conversation, limit: 20)
    let reply = try #require(page.messages.first { $0.id == run.assistantMessageID })
    #expect(reply.content == "kept")
    #expect(page.activities.map(\.activity.kind) == [.assistant, .thought])
    let traceEvents = try database.deviceOwnedGatewayTraceEvents(runID: run.runID)
    #expect(traceEvents.count == 1)
    #expect(traceEvents.first?.sequence == 1)
    #expect(traceEvents.first?.rawEventJSON == raw)

    try database.appendDeviceOwnedGatewayTraceEvent(runID: run.runID,
      eventName: "agent", sequence: 2, eventType: "assistant_delta",
      eventPhase: "update", toolName: nil, content: "uncertain",
      rawEventJSON: "legacy")
    #expect(try database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
      eventName: "agent", sequence: 2, eventType: "assistant_delta",
      eventPhase: "update", toolName: nil, content: "uncertain",
      rawEventJSON: "legacy", assistantMessageID: run.assistantMessageID,
      assistantMutation: .append("uncertain"), activity: nil) == .legacyUncertain)
    let afterLegacy = try database.conversationHistoryPage(id: conversation, limit: 20)
    #expect(afterLegacy.messages.first { $0.id == run.assistantMessageID }?.content == "kept")
    #expect(try database.deviceOwnedGatewayTraceEvents(runID: run.runID).map(\.sequence) == [1])
  }

  @Test("trace hydration retains durable sequence order across reopen")
  func hydrationOrder() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("workspace.sqlite")
    let database = try WorkspaceDatabase(url: url)
    let conversation = try database.createLocalACPSession(runtimeKind: .openclaw,
      title: "Replay", ownerDeviceID: UUID())
    let run = try database.beginLocalACPRun(conversationID: conversation, content: "Hello")
    let sameInstant = Date(timeIntervalSince1970: 100)
    _ = try database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
      eventName: "agent", eventStream: "assistant",
      sequence: 1, eventType: "assistant_delta", eventPhase: "update", toolName: nil,
      content: nil, rawEventJSON: "seven", assistantMessageID: nil,
      assistantMutation: nil, activity: nil, createdAt: sameInstant)
    _ = try database.applyDeviceOwnedGatewayProjection(runID: run.runID, remoteRunID: "remote",
      eventName: "agent", eventStream: "reasoning",
      sequence: 1, eventType: "reasoning", eventPhase: "update", toolName: nil,
      content: nil, rawEventJSON: "three", assistantMessageID: nil,
      assistantMutation: nil, activity: nil, createdAt: sameInstant)
    let reopened = try WorkspaceDatabase(url: url)
    let events = try reopened.deviceOwnedGatewayTraceEvents(runID: run.runID)
    #expect(events.map(\.sequence) == [1, 1])
    #expect(events.map(\.rawEventJSON) == ["seven", "three"])
  }
}
