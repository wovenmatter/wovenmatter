import Foundation
import Testing
import WovenLibrary
import WovenProtocol
@testable import WovenServerKit

private let appVersion = "test"

/// A server with the stand-in runtime and a scheduler clock `offset` ahead.
private struct TestServer {
  let server: WovenServer
  let folder: URL
  let socket: String

  static func start(folder: URL? = nil, store: StandInRuntime.NativeStore, offset: TimeInterval = 0) async throws -> TestServer {
    let folder = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("woven-server-\(UUID().uuidString)")
    let socket = "/tmp/wvt-\(UUID().uuidString.prefix(8)).sock"
    var options = WovenServer.Options(
      dataFolder: folder, socketPath: socket, listen: nil, appVersion: appVersion, machineName: "test",
      tailnet: StandInTailnet(), runtimes: [StandInRuntime(store: store)], discoveryInterval: .seconds(3600))
    options.secretStore = FileSecretStore(file: folder.appendingPathComponent("secrets.json"))
    options.schedulerClock = { Date().addingTimeInterval(offset) }
    return TestServer(server: try await WovenServer.start(options), folder: folder, socket: socket)
  }

  func connect(role: Hello.Role = .ui) async throws -> Client {
    let client = Client(transport: try await connectWebSocket(.unix(path: socket)))
    _ = try await client.open(Hello(role: role, machine: Machine(id: "ui", name: "UI"), appVersion: appVersion))
    return client
  }
}

private func task(on machineID: String, startsAt: Date, recurrence: Recurrence? = nil) -> ScheduleDraft {
  ScheduleDraft(machineID: machineID, kind: .task, title: "Morning report", prompt: "Write the report.",
                runtime: StandInRuntime.kind, startsAt: startsAt, timeZone: "UTC", recurrence: recurrence)
}

/// The prompts the task has sent, in every session.
private func runs(_ client: Client) async throws -> [SessionItem] {
  var found: [SessionItem] = []
  for session in try await client.call(ListSessions()) {
    found += try await client.call(SessionItems(sessionID: session.id)).filter { $0.author?.source == .scheduledTask }
  }
  return found
}

private func waitFor(_ condition: () async throws -> Bool) async throws {
  for _ in 0..<400 {
    if try await condition() { return }
    try await Task.sleep(for: .milliseconds(25))
  }
}

@Test(.timeLimit(.minutes(1)))
func anEntryFiresOnceAcrossARestart() async throws {
  let store = StandInRuntime.NativeStore()
  let first = try await TestServer.start(store: store)
  let client = try await first.connect()
  let entry = try await client.call(SaveSchedule(draft: task(on: first.server.machineID, startsAt: Date().addingTimeInterval(1))))
  try await waitFor { try await runs(client).count == 1 }
  #expect(try await runs(client).count == 1)
  await first.server.stop()

  let second = try await TestServer.start(folder: first.folder, store: store)
  defer { Task { await second.server.stop() } }
  let again = try await second.connect()
  try await Task.sleep(for: .seconds(2))
  #expect(try await runs(again).count == 1)
  let state = try #require(try await again.call(ListSchedules()).first { $0.id == entry.id }?.state)
  #expect(state.nextFireAt == nil)
  #expect(state.lastSessionID != nil)
}

@Test(.timeLimit(.minutes(1)))
func runsMissedWhileTheServerWasOffRunOnceLateThenCarryOn() async throws {
  let store = StandInRuntime.NativeStore()
  let first = try await TestServer.start(store: store)
  let client = try await first.connect()
  let start = Date().addingTimeInterval(30)
  let entry = try await client.call(SaveSchedule(draft: task(on: first.server.machineID, startsAt: start,
                                                             recurrence: Recurrence(unit: .minute))))
  try await waitFor { try await client.call(ListSchedules()).first?.state?.nextFireAt != nil }
  await first.server.stop()

  // Ten minutes later: ten runs were missed.
  let later: TimeInterval = 600
  let second = try await TestServer.start(folder: first.folder, store: store, offset: later)
  defer { Task { await second.server.stop() } }
  let again = try await second.connect()
  try await waitFor { try await runs(again).count >= 1 }
  try await Task.sleep(for: .seconds(1))
  #expect(try await runs(again).count == 1)
  let state = try #require(try await again.call(ListSchedules()).first { $0.id == entry.id }?.state)
  let now = Date().addingTimeInterval(later)
  let next = try #require(state.nextFireAt)
  #expect(next > now && next <= now.addingTimeInterval(60))
  #expect(abs((state.lastFiredAt ?? .distantPast).timeIntervalSince(start)) < 0.01)
}

@Test(.timeLimit(.minutes(1)))
func aGoalContinuesUntilTheAgentSaysItIsMet() async throws {
  let host = try await TestServer.start(store: StandInRuntime.NativeStore())
  defer { Task { await host.server.stop() } }
  let client = try await host.connect()
  let session = try await client.call(CreateSession(runtime: StandInRuntime.kind, title: "Builder"))
  _ = try await client.call(SetGoal(sessionID: session.id, goal: "The page builds."))

  func continuations() async throws -> Int {
    try await client.call(SessionItems(sessionID: session.id)).filter { $0.author?.source == .goal }.count
  }
  try await waitFor { try await continuations() >= 3 }
  #expect(try await continuations() >= 3)

  // The agent calls `goal_met`, as its runtime's MCP client would.
  let server = try await host.connect(role: .server)
  let result = try await server.call(CallTool(name: "goal_met", arguments: .object(["evidence": .string("It builds.")]),
                                              caller: ToolCaller(machineID: host.server.machineID, sessionID: session.id)))
  #expect(!result.isError)
  try await Task.sleep(for: .milliseconds(300))
  let settled = try await client.call(SessionItems(sessionID: session.id)).count
  try await Task.sleep(for: .milliseconds(500))
  let items = try await client.call(SessionItems(sessionID: session.id))
  #expect(items.count == settled)
  #expect(items.contains { if case .notice(let notice) = $0.content { notice.kind == .goalMet } else { false } })
  #expect(try await client.call(ListSessions()).first { $0.id == session.id }?.goal == nil)
}
