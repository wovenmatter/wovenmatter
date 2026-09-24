import AppKit
import Foundation
import Observation
import WovenMatterCore
import WovenMatterDashboardStore

/// Debug test builds must opt into a separate workspace before any lease/database
/// opens. The same value is used by the app lease, database, journal and note socket.
enum CompanionTestWorkspace {
    nonisolated static var supportDirectory: URL? {
        #if DEBUG
        let arguments = CommandLine.arguments
        let requested: URL
        if let index = arguments.firstIndex(of: "--companion-test-workspace") {
            guard arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else {
                fatalError("An absolute isolated test workspace is required")
            }
            requested = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else if Bundle.main.bundleIdentifier == "com.wovenmatter.macos.companion-test" {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            requested = support.appending(path: "Woven Matter Companion Test", directoryHint: .isDirectory)
        } else { return nil }
        let isolated = requested.standardizedFileURL.resolvingSymlinksInPath()
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.resolvingSymlinksInPath()
        let production = home.appending(path: "Library/Application Support/Woven Matter").resolvingSymlinksInPath()
        let development = home.appending(path: "Library/Application Support/Woven Matter Dev").resolvingSymlinksInPath()
        let legacy = home.appending(path: ".woven-matter").resolvingSymlinksInPath()
        guard isolated.path != "/", isolated != home, isolated != production,
              !isolated.path.hasPrefix(production.path + "/"),
              isolated != development, !isolated.path.hasPrefix(development.path + "/"),
              !isolated.path.hasPrefix(development.path + " "), isolated != legacy,
              !isolated.path.hasPrefix(legacy.path + "/") else {
            fatalError("The companion test app cannot open a production workspace")
        }
        return isolated
        #else
        return nil
        #endif
    }
}

@Observable @MainActor
final class CompanionHostController {
    private weak var model: ApplicationModel?
    private(set) var isEnabled: Bool
    private(set) var isStarting = false
    private(set) var endpoint: URL?
    private(set) var status = "Sharing is stopped"
    private(set) var errorMessage: String?
    private(set) var pairingPayload: CompanionPairingPayload?
    private(set) var pairingExpiresAt: Date?
    private(set) var pairedDevices: [CompanionPairedDevice] = []
    private(set) var lastSeenAt: Date?
    private var authentication: CompanionAuthentication?
    private var server: CompanionHTTPServer?
    private var serve: CompanionTailscaleServe?
    private var stoppingExposures: [CompanionTailscaleServe] = []
    private let defaults: UserDefaults
    private let supportDirectory: URL?
    private let makeExposure: @MainActor () -> CompanionTailscaleServe
    private var generation = UUID()
    private var healthTask: Task<Void, Never>?
    private var awakeActivity: NSObjectProtocol?
    private static let enabledKey = "companion.sharing.enabled"

