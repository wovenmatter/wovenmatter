#if canImport(CompanionClient) && os(macOS)
import Foundation
import Testing
import CompanionClient
import WovenMatterCompanion
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterLibraryHost

/// An in-process tailnet: each `host:port` routes to a Mac or Linux handler.
/// A Linux host sits behind Tailscale Serve, which strips `/wovenmatter`.
private final class Tailnet: MobileHTTPPerforming, @unchecked Sendable {
  typealias Handler = @Sendable (CompanionHTTPRequest) async -> CompanionHTTPResponse
  private let lock = NSLock()
  private var routes: [String: (strip: Bool, handler: Handler)] = [:]
  private var down: Set<String> = []
  func route(_ authority: String, strip: Bool, _ handler: @escaping Handler) { lock.withLock { routes[authority] = (strip, handler) } }
  func setOnline(_ authority: String, _ online: Bool) { lock.withLock { if online { down.remove(authority) } else { down.insert(authority) } } }

  private static func authority(_ url: URL) -> String { (url.host ?? "") + (url.port.map { ":\($0)" } ?? "") }
  func send(_ url: URL, _ request: CompanionHTTPRequest) async throws -> CompanionHTTPResponse {
    let authority = Self.authority(url)
    guard let route = lock.withLock({ down.contains(authority) ? nil : routes[authority] }) else { throw URLError(.cannotConnectToHost) }
    var target = request.target
    if route.strip, target.hasPrefix("/wovenmatter") { target = String(target.dropFirst("/wovenmatter".count)); if target.isEmpty { target = "/" } }
    let headers = Dictionary(request.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    return await route.handler(.init(method: request.method, target: target, headers: headers, body: request.body))
  }
  // The phone's requests.
  func perform(_ request: URLRequest, maximumBytes: Int, longLived: Bool) async throws -> (Data, HTTPURLResponse) {
    guard let url = request.url else { throw URLError(.badURL) }
    var headers: [String: String] = [:]
    for (name, value) in request.allHTTPHeaderFields ?? [:] { headers[name] = value }
    let response = try await send(url, .init(method: request.httpMethod ?? "GET", target: MobileRequestSigning.target(of: url),
                                             headers: headers, body: request.httpBody ?? Data()))
    return (response.body, HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: response.headers)!)
  }
  // Peer sync between the Mac and the Linux host.
  var peers: LibraryPeerTransport {
    .init { [self] endpoint, request in
      guard let url = URL(string: request.target, relativeTo: endpoint) else { throw URLError(.badURL) }
      return try await send(url, request)
    }
  }
}

/// A Linux workspace's sessions (the Node server's role): signed member
/// requests create sessions here with every Mac offline.
@MainActor private final class LinuxSessions: CompanionCommandServing {
  var created: [CompanionCommand] = []
  var receipts: [String: CompanionCommandReceipt] = [:]
  func providers() -> [CompanionProvider] { [.init(id: "local:default_agent", runtimeKind: "default_agent", displayName: "Agent", routeName: "Box", available: true)] }
  func pendingInteractions() async -> [CompanionPendingInteraction] { [] }
  func sessionCapabilities(conversationID: String) async throws -> CompanionProvider { providers()[0] }
  func transcript(conversationID: String, before: String?) async throws -> CompanionTranscript { .init(conversationID: conversationID) }
  func receipt(commandID: String, deviceID: String) async throws -> CompanionCommandReceipt? { receipts[commandID] }
  func execute(_ command: CompanionCommand, deviceID: String) async throws -> CompanionCommandReceipt {
    created.append(command)
    let receipt = CompanionCommandReceipt(commandID: command.commandID, deviceID: deviceID, status: .completed, conversationID: command.conversationID)
    receipts[command.commandID] = receipt
    return receipt
  }
}

