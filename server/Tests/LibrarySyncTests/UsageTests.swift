import Foundation
import Testing
import WovenLibrary
import WovenProtocol

/// Usage every machine reads from its runtimes' own records counts on every
/// machine after sync, with its sessions.
@Test func usageTotalsCoverEveryMachinesUsageAfterSync() async throws {
  func library(_ name: String) async throws -> Library {
    try await Library.open(folder: FileManager.default.temporaryDirectory.appendingPathComponent("woven-usage-\(UUID().uuidString)"),
                           machineName: name)
  }
  let a = try await library("a"), b = try await library("b")
  let now = Date()
  try await a.saveUsage([
    UsageEntry(id: "piDurable:r1", runtime: .piDurable, nativeSession: "s1", woven: true, model: "gpt", at: now,
               input: 100, output: 10, cacheRead: 5),
    UsageEntry(id: "piDurable:r2", runtime: .piDurable, nativeSession: "s1", woven: true, model: "gpt", at: now,
               input: 50, output: 5),
  ], source: UsageSource(id: "a"))
  try await b.saveUsage([UsageEntry(id: "bots:r3", runtime: .bots, nativeSession: "bot/1", woven: true, model: "claude", at: now,
                                    input: 7, output: 3, cacheWrite: 2)], source: UsageSource(id: "b"))
  while true {
    let page = try await a.pull(after: try await b.cursor(for: a.machineID), limit: 100)
    try await b.apply(page, from: a.machineID)
    if !page.more { break }
  }

  let report = try await b.usage(from: now.addingTimeInterval(-3600), to: now.addingTimeInterval(60), periodSeconds: 3600)
  #expect(report.totals == UsageAmounts(input: 157, output: 18, cacheRead: 5, cacheWrite: 2, requests: 3))
  #expect(report.sessions == 2)
  #expect(Set(report.newestByMachine.keys) == [a.machineID, b.machineID])
  let fromA = report.groups.filter { $0.machineID == a.machineID }
  #expect(fromA.reduce(0) { $0 + $1.amounts.input } == 150 && fromA.allSatisfy { $0.nativeSessionID == "s1" && $0.inWoven })
}

private func usageLibrary(_ name: String) async throws -> Library {
  try await Library.open(folder: FileManager.default.temporaryDirectory.appendingPathComponent("woven-usage-\(UUID().uuidString)"),
                         machineName: name)
}

private func pull(_ from: Library, into other: Library) async throws {
  while true {
    let page = try await from.pull(after: try await other.cursor(for: from.machineID), limit: 100)
    try await other.apply(page, from: from.machineID)
    if !page.more { break }
  }
}

private func response(_ id: String, session: String = "s", model: String = "m", at: String, input: Int64 = 1) -> UsageEntry {
  UsageEntry(id: id, runtime: .claudeCode, nativeSession: session, model: model, at: try! Date(at, strategy: .iso8601),
             input: input, output: 0)
}

/// A history-read hour that gains a response is written again in place, and
/// a machine that received its first sums ends with the new ones, once.
@Test func aRewrittenUsageHourReachesAnotherMachineAsItIsNow() async throws {
  let a = try await usageLibrary("a"), b = try await usageLibrary("b")
  try await a.saveUsage([response("claude:1", at: "2026-01-05T11:10:00Z", input: 5)], source: UsageSource(id: "x"))
  try await pull(a, into: b)
  let saved = try await a.saveUsage([response("claude:2", at: "2026-01-05T11:20:00Z", input: 7)], source: UsageSource(id: "x"))
  #expect(saved.added == 1 && saved.records == 1)
  try await pull(a, into: b)
  let report = try await b.usage(from: .distantPast, to: .distantFuture, periodSeconds: 3600)
  #expect(report.groups.count == 1 && report.totals == UsageAmounts(input: 12, requests: 2))
  #expect(try await b.rows("usage_hours", where: "machine_id", is: .text(a.machineID)).count == 1)
}

