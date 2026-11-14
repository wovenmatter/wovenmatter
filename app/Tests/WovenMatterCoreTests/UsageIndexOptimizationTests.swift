import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterLibraryStore

@Suite("Usage index query and parser provenance")
struct UsageIndexOptimizationTests {

  @Test("Parser returns usage with request provenance after wrapper removal")
  func transcriptProvenance() throws {
    let line = #"{"type":"assistant","timestamp":"2026-05-28T12:00:00Z","sessionId":"s","requestId":"r","message":{"id":"m","model":"claude-sonnet-4","usage":{"input_tokens":9,"output_tokens":4}}}"#
    let parsed = try #require(LocalUsageTranscriptParser.parseClaude(line: line, lineNumber: 1))
    #expect(parsed.dedupeKey == "m:r")
    #expect(parsed.sourceEventID == "m:r")
    #expect(parsed.tokens.totalTokens == 13)
  }
}
