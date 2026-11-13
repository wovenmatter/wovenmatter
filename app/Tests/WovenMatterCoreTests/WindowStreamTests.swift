#if canImport(LibraryClient)
import Foundation
import LibraryClient
import Testing
import WorkspaceFixtures
import WovenMatterClient
import WovenMatterCore
@testable import WovenMatterLibraryStore

extension BackendStreamChannel: StreamByteChannel {}

/// A Mac window's one connection to its own background server ("Mac window
/// to its own server" in docs/architecture/WOVEN_EVERYWHERE.md): the real
/// background-server socket and its peer check, the length-prefixed frames,
/// and the window's `StreamConnection`, against each other.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct WindowStreamTests {
  @Test func aWindowFollowsServerStateAndALiveConversationAndReconnectsAfterARestart() async throws {
    let mac = try await WindowMac(); defer { mac.remove() }
    let conversation = try await mac.database.createFixtureLocalACPSession(runtimeKind: .codex, title: "Fix the build", ownerDeviceID: UUID())
    let run = try await mac.database.beginLocalACPRun(conversationID: conversation, input: .init(text: "Run the tests"))

    // One-shot calls keep working on the same socket.
    #expect(try await BackendRPCClient(socketURL: mac.socket).call(method: "echo", payload: Data("hi".utf8)) == Data("hi".utf8))

    let inbox = Inbox()
    let connection = StreamConnection(configuration: .init(retrySleep: { _ in try await Task.sleep(for: .milliseconds(50)) })) { [socket = mac.socket] in
      LengthPrefixedStreamTransport(channel: try await BackendRPCClient(socketURL: socket).openStream())
    }
    await connection.subscribe(.serverState) { await inbox.add("state", $0); return .accepted }
    await connection.subscribe(.conversation, params: .init(conversationID: conversation)) { await inbox.add("chat", $0); return .accepted }
    await connection.start()

    // server.state: synchronized first (read everything again), then each change.
    #expect(try await inbox.item("state").payload == .synchronized)
    #expect(await connection.hello?.libraryID == mac.libraryID)
    await mac.window.serverState.publish(.init(scopes: ["settings"], conversationIDs: [conversation]))
    #expect(try await inbox.item("state").payload == .serverState(.init(scopes: ["settings"], conversationIDs: [conversation])))

    // conversation: the snapshot, capabilities, session settings, synchronized.
    guard case .transcript(let snapshot) = try await inbox.item("chat").payload else { Issue.record("no transcript"); return }
    #expect(snapshot.snapshot && snapshot.transcript.messages.contains { $0.role == "user" })
    guard case .capabilities = try await inbox.item("chat").payload else { Issue.record("no capabilities"); return }
    guard case .session(let session) = try await inbox.item("chat").payload else { Issue.record("no session"); return }
    #expect(session.settings.model == "gpt-5.5")
    #expect(try await inbox.item("chat").payload == .synchronized, "a session this Mac runs has no pending or owner items")
    #expect(await mac.source.opened == [conversation])

    // Live text: every chunk arrives as the whole message so far.
    try await mac.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: "All 214 tests")
    try await mac.database.appendLocalACPAssistantChunk(runID: run.runID, chunk: " pass")
    let update = try await inbox.transcript("chat") { $0.messages.contains { $0.id == run.assistantMessageID && $0.content == "All 214 tests pass" } }
    #expect(!update.snapshot && update.transcript.messages.map(\.id) == [run.assistantMessageID])

    // The session item when the settings change, and only then.
    await MainActor.run { mac.source.model = "gpt-5.5-mini" }
    mac.window.liveStateChanged(conversationIDs: [conversation])
    let changed = try await inbox.item("chat") { if case .session = $0.payload { true } else { false } }
    guard case .session(let next) = changed.payload else { return }
    #expect(next.settings.model == "gpt-5.5-mini")

    // The background server restarts: the window reconnects, resubscribes and starts again from snapshots.
    mac.restart()
    try await mac.startServers()
    #expect(try await inbox.item("state") { $0.payload == .synchronized }.payload == .synchronized)
    let again = try await inbox.transcript("chat") { _ in true }
    #expect(again.snapshot && again.transcript.messages.contains { $0.content == "All 214 tests pass" })
    #expect(await connection.isOpen)
    await connection.stop()
  }

  @Test func aSessionAnotherMachineRunsCarriesItsQuestionsAndOwner() async throws {
    let mac = try await WindowMac(); defer { mac.remove() }
    await MainActor.run { mac.source.relayed["remote-1"] = .init(interactions: [], owner: .init(online: true)) }
    let inbox = Inbox()
    let connection = StreamConnection { [socket = mac.socket] in
      LengthPrefixedStreamTransport(channel: try await BackendRPCClient(socketURL: socket).openStream())
    }
    let subscription = await connection.subscribe(.conversation, params: .init(conversationID: "remote-1")) { await inbox.add("chat", $0); return .accepted }
    await connection.start()
    guard case .transcript = try await inbox.item("chat").payload else { Issue.record("no transcript"); return }
    _ = try await inbox.item("chat") { $0.payload == .pending(.init(interactions: [])) }
    #expect(try await inbox.item("chat").payload == .owner(.init(online: true)))
    #expect(try await inbox.item("chat").payload == .synchronized)

    // The machine goes away: its owner item changes, nothing else.
    let question = PendingInteraction(id: "q1", conversationID: "remote-1", runID: "r1", kind: .approval, title: "Run npm test?",
                                      options: [.init(id: "allow", label: "Allow")], questions: [])
    await MainActor.run { mac.source.relayed["remote-1"] = .init(interactions: [question], owner: .init(online: false, error: "Offline")) }
    mac.window.liveStateChanged(conversationIDs: ["remote-1"])
    #expect(try await inbox.item("chat").payload == .pending(.init(interactions: [question])))
    #expect(try await inbox.item("chat").payload == .owner(.init(online: false, error: "Offline")))

    // Closing the chat closes what the server opened for it.
    await connection.unsubscribe(subscription)
    #expect(try await pollUntil(attempts: 1_000, interval: .milliseconds(10)) { await mac.source.closed == ["remote-1"] })
    await connection.stop()
  }

  @Test func queuedServerStateChangesAccumulate() throws {
    let first = StreamItem(id: "s", payload: .serverState(.init(scopes: ["settings"], conversationIDs: ["a"])))
    let second = StreamItem(id: "s", payload: .serverState(.init(scopes: ["usage", "settings"], conversationIDs: ["b", "a"])))
    #expect(StreamSession.merge(first, second)?.payload == .serverState(.init(scopes: ["settings", "usage"], conversationIDs: ["a", "b"])))
    let scopesOnly = StreamItem(id: "s", payload: .serverState(.init(scopes: ["bots"])))
    #expect(StreamSession.merge(scopesOnly, scopesOnly)?.payload == scopesOnly.payload)
  }

  @Test func aServerWithoutTheStreamRefusesItAndAWindowCannotSendCommandsOnIt() async throws {
    let directory = try WindowMac.socketDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
    let socket = directory.appending(path: "control.sock")
    let server = BackendRPCServer(socketURL: socket)
    try server.start { BackendRPCResponse(id: $0.id, result: Data()) }
    defer { server.stop() }
    await #expect(throws: BackendRPCError.self) { _ = try await BackendRPCClient(socketURL: socket).openStream() }

    let mac = try await WindowMac(); defer { mac.remove() }
    let inbox = Inbox()
    let connection = StreamConnection { [socket = mac.socket] in
      LengthPrefixedStreamTransport(channel: try await BackendRPCClient(socketURL: socket).openStream())
    }
    await connection.subscribe(.workspace) { await inbox.add("workspace", $0); return .accepted }
    await connection.start()
    guard case .ended(let error) = try await inbox.event("workspace") else { Issue.record("workspace was served"); return }
    #expect(error?.code == "invalid")
    await #expect(throws: StreamConnectionError.self) {
      _ = try await connection.command(.init(deviceID: "d", kind: .send, conversationID: "c", text: "Hi"))
    }
    #expect(mac.window.openSessionCount() == 1)
    await connection.stop()
    #expect(try await pollUntil(attempts: 1_000, interval: .milliseconds(10)) { mac.window.openSessionCount() == 0 })
  }
}

