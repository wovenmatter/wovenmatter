import Foundation
import Synchronization
import Testing
import WovenLibrary
import WovenProtocol
import WovenServerCore
@testable import WovenDevice

// The device and a server's core standing in for a Mac, over the connection
// the device opens (an in-memory one in place of the tailnet). Sync through a
// real server over WebSocket is covered in server/Tests (DeviceTests).

private struct NoPeers: Peers {
  func reached() async -> [String: PeerStatus] { [:] }
  func fetchContent(_ digest: String) async -> Bool { false }
}

/// Whether the stand-in Mac answers.
private final class Reachable: Sendable {
  let on = Mutex(true)
}

private func eventually(_ check: () async throws -> Bool) async throws -> Bool {
  for _ in 0..<400 {
    if try await check() { return true }
    try await Task.sleep(for: .milliseconds(25))
  }
  return false
}

@Test(.timeLimit(.minutes(1)))
func aDeviceSyncsWithTheMacItAddsAndStartsAgainWhenRemoved() async throws {
  let macFolder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-mac-\(UUID().uuidString)")
  let mac = try await Library.open(folder: macFolder, machineName: "Studio", platform: .mac)
  let core = try await ServerCore.start(library: mac, appVersion: appVersion, runtimes: [StandInRuntime()],
                                        dataFolder: macFolder, peers: NoPeers())
  @Sendable func connect(_ origin: Caller.Origin) -> any MessageTransport {
    let (ours, theirs) = InMemoryTransport.pair()
    Task { await core.serve(theirs, origin: origin) }
    return ours
  }
  let reachable = Reachable()
  let dial: Machines.Dial = { _, _ in
    guard reachable.on.withLock({ $0 }) else { throw ConnectionClosed() }
    return connect(.tailnet(name: "phone"))
  }
  let model = Model()
  await model.then(
    { $0.toolCall(id: "call-1", name: "render_html", arguments: ["html": "<html><body>Hi</body></html>", "title": "Hi"]) },
    { $0.text("Shown.") })
  let phone = try await Device.start(model, dial: dial)
  defer {
    Task {
      await core.stop(); await mac.close()
      try? FileManager.default.removeItem(at: phone.folder); try? FileManager.default.removeItem(at: macFolder)
    }
  }

  // A Quick Chat with a visual reply, before the device knows any machine.
  let chat = try await phone.ui.call(CreateSession(runtime: .piDurable, title: "Quick Chat"))
  let watching = try await phone.watch(chat.id)
  _ = try await phone.ui.call(SendTurn(sessionID: chat.id, text: "show hi"))
  try await watching.idle(after: 1)
  let reply = try #require(await watching.finished.compactMap { item -> VisualReply? in
    if case .visualReply(let reply) = item.content { reply } else { nil }
  }.first)

  // Adding the Mac syncs both ways; the visual reply's content reaches it too.
  let code = try #require(ConnectionCode(code: "000-0AK"))
  try await phone.device.add(code)
  #expect(try await eventually { try await mac.items(sessionID: chat.id).count == 4 })
  #expect(try await mac.hasContent(reply.digest))
  let onMac = Client(transport: connect(.local))
  _ = try await onMac.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI", platform: .mac), appVersion: appVersion))
  let note = try await onMac.call(CreateArtifact(kind: .note, title: "Groceries"))
  #expect(try await eventually { (try? await phone.device.library.artifact(note.artifact.id)) != nil })
  let listed = try await phone.ui.call(ListMachines())
  #expect(listed.map(\.machine.id) == [mac.machineID] && listed.first?.online == true)

  // A device on another release is refused, naming the machine.
  let stale = try await Device.start(Model(), release: "older", dial: dial)
  defer { Task { await stale.device.stop(); try? FileManager.default.removeItem(at: stale.folder) } }
  await #expect(throws: DeviceConnectionError.otherRelease(machineName: "Studio", appVersion: appVersion)) {
    try await stale.device.add(code)
  }

  // Started again while the Mac does not answer, the device still lists it
  // where it was last reached, offline, so the UI can keep trying it.
  await phone.device.stop()
  reachable.on.withLock { $0 = false }
  let again = try await Device.start(model, folder: phone.folder, dial: dial)
  defer { Task { await again.device.stop() } }
  let remembered = try await again.ui.call(ListMachines())
  #expect(remembered.map(\.machine.id) == [mac.machineID])
  #expect(remembered.first.map { [$0.address, $0.port.map(String.init), $0.appVersion] }
            == [code.address, String(code.port), appVersion])
  #expect(remembered.first?.online == false)
  reachable.on.withLock { $0 = true }
  await again.device.setActive(false)
  await again.device.setActive(true)

  // Removed from the Mac, the device starts again empty and forgets the Mac.
  let removed = again.device.library.machineID
  try await mac.removeMachine(removed)
  #expect(try await eventually { again.device.library.machineID != removed })
  #expect(try await again.device.library.sessions().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: phone.folder.appendingPathComponent("machines.json").path))
}
