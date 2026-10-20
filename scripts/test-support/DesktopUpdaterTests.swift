import AppKit
import Sparkle

@MainActor enum LocalExecutionRole { case frontend, backend; static let current = Self.frontend }
@MainActor enum WorkspaceAssetSession { static func cancelPreparedRestart() {} }
@MainActor final class Analytics {
    enum Event { case updateCheckClicked, updateDownloadStarted, updateDownloadCompleted, updateDownloadFailed, updateInstallStarted, updateInstallFailed }
    var cancellations = 0
    var events: [(Event, [String: String])] = []
    var preparations: [(String, Int)] = []
    func record(_ event: Event, properties: [String: String] = [:]) async { events.append((event, properties)) }
    func prepareUpdateInstallation(version: String, build: Int) -> Bool { preparations.append((version, build)); return true }
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
        let item = SUAppcastItem(dictionary: ["enclosure": [
            "url": "https://example.invalid/update.dmg", "sparkle:version": "600",
            "sparkle:shortVersionString": "0.3.1"]])!
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
        // Install-on-quit need not call shouldPostponeRelaunchForUpdate.
        // The receipt must already exist before yielding or terminating.
        precondition(model.analytics.preparations.count == 1)
        precondition(model.analytics.preparations[0].0 == "0.3.1" && model.analytics.preparations[0].1 == 600)
        delegate.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationError.rawValue)))
        await waitUntil { model.recoveries == 1 && model.analytics.events.contains { $0.0 == .updateInstallFailed } }
        precondition(!delegate.isInstalling && !delegate.hasStagedUpdate)
        precondition(model.analytics.cancellations == 1 && model.recoveries == 1)
        let failures = model.analytics.events.filter { $0.0 == .updateInstallFailed }
        precondition(failures.count == 1 && failures[0].1 == ["target_version": "0.3.1"])
        delegate.updater(updater, willInstallUpdate: item)
        delegate.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue)))
        await waitUntil { model.recoveries == 2 }
        precondition(model.analytics.events.filter { $0.0 == .updateInstallFailed }.count == 1)
        delegate.updater(updater, willDownloadUpdate: item, with: NSMutableURLRequest(url: URL(string: "https://example.invalid/update.dmg")!))
        await waitUntil { model.analytics.events.contains { $0.0 == .updateDownloadStarted } }
        precondition(model.analytics.events.filter { $0.0 == .updateInstallStarted }.count == 2)
        print("Sparkle delegate passed: synchronous install-on-quit receipts, failure metadata, cancellation exclusion, lifecycle stages, and backend recovery.")
    }

    @MainActor static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<1000 {
            if condition() { return }
            await Task.yield()
        }
        precondition(condition(), "Delegate tasks did not complete")
    }
}
