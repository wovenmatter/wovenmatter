import Foundation
import Testing
import WovenProtocol
@testable import WovenServerKit

private func startServer(name: String, tailnet: StandInTailnet, port: Int = 0) async throws -> (WovenServer, String) {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
  let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
  var options = WovenServer.Options(
    dataFolder: folder, socketPath: socket, listen: ("127.0.0.1", port), appVersion: "test", machineName: name,
    tailnet: tailnet, runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
  options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  return (try await WovenServer.start(options), socket)
}

/// Waits for the next machine list in which `check` holds for the Laptop.
private func next(_ events: AsyncThrowingStream<[MachineStatus], any Error>, _ id: String,
                  _ check: (MachineStatus?) -> Bool) async throws -> MachineStatus? {
  for try await statuses in events {
    let laptop = statuses.first { $0.machine.id == id }
    if check(laptop) { return laptop }
  }
  return nil
}

/// A machine the library already holds, whose server is linked or lost after
/// the UI read the list, reaches the UI: online with where its server
/// answers, then offline. Nothing in the library changes meanwhile.
@Test(.timeLimit(.minutes(1)))
func aMachineLinkedAfterTheListWasReadReachesTheUI() async throws {
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let (a, socket) = try await startServer(name: "Studio", tailnet: tailnetA)
  let (b, _) = try await startServer(name: "Laptop", tailnet: tailnetB)
  defer { a.stopLater(); b.stopLater() }
  let laptop = [TailnetMachine(name: "b", host: "127.0.0.1", port: b.port!)]

  let ui = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await ui.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))
  let machines = try await ui.subscribe(SubscribeMachines())
  #expect(machines.reply.map(\.machine.id) == [a.machineID])

  tailnetA.setMachines(laptop)
  await a.discoverMachines()
  #expect(try await next(machines.events, b.machineID) { $0?.online == true } != nil)

  tailnetA.setMachines([])
  await a.discoverMachines()
  #expect(try await next(machines.events, b.machineID) { $0?.online == false } != nil)

  tailnetA.setMachines(laptop)
  await a.discoverMachines()
  let online = try await next(machines.events, b.machineID) { $0?.online == true }
  #expect(online?.address == "127.0.0.1" && online?.port == b.port)
}

/// A link asleep between attempts at an address with no server yet tries
/// again at once when asked, so a server that has just started links within
/// a moment rather than after the backoff.
@Test(.timeLimit(.minutes(1)))
func aSleepingLinkRetriedNowLinksAtOnce() async throws {
  let tailnetA = StandInTailnet()
  let (a, socket) = try await startServer(name: "Studio", tailnet: tailnetA)
  // A port with nothing on it: a server's, stopped.
  let (gone, _) = try await startServer(name: "Gone", tailnet: StandInTailnet())
  let port = gone.port!
  await gone.stop()
  defer { a.stopLater() }

  let ui = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await ui.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))
  let machines = try await ui.subscribe(SubscribeMachines())
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: port)])
  await a.discoverMachines()
  // Failed at 0, 1 and 3 s; asleep until 7 s.
  try await Task.sleep(for: .seconds(3.5))

  let (b, _) = try await startServer(name: "Laptop", tailnet: StandInTailnet(), port: port)
  defer { b.stopLater() }
  let asked = ContinuousClock.now
  await a.retryMachinesNow()
  #expect(try await next(machines.events, b.machineID) { $0?.online == true } != nil)
  #expect(ContinuousClock.now - asked < .seconds(2))
}
