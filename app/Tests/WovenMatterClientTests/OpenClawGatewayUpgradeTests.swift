import CryptoKit
import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterClient

struct OpenClawGatewayUpgradeTests {
  private let endpoint = OpenClawGatewayEndpoint(url: URL(string: "ws://127.0.0.1:1")!, authorization: .localService)

  @Test func gatewayPersistsIdentityAndTokenWithoutMethodAllowlist() async throws {
    let store = GatewayMemoryCredentials()
    let first = GatewayFixtureSocket()
    let client = OpenClawGatewayClient(endpoint: endpoint, credentialStore: store, socketFactory: { _ in first })
    _ = try await client.connect()
    // Intentionally absent from hello.features.methods.
    #expect(try await client.request("question.list") == .object(["questions": .array([])]))
    let identity = await first.connectParams
    await client.disconnect()
    let second = GatewayFixtureSocket()
    let reopened = OpenClawGatewayClient(endpoint: endpoint, credentialStore: store, socketFactory: { _ in second })
    _ = try await reopened.connect()
    #expect(await second.connectParams?.objectValue?["device"]?.objectValue?["id"] == identity?.objectValue?["device"]?.objectValue?["id"])
    #expect(await second.connectParams?.objectValue?["auth"]?.objectValue?["token"] == .string("fixture-device-token"))
    await reopened.disconnect()
  }

  @Test func gatewayChallengeWaitIsBounded() async throws {
    let socket = GatewayFixtureSocket(challenge: false)
    let client = OpenClawGatewayClient(endpoint: endpoint, credentialStore: GatewayMemoryCredentials(),
      handshakeTimeout: .milliseconds(20), socketFactory: { _ in socket })
    do { _ = try await client.connect(); Issue.record("Silent socket connected") } catch { }
    #expect(await socket.closed)
    await client.disconnect()
  }

  @Test func gatewaySequenceDuplicatesAreIgnoredAndGapsCloseSocket() async throws {
    let socket = GatewayFixtureSocket()
    let events = GatewayEventRecorder()
    let client = OpenClawGatewayClient(endpoint: endpoint, credentialStore: GatewayMemoryCredentials(),
      socketFactory: { _ in socket }, eventHandler: { await events.append($0) })
    _ = try await client.connect()
    for sequence in [10, 10, 11, 13] {
      try await socket.push(.object(["type": .string("event"), "event": .string("chat"), "seq": .number(Double(sequence))]))
    }
    for _ in 0..<100 where !(await socket.closed) { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await socket.closed)
    #expect(await events.sequences == [10, 11])
    await client.disconnect()
  }

  @Test func gatewayHistoryDoesNotTreatMissingLivenessAsIdle() throws {
    let unknown = try OpenClawGatewayHistory(payload: .object(["messages": .array([])]))
    #expect(!unknown.isIdle)
    let idle = try OpenClawGatewayHistory(payload: .object(["messages": .array([]), "sessionInfo": .object(["activeRunIds": .array([])])]))
    #expect(idle.isIdle)
    let active = try OpenClawGatewayHistory(payload: .object(["messages": .array([]), "sessionInfo": .object([
      "hasActiveRun": .bool(true), "activeRunIds": .array([])])]))
    #expect(!active.isIdle)
  }

  @Test func gatewayHistoryPreservesRawMediaAndNativeAgentIdentity() throws {
    let payload: GatewayJSONValue = .object(["role": .string("assistant"), "__openclaw": .object([
      "id": .string("record-1"), "idempotencyKey": .string("run-1:assistant-media")]), "content": .array([
      .object(["type": .string("image"), "artifactId": .string("private-artifact")])])])
    let message = try #require(OpenClawGatewayHistoryMessage(payload: payload))
    #expect(message.runID == "run-1")
    #expect(message.text.contains("Control UI"))
    #expect(try JSONDecoder().decode(GatewayJSONValue.self, from: message.raw) == payload)
    #expect(OpenClawGatewaySession.agentID(for: "agent:eddie:shared") == "eddie")
    #expect(OpenClawGatewaySession.agentID(for: "global") == nil)
  }

  @Test(arguments: ["javascript:alert(1)", "https://example.com/?token=secret", "https://user:pass@example.com", "https://example.com/#token=secret"])
  func gatewayBrowserLinksNeverCarryAuthentication(_ value: String) {
    #expect(OpenClawGatewayControls.safeControlUIURL(URL(string: value)) == nil)
  }

  @Test func gatewayNumbersCannotTrapDuringDecode() {
    #expect(GatewayJSONValue.number(.infinity).intValue == nil)
    #expect(GatewayJSONValue.number(Double.greatestFiniteMagnitude).intValue == nil)
  }

  @Test func gatewayHistoryKeepsSiblingRowsAndFailureEvidence() throws {
    let row: GatewayJSONValue = .object(["role": .string("assistant"),
      "__openclaw": .object(["id": .string("shared-record")]),
      "stopReason": .string("error"), "errorMessage": .string("Provider unavailable")])
    var sibling = row.objectValue!
    sibling["content"] = .string("Second projected row")
    let history = try OpenClawGatewayHistory(payload: .object(["messages": .array([row, .object(sibling)])]))
    #expect(history.messages.count == 2)
    #expect(history.messages[0].id != history.messages[1].id)
    #expect(history.messages[0].terminalError == "Provider unavailable")
    let tail = try OpenClawGatewayHistory(payload: .object(["messages": .array([.object(sibling)])]))
    #expect(tail.messages[0].id == history.messages[1].id)
  }

