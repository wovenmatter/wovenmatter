import AppKit
import Foundation
import WovenMatterLibraryStore

/// The app, rather than an SSH script, owns transitions across the execution lease.
/// This mailbox contains no pairing link, token or account credential.
@MainActor
enum RemoteDeviceSetup {
    private static var handling = false
    private static let observingKey = "wovenmatter.device-setup.observing-pairing"
    static func handle(model: ApplicationModel, defaults: UserDefaults = .standard) async {
        guard !handling, !model.isPreparedForExecutionRestart, DevelopmentLaunch.mode == nil, LocalExecutionRole.current != .backend,
              model.state == .ready else { return }
        handling = true
        defer { handling = false }
        let host = model.libraryHost
        await host.refreshStatus()
        if let observedRaw = defaults.string(forKey: observingKey),
           let observed = try? JSONDecoder().decode(MacSetupRequest.self, from: Data(observedRaw.utf8)) {
            if host.connectedPeerRoutes.contains(where: { route in route.endpoint == observed.endpoint && host.pairedDevices.contains(where: { $0.id == route.deviceID }) }) {
                publish(observed, phase: .paired, message: "Paired Macs keep their libraries synchronized.", defaults: defaults)
                defaults.removeObject(forKey: observingKey)
            } else if let error = host.peerPairingError ?? host.errorMessage {
                publish(observed, phase: .failed, message: error, defaults: defaults)
                defaults.removeObject(forKey: observingKey)
            } else {
                publish(observed, phase: .waiting, message: "Waiting for pairing approval on the other Mac.", defaults: defaults)
            }
        }
        guard let raw = defaults.string(forKey: MacSetupRequest.preferenceKey) else { return }
        var decodedRequest: MacSetupRequest?
        do {
            guard raw.utf8.count <= 4096 else { throw MacDeviceSetupError("The setup request is too large.") }
            let request = try JSONDecoder().decode(MacSetupRequest.self, from: Data(raw.utf8))
            decodedRequest = request
            try request.validate()
            switch request.action {
            case .pair:
                guard let endpoint = request.endpoint else { throw MacDeviceSetupError("The paired Mac address is missing.") }
                if let deviceID = host.peerIdentity?.deviceID { defaults.set(deviceID, forKey: "wovenmatter.device-setup.device-id") }
                if host.connectedPeerRoutes.contains(where: { $0.endpoint == endpoint }) {
                    publish(request, phase: .paired, message: "Already paired with this Mac.", defaults: defaults)
                } else {
                    await host.pairAtEndpoint(endpoint)
                    defaults.set(raw, forKey: observingKey)
                    publish(request, phase: .submitting, message: "Submitting pairing request…", defaults: defaults)
                }
            case .update:
                MacSetupRequest.clearIfCurrent(raw, defaults: defaults)
                publish(request, phase: .preparing, message: "Preparing Woven Matter to update…", defaults: defaults)
                guard await WorkspaceAssetSession.prepareForRestart() else { throw CancellationError() }
                if model.isBackendFrontend { try await model.prepareBackendForUpdate() }
                else {
                    guard await model.flushNotesBeforeBackendClientQuit() else { throw ApplicationModelError.noteDraftSaveFailed }
                    try await model.prepareOpenCodeInstancesToQuit()
                }
                model.isPreparedForExecutionRestart = true
                WovenMatterLifecycleDelegate.requestTerminationAfterUpdate()
            }
            MacSetupRequest.clearIfCurrent(raw, defaults: defaults)
        } catch {
            defaults.removeObject(forKey: observingKey)
            MacSetupRequest.clearIfCurrent(raw, defaults: defaults)
            if let decodedRequest { publish(decodedRequest, phase: .failed, message: error.localizedDescription, defaults: defaults) }
            WorkspaceAssetSession.cancelPreparedRestart()
            if model.isBackendFrontend, model.isPreparedForExecutionRestart { try? await model.recoverBackendAfterFailedUpdate() }
        }
    }
    private static func publish(_ request: MacSetupRequest, phase: MacSetupStatus.Phase, message: String, defaults: UserDefaults) {
        let status = MacSetupStatus(requestID: request.id, phase: phase, message: message)
        defaults.set(try? status.json(), forKey: MacSetupRequest.statusKey)
    }
}
