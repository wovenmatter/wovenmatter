import CryptoKit
import XCTest
import WovenMatterShared
@testable import LibraryClient

/// One in-process socket: the test plays the server.
actor FakeStreamSocket: StreamTransport {
  private(set) var sent: [StreamFrame] = []
  private(set) var pings = 0
  private(set) var closedWith: StreamProtocol.CloseCode?
  private var inbox: [Result<StreamFrame, any Error>] = []
  private var receiver: CheckedContinuation<StreamFrame, any Error>?
  private var closed = false
  var failPings = false

  func receive() async throws -> StreamFrame {
    if !inbox.isEmpty { return try inbox.removeFirst().get() }
    if closed { throw StreamTransportClosed() }
    return try await withCheckedThrowingContinuation { receiver = $0 }
  }
  func send(_ frame: StreamFrame) throws {
    guard !closed else { throw StreamTransportClosed() }
    sent.append(frame)
  }
  func ping() throws {
    pings += 1
    if failPings { throw StreamTransportClosed() }
  }
  func close(_ code: StreamProtocol.CloseCode) { closedWith = closedWith ?? code; serverClose(code: code.rawValue) }

  func push(_ frame: StreamFrame) { deliver(.success(frame)) }
  /// The server closes the socket with `code`.
  func serverClose(code: Int?) {
    guard !closed else { return }
    closed = true
    deliver(.failure(StreamTransportClosed(code: code)))
  }
  func setFailPings(_ value: Bool) { failPings = value }
  private func deliver(_ result: Result<StreamFrame, any Error>) {
    if let receiver { self.receiver = nil; receiver.resume(with: result) } else { inbox.append(result) }
  }

  var subscriptions: [StreamSubscribe] { sent.compactMap { if case .subscribe(let value) = $0 { value } else { nil } } }
  var requests: [StreamRequest] { sent.compactMap { if case .request(let value) = $0 { value } else { nil } } }
  var cancels: [String] { sent.compactMap { if case .cancel(let value) = $0 { value.id } else { nil } } }
}

/// Hands out a new socket per attempt, or a queued refusal.
final class FakeStreamServer: @unchecked Sendable {
  private let lock = NSLock()
  private var _sockets: [FakeStreamSocket] = []
  private var _refusals: [any Error] = []
  private var _delays: [Duration] = []
  var sockets: [FakeStreamSocket] { lock.withLock { _sockets } }
  var attempts: Int { lock.withLock { _sockets.count + _refused } }
  private var _refused = 0
  var delays: [Duration] { lock.withLock { _delays } }

  func refuse(_ error: any Error) { lock.withLock { _refusals.append(error) } }
  func connect() throws -> any StreamTransport {
    try lock.withLock {
      if !_refusals.isEmpty { _refused += 1; throw _refusals.removeFirst() }
      let socket = FakeStreamSocket()
      _sockets.append(socket)
      return socket
    }
  }
  func recordDelay(_ delay: Duration) { lock.withLock { _delays.append(delay) } }

  func connection(pingInterval: Duration = .seconds(3600), requestTimeout: Duration = .seconds(5)) -> StreamConnection {
    StreamConnection(configuration: .init(pingInterval: pingInterval, pongTimeout: .seconds(1), requestTimeout: requestTimeout,
      openWait: .seconds(2), retrySleep: { [weak self] delay in self?.recordDelay(delay); await Task.yield() }, random: { 0.5 })) { [weak self] in
      guard let self else { throw StreamTransportClosed() }
      return try self.connect()
    }
  }
}

/// Records what a subscription received.
final class StreamEvents: @unchecked Sendable {
  private let lock = NSLock()
  private var _events: [StreamSubscriptionEvent] = []
  var events: [StreamSubscriptionEvent] { lock.withLock { _events } }
  var kinds: [String] { events.map { if case .item(let item) = $0 { item.payload.kind } else { "ended" } } }
  var disposition: @Sendable (StreamItem) -> StreamItemDisposition = { _ in .accepted }
  func handler() -> StreamConnection.Handler {
    { [self] event in
      lock.withLock { _events.append(event) }
      if case .item(let item) = event { return disposition(item) }
      return .accepted
    }
  }
}

