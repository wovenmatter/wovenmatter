import XCTest
import LibraryClient
import WovenMatterShared
@testable import WovenMatterMobileApp

/// The library host's mobile API, counting every live read the phone makes.
private actor CountingLibrary: OfflineLibraryTransport {
  private(set) var transcripts = 0, pendingReads = 0, providerReads = 0, receiptReads = 0, changeReads = 0
  /// The host's library change cursor, as `GET v1/changes` reports it.
  private var latestCursor: Int64 = 1
  func setCursor(_ value: Int64) { latestCursor = value }
  func workspaceIdentity() async throws -> String { "library-a" }
  func snapshot() async throws -> LibrarySnapshot { .init(workspaceID: "library-a", cursor: latestCursor) }
  func changes(after: Int64) async throws -> LibraryChangePage { changeReads += 1; return .init(workspaceID: "library-a", cursor: max(after, latestCursor)) }
  func providers() async throws -> [HarnessCapabilities] {
    providerReads += 1
    return [.init(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true)]
  }
  func pending() async throws -> [PendingInteraction] { pendingReads += 1; return [] }
  func transcript(_ id: String) async throws -> LibraryTranscript { transcripts += 1; return .init(conversationID: id) }
  func receipt(_ id: String) async throws -> LibraryCommandReceipt? { receiptReads += 1; return nil }
  private(set) var detailReads: [String] = []
  func activityDetails(_ id: String, runID: String, activityID: String) async throws -> LibraryActivity {
    detailReads.append(runID + "/" + activityID)
    return .init(id: activityID, runID: runID, title: "Read file", status: "completed",
                 projectionJSON: #"{"id":"a1","kind":"tool","title":"Read file","content":"The whole file","locations":[],"changes":[],"planEntries":[]}"#)
  }
  var liveReads: Int { transcripts + pendingReads + receiptReads }
}

/// A Mac's execution routes, recording each path the phone asked for.
private final class RecordingWorkspaceHTTP: MobileHTTPPerforming, @unchecked Sendable {
  private let lock = NSLock()
  private var workspaces: [String: ExecutionWorkspace] = [:]
  private var recorded: [String] = []
  func serve(_ workspace: ExecutionWorkspace) { lock.withLock { workspaces[workspace.endpoint?.host ?? ""] = workspace } }
  var paths: [String] { lock.withLock { recorded } }
  func paths(host: String) -> [String] { lock.withLock { recorded.filter { $0.hasPrefix(host) } } }
  func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
    let host = request.url?.host ?? "", path = request.url?.path ?? ""
    let workspace = lock.withLock { recorded.append(host + path); return workspaces[host] }
    let body: Data
    switch path {
    case "/wovenmatter/v1/execution": body = try JSONEncoder().encode(workspace)
    case "/wovenmatter/v1/execution/events": body = try JSONEncoder().encode(ExecutionJournalPage(libraryID: workspace?.libraryID ?? "", cursor: 0))
    case "/wovenmatter/v1/execution/providers":
      body = try JSONEncoder().encode([HarnessCapabilities(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true)])
    default: body = Data("[]".utf8)
    }
    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
  }
}

/// One in-process socket; the test plays the Mac's stream server.
private actor TestSocket: StreamTransport {
  private(set) var sent: [StreamFrame] = []
  private(set) var closedWith: StreamProtocol.CloseCode?
  private(set) var pings = 0
  private var inbox: [Result<StreamFrame, any Error>] = []
  private var receiver: CheckedContinuation<StreamFrame, any Error>?
  private var closed = false
  func receive() async throws -> StreamFrame {
    if !inbox.isEmpty { return try inbox.removeFirst().get() }
    if closed { throw StreamTransportClosed() }
    return try await withCheckedThrowingContinuation { receiver = $0 }
  }
  func send(_ frame: StreamFrame) throws { guard !closed else { throw StreamTransportClosed() }; sent.append(frame) }
  func ping() { pings += 1 }
  func close(_ code: StreamProtocol.CloseCode) { closedWith = closedWith ?? code; serverClose(code: code.rawValue) }
  func push(_ frame: StreamFrame) { deliver(.success(frame)) }
  func serverClose(code: Int?) {
    guard !closed else { return }
    closed = true; deliver(.failure(StreamTransportClosed(code: code)))
  }
  private func deliver(_ result: Result<StreamFrame, any Error>) {
    if let receiver { self.receiver = nil; receiver.resume(with: result) } else { inbox.append(result) }
  }
  var subscriptions: [StreamSubscribe] { sent.compactMap { if case .subscribe(let value) = $0 { value } else { nil } } }
  var cancels: [String] { sent.compactMap { if case .cancel(let value) = $0 { value.id } else { nil } } }
}

