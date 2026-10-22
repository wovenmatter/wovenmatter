import Foundation
import Testing
import WovenMatterCompanion
import WovenMatterDashboardStore
@testable import WovenMatterAppFacade

@Suite("Desktop update completion")
struct DesktopUpdateReceiptTests {
    @Test("installation preparation saves before termination and respects opt-out")
    @MainActor func savesBeforeTermination() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "wovenmatter.receipt-test." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let database = try await WorkspaceDatabase(url: directory.appending(path: "workspace.sqlite"))
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
