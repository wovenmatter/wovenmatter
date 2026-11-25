import Foundation
import Testing
import WovenProtocol
@testable import WovenServerKit

/// Another Mac's UI asks this Mac's server to update the app: the server
/// hands it to the UI on this Mac, and its answer comes back. A Linux server
/// refuses it.
@Test(.timeLimit(.minutes(1)))
func anotherMacsRequestToUpdateReachesThisMacsAppAndItsAnswerComesBack() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
  let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
  var options = WovenServer.Options(
    dataFolder: folder, socketPath: socket, listen: ("127.0.0.1", 0), appVersion: "0.4.8", machineName: "Studio",
    tailnet: StandInTailnet(), runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
  options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  let server = try await WovenServer.start(options)
  defer { server.stopLater() }

  // Another Mac's UI, over the tailnet address.
  let other = Client(transport: try await connectWebSocket(.tcp(host: "127.0.0.1", port: server.port!)))
  _ = try await other.open(Hello(role: .ui, machine: Machine(id: "other-ui", name: "UI"), appVersion: "0.4.9"))
  guard MachinePlatform.current == .mac else {
    // A Linux server is updated over SSH from a Mac, never asked this.
    await #expect(throws: ProtocolError.self) { _ = try await other.call(UpdateApp()) }
    return
  }

  // The app on this Mac, answering the update call the way it would.
  let app = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await app.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "0.4.8"))
  let calls = try await app.subscribe(SubscribeUITools())
  let answers = Task {
    var seen: [String] = []
    for try await call in calls.events {
      seen.append(call.tool)
      let result: ToolResult = seen.count == 1 ? .text("Updating.") : .error("Woven Matter is already up to date on this Mac.")
      try await app.call(AnswerUITool(id: call.id, result: result))
      if seen.count == 2 { break }
    }
    return seen
  }

  _ = try await other.call(UpdateApp())
  await #expect(throws: ProtocolError.self) { _ = try await other.call(UpdateApp()) }
  #expect(try await answers.value == [UIToolBroker.appUpdateTool, UIToolBroker.appUpdateTool])
}