/// Hands out a socket per attempt, or a queued refusal.
private final class TestStreamServer: @unchecked Sendable {
  private let lock = NSLock()
  private var _sockets: [TestSocket] = []
  private var _refusals: [any Error] = []
  private var _attempts = 0
  var sockets: [TestSocket] { lock.withLock { _sockets } }
  var attempts: Int { lock.withLock { _attempts } }
  func refuse(_ error: any Error) { lock.withLock { _refusals.append(error) } }
  var connect: StreamConnection.Connect {
    { [self] in
      try lock.withLock {
        _attempts += 1
        if !_refusals.isEmpty { throw _refusals.removeFirst() }
        let socket = TestSocket(); _sockets.append(socket); return socket
      }
    }
  }
}

@MainActor private func waitUntil(_ message: String, timeout: Duration = .seconds(5), _ condition: () async -> Bool,
                                  file: StaticString = #filePath, line: UInt = #line) async {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(10))
  }
  XCTFail("Timed out waiting for \(message)", file: file, line: line)
}

/// The iPhone streams the library host Mac's own sessions (the central
/// route), and nothing polls an execution workspace.
final class CentralStreamTests: XCTestCase {
  private let hostDevice = "a0000000-0000-0000-0000-00000000000a"
  private let miniDevice = "b0000000-0000-0000-0000-00000000000b"

  private struct Fixture {
    let model: MobileModel
    let library: CountingLibrary
    let http: RecordingWorkspaceHTTP
    let server: TestStreamServer
    let studio: ExecutionWorkspace
    let mini: ExecutionWorkspace
    let root: URL
  }

