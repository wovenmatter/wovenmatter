import Foundation
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
  let dial: Machines.Dial = { _, _ in connect(.tailnet(name: "phone")) }
  let model = Model()
  await model.then(
    { $0.toolCall(id: "call-1", name: "render_html", arguments: ["html": "<html><body>Hi</body></html>", "title": "Hi"]) },
    { $0.text("Shown.") })
  let phone = try await Device.start(model, dial: dial)
  defer {
    Task {
      await phone.device.stop(); await core.stop(); await mac.close()
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

  // Removed from the Mac, the device starts again empty and forgets the Mac.
  let removed = phone.device.library.machineID
  try await mac.removeMachine(removed)
  #expect(try await eventually { phone.device.library.machineID != removed })
  #expect(try await phone.device.library.sessions().isEmpty)
  #expect(!FileManager.default.fileExists(atPath: phone.folder.appendingPathComponent("machines.json").path))
}
