import AppKit
import Observation
import WovenProtocol
#if canImport(Sparkle)
import Sparkle
#endif

/// One updater per app, so closing Settings never cancels an update or loses it.
@MainActor @Observable
final class DesktopUpdater: NSObject {
    static let shared = DesktopUpdater()
    private(set) var canCheckForUpdates = false
    private(set) var errorMessage: String?
    private(set) var isInstalling = false
    private(set) var hasStagedUpdate = false
    /// Tells this Mac's server an updater step, with the release it is for,
    /// for its anonymous usage statistics.
    @ObservationIgnored var report: ((AppEvent, String?) -> Void)?
    /// The release being installed, for a failure, which names none.
    @ObservationIgnored private var installingVersion: String?

    #if canImport(Sparkle)
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var pendingInstallHandler: (() -> Void)?
    #endif

    func start() {
        #if canImport(Sparkle)
        guard controller == nil, Bundle.main.bundleIdentifier == "wovenmatter.desktop" else { return }
        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        observation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] _, change in
            let enabled = change.newValue ?? false
            Task { @MainActor in self?.canCheckForUpdates = enabled }
        }
        controller.startUpdater()
        #endif
    }

    func checkForUpdates() {
        errorMessage = nil
        #if canImport(Sparkle)
        controller?.checkForUpdates(nil)
        #endif
    }

    /// Downloads and installs the newest release through Sparkle, which then
    /// relaunches the app; the relaunched app restarts this Mac's server on the
    /// new program. Nil when it started, else why it could not.
    func installUpdate() -> String? {
        #if canImport(Sparkle)
        guard let controller, canCheckForUpdates else {
            return "Only the installed Woven Matter app updates itself."
        }
        errorMessage = nil
        report?(.updateCheckClicked, nil)
        controller.checkForUpdates(nil)
        return nil
        #else
        return "Only the installed Woven Matter app updates itself."
        #endif
    }
}

#if canImport(Sparkle)
extension DesktopUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        report?(.updateDownloadStarted, item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        report?(.updateDownloadCompleted, item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        report?(.updateDownloadFailed, item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstallHandler = installHandler
        // Enter installation outside the Swift task/main dispatch queue, so
        // AppKit's deferred termination can perform main-actor cleanup.
        RunLoop.main.perform(inModes: [.common]) {
            MainActor.assumeIsolated {
                let handler = self.pendingInstallHandler
                self.pendingInstallHandler = nil
                handler?()
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, didExtractUpdate item: SUAppcastItem) {
        hasStagedUpdate = true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstalling = true
        installingVersion = item.displayVersionString
        report?(.updateInstallStarted, item.displayVersionString)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let wasInstalling = isInstalling
        pendingInstallHandler = nil
        isInstalling = false
        hasStagedUpdate = false
        let failure = error as NSError
        let expected = failure.domain == SUSparkleErrorDomain &&
            [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(failure.code)
        errorMessage = expected ? nil : error.localizedDescription
        if wasInstalling, !expected { report?(.updateInstallFailed, installingVersion) }
        installingVersion = nil
    }
}
#endif
