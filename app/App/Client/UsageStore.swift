import Foundation
import Observation

/// Usage records, analytics, provider limits, per-machine usage and the price table.
@MainActor
@Observable
final class UsageStore {
    /// Records and limits for the selected range. Nil until the server first answers.
    private(set) var snapshot: UsageSnapshot?
    /// The last failure to read usage or limits.
    private(set) var error: String?
    private(set) var isRefreshing = false
    private(set) var isRefreshingLimits = false
    /// Every machine whose usage the pages include, this machine first.
    private(set) var machines: [UsageMachineSummary] = []
    private(set) var prices = UsagePriceState()
    /// How far reading past usage has reached, while it is still going.
    private(set) var historyImport: UsageHistoryImportProgress?

    init() {}

    /// Usage opened: read the selected range.
    func destinationAppeared(range: UsageTimeRange) async {
        error = ClientError.notConnected.localizedDescription
    }

    /// The Analytics page was chosen.
    func analyticsSelected(range: UsageTimeRange) async {
        error = ClientError.notConnected.localizedDescription
    }

    /// Re-reads usage for the range, and provider limits when asked.
    func refresh(range: UsageTimeRange, refreshLimits: Bool = false) async {
        error = ClientError.notConnected.localizedDescription
    }

    /// Loads the API list-price table, again when `force` is set.
    func loadPrices(force: Bool = false) async {
        guard force || (prices.table == nil && !prices.isLoading) else { return }
        prices.error = ClientError.notConnected.localizedDescription
    }
}
