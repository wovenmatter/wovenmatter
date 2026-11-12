import Foundation
import Testing
@testable import WovenMatterShared
import WovenMatterCore
import WovenMatterDashboardStore
@testable import WovenMatterLibraryHost

/// Timers of a Linux session and of a bot fire from the library host with no Mac:
/// the host claims due occurrences, the Node server delivers and settles them.
@Suite("wovenmatter-library timers", .serialized)
struct LibraryHostTimersTests {
  private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

  private func host() async throws -> (LibraryHost, URL) {
    let directory = URL(fileURLWithPath: "/tmp").appending(path: "wmt-\(UUID().uuidString.prefix(8))")
    return (try await LibraryHost(layout: LibraryHostLayout(root: directory)), directory)
  }

  private func call(_ host: LibraryHost, caller: String, bot: Bool = false, _ name: String,
                    _ arguments: [String: GatewayJSONValue], groups: Set<WorkspaceToolGroup>) async throws -> WovenMatterToolResponse {
    let message: GatewayJSONValue = .object(["jsonrpc": .string("2.0"), "id": .number(1), "method": .string("tools/call"),
      "params": .object(["name": .string(name), "arguments": .object(arguments)])])
    let callerID: String
    if bot { callerID = caller; try await host.database.registerBotCaller(caller, displayName: "Scheduler") }
    else { callerID = try await host.ensureCaller(caller, groups: groups) }
    let executor = WorkspaceToolExecutor(database: host.database)
    let reply = await WovenMCPServer.handle(message, allowedTools: LibraryHost.allowedTools(groups, context: false),
                                            outsideCaller: bot, botCaller: bot) { request in
      await executor.execute(request, callerID: callerID, handlers: WorkspaceToolHandlers())
    }
    let content = try #require(reply?.objectValue?["result"]?.objectValue?["structuredContent"], "\(String(describing: reply))")
    return try JSONDecoder().decode(WovenMatterToolResponse.self, from: JSONEncoder().encode(content))
  }

  @Test func aSessionTimerFiresOnceAndIsSettledHere() async throws {
    let (host, directory) = try await host(); defer { host.stop(); try? FileManager.default.removeItem(at: directory) }
    let session = UUID().uuidString.lowercased()
    #expect(LibraryHost.servedGroups.contains(.timers))
    let created = try await call(host, caller: session, "woven_timers_create",
      ["at": .string(Self.iso(Date().addingTimeInterval(-1))), "text": .string("Check the build"),
       "requestID": .string(UUID().uuidString.lowercased())], groups: [.notes, .timers])
    #expect(created.success, "\(created.error ?? "")")
    let due = try await host.timers.due()
    let occurrence = try #require(due.occurrences.first)
    #expect(due.occurrences.count == 1 && occurrence.kind == "session" && occurrence.target == session && occurrence.text == "Check the build")
    // Offered again until settled (a server that stopped mid-delivery retries it).
    #expect(try await host.timers.due().occurrences.map(\.deliveryID) == [occurrence.deliveryID])
    try await host.timers.settle(.init(timerID: occurrence.timerID, deliveryID: occurrence.deliveryID, outcome: "accepted"))
    #expect(try await host.timers.due().occurrences.isEmpty)
    let timer = try #require(try await host.database.sessionTimers(sessionID: session).first)
    #expect(timer.isPaused && timer.pendingDeliveryID == nil)
    #expect(try await host.database.toolDelivery(id: occurrence.deliveryID)?.status == "accepted")
  }

  @Test func aBotSchedulesItsOwnTimerAndIsWokenByIt() async throws {
    let (host, directory) = try await host(); defer { host.stop(); try? FileManager.default.removeItem(at: directory) }
    var settings = try await host.database.toolSettings()
    settings.botMCP = .init(isEnabled: true, groups: [.timers])
    try await host.database.saveToolSettings(settings)
    let botID = UUID().uuidString.lowercased(), principal = WovenMCPCaller.bot(machineID: host.identity.deviceID, botID: botID)
    let start = Date()
    // No session: a bot's timers are its own schedule.
    let created = try await call(host, caller: principal, bot: true, "woven_timers_create",
      ["at": .string(Self.iso(start.addingTimeInterval(-1))), "every": .number(3_600), "text": .string("Morning report"),
       "requestID": .string(UUID().uuidString.lowercased())], groups: [.timers])
    #expect(created.success, "\(created.error ?? "")")
    let listed = try await call(host, caller: principal, bot: true, "woven_timers_list", [:], groups: [.timers])
    #expect(listed.result?.objectValue?["rows"]?.arrayValue?.count == 1)
    let first = try #require(try await host.timers.due(now: start).occurrences.first)
    #expect(first.kind == "bot" && first.botID == botID && first.target == principal)
    // An undelivered occurrence waits 30 seconds, then is offered again.
    try await host.timers.settle(.init(timerID: first.timerID, deliveryID: first.deliveryID, outcome: "retry"), now: start)
    #expect(try await host.timers.due(now: start).occurrences.isEmpty)
    let retried = try #require(try await host.timers.due(now: start.addingTimeInterval(31)).occurrences.first)
    #expect(retried.deliveryID == first.deliveryID)
    try await host.timers.settle(.init(timerID: first.timerID, deliveryID: first.deliveryID, outcome: "accepted"), now: start.addingTimeInterval(31))
    let timer = try #require(try await host.database.sessionTimers(sessionID: principal).first)
    #expect(!timer.isPaused && timer.nextFireAt > start.addingTimeInterval(3_000))
    #expect(try await host.timers.due(now: start.addingTimeInterval(60)).nextFireAt == Self.iso(timer.nextFireAt))

    // Another bot cannot be scheduled by this one, and another machine's bot fires there.
    let other = WovenMCPCaller.bot(machineID: host.identity.deviceID, botID: UUID().uuidString.lowercased())
    try await host.database.registerBotCaller(other, displayName: "Other")
    await #expect(throws: (any Error).self) {
      try await host.database.saveSessionTimer(.init(sessionID: other, instruction: "x", nextFireAt: start), callerID: principal,
                                               requestID: UUID().uuidString.lowercased(), creating: true)
    }
    // Pausing every bot stops their timers without stopping the scheduler.
    settings.botMCP.isEnabled = false
    try await host.database.saveToolSettings(settings)
    #expect(try await host.timers.due(now: start.addingTimeInterval(7_300)).occurrences.isEmpty)
  }
}