func eventually(_ message: String = "condition", timeout: Duration = .seconds(3), _ condition: () async -> Bool,
                file: StaticString = #filePath, line: UInt = #line) async {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
  XCTFail("Timed out waiting for \(message)", file: file, line: line)
}

let streamHello = StreamHello(deviceID: "6f1c2a8e-58a4-4d0e-9b6b-1b2e3c4d5e6f", libraryID: "library", workspaceID: "linux",
                              serverTime: 1_762_905_600_000, capabilities: [StreamProtocol.capability])

func journalItem(_ id: String, _ sequence: Int64, workspace: String = "linux", conversation: String = "chat") -> StreamFrame {
  .item(.init(id: id, seq: sequence, payload: .journal(.init(entry: .init(eventID: "event-\(sequence)", workspaceID: workspace,
    originSequence: sequence, conversationID: conversation, kind: .conversation, conversation: .init(id: conversation, title: "Version \(sequence)"))))))
}

final class StreamConnectionTests: XCTestCase {
  private func open(_ server: FakeStreamServer, _ connection: StreamConnection, socket index: Int = 0) async -> FakeStreamSocket {
    await eventually("socket \(index)") { server.sockets.count > index }
    let socket = server.sockets[index]
    await socket.push(.hello(streamHello))
    await eventually("open") { await connection.isOpen }
    return socket
  }

