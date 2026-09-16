import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient
@testable import WovenMatterDashboardStore

struct OpenClawGatewayReviewTests {
  @Test(arguments: ["off", "serve", "funnel"])
  func localConfigurationPreservesAuthenticationAndTailscale(mode: String) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "openclaw.json")
    let data = Data("""
      { "gateway": { "mode": "local", "port": 19789, "bind": "loopback",
        "auth": { "mode": "token", "token": "${FIXTURE_GATEWAY_TOKEN}" },
        "tailscale": { "mode": "\(mode)", "resetOnExit": false } } }
      """.utf8)
    try data.write(to: url)
    let config = try OpenClawLocalGatewayConfiguration(environment: [
      "HOME": directory.path, "OPENCLAW_CONFIG_PATH": url.path,
      "FIXTURE_GATEWAY_TOKEN": "fixture-token", "OPENCLAW_GATEWAY_PASSWORD": "unrelated-password"
    ])
    #expect(config.port == 19789)
    #expect(config.token == "fixture-token")
    #expect(config.password == nil)
    #expect(try Data(contentsOf: url) == data)
  }

  @Test func localPasswordModeDoesNotReadAnUnusedTokenReference() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appending(path: "openclaw.json")
    try Data("""
      { "gateway": { "mode": "local", "auth": { "mode": "password",
        "password": { "source": "env", "id": "FIXTURE_PASSWORD" },
        "token": { "source": "store", "id": "unavailable-unused-token" } } } }
      """.utf8).write(to: url)
    let config = try OpenClawLocalGatewayConfiguration(environment: [
      "HOME": directory.path, "OPENCLAW_CONFIG_PATH": url.path, "FIXTURE_PASSWORD": "fixture-password"
    ])
    #expect(config.port == 18789)
    #expect(config.password == "fixture-password")
    #expect(config.token == nil)
  }

  @Test func steeringHistoryReconcilesExactMessagesAfterReopen() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    let initial = try fixture.database.beginLocalACPRun(conversationID: id, content: "First")
    let steering = try fixture.database.beginLocalACPSteeringTurn(runID: initial.runID, input: AgentMessageInput(text: "Second"), completesPreviousAssistant: false)
    let history = try OpenClawGatewayHistory(payload: .object(["messages": .array([
      historyMessage("u1", "user", initial.runID, "First"), historyMessage("a1", "assistant", initial.runID, "First reply"),
      historyMessage("u2", "user", steering.userMessageID, "Second"), historyMessage("a2", "assistant", steering.userMessageID, "Second reply")
    ])]))
    let reopened = try WorkspaceDatabase(url: fixture.directory.appending(path: "review.sqlite"))
    try reopened.synchronizeOpenClawHistory(conversationID: id, history: history)
    try reopened.synchronizeOpenClawHistory(conversationID: id, history: history)
    let messages = try reopened.conversationContent(id: id).messages
    #expect(messages.count == 4)
    #expect(messages.first { $0.id == initial.assistantMessageID }?.content == "First reply")
    #expect(messages.first { $0.id == steering.assistantMessageID }?.content == "Second reply")
    await fixture.coordinator.shutdown()
  }

  @Test func nativeRunIdentityReconcilesAfterDatabaseReopen() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    let run = try fixture.database.beginLocalACPRun(conversationID: id, content: "Hello")
    let history = try OpenClawGatewayHistory(payload: .object([
      "sessionInfo": .object(["hasActiveRun": .bool(false)]),
      "messages": .array([.object(["role": .string("assistant"), "content": .string("Native reply"),
        "__openclaw": .object(["id": .string("native-answer"), "runId": .string(run.runID)])])])]))
    let reopened = try WorkspaceDatabase(url: fixture.directory.appending(path: "review.sqlite"))
    try reopened.recoverInterruptedLocalACPRuns()
    #expect(try reopened.interruptedOpenClawRuns(conversationID: id).count == 1)
    try reopened.synchronizeOpenClawHistory(conversationID: id, history: history)
    try await fixture.coordinator.recoverSessionRuns(conversationID: id, history: history)
    let messages = try reopened.conversationContent(id: id).messages
    #expect(messages.count == 2)
    #expect(messages.first { $0.id == run.assistantMessageID }?.content == "Native reply")
    #expect(messages.first { $0.id == run.assistantMessageID }?.status == "completed")
    await fixture.coordinator.shutdown()
  }

  @Test func newWorkspaceSessionSetsOnlyItsOwnDirectory() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let key = "agent:eddie:wovenmatter:new"
    try await fixture.coordinator.createWorkspaceSession(agentID: fixture.agentID, sessionKey: key,
      cwd: URL(fileURLWithPath: "/shared/wovenmatter"))
    #expect(await fixture.socket.creationParameters == .object([
      "key": .string(key), "cwd": .string("/shared/wovenmatter")
    ]))
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    #expect(try fixture.database.knownOpenClawSessionKeys(agentID: fixture.agentID).contains(fixture.session.key))
    #expect(try fixture.database.openClawGatewaySession(conversationID: id).sessionKey == fixture.session.key)
    await fixture.coordinator.shutdown()
  }

  @Test func providerIdentityRepairsHistoryDuplicateAndContentRevisions() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    let run = try fixture.database.beginLocalACPRun(conversationID: id, content: "Hello")
    try fixture.database.replaceLocalACPAssistantMessage(runID: run.runID, assistantMessageID: run.assistantMessageID, content: "Reply")
    func history(_ text: String, gatewayID: String?) throws -> OpenClawGatewayHistory {
      var metadata: [String: GatewayJSONValue] = ["id": .string("answer"), "idempotencyKey": .string("codex-app-server:thread:turn:assistant")]
      if let gatewayID { metadata["runId"] = .string(gatewayID) }
      return try OpenClawGatewayHistory(payload: .object(["messages": .array([
        .object(["role": .string("assistant"), "content": .string(text), "__openclaw": .object(metadata)])])]))
    }
    // Seed the same orphan history row the old parser created, without editing a live DB.
    try fixture.database.synchronizeOpenClawHistory(conversationID: id, history: history("Reply", gatewayID: nil))
    #expect(try fixture.database.conversationContent(id: id).messages.count == 3)
    let reopened = try WorkspaceDatabase(url: fixture.directory.appending(path: "review.sqlite"))
    try reopened.synchronizeOpenClawHistory(conversationID: id, history: history("Reply", gatewayID: run.runID))
    try reopened.synchronizeOpenClawHistory(conversationID: id, history: history("Revised reply", gatewayID: run.runID))
    try reopened.synchronizeOpenClawHistory(conversationID: id, history: history("Revised reply", gatewayID: run.runID))
    #expect(try history("Reply", gatewayID: run.runID).messages.first?.correlatedRunID(knownInputIDs: [run.runID]) == run.runID)
    let messages = try reopened.conversationContent(id: id).messages
    #expect(messages.count == 2)
    #expect(messages.first { $0.id == run.assistantMessageID }?.content == "Revised reply")
    #expect(try reopened.interruptedOpenClawRuns(conversationID: id).first?.runID == run.runID)
    await fixture.coordinator.shutdown()
  }

  @Test func exactSteeringKeyWinsOverExecutionIDAndDistinctRepliesRemain() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    let run = try fixture.database.beginLocalACPRun(conversationID: id, content: "First")
    let steering = try fixture.database.beginLocalACPSteeringTurn(runID: run.runID, input: AgentMessageInput(text: "Second"), completesPreviousAssistant: false)
    let rows: [GatewayJSONValue] = ["one", "two"].map { key in
      .object(["role": .string("assistant"), "content": .string("Same text"),
        "__openclaw": .object(["id": .string(key), "idempotencyKey": .string(steering.userMessageID + ":assistant"), "runId": .string(run.runID)])])
    }
    let history = try OpenClawGatewayHistory(payload: .object(["messages": .array(rows)]))
    try fixture.database.synchronizeOpenClawHistory(conversationID: id, history: history)
    try fixture.database.synchronizeOpenClawHistory(conversationID: id, history: history)
    let messages = try fixture.database.conversationContent(id: id).messages
    #expect(messages.count == 5)
    #expect(messages.first { $0.id == steering.assistantMessageID }?.content == "Same text")
    #expect(messages.first { $0.id == run.assistantMessageID }?.content != "Same text")
    await fixture.coordinator.shutdown()
  }

  @Test func partialHistoryRetainsProjectedSiblings() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    let rows: [GatewayJSONValue] = ["First", "Second"].map { text in
      .object(["role": .string("assistant"), "content": .string(text),
        "__openclaw": .object(["id": .string("shared-record"), "runId": .string("external-run")])])
    }
    try fixture.database.synchronizeOpenClawHistory(conversationID: id,
      history: OpenClawGatewayHistory(payload: .object(["messages": .array(rows)])))
    try fixture.database.synchronizeOpenClawHistory(conversationID: id,
      history: OpenClawGatewayHistory(payload: .object(["messages": .array([rows[1]])])))
    #expect(try fixture.database.conversationContent(id: id).messages.count == 2)
    await fixture.coordinator.shutdown()
  }

  @Test func initialReplyDoesNotProveLatestSteeringWasDelivered() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    let initial = try fixture.database.beginLocalACPRun(conversationID: id, content: "First")
    let steering = try fixture.database.beginLocalACPSteeringTurn(runID: initial.runID, input: AgentMessageInput(text: "Second"), completesPreviousAssistant: false)
    let history = try OpenClawGatewayHistory(payload: .object([
      "messages": .array([historyMessage("a1", "assistant", initial.runID, "First reply")]),
      "sessionInfo": .object(["hasActiveRun": .bool(false)])]))
    try await fixture.coordinator.recoverSessionRuns(conversationID: id, history: history)
    let message = try #require(fixture.database.conversationContent(id: id).messages.first { $0.id == steering.assistantMessageID })
    #expect(message.status == "failed")
    await fixture.coordinator.shutdown()
  }

  private func historyMessage(_ id: String, _ role: String, _ runID: String, _ text: String) -> GatewayJSONValue {
    .object(["role": .string(role), "content": .string(text),
      "__openclaw": .object(["id": .string(id), "idempotencyKey": .string(runID + ":" + role)])])
  }

  @Test func failedImportLeavesNoPhantomConversation() async throws {
    let fixture = try ReviewGatewayFixture(denyHistory: true)
    defer { fixture.remove() }
    do {
      _ = try await fixture.coordinator.importSession(agentID: fixture.agentID, session: fixture.session)
      Issue.record("Denied history was imported")
    } catch OpenClawGatewayClientError.rejected { }
    #expect(try fixture.database.openClawGatewaySessions(agentID: fixture.agentID).isEmpty)
    await fixture.coordinator.shutdown()
  }

  @Test func historyDoesNotRequireApprovalScopes() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try await fixture.coordinator.importSession(agentID: fixture.agentID, session: fixture.session)
    _ = try await fixture.coordinator.synchronizeSession(conversationID: id)
    #expect(await fixture.socket.historyCalls == 2)
    await fixture.coordinator.shutdown()
  }

  @Test func toolOutputCannotReplaceAssistantOrProveSuccessfulRecovery() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    let run = try fixture.database.beginLocalACPRun(conversationID: id, content: "Hello")
    let history = try OpenClawGatewayHistory(payload: .object([
      "sessionInfo": .object(["hasActiveRun": .bool(false)]),
      "messages": .array([.object(["role": .string("toolResult"), "content": .string("Tool succeeded"),
        "__openclaw": .object(["id": .string("tool"), "idempotencyKey": .string(run.runID)])])])]))
    try fixture.database.synchronizeOpenClawHistory(conversationID: id, history: history)
    let before = try #require(fixture.database.conversationContent(id: id).messages.first { $0.id == run.assistantMessageID })
    #expect(before.content.isEmpty)
    try await fixture.coordinator.recoverSessionRuns(conversationID: id, history: history)
    let after = try #require(fixture.database.conversationContent(id: id).messages.first { $0.id == run.assistantMessageID })
    #expect(after.status == "failed")
    #expect(after.content.contains("not resent"))
    await fixture.coordinator.shutdown()
  }

  @Test(arguments: [false, true])
  func idleHistoryPreservesCommentaryThroughCoordinatorRecovery(tracked: Bool) async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    let run = try fixture.database.beginLocalACPRun(conversationID: id, content: "Start")
    try fixture.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "Commentary\n\n")
    try fixture.database.recordAssistantStreamBoundary(runID: run.runID)
    try fixture.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "Draft final")
    try fixture.database.recordAssistantStreamBoundary(runID: run.runID, finalSegment: true)
    try fixture.database.upsertDeviceOwnedRunActivity(runID: run.runID,
      activity: AgentRunActivity(id: "late", kind: .thought, content: "Late reasoning"))
    let payload: GatewayJSONValue = .object([
      "sessionInfo": .object(["hasActiveRun": .bool(false)]),
      "messages": .array([.object(["role": .string("assistant"), "text": .string("Final answer"),
        "__openclaw": .object(["id": .string("final"), "runId": .string(run.runID), "idempotencyKey": .string(run.runID + ":assistant")])])]),
    ])
    await fixture.socket.setHistory(payload)
    if tracked {
      let active = try OpenClawGatewayHistory(payload: .object([
        "sessionInfo": .object(["hasActiveRun": .bool(true)]), "messages": .array([]),
      ]))
      try await fixture.coordinator.recoverSessionRuns(conversationID: id, history: active)
      // The recovered observer must perform the actual idle synchronization
      // before it terminalizes the locally tracked run.
      for _ in 0..<400 {
        if try fixture.database.conversationContent(id: id).runs.first?.status == "completed" { break }
        try await Task.sleep(for: .milliseconds(5))
      }
    } else {
      _ = try await fixture.coordinator.synchronizeSession(conversationID: id)
    }
    let page = try fixture.database.conversationHistoryPage(id: id, limit: 20)
    let reply = try #require(page.messages.first { $0.id == run.assistantMessageID })
    #expect(reply.content == "Commentary\n\nFinal answer")
    #expect(page.runs.first?.status == "completed")
    let projection = AssistantTranscriptProjection(messageID: reply.id, content: reply.content,
      activities: page.activities.map(\.activity))
    #expect(projection.body == "Final answer")
    #expect(projection.commentary.map(\.content) == ["Commentary\n\n"])
    // Ordinary refresh after completion and database reopen must not erase
    // the preserved prefix, even when this page contains only the final row.
    _ = try await fixture.coordinator.synchronizeSession(conversationID: id)
    #expect(try fixture.database.conversationContent(id: id).messages.first { $0.id == run.assistantMessageID }?.content == reply.content)
    let reopened = try WorkspaceDatabase(url: fixture.directory.appending(path: "review.sqlite"))
    try reopened.synchronizeOpenClawHistory(conversationID: id, history: OpenClawGatewayHistory(payload: payload))
    #expect(try reopened.conversationContent(id: id).messages.first { $0.id == run.assistantMessageID }?.content == reply.content)
    let replacement = try OpenClawGatewayHistory(payload: .object([
      "messages": .array([.object(["role": .string("assistant"), "text": .string("Authoritative replacement"),
        "__openclaw": .object(["id": .string("final"), "runId": .string(run.runID)])])]),
    ]))
    try reopened.synchronizeOpenClawHistory(conversationID: id, history: replacement)
    let replaced = try reopened.conversationHistoryPage(id: id, limit: 20)
    let replacedReply = try #require(replaced.messages.first { $0.id == run.assistantMessageID })
    #expect(replacedReply.content == "Authoritative replacement")
    #expect(AssistantTranscriptProjection(messageID: replacedReply.id, content: replacedReply.content,
      activities: replaced.activities.map(\.activity)).commentary.isEmpty)
    await fixture.coordinator.shutdown()
  }

  @Test func modelDiscoveryUsesTheImportedSessionAndPreparedDetails() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    let metadata = try await fixture.coordinator.sessionMetadata(conversationID: id)
    let params = try #require(await fixture.socket.modelParameters?.objectValue)
    #expect(params["sessionKey"] == .string("agent:eddie:shared"))
    #expect(params["agentId"] == .string("eddie"))
    #expect(params["preparedOnly"] == .bool(true))
    #expect(params["includeDetails"] == .bool(true))
    #expect(params["refresh"] == nil)
    #expect(metadata.model == "xai/grok-4.6")
    #expect(metadata.modelOptions == ["xai/grok-4.6", "anthropic/claude-sonnet-4-6"])
    #expect(metadata.modelOptionMetadata?["xai/grok-4.6"] == SessionOptionMetadata(
      name: "Grok 4.6", description: "Native model description"
    ))
    #expect(metadata.thinkingLevels == ["high", "low"])
    #expect(metadata.thinkingOptionMetadata?["high"] == SessionOptionMetadata(
      name: "High effort", description: "Thorough reasoning"
    ))
    #expect(metadata.thinkingOptionMetadata?["low"]?.name == "Low effort")
    #expect(!(await fixture.socket.requestMethods).contains("agents.list"))
    await fixture.coordinator.shutdown()
  }

  @Test func modelDiscoveryFallsBackToSessionLevelsOnlyWhenCatalogFieldIsAbsent() async throws {
    let absent = try ReviewGatewayFixture(modelThinkingLevels: nil)
    defer { absent.remove() }
    let absentID = try absent.database.importOpenClawGatewaySession(
      agentID: absent.agentID, session: absent.session
    )
    let fallback = try await absent.coordinator.sessionMetadata(conversationID: absentID)
    #expect(fallback.thinkingLevels == ["medium"])
    #expect(fallback.thinkingOptionMetadata?["medium"]?.name == "Session medium")
    await absent.coordinator.shutdown()

    let empty = try ReviewGatewayFixture(modelThinkingLevels: .array([]))
    defer { empty.remove() }
    let emptyID = try empty.database.importOpenClawGatewaySession(
      agentID: empty.agentID, session: empty.session
    )
    let authoritativeEmpty = try await empty.coordinator.sessionMetadata(conversationID: emptyID)
    #expect(authoritativeEmpty.thinkingLevels == [])
    #expect(authoritativeEmpty.thinkingOptionMetadata == [:])
    await empty.coordinator.shutdown()
  }

  @Test func concurrentImportsKeepOneNativeSession() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let database = fixture.database, agentID = fixture.agentID, session = fixture.session
    let ids = try await withThrowingTaskGroup(of: String.self) { group in
      for _ in 0..<12 { group.addTask { try database.importOpenClawGatewaySession(agentID: agentID, session: session) } }
      var ids: [String] = []
      for try await id in group { ids.append(id) }
      return ids
    }
    #expect(Set(ids).count == 1)
    #expect(try database.openClawGatewaySessions(agentID: agentID).count == 1)
    await fixture.coordinator.shutdown()
  }
}

