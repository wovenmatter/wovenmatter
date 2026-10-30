import AppKit
import Foundation
import WovenMatterDashboardStore

/// The app, rather than an SSH script, owns transitions across the execution lease.
/// This mailbox contains no pairing link, token or account credential.
@MainActor
enum RemoteDeviceSetup {
    private static var handling = false
    private static let observingKey = "wovenmatter.device-setup.observing-pairing"
    static func handle(model: ApplicationModel, defaults: UserDefaults = .standard) async {
        guard !handling, !model.isPreparedForExecutionRestart, DevelopmentLaunch.mode == nil, LocalExecutionRole.current != .backend,
              model.isLibraryClient || model.state == .ready else { return }
        handling = true
        defer { handling = false }
        if model.isLibraryClient, let observedRaw = defaults.string(forKey: observingKey),
           let observed = try? JSONDecoder().decode(CompanionMacSetupRequest.self, from: Data(observedRaw.utf8)) {
            await model.libraryClient.initialize()
            let pairing = model.libraryClient.devicePairing
            if !pairing.isRequestPending, pairing.errorMessage == nil { await pairing.restorePendingRequest() }
            if let credential = model.libraryClient.credential {
                publish(observed, phase: credential.endpoint == observed.endpoint ? .paired : .failed,
                    message: credential.endpoint == observed.endpoint ? "Paired with the central database." : "This Mac is paired with another central database.", defaults: defaults)
                defaults.removeObject(forKey: observingKey)
            } else if let error = pairing.errorMessage, !pairing.isRequestPending {
                publish(observed, phase: .failed, message: error, defaults: defaults)
                defaults.removeObject(forKey: observingKey)
            } else if !pairing.isRequestPending {
                publish(observed, phase: .failed, message: "The pairing request was closed. Try pairing again.", defaults: defaults)
                defaults.removeObject(forKey: observingKey)
            } else if pairing.hasSubmittedRequest {
                publish(observed, phase: .waiting, message: "Waiting for pairing approval on the central Mac.", defaults: defaults)
            }
        }
        guard let raw = defaults.string(forKey: CompanionMacSetupRequest.preferenceKey) else { return }
        var decodedRequest: CompanionMacSetupRequest?
        do {
            guard raw.utf8.count <= 4096 else { throw MacDeviceSetupError("The setup request is too large.") }
            let request = try JSONDecoder().decode(CompanionMacSetupRequest.self, from: Data(raw.utf8))
            decodedRequest = request
            try request.validate()
            switch request.action {
            case .pair:
                guard let endpoint = request.endpoint else { throw MacDeviceSetupError("The central database address is missing.") }
                if !model.isLibraryClient {
                    publish(request, phase: .preparing, message: "Preparing this Mac as a node…", defaults: defaults)
                    // Retain the intent across the app's existing safe restart.
                    try await model.activateLibraryClientMode()
                    return
                }
                await model.libraryClient.initialize()
                defaults.set(model.libraryClient.state.deviceID, forKey: "wovenmatter.device-setup.device-id")
                if let credential = model.libraryClient.credential {
                    guard credential.endpoint == endpoint else { throw MacDeviceSetupError("This Mac is already paired with another central database. Unpair it there before setting up a different database.") }
                    publish(request, phase: .paired, message: "Already paired with this central database.", defaults: defaults)
                } else {
                    await model.libraryClient.devicePairing.restorePendingRequest()
                    try await model.libraryClient.devicePairing.requestPairing(endpoint: endpoint)
                    defaults.set(raw, forKey: observingKey)
                    publish(request, phase: .submitting, message: "Submitting pairing request…", defaults: defaults)
                }
            case .update:
                CompanionMacSetupRequest.clearIfCurrent(raw, defaults: defaults)
                publish(request, phase: .preparing, message: "Preparing Woven Matter to update…", defaults: defaults)
                guard await WorkspaceAssetSession.prepareForRestart() else { throw CancellationError() }
                if model.isLibraryClient { try await model.prepareLibraryClientForQuit() }
                else if model.isBackendFrontend { try await model.prepareBackendForUpdate() }
                else {
                    guard await model.flushNotesBeforeBackendClientQuit() else { throw ApplicationModelError.noteDraftSaveFailed }
                    try await model.prepareOpenCodeInstancesToQuit()
                }
                model.isPreparedForExecutionRestart = true
                WovenMatterLifecycleDelegate.requestTerminationAfterUpdate()
            }
            CompanionMacSetupRequest.clearIfCurrent(raw, defaults: defaults)
        } catch {
            defaults.removeObject(forKey: observingKey)
            CompanionMacSetupRequest.clearIfCurrent(raw, defaults: defaults)
            if let decodedRequest { publish(decodedRequest, phase: .failed, message: error.localizedDescription, defaults: defaults) }
            WorkspaceAssetSession.cancelPreparedRestart()
            if model.isBackendFrontend, model.isPreparedForExecutionRestart { try? await model.recoverBackendAfterFailedUpdate() }
        }
    }
    private static func publish(_ request: CompanionMacSetupRequest, phase: CompanionMacSetupStatus.Phase, message: String, defaults: UserDefaults) {
        let status = CompanionMacSetupStatus(requestID: request.id, phase: phase, message: message)
        defaults.set(try? status.json(), forKey: CompanionMacSetupRequest.statusKey)
    }
}
