import AppKit
import Observation
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
    weak var model: ApplicationModel?

    #if canImport(Sparkle)
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var pendingInstallHandler: (() -> Void)?
    @ObservationIgnored private var installationTargetVersion: String?
    #endif

    func start(model: ApplicationModel) {
        self.model = model
        #if canImport(Sparkle)
        guard controller == nil,
              Bundle.main.bundleIdentifier == "wovenmatter.desktop",
              LocalExecutionRole.current != .backend else { return }
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
        Task { await model?.analytics.record(.updateCheckClicked) }
    }
}

#if canImport(Sparkle)
extension DesktopUpdater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        Task { await model?.analytics.record(.updateDownloadStarted, properties: ["target_version": item.displayVersionString]) }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Task { await model?.analytics.record(.updateDownloadCompleted, properties: ["target_version": item.displayVersionString]) }
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        Task { await model?.analytics.record(.updateDownloadFailed, properties: ["target_version": item.displayVersionString]) }
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
        // Sparkle installs an extracted update on ordinary quit as well as
        // through Install and Relaunch. Both paths must stop the old backend.
        hasStagedUpdate = true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstalling = true
        installationTargetVersion = item.displayVersionString
        // Sparkle can skip its relaunch callback when installing on ordinary
        // quit. Persist synchronously at the installation boundary instead.
        if let build = Int(item.versionString) {
            _ = model?.analytics.prepareUpdateInstallation(version: item.displayVersionString, build: build)
        }
        Task { await model?.analytics.record(.updateInstallStarted, properties: ["target_version": item.displayVersionString]) }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let wasInstalling = isInstalling
        let targetVersion = installationTargetVersion
        installationTargetVersion = nil
        pendingInstallHandler = nil
        isInstalling = false
        hasStagedUpdate = false
        let failure = error as NSError
        let expected = failure.domain == SUSparkleErrorDomain &&
            [Int(SUError.noUpdateError.rawValue), Int(SUError.installationCanceledError.rawValue)].contains(failure.code)
        errorMessage = expected ? nil : error.localizedDescription
        guard wasInstalling else { return }
        model?.analytics.cancelUpdateInstallation()
        // A canceled/failed installation must restore a stopped execution owner.
        Task {
            WorkspaceAssetSession.cancelPreparedRestart()
            do { try await model?.recoverBackendAfterFailedUpdate() }
            catch { errorMessage = error.localizedDescription }
            // Telemetry must not delay recovery, and its backend may have been
            // stopped for installation. Report only after the recovery attempt.
            if !expected {
                await model?.analytics.record(.updateInstallFailed,
                    properties: targetVersion.map { ["target_version": $0] } ?? [:])
            }
        }
    }
}
#endif
