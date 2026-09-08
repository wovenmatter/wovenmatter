import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient
@testable import WovenMatterDashboardStore

struct StreamingExperienceTests {
  @Test func commentaryKeepsFinalVisibleAndCanonicalReplacementWins() {
    let segments = [segment("1", "Before tool.\n"), segment("2", "Answer")]
    let live = AssistantTranscriptProjection(messageID: "reply", content: "Before tool.\nAnswer", activities: segments)
    #expect(live.body == "Answer")
    #expect(live.commentary.map(\.id) == ["1"])
    let replaced = AssistantTranscriptProjection(messageID: "reply", content: "Corrected answer", activities: segments)
    #expect(replaced.body == "Corrected answer")
    let canonicalFinal = AssistantTranscriptProjection(messageID: "reply", content: "Answer", activities: segments)
    #expect(canonicalFinal.commentary.map(\.id) == ["1"])
    let other = AssistantTranscriptProjection(messageID: "other", content: "Before tool.\nAnswer", activities: segments)
    #expect(other.commentary.isEmpty)
    #expect(other.body == "Before tool.\nAnswer")
  }

  @Test func replacementSnapshotsDoNotDuplicateFrozenCommentary() throws {
    let fixture = try databaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let run = try fixture.database.beginLocalACPRun(conversationID: fixture.conversation, content: "fixture")
    for snapshot in ["First segment", "Replaced segment 👩🏽‍💻\n", "Replaced segment 👩🏽‍💻\nNext"] {
      try fixture.database.replaceLocalACPAssistantMessage(runID: run.runID, content: snapshot)
      try fixture.database.recordAssistantStreamBoundary(runID: run.runID)
    }
    let page = try fixture.database.conversationHistoryPage(id: fixture.conversation, limit: 50)
    #expect(page.activities.map(\.activity.content) == ["First segment", "Replaced segment 👩🏽‍💻\n", "Next"])
    let projection = AssistantTranscriptProjection(messageID: run.assistantMessageID,
      content: "Replaced segment 👩🏽‍💻\nNext", activities: page.activities.map(\.activity))
    #expect(projection.body == "Next")
    #expect(projection.commentary.count == 2)
  }

  @Test func preToolTextStaysAboveToolBeforeNextDeltaArrives() {
    let before = segment("1", "Checking now.")
    let tool = AgentRunActivity(id: "tool", kind: .tool, status: "running")
    let projection = AssistantTranscriptProjection(messageID: "reply", content: "Checking now.", activities: [before, tool])
    #expect(projection.body.isEmpty)
    #expect(projection.commentary.map(\.content) == ["Checking now."])
  }

