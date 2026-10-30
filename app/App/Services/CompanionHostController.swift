import AppKit
import Foundation
import Observation
import Security
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
    weak var model: ApplicationModel?
    private(set) var isEnabled = false
    private(set) var isStarting = false
    private(set) var endpoint: URL?
    private(set) var status = "Unavailable"
    private(set) var errorMessage: String?
    private(set) var pairingPayload: CompanionPairingPayload?
    private(set) var pairingExpiresAt: Date?
    private(set) var discoveredPeers: [CompanionDiscoveredPeer] = []
    private(set) var pendingPairingRequests: [CompanionPendingPairingRequest] = []
    private(set) var executionWorkspaces: [CompanionExecutionWorkspace] = []
    private(set) var isDiscovering = false
    private(set) var pendingDeviceRevocations: [String: [String]] = [:]
    @ObservationIgnored lazy var peerSync = PairedMacSyncController(host: self)
    private(set) var peerPairingStatus = ""
    private(set) var peerSyncErrors: [String: String] = [:]
    private(set) var peerPairingError: String?
    private var projectedPeerRoutes: [PairedMacRoute] = []
    var connectedPeerRoutes: [PairedMacRoute] { model?.isBackendFrontend == true ? projectedPeerRoutes : peerSync.routes }
    var peerIdentity: CompanionPairingDeviceIdentity? { discoveryIdentity }
    private var discoveryIdentity: CompanionPairingDeviceIdentity?
    private let discovery = CompanionMacDiscovery()
    private let pairingNetwork = CompanionPairingNetwork()
    private(set) var pairedDevices: [CompanionPairedDevice] = []
    private(set) var lastSeenAt: Date?
    private var authentication: CompanionAuthentication?
    private var executionAPI: CompanionMacExecutionAPI?
    private var inferenceHost: CompanionInferenceHost?
    private var executionAuthentication: CompanionExecutionAuthentication?
    private var provisioningWorkspaceIDs: Set<String> = []
    private var revokingDeviceIDs: Set<String> = []
    var mcpSettingsFingerprints: [String: String] = [:]
    private var registryRefreshInProgress = false
    private var revocationRetryInProgress = false
    private static let pendingRevocationsKey = "companion.execution.pending-revocations"
    private var server: CompanionHTTPServer?
    private var serve: CompanionTailscaleServe?
    private var stoppingExposures: [CompanionTailscaleServe] = []
    private let defaults: UserDefaults
    private let supportDirectory: URL?
    private let makeExposure: @MainActor () -> CompanionTailscaleServe
    private var generation = UUID()
    private var healthTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private let retryInterval: Duration

    init(model: ApplicationModel, defaults: UserDefaults = .standard, supportDirectory: URL? = nil,
         retryInterval: Duration = .seconds(15),
         makeExposure: @escaping @MainActor () -> CompanionTailscaleServe = { CompanionTailscaleServe() }) {
        self.model = model
        self.defaults = defaults
        self.supportDirectory = supportDirectory
        self.makeExposure = makeExposure
        self.retryInterval = retryInterval
    }

    /// This Mac shares its local library while its background server and Tailscale are running.
    /// Listening does not create a pairing offer or authorize any device.
    func startForCentralDatabase() async {
        guard !DevelopmentLaunch.isClient else { return }
        guard model?.isLibraryClient == false else { return }
        if model?.isBackendFrontend == true { await forward(.status); return }
        guard availabilityTask == nil else { return }
        isEnabled = true
        availabilityTask = Task { [weak self, retryInterval] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.start()
                do { try await Task.sleep(for: retryInterval) } catch { return }
            }
        }
    }

    func start() async {
        guard !DevelopmentLaunch.isClient else { return }
        if model?.isBackendFrontend == true { await forward(.start); return }
        guard model?.isLibraryClient == false, !isStarting, endpoint == nil, model?.dashboardStore != nil else { return }
        isStarting = true; errorMessage = nil; status = "Connecting…"
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
            let centralIdentity = try await database.companionLibraryIdentity()
            discoveryIdentity = .init(deviceID: centralIdentity.hostDeviceID,
                deviceName: DevelopmentLaunch.deviceName(),
                metadata: CompanionMacPairingController.metadata)
            let api = CompanionWorkspaceAPI(database: database, authentication: authentication,
                commands: model.companionCommands,
                isActive: { [weak self] in self?.generation == expectedGeneration && self?.endpoint != nil },
                onCancelPairing: { [weak self] principal in
                    guard let self else { throw CompanionAPIError(code: "unavailable", message: "This sharing session stopped.") }
                    await self.revoke(principal.id, expected: principal)
                    guard await authentication.isCurrent(principal) == false else {
                        throw CompanionAPIError(code: "revocation_pending", message: "This device's pairing could not yet be cancelled.")
                    }
                },
                discovery: { [weak self] in self?.discoveryIdentity.map { .init(role: .central, identity: $0, capabilities: ["library.peers.v1"]) } },
                onPair: { [weak self] in await self?.didPair() },
                onMutation: { [weak model] in Task { await model?.refreshWorkspace() } },
                onRequest: { [weak self] in self?.lastSeenAt = Date() },
                linkedData: { [weak model] link in
                    guard let model else { throw CompanionAPIError(code: "unavailable", message: "The Mac workspace is closed.") }
                    do { return try await model.linkedData(for: link) }
                    catch { throw CompanionAPIError(code: "linked_data_unavailable", message: error.localizedDescription) }
                })
            let listener = CompanionHTTPServer { [weak self] request in
                guard let self else { return .error("unavailable", "This sharing session has stopped.", status: 503) }
                return await self.handle(request, generation: expectedGeneration, libraryAPI: api)
            }
            attemptListener = listener
            server = listener
            let localPort = try await listener.start()
            guard generation == expectedGeneration, !Task.isCancelled else { throw CancellationError() }
            let exposure = makeExposure()
            attemptExposure = exposure
            serve = exposure
            let portKey = "companion.https.port." + (try await database.companionWorkspaceID())
            // Only paired devices rely on a stable address. Before the first
            // pairing, an old occupied port must not prevent initial setup.
            let savedPort = pairedDevices.isEmpty ? nil : defaults.object(forKey: portKey) as? Int
            let address = try await exposure.start(loopbackPort: localPort, preferredHTTPSPort: savedPort)
            guard generation == expectedGeneration, !Task.isCancelled else { throw CancellationError() }
            defaults.set(address.port ?? 443, forKey: portKey)
            endpoint = address; isEnabled = true
            try await refreshExecutionRegistry()
            let identity = try await database.companionLibraryIdentity()
            let descriptors = try await database.companionExecutionWorkspaces()
            guard let local = descriptors.first(where: { $0.id == localExecutionWorkspaceID(libraryID: identity.libraryID) }) else {
                throw CompanionAPIError(code: "unavailable", message: "The local execution workspace could not be registered.")
            }
            let executionAuth = try loadExecutionAuthentication()
            guard generation == expectedGeneration, !Task.isCancelled else { throw CancellationError() }
            executionAPI = CompanionMacExecutionAPI(database: database, commands: model.companionCommands,
                authentication: executionAuth, descriptor: local,
                isActive: { [weak self] in self?.generation == expectedGeneration && self?.endpoint != nil },
                authorizeDevice: { deviceID in
                    let active = await authentication.devices()
                    guard deviceID == centralIdentity.hostDeviceID || active.contains(where: { $0.id == deviceID }) else {
                        throw CompanionAPIError(code: "unauthorized", message: "This device is no longer paired.")
                    }
                })
            inferenceHost = CompanionInferenceHost(authentication: executionAuth, descriptor: local,
                directory: try supportDirectory ?? ApplicationModel.dashboardSupportDirectory(),
                isActive: { [weak self] in self?.generation == expectedGeneration && self?.endpoint != nil })
            isStarting = false; status = "Available to your paired devices"
            try await peerSync.restore()
            // Availability alone must not hold the Mac awake. Active execution
            // continues to use the app's existing work/sleep policy.
            healthTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled, let self else { return }
                    if self.serve?.isRunning != true {
                        self.stopService()
                        self.errorMessage = "Tailscale is unavailable. Woven Matter will reconnect automatically."
                        return
                    }
                    do { try await self.refreshExecutionRegistry() }
                    catch { self.errorMessage = error.localizedDescription }
                    try? await LegacyMacLibraryUpgrade.reconnect(host: self, defaults: self.defaults)
                    await self.peerSync.synchronize()
                    await self.retryPendingRevocations()
                    await self.refreshStatus()
                    if let model = self.model, let client = try? model.centralExecutionClient() {
                        await client.refreshRegisteredWorkspaces()
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
            stopService(); errorMessage = error.localizedDescription
        }
    }

    private func handle(_ request: CompanionHTTPRequest, generation expected: UUID, libraryAPI: CompanionWorkspaceAPI) async -> CompanionHTTPResponse {
        guard generation == expected else { return .error("unavailable", "This sharing session has stopped.", status: 503) }
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        if let response = await peerSync.handle(request) { return response }
        if path == "/mcp" || path == "/wovenmatter/mcp" {
            if let response = await model?.agentTools?.handleMCP(request) { return response }
            return await libraryAPI.handle(request)
        }
        if path == "/mcp/workspace" || path == "/wovenmatter/mcp/workspace" { return await libraryAPI.handle(request) }
        if path == "/v1/execution" || path.hasPrefix("/v1/execution/") || path == "/wovenmatter/v1/execution" || path.hasPrefix("/wovenmatter/v1/execution/") {
            guard let executionAPI else { return .error("unavailable", "This execution workspace is starting.", status: 503) }
            return await executionAPI.handle(request)
        }
        if path.hasPrefix("/v1/inference/") || path.hasPrefix("/wovenmatter/v1/inference/") {
            guard let inferenceHost else { return .error("unavailable", "This inference host is starting.", status: 503) }
            return await inferenceHost.handle(request)
        }
        return await libraryAPI.handle(request)
    }

    /// Quit and role changes cancel recovery as well as the owned listener.
    /// Connection failures only stop the current attempt so recovery can continue.
    func stop() {
        availabilityTask?.cancel(); availabilityTask = nil
        isEnabled = false
        stopService()
    }

    private func stopService() {
        generation = UUID(); healthTask?.cancel(); healthTask = nil
        server?.stop(); server = nil; executionAPI = nil; inferenceHost = nil
        if let serve {
            serve.stop()
            if !stoppingExposures.contains(where: { $0 === serve }) { stoppingExposures.append(serve) }
            self.serve = nil
        }
        mcpSettingsFingerprints.removeAll()
        endpoint = nil; isStarting = false; status = "Unavailable"
        pairingPayload = nil; pairingExpiresAt = nil; discoveryIdentity = nil; pendingPairingRequests = []
        if let authentication { Task { await authentication.cancelOffer() } }
    }
    func stopSharing() {
        if model?.isBackendFrontend == true { Task { await forward(.stop) }; return }
        stop()
    }

    func createPairingCode() async {
        if model?.isBackendFrontend == true { await forward(.createCode); return }
        guard !isStarting, let endpoint, let authentication else { return }
        do {
            let offer = try await authentication.createOffer(endpoint: endpoint)
            pairingPayload = offer.payload; pairingExpiresAt = offer.expiresAt; errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func revoke(_ deviceID: String, expected: CompanionPairedDevice? = nil) async {
        if model?.isBackendFrontend == true { await forward(.revoke(deviceID)); return }
        guard !revokingDeviceIDs.contains(deviceID) else { return }
        revokingDeviceIDs.insert(deviceID)
        defer { revokingDeviceIDs.remove(deviceID) }
        do {
            try await loadAuthentication()
            if let expected, await authentication?.isCurrent(expected) != true {
                throw CompanionAPIError(code: "unauthorized", message: "This pairing has already changed.")
            }
            // Persist the remote work list before revoking local access. An offline
            // workspace remains explicitly pending until its token is removed.
            if let database = model?.dashboardStore?.database {
                let descriptors = try await database.companionExecutionWorkspaces()
                var pending = pendingRevocations
                let identity = try await database.companionLibraryIdentity()
                let localID = localExecutionWorkspaceID(libraryID: identity.libraryID)
                let targets = descriptors.filter { $0.kind != .ios && $0.id != localID && $0.libraryID == identity.libraryID && $0.journalDeviceIDs.contains(deviceID) }.map(\.id)
                let workspaceIDs = Array(Set((pending[deviceID] ?? []) + targets)).sorted()
                if workspaceIDs.isEmpty { pending.removeValue(forKey: deviceID) }
                else { pending[deviceID] = workspaceIDs }
                pendingRevocations = pending
            }
            try await authentication?.revoke(deviceID: deviceID, expected: expected)
            try await model?.dashboardStore?.database.withdrawUnpairedMac(deviceID)
            try await loadExecutionAuthentication().revoke(deviceID: deviceID)
            try peerSync.revoke(deviceID)
            pairedDevices = await authentication?.devices() ?? []
            pairingPayload = nil; pairingExpiresAt = nil; lastSeenAt = nil; errorMessage = nil
            try await removeJournalGrants(deviceID: deviceID)
            await retryPendingRevocations()
        } catch { errorMessage = error.localizedDescription }
    }
    private var pendingRevocations: [String: [String]] {
        get { defaults.dictionary(forKey: Self.pendingRevocationsKey) as? [String: [String]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.pendingRevocationsKey) }
    }

    private func localExecutionWorkspaceID(libraryID: String) -> String {
        let key = "companion.execution.local-id." + libraryID
        if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil { return value.lowercased() }
        let value = UUID().uuidString.lowercased(); defaults.set(value, forKey: key); return value
    }

    /// Registry changes do not open connections, start containers, or move workspace files.
    private func refreshExecutionRegistry() async throws {
        guard !registryRefreshInProgress, let model, let database = model.dashboardStore?.database else { return }
        registryRefreshInProgress = true
        let expectedGeneration = generation
        defer { registryRefreshInProgress = false }
        let identity = try await database.companionLibraryIdentity()
        try await database.savePairedRemoteWorkspaces(model.remoteWorkspaces.workspaces)
        let existing = try await database.companionExecutionWorkspaces()
        let localID = localExecutionWorkspaceID(libraryID: identity.libraryID)
        if DevelopmentLaunch.isSnapshot {
            // Upgrade existing snapshots too. New paired owners remain live; copied
            // owners retain their identity for history without becoming connections.
            let connected = await authentication?.devices() ?? []
            let paired = Set(connected.map(\.id))
            for var copied in existing where !copied.deleted && copied.retainedHistory != true
                && copied.id != localID && copied.ownerDeviceID != identity.hostDeviceID && !paired.contains(copied.ownerDeviceID) {
                guard generation == expectedGeneration, !Task.isCancelled else { return }
                copied.retainedHistory = true; copied.endpoint = nil
                _ = try await database.registerCompanionExecutionWorkspace(.init(workspace: copied, expectedRevision: copied.revision), deviceID: identity.hostDeviceID)
            }
        }
        var desired: [CompanionExecutionWorkspace] = [
            .init(id: localID, libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
                  kind: .mac, name: DevelopmentLaunch.deviceName(), endpoint: endpoint,
                  capabilities: ["execution.v1", "history.central.v1", "inference.v1"], executionDeviceID: identity.hostDeviceID, developmentInstance: DevelopmentLaunch.instance)
        ]
        desired += model.remoteWorkspaces.workspaces.map { configuration in
            let id = configuration.id.uuidString.lowercased()
            let prior = existing.first { $0.id == id }
            return .init(id: id, libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
                kind: .linux, name: configuration.name, endpoint: prior?.endpoint,
                capabilities: prior?.capabilities ?? ["execution.v1", "inference.v1"],
                executionDeviceID: prior?.executionDeviceID)
        }
        for var workspace in desired {
            guard generation == expectedGeneration, !Task.isCancelled else { return }
            let prior = existing.first { $0.id == workspace.id }
            guard prior?.deleted != true else { continue }
            workspace.journalDeviceIDs = prior?.journalDeviceIDs ?? []
            workspace.revision = prior?.revision ?? 0
            _ = try await database.registerCompanionExecutionWorkspace(
                .init(workspace: workspace, expectedRevision: prior?.revision), deviceID: identity.hostDeviceID)
        }
        guard generation == expectedGeneration, !Task.isCancelled else { return }
        executionWorkspaces = try await database.companionExecutionWorkspaces()
        for workspace in executionWorkspaces where workspace.kind == .linux && workspace.executionDeviceID != nil && !workspace.deleted {
            if let configuration = model.remoteWorkspaces.workspaces.first(where: { $0.id.uuidString.lowercased() == workspace.id }) {
                try? await ensureExecutionPublisher(workspace: workspace, configuration: configuration)
            }
        }
    }

    func provisionExecutionWorkspace(id: String, device: CompanionPairedDevice) async throws -> CompanionExecutionCredential {
        guard UUID(uuidString: id) != nil, let model, let database = model.dashboardStore?.database,
              authentication != nil, try await deviceMayExecute(device, workspaceID: id),
              !revokingDeviceIDs.contains(device.id), !provisioningWorkspaceIDs.contains(id) else {
            throw CompanionAPIError(code: "unavailable", message: "This workspace is unavailable or another enrollment is in progress. Retry shortly.")
        }
        provisioningWorkspaceIDs.insert(id)
        defer { provisioningWorkspaceIDs.remove(id) }
        let identity = try await database.companionLibraryIdentity()
        if let workspace = try await database.companionExecutionWorkspaces().first(where: { $0.id == id && !$0.deleted }), workspace.libraryID != identity.libraryID {
            return try await peerSync.provision(workspace: workspace, deviceID: device.id)
        }
        if id == localExecutionWorkspaceID(libraryID: identity.libraryID) {
            guard let executionAPI else { throw CompanionAPIError(code: "unavailable", message: "This Mac’s workspace connection is not ready yet.") }
            let expectedGeneration = generation
            let credential = try await executionAPI.provision(device: device)
            guard generation == expectedGeneration, endpoint != nil,
                  try await deviceMayExecute(device, workspaceID: id), !revokingDeviceIDs.contains(device.id) else {
                try await loadExecutionAuthentication().revoke(deviceID: device.id)
                throw CompanionAPIError(code: "unauthorized", message: "This device or sharing session was revoked during enrollment.")
            }
            return credential
        }
        try await completePendingRevocation(workspaceID: id, deviceID: device.id)
        guard try await deviceMayExecute(device, workspaceID: id), !revokingDeviceIDs.contains(device.id) else {
            throw CompanionAPIError(code: "unauthorized", message: "This device was revoked during enrollment.")
        }
        let configuration = model.remoteWorkspaces.workspaces.first(where: { $0.id.uuidString.lowercased() == id })
        let registered = try await database.companionExecutionWorkspaces().first { $0.id == id && !$0.deleted }
        var credential: CompanionExecutionCredential
        if let configuration {
            credential = try await model.remoteWorkspaces.provisionExecutionDevice(configuration: configuration,
                libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID, deviceID: device.id, deviceName: device.name)
        } else if let registered, registered.kind == .mac {
            credential = try await managedExecutionRequest(workspace: registered, deviceID: device.id, revoke: false)
        } else {
            throw CompanionAPIError(code: "unknown_workspace", message: "Enable client access on this workspace's managing device first.")
        }
        do {
            guard credential.deviceID == device.id, credential.workspace.id == id,
                  credential.workspace.libraryID == identity.libraryID,
                  registered.map({ original in
                      original.ownerDeviceID == credential.workspace.ownerDeviceID && original.kind == credential.workspace.kind
                          && (original.kind != .mac || original.endpoint == credential.workspace.endpoint)
                          && (original.executionDeviceID == nil || original.executionDeviceID == credential.workspace.executionDeviceID)
                  }) ?? (configuration != nil) else {
                throw CompanionAPIError(code: "wrong_workspace", message: "The workspace returned an execution grant for a different identity.")
            }
            guard try await deviceMayExecute(device, workspaceID: id), !revokingDeviceIDs.contains(device.id) else {
                throw CompanionAPIError(code: "unauthorized", message: "This device was revoked during enrollment.")
            }
            let prior = try await database.companionExecutionWorkspaces().first { $0.id == id }
            credential.workspace.journalDeviceIDs = Array(Set((prior?.journalDeviceIDs ?? []) + [device.id])).sorted()
            credential.workspace.revision = prior?.revision ?? 0
            credential.workspace = try await database.registerCompanionExecutionWorkspace(
                .init(workspace: credential.workspace, expectedRevision: prior?.revision), deviceID: identity.hostDeviceID)
            guard try await deviceMayExecute(device, workspaceID: id), !revokingDeviceIDs.contains(device.id) else {
                try await removeJournalGrants(deviceID: device.id)
                throw CompanionAPIError(code: "unauthorized", message: "This device was revoked during enrollment.")
            }
            if let configuration { try? await ensureExecutionPublisher(workspace: credential.workspace, configuration: configuration) }
            guard try await deviceMayExecute(device, workspaceID: id) else {
                throw CompanionAPIError(code: "unauthorized", message: "This device's execution access changed during enrollment.")
            }
            return credential
        } catch {
            enqueueRevocation(deviceID: device.id, workspaceID: id)
            await retryPendingRevocations()
            throw error
        }
    }

    /// Internal execution-owner path for this desktop itself. It cannot
    /// choose an arbitrary principal and is never exposed as a client HTTP route.
    func provisionCentralExecutionWorkspace(id: String) async throws -> CompanionExecutionCredential {
        guard let model, !model.isBackendFrontend, !model.isLibraryClient,
              let database = model.dashboardStore?.database, UUID(uuidString: id) != nil,
              !provisioningWorkspaceIDs.contains(id) else {
            throw CompanionAPIError(code: "unavailable", message: "This Mac’s execution owner is unavailable.")
        }
        provisioningWorkspaceIDs.insert(id)
        defer { provisioningWorkspaceIDs.remove(id) }
        let identity = try await database.companionLibraryIdentity()
        if let workspace = try await database.companionExecutionWorkspaces().first(where: { $0.id == id && !$0.deleted }), workspace.libraryID != identity.libraryID {
            return try await peerSync.provision(workspace: workspace, deviceID: identity.hostDeviceID)
        }
        try await completePendingRevocation(workspaceID: id, deviceID: identity.hostDeviceID)
        let registered = try await database.companionExecutionWorkspaces().first { $0.id == id && !$0.deleted }
        var credential: CompanionExecutionCredential
        if let configuration = model.remoteWorkspaces.workspaces.first(where: { $0.id.uuidString.lowercased() == id }) {
            credential = try await model.remoteWorkspaces.provisionExecutionDevice(configuration: configuration,
                libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
                deviceID: identity.hostDeviceID, deviceName: Host.current().localizedName ?? "Mac")
        } else if let registered, registered.kind == .mac {
            credential = try await managedExecutionRequest(workspace: registered, deviceID: identity.hostDeviceID, revoke: false)
        } else {
            throw CompanionAPIError(code: "unavailable", message: "This execution workspace must be reachable and enrolled before this Mac can control it.")
        }
        guard credential.deviceID == identity.hostDeviceID, credential.workspace.id == id,
              credential.workspace.libraryID == identity.libraryID,
              registered.map({ original in
                  original.ownerDeviceID == credential.workspace.ownerDeviceID && original.kind == credential.workspace.kind
                      && (original.kind != .mac || original.endpoint == credential.workspace.endpoint)
                      && (original.executionDeviceID == nil || original.executionDeviceID == credential.workspace.executionDeviceID)
              }) ?? true else {
            throw CompanionAPIError(code: "wrong_workspace", message: "The execution workspace returned a different identity.")
        }
        let prior = try await database.companionExecutionWorkspaces().first { $0.id == id }
        credential.workspace.journalDeviceIDs = Array(Set((prior?.journalDeviceIDs ?? []) + [identity.hostDeviceID])).sorted()
        credential.workspace.revision = prior?.revision ?? 0
        credential.workspace = try await database.registerCompanionExecutionWorkspace(
            .init(workspace: credential.workspace, expectedRevision: prior?.revision), deviceID: identity.hostDeviceID)
        if let configuration = model.remoteWorkspaces.workspaces.first(where: { $0.id.uuidString.lowercased() == id }) {
            try? await ensureExecutionPublisher(workspace: credential.workspace, configuration: configuration)
        }
        return credential
    }

    func registerExecutionManagement(_ grant: CompanionExecutionManagementGrant, device: CompanionPairedDevice) async throws -> CompanionExecutionWorkspace {
        guard let database = model?.dashboardStore?.database, let authentication,
              await authentication.isCurrent(device),
              let workspace = try await database.companionExecutionWorkspaces().first(where: { $0.id == grant.workspaceID }),
              !workspace.deleted, workspace.kind == .mac, workspace.ownerDeviceID == device.id,
              workspace.endpoint == grant.endpoint,
              CompanionPairingPayload.isValidEndpoint(grant.endpoint), (32...256).contains(grant.token.utf8.count) else {
            throw CompanionAPIError(code: "wrong_owner", message: "Only the registered workspace owner can enable managed device access.")
        }
        guard await authentication.isCurrent(device), !revokingDeviceIDs.contains(device.id) else {
            throw CompanionAPIError(code: "unauthorized", message: "This workspace owner was revoked during enrollment.")
        }
        try ExecutionManagementVault.save(grant, libraryID: workspace.libraryID)
        return workspace
    }

    private func deviceMayExecute(_ device: CompanionPairedDevice, workspaceID: String) async throws -> Bool {
        guard let authentication, let database = model?.dashboardStore?.database,
              !revokingDeviceIDs.contains(device.id), await authentication.isCurrent(device) else { return false }
        guard try await database.companionExecutionWorkspaces().contains(where: { $0.id == workspaceID && !$0.deleted }) else { return false }
        return await authentication.isCurrent(device)
    }

    func withdrawDevelopmentWorkspace() async throws {
        guard DevelopmentLaunch.mode != nil, let database = model?.dashboardStore?.database else { return }
        stop() // Cancel recovery as well as periodic registrations before withdrawal.
        do {
            let identity = try await database.companionLibraryIdentity()
            let id = localExecutionWorkspaceID(libraryID: identity.libraryID)
            if var workspace = try await database.companionExecutionWorkspaces().first(where: { $0.id == id && !$0.deleted }) {
                workspace.endpoint = nil
                _ = try await database.registerCompanionExecutionWorkspace(.init(workspace: workspace, expectedRevision: workspace.revision), deviceID: identity.hostDeviceID)
            }
        } catch {
            await startForCentralDatabase()
            throw error
        }
    }

    func disconnectLocalDevelopment(_ request: DevelopmentDisconnectRequest) async throws {
        guard let authentication, let database = model?.dashboardStore?.database else { throw CompanionAPIError(code: "unavailable", message: "This Mac’s library is unavailable.") }
        try await authentication.suspendLocalDevelopment(deviceID: request.deviceID, credential: request.credential)
        try await database.withdrawDevelopmentWorkspaces(ownedBy: request.deviceID)
        try await refreshStatusAndDevelopmentPresence(database: database)
    }

    private func refreshStatusAndDevelopmentPresence(database: WorkspaceDatabase) async throws {
        pairedDevices = await authentication?.devices() ?? []
        let active = Set(pairedDevices.map(\.id))
        executionWorkspaces = try await database.companionConnectionWorkspaces(activeDeviceIDs: active)
    }

    private func enqueueRevocation(deviceID: String, workspaceID: String) {
        var pending = pendingRevocations
        pending[deviceID] = Array(Set((pending[deviceID] ?? []) + [workspaceID])).sorted()
        pendingRevocations = pending
        pendingDeviceRevocations = pending
    }

    private func managedExecutionRequest<Value: Decodable>(workspace: CompanionExecutionWorkspace, deviceID: String, revoke: Bool) async throws -> Value {
        guard let grant = try ExecutionManagementVault.load(libraryID: workspace.libraryID, workspaceID: workspace.id),
              grant.endpoint == workspace.endpoint, CompanionPairingPayload.isValidEndpoint(grant.endpoint) else {
            throw CompanionAPIError(code: "unavailable", message: "Reconnect this workspace's Mac and enable execution sharing before granting access.")
        }
        var request = URLRequest(url: grant.endpoint.appendingPathComponent(revoke ? "v1/execution/manage/revoke" : "v1/execution/manage/devices"))
        request.httpMethod = "POST"
        request.httpBody = try JSONEncoder().encode(["deviceID": deviceID])
        request.setValue("Bearer " + grant.token, forHTTPHeaderField: "Authorization")
        request.setValue(String(CompanionProtocol.version), forHTTPHeaderField: "X-Woven-Protocol")
        request.setValue(workspace.libraryID, forHTTPHeaderField: "X-Woven-Library")
        request.setValue(workspace.id, forHTTPHeaderField: "X-Woven-Workspace")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: ExecutionManagementRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200,
              response.expectedContentLength <= 1_048_576 else {
            throw CompanionAPIError(code: "unavailable", message: "The workspace's Mac did not authorize this device-management request.")
        }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw CompanionAPIError(code: "invalid_response", message: "Device-management response exceeds its size limit.") }
            data.append(byte)
        }
        return try JSONDecoder().decode(Value.self, from: data)
    }

    private func removeJournalGrants(deviceID: String) async throws {
        guard let database = model?.dashboardStore?.database else { return }
        let identity = try await database.companionLibraryIdentity()
        for var workspace in try await database.companionExecutionWorkspaces() where !workspace.deleted && workspace.libraryID == identity.libraryID && workspace.journalDeviceIDs.contains(deviceID) {
            let revision = workspace.revision
            workspace.journalDeviceIDs.removeAll { $0 == deviceID }
            _ = try await database.registerCompanionExecutionWorkspace(.init(workspace: workspace, expectedRevision: revision), deviceID: identity.hostDeviceID)
        }
    }

    /// Called only while holding the workspace operation guard. A replacement
    /// enrollment cannot race an old revocation or inherit its pending entry.
    private func completePendingRevocation(workspaceID: String, deviceID: String) async throws {
        guard pendingRevocations[deviceID]?.contains(workspaceID) == true, let model else { return }
        if let configuration = model.remoteWorkspaces.workspaces.first(where: { $0.id.uuidString.lowercased() == workspaceID }) {
            try await model.remoteWorkspaces.revokeExecutionDevice(configuration: configuration, deviceID: deviceID)
        } else if let workspace = try await model.dashboardStore?.database.companionExecutionWorkspaces().first(where: { $0.id == workspaceID && $0.kind == .mac }) {
            let acknowledgement: ExecutionManagementAcknowledgement = try await managedExecutionRequest(workspace: workspace, deviceID: deviceID, revoke: true)
            guard acknowledgement.revoked else {
                throw CompanionAPIError(code: "revocation_pending", message: "The workspace has not yet revoked this device.")
            }
        } else {
            throw CompanionAPIError(code: "revocation_pending", message: "Reconnect this workspace before enrolling this device again.")
        }
        var pending = pendingRevocations
        pending[deviceID]?.removeAll { $0 == workspaceID }
        if pending[deviceID]?.isEmpty == true { pending.removeValue(forKey: deviceID) }
        pendingRevocations = pending
    }

    private func retryPendingRevocations() async {
        guard !revocationRetryInProgress, model != nil else { return }
        revocationRetryInProgress = true
        defer { revocationRetryInProgress = false }
        // Older persisted state may contain a device with no remote targets.
        pendingRevocations = pendingRevocations.filter { !$0.value.isEmpty }
        for (deviceID, ids) in pendingRevocations {
            for id in ids where !provisioningWorkspaceIDs.contains(id) {
                provisioningWorkspaceIDs.insert(id)
                do { try await completePendingRevocation(workspaceID: id, deviceID: deviceID) }
                catch { /* Retain the durable entry until its workspace acknowledges. */ }
                provisioningWorkspaceIDs.remove(id)
            }
        }
        let pendingMessage = "Device access changes are pending on workspaces that have not reconnected yet."
        if !pendingRevocations.isEmpty { errorMessage = pendingMessage }
        else if errorMessage == pendingMessage { errorMessage = nil }
    }

    var snapshot: CompanionHostSnapshot {
        .init(isEnabled: isEnabled, isStarting: isStarting, endpoint: endpoint, status: status,
              errorMessage: errorMessage, pairingPayload: pairingPayload, pairingExpiresAt: pairingExpiresAt,
              pairedDevices: pairedDevices, lastSeenAt: lastSeenAt, discoveredPeers: discoveredPeers,
              pendingPairingRequests: pendingPairingRequests, isDiscovering: isDiscovering, executionWorkspaces: executionWorkspaces,
              pendingDeviceRevocations: pendingRevocations, peerPairingStatus: peerSync.pairing.status, peerPairingError: peerSync.pairing.errorMessage, peerSyncErrors: peerSync.errors, peerRoutes: peerSync.routes, peerIdentity: discoveryIdentity)
    }

    func refreshStatus() async {
        if model?.isBackendFrontend == true { await forward(.status); return }
        do {
            try await loadAuthentication()
            pendingPairingRequests = await authentication?.pendingPairingRequests() ?? []
            pendingDeviceRevocations = pendingRevocations
            if let database = model?.dashboardStore?.database { try await refreshStatusAndDevelopmentPresence(database: database) }
        } catch { errorMessage = error.localizedDescription }
    }
    func refreshDiscovery() async {
        if model?.isBackendFrontend == true { await forward(.discover); return }
        guard !isDiscovering else { return }
        isDiscovering = true; errorMessage = nil
        defer { isDiscovering = false }
        do { discoveredPeers = try await discovery.discover() }
        catch { errorMessage = error.localizedDescription }
    }
    func approvePairing(id: String) async {
        if model?.isBackendFrontend == true { await forward(.approvePairing(id)); return }
        guard endpoint != nil, let authentication, let database = model?.dashboardStore?.database else { return }
        do {
            try await authentication.approvePairing(id: id, workspaceID: database.companionWorkspaceID())
            await refreshStatus(); errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func denyPairing(id: String) async {
        if model?.isBackendFrontend == true { await forward(.denyPairing(id)); return }
        do { try await authentication?.denyPairing(id: id); await refreshStatus() }
        catch { errorMessage = error.localizedDescription }
    }
    func invitePairing(peer: CompanionDiscoveredPeer) async {
        if model?.isBackendFrontend == true { await forward(.invitePairing(peer)); return }
        guard peer.advertisement.role == .client, discoveredPeers.contains(peer),
              let endpoint, let authentication, let identity = discoveryIdentity else { return }
        do {
            let offer = try await authentication.createOffer(endpoint: endpoint, deviceID: peer.advertisement.identity.deviceID)
            let invitation = CompanionPairingInvitation(id: UUID().uuidString.lowercased(), central: identity,
                payload: offer.payload, expiresAt: offer.expiresAt)
            let _: [String: Bool] = try await pairingNetwork.request(peer.endpoint, path: "v1/pairing/invite", body: JSONEncoder().encode(invitation))
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }

    private func forward(_ action: CompanionHostAction) async {
        guard let model else { return }
        do {
            guard let value = try await model.sendBackendCommand(.companion(action)).companion else { return }
            isEnabled = value.isEnabled; isStarting = value.isStarting; endpoint = value.endpoint
            status = value.status; errorMessage = value.errorMessage; pairingPayload = value.pairingPayload
            pairingExpiresAt = value.pairingExpiresAt; pairedDevices = value.pairedDevices; lastSeenAt = value.lastSeenAt
            discoveredPeers = value.discoveredPeers; pendingPairingRequests = value.pendingPairingRequests
            isDiscovering = value.isDiscovering; executionWorkspaces = value.executionWorkspaces
            pendingDeviceRevocations = value.pendingDeviceRevocations
            peerPairingStatus = value.peerPairingStatus ?? ""; peerPairingError = value.peerPairingError
            projectedPeerRoutes = value.peerRoutes ?? []; discoveryIdentity = value.peerIdentity
            peerSyncErrors = value.peerSyncErrors ?? [:]
        } catch { errorMessage = error.localizedDescription }
    }

    func peerAuthentication() async throws -> CompanionAuthentication {
        try await loadAuthentication()
        guard let authentication else { throw CancellationError() }
        return authentication
    }
    func peerRoute() async throws -> PairedMacRoute {
        guard let endpoint, let database = model?.dashboardStore?.database else { throw CompanionAPIError(code: "unavailable", message: "Wait for this Mac to connect to Tailscale before pairing.") }
        let identity = try await database.companionLibraryIdentity()
        return .init(deviceID: identity.hostDeviceID, libraryID: identity.libraryID, endpoint: endpoint, name: DevelopmentLaunch.deviceName())
    }
    func pairWithPeer(_ peer: CompanionDiscoveredPeer) async {
        if model?.isBackendFrontend == true { await forward(.pairWithPeer(peer)); return }
        guard peer.advertisement.identity.deviceID != discoveryIdentity?.deviceID else { return }
        await peerSync.pairing.requestPairing(with: peer)
    }
    func pairAtEndpoint(_ endpoint: URL) async {
        if model?.isBackendFrontend == true { await forward(.pairAtEndpoint(endpoint)); return }
        do {
            let advertisement: CompanionDiscoveryAdvertisement = try await pairingNetwork.request(endpoint, path: "v1/discovery")
            guard advertisement.capabilities?.contains("library.peers.v1") == true else { throw CompanionAPIError(code: "update_required", message: "Update both Macs before pairing their libraries.") }
            await pairWithPeer(.init(endpoint: endpoint, advertisement: advertisement))
        } catch { errorMessage = error.localizedDescription }
    }
    func pairUsingLink(_ link: String) async {
        if model?.isBackendFrontend == true { await forward(.pairUsingLink(link)); return }
        do { try await peerSync.pairUsingLink(link); errorMessage = nil; await refreshStatus() }
        catch { errorMessage = error.localizedDescription }
    }
    func cancelPeerPairing() async {
        if model?.isBackendFrontend == true { await forward(.cancelPeerPairing); return }
        peerSync.pairing.cancelRequest()
    }
    func applyPeerRevocations() async throws {
        guard let authentication else { return }
        let devices = await authentication.peerDevices()
        let revoked = Set(devices.filter { $0.revokedAt != nil }.map(\.id))
            .subtracting(devices.filter { $0.revokedAt == nil }.map(\.id))
        var processed = Set(defaults.stringArray(forKey: "companion.peers.applied-revocations") ?? [])
        for id in revoked {
            let stamp = devices.filter { $0.id == id }.compactMap(\.revokedAt).max()?.timeIntervalSince1970 ?? 0
            let key = id + ":" + String(stamp)
            if !processed.contains(key) {
                await revoke(id)
                processed.insert(key)
            }
        }
        defaults.set(Array(processed).sorted(), forKey: "companion.peers.applied-revocations")
        pairedDevices = await authentication.devices()
    }

    private func loadExecutionAuthentication() throws -> CompanionExecutionAuthentication {
        if let executionAuthentication { return executionAuthentication }
        let file = try (supportDirectory ?? ApplicationModel.dashboardSupportDirectory()).appending(path: "execution-devices.json")
        let value = try CompanionExecutionAuthentication(fileURL: file)
        executionAuthentication = value
        return value
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

    func connectLocalDevelopment(_ request: DevelopmentClientRequest) async throws -> DevelopmentClientConnection {
        guard DevelopmentLaunch.mode == nil || DevelopmentLaunch.isLiveHost, model?.isLibraryClient == false,
              let database = model?.dashboardStore?.database, let endpoint, let authentication else {
            throw CompanionAPIError(code: "unavailable", message: "Run production with background execution enabled, or a live Dev host, and wait for its library to connect.")
        }
        let response = try await authentication.enrollLocalDevelopment(deviceID: request.deviceID,
            name: request.name, workspaceID: database.companionWorkspaceID())
        await didPair()
        return .init(endpoint: endpoint, pairing: response)
    }
}

// Settings is a projection. Only the background execution owner opens the HTTP
// listener, holds pairing secrets, and owns the Tailscale Serve child.
enum CompanionHostAction: Codable, Sendable {
    case status, start, stop, createCode
    case revoke(String), approvePairing(String), denyPairing(String)
    case discover, invitePairing(CompanionDiscoveredPeer), pairWithPeer(CompanionDiscoveredPeer), pairAtEndpoint(URL), pairUsingLink(String), cancelPeerPairing
}

struct CompanionHostSnapshot: Codable, Sendable {
    let isEnabled: Bool
    let isStarting: Bool
    let endpoint: URL?
    let status: String
    let errorMessage: String?
    let pairingPayload: CompanionPairingPayload?
    let pairingExpiresAt: Date?
    let pairedDevices: [CompanionPairedDevice]
    let lastSeenAt: Date?
    let discoveredPeers: [CompanionDiscoveredPeer]
    let pendingPairingRequests: [CompanionPendingPairingRequest]
    let isDiscovering: Bool
    let executionWorkspaces: [CompanionExecutionWorkspace]
    let pendingDeviceRevocations: [String: [String]]
    var peerPairingStatus: String? = nil
    var peerPairingError: String? = nil
    var peerSyncErrors: [String: String]? = nil
    var peerRoutes: [PairedMacRoute]? = nil
    var peerIdentity: CompanionPairingDeviceIdentity? = nil
}

private struct ExecutionManagementAcknowledgement: Decodable { let revoked: Bool }
private final class ExecutionManagementRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The Mac that added a workspace holds its scoped enrollment capability here.
/// Tokens never enter SQLite, replicated app data, logs, or UserDefaults.
private enum ExecutionManagementVault {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "com.wovenmatter") + ".execution-management" }
    private static func query(libraryID: String, workspaceID: String) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword, kSecAttrService: service,
         kSecAttrAccount: libraryID + ":" + workspaceID]
    }
    static func save(_ grant: CompanionExecutionManagementGrant, libraryID: String) throws {
        let query = query(libraryID: libraryID, workspaceID: grant.workspaceID)
        let attributes: [CFString: Any] = [kSecValueData: try JSONEncoder().encode(grant),
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            let inserted = SecItemAdd(query.merging(attributes) { _, value in value } as CFDictionary, nil)
            guard inserted == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(inserted)) }
        } else if status != errSecSuccess { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    static func load(libraryID: String, workspaceID: String) throws -> CompanionExecutionManagementGrant? {
        var query = query(libraryID: libraryID, workspaceID: workspaceID)
        query[kSecReturnData] = true; query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return try JSONDecoder().decode(CompanionExecutionManagementGrant.self, from: data)
    }
}
