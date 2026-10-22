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

    @Test("new updater stages and historical names stay decodable and never qualify as active")
    func updateStageCompatibility() throws {
        for name in ["update_download_started", "update_install_started", "update_download_clicked", "update_install_clicked"] {
            let decoded = try JSONDecoder().decode(ProductAnalyticsEvent.Name.self, from: JSONEncoder().encode(name))
            let event = ProductAnalyticsEvent(preferenceRevision: 1, name: decoded)
            #expect(!event.qualifying)
            #expect(!event.rateLimited)
        }
    }

    @Test("same-version replacement confirms only the intended running build")
    func confirmsBuildAfterLaunch() {
        var receipt = ProductAnalyticsUpdateReceipt(analyticsID: "fixture", version: "0.3.0", build: 543,
            event: ProductAnalyticsEvent(preferenceRevision: 1, name: .updateInstallCompleted))
        let oldBuild = receipt.confirmLaunch(version: "0.3.0", build: 541)
        let wrongVersion = receipt.confirmLaunch(version: "0.2.8", build: 543)
        let installed = receipt.confirmLaunch(version: "0.3.0", build: 543)
        let duplicate = receipt.confirmLaunch(version: "0.3.0", build: 543)
        #expect(!oldBuild)
        #expect(!wrongVersion)
        #expect(installed)
        #expect(!duplicate)
        #expect(receipt.event.properties["app_version"] == "0.3.0")
    }

}
