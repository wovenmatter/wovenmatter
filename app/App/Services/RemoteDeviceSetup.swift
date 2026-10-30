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
        if model.isLibraryClient, defaults.bool(forKey: observingKey) {
            await model.libraryClient.initialize()
            let pairing = model.libraryClient.devicePairing
            if !pairing.isRequestPending, pairing.errorMessage == nil { await pairing.restorePendingRequest() }
            if model.libraryClient.credential != nil {
                defaults.set("Paired with the central database.", forKey: CompanionMacSetupRequest.statusKey)
                defaults.removeObject(forKey: observingKey)
            } else if let error = pairing.errorMessage, !pairing.isRequestPending {
                defaults.set("Pairing needs attention: " + error, forKey: CompanionMacSetupRequest.statusKey)
                defaults.removeObject(forKey: observingKey)
            } else if !pairing.isRequestPending {
                defaults.set("Pairing needs attention: The pairing request was closed. Try pairing again.", forKey: CompanionMacSetupRequest.statusKey)
                defaults.removeObject(forKey: observingKey)
            } else if pairing.hasSubmittedRequest {
                defaults.set("Waiting for pairing approval on the central Mac.", forKey: CompanionMacSetupRequest.statusKey)
            }
        }
        guard let raw = defaults.string(forKey: CompanionMacSetupRequest.preferenceKey) else { return }
        do {
            guard raw.utf8.count <= 4096 else { throw MacDeviceSetupError("The setup request is too large.") }
            let request = try JSONDecoder().decode(CompanionMacSetupRequest.self, from: Data(raw.utf8))
            try request.validate()
            switch request.action {
            case .pair:
                guard let endpoint = request.endpoint else { throw MacDeviceSetupError("The central database address is missing.") }
                if !model.isLibraryClient {
                    defaults.set("Preparing this Mac as a node…", forKey: CompanionMacSetupRequest.statusKey)
                    // Retain the intent across the app's existing safe restart.
                    try await model.activateLibraryClientMode()
                    return
                }
                await model.libraryClient.initialize()
                defaults.set(model.libraryClient.state.deviceID, forKey: "wovenmatter.device-setup.device-id")
                if let credential = model.libraryClient.credential {
                    guard credential.endpoint == endpoint else { throw MacDeviceSetupError("This Mac is already paired with another central database. Unpair it there before setting up a different database.") }
                    defaults.set("Already paired with this central database.", forKey: CompanionMacSetupRequest.statusKey)
                } else {
                    await model.libraryClient.devicePairing.restorePendingRequest()
                    try await model.libraryClient.devicePairing.requestPairing(endpoint: endpoint)
                    defaults.set(true, forKey: observingKey)
                    defaults.set("Submitting pairing request…", forKey: CompanionMacSetupRequest.statusKey)
                }
            case .update:
                defaults.removeObject(forKey: CompanionMacSetupRequest.preferenceKey)
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
            defaults.removeObject(forKey: CompanionMacSetupRequest.preferenceKey)
        } catch {
            defaults.removeObject(forKey: observingKey)
            defaults.removeObject(forKey: CompanionMacSetupRequest.preferenceKey)
            defaults.set("Pairing needs attention: " + error.localizedDescription, forKey: CompanionMacSetupRequest.statusKey)
            WorkspaceAssetSession.cancelPreparedRestart()
            if model.isBackendFrontend, model.isPreparedForExecutionRestart { try? await model.recoverBackendAfterFailedUpdate() }
        }
    }
}
