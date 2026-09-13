import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient
@testable import WovenMatterDashboardStore

struct OpenClawGatewayReviewTests {
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

  @Test func modelDiscoveryUsesTheImportedSessionAndPreparedDetails() async throws {
    let fixture = try ReviewGatewayFixture()
    defer { fixture.remove() }
    let id = try fixture.database.importOpenClawGatewaySession(agentID: fixture.agentID, session: fixture.session)
    _ = try await fixture.coordinator.sessionMetadata(conversationID: id)
    let params = try #require(await fixture.socket.modelParameters?.objectValue)
    #expect(params["sessionKey"] == .string("agent:eddie:shared"))
    #expect(params["agentId"] == .string("eddie"))
    #expect(params["preparedOnly"] == .bool(true))
    #expect(params["includeDetails"] == .bool(true))
    #expect(params["refresh"] == nil)
    await fixture.coordinator.shutdown()
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

  init(denyHistory: Bool = false) throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    database = try WorkspaceDatabase(url: directory.appending(path: "review.sqlite"))
    _ = try database.createLocalACPSession(runtimeKind: .openclaw, title: "Seed", ownerDeviceID: UUID())
    agentID = try #require(database.dashboardAgents().first).id
    let endpoint = OpenClawGatewayEndpoint(url: URL(string: "ws://127.0.0.1:1")!, authorization: .localService)
    try database.saveOpenClawGatewayLink(OpenClawGatewayLink(agentID: agentID, location: .localAgentWorkspace, endpoint: endpoint))
    session = try #require(OpenClawGatewaySession(payload: .object(["key": .string("agent:eddie:shared") ])))
    socket = ReviewGatewaySocket(denyHistory: denyHistory)
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
  var modelParameters: GatewayJSONValue?
  var creationParameters: GatewayJSONValue?
  var historyCalls = 0
  private var frames: [Data] = []
  private var waiter: CheckedContinuation<Data, any Error>?
  private var closed = false
  init(denyHistory: Bool) {
    self.denyHistory = denyHistory
  }
  func start() async {
    try? push(.object(["type": .string("event"), "event": .string("connect.challenge"),
      "payload": .object(["nonce": .string("fixture"), "ts": .number(1_700_000_000_000)])]))
  }
  func send(_ data: Data) async throws {
    let row = try JSONDecoder().decode(GatewayJSONValue.self, from: data).objectValue ?? [:]
    let method = row["method"]?.stringValue ?? ""
    let rejected = (method == "chat.history" && denyHistory)
      || (row["params"]?.objectValue?["includeApprovals"] == .bool(true))
    if method == "chat.history" { historyCalls += 1 }
    if method == "models.list" { modelParameters = row["params"] }
    if method == "sessions.create" { creationParameters = row["params"] }
    let payload: GatewayJSONValue
    switch method {
    case "connect": payload = .object(["protocol": .number(4)])
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
