import Foundation
import Testing
import WovenMatterCompanion
@testable import WovenMatterAppFacade

@Suite("Desktop update completion")
struct DesktopUpdateReceiptTests {
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

    @Test("legacy helper still requires its matching installation marker")
    func legacyMarker() {
        let event = ProductAnalyticsEvent(preferenceRevision: 1, name: .updateInstallCompleted)
        var receipt = ProductAnalyticsUpdateReceipt(analyticsID: "fixture", version: "0.3.0", build: 543, event: event)
        let wrongMarker = receipt.confirmLaunch(marker: URL(fileURLWithPath: "/tmp/.ready-other"), version: "0.3.0", build: 543)
        let installed = receipt.confirmLaunch(marker: URL(fileURLWithPath: "/tmp/.ready-" + event.id), version: "0.3.0", build: 543)
        #expect(!wrongMarker)
        #expect(installed)
    }
}