    init(model: ApplicationModel, defaults: UserDefaults = .standard, supportDirectory: URL? = nil,
         makeExposure: @escaping @MainActor () -> CompanionTailscaleServe = { CompanionTailscaleServe() }) {
        self.model = model
        self.defaults = defaults
        self.supportDirectory = supportDirectory
        self.makeExposure = makeExposure
        self.isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func restoreIfEnabled() async {
        do { try await loadAuthentication() } catch { errorMessage = error.localizedDescription }
        if isEnabled { await start() }
    }

    func start() async {
        guard !isStarting, endpoint == nil, model?.dashboardStore != nil else { return }
        isStarting = true; errorMessage = nil; status = "Starting sharing…"
        generation = UUID()
        let expectedGeneration = generation
        var attemptListener: CompanionHTTPServer?
        var attemptExposure: CompanionTailscaleServe?
        do {
            let previousExposures = stoppingExposures
            for previous in previousExposures {
                try await previous.waitUntilStopped()
                guard generation == expectedGeneration, !Task.isCancelled else { throw CancellationError() }
            }
            stoppingExposures.removeAll { previous in previousExposures.contains(where: { $0 === previous }) }
            try await loadAuthentication()
            guard generation == expectedGeneration, !Task.isCancelled else { throw CancellationError() }
            guard let model, let database = model.dashboardStore?.database, let authentication else {
                throw CompanionAPIError(code: "unavailable", message: "The Mac workspace is not ready.")
            }
            let api = CompanionWorkspaceAPI(database: database, authentication: authentication,
                commands: model.companionCommands,
                isActive: { [weak self] in self?.generation == expectedGeneration && self?.endpoint != nil },
                onPair: { [weak self] in await self?.didPair() },
                onMutation: { [weak model] in Task { await model?.refreshWorkspace() } },
                onRequest: { [weak self] in self?.lastSeenAt = Date() },
                linkedData: { [weak model] link in
                    guard let model else { throw CompanionAPIError(code: "unavailable", message: "The Mac workspace is closed.") }
                    do { return try await model.linkedData(for: link) }
                    catch { throw CompanionAPIError(code: "linked_data_unavailable", message: error.localizedDescription) }
                })
            let listener = CompanionHTTPServer { request in await api.handle(request) }
            attemptListener = listener
            server = listener
            let localPort = try await listener.start()
            guard generation == expectedGeneration, !Task.isCancelled else { throw CancellationError() }
            let exposure = makeExposure()
            attemptExposure = exposure
            serve = exposure
            let portKey = "companion.https.port." + (try database.companionWorkspaceID())
            let savedPort = defaults.object(forKey: portKey) as? Int
            let address = try await exposure.start(loopbackPort: localPort, preferredHTTPSPort: savedPort)
            guard generation == expectedGeneration, !Task.isCancelled else { throw CancellationError() }
            defaults.set(address.port ?? 443, forKey: portKey)
            endpoint = address; isEnabled = true; isStarting = false
            defaults.set(true, forKey: Self.enabledKey)
            status = "Available to your paired iPhone"
            awakeActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: "Woven Matter iPhone companion sharing")
            healthTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    if self.serve?.isRunning != true {
                        self.stop()
                        self.errorMessage = "Tailscale sharing stopped. Check Tailscale, then start sharing again."
                        return
                    }
                    if let expiry = self.pairingExpiresAt, expiry <= Date() {
                        self.pairingPayload = nil; self.pairingExpiresAt = nil
                    }
                }
            }
        } catch {
            attemptListener?.stop()
            attemptExposure?.stop()
            guard generation == expectedGeneration else { return }
            stop(); errorMessage = error.localizedDescription
        }
    }

    /// Quit preserves the explicit enable preference for next launch. Stop sharing
    /// in Settings also clears that preference; neither action cancels agent runs.
    func stop() {
        generation = UUID(); healthTask?.cancel(); healthTask = nil
        server?.stop(); server = nil
        if let serve {
            serve.stop()
            if !stoppingExposures.contains(where: { $0 === serve }) { stoppingExposures.append(serve) }
            self.serve = nil
        }
        endpoint = nil; isStarting = false; status = "Sharing is stopped"
        pairingPayload = nil; pairingExpiresAt = nil
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity) }
        awakeActivity = nil
        if let authentication { Task { await authentication.cancelOffer() } }
    }
    func stopSharing() { isEnabled = false; defaults.set(false, forKey: Self.enabledKey); stop() }

    func createPairingCode() async {
        guard let endpoint, let authentication else { return }
        do {
            let offer = try await authentication.createOffer(endpoint: endpoint)
            pairingPayload = offer.payload; pairingExpiresAt = offer.expiresAt; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func revoke(_ deviceID: String) async {
        do {
            try await authentication?.revoke(deviceID: deviceID)
            pairedDevices = await authentication?.devices() ?? []
            pairingPayload = nil; pairingExpiresAt = nil; lastSeenAt = nil; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    private func loadAuthentication() async throws {
        if authentication == nil {
            let file = try (supportDirectory ?? ApplicationModel.dashboardSupportDirectory()).appendingPathComponent("companion-devices.json")
            authentication = try CompanionAuthentication(fileURL: file)
        }
        pairedDevices = await authentication?.devices() ?? []
    }

    private func didPair() async {
        pairedDevices = await authentication?.devices() ?? []
        pairingPayload = nil; pairingExpiresAt = nil
    }
}