// MARK: - Fixture

/// What a background server's windows read: a local session from its rows,
/// and relayed state for sessions named in `relayed`.
@MainActor private final class WindowSource: ExecutionConversationSource {
  let database: WorkspaceDatabase
  var model = "gpt-5.5"
  var relayed: [String: ExecutionConversationRelay] = [:]
  private(set) var opened: [String] = []
  private(set) var closed: [String] = []
  init(database: WorkspaceDatabase) { self.database = database }

  func conversationOpened(_ conversationID: String) async throws { opened.append(conversationID) }
  func conversationClosed(_ conversationID: String) async { closed.append(conversationID) }
  func conversationRelay(conversationID: String) async -> ExecutionConversationRelay? { relayed[conversationID] }

  func localTranscript(conversationID: String, before: String?) async throws -> LibraryTranscript {
    guard relayed[conversationID] == nil else { return LibraryTranscript(conversationID: conversationID) }
    let (messages, active) = try await database.read { connection in
      (try connection.historyRowsUnlocked("SELECT id,run_id,role,content,status,created_at FROM messages WHERE conversation_id=? ORDER BY created_at,id", values: [conversationID]),
       try connection.historyRowsUnlocked("SELECT id FROM runs WHERE conversation_id=? AND status IN ('queued','running') ORDER BY created_at DESC LIMIT 1", values: [conversationID]))
    }
    return LibraryTranscript(conversationID: conversationID, messages: messages.compactMap { row in
      guard let value = row.objectValue, let id = value["id"]?.stringValue else { return nil }
      return LibraryMessage(id: id, conversationID: conversationID, runID: value["run_id"]?.stringValue, role: value["role"]?.stringValue ?? "",
                            content: value["content"]?.stringValue ?? "", status: value["status"]?.stringValue, createdAt: value["created_at"]?.stringValue ?? "")
    }, activeRunID: active.first?.objectValue?["id"]?.stringValue)
  }