  @Test func gatewayExplicitDisconnectCannotBeReopenedByStaleCaller() async throws {
    let socket = GatewayFixtureSocket()
    let client = OpenClawGatewayClient(endpoint: endpoint, credentialStore: GatewayMemoryCredentials(), socketFactory: { _ in socket })
    _ = try await client.connect()
    await client.disconnect()
    do { _ = try await client.request("sessions.patch"); Issue.record("Retired client reopened") }
    catch OpenClawGatewayClientError.connectionClosed { }
    #expect(await socket.starts == 1)
  }

  @Test func gatewayDecisionCannotCrossSocketReconnect() async throws {
    let first = GatewayFixtureSocket(), second = GatewayFixtureSocket()
    let pool = GatewaySocketPool([first, second])
    let client = OpenClawGatewayClient(endpoint: endpoint, credentialStore: GatewayMemoryCredentials(), socketFactory: { _ in pool.next() })
    _ = try await client.connect()
    let oldGeneration = try #require(await client.connectedGeneration)
    await first.close()
    for _ in 0..<100 where await client.connectedGeneration != nil { try await Task.sleep(for: .milliseconds(5)) }
    _ = try await client.connect()
    #expect(await client.connectedGeneration != oldGeneration)
    do {
      _ = try await client.request("approval.resolve", expectedConnectionGeneration: oldGeneration)
      Issue.record("A decision crossed a socket reconnect")
    } catch OpenClawGatewayClientError.rejected { }
    #expect(await second.methods == ["connect"])
    await client.disconnect()
  }

  @Test func gatewayMultiSelectRetainsChoicesAlongsideOtherText() {
    let question: GatewayJSONValue = .object(["questionId": .string("choice"), "multiSelect": .bool(true), "isOther": .bool(true),
      "options": .array([.object(["label": .string("A")])])])
    #expect(OpenClawQuestionAnswers.resolve(questions: [question], selected: ["choice": ["A"]], freeText: ["choice": "B"]) == ["choice": ["A", "B"]])
  }
}

private final class GatewayMemoryCredentials: OpenClawGatewayCredentialStore, @unchecked Sendable {
  private let lock = NSLock()
  private var records: [String: OpenClawGatewayCredentials] = [:]
  func credentials(for scope: String) throws -> OpenClawGatewayCredentials {
    lock.withLock {
      if let value = records[scope] { return value }
      let value = OpenClawGatewayCredentials(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
      records[scope] = value; return value
    }
  }
  func save(_ value: OpenClawGatewayCredentials, for scope: String) throws { lock.withLock { records[scope] = value } }
}

private actor GatewayEventRecorder {
  var sequences: [Int] = []
  func append(_ event: OpenClawGatewayEvent) { if let seq = event.sequence { sequences.append(seq) } }
}

private actor GatewayFixtureSocket: OpenClawGatewaySocket {
  let challenge: Bool
  var closed = false
  var connectParams: GatewayJSONValue?
  var starts = 0
  var methods: [String] = []
  private var frames: [Data] = []
  private var waiter: CheckedContinuation<Data, any Error>?
  init(challenge: Bool = true) { self.challenge = challenge }
  func start() async {
    starts += 1
    if challenge { try? push(.object(["type": .string("event"), "event": .string("connect.challenge"),
      "payload": .object(["nonce": .string("test-nonce"), "ts": .number(1_700_000_000_000)])])) }
  }
  func send(_ data: Data) async throws {
    let row = try JSONDecoder().decode(GatewayJSONValue.self, from: data).objectValue ?? [:]
    methods.append(row["method"]?.stringValue ?? "")
    let result: GatewayJSONValue
    if row["method"] == .string("connect") {
      connectParams = row["params"]
      result = .object(["protocol": .number(4), "features": .object(["methods": .array([])]),
        "auth": .object(["deviceToken": .string("fixture-device-token")])])
    } else { result = .object(["questions": .array([])]) }
    try push(.object(["type": .string("res"), "id": row["id"] ?? .null, "ok": .bool(true), "payload": result]))
  }
  func receive() async throws -> Data {
    if !frames.isEmpty { return frames.removeFirst() }
    if closed { throw OpenClawGatewayClientError.connectionClosed }
    return try await withCheckedThrowingContinuation { waiter = $0 }
  }
  func close() async {
    closed = true; waiter?.resume(throwing: OpenClawGatewayClientError.connectionClosed); waiter = nil
  }
  func push(_ value: GatewayJSONValue) throws {
    let data = try JSONEncoder().encode(value)
    if let waiter { self.waiter = nil; waiter.resume(returning: data) }
    else { frames.append(data) }
  }
}

private final class GatewaySocketPool: @unchecked Sendable {
  private let lock = NSLock()
  private var sockets: [GatewayFixtureSocket]
  init(_ sockets: [GatewayFixtureSocket]) { self.sockets = sockets }
  func next() -> GatewayFixtureSocket { lock.withLock { sockets.removeFirst() } }
}