private struct ReviewGatewayFixture {
  let directory: URL
  let database: WorkspaceDatabase
  let coordinator: OpenClawGatewayCoordinator
  let agentID: UUID
  let session: OpenClawGatewaySession
  let socket: ReviewGatewaySocket

  init(denyHistory: Bool = false, modelThinkingLevels: GatewayJSONValue? = .array([
    .object(["id": .string("high"), "label": .string("High effort"),
      "description": .string("Thorough reasoning")]),
    .object(["id": .string("low"), "label": .string("Low effort")]),
  ])) throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try WorkspaceDatabase(url: directory.appending(path: "review.sqlite"))
    _ = try database.createLocalACPSession(runtimeKind: .openclaw, title: "Seed", ownerDeviceID: UUID())
    agentID = try #require(database.dashboardAgents().first).id
    let endpoint = OpenClawGatewayEndpoint(url: URL(string: "ws://127.0.0.1:1")!, authorization: .localService)
    try database.saveOpenClawGatewayLink(OpenClawGatewayLink(agentID: agentID, location: .localAgentWorkspace, endpoint: endpoint))
    session = try #require(OpenClawGatewaySession(payload: .object(["key": .string("agent:eddie:shared") ])))
    socket = ReviewGatewaySocket(
      denyHistory: denyHistory, modelThinkingLevels: modelThinkingLevels
    )
    let socket = socket
    let client = OpenClawGatewayClient(endpoint: endpoint, credentialStore: ReviewCredentials(), socketFactory: { _ in socket })
    coordinator = OpenClawGatewayCoordinator(database: database, client: client, connectClient: { try await $0.connect() })
  }
  func remove() { try? FileManager.default.removeItem(at: directory) }
}