  func localCapabilities(conversationID: String) async throws -> HarnessCapabilities {
    .init(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true)
  }

  func localSessionSettings(conversationID: String) async throws -> SessionSettings {
    .init(conversationID: conversationID, model: model, thinking: "high", permission: nil, models: [.init(id: model, label: model)],
          thinkingLevels: [], permissions: [], availableTools: [], enabledTools: [], canConfigure: true)
  }
}

/// A background server's socket with the window stream behind it.
private final class WindowMac: @unchecked Sendable {
  let fixture: PersistenceFixture
  let database: WorkspaceDatabase
  let directory: URL
  let socket: URL
  let libraryID: String
  let source: WindowSource
  private let lock = NSLock()
  private var current: (rpc: BackendRPCServer, window: ExecutionWindowStreamServer)?
  var window: ExecutionWindowStreamServer { lock.withLock { current!.window } }

  static func socketDirectory() throws -> URL {
    // sun_path is short: keep the socket under /private/tmp.
    let directory = URL(fileURLWithPath: "/private/tmp/wm-window-" + UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return directory
  }

  init() async throws {
    fixture = try PersistenceFixture()
    database = try await fixture.openDatabase()
    libraryID = try await database.libraryIdentity().libraryID
    directory = try Self.socketDirectory()
    socket = directory.appending(path: "control.sock")
    let database = database
    source = await MainActor.run { WindowSource(database: database) }
    try await startServers()
  }

  func startServers() async throws {
    var configuration = ExecutionStreamConfiguration()
    configuration.smallMessageInterval = .milliseconds(20)
    let libraryID = libraryID
    let window = ExecutionWindowStreamServer(database: database, source: source, configuration: configuration) {
      StreamHello(deviceID: "mac", libraryID: libraryID, workspaceID: "this-mac", serverTime: MemberRequestSignature.now())
    }
    await window.start()
    let rpc = BackendRPCServer(socketURL: socket)
    try rpc.start(handler: { BackendRPCResponse(id: $0.id, result: $0.payload) }, stream: { window.accept($0) })
    lock.withLock { current = (rpc, window) }
  }

  /// The background server stops: its socket and every window's connection close.
  func restart() {
    guard let (rpc, window) = lock.withLock({ current }) else { return }
    window.stop(); rpc.stop()
  }

  func remove() {
    restart()
    fixture.remove()
    try? FileManager.default.removeItem(at: directory)
  }
}

/// What each subscription received, in order.
private actor Inbox {
  private var events: [String: [StreamSubscriptionEvent]] = [:]
  func add(_ tag: String, _ event: StreamSubscriptionEvent) { events[tag, default: []].append(event) }

  func event(_ tag: String, timeout: Duration = .seconds(10)) async throws -> StreamSubscriptionEvent {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if var queue = events[tag], !queue.isEmpty {
        let first = queue.removeFirst(); events[tag] = queue
        return first
      }
      try await Task.sleep(for: .milliseconds(5))
    }
    throw WindowStreamTestError.timeout(tag)
  }

  /// The next item matching `predicate`; earlier items are dropped.
  func item(_ tag: String, where predicate: (StreamItem) -> Bool = { _ in true }) async throws -> StreamItem {
    while true {
      if case .item(let item) = try await event(tag), predicate(item) { return item }
    }
  }

  func transcript(_ tag: String, where predicate: (LibraryTranscript) -> Bool) async throws -> StreamTranscript {
    let item = try await item(tag) { if case .transcript(let value) = $0.payload { predicate(value.transcript) } else { false } }
    guard case .transcript(let value) = item.payload else { throw WindowStreamTestError.timeout(tag) }
    return value
  }
}

private enum WindowStreamTestError: Error { case timeout(String) }
#endif
