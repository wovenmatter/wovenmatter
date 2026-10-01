import Foundation
import Testing
import WovenMatterCore
@testable import WovenMatterDashboardStore

@Suite("Usage account selection")
struct UsageConnectionSelectionTests {
    @Test("Explicit display account wins without changing the preferred account")
    func selectedAccount() {
        let first = UsageConnectionChoice(provider: .codex, connectionID: "openai-codex", accountID: "one", label: "First", preferred: true)
        let second = UsageConnectionChoice(provider: .codex, connectionID: "openai", accountID: "two", label: "Second", preferred: true)
        let values = [first, second]
        #expect(UsageConnectionChoice.resolve(values, selectedID: second.id) == second)
        #expect(UsageConnectionChoice.resolve(values, selectedID: nil) == first)
        #expect(UsageConnectionChoice.resolve(values, selectedID: "removed") == first)
        #expect(values[0].preferred)
        #expect(UsageConnectionChoice.resolve([], selectedID: first.id) == nil)
    }

    @Test("API key selections cannot show subscription quota or another account's identity")
    func apiKeyLimits() {
        let choice = UsageConnectionChoice(provider: .codex, connectionID: "openai", accountID: "key-one", label: "API key · Work", preferred: false)
        let value = ProviderLimitCollector.apiKeyAccount(.codex, choice: choice, present: true, now: Date())
        #expect(value.accountScopeID == "wovenmatter.shared.openai:key-one")
        #expect(value.accountLabel == choice.label)
        #expect(value.quotaWindows.isEmpty)
        #expect(value.balance == nil)
        #expect(value.status == .unavailable)
        #expect(ProviderLimitCollector.apiKeyAccount(.codex, choice: choice, present: false, now: Date()).status == .needsCredential)
    }
}
