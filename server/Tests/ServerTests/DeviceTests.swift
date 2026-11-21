import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

private let appVersion = "test"

/// A server with its own temporary data folder, listening on the stand-in tailnet.
private struct TestServer {
  let server: WovenServer
  let socket: String

  static func start(name: String, tailnet: StandInTailnet) async throws -> TestServer {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
    let socket = "/tmp/wvd-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: ("127.0.0.1", 0), appVersion: appVersion,
      machineName: name, tailnet: tailnet, runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    return TestServer(server: try await WovenServer.start(options), socket: socket)
  }

  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: appVersion))
    return client
  }

  /// A connection from the tailnet, as a device opens one.
  func dial(_ hello: Hello) async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.tcp(host: "127.0.0.1", port: server.port!)))
    _ = try await client.open(hello)
    return client
  }
}

/// A device's core with no servers reached.
private struct NoPeers: Peers {
  func reached() async -> [String: PeerStatus] { [:] }
  func fetchContent(_ digest: String) async -> Bool { false }
}

/// The protocol error `body` failed with, or nil when it did not fail with one.
private func refusal(_ body: () async throws -> Void) async -> ProtocolError? {
  do {
    try await body()
    return nil
  } catch {
    return error as? ProtocolError
  }
}

private func eventually(_ check: () async throws -> Bool) async throws -> Bool {
  for _ in 0..<400 {
    if try await check() { return true }
    try await Task.sleep(for: .milliseconds(25))
  }
  return false
}

