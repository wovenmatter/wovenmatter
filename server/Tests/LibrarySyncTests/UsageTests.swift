import Foundation
import Testing
import WovenLibrary
import WovenProtocol

@Test func usageTotalsCoverEveryMachinesRecordsAfterSync() async throws {
  func library(_ name: String) async throws -> Library {
    try await Library.open(folder: FileManager.default.temporaryDirectory.appendingPathComponent("woven-usage-\(UUID().uuidString)"),
                           machineName: name)
  }
  let a = try await library("a"), b = try await library("b")
  try await a.recordUsage(sessionID: "s1", runtime: .codex, model: "gpt", input: 100, output: 10, cacheRead: 5, cacheWrite: 0, cost: 0.5)
  try await a.recordUsage(sessionID: "s1", runtime: .codex, model: "gpt", input: 50, output: 5, cacheRead: 0, cacheWrite: 0, cost: 0.25)
  try await b.recordUsage(sessionID: "s2", runtime: .claudeCode, model: "claude", input: 7, output: 3, cacheRead: 0, cacheWrite: 2, cost: 0)
  while true {
    let page = try await a.pull(after: try await b.cursor(for: a.machineID), limit: 100)
    try await b.apply(page, from: a.machineID)
    if !page.more { break }
  }

  let report = try await b.usage(from: Date().addingTimeInterval(-3600), to: Date().addingTimeInterval(60), periodSeconds: 3600)
  #expect(report.totals == UsageAmounts(input: 157, output: 18, cacheRead: 5, cacheWrite: 2, cost: 0.75, requests: 3))
  #expect(report.sessions == 2)
  #expect(Set(report.newestByMachine.keys) == [a.machineID, b.machineID])
  let fromA = report.groups.filter { $0.machineID == a.machineID }
  #expect(fromA.reduce(0) { $0 + $1.amounts.input } == 150 && fromA.allSatisfy { $0.sessionID == "s1" })
}
