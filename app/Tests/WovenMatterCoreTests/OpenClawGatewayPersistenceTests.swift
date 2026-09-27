import Foundation
import Testing
import WovenMatterCore
import WovenMatterClient
@testable import WovenMatterDashboardStore

struct OpenClawGatewayPersistenceTests {
  @Test func gatewayImportIsIdempotentAndHistorySurvivesReopen() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "test.sqlite")
    let db = try await WorkspaceDatabase(url: url)
    _ = try await db.createLocalACPSession(runtimeKind: .openclaw, title: "Seed", ownerDeviceID: UUID())
    let agentID = try await #require(db.dashboardAgents().first).id
    let session = try #require(OpenClawGatewaySession(payload: .object(["key": .string("agent:eddie:shared"), "title": .string("Shared") ])))
    let id = try await db.importOpenClawGatewaySession(agentID: agentID, session: session)
    #expect(try await db.importOpenClawGatewaySession(agentID: agentID, session: session) == id)
    let run = try await db.beginLocalACPRun(conversationID: id, content: "Hello")
    let history = try OpenClawGatewayHistory(payload: .object(["messages": .array([
      message(id: "native-user", role: "user", runID: run.runID + ":user", text: "Hello"),
      message(id: "native-assistant", role: "assistant", runID: run.runID + ":assistant", text: "World")
    ])]))
    try await db.synchronizeOpenClawHistory(conversationID: id, history: history)
    try await db.synchronizeOpenClawHistory(conversationID: id, history: history)
    #expect(try await db.conversationContent(id: id).messages.count == 2)
    try await db.replaceLocalACPAssistantMessage(runID: run.runID, assistantMessageID: run.assistantMessageID, content: "Newer live text")
    try await db.synchronizeOpenClawHistory(conversationID: id, history: history, liveRunIDs: [run.runID])
    #expect(try await db.conversationContent(id: id).messages.first(where: { $0.id == run.assistantMessageID })?.content == "Newer live text")
    let reopened = try await WorkspaceDatabase(url: url)
    try await reopened.recoverInterruptedLocalACPRuns()
    #expect(try await reopened.interruptedOpenClawRuns(conversationID: id).map(\.runID) == [run.runID])
    try await reopened.synchronizeOpenClawHistory(conversationID: id, history: history)
    #expect(try await reopened.conversationContent(id: id).messages.count == 2)
    #expect(try await reopened.conversationContent(id: id).messages.first(where: { $0.id == run.assistantMessageID })?.content == "World")
  }

  @Test func gatewayUnknownDeliveryIsNotResentOrReportedSuccessful() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let db = try await WorkspaceDatabase(url: directory.appending(path: "test.sqlite"))
    let id = try await db.createLocalACPSession(runtimeKind: .openclaw, title: "Delivery", ownerDeviceID: UUID())
    let agentID = try await #require(db.dashboardAgents().first).id
    try await db.attachOpenClawGatewaySession(conversationID: id, agentID: agentID, sessionKey: "agent:eddie:shared")
    let run = try await db.beginLocalACPRun(conversationID: id, content: "Unconfirmed")
    let coordinator = OpenClawGatewayCoordinator(database: db, connectClient: { _ in
      Issue.record("Recovery must not send an input or connect to a provider")
      return OpenClawGatewayCapabilities(methods: [], events: [])
    })
    let unknown = try OpenClawGatewayHistory(payload: .object(["messages": .array([])]))
    try await coordinator.recoverSessionRuns(conversationID: id, history: unknown)
    #expect(try await db.interruptedOpenClawRuns(conversationID: id).count == 1)
    let idle = try OpenClawGatewayHistory(payload: .object([
      "messages": .array([]), "sessionInfo": .object(["hasActiveRun": .bool(false)])]))
    try await coordinator.recoverSessionRuns(conversationID: id, history: idle)
    #expect(try await db.interruptedOpenClawRuns(conversationID: id).isEmpty)
    let assistant = try await #require(db.conversationContent(id: id).messages.first { $0.id == run.assistantMessageID })
    #expect(assistant.status == "failed")
    #expect(assistant.content.contains("not resent"))
  }

  private func message(id: String, role: String, runID: String, text: String) -> GatewayJSONValue {
    .object(["role": .string(role), "text": .string(text), "timestamp": .number(1_700_000_000_000),
      "__openclaw": .object(["id": .string(id), "idempotencyKey": .string(runID)])])
  }
}