@Test(.timeLimit(.minutes(1)))
func aDeviceAndTheServersConvergeOverTheConnectionTheDeviceOpens() async throws {
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let a = try await TestServer.start(name: "Studio", tailnet: tailnetA)
  let b = try await TestServer.start(name: "Laptop", tailnet: tailnetB)
  defer { a.server.stopLater(); b.server.stopLater() }
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
  await a.server.discoverMachines()
  await b.server.discoverMachines()

  // The device runs the server's core in the app, listening on nothing; its
  // UI talks to it over an in-memory connection and holds a Quick Chat there.
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-device-\(UUID().uuidString)")
  let phone = try await Library.open(folder: folder, machineName: "Phone", platform: .iPhone)
  let core = try await ServerCore.start(library: phone, appVersion: appVersion, runtimes: [StandInRuntime()],
                                        dataFolder: folder, peers: NoPeers())
  defer { Task { await core.stop(); await phone.close(); try? FileManager.default.removeItem(at: folder) } }
  let (uiEnd, coreEnd) = InMemoryTransport.pair()
  Task { await core.serve(coreEnd, origin: .local) }
  let ui = Client(transport: uiEnd)
  _ = try await ui.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: appVersion))
  let chat = try await ui.call(CreateSession(runtime: StandInRuntime.kind, title: "Quick Chat"))
  let watching = try await ui.subscribe(SubscribeSession(sessionID: chat.id))
  var events = watching.events.makeAsyncIterator()
  /// Sends a turn and returns the items announced until the session is idle again.
  func turn(_ text: String) async throws -> [SessionItem] {
    _ = try await ui.call(SendTurn(sessionID: chat.id, text: text))
    var finished: [SessionItem] = []
    while let event = try await events.next() {
      if case .itemFinished(let item) = event { finished.append(item) }
      if event == .runState(.idle) { break }
    }
    return finished
  }
  let announced = try await turn("hello").map(\.id)
  // Each finished item is announced once and saved once, in order.
  #expect(try await phone.items(sessionID: chat.id).map(\.id) == announced)
  #expect(announced.count == 3)
  // With no title runtime, the chat is named from its first message.
  #expect(try await eventually { try await phone.session(chat.id)?.title == "hello" })

  // The runtime calls a Woven tool in the app, with no bridge, and only
  // while the session may use the tool's group.
  func toolCall(in items: [SessionItem]) -> ToolCall? {
    items.lazy.compactMap { if case .toolCall(let call) = $0.content { call } else { nil } }.first
  }
  _ = try await ui.call(UpdateSession(sessionID: chat.id, tools: [.history]))
  let refused = toolCall(in: try await turn(#"woven create_artifact {"kind":"note","title":"Groceries","text":"Milk"}"#))
  #expect(refused?.failed == true)
  _ = try await ui.call(UpdateSession(sessionID: chat.id, tools: [.notes]))
  let created = toolCall(in: try await turn(#"woven create_artifact {"kind":"note","title":"Groceries","text":"Milk"}"#))
  #expect(created?.failed == false)
  #expect(try await phone.artifacts().map(\.title) == ["Groceries"])
  // The bots' saved chats are read from the device's own library.
  #expect(try await ui.call(ListSavedBots()).bots.isEmpty)
  #expect(try await phone.session(chat.id)?.machineID == phone.machineID)

  let device = try #require(try await phone.machine(phone.machineID))
  let toA = try await a.dial(Hello(role: .device, machine: device, appVersion: appVersion))
  let following = Task { try await phone.follow(toA, machineID: a.server.machineID) }
  defer { following.cancel() }

  // The device's chat reaches A, and from A a second server.
  #expect(try await eventually { try await a.server.library.items(sessionID: chat.id).count == 7 })
  #expect(try await eventually { try await b.server.library.items(sessionID: chat.id).count == 7 })
  #expect(try await b.server.library.session(chat.id)?.machineID == phone.machineID)

  // A note written on a server reaches the device.
  let onB = try await b.connect()
  let note = try await onB.call(CreateArtifact(kind: .note, title: "Plans"))
  #expect(try await eventually { (try? await phone.artifact(note.artifact.id)) != nil })

  // A device is not a machine: it is listed only as a device, and what it
  // owns cannot be reached from a server.
  let onA = try await a.connect()
  let machines = try await onA.call(ListMachines())
  #expect(Set(machines.map(\.machine.id)) == [a.server.machineID, b.server.machineID])
  let here = try #require(machines.first { $0.isThisMachine })
  #expect(here.address == "127.0.0.1" && here.port == a.server.port)
  let devices = try await onA.call(ListDevices())
  #expect(devices.map(\.device) == [device])
  #expect(devices.first?.lastSyncedAt != nil)
  let unreachable = await refusal { _ = try await onA.call(SendTurn(sessionID: chat.id, text: "more")) }
  #expect(unreachable?.code == .ownerUnreachable && unreachable?.machineID == phone.machineID)

  // Only a device on the same release hands rows to a server.
  let stale = try await a.dial(Hello(role: .device, machine: device, appVersion: "older"))
  #expect(await refusal { _ = try await stale.call(SyncCursor()) }?.code == .versionMismatch)
  #expect(await refusal { _ = try await stale.call(SyncPull(after: 0)) }?.code == .versionMismatch)
  let empty = SyncPage(rows: [], next: 0, more: false)
  #expect(await refusal { _ = try await onA.call(SyncPush(page: empty)) }?.code == .refused)

  // Removing the device reaches its library, which then starts afresh, and
  // takes its chat from every library.
  _ = try await onB.call(RemoveMachine(machineID: phone.machineID))
  #expect(try await eventually { phone.isRemoved })
  #expect(try await eventually { try await a.server.library.session(chat.id) == nil })
  #expect(try await onA.call(ListDevices()).isEmpty)
}

/// A dotted IPv4 address, built so the tree holds no address but loopback.
private func dotted(_ octets: Int...) -> String {
  octets.map(String.init).joined(separator: ".")
}

@Test
func connectionCodeRoundTripsAndRefusesWhatIsNotATailnetAddress() throws {
  let plain = try #require(ConnectionCode(address: dotted(100, 101, 102, 103)))
  #expect(plain.code.count == 7)
  #expect(ConnectionCode(code: plain.code) == plain)
  #expect(ConnectionCode(code: plain.code.lowercased().replacingOccurrences(of: "-", with: " ")) == plain)
  #expect(ConnectionCode(link: plain.link(scheme: "wovenmatter")) == plain)
  #expect(ConnectionCode(plain.link(scheme: "wovenmatter-dev").absoluteString) == plain)
  #expect(ConnectionCode(link: URL(string: "https://connect/\(plain.code)")!) == nil)

  let development = try #require(ConnectionCode(address: dotted(100, 127, 255, 1), port: 47338))
  #expect(development.code.count == 12)
  let read = try #require(ConnectionCode(development.code))
  #expect(read.address == dotted(100, 127, 255, 1) && read.port == 47338)

  let outside = [dotted(192, 168, 1, 2), dotted(100, 63, 255, 255), dotted(100, 128, 0, 1), dotted(100, 64, 0),
                 dotted(100, 64, 0, 256), "fd7a:115c:a1e0::1"]
  for address in outside {
    #expect(ConnectionCode(address: address) == nil)
  }
  // A mistyped character is caught rather than read as another address.
  var typo = Array(plain.code)
  typo[1] = typo[1] == "X" ? "Y" : "X"
  #expect(ConnectionCode(code: String(typo)) == nil)
}
