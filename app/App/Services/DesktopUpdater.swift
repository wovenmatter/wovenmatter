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
    weak var model: ApplicationModel?

    #if canImport(Sparkle)
    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var pendingInstallHandler: (() -> Void)?
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
        Task { await model?.analytics.record(.updateDownloadClicked, properties: ["target_version": item.displayVersionString]) }
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        Task { await model?.analytics.record(.updateDownloadCompleted, properties: ["target_version": item.displayVersionString]) }
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        Task { await model?.analytics.record(.updateDownloadFailed, properties: ["target_version": item.displayVersionString]) }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        pendingInstallHandler = installHandler
        Task {
            if let build = Int(item.versionString) {
                _ = await model?.analytics.prepareUpdateInstallation(version: item.displayVersionString, build: build)
            }
            // Enter installation outside the Swift task/main dispatch queue, so
            // AppKit's deferred termination can perform main-actor cleanup.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated {
                    let handler = self.pendingInstallHandler
                    self.pendingInstallHandler = nil
                    handler?()
                }
            }
        }
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstalling = true
        Task { await model?.analytics.record(.updateInstallClicked, properties: ["target_version": item.displayVersionString]) }
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        let wasInstalling = isInstalling
        pendingInstallHandler = nil
        isInstalling = false
        errorMessage = error.localizedDescription
        model?.analytics.cancelUpdateInstallation()
        guard wasInstalling else { return }
        // A canceled/failed installation must restore a stopped execution owner.
        Task {
            WorkspaceAssetSession.cancelPreparedRestart()
            do { try await model?.recoverBackendAfterFailedUpdate() }
            catch { errorMessage = error.localizedDescription }
        }
    }
}
#endif
