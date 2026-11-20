import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

private let appVersion = "test"

/// A server with its own temporary data folder and a short socket path.
private struct TestServer {
  let server: WovenServer
  let socket: String

  static func start(name: String, tailnet: StandInTailnet = StandInTailnet(), listen: Bool = false) async throws -> TestServer {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
    let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: listen ? ("127.0.0.1", 0) : nil, appVersion: appVersion,
      machineName: name, tailnet: tailnet, runtimes: [StandInRuntime()], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    return TestServer(server: try await WovenServer.start(options), socket: socket)
  }

  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: appVersion))
    return client
  }
}

/// Two linked servers, and a database owned by the first that the second has received.
private func linkedPair() async throws -> (owner: TestServer, other: TestServer, onOther: Client, database: Database) {
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let a = try await TestServer.start(name: "Studio", tailnet: tailnetA, listen: true)
  let b = try await TestServer.start(name: "Laptop", tailnet: tailnetB, listen: true)
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
  await a.server.discoverMachines()
  await b.server.discoverMachines()

  let onA = try await a.connect()
  let database = try await onA.call(CreateDatabase(name: "Readings"))
  _ = try await onA.call(ExecuteDatabase(databaseID: database.id, sql: "CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (1)"))
  let onB = try await b.connect()
  for _ in 0..<200 where try await onB.call(ListDatabases()).isEmpty {
    try await Task.sleep(for: .milliseconds(25))
  }
  return (a, b, onB, database)
}

@Test(.timeLimit(.minutes(1)))
func writeThroughAnotherServerIsCarriedOutByTheOwnerAndReadFromTheCopy() async throws {
  let (a, b, onB, database) = try await linkedPair()
  defer { Task { await a.server.stop(); await b.server.stop() } }

  let written = try await onB.call(ExecuteDatabase(databaseID: database.id, sql: "INSERT INTO t VALUES (2), (3)"))
  #expect(written.changes == 2)
  #expect(written.database.machineID == a.server.machineID)

  let onA = try await a.connect()
  #expect(try await onA.call(QueryDatabase(databaseID: database.id, sql: "SELECT n FROM t ORDER BY n")).rows == [["1"], ["2"], ["3"]])
  let read = try await onB.call(QueryDatabase(databaseID: database.id, sql: "SELECT n FROM t ORDER BY n"))
  #expect(read.fromCopy)
  #expect(read.rows == [["1"], ["2"], ["3"]])
  #expect(read.json == #"[{"n":"1"},{"n":"2"},{"n":"3"}]"#)
}

@Test(.timeLimit(.minutes(1)))
func writeWhileTheOwnerIsUnreachableFailsClearly() async throws {
  let (a, b, onB, database) = try await linkedPair()
  defer { Task { await b.server.stop() } }
  await a.server.stop()

  let error = await #expect(throws: ProtocolError.self) {
    _ = try await onB.call(ExecuteDatabase(databaseID: database.id, sql: "INSERT INTO t VALUES (2)"))
  }
  #expect(error?.code == .ownerUnreachable)
  #expect(error?.message.contains("Studio") == true)
  #expect(error?.message.contains("cannot be changed until it is back") == true)
}

@Test(.timeLimit(.minutes(1)))
func writesCannotEscapeTheirDatabaseAndQueriesCannotWrite() async throws {
  let host = try await TestServer.start(name: "Studio")
  defer { Task { await host.server.stop() } }
  let client = try await host.connect()
  let database = try await client.call(CreateDatabase(name: "Readings"))
  _ = try await client.call(ExecuteDatabase(databaseID: database.id, sql: "CREATE TABLE t (n INTEGER); INSERT INTO t VALUES (1)"))

  let refused = [
    "INSERT INTO t VALUES (2); ATTACH DATABASE '/tmp/woven-other.sqlite' AS other",
    "INSERT INTO t VALUES (2); PRAGMA journal_mode = DELETE",
    "INSERT INTO t VALUES (2); COMMIT; INSERT INTO t VALUES (3)",
    "BEGIN; INSERT INTO t VALUES (2); COMMIT",
    "INSERT INTO t VALUES (2); SELECT load_extension('/tmp/woven-extension')",
  ]
  for sql in refused {
    await #expect(throws: ProtocolError.self, "\(sql)") {
      _ = try await client.call(ExecuteDatabase(databaseID: database.id, sql: sql))
    }
  }
  await #expect(throws: ProtocolError.self) {
    _ = try await client.call(QueryDatabase(databaseID: database.id, sql: "INSERT INTO t VALUES (2)"))
  }
  #expect(try await client.call(QueryDatabase(databaseID: database.id, sql: "SELECT n FROM t")).rows == [["1"]])
}