  /// A phone in member mode that syncs with Studio, which streams, beside Mini, which does not.
  @MainActor private func makeFixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library-a")
    try await store.apply(LibrarySnapshot(workspaceID: "library-a", cursor: 1, folders: [], notes: [], conversations: [
      .init(id: "central-chat", title: "Release plan", providerID: "local:codex", runtimeKind: "codex"),
    ]))
    let library = CountingLibrary()
    let model = MobileModel(store: store, transport: library)
    await model.reload()
    model.credential = .init(endpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!, workspaceID: "library-a",
                             deviceID: model.state.deviceID, token: "synthetic-test-token")
    let studio = ExecutionWorkspace(id: "11111111-1111-4111-8111-111111111111", libraryID: "library-a", ownerDeviceID: hostDevice, kind: .mac,
      name: "Studio", endpoint: URL(string: "https://studio.tail1.ts.net/wovenmatter")!,
      capabilities: ["execution.v1", "history.central.v1", StreamProtocol.capability], executionDeviceID: hostDevice)
    let mini = ExecutionWorkspace(id: "22222222-2222-4222-8222-222222222222", libraryID: "library-a", ownerDeviceID: miniDevice, kind: .mac,
      name: "Mini", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter")!, capabilities: ["execution.v1", "history.central.v1"],
      executionDeviceID: miniDevice)
    try await store.journal.bind(libraryID: "library-a")
    try await store.journal.upsertWorkspace(studio, pending: false, trustedRegistry: true)
    try await store.journal.upsertWorkspace(mini, pending: false, trustedRegistry: true)
    let http = RecordingWorkspaceHTTP(); http.serve(studio); http.serve(mini)
    model.httpPerformer = http
    model.memberKeyStorage = .memory()
    let identity = try model.loadMemberIdentity()
    var membership = MobileMembershipState(deviceID: model.state.deviceID, pairedEndpoint: studio.endpoint!, pairedHostDeviceID: hostDevice)
    membership.currentHost = .init(deviceID: hostDevice, kind: "mac", name: "Studio", endpoint: studio.endpoint!)
    membership.membersRevision = "r1"
    model.libraryHosts = try MobileLibraryHosts(state: membership, identity: identity, file: nil, performer: http)
    model.membership = membership
    model.workspaceCredentials = .init(load: { _ in nil }, save: { _ in XCTFail("Saved a grant") }, clear: { _ in })
    let server = TestStreamServer()
    let studioID = studio.id
    model.streamConnector = { workspace in workspace.id == studioID ? server.connect : nil }
    return Fixture(model: model, library: library, http: http, server: server, studio: studio, mini: mini, root: root)
  }

  @MainActor private func openHost(_ fixture: Fixture, socket index: Int = 0) async -> TestSocket {
    await waitUntil("socket \(index)") { fixture.server.sockets.count > index }
    let socket = fixture.server.sockets[index]
    await socket.push(.hello(.init(deviceID: hostDevice, libraryID: "library-a", workspaceID: fixture.studio.id, serverTime: 0,
                                   capabilities: [StreamProtocol.capability])))
    await waitUntil("open") { fixture.model.workspaceReachable[fixture.studio.id] == true }
    return socket
  }

  /// A central-route chat (no workspace) is followed on the library host's
  /// stream: `workspace` and `conversation` for the open chat. Its transcript,
  /// run state, questions, capabilities and settings arrive there, and no
  /// refresh reads them over HTTP.
  @MainActor func testCentralChatsStreamFromTheLibraryHostAndNothingPollsThem() async throws {
    let fixture = try await makeFixture(); let model = fixture.model
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await model.refreshExecutionWorkspaces(force: true)
    XCTAssertEqual(model.centralExecutionWorkspace?.id, fixture.studio.id)
    XCTAssertTrue(model.streamsCentral)
    let socket = await openHost(fixture)
    await model.selectConversation("central-chat")
    XCTAssertEqual(model.selectedExecutionWorkspaceID, "central", "The chat keeps its central route")
    await waitUntil("subscriptions") { await socket.subscriptions.count == 2 }
    let subscriptions = await socket.subscriptions
    XCTAssertEqual(subscriptions.map(\.stream), ["workspace", "conversation"])
    XCTAssertEqual(subscriptions[1].params.conversationID, "central-chat")
    let workspaceSub = subscriptions[0].id, chat = subscriptions[1].id

    await socket.push(.item(.init(id: chat, payload: .transcript(.init(transcript: .init(conversationID: "central-chat", messages: [
      .init(id: "m1", conversationID: "central-chat", runID: "run", role: "user", content: "Plan the release"),
      .init(id: "m2", conversationID: "central-chat", runID: "run", role: "assistant", content: "Reading", status: "streaming"),
    ], activeRunID: "run", runs: [.init(id: "run", status: "running")]), snapshot: true)))))
    let question = PendingInteraction(id: "q1", conversationID: "central-chat", runID: "run", kind: .approval, title: "Run the tests?")
    await socket.push(.item(.init(id: workspaceSub, payload: .pending(.init(interactions: [question])))))
    await socket.push(.item(.init(id: chat, payload: .capabilities(.init(capabilities:
      .init(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true, canSteer: true, canStop: true))))))
    let settings = SessionSettings(conversationID: "central-chat", model: "gpt", thinking: nil, permission: nil, models: [], thinkingLevels: [],
                                   permissions: [], availableTools: [], enabledTools: [], canConfigure: true)
    await socket.push(.item(.init(id: chat, payload: .session(.init(settings: settings)))))
    await waitUntil("transcript") { model.transcript?.messages.count == 2 }
    await waitUntil("question") { model.currentPending.map(\.id) == ["q1"] }
    await waitUntil("settings") { model.streamedSessionSettings["central-chat"]?.model == "gpt" }
    XCTAssertEqual(model.activeRunID, "run")
    XCTAssertEqual(model.activeProvider?.canSteer, true)
    XCTAssertTrue(model.streamsSessionSettings("central-chat"), "Settings are not read for a streamed central chat")

    // A library sync, as the 15 s tick runs it, reads nothing live: no transcript, pending or receipts.
    await model.refresh(); await model.refresh()
    await model.refreshExecutionWorkspaces()
    let liveReads = await fixture.library.liveReads
    XCTAssertEqual(liveReads, 0, "No central transcript, pending or receipt polling")
    let providerReads = await fixture.library.providerReads
    XCTAssertEqual(providerReads, 1, "The agent list is read once per connection, not every fifth refresh")
    XCTAssertEqual(model.currentPending.map(\.id), ["q1"], "One copy of each question, from the stream")
    let execution = fixture.http.paths(host: "studio.tail1.ts.net")
    XCTAssertFalse(execution.contains { $0.contains("/transcript") || $0.contains("/interactions") || $0.contains("/capabilities") }, "\(execution)")

    // A streamed row carries the compact projection; expanding it reads the
    // library host's details route once, and nothing else.
    await socket.push(.item(.init(id: chat, payload: .transcript(.init(transcript: .init(conversationID: "central-chat", messages: [],
      activities: [.init(id: "a1", runID: "run", title: "Read file", status: "completed",
                         projectionJSON: #"{"id":"a1","kind":"tool","title":"Read file","content":"The wh","detailsAvailable":true,"locations":[],"changes":[],"planEntries":[]}"#)],
      activeRunID: "run", runs: [.init(id: "run", status: "running")]), snapshot: false)))))
    await waitUntil("compact row") { model.transcript?.activities.first?.id == "a1" }
    let detail = try await model.conversationActivityDetail(conversationID: "central-chat", runID: "run", activityID: "a1")
    XCTAssertEqual(detail?.content, "The whole file")
    let detailReads = await fixture.library.detailReads
    XCTAssertEqual(detailReads, ["run/a1"])
    let transcriptReads = await fixture.library.transcripts
    XCTAssertEqual(transcriptReads, 0, "Details never read the whole transcript")

    // Leaving the chat ends its subscription; nothing else changes.
    await model.selectConversation("central-chat-2")
    await waitUntil("cancel") { await socket.cancels == [chat] }
  }

  /// The library host's stream announces its library changes (`library`
  /// items): a cursor ahead of the phone's synchronizes at once, and while
  /// that stream is open the library has no timer. When it closes, the 15 s
  /// timer returns.
  @MainActor func testLibraryItemsFromTheHostSyncAtOnceAndReplaceTheTimer() async throws {
    let fixture = try await makeFixture(); let model = fixture.model
    defer { try? FileManager.default.removeItem(at: fixture.root); model.stopDeviceScheduler() }
    model.automaticSynchronization = true
    await model.refreshExecutionWorkspaces(force: true)
    let socket = await openHost(fixture)
    await waitUntil("workspace subscription") { await socket.subscriptions.count == 1 }
    let workspaceSub = await socket.subscriptions[0].id
    XCTAssertTrue(model.librarySyncTimerNeeded, "No announcement yet: the timer stays")

    // The cursor the phone already holds: no sync, and no timer from now on.
    await socket.push(.item(.init(id: workspaceSub, payload: .library(.init(cursor: 1)))))
    await waitUntil("announcing stream") { !model.librarySyncTimerNeeded }
    let loop = Task { await model.maintainConnections() }
    defer { loop.cancel() }
    await waitUntil("the loop waits on the stream") { model.librarySyncPause == .stream }
    let settled = await fixture.library.changeReads
    try await Task.sleep(for: .milliseconds(100))
    let idle = await fixture.library.changeReads
    XCTAssertEqual(idle, settled, "Nothing reads the library while the stream is quiet")

    // A change on the host: synchronized at once, with no timer involved.
    await fixture.library.setCursor(5)
    await socket.push(.item(.init(id: workspaceSub, payload: .library(.init(cursor: 5)))))
    await waitUntil("synchronized") { await fixture.model.store?.snapshot().cursor == 5 }
    let reads = await fixture.library.changeReads
    XCTAssertGreaterThan(reads, settled)
    XCTAssertEqual(model.librarySyncPause, .stream, "Still no timer")

    // A cursor this phone already passed does not sync again.
    await socket.push(.item(.init(id: workspaceSub, payload: .library(.init(cursor: 4)))))
    try await Task.sleep(for: .milliseconds(100))
    let unchanged = await fixture.library.changeReads
    XCTAssertEqual(unchanged, reads, "An older cursor does not sync")

    // The stream closes: the timer returns until it announces again.
    await socket.serverClose(code: 1006)
    await waitUntil("timer") { model.librarySyncPause == .timer }
    XCTAssertTrue(model.librarySyncTimerNeeded)
    XCTAssertEqual(MobileModel.librarySyncInterval, .seconds(15))
  }

  /// A workspace without a stream is read once when its client is made and
  /// on explicit refreshes, never on the 15 s tick.
  @MainActor func testAWorkspaceWithoutAStreamIsNotPolled() async throws {
    let fixture = try await makeFixture(); let model = fixture.model
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    await model.refreshExecutionWorkspaces(force: true)
    await model.workspaceReadTasks[fixture.mini.id]?.value
    XCTAssertEqual(model.workspaceReachable[fixture.mini.id], true)
    let first = fixture.http.paths(host: "mini.tail1.ts.net").count
    XCTAssertGreaterThan(first, 0)
    for _ in 0..<3 { await model.refreshExecutionWorkspaces(); await model.workspaceReadTasks[fixture.mini.id]?.value }
    XCTAssertEqual(fixture.http.paths(host: "mini.tail1.ts.net").count, first, "No request on the periodic tick")
    await model.refreshExecutionWorkspaces(force: true)
    await model.workspaceReadTasks[fixture.mini.id]?.value
    XCTAssertGreaterThan(fixture.http.paths(host: "mini.tail1.ts.net").count, first, "An explicit refresh reads it once")
    XCTAssertEqual(MobileModel.librarySyncInterval, .seconds(15))
  }

  /// Background closes every stream cleanly; the foreground reopens it at
  /// once with its subscriptions; a network path change tries at once.
  @MainActor func testBackgroundForegroundAndNetworkChanges() async throws {
    let fixture = try await makeFixture(); let model = fixture.model
    defer { try? FileManager.default.removeItem(at: fixture.root); model.stopDeviceScheduler() }
    await model.refreshExecutionWorkspaces(force: true)
    let socket = await openHost(fixture)
    await model.selectConversation("central-chat")
    await waitUntil("subscriptions") { await socket.subscriptions.count == 2 }

    model.sceneChanged(.background)
    await waitUntil("closed cleanly") { await socket.closedWith == .normal }
    try await Task.sleep(for: .milliseconds(50))
    XCTAssertEqual(fixture.server.attempts, 1, "Nothing reconnects in the background")
    await model.reconcileWorkspaceStreams()
    XCTAssertEqual(fixture.server.attempts, 1, "A refresh in the background opens nothing")

    model.sceneChanged(.active)
    let resumed = await openHost(fixture, socket: 1)
    await waitUntil("resubscribed") { await resumed.subscriptions.count == 2 }
    let streams = await resumed.subscriptions.map(\.stream)
    XCTAssertEqual(streams, ["workspace", "conversation"])

    // A network path change checks an open socket with a ping...
    model.connectionDidBecomeReachable()
    await waitUntil("probe") { await resumed.pings > 0 }
    // ...and reconnects a waiting one at once instead of after its backoff (1 s or more).
    fixture.server.refuse(StreamConnectionError.disconnected)
    await resumed.serverClose(code: 1006)
    await waitUntil("refused") { fixture.server.attempts == 3 }
    model.connectionDidBecomeReachable()
    await waitUntil("immediate retry", timeout: .milliseconds(700)) { fixture.server.sockets.count == 3 }
  }

  /// A stale clock says so in the open chat; a 4401 close stops retries until
  /// the member list changes.
  @MainActor func testStaleClockAndRemovedMember() async throws {
    let fixture = try await makeFixture(); let model = fixture.model
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    fixture.server.refuse(StreamConnectionError.memberTimeStale(serverTime: 1))
    await model.refreshExecutionWorkspaces(force: true)
    await model.selectConversation("central-chat")
    await waitUntil("stale clock") { model.selectedStreamProblem != nil }
    XCTAssertEqual(model.selectedStreamProblem, "This device's clock is wrong. Turn on Set Automatically in Settings › General › Date & Time.")

    let socket = await openHost(fixture)
    XCTAssertNil(model.selectedStreamProblem)
    await socket.serverClose(code: StreamProtocol.CloseCode.memberRemoved.rawValue)
    await waitUntil("removed") { model.selectedStreamProblem == "Studio no longer lists this device as a member." }
    let attempts = fixture.server.attempts
    model.connectionDidBecomeReachable()
    model.sceneChanged(.background); model.sceneChanged(.active)
    model.stopDeviceScheduler()
    await model.reconcileWorkspaceStreams()
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertEqual(fixture.server.attempts, attempts, "No retry after 4401 until the member list changes")

    var membership = try XCTUnwrap(model.membership)
    membership.membersRevision = "r2"
    model.membership = membership
    await model.reconcileWorkspaceStreams()
    _ = await openHost(fixture, socket: 1)
    XCTAssertEqual(fixture.server.attempts, attempts + 1)
  }
}
