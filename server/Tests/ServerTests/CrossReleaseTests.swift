import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

private struct Peer {
  let server: WovenServer
  let ui: Client
}

/// Two linked servers on releases 0.4.9 and 0.4.8; `shape` is the Laptop's library shape.
private func linkedPair(laptopShape shape: String) async throws -> (studio: Peer, laptop: Peer) {
  func start(_ name: String, _ version: String, _ shape: String, _ tailnet: StandInTailnet) async throws -> Peer {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
    let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: ("127.0.0.1", 0), appVersion: version, machineName: name,
      tailnet: tailnet, runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    options.libraryShape = shape
    let server = try await WovenServer.start(options)
    let ui = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await ui.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: version))
    return Peer(server: server, ui: ui)
  }
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let studio = try await start("Studio", "0.4.9", Schema.shape, tailnetA)
  let laptop = try await start("Laptop", "0.4.8", shape, tailnetB)
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: laptop.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: studio.server.port!)])
  await studio.server.discoverMachines()
  await laptop.server.discoverMachines()
  return (studio, laptop)
}

/// Waits until `check` holds, for up to ten seconds.
private func eventually(_ check: () async throws -> Bool) async throws -> Bool {
  for _ in 0..<400 {
    if try await check() { return true }
    try await Task.sleep(for: .milliseconds(25))
  }
  return false
}

private func status(of other: Peer, on peer: Peer) async throws -> MachineStatus? {
  try await peer.ui.call(ListMachines()).first { $0.machine.id == other.server.machineID }
}

private func makeFolder(on peer: Peer) async throws -> Folder {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("woven-repo-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return try await peer.ui.call(CreateFolder(name: "Repo", path: directory.path))
}

/// Updating one machine and not the other leaves both online to each other,
/// and while the library is unchanged they sync as before.
@Test(.timeLimit(.minutes(1)))
func machinesOnDifferentReleasesWithOneLibraryShowOnlineAndSync() async throws {
  let (studio, laptop) = try await linkedPair(laptopShape: Schema.shape)
  defer { studio.server.stopLater(); laptop.server.stopLater() }
  let folder = try await makeFolder(on: laptop)

  #expect(try await eventually {
    let onStudio = try await status(of: laptop, on: studio), onLaptop = try await status(of: studio, on: laptop)
    let synced = try await studio.server.library.folder(folder.id) != nil
    return onStudio?.online == true && onStudio?.syncs == true && onStudio?.appVersion == "0.4.8"
      && onLaptop?.online == true && onLaptop?.syncs == true && synced
  })
}

/// With libraries of different shapes the machines stay online to each other
/// and say they can't sync, and nothing passes between them.
@Test(.timeLimit(.minutes(1)))
func machinesWithDifferentLibrariesShowOnlineButDoNotSync() async throws {
  let (studio, laptop) = try await linkedPair(laptopShape: "another shape")
  defer { studio.server.stopLater(); laptop.server.stopLater() }
  let folder = try await makeFolder(on: laptop)

  #expect(try await eventually {
    let onStudio = try await status(of: laptop, on: studio), onLaptop = try await status(of: studio, on: laptop)
    return onStudio?.online == true && onStudio?.syncs == false && onLaptop?.online == true && onLaptop?.syncs == false
  })
  try await Task.sleep(for: .milliseconds(200))
  #expect(try await studio.server.library.folder(folder.id) == nil)
}
