import WorkspaceFixtures
import Foundation
import Testing
import WovenMatterCompanion
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@Suite("Desktop update completion")
struct DesktopUpdateReceiptTests {
    @Test("installation preparation saves before termination and respects opt-out")
    @MainActor func savesBeforeTermination() async throws {
        let persistence = try PersistenceFixture()
        let suite = "wovenmatter.receipt-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            persistence.remove()
        }
        let database = try await persistence.openDatabase()
        let analytics = ProductAnalyticsModel(defaults: defaults)
        analytics.configure(database: database, publisher: false)
        await analytics.refresh()
        let installationID = analytics.prepareUpdateInstallation(version: "0.3.1", build: 600)
        let data = try #require(defaults.data(forKey: ProductAnalyticsModel.updateReceiptKey))
        let receipt = try JSONDecoder().decode(ProductAnalyticsUpdateReceipt.self, from: data)
        #expect(receipt.event.id == installationID.uuidString.lowercased())
        #expect(receipt.version == "0.3.1" && receipt.build == 600)
        #expect(!receipt.confirmed)
        await analytics.setEnabled(false)
        #expect(defaults.data(forKey: ProductAnalyticsModel.updateReceiptKey) == nil)
        _ = analytics.prepareUpdateInstallation(version: "0.3.1", build: 600)
        #expect(defaults.data(forKey: ProductAnalyticsModel.updateReceiptKey) == nil)
    }

}