  func testHelloOpensTheConnectionBeforeAnySubscriptionIsSent() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    let events = StreamEvents()
    await connection.subscribe(.workspace, params: .init(after: 41), handler: events.handler())
    await connection.start()
    await eventually("socket") { !server.sockets.isEmpty }
    let socket = server.sockets[0]
    try await Task.sleep(for: .milliseconds(20))
    let early = await socket.sent
    XCTAssertTrue(early.isEmpty, "Nothing is sent before hello")
    await socket.push(.hello(streamHello))
    await eventually("open") { await connection.isOpen }
    let hello = await connection.hello
    XCTAssertEqual(hello, streamHello)
    await eventually("subscription") { await !socket.subscriptions.isEmpty }
    let subscription = await socket.subscriptions[0]
    XCTAssertEqual(subscription.stream, StreamProtocol.Stream.workspace.rawValue)
    XCTAssertEqual(subscription.params.after, 41)
  }

  func testItemsArriveInOrderThenSynchronizedAndAdvanceAfter() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    let events = StreamEvents()
    let subscription = await connection.subscribe(.workspace, params: .init(after: 41), handler: events.handler())
    await connection.start()
    let socket = await open(server, connection)
    await eventually("subscribe") { await !socket.subscriptions.isEmpty }
    let id = await socket.subscriptions[0].id
    await socket.push(.item(.init(id: id, payload: .pending(.init(interactions: [])))))
    await socket.push(journalItem(id, 42))
    await socket.push(.item(.init(id: "someone-else", payload: .synchronized)))
    await socket.push(.item(.init(id: id, seq: 43, payload: .unknown(kind: "futureKind", data: .object([:])))))
    await socket.push(.item(.init(id: id, payload: .synchronized)))
    await eventually("items") { events.events.count == 4 }
    XCTAssertEqual(events.kinds, ["pending", "journal", "futureKind", "synchronized"])
    let after = await connection.parameters(subscription)?.after
    XCTAssertEqual(after, 43, "An accepted seq advances after, unknown kinds included")
  }

  func testReconnectResubscribesWithTheLatestAfterAndSignsEachAttempt() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    let events = StreamEvents()
    let conversation = StreamEvents()
    await connection.subscribe(.workspace, params: .init(after: 41), handler: events.handler())
    await connection.subscribe(.conversation, params: .init(conversationID: "chat"), handler: conversation.handler())
    await connection.start()
    let first = await open(server, connection)
    await eventually("subscribe") { await first.subscriptions.count == 2 }
    let id = await first.subscriptions[0].id
    await first.push(journalItem(id, 42))
    await eventually("journal") { events.events.count == 1 }
    await first.serverClose(code: StreamProtocol.CloseCode.goingAway.rawValue)
    let second = await open(server, connection, socket: 1)
    XCTAssertEqual(server.attempts, 2, "Each attempt opens (and signs) a new upgrade")
    await eventually("resubscribe") { await second.subscriptions.count == 2 }
    let again = await second.subscriptions
    XCTAssertEqual(again.first { $0.stream == "workspace" }?.params.after, 42)
    XCTAssertEqual(again.first { $0.stream == "conversation" }?.params, .init(conversationID: "chat"))
    XCTAssertNil(again.first { $0.stream == "conversation" }?.params.after, "A subscription without after never gains one")
    let firstIDs = Set(await first.subscriptions.map(\.id))
    XCTAssertTrue(firstIDs.isDisjoint(with: again.map(\.id)), "Wire IDs are new on every socket")
  }

  func testResyncSubscribesAgainFromTheLatestCursor() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    let events = StreamEvents()
    await connection.subscribe(.workspace, params: .init(after: 0), handler: events.handler())
    await connection.start()
    let socket = await open(server, connection)
    await eventually("subscribe") { await socket.subscriptions.count == 1 }
    let id = await socket.subscriptions[0].id
    await socket.push(journalItem(id, 1))
    await socket.push(.end(.init(id: id, error: .init(.resync, "This subscription fell behind. Subscribe again.", retryable: true))))
    await eventually("resubscribe") { await socket.subscriptions.count == 2 }
    let next = await socket.subscriptions[1]
    XCTAssertNotEqual(next.id, id)
    XCTAssertEqual(next.params.after, 1)
    XCTAssertEqual(events.kinds, ["journal"], "A resync is not an end")
    await socket.push(journalItem(id, 2))
    await socket.push(journalItem(next.id, 2))
    await eventually("item on the new subscription") { events.events.count == 2 }
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(events.events.count, 2, "Items for the old wire ID are ignored")
  }

  func testAGapResubscribesWithTheSubscribersCursor() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    let events = StreamEvents()
    events.disposition = { item in item.seq == 5 ? .resubscribe(.init(after: 3)) : .accepted }
    await connection.subscribe(.workspace, params: .init(after: 3), handler: events.handler())
    await connection.start()
    let socket = await open(server, connection)
    await eventually("subscribe") { await socket.subscriptions.count == 1 }
    let id = await socket.subscriptions[0].id
    await socket.push(journalItem(id, 5))
    await eventually("resubscribe") { await socket.subscriptions.count == 2 }
    let cancels = await socket.cancels
    XCTAssertEqual(cancels, [id])
    let next = await socket.subscriptions[1]
    XCTAssertEqual(next.params.after, 3)
  }

  func testEndWithoutResyncEndsTheSubscription() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    let events = StreamEvents()
    await connection.subscribe(.conversation, params: .init(conversationID: "gone"), handler: events.handler())
    await connection.start()
    let socket = await open(server, connection)
    await eventually("subscribe") { await socket.subscriptions.count == 1 }
    let id = await socket.subscriptions[0].id
    await socket.push(.end(.init(id: id, error: .init(.notFound, "No such session."))))
    await eventually("ended") { events.events.count == 1 }
    XCTAssertEqual(events.events, [.ended(.init(.notFound, "No such session."))])
    await socket.serverClose(code: 1001)
    let second = await open(server, connection, socket: 1)
    try await Task.sleep(for: .milliseconds(20))
    let subscriptions = await second.subscriptions
    XCTAssertTrue(subscriptions.isEmpty)
  }

  func testMemberRemovedStopsRetriesUntilTheMemberListChanges() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    await connection.start()
    let socket = await open(server, connection)
    await socket.serverClose(code: StreamProtocol.CloseCode.memberRemoved.rawValue)
    await eventually("member removed") { await connection.state == .memberRemoved }
    await connection.connectNow()
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(server.attempts, 1, "No retry after 4401, not even on wake")
    do { _ = try await connection.request("execution.receipt"); XCTFail("Expected a refusal") }
    catch { XCTAssertEqual(error as? StreamConnectionError, .memberRemoved) }
    await connection.membersChanged()
    _ = await open(server, connection, socket: 1)
    XCTAssertEqual(server.attempts, 2)
  }

  func testRequestsFailOnDisconnectAndAreNeverReplayed() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    await connection.start()
    let first = await open(server, connection)
    let call = Task { try await connection.request("execution.command", params: .object(["command": .string("x")])) }
    await eventually("request sent") { await first.requests.count == 1 }
    await first.serverClose(code: nil)
    do { _ = try await call.value; XCTFail("Expected a lost reply") }
    catch { XCTAssertEqual(error as? StreamConnectionError, .disconnected) }
    let second = await open(server, connection, socket: 1)
    try await Task.sleep(for: .milliseconds(30))
    let replayed = await second.requests
    XCTAssertTrue(replayed.isEmpty, "A call is never resent after a reconnect")
  }

  func testResponsesResolveCallsAndErrorsThrow() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    await connection.start()
    let socket = await open(server, connection)
    let receipt = LibraryCommandReceipt(commandID: "c1", deviceID: "phone", status: .accepted, conversationID: "chat")
    let ok = Task { try await connection.receipt("c1") }
    await eventually("receipt request") { await socket.requests.count == 1 }
    let first = await socket.requests[0]
    XCTAssertEqual(first.method, "execution.receipt")
    XCTAssertEqual(try first.decodeParams(StreamReceiptParams.self).commandID, "c1")
    await socket.push(.response(try .init(id: first.id, encoding: receipt)))
    let value = try await ok.value
    XCTAssertEqual(value, receipt)
    let none = Task { try await connection.receipt("c2") }
    await eventually("second request") { await socket.requests.count == 2 }
    await socket.push(.response(.init(id: await socket.requests[1].id, result: .null)))
    let missing = try await none.value
    XCTAssertNil(missing)
    let refused = Task { try await connection.receipt("c3") }
    await eventually("third request") { await socket.requests.count == 3 }
    let error = StreamError(.conflict, "The session is running.")
    await socket.push(.response(.init(id: await socket.requests[2].id, error: error)))
    do { _ = try await refused.value; XCTFail("Expected an error") }
    catch { XCTAssertEqual(error as? StreamConnectionError, .remote(.init(.conflict, "The session is running."))) }
  }

  func testATimedOutCallIsCancelledOnTheSocket() async throws {
    let server = FakeStreamServer()
    let connection = server.connection(requestTimeout: .milliseconds(50))
    await connection.start()
    let socket = await open(server, connection)
    do { _ = try await connection.request("execution.receipt"); XCTFail("Expected a timeout") }
    catch { XCTAssertEqual(error as? StreamConnectionError, .timedOut) }
    await eventually("cancel") { await socket.cancels.count == 1 }
  }

  func testALostCommandBecomesOutcomeUnknownAndIsResolvedByReceipt() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "journal.json")
    let journal = try WorkspaceJournal(file: file)
    let server = FakeStreamServer()
    let connection = server.connection()
    await connection.start()
    let first = await open(server, connection)
    let command = try await journal.rememberCommand(.init(deviceID: "phone", kind: .send, conversationID: "chat", text: "Run the tests",
      libraryID: "library", workspaceID: "linux"), workspaceID: "linux")
    let delivery = Task { try await StreamCommands.deliver(command, retrying: false, workspaceID: "linux", journal: journal, connection: connection) }
    await eventually("command sent") { await first.requests.count == 1 }
    let sent = await first.requests[0]
    XCTAssertEqual(sent.method, "execution.command")
    XCTAssertEqual(try sent.decodeParams(StreamCommandParams.self).command, command)
    await first.serverClose(code: 1006)
    do { _ = try await delivery.value; XCTFail("Expected a lost reply") }
    catch { XCTAssertEqual(error as? StreamConnectionError, .disconnected) }
    let unknown = await journal.commandRecords(workspaceID: "linux").first?.receipt?.status
    XCTAssertEqual(unknown, .outcomeUnknown)

    let second = await open(server, connection, socket: 1)
    let resolve = Task { try await StreamCommands.resolveUnknown(workspaceID: "linux", journal: journal, connection: connection) }
    await eventually("receipt request") { await second.requests.count == 1 }
    let ask = await second.requests[0]
    XCTAssertEqual(ask.method, "execution.receipt")
    let accepted = LibraryCommandReceipt(commandID: command.commandID, deviceID: "phone", status: .accepted, conversationID: "chat")
    await second.push(.response(try .init(id: ask.id, encoding: accepted)))
    let learned = try await resolve.value
    XCTAssertEqual(learned, [accepted])
    let resolved = await journal.commandRecords(workspaceID: "linux").first?.receipt
    XCTAssertEqual(resolved, accepted)
    let methods = await second.requests.map(\.method)
    XCTAssertEqual(methods, ["execution.receipt"], "The command itself is not resent")
  }

  func testARetriedCommandAsksForItsReceiptFirst() async throws {
    let file = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString).appending(path: "journal.json")
    let journal = try WorkspaceJournal(file: file)
    let server = FakeStreamServer()
    let connection = server.connection()
    await connection.start()
    let socket = await open(server, connection)
    let command = try await journal.rememberCommand(.init(deviceID: "phone", kind: .stop, conversationID: "chat", runID: "run"), workspaceID: "linux")
    let delivery = Task { try await StreamCommands.deliver(command, retrying: true, workspaceID: "linux", journal: journal, connection: connection) }
    await eventually("receipt request") { await socket.requests.count == 1 }
    let completed = LibraryCommandReceipt(commandID: command.commandID, deviceID: "phone", status: .completed)
    await socket.push(.response(try .init(id: await socket.requests[0].id, encoding: completed)))
    let receipt = try await delivery.value
    XCTAssertEqual(receipt, completed)
    let methods = await socket.requests.map(\.method)
    XCTAssertEqual(methods, ["execution.receipt"])
  }

  func testBackoffStaysWithinOneToThirtySecondsWithJitter() async throws {
    for attempt in 0...40 {
      for random in [0.0, 0.25, 0.5, 0.75, 1.0] {
        let delay = StreamConnection.retryDelay(attempt: attempt, random: random)
        XCTAssertGreaterThanOrEqual(delay, .seconds(1)); XCTAssertLessThanOrEqual(delay, .seconds(30))
      }
    }
    XCTAssertEqual(StreamConnection.retryDelay(attempt: 0, random: 0.5), .seconds(1))
    XCTAssertEqual(StreamConnection.retryDelay(attempt: 3, random: 0.5), .seconds(8))
    XCTAssertEqual(StreamConnection.retryDelay(attempt: 20, random: 0.5), .seconds(30))
    XCTAssertEqual(StreamConnection.retryDelay(attempt: 3, random: 0), .seconds(6))
    XCTAssertEqual(StreamConnection.retryDelay(attempt: 3, random: 1), .seconds(10))

    let server = FakeStreamServer()
    for _ in 0..<7 { server.refuse(StreamConnectionError.unauthorized) }
    let connection = server.connection()
    await connection.start()
    _ = await open(server, connection)
    XCTAssertEqual(server.delays, [1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    let state = await connection.state
    XCTAssertEqual(state, .open(streamHello), "Hello resets the backoff")
  }

  func testWakeTriesAtOnceAndAStaleClockIsReportedDistinctly() async throws {
    let server = FakeStreamServer()
    server.refuse(StreamConnectionError.memberTimeStale(serverTime: 1))
    let connection = StreamConnection(configuration: .init(retrySleep: { _ in try await Task.sleep(for: .seconds(3600)) })) {
      try server.connect()
    }
    await connection.start()
    await eventually("waiting") { await connection.state == .waiting(.memberTimeStale(serverTime: 1)) }
    XCTAssertEqual(StreamConnectionError.memberTimeStale(serverTime: 1).localizedDescription,
                   "This device's clock is wrong. Set the date and time automatically, then try again.")
    await connection.connectNow()
    _ = await open(server, connection)
    XCTAssertEqual(server.attempts, 2)
  }

  func testPingsKeepTheSocketAndAMissingPongReconnects() async throws {
    let server = FakeStreamServer()
    let connection = server.connection(pingInterval: .milliseconds(20))
    await connection.start()
    let socket = await open(server, connection)
    await eventually("pings") { await socket.pings >= 2 }
    await socket.setFailPings(true)
    _ = await open(server, connection, socket: 1)
  }

  func testStopClosesCleanlyAndStartResumesSubscriptions() async throws {
    let server = FakeStreamServer()
    let connection = server.connection()
    await connection.subscribe(.workspace, params: .init(after: 7), handler: StreamEvents().handler())
    await connection.start()
    let socket = await open(server, connection)
    await connection.stop()
    let code = await socket.closedWith
    XCTAssertEqual(code, .normal)
    let state = await connection.state
    XCTAssertEqual(state, .idle)
    try await Task.sleep(for: .milliseconds(20))
    XCTAssertEqual(server.attempts, 1, "A stopped connection stays closed")
    await connection.start()
    let resumed = await open(server, connection, socket: 1)
    await eventually("resubscribe") { await resumed.subscriptions.count == 1 }
    let after = await resumed.subscriptions[0].params.after
    XCTAssertEqual(after, 7)
  }

  func testRefusalsBeforeTheUpgrade() throws {
    let stale = Data(#"{"code":"member_time_stale","message":"Clock","serverTime":1762905600000}"#.utf8)
    XCTAssertEqual(StreamConnectionError.refusal(status: 401, body: stale), .memberTimeStale(serverTime: 1_762_905_600_000))
    XCTAssertEqual(StreamConnectionError.refusal(status: 401, body: Data(#"{"code":"unauthorized","message":"No"}"#.utf8)), .unauthorized)
    XCTAssertEqual(StreamConnectionError.refusal(status: 426, body: Data(#"{"code":"protocol_unsupported","supported":[1]}"#.utf8)),
                   .protocolUnsupported(supported: [1]))
    // URLSessionWebSocketTask exposes headers but not the body.
    let now = Date(timeIntervalSince1970: 1_762_905_600)
    XCTAssertEqual(StreamConnectionError.refusal(status: 401, headers: ["date": "Wed, 12 Nov 2025 00:10:00 GMT"], now: now),
                   .memberTimeStale(serverTime: 1_762_906_200_000))
    XCTAssertEqual(StreamConnectionError.refusal(status: 401, headers: ["Date": "Wed, 12 Nov 2025 00:01:00 GMT"], now: now), .unauthorized)
    XCTAssertEqual(StreamConnectionError.refusal(status: 401, headers: ["X-Woven-Error": "member_time_stale"], now: now), .memberTimeStale(serverTime: nil))
    XCTAssertEqual(StreamConnectionError.refusal(status: 403), .refused(status: 403, code: nil, message: nil))
  }

  func testEveryUpgradeIsSignedAfreshForItsExactTarget() async throws {
    let key = Curve25519.Signing.PrivateKey()
    let signer = MemberRequestSigner(deviceID: "6F1C2A8E-58A4-4D0E-9B6B-1B2E3C4D5E6F", key: key)
    let audience = "4a5b6c7d-8e9f-4a0b-9c1d-2e3f4a5b6c7d"
    let mac = try StreamEndpoint.url(for: URL(string: "https://studio.example.ts.net:8443/wovenmatter")!)
    XCTAssertEqual(mac.absoluteString, "wss://studio.example.ts.net:8443/wovenmatter/v1/stream?protocol=1")
    let linux = try StreamEndpoint.url(for: URL(string: "https://server.example.ts.net/wovenmatter-execution/abc/")!)
    XCTAssertEqual(linux.absoluteString, "wss://server.example.ts.net/wovenmatter-execution/abc/v1/stream?protocol=1")
    XCTAssertThrowsError(try StreamEndpoint.url(for: URL(string: "https://example.com/wovenmatter")!))
    XCTAssertThrowsError(try StreamEndpoint.url(for: URL(string: "http://studio.example.ts.net/wovenmatter")!))

    let authorize: WebSocketStreamTransport.Authorize = { url in try StreamEndpoint.signedHeaders(for: url, signer: signer, audience: audience) }
    let first = try await WebSocketStreamTransport.request(url: mac, headers: ["X-Woven-Workspace": "mac"], authorize: authorize)
    let second = try await WebSocketStreamTransport.request(url: mac, headers: ["X-Woven-Workspace": "mac"], authorize: authorize)
    let nonce = MemberRequestSignature.nonceHeader
    XCTAssertNotNil(first.value(forHTTPHeaderField: nonce))
    XCTAssertNotEqual(first.value(forHTTPHeaderField: nonce), second.value(forHTTPHeaderField: nonce))
    XCTAssertEqual(first.value(forHTTPHeaderField: "X-Woven-Workspace"), "mac")
    XCTAssertEqual(first.value(forHTTPHeaderField: MemberRequestSignature.audienceHeader), audience)
    XCTAssertNil(first.value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(StreamEndpoint.target(of: mac), "/wovenmatter/v1/stream?protocol=1")
    // The signature covers GET, the target with its query and an empty body.
    let time = Int64(first.value(forHTTPHeaderField: MemberRequestSignature.timeHeader)!)!
    let message = MemberRequestSignature.message(audience: audience, method: "GET", target: "/wovenmatter/v1/stream?protocol=1",
      time: time, nonce: first.value(forHTTPHeaderField: nonce)!, bodySHA256: MemberRequestSignature.bodyHash(Data()))
    let signature = MemberRequestSignature.decodeBase64URL(first.value(forHTTPHeaderField: MemberRequestSignature.signatureHeader)!)!
    XCTAssertTrue(key.publicKey.isValidSignature(signature, for: message))
  }

  func testTranscriptUpdatesReplaceEntitiesByID() {
    let current = LibraryTranscript(conversationID: "chat", messages: [
      .init(id: "m1", conversationID: "chat", role: "user", content: "Run the tests"),
      .init(id: "m2", conversationID: "chat", role: "assistant", content: "All 214 tests pass so f"),
      .init(id: "t1", conversationID: "chat", role: "tool", content: "npm test"),
    ], activities: [.init(id: "a1", runID: "run", title: "npm test", status: "running")], activeRunID: "run", olderCursor: "owner:c-20",
      runs: [.init(id: "run", status: "running")])
    let update = StreamTranscript(transcript: .init(conversationID: "chat", messages: [
      .init(id: "m2", conversationID: "chat", role: "assistant", content: "All 214 tests pass so far."),
      .init(id: "m3", conversationID: "chat", role: "assistant", content: "Done."),
    ], activities: [.init(id: "a1", runID: "run", title: "npm test", status: "completed")], activeRunID: nil,
      runs: [.init(id: "run", status: "completed")], removedMessageIDs: ["t1", "m1"]), snapshot: false)
    let next = current.applying(update)
    XCTAssertEqual(next.messages.map(\.id), ["m1", "m2", "m3"], "User messages are never removed")
    XCTAssertEqual(next.messages[1].content, "All 214 tests pass so far.")
    XCTAssertEqual(next.activities.map(\.status), ["completed"])
    XCTAssertEqual(next.runs, [.init(id: "run", status: "completed")])
    XCTAssertNil(next.activeRunID)
    XCTAssertEqual(next.olderCursor, "owner:c-20")
    let snapshot = StreamTranscript(transcript: .init(conversationID: "chat", olderCursor: "c-30"), snapshot: true)
    XCTAssertEqual(current.applying(snapshot), snapshot.transcript)
  }
}

/// The fixture file the Swift and Node suites share, decoded through this client's own path.
final class StreamFixtureDecodingTests: XCTestCase {
  private struct Fixtures: Decodable {
    struct Named: Decodable { let name: String; let frame: GatewayJSONValue }
    struct Prefixed: Decodable { let frame: GatewayJSONValue; let hex: String }
    let frames: [Named]
    let unknownFrames: [GatewayJSONValue]
    let lengthPrefixed: Prefixed
  }
  private func fixtures() throws -> Fixtures {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appending(path: "shared/Tests/WovenMatterSharedTests/StreamProtocolFixtures.json")
    return try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
  }
  private func object(_ data: Data) throws -> NSObject {
    try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as! NSObject
  }

  func testEveryFixtureFrameDecodesThroughTheWebSocketPath() throws {
    let fixtures = try fixtures()
    XCTAssertFalse(fixtures.frames.isEmpty)
    for fixture in fixtures.frames {
      let text = String(decoding: try JSONEncoder().encode(fixture.frame), as: UTF8.self)
      let frame = try WebSocketStreamTransport.decode(.string(text))
      if case .unknown = frame { XCTFail("\(fixture.name) decoded as unknown") }
      let binary = try WebSocketStreamTransport.decode(.data(Data(text.utf8)))
      XCTAssertEqual(frame, binary, fixture.name)
      XCTAssertEqual(try object(StreamProtocol.encode(frame)), try object(Data(text.utf8)), fixture.name)
    }
    for frame in fixtures.unknownFrames {
      let decoded = try WebSocketStreamTransport.decode(.string(String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)))
      XCTAssertEqual(decoded, .unknown("futureFrame"))
    }
  }

  func testTheLengthPrefixedFixtureDecodesThroughTheByteChannelPath() async throws {
    let fixtures = try fixtures()
    let hex = fixtures.lengthPrefixed.hex
    let bytes = Data(stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
      let start = hex.index(hex.startIndex, offsetBy: offset)
      return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    })
    // Delivered in uneven pieces, as a socket may.
    let channel = MemoryByteChannel(reads: [bytes.prefix(3), bytes.dropFirst(3).prefix(10), bytes.dropFirst(13)].map { Data($0) })
    let transport = LengthPrefixedStreamTransport(channel: channel)
    let frame = try await transport.receive()
    XCTAssertEqual(frame, .cancel(.init(id: "s2")))
    try await transport.send(frame)
    let written = await channel.written
    XCTAssertEqual(written, [bytes])
    do { _ = try await transport.receive(); XCTFail("Expected the end of the stream") }
    catch { XCTAssertTrue(error is StreamTransportClosed) }
  }
}

actor MemoryByteChannel: StreamByteChannel {
  private var reads: [Data]
  private(set) var written: [Data] = []
  init(reads: [Data]) { self.reads = reads }
  func read() -> Data? { reads.isEmpty ? nil : reads.removeFirst() }
  func write(_ data: Data) { written.append(data) }
  func close() { reads = [] }
}
