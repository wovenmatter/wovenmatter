import Foundation
import Testing
import WovenProtocol
@testable import WovenServerKit

@Test(.timeLimit(.minutes(1)))
func deletingAFolderDeletesTheDirectoryTheServerMadeAndNeverALinkedOne() async throws {
  let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
  let root = folder.appendingPathComponent("Folders", isDirectory: true)
  let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
  var options = WovenServer.Options(dataFolder: folder, socketPath: socket, listen: nil, appVersion: "test",
                                    machineName: "test", tailnet: StandInTailnet(), runtimes: [StandInRuntime()],
                                    foldersRoot: root)
  options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
  let server = try await WovenServer.start(options)
  defer { server.stopLater() }
  let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
  _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))

  let linkedDirectory = folder.appendingPathComponent("Mine", isDirectory: true)
  try FileManager.default.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
  let linked = try await client.call(CreateFolder(name: "Mine", path: linkedDirectory.path))
  let made = try await client.call(CreateFolder(name: "Made"))
  #expect(!linked.managed && made.managed)
  try Data("x".utf8).write(to: URL(fileURLWithPath: made.path).appendingPathComponent("file.txt"))

  await #expect(throws: ProtocolError.self) {
    _ = try await client.call(DeleteFolder(folderID: linked.id, deleteDirectory: true))
  }
  _ = try await client.call(DeleteFolder(folderID: linked.id))
  _ = try await client.call(DeleteFolder(folderID: made.id, deleteDirectory: true))

  #expect(FileManager.default.fileExists(atPath: linkedDirectory.path))
  #expect(!FileManager.default.fileExists(atPath: made.path))
  #expect(try await client.call(ListFolders()).isEmpty)
}