  @Test func durableBoundariesPreserveWhitespaceOrderingAndReopen() async throws {
    let fixture = try databaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let run = try fixture.database.beginLocalACPRun(conversationID: fixture.conversation, content: "fixture")
    let writer = LocalACPAssistantStreamWriter(database: fixture.database, runID: run.runID,
      conversationID: fixture.conversation, onChange: nil)
    try await writer.append("Before\n```swift\n  ")
    try await writer.append("let x = 1\n```\n")
    try await writer.finishSegment()
    try fixture.database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: AgentRunActivity(id: "tool", kind: .tool, status: "running"))
    try await writer.finishSegment() // repeated boundary must not duplicate text
    try await writer.append("Final answer")
    try await writer.finish()
    try fixture.database.completeLocalACPRun(runID: run.runID)
    let reopened = try WorkspaceDatabase(url: fixture.directory.appending(path: "workspace.sqlite"))
    let page = try reopened.conversationHistoryPage(id: fixture.conversation, limit: 50)
    let reply = try #require(page.messages.first { $0.id == run.assistantMessageID })
    let activities = page.activities.sorted(by: WorkspaceRunActivityRecord.precedes)
    #expect(activities.map(\.activity.kind) == [.assistant, .tool])
    let projection = AssistantTranscriptProjection(messageID: reply.id, content: reply.content, activities: activities.map(\.activity))
    #expect(projection.body == "Final answer")
    #expect(projection.commentary.first?.content == "Before\n```swift\n  let x = 1\n```\n")
    #expect(throws: (any Error).self) {
      try reopened.appendLocalACPAssistantChunk(runID: run.runID, chunk: "late")
    }
  }

  @Test(arguments: AgentRuntimeKind.allCases)
  func coordinatorPreservesBufferedTailOnFailure(runtime: AgentRuntimeKind) async throws {
    let fixture = try databaseFixture(runtime: runtime)
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let changes = AsyncStream<DashboardConversationChange>.makeStream()
    let coordinator = LocalACPSessionCoordinator(database: fixture.database,
      onChange: { changes.continuation.yield($0) }, clientFactory: { _, _ in
        LocalACPSessionDriver(initializeSession: { _, _, _, _ in
          LocalACPInitializedSession(sessionID: "fixture-session", loadedExistingSession: false)
        }, prompt: { _, onEvent, _, _ in
          try await onEvent?(.assistantChunk("Useful partial reply\n"))
          throw FixtureError.disconnected
        }, configuration: { .empty }, setConfiguration: { _, _ in .empty }, cancel: {}, shutdown: {})
      })
    let run = try await coordinator.accept(conversationID: fixture.conversation, content: "fixture",
      launch: LocalACPRuntimeLaunchConfiguration(runtimeKind: runtime,
        executableURL: URL(filePath: "/nonexistent-fixture"), arguments: []),
      workspace: LocalACPWorkspaceLaunchConfiguration(rootURL: fixture.directory, repositoriesURL: fixture.directory))
    for await change in changes.stream where change.runID == run.runID && change.phase == .terminal { break }
    changes.continuation.finish()
    let page = try fixture.database.conversationHistoryPage(id: fixture.conversation, limit: 50)
    #expect(page.messages.first { $0.id == run.assistantMessageID }?.content == "Useful partial reply\n")
    #expect(page.runs.first?.status == "failed")
    await coordinator.shutdown()
  }

  @Test func gatewayFencesMirrorsLateFramesAndSeparateRuns() {
    var fence = GatewayStreamEventFence()
    let accepted0 = fence.accept(event("agent", stream: "tool", seq: 5), remoteRunID: "a", terminal: false)
    #expect(accepted0)
    let accepted1 = !fence.accept(event("session.tool", stream: "tool", seq: 5), remoteRunID: "a", terminal: false)
    #expect(accepted1)
    let accepted2 = !fence.accept(event("agent", stream: "tool", seq: 4), remoteRunID: "a", terminal: false)
    #expect(accepted2)
    let accepted3 = fence.accept(event("chat", seq: 1), remoteRunID: "a", terminal: false)
    #expect(accepted3)
    let accepted4 = fence.accept(event("chat", seq: 2), remoteRunID: "a", terminal: true)
    #expect(accepted4)
    let accepted5 = !fence.accept(event("agent", stream: "assistant", seq: 99), remoteRunID: "a", terminal: false)
    #expect(accepted5)
    let accepted6 = fence.accept(event("agent", stream: "tool", seq: 1), remoteRunID: "b", terminal: false)
    #expect(accepted6)
    // The outer transport sequence resets with a connection; it isn't a run fence.
    let accepted7 = fence.accept(event("agent", stream: "assistant"), remoteRunID: "b", terminal: false)
    #expect(accepted7)
  }

  @Test func gatewayMirroredDeltasAreNotAppendedTwice() {
    var source = GatewayAssistantStreamSource()
    let accepted8 = source.accepts(event("agent"), runID: "a", update: .append("Hello"), terminal: false)
    #expect(accepted8)
    let accepted9 = !source.accepts(event("chat"), runID: "a", update: .append("Hello"), terminal: false)
    #expect(accepted9)
    let accepted10 = source.accepts(event("chat"), runID: "a", update: .replace("Hello world"), terminal: false)
    #expect(accepted10)
    let accepted11 = !source.accepts(event("agent"), runID: "a", update: .append(" world"), terminal: false)
    #expect(accepted11)
    let accepted12 = source.accepts(event("chat"), runID: "a", update: .replace("Corrected"), terminal: true)
    #expect(accepted12)
  }

  @Test func historyMatchesExactRunAndNeverAdoptsLatestForeignReply() {
    let history: GatewayJSONValue = .object(["messages": .array([
      .object(["role": .string("assistant"), "text": .string("Mine"),
        "__openclaw": .object(["runId": .string("a")])]),
      .object(["role": .string("assistant"), "text": .string("Other client"), "runId": .string("b")])
    ])])
    #expect(OpenClawGatewayCoordinator.assistantText(history: history, idempotencyKey: "a") == "Mine")
    #expect(OpenClawGatewayCoordinator.assistantText(history: history, idempotencyKey: "missing") == nil)
  }

  @Test func structuredPlanAndLifecycleAreProjected() throws {
    let plan = OpenClawGatewayEvent(name: "agent", payload: .object([
      "stream": .string("plan"), "data": .object(["steps": .array([
        .object(["step": .string("Validate"), "status": .string("in_progress")])])])]), sequence: nil)
    #expect(OpenClawGatewayEventProjection.project(plan)?.activity?.planEntries == [AgentRunPlanEntry(content: "Validate", status: "in_progress")])
    let terminal = OpenClawGatewayEvent(name: "agent", payload: .object([
      "stream": .string("lifecycle"), "data": .object(["phase": .string("error"), "error": .string("Fixture failure")])]), sequence: nil)
    #expect(OpenClawGatewayEventProjection.project(terminal)?.terminalState == .failed("Fixture failure"))
  }

  @Test func historyRecoveryRetriesEmptySuccessAndStopsAtMatchingReply() async {
    let history = DelayedHistoryFixture()
    let text = await GatewayHistoryRecovery.assistantText(remoteRunID: "a", fetch: {
      await history.fetch()
    }, pause: { _ in })
    #expect(text == "Persisted final")
    #expect(await history.calls == 3)
    let missing = DelayedHistoryFixture(neverMatches: true)
    let absent = await GatewayHistoryRecovery.assistantText(remoteRunID: "a", fetch: {
      await missing.fetch()
    }, pause: { _ in })
    #expect(absent == nil)
    #expect(await missing.calls == 5)
  }

  @Test func emptyTerminalDoesNotErasePartialAndProgressClearRetiresChecklist() throws {
    let terminal = OpenClawGatewayEvent(name: "chat", payload: .object([
      "state": .string("aborted"), "message": .object(["text": .string("")])
    ]), sequence: nil)
    #expect(OpenClawGatewayEventProjection.project(terminal)?.assistantUpdate == nil)
    let card = OpenClawGatewayEventProjection.progressCardActivity(.object([
      "markdown": .string("Validation in progress"), "steps": .array([
        .object(["step": .string("Build"), "status": .string("in_progress")])
      ])
    ]))
    #expect(card.planEntries.first?.status == "in_progress")
    let cleared = card.merging(OpenClawGatewayEventProjection.progressCardActivity(nil))
    #expect(cleared.planEntries.isEmpty)
    #expect(cleared.phase == "clear")
    #expect(cleared.content == "")
  }

  @Test func terminalWriterFlushesPausedTailAndRejectsLateChunks() async throws {
    let fixture = try databaseFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let run = try fixture.database.beginLocalACPRun(conversationID: fixture.conversation, content: "fixture")
    let writer = LocalACPAssistantStreamWriter(database: fixture.database, runID: run.runID,
      conversationID: fixture.conversation, onChange: nil)
    try await writer.append("Partial")
    try await writer.finishSegmentAndPause()
    try await writer.finish()
    try await writer.append("late")
    try fixture.database.cancelLocalACPRun(runID: run.runID)
    let page = try fixture.database.conversationHistoryPage(id: fixture.conversation, limit: 50)
    #expect(page.runs.first?.status == "cancelled")
    #expect(page.messages.first { $0.id == run.assistantMessageID }?.content == "Partial")
    #expect(OpenClawGatewayCoordinator.isAmbiguousSendError(OpenClawGatewayClientError.requestTimedOut("chat.send")))
    #expect(!OpenClawGatewayCoordinator.isAmbiguousSendError(OpenClawGatewayClientError.invalidEndpoint))
  }

  private func segment(_ id: String, _ content: String) -> AgentRunActivity {
    AgentRunActivity(id: id, kind: .assistant, content: content, assistantMessageID: "reply")
  }
  private func event(_ name: String, stream: String? = nil, seq: Int? = nil) -> OpenClawGatewayEvent {
    var payload: [String: GatewayJSONValue] = [:]
    if let stream { payload["stream"] = .string(stream) }
    if let seq { payload["seq"] = .number(Double(seq)) }
    return OpenClawGatewayEvent(name: name, payload: .object(payload), sequence: 1)
  }
  private func databaseFixture(runtime: AgentRuntimeKind = .codex) throws -> (directory: URL, database: WorkspaceDatabase, conversation: String) {
    let directory = FileManager.default.temporaryDirectory.appending(path: "woven-stream-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
    let conversation = try database.createLocalACPSession(runtimeKind: runtime, title: "Streaming fixture", ownerDeviceID: UUID())
    return (directory, database, conversation)
  }
}

private enum FixtureError: Error { case disconnected }

private actor DelayedHistoryFixture {
  var calls = 0
  let neverMatches: Bool
  init(neverMatches: Bool = false) { self.neverMatches = neverMatches }
  func fetch() -> GatewayJSONValue {
    calls += 1
    if calls < 3 || neverMatches { return .object(["messages": .array([])]) }
    return .object(["messages": .array([.object([
      "role": .string("assistant"), "text": .string("Persisted final"),
      "idempotencyKey": .string("a:assistant")
    ])])])
  }
}
