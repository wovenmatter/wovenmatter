import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage index query and parser provenance")
struct UsageIndexOptimizationTests {
  private let now = Date(timeIntervalSince1970: 1_780_000_000)


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
