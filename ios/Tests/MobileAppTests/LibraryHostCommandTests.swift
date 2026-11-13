import XCTest
import LibraryClient
import WovenMatterShared
@testable import WovenMatterMobileApp

/// The library host's mobile API (`POST v1/commands`), recording every central command.
private actor HostLibrary: OfflineLibraryTransport {
  private(set) var commands: [LibraryCommand] = []
  func workspaceIdentity() async throws -> String { "library-a" }
  func snapshot() async throws -> LibrarySnapshot { .init(workspaceID: "library-a", cursor: 1) }
  func changes(after: Int64) async throws -> LibraryChangePage { .init(workspaceID: "library-a", cursor: max(after, 1)) }
  func providers() async throws -> [HarnessCapabilities] {
    [.init(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true, canSteer: true, canStop: true)]
  }
  func pending() async throws -> [PendingInteraction] { [] }
  func transcript(_ id: String) async throws -> LibraryTranscript { .init(conversationID: id) }
  func receipt(_ id: String) async throws -> LibraryCommandReceipt? { nil }
  func command(_ command: LibraryCommand) async throws -> LibraryCommandReceipt {
    commands.append(command)
    return .init(commandID: command.commandID, deviceID: command.deviceID, status: command.kind == .createSession ? .completed : .accepted,
                 conversationID: command.conversationID, runID: command.kind == .createSession ? nil : "run-" + command.commandID)
  }
}

/// Each Mac's signed HTTP routes: its execution descriptor, agents and the
/// library host's `GET v1/hello`. Commands never arrive here: streamed
/// workspaces take them on their stream.
private final class MacHTTP: MobileHTTPPerforming, @unchecked Sendable {
  private let lock = NSLock()
  private var workspaces: [String: ExecutionWorkspace] = [:]
  private var recorded: [String] = []
  func serve(_ workspace: ExecutionWorkspace) { lock.withLock { workspaces[workspace.endpoint?.host ?? ""] = workspace } }
  var paths: [String] { lock.withLock { recorded } }
  func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
    let host = request.url?.host ?? "", path = request.url?.path ?? ""
    let workspace = lock.withLock { recorded.append((request.httpMethod ?? "GET") + " " + host + path); return workspaces[host] }
    let body: Data
    switch path {
    case "/wovenmatter/v1/hello": body = try JSONEncoder().encode(LibraryHello(workspaceID: "library-a", hostName: "Dev", capabilities: []))
    case "/wovenmatter/v1/execution": body = try JSONEncoder().encode(workspace)
    case "/wovenmatter/v1/execution/events": body = try JSONEncoder().encode(ExecutionJournalPage(libraryID: workspace?.libraryID ?? "", cursor: 0))
    case "/wovenmatter/v1/execution/providers":
      body = try JSONEncoder().encode([HarnessCapabilities(id: "local:codex", runtimeKind: "codex", displayName: "Codex", available: true, canSteer: true, canStop: true)])
    default: body = Data("[]".utf8)
    }
    return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
  }
}

/// One Mac's stream socket. It answers `execution.command` exactly as the
/// Mac's `executeLocal` checks it: the member device ID of the socket, and
/// the library and workspace of the descriptor it serves.
private actor MacSocket: StreamTransport {
  let descriptor: ExecutionWorkspace
  let memberDeviceID: String
  private(set) var commands: [LibraryCommand] = []
  private var inbox: [Result<StreamFrame, any Error>] = []
  private var receiver: CheckedContinuation<StreamFrame, any Error>?
  private var closed = false
  init(descriptor: ExecutionWorkspace, memberDeviceID: String) { self.descriptor = descriptor; self.memberDeviceID = memberDeviceID }
  func receive() async throws -> StreamFrame {
    if !inbox.isEmpty { return try inbox.removeFirst().get() }
    if closed { throw StreamTransportClosed() }
    return try await withCheckedThrowingContinuation { receiver = $0 }
  }
  func send(_ frame: StreamFrame) throws {
    guard !closed else { throw StreamTransportClosed() }
    guard case .request(let request) = frame else { return }
    switch StreamProtocol.Method(rawValue: request.method) {
    case .executionCommand?:
      let command = try request.decodeParams(StreamCommandParams.self).command
      commands.append(command)
      guard command.deviceID == memberDeviceID, command.libraryID == descriptor.libraryID, command.workspaceID == descriptor.id else {
        deliver(.success(.response(.init(id: request.id, error: .init(code: "wrong_workspace",
          message: "Command identity does not match its authenticated execution scope.")))))
        return
      }
      let receipt = LibraryCommandReceipt(commandID: command.commandID, deviceID: command.deviceID,
        status: command.kind == .createSession ? .completed : .accepted, conversationID: command.conversationID,
        runID: command.kind == .createSession ? nil : "run-" + command.commandID, libraryID: descriptor.libraryID, workspaceID: descriptor.id)
      deliver(.success(.response(try .init(id: request.id, encoding: receipt))))
    case .executionReceipt?: deliver(.success(.response(.init(id: request.id, result: .null))))
    case nil: break
    }
  }
  func ping() {}
  func close(_ code: StreamProtocol.CloseCode) { guard !closed else { return }; closed = true; deliver(.failure(StreamTransportClosed(code: code.rawValue))) }
  func push(_ frame: StreamFrame) { deliver(.success(frame)) }
  private func deliver(_ result: Result<StreamFrame, any Error>) {
    if let receiver { self.receiver = nil; receiver.resume(with: result) } else { inbox.append(result) }
  }
}