/// Several Woven Matter sessions naming one harness session label its usage
/// with one of them and count it once.
@Test func aHarnessSessionNamedTwiceCountsOnce() async throws {
  let library = try await usageLibrary("a")
  try await library.setNativeSession("woven-2", runtime: .claudeCode, handle: "s")
  try await library.setNativeSession("woven-1", runtime: .claudeCode, handle: "s")
  try await library.saveUsage([response("claude:1", at: "2026-01-05T11:10:00Z", input: 5)], source: UsageSource(id: "x"))
  let report = try await library.usage(from: .distantPast, to: .distantFuture, periodSeconds: 86_400)
  #expect(report.totals.input == 5 && report.groups.count == 1 && report.groups[0].sessionID == "woven-1" && report.groups[0].inWoven)
}

/// With a time zone, daily usage falls on that zone's days: evening usage
/// west of UTC is the same day, and the days around a change of clocks are
/// 23 and 25 hours long.
@Test func dailyUsageFollowsTheViewersDays() async throws {
  let library = try await usageLibrary("a")
  try await library.saveUsage([
    // 2026-03-07 21:00 in New York, the evening before clocks go forward.
    response("claude:1", at: "2026-03-08T02:00:00Z"),
    // 2026-03-08 23:30 in New York: that day has 23 hours.
    response("claude:2", at: "2026-03-09T03:30:00Z"),
    // 2026-03-09 00:30 in New York.
    response("claude:3", at: "2026-03-09T04:30:00Z"),
    // 2026-03-09 08:45 in Kathmandu (UTC+5:45), 2026-03-09 03:00 UTC.
    response("claude:4", at: "2026-03-09T03:00:00Z"),
  ], source: UsageSource(id: "x"))
  func days(_ zone: String?) async throws -> [String: Int] {
    let timeZone = zone.flatMap(TimeZone.init(identifier:))
    let report = try await library.usage(from: .distantPast, to: .distantFuture, periodSeconds: 86_400, timeZone: timeZone)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone ?? TimeZone(identifier: "UTC")!
    var counts: [String: Int] = [:]
    for group in report.groups {
      #expect(calendar.startOfDay(for: group.period) == group.period)
      let parts = calendar.dateComponents([.year, .month, .day], from: group.period)
      counts[String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!), default: 0] += group.amounts.requests
    }
    return counts
  }
  #expect(try await days(nil) == ["2026-03-08": 1, "2026-03-09": 3])
  #expect(try await days("America/New_York") == ["2026-03-07": 1, "2026-03-08": 2, "2026-03-09": 1])
  #expect(try await days("Asia/Kathmandu") == ["2026-03-08": 1, "2026-03-09": 3])
  #expect(try await days("Pacific/Auckland") == ["2026-03-08": 1, "2026-03-09": 3])
}

/// A bot's usage is filed under that bot's chat on the machine that read
/// it, never under another machine's chat of the same bot.
@Test func botUsageIsFiledOnlyUnderThisMachinesChat() async throws {
  let a = try await usageLibrary("a"), b = try await usageLibrary("b")
  try await b.saveBotMirror(BotMirror(
    bot: BotMirror.Bot(id: "b1", name: "Ada", isAdmin: false, manager: false, managerID: nil, orchestrator: false, trashed: false,
                       createdAt: Date()),
    chats: [BotMirror.Chat(sessionID: "chat-on-b", botID: "b1", conversationID: 1, kind: .main, parentConversationID: nil,
                           title: "Ada", pinned: false, createdAt: Date())],
    items: [], checkpoint: "bot:b1", upTo: 0))
  try await pull(b, into: a)
  try await a.saveUsage([UsageEntry(id: "bots:r1", runtime: .bots, nativeSession: "b1/1", woven: true, model: "m", at: Date(),
                                    input: 5, output: 1)], source: UsageSource(id: "x"))
  let groups = try await a.usage(from: .distantPast, to: .distantFuture, periodSeconds: 86_400).groups
  #expect(groups.count == 1 && groups[0].sessionID == nil && groups[0].inWoven)
}
