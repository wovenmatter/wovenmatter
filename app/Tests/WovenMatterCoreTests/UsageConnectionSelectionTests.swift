import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage account selection")
struct UsageConnectionSelectionTests {
  @Test func multipleAccountsHaveDistinctDisplayIdentities() {
    let first = UsageLimitAccount(provider: .codex, accountScopeID: "first", accountLabel: "First",
      status: .signedIn, source: "fixture", detail: "")
    let second = UsageLimitAccount(provider: .codex, accountScopeID: "second", accountLabel: "Second",
      status: .signedIn, source: "fixture", detail: "")
    #expect(first.id != second.id)
    #expect(first.stale().id == first.id)
  }



    @Test("API key selections cannot show subscription quota or another account's identity")
    func apiKeyLimits() {
        let choice = UsageConnectionChoice(provider: .codex, connectionID: "openai", accountID: "key-one", label: "API key · Work", preferred: false)
        let value = ProviderLimitCollector.apiKeyAccount(.codex, choice: choice, present: true, now: Date())
        #expect(value.accountScopeID == "wovenmatter.shared.openai:key-one")
        #expect(value.accountLabel == choice.label)
        #expect(value.quotaWindows.isEmpty)
        #expect(value.balance == nil)
        #expect(value.status == .signedIn)
        #expect(ProviderLimitCollector.apiKeyAccount(.codex, choice: choice, present: false, now: Date()).status == .unavailable)
    }
}
