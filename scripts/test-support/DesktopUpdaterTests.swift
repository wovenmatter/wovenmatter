import AppKit
import Sparkle

@MainActor enum LocalExecutionRole { case frontend, backend; static let current = Self.frontend }
@MainActor enum WorkspaceAssetSession { static func cancelPreparedRestart() {} }
@MainActor final class Analytics {
    enum Event { case updateCheckClicked, updateDownloadClicked, updateDownloadCompleted, updateDownloadFailed, updateInstallClicked }
    var cancellations = 0
    func record(_ event: Event, properties: [String: String] = [:]) async {}
    func prepareUpdateInstallation(version: String, build: Int) async -> Bool { true }
    func cancelUpdateInstallation() { cancellations += 1 }
}
@MainActor final class ApplicationModel {
    let analytics = Analytics()
    var recoveries = 0
    func recoverBackendAfterFailedUpdate() async throws { recoveries += 1 }
}

@main struct DesktopUpdaterTests {
    @MainActor static func main() async {
        let model = ApplicationModel()
        let delegate = DesktopUpdater.shared
        delegate.model = model
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
        let updater = controller.updater
        let item = SUAppcastItem.empty()
        delegate.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue)))
        precondition(delegate.errorMessage == nil && model.analytics.cancellations == 0)
        delegate.updater(updater, didExtractUpdate: item)
        precondition(delegate.hasStagedUpdate && !delegate.isInstalling)
        delegate.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        precondition(!delegate.hasStagedUpdate && delegate.errorMessage == nil && model.analytics.cancellations == 0)
        delegate.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.downloadError.rawValue)))
        precondition(delegate.errorMessage != nil && model.analytics.cancellations == 0)
        delegate.updater(updater, willInstallUpdate: item)
        precondition(delegate.isInstalling)
        delegate.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationError.rawValue)))
        try? await Task.sleep(for: .milliseconds(20))
        precondition(!delegate.isInstalling && !delegate.hasStagedUpdate)
        precondition(model.analytics.cancellations == 1 && model.recoveries == 1)
        print("Sparkle delegate passed: extraction stages ordinary-quit install; expected outcomes stay quiet; only aborted installation cancels receipt and restores backend.")
    }
}