private struct ReviewCredentials: OpenClawGatewayCredentialStore {
  func credentials(for scope: String) throws -> OpenClawGatewayCredentials { .init(privateKey: Data(repeating: 1, count: 32)) }
  func save(_ value: OpenClawGatewayCredentials, for scope: String) throws { }
}

private actor ReviewGatewaySocket: OpenClawGatewaySocket {
  let denyHistory: Bool
  let modelThinkingLevels: GatewayJSONValue?
  var modelParameters: GatewayJSONValue?
  var creationParameters: GatewayJSONValue?
  var historyCalls = 0
  var requestMethods: [String] = []
  private var historyPayload: GatewayJSONValue?
  func setHistory(_ payload: GatewayJSONValue) { historyPayload = payload }
  private var frames: [Data] = []
  private var waiter: CheckedContinuation<Data, any Error>?
  private var closed = false
  init(denyHistory: Bool, modelThinkingLevels: GatewayJSONValue?) {
    self.denyHistory = denyHistory
    self.modelThinkingLevels = modelThinkingLevels
  }
  func start() async {
    try? push(.object(["type": .string("event"), "event": .string("connect.challenge"),
      "payload": .object(["nonce": .string("fixture"), "ts": .number(1_700_000_000_000)])]))
  }
  func send(_ data: Data) async throws {
    let row = try JSONDecoder().decode(GatewayJSONValue.self, from: data).objectValue ?? [:]
    let method = row["method"]?.stringValue ?? ""
    requestMethods.append(method)
    let rejected = (method == "chat.history" && denyHistory)
      || (row["params"]?.objectValue?["includeApprovals"] == .bool(true))
    if method == "chat.history" { historyCalls += 1 }
    if method == "models.list" { modelParameters = row["params"] }
    if method == "sessions.create" { creationParameters = row["params"] }
    let payload: GatewayJSONValue
    switch method {
    case "connect": payload = .object(["protocol": .number(4)])
    case "sessions.describe": payload = .object(["session": .object([
      "model": .string("grok-4.6"), "modelProvider": .string("xai"),
      "thinkingLevel": .string("high"),
      "thinkingLevels": .array([.object([
        "id": .string("medium"), "label": .string("Session medium"),
      ])]),
    ])])
    case "models.list":
      var selected: [String: GatewayJSONValue] = [
        "id": .string("grok-4.6"), "provider": .string("xai"),
        "name": .string("Grok 4.6"),
        "description": .string("Native model description"),
        "available": .bool(true),
      ]
      if let modelThinkingLevels { selected["thinkingLevels"] = modelThinkingLevels }
      payload = .object(["models": .array([
      .object(selected),
      .object([
        "id": .string("claude-sonnet-4-6"), "provider": .string("anthropic"),
        "name": .string("Claude Sonnet 4.6"), "available": .bool(true),
        "thinkingLevels": .array([.object([
          "id": .string("medium"), "label": .string("Medium effort"),
        ])]),
      ]),
      .object([
        "id": .string("hidden"), "provider": .string("xai"),
        "name": .string("Unavailable"), "available": .bool(false),
      ]),
    ])])
    case "chat.history": payload = historyPayload ?? .object(["messages": .array([]), "sessionInfo": .object(["hasActiveRun": .bool(false)])])
    case "sessions.create": payload = .object(["key": row["params"]?.objectValue?["key"] ?? .null, "entry": .object(["spawnedCwd": row["params"]?.objectValue?["cwd"] ?? .null])])
    default: payload = .object(["messages": .array([]), "sessionInfo": .object(["hasActiveRun": .bool(false)])])
    }
    try push(.object(["type": .string("res"), "id": row["id"] ?? .null,
      "ok": .bool(!rejected), "payload": payload,
      "error": rejected ? .object(["code": .string("INVALID_REQUEST"), "message": .string("Denied")]) : .null]))
  }
  func receive() async throws -> Data {
    if !frames.isEmpty { return frames.removeFirst() }
    if closed { throw OpenClawGatewayClientError.connectionClosed }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }
  func close() async { closed = true; waiter?.resume(throwing: OpenClawGatewayClientError.connectionClosed); waiter = nil }
  private func push(_ value: GatewayJSONValue) throws {
    let data = try JSONEncoder().encode(value)
    if let waiter { self.waiter = nil; waiter.resume(returning: data) } else { frames.append(data) }
  }
}
