import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

private struct LinkedServer {
  let server: WovenServer
  let socket: String

  static func start(name: String, tailnet: StandInTailnet, runtime: StandInRuntime) async throws -> LinkedServer {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
    let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: ("127.0.0.1", 0), appVersion: "test", machineName: name,
      tailnet: tailnet, runtimes: [runtime], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    return LinkedServer(server: try await WovenServer.start(options), socket: socket)
  }

  func connect() async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: .ui, machine: Machine(id: "ui", name: "UI"), appVersion: "test"))
    return client
  }
}

private func text(_ result: ToolResult) -> String {
  result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined(separator: "\n")
}

/// Waits until `check` holds, for up to ten seconds.
private func eventually(_ check: () async throws -> Bool) async throws -> Bool {
  for _ in 0..<400 {
    if try await check() { return true }
    try await Task.sleep(for: .milliseconds(25))
  }
  return false
}

@Test(.timeLimit(.minutes(1)))
func aBotStartsSteersAndFollowsASessionOnAnotherMachine() async throws {
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let gate = StandInRuntime.Gate()
  let a = try await LinkedServer.start(name: "Studio", tailnet: tailnetA, runtime: StandInRuntime())
  let b = try await LinkedServer.start(name: "Laptop", tailnet: tailnetB, runtime: StandInRuntime(gate: gate))
  defer { a.server.stopLater(); b.server.stopLater() }
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
  await a.server.discoverMachines()
  await b.server.discoverMachines()

  // The bot lives on the Studio; the Laptop has a folder of its own.
  try await a.server.library.saveBotMirror(BotMirror(
    bot: .init(id: "b1", name: "Scout", isAdmin: false, manager: false, managerID: nil, orchestrator: false, trashed: false,
               createdAt: Date()),
    chats: [], items: [], checkpoint: "bot:b1", upTo: 0))
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent("woven-repo-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let onB = try await b.connect()
  let folder = try await onB.call(CreateFolder(name: "Repo", path: directory.path))
  #expect(try await eventually { try await a.server.library.folder(folder.id) != nil })
  #expect(try await eventually { try await b.server.library.savedBots().bots.contains { $0.id == "b1" } })

  let tools = try #require(await a.server.bots.toolsForTests)
  let bot = ToolCaller(machineID: a.server.machineID, botID: "b1")
  let places = text(await tools.call("list_places", arguments: .object([:]), caller: bot))
  let laptop = try #require(places.split(separator: "\n").first { $0.hasPrefix("machine \(b.server.machineID) ") })
  #expect(laptop.hasSuffix("| online | runtimes: \(StandInRuntime.kind.rawValue)"), "\(places)")
  #expect(places.contains("folder \(folder.id) | Repo"))

  let started = await tools.call("start_session", arguments: .object([
    "runtime": .string(StandInRuntime.kind.rawValue), "title": .string("Map"), "message": .string("Map the repo."),
    "folderID": .string(folder.id)]), caller: bot)
  #expect(!started.isError, "\(text(started))")
  let sessionID = try #require(text(started).split(separator: " ").dropFirst(2).first.map(String.init))
  let session = try #require(try await b.server.library.session(sessionID))
  #expect(session.machineID == b.server.machineID && session.directory == folder.path)

  // The turn is held after its first piece, so the follow-up steers it.
  let sent = await tools.call("send_to_session", arguments: .object([
    "sessionID": .string(sessionID), "text": .string("Count the files too.")]), caller: bot)
  #expect(!sent.isError, "\(text(sent))")
  let listed = text(await tools.call("list_sessions", arguments: .object([:]), caller: bot))
  #expect(listed.contains("\(sessionID) | Map | \(StandInRuntime.kind.rawValue) | Laptop |") && listed.contains("| running"), "\(listed)")
  let reading = text(await tools.call("read_session", arguments: .object(["sessionID": .string(sessionID)]), caller: bot))
  #expect(reading.hasPrefix("Session \(sessionID): Map (\(StandInRuntime.kind.rawValue)) on Laptop, running"), "\(reading)")

  // A caller that never touched the session may not stop it; the bot that started it may.
  let stranger = ToolCaller(machineID: a.server.machineID, botID: "b2")
  let refused = await tools.call("stop_session", arguments: .object(["sessionID": .string(sessionID)]), caller: stranger)
  #expect(refused.isError && text(refused).contains("only a session you started"), "\(text(refused))")
  let stopped = await tools.call("stop_session", arguments: .object(["sessionID": .string(sessionID)]), caller: bot)
  #expect(text(stopped) == "Stopped Map.", "\(text(stopped))")
  #expect(try await eventually {
    try await onB.call(SessionItems(sessionID: sessionID)).contains { $0.content == .notice(Notice(kind: .interrupted, text: "Stopped by Scout.")) }
  })
  await gate.open()

  // It goes on when the bot sends to it again, and every message on B is the bot's.
  let again = await tools.call("send_to_session", arguments: .object([
    "sessionID": .string(sessionID), "text": .string("Keep going.")]), caller: bot)
  #expect(!again.isError, "\(text(again))")
  #expect(try await eventually {
    let read = text(await tools.call("read_session", arguments: .object(["sessionID": .string(sessionID)]), caller: bot))
    return read.contains(", idle") && read.contains("Scout: Keep going.") && read.contains("This message is from the bot")
  })
  let idle = await tools.call("stop_session", arguments: .object(["sessionID": .string(sessionID)]), caller: bot)
  #expect(text(idle) == "Nothing was running in Map.", "\(text(idle))")
  let messages = try await onB.call(SessionItems(sessionID: sessionID)).filter {
    if case .userMessage = $0.content { true } else { false }
  }
  #expect(messages.map(\.content) == [.userMessage(text: "Map the repo."), .userMessage(text: "Count the files too."),
                                       .userMessage(text: "Keep going.")])
  #expect(messages.allSatisfy { $0.author == ItemAuthor(botID: "b1", name: "Scout") })
}