/// Hands out one socket per connection attempt to one Mac.
private final class MacStreamServer: @unchecked Sendable {
  private let lock = NSLock()
  private var _sockets: [MacSocket] = []
  let descriptor: ExecutionWorkspace
  let memberDeviceID: String
  init(descriptor: ExecutionWorkspace, memberDeviceID: String) { self.descriptor = descriptor; self.memberDeviceID = memberDeviceID }
  var sockets: [MacSocket] { lock.withLock { _sockets } }
  var connect: StreamConnection.Connect {
    { [self] in
      lock.withLock { let socket = MacSocket(descriptor: descriptor, memberDeviceID: memberDeviceID); _sockets.append(socket); return socket }
    }
  }
  /// Every command any socket to this Mac received.
  func commands() async -> [LibraryCommand] {
    var result: [LibraryCommand] = []
    for socket in sockets { result += await socket.commands }
    return result
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

/// A Dev snapshot Mac hosts the library: its registry holds two copied
/// (retained-history) rows of the production Mac beside its own live row,
/// and another member Mac streams too. The phone creates and uses chats on
/// both, and each command reaches the right server with the right identity.
final class LibraryHostCommandTests: XCTestCase {
  private let hostDevice = "a0000000-0000-4000-8000-00000000000a"
  private let productionDevice = "c0000000-0000-4000-8000-00000000000c"
  private let olderDevice = "d0000000-0000-4000-8000-00000000000d"
  private let miniDevice = "b0000000-0000-4000-8000-00000000000b"
  private let streamed = ["execution.v1", "history.central.v1", "inference.v1", StreamProtocol.capability]

  private struct Fixture {
    let model: MobileModel
    let library: HostLibrary
    let http: MacHTTP
    let dev: ExecutionWorkspace
    let mini: ExecutionWorkspace
    let devServer: MacStreamServer
    let miniServer: MacStreamServer
    let root: URL
  }

  @MainActor private func makeFixture() async throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let store = try MobileStore(file: root.appendingPathComponent("library.json"))
    try await store.bindWorkspace("library-a")
    try await store.apply(LibrarySnapshot(workspaceID: "library-a", cursor: 1))
    let library = HostLibrary()
    let model = MobileModel(store: store, transport: library)
    model.executionDirectory = root.appendingPathComponent("execution", isDirectory: true)
    await model.reload()
    let devEndpoint = URL(string: "https://dev.tail1.ts.net/wovenmatter")!
    model.credential = .init(endpoint: devEndpoint, workspaceID: "library-a", deviceID: model.state.deviceID, token: "synthetic-test-token")
    // The production snapshot's copies: no endpoint, history only. One still lists the stream.
    let copied = ExecutionWorkspace(id: "33333333-3333-4333-8333-333333333333", libraryID: "library-a", ownerDeviceID: productionDevice, kind: .mac,
      name: "Studio", capabilities: streamed, executionDeviceID: productionDevice, retainedHistory: true)
    let older = ExecutionWorkspace(id: "44444444-4444-4444-8444-444444444444", libraryID: "library-a", ownerDeviceID: olderDevice, kind: .mac,
      name: "Studio", capabilities: ["execution.v1", "history.central.v1"], executionDeviceID: olderDevice, retainedHistory: true)
    let dev = ExecutionWorkspace(id: "11111111-1111-4111-8111-111111111111", libraryID: "library-a", ownerDeviceID: hostDevice, kind: .mac,
      name: "Studio (Dev)", endpoint: devEndpoint, capabilities: streamed, executionDeviceID: hostDevice, developmentInstance: "snapshot")
    // Another Mac keeps its own library namespace.
    let mini = ExecutionWorkspace(id: "22222222-2222-4222-8222-222222222222", libraryID: "library-b", ownerDeviceID: miniDevice, kind: .mac,
      name: "Mini", endpoint: URL(string: "https://mini.tail1.ts.net/wovenmatter")!, capabilities: streamed, executionDeviceID: miniDevice)
    try await store.journal.bind(libraryID: "library-a")
    for workspace in [copied, older, dev, mini] { try await store.journal.upsertWorkspace(workspace, pending: false, trustedRegistry: true) }
    let http = MacHTTP(); http.serve(dev); http.serve(mini)
    model.httpPerformer = http
    model.memberKeyStorage = .memory()
    let identity = try model.loadMemberIdentity()
    var membership = MobileMembershipState(deviceID: model.state.deviceID, pairedEndpoint: devEndpoint, pairedHostDeviceID: hostDevice)
    membership.currentHost = .init(deviceID: hostDevice, kind: "mac", name: "Studio (Dev)", endpoint: devEndpoint)
    membership.membersRevision = "r1"
    model.libraryHosts = try MobileLibraryHosts(state: membership, identity: identity, file: nil, performer: http)
    model.membership = membership
    model.transport = try HTTPSLibraryTransport(host: devEndpoint, hostDeviceID: hostDevice, identity: identity, performer: http)
    let devServer = MacStreamServer(descriptor: dev, memberDeviceID: identity.deviceID)
    let miniServer = MacStreamServer(descriptor: mini, memberDeviceID: identity.deviceID)
    let servers = [dev.id: devServer, mini.id: miniServer]
    model.streamConnector = { workspace in servers[workspace.id]?.connect }
    return Fixture(model: model, library: library, http: http, dev: dev, mini: mini, devServer: devServer, miniServer: miniServer, root: root)
  }

  /// Synchronizes with the host, then opens both Macs' streams with their `hello`.
  @MainActor private func connect(_ fixture: Fixture) async {
    let model = fixture.model
    await model.refresh()
    await model.refreshExecutionWorkspaces(force: true)
    for (server, device) in [(fixture.devServer, hostDevice), (fixture.miniServer, miniDevice)] {
      await waitUntil("socket to \(server.descriptor.name)") { !server.sockets.isEmpty }
      await server.sockets[0].push(.hello(.init(deviceID: device, libraryID: server.descriptor.libraryID, workspaceID: server.descriptor.id,
                                                serverTime: 0, capabilities: [StreamProtocol.capability])))
      await waitUntil("\(server.descriptor.name) open") { model.workspaceReachable[server.descriptor.id] == true }
      await waitUntil("\(server.descriptor.name) agents") { model.workspaceProviders[server.descriptor.id] != nil }
    }
  }

  /// Codex under the library host's own workspace is the central route: the
  /// live row, never a copy. The chat is created and used through the mobile
  /// API (`POST v1/commands`), and nothing reaches the host's stream.
  @MainActor func testChatOnTheLibraryHostUsesTheMobileAPI() async throws {
    let fixture = try await makeFixture(); let model = fixture.model
    defer { try? FileManager.default.removeItem(at: fixture.root); model.closeWorkspaceStreams() }
    await connect(fixture)
    XCTAssertEqual(model.centralExecutionWorkspace?.id, fixture.dev.id, "The live row, not a copied one, is the library host")
    XCTAssertTrue(model.streamsCentral)
    XCTAssertEqual(model.launcherGroups.map(\.id), ["local", "central", fixture.mini.id], "Copied rows are never listed")
    let central = try XCTUnwrap(model.launcherGroups.first { $0.id == "central" })
    XCTAssertEqual(central.workspace?.id, fixture.dev.id)
    let codex = try XCTUnwrap(central.agents.first { $0.providerID == "local:codex" })

    await model.launchAgent(codex)
    XCTAssertNil(model.chatSetupProblem); XCTAssertNil(model.errorMessage)
    let id = try XCTUnwrap(model.selectedConversationID)
    XCTAssertEqual(model.selectedExecutionWorkspaceID, "central")
    model.composer = "Plan the release"
    await model.send()
    XCTAssertNil(model.errorMessage)

    let sent = await fixture.library.commands
    XCTAssertEqual(sent.map(\.kind), [.createSession, .send])
    XCTAssertTrue(sent.allSatisfy { $0.conversationID == id && $0.deviceID == model.state.deviceID && $0.workspaceID == nil })
    let streamed = await fixture.devServer.commands()
    XCTAssertTrue(streamed.isEmpty, "Central commands stay on the mobile API: \(streamed.map(\.kind))")
    XCTAssertFalse(fixture.http.paths.contains { $0.contains("/v1/execution/commands") })

    // The next message, stopping and the composer's route stay central too.
    model.composer = "And the changelog"
    await model.send()
    XCTAssertNil(model.errorMessage)
    let after = await fixture.library.commands
    XCTAssertEqual(after.map(\.kind), [.createSession, .send, .send])
    let stillNone = await fixture.devServer.commands()
    XCTAssertTrue(stillNone.isEmpty)
  }

  /// Codex on another member Mac takes signed `execution.command` on that
  /// Mac's stream, with this phone's member device ID and that Mac's own
  /// library and workspace, which its server accepts.
  @MainActor func testChatOnAMemberMacUsesItsStreamWithItsIdentity() async throws {
    let fixture = try await makeFixture(); let model = fixture.model
    defer { try? FileManager.default.removeItem(at: fixture.root); model.closeWorkspaceStreams() }
    await connect(fixture)
    let group = try XCTUnwrap(model.launcherGroups.first { $0.id == fixture.mini.id })
    let codex = try XCTUnwrap(group.agents.first { $0.providerID == "local:codex" })

    await model.launchAgent(codex)
    XCTAssertNil(model.chatSetupProblem); XCTAssertNil(model.errorMessage)
    let id = try XCTUnwrap(model.selectedConversationID)
    XCTAssertEqual(model.selectedExecutionWorkspaceID, fixture.mini.id)
    model.composer = "Run the tests"
    await model.send()
    XCTAssertNil(model.errorMessage)

    let commands = await fixture.miniServer.commands()
    XCTAssertEqual(commands.map(\.kind), [.createSession, .send])
    for command in commands {
      XCTAssertEqual(command.conversationID, id)
      XCTAssertEqual(command.deviceID, model.memberIdentity?.deviceID, "The member device ID the socket is signed with")
      XCTAssertEqual(command.libraryID, fixture.mini.libraryID, "The Mac's own library, not the phone's")
      XCTAssertEqual(command.workspaceID, fixture.mini.id)
    }
    let central = await fixture.library.commands
    XCTAssertTrue(central.isEmpty)
    let host = await fixture.devServer.commands()
    XCTAssertTrue(host.isEmpty)
  }

  /// While the library is unreachable, a central chat may fall back to the
  /// host's own workspace route; that also takes the host's identity.
  @MainActor func testCentralChatFallbackToTheHostWorkspaceCarriesItsIdentity() async throws {
    let fixture = try await makeFixture(); let model = fixture.model
    defer { try? FileManager.default.removeItem(at: fixture.root); model.closeWorkspaceStreams() }
    await connect(fixture)
    let id = UUID().uuidString.lowercased()
    model.state.conversations[id] = .init(id: id, title: "Release plan", providerID: "local:codex", runtimeKind: "codex")
    model.online = false
    await model.selectConversation(id)
    XCTAssertEqual(model.executionOwner(of: id), "central")
    XCTAssertEqual(model.selectedExecutionWorkspaceID, fixture.dev.id, "The host's own workspace, never a copied row")
    model.composer = "Still there?"
    await model.send()
    XCTAssertNil(model.errorMessage)
    let commands = await fixture.devServer.commands()
    XCTAssertEqual(commands.map(\.kind), [.send])
    XCTAssertEqual(commands.first?.deviceID, model.memberIdentity?.deviceID)
    XCTAssertEqual(commands.first?.libraryID, fixture.dev.libraryID)
    XCTAssertEqual(commands.first?.workspaceID, fixture.dev.id)
  }
}
