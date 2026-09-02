import Foundation
import Testing
@testable import WovenMatterDashboardStore

@Suite("Cursor account limits")
struct CursorAccountClientTests {
  @Test("Grok Bot payload maps percent-used and weekly reset")
  func grokBotReportedLane() throws {
    let fixture = Data(#"""
    {
      "currentPeriodStart": "2026-08-31T07:57:50.647Z",
      "nextResetTimestampUtc": "2026-09-07T07:57:50.647Z",
      "usagePercent": 0,
      "hasAvailableUsage": true,
      "hasNonZeroIncludedLimit": true
    }
    """#.utf8)

    let status = try JSONDecoder().decode(CursorSandUsage.self, from: fixture)
    let window = try #require(status.quotaWindow)

    #expect(window.id == "grok-bot")
    #expect(window.label == "Grok Bot")
    #expect(window.usedPercent == 0)
    #expect(window.remainingPercent == 100)
    #expect(window.windowMinutes == 10_080)
    let expectedReset = try Date.ISO8601FormatStyle(
      includingFractionalSeconds: true
    ).parse("2026-09-07T07:57:50.647Z")
    #expect(window.resetsAt == expectedReset)
  }

  @Test("absent Grok Bot payload does not fabricate a quota row")
  func grokBotAbsentLane() throws {
    let fixture = Data(#"{}"#.utf8)
    let status = try JSONDecoder().decode(CursorSandUsage.self, from: fixture)

    #expect(status.quotaWindow == nil)
  }

  @Test("legacy Grok Bot aliases decode without changing units")
  func grokBotLegacyAliases() throws {
    let fixture = Data(#"""
    {
      "current_period_start": "2026-08-31T07:57:50Z",
      "next_reset_timestamp_utc": "2026-09-07T07:57:50Z",
      "usage_percent": 25,
      "has_available_usage": true,
      "has_non_zero_included_limit": true
    }
    """#.utf8)

    let status = try JSONDecoder().decode(CursorSandUsage.self, from: fixture)
    let window = try #require(status.quotaWindow)

    #expect(window.usedPercent == 25)
    #expect(window.remainingPercent == 75)
    #expect(window.windowMinutes == 10_080)
  }

  @Test("Grok Bot request carries Cursor's required origin")
  func grokBotRequestContract() throws {
    let request = CursorAccountClient.sandRequest(
      baseURL: try #require(URL(string: "https://cursor.com")),
      cookie: "WorkosCursorSessionToken=test"
    )

    #expect(request.url?.path == "/api/dashboard/get-sand-usage-status")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Origin") == "https://cursor.com")
    #expect(request.value(forHTTPHeaderField: "Cookie") == "WorkosCursorSessionToken=test")
    #expect(request.httpBody == Data("{}".utf8))
  }
}