/// A fake Mac (library, members, peer sync, mobile API with pairing) and a
/// Linux library host with its workspace's execution endpoint, joined by an
/// in-process tailnet.
private final class ReachWorld: @unchecked Sendable {
  static let macURL = URL(string: "https://studio.tail1.ts.net/wovenmatter")!
  static let boxURL = URL(string: "https://box.tail1.ts.net/wovenmatter/")!
  let tailnet = Tailnet()
  let linux: LibraryHost
  let macDatabase: WorkspaceDatabase
  let macMembers: MemberDirectory
  let macSync: LibraryPeerSync
  let pairing: CompanionAuthentication
  let workspace: CompanionExecutionWorkspace
  let sessions: LinuxSessions

  init(root: URL) async throws {
    let tailnet = self.tailnet
    let macURL = Self.macURL, boxURL = Self.boxURL
    // The Linux library host.
    let linux = try await LibraryHost(layout: LibraryHostLayout(root: root.appending(path: "box")), name: "Box", endpoints: [boxURL],
                                      transport: tailnet.peers, presenceInterval: 1)
    self.linux = linux
    tailnet.route("box.tail1.ts.net", strip: true) { await linux.handleNetwork($0) }

    // The Mac: its library, member directory, peer sync and mobile API.
    let macStore = try await DashboardStore(supportDirectory: root.appending(path: "mac"))
    try await macStore.prepareLocalWorkspace()
    let macDatabase = macStore.database
    self.macDatabase = macDatabase
    let macMembers = MemberDirectory(database: macDatabase, identity: try MemberIdentity.loadOrCreate(file: root.appending(path: "mac.key"),
      deviceID: try await macDatabase.companionLibraryIdentity().hostDeviceID, kind: .mac), cacheLifetime: 0)
    self.macMembers = macMembers
    try await macMembers.ensureSelf(name: "Studio", endpoints: [macURL])
    var configuration = LibraryPeerSync.Configuration(version: "test")
    configuration.presenceInterval = 1
    let macSync = LibraryPeerSync(directory: macMembers, transport: tailnet.peers, configuration: configuration)
    self.macSync = macSync
    let pairing = try CompanionAuthentication(fileURL: root.appending(path: "mac-devices.json"))
    self.pairing = pairing
    let api = await MainActor.run {
      CompanionWorkspaceAPI(database: macDatabase, authentication: pairing, commands: LibraryHostCommands(executor: WorkspaceToolExecutor(database: macDatabase)),
        isActive: { true }, members: macMembers, onMemberPaired: { id, name, key in
          _ = try? await macMembers.add(deviceID: id, kind: .ios, name: name, publicKey: key, endpoints: [])
        }, syncStatus: { await macSync.status() })
    }
    tailnet.route("studio.tail1.ts.net", strip: false) { request in
      if let response = await macSync.handle(request) { return response }
      return await api.handle(request)
    }
    // The Mac adds the Linux host (as "Add machine" does) and both sync.
    try await macMembers.add(deviceID: linux.identity.deviceID, kind: .linux, name: "Box", publicKey: linux.identity.publicKey, endpoints: [boxURL])
    let token = try String(contentsOf: LibraryHostLayout(root: root.appending(path: "box")).defaultTokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    let adopted = await linux.handleLocal(.init(method: "POST", target: "/v1/members/adopt", headers: ["authorization": "Bearer " + token],
                                                body: try JSONEncoder().encode(await macMembers.adoption())))
    guard adopted.status == 200 else { throw CompanionAPIError(code: "adopt", message: String(decoding: adopted.body, as: UTF8.self)) }
    await linux.startSync(); await macSync.start()

    // The Linux workspace's execution endpoint, registered in the library.
    let linuxLibrary = try await linux.database.companionLibraryIdentity()
    let workspace = CompanionExecutionWorkspace(id: UUID().uuidString.lowercased(), libraryID: linuxLibrary.libraryID,
      ownerDeviceID: linuxLibrary.hostDeviceID, kind: .linux, name: "Box", endpoint: URL(string: "https://box.tail1.ts.net:9443/wovenmatter")!,
      capabilities: ["execution.v1"], executionDeviceID: linuxLibrary.hostDeviceID)
    self.workspace = workspace
    _ = try await linux.database.registerCompanionExecutionWorkspace(.init(workspace: workspace), deviceID: linuxLibrary.hostDeviceID)
    let sessions = await MainActor.run { LinuxSessions() }
    self.sessions = sessions
    let execution = await MainActor.run {
      CompanionMacExecutionAPI(database: linux.database, commands: sessions,
        authentication: try! CompanionExecutionAuthentication(fileURL: root.appending(path: "box-execution.json")),
        descriptor: workspace, isActive: { true }, members: linux.members)
    }
    tailnet.route("box.tail1.ts.net:9443", strip: false) { await execution.handle($0) }
  }
}

@Suite("iPhone reaches every member", .serialized)
struct PhoneReachTests {
  private static func waitUntil(_ condition: () async throws -> Bool) async throws -> Bool {
    for _ in 0..<300 { if try await condition() { return true }; try await Task.sleep(for: .milliseconds(50)) }
    return false
  }

