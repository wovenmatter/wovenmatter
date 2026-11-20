import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

private let appVersion = "test"

/// A server whose sessions run the stand-in, which calls Woven tools over the
/// session's own tool socket as a runtime's MCP client does.
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

/// Has the session call one Woven tool and returns the tool call it saved.
private func callTool(_ client: Client, from sessionID: String, _ name: String, _ arguments: String) async throws -> ToolCall {
  let subscription = try await client.subscribe(SubscribeSession(sessionID: sessionID))
  _ = try await client.call(SendTurn(sessionID: sessionID, text: "woven \(name) \(arguments)"))
  for try await event in subscription.events {
    if case .itemFinished(let item) = event, case .toolCall(let call) = item.content {
      try await client.unsubscribe(subscription.id)
      return call
    }
  }
  throw ToolFailure("The session ended without a tool call.")
}

/// The first message in a session that another session sent, once it is there.
private func messageFromAnotherSession(_ client: Client, in sessionID: String) async throws -> SessionItem? {
  for _ in 0..<400 {
    if let item = try await client.call(SessionItems(sessionID: sessionID)).first(where: { $0.author?.sessionID != nil }) {
      return item
    }
    try await Task.sleep(for: .milliseconds(25))
  }
  return nil
}

@Test(.timeLimit(.minutes(1)))
func aToolCallFromASessionIsCarriedOutAndAttributedToThatSession() async throws {
  let host = try await TestServer.start(name: "Studio")
  defer { Task { await host.server.stop() } }
  let client = try await host.connect()
  let caller = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Planner"))
  let target = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Builder"))

  let call = try await callTool(client, from: caller.id, "send_to_session",
                                #"{"sessionID":"\#(target.id)","text":"Build the page."}"#)
  #expect(!call.failed)

  let item = try #require(try await messageFromAnotherSession(client, in: target.id))
  #expect(item.content == .userMessage(text: "Build the page."))
  #expect(item.author?.sessionID == caller.id)
  #expect(item.author?.name == "Planner")
}

@Test(.timeLimit(.minutes(1)))
func aToolForAnotherMachineIsForwardedToItsOwner() async throws {
  let tailnetA = StandInTailnet(), tailnetB = StandInTailnet()
  let a = try await TestServer.start(name: "Studio", tailnet: tailnetA, listen: true)
  let b = try await TestServer.start(name: "Laptop", tailnet: tailnetB, listen: true)
  defer { Task { await a.server.stop(); await b.server.stop() } }
  tailnetA.setMachines([TailnetMachine(name: "b", host: "127.0.0.1", port: b.server.port!)])
  tailnetB.setMachines([TailnetMachine(name: "a", host: "127.0.0.1", port: a.server.port!)])
  await a.server.discoverMachines()
  await b.server.discoverMachines()

  let onA = try await a.connect(), onB = try await b.connect()
  let caller = try await onA.call(CreateSession(runtime: StandInRuntime.kind, title: "Planner"))
  let target = try await onB.call(CreateSession(runtime: StandInRuntime.kind, title: "Builder"))
  for _ in 0..<400 where try await onA.call(ListSessions()).contains(where: { $0.id == target.id }) == false {
    try await Task.sleep(for: .milliseconds(25))
  }

  let call = try await callTool(onA, from: caller.id, "send_to_session", #"{"sessionID":"\#(target.id)","text":"Run the tests."}"#)
  #expect(!call.failed, "\(call.output ?? "")")

  // The Laptop, which owns the session, saved the message and ran the turn.
  let item = try #require(try await messageFromAnotherSession(onB, in: target.id))
  #expect(item.content == .userMessage(text: "Run the tests."))
  #expect(item.author?.sessionID == caller.id)
}

@Test(.timeLimit(.minutes(1)))
func aUIToolFailsCleanlyWithNoUIConnected() async throws {
  let host = try await TestServer.start(name: "Studio")
  defer { Task { await host.server.stop() } }
  let client = try await host.connect()
  let session = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Browsing"))

  let call = try await callTool(client, from: session.id, "browser", #"{"action":"tabs"}"#)
  #expect(call.failed)
  #expect(call.output?.contains("needs the Woven Matter app open") == true)
}
