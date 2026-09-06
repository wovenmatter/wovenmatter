import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage index query and parser provenance")
struct UsageIndexOptimizationTests {
  private let now = Date(timeIntervalSince1970: 1_780_000_000)

  @Test("Source filtering preserves full sample values, boundaries and ordering")
  func sourceQuery() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try UsageStore(databaseURL: root.appending(path: "usage.sqlite"))
    for source in ["cursor:account", "cursor:account:copy", "other"] {
      let samples = [-1, 0, 10, 10, 11].enumerated().map { index, offset in
        sample("event-\(index)", at: now.addingTimeInterval(Double(offset)), source: source)
      }
      try store.replace(
        sourceID: source, sourceName: source, location: "synthetic", provider: .cursor,
        harness: "Cursor", fingerprint: "fixture", samples: samples, importedAt: now
      )
    }
    let interval = DateInterval(start: now, end: now.addingTimeInterval(10))
    let all = try store.samples(in: interval)
    let filtered = try store.samples(in: interval, sourceID: "cursor:account")
    #expect(filtered == all.filter { $0.sourceID == "cursor:account" })
    #expect(filtered.map(\.sourceEventID) == ["event-1", "event-2", "event-3"])
    #expect(try store.samples(in: interval, sourceID: "missing").isEmpty)
    #expect(try store.statistics(sourceID: "cursor:account", in: interval).events == 3)
    #expect(try store.statistics(sourceIDPrefix: "cursor:account", in: interval).events == 6)
  }

  @Test("Parser returns usage with request provenance after wrapper removal")
  func transcriptProvenance() throws {
    let line = #"{"type":"assistant","timestamp":"2026-05-28T12:00:00Z","sessionId":"s","requestId":"r","message":{"id":"m","model":"claude-sonnet-4","usage":{"input_tokens":9,"output_tokens":4}}}"#
    let parsed = try #require(LocalUsageTranscriptParser.parseClaude(line: line, lineNumber: 1))
    #expect(parsed.dedupeKey == "m:r")
    #expect(parsed.sourceEventID == "m:r")
    #expect(parsed.tokens.totalTokens == 13)
  }

  private func sample(
    _ id: String, at date: Date, source: String,
    provider: ProviderKind = .cursor, model: String = "gpt-5.4",
    session: String = "session"
  ) -> UsageSample {
    UsageSample(
      id: id, provider: provider, timestamp: date, sessionID: session,
      accountLabel: "synthetic", model: model, harness: "Cursor", application: "fixture",
      tokens: UsageTokenCounts(inputTokens: 7, cachedInputTokens: 2, outputTokens: 3),
      costUSD: 0.012, sourceID: source, sourceEventID: id
    )
  }
}
