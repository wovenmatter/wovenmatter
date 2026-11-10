import Foundation
import Testing
import WovenMatterCore

struct WovenMatterKeychainServiceTests {
    @Test func productionKeepsItsRemoteWorkspaceServiceAndDevBuildsUseTheirOwn() {
        #expect(WovenMatterKeychainService.remoteWorkspaces(forBundleIdentifier: "wovenmatter.desktop") == "com.wovenmatter.remote-workspaces")
        #expect(WovenMatterKeychainService.remoteWorkspaces(forBundleIdentifier: nil) == "com.wovenmatter.remote-workspaces")
        let dev = WovenMatterKeychainService.remoteWorkspaces(forBundleIdentifier: "wovenmatter.desktop.dev.mini.snapshot")
        #expect(dev == "Woven Matter.desktop.dev.mini.snapshot.remote-workspaces")
        #expect(dev != "com.wovenmatter.remote-workspaces")
    }
}

struct UsageSampleMergeTests {
    @Test func mergingByHourKeepsTotalsRequestsAndSessions() {
        let base = Date(timeIntervalSince1970: 1_794_000_000)
        func sample(_ id: String, _ offset: TimeInterval, session: String = "s1", input: Int64 = 10, cost: Double? = 0.5) -> UsageSample {
            UsageSample(id: id, provider: .claude, timestamp: base.addingTimeInterval(offset), sessionID: session,
                        accountLabel: "a", model: "claude-opus", harness: "Claude Code", application: "Woven",
                        tokens: UsageTokenCounts(inputTokens: input, outputTokens: 2), requestCount: 1, costUSD: cost, sourceID: "src")
        }
        let samples = [sample("1", 0), sample("2", 60), sample("3", 120, cost: nil), sample("4", 4000), sample("5", 30, session: "s2")]
        let snapshot = UsageAnalyticsSnapshot(range: .last7Days, generatedAt: base, samples: samples, sources: [])
        let merged = snapshot.mergingSamplesByHour()
        #expect(merged.samples.count == 3)
        let before = UsageAnalyticsSummary(samples: samples), after = UsageAnalyticsSummary(samples: merged.samples)
        #expect(after.requests == before.requests && after.sessions == before.sessions)
        #expect(after.tokens.inputTokens == before.tokens.inputTokens && after.tokens.outputTokens == before.tokens.outputTokens)
        #expect(merged.samples.first { $0.id.hasPrefix("1") }?.costUSD == 1.0)
        #expect(merged.samples.first { $0.id.hasPrefix("1") }?.timestamp == base.addingTimeInterval(120))
        // Still over the limit hourly: merge by day instead.
        let daily = snapshot.mergingSamplesForTransport(limit: 2)
        #expect(daily.samples.count == 2)
        #expect(UsageAnalyticsSummary(samples: daily.samples).requests == before.requests)
    }
}