  /// Pair once with a Mac, sync through it, then lose it: the phone fails over
  /// to the Linux library host, keeps its writing, creates a session on the
  /// Linux workspace with every Mac offline, and still works after a restart
  /// with the paired Mac gone. When the Linux host drops and the Mac returns,
  /// it fails back without re-uploading anything.
  @Test func phoneSyncsAndRunsSessionsWithThePairedMacGone() async throws {
    let root = URL(fileURLWithPath: "/tmp").appending(path: "wmr-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let world = try await ReachWorld(root: root)
    defer { world.linux.stop() }
    let tailnet = world.tailnet, linux = world.linux, macDatabase = world.macDatabase, macMembers = world.macMembers
    let macSync = world.macSync, pairing = world.pairing, workspace = world.workspace, sessions = world.sessions
    let macURL = ReachWorld.macURL
    let linuxLibrary = try await linux.database.companionLibraryIdentity()

    // The phone pairs once with the Mac, presenting its member key.
    let store = try MobileStore(file: root.appending(path: "phone/library.json"))
    let phoneID = await store.snapshot().deviceID
    let keys = MobileMemberKeyStorage.memory()
    let identity = try MobileMemberKeyVault.loadOrCreate(deviceID: phoneID, storage: keys)
    let offer = try await pairing.createOffer(endpoint: macURL)
    let paired = try await HTTPSCompanionTransport.pair(offer.payload, deviceID: phoneID, deviceName: "iPhone",
      metadata: .init(kind: .iPhone), memberPublicKey: identity.publicKey, performer: tailnet)
    #expect(await macMembers.member(phoneID)?.kind == .ios)
    try await store.prepareForPairing(paired.workspaceID)
    let membershipFile = root.appending(path: "phone/membership.json")
    let hosts = try MobileLibraryHosts(state: .init(deviceID: phoneID, pairedEndpoint: macURL), identity: identity, file: membershipFile, performer: tailnet)
    var engine = MobileSyncEngine(store: store, hosts: hosts, initial: try await hosts.transport(for: .init(deviceID: "paired", kind: "mac", name: "Studio", endpoint: macURL)))
    try await engine.synchronize()
    #expect(await store.snapshot().workspaceID == paired.workspaceID)
    #expect(await hosts.snapshot().pairedHostDeviceID == macMembers.identity.deviceID)
    #expect(await hosts.snapshot().members.contains { $0.kind == "linux" && $0.name == "Box" })

    // Writing on the phone reaches the Mac, and peer sync takes it to Linux.
    let note = try await store.createNote(folderID: nil, title: "Groceries", content: try NoteDocument(blocks: [.richText(.init(id: "b", text: "milk"))]).encoded())
    try await engine.synchronize()
    #expect(try await macDatabase.companionNote(id: note.id) != nil)
    #expect(try await Self.waitUntil { try await linux.database.companionNote(id: note.id) != nil })
    // The Linux host learned the phone from the Mac's records.
    #expect(try await Self.waitUntil { await linux.members.member(phoneID) != nil })

    // The paired Mac goes offline. The phone keeps writing and fails over.
    tailnet.setOnline("studio.tail1.ts.net", false)
    await macSync.stop()
    let edited = try NoteDocument(blocks: [.richText(.init(id: "b", text: "milk, eggs"))]).encoded()
    try await store.editNote(id: note.id, title: "Groceries", content: edited, folderID: nil)
    let second = try await store.createNote(folderID: nil, title: "While the Mac was away", content: try NoteDocument(blocks: [.richText(.init(id: "c", text: "hello"))]).encoded())
    try await engine.synchronize()
    let afterFailover = await store.snapshot()
    #expect(afterFailover.workspaceID == linuxLibrary.libraryID)
    #expect(afterFailover.outbox.isEmpty, "\(afterFailover.outbox)")
    #expect(afterFailover.conflicts.isEmpty, "\(afterFailover.conflicts)")
    #expect(await engine.synchronizationStatus().libraryHost?.kind == "linux")
    #expect(try await linux.database.companionNote(id: note.id)?.content == edited)
    #expect(try await linux.database.companionNote(id: second.id) != nil)

    // A session on the Linux workspace, signed by the phone, with every Mac offline.
    let client = WorkspaceClient(store: store, workspaceID: workspace.id,
      transport: try HTTPSExecutionWorkspaceTransport(workspace: workspace, identity: identity, performer: tailnet))
    #expect(try await client.providers().map(\.id) == ["local:default_agent"])
    let conversation = UUID().uuidString.lowercased()
    var create = CompanionCommand(deviceID: phoneID, kind: .createSession, conversationID: conversation, providerID: "local:default_agent")
    create.libraryID = workspace.libraryID
    let receipt = try await client.submit(create)
    #expect(receipt.status == .completed)
    #expect(await MainActor.run { sessions.created.map(\.conversationID) } == [conversation])

    // A restart with the paired Mac gone for good: the saved membership goes
    // straight to the Linux host.
    let restored = try #require(try MobileLibraryHosts.load(file: membershipFile))
    #expect(restored.candidates().first?.kind == "linux")
    let reopened = try MobileStore(file: root.appending(path: "phone/library.json"))
    let restartedHosts = try MobileLibraryHosts(state: restored, identity: try MobileMemberKeyVault.loadOrCreate(deviceID: phoneID, storage: keys),
                                                file: membershipFile, performer: tailnet)
    engine = MobileSyncEngine(store: reopened, hosts: restartedHosts, initial: try await restartedHosts.transport(for: restored.candidates()[0]))
    _ = try await reopened.createNote(folderID: nil, title: "After restart", content: try NoteDocument(blocks: [.richText(.init(id: "d", text: "still here"))]).encoded())
    try await engine.synchronize()
    #expect(await reopened.snapshot().outbox.isEmpty)
    #expect(try await linux.database.companionSnapshot().notes.contains { $0.title == "After restart" })

    // The Mac returns and catches up from Linux; then Linux drops and the
    // phone fails back to the Mac, rebasing on the Mac's revisions.
    tailnet.setOnline("studio.tail1.ts.net", true)
    await macSync.start()
    #expect(try await Self.waitUntil { try await macDatabase.companionNote(id: note.id)?.content == edited })
    #expect(try await Self.waitUntil { try await macDatabase.companionSnapshot().notes.contains { $0.title == "After restart" } })
    tailnet.setOnline("box.tail1.ts.net", false)
    let latest = try NoteDocument(blocks: [.richText(.init(id: "b", text: "milk, eggs, bread"))]).encoded()
    try await reopened.editNote(id: note.id, title: "Groceries", content: latest, folderID: nil)
    try await engine.synchronize()
    let back = await reopened.snapshot()
    #expect(back.workspaceID == paired.workspaceID)
    #expect(back.outbox.isEmpty && back.conflicts.isEmpty, "\(back.outbox) \(back.conflicts)")
    #expect(try await macDatabase.companionNote(id: note.id)?.content == latest)
    // Nothing was duplicated by the moves.
    #expect(try await macDatabase.companionSnapshot().notes.filter { $0.title == "Groceries" }.count == 1)
    await macSync.stop()
  }
  /// Not a test: keeps the fake Mac and Linux host listening on loopback so a
  /// Debug simulator build can pair and sync with them
  /// (`WOVENMATTER_DEV_TAILNET="studio.tail1.ts.net=18431,box.tail1.ts.net=18432,box.tail1.ts.net:9443=18433"`).
  /// Writes the pairing link to `<dir>/pairing-link`; creating `<dir>/mac-offline`
  /// or `<dir>/box-offline` takes that host off the tailnet.
  @Test(.enabled(if: ProcessInfo.processInfo.environment["WOVENMATTER_PHONE_REACH_SERVE_DIR"] != nil))
  func serveFakeHostsForASimulator() async throws {
    let directory = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["WOVENMATTER_PHONE_REACH_SERVE_DIR"]))
    let seconds = Int(ProcessInfo.processInfo.environment["WOVENMATTER_PHONE_REACH_SERVE_SECONDS"] ?? "900") ?? 900
    let root = URL(fileURLWithPath: "/tmp").appending(path: "wmr-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: root) }
    let world = try await ReachWorld(root: root)
    defer { world.linux.stop() }
    for (title, text) in [("Trip plan", "Book the train"), ("Ideas", "A garden bench")] {
      let content = try NoteDocument(blocks: [.richText(.init(id: "a", text: text))]).encoded()
      _ = try await world.macDatabase.applyCompanionMutation(.init(deviceID: UUID().uuidString.lowercased(), kind: .createNote,
        resourceID: UUID().uuidString.lowercased(), title: title, content: content))
    }
    var servers: [CompanionSocketHTTPServer] = []
    for (authority, port) in [("studio.tail1.ts.net", 18431), ("box.tail1.ts.net", 18432), ("box.tail1.ts.net:9443", 18433)] {
      let tailnet = world.tailnet
      let server = CompanionSocketHTTPServer { request in
        do { return try await tailnet.send(URL(string: "https://" + authority)!, request) }
        catch { return .error("unavailable", "offline", status: 503) }
      }
      _ = try server.start(.loopback(port: UInt16(port)))
      servers.append(server)
    }
    defer { for server in servers { server.stop() } }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var offerAt = Date.distantPast
    for _ in 0..<seconds {
      if Date().timeIntervalSince(offerAt) > 240 {
        let offer = try await world.pairing.createOffer(endpoint: ReachWorld.macURL)
        try offer.payload.encodedURL.absoluteString.write(to: directory.appending(path: "pairing-link"), atomically: true, encoding: .utf8)
        offerAt = Date()
      }
      for (name, authority) in [("mac-offline", "studio.tail1.ts.net"), ("box-offline", "box.tail1.ts.net")] {
        world.tailnet.setOnline(authority, !FileManager.default.fileExists(atPath: directory.appending(path: name).path))
      }
      let status = await world.macSync.status()
      let line = "members=\((try? await world.macMembers.list().members.count) ?? 0) sessions=\(await MainActor.run { world.sessions.created.count }) peers=\(status.peers.map { "\($0.name):\($0.state.rawValue)" })\n"
      try line.write(to: directory.appending(path: "status"), atomically: true, encoding: .utf8)
      try await Task.sleep(for: .seconds(1))
    }
    await world.macSync.stop()
  }
}
#endif
