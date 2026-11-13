import AppKit
import Foundation
import Observation
import Security
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// Debug test builds must opt into a separate workspace before any lease/database
/// opens. The same value is used by the app lease, database, journal and note socket.
enum IsolatedTestWorkspace {
    nonisolated static var supportDirectory: URL? {
        #if DEBUG
        let arguments = CommandLine.arguments
        let requested: URL
        if let index = arguments.firstIndex(of: "--isolated-test-workspace") {
            guard arguments.indices.contains(index + 1), arguments[index + 1].hasPrefix("/") else {
                fatalError("An absolute isolated test workspace is required")
            }
            requested = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        } else if Bundle.main.bundleIdentifier == "com.wovenmatter.macos.isolated-test" {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            requested = support.appending(path: "Woven Matter Isolated Test", directoryHint: .isDirectory)
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
            fatalError("The isolated test app cannot open a production workspace")
        }
        return isolated
        #else
        return nil
        #endif
    }
}

@Observable @MainActor
final class LibraryHostController {
    weak var model: ApplicationModel?
    private(set) var isEnabled = false
    private(set) var isStarting = false
    private(set) var endpoint: URL?
    private(set) var status = "Unavailable"
    private(set) var errorMessage: String?
    private(set) var pairingPayload: PairingPayload?
    private(set) var pairingExpiresAt: Date?
    private(set) var discoveredPeers: [DiscoveredPeer] = []
    private(set) var pendingPairingRequests: [PendingPairingRequest] = []
    private(set) var executionWorkspaces: [ExecutionWorkspace] = []
    private(set) var isDiscovering = false
    private(set) var pendingDeviceRevocations: [String: [String]] = [:]
    @ObservationIgnored lazy var peerSync = PairedMacSyncController(host: self, storage: peerStorage)
    /// Device-only secrets for paired Macs and direct execution grants.
    let peerStorage: PairedMacDeviceStorage
    private(set) var peerPairingStatus = ""
    private(set) var peerSyncErrors: [String: String] = [:]
    private(set) var peerPairingError: String?
    private var projectedPeerRoutes: [PairedMacRoute] = []
    var connectedPeerRoutes: [PairedMacRoute] { model?.isBackendFrontend == true ? projectedPeerRoutes : peerSync.routes }
    var peerIdentity: PairingDeviceIdentity? { discoveryIdentity }
    private var discoveryIdentity: PairingDeviceIdentity?
    private let discovery = MacDiscovery()
    private let pairingNetwork = PairingNetwork()
    private(set) var pairedDevices: [PairedDevice] = []
    private(set) var lastSeenAt: Date?
    private var authentication: DeviceAuthentication?
    private var executionAPI: MacExecutionAPI?
    /// `GET /v1/stream`: live sessions for every other member device.
    private(set) var executionStream: ExecutionStreamServer?
    /// Open stream sockets and bots relays by member, closed when a member is removed.
    private var memberSockets: MemberSocketRegistry?
    private var inferenceHost: InferenceHost?
    /// Who may use this Mac's bots from another device (`/v1/bots/*`).
    private var authorizeBots: (@MainActor (LibraryHTTPRequest) async throws -> Void)?
    private var executionAuthentication: ExecutionAuthentication?
    private var provisioningWorkspaceIDs: Set<String> = []
    private var revokingDeviceIDs: Set<String> = []
    var mcpSettingsFingerprints: [String: String] = [:]
    private var registryRefreshInProgress = false
    /// Linux hosts this Mac finished setting up this launch, and those whose
    /// setup is retrying (`setUpLinuxHost`).
    @ObservationIgnored private var readyLinuxHosts: Set<String> = []
    @ObservationIgnored private var linuxHostSetups: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    /// Test seam: the first retry delay, doubled after each failure up to ten minutes.
    @ObservationIgnored var linuxHostSetupRetry: Duration = .seconds(5)
    /// Test seam: adoption and enrollment of a Linux host. A test process sets
    /// up no host unless a fixture supplies these, so it never reaches SSH or Keychain.
    struct LinuxHostSetupSteps {
        var adopt: @MainActor (RemoteWorkspaceConfiguration) async throws -> Void
        var enroll: @MainActor (String) async throws -> Void
    }
    @ObservationIgnored var linuxHostSetupSteps: LinuxHostSetupSteps?
    private var revocationRetryInProgress = false
    private static let pendingRevocationsKey = "library.execution.pending-revocations"
    private static let pendingInstallerRotationsKey = "library.execution.pending-installer-rotations"
    nonisolated static let appliedPeerRevocationsKey = "library.peers.applied-revocations"
    /// Followed by the library ID.
    private static let httpsPortKeyPrefix = "library.https.port."
    /// Followed by the library ID.
    nonisolated static let localExecutionIDKeyPrefix = "library.execution.local-id."
    private var server: LibraryHTTPServer?
    private var serve: TailscaleServe?
    private var stoppingExposures: [TailscaleServe] = []
    private let defaults: UserDefaults
    private let supportDirectory: URL?
    private let makeExposure: @MainActor () -> TailscaleServe
    private var generation = UUID()
    private var healthTask: Task<Void, Never>?
    private var availabilityTask: Task<Void, Never>?
    private let retryInterval: Duration

    /// Settings saved before November 2026 used a "companion." prefix. They
    /// move once, keeping pending revocations, the HTTPS port and this Mac's
    /// execution workspace ID.
    nonisolated static func moveLegacyDefaults(in defaults: UserDefaults) {
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("companion.") {
            let current = "library." + key.dropFirst("companion.".count)
            if defaults.object(forKey: current) == nil { defaults.set(value, forKey: current) }
            defaults.removeObject(forKey: key)
        }
    }
    init(model: ApplicationModel, defaults: UserDefaults = .standard, supportDirectory: URL? = nil,
         retryInterval: Duration = .seconds(15),
         peerStorage: PairedMacDeviceStorage? = nil,
         makeExposure: @escaping @MainActor () -> TailscaleServe = { TailscaleServe() }) {
        self.peerStorage = peerStorage ?? .standard
        self.model = model
        self.defaults = defaults
        Self.moveLegacyDefaults(in: defaults)
        self.supportDirectory = supportDirectory
        self.makeExposure = makeExposure
        self.retryInterval = retryInterval
    }

    /// This Mac shares its local library while its background server and Tailscale are running.
    /// Listening does not create a pairing offer or authorize any device.
    func startForCentralDatabase() async {
        guard model != nil else { return }
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
        if model?.isBackendFrontend == true { await forward(.start); return }
        guard !isStarting, endpoint == nil, model?.dashboardStore != nil else { return }
        isStarting = true; errorMessage = nil; status = "Connecting…"
        generation = UUID()
        let expectedGeneration = generation
        var attemptListener: LibraryHTTPServer?
        var attemptExposure: TailscaleServe?
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
                throw LibraryAPIError(code: "unavailable", message: "The Mac workspace is not ready.")
            }
            let centralIdentity = try await database.libraryIdentity()
            discoveryIdentity = .init(deviceID: centralIdentity.hostDeviceID,
                deviceName: DevelopmentLaunch.deviceName(),
                metadata: MacPairingController.metadata)
            let api = DeviceAPI(database: database, authentication: authentication,
                commands: model.libraryCommands,
                isActive: { [weak self] in self?.generation == expectedGeneration && self?.endpoint != nil },
                onCancelPairing: { [weak self] principal in
                    guard let self else { throw LibraryAPIError(code: "unavailable", message: "This sharing session stopped.") }
                    await self.revoke(principal.id, expected: principal)
                    guard await authentication.isCurrent(principal) == false else {
                        throw LibraryAPIError(code: "revocation_pending", message: "This device's pairing could not yet be cancelled.")
                    }
                },
                discovery: { [weak self] in self?.discoveryIdentity.map { .init(role: .central, identity: $0, capabilities: [PairedMacSyncController.capability]) } },
                onPair: { [weak self] in await self?.didPair() },
                onMutation: { [weak model] in Task { await model?.refreshWorkspace() } },
                onRequest: { [weak self] in self?.lastSeenAt = Date() },
                linkedData: { [weak model] link in
                    guard let model else { throw LibraryAPIError(code: "unavailable", message: "The Mac workspace is closed.") }
                    do { return try await model.linkedData(for: link) }
                    catch { throw LibraryAPIError(code: "linked_data_unavailable", message: error.localizedDescription) }
                }, members: try? await peerSync.members(),
                onMemberPaired: { [weak self] deviceID, name, key in
                    // Pairing again on this Mac replaces the phone's key (a
                    // restored backup); a refusal is returned to the phone.
                    guard let self else { throw LibraryAPIError(code: "unavailable", message: "This sharing session stopped.") }
                    try await self.peerSync.members().add(deviceID: deviceID, kind: .ios, name: name, publicKey: key, endpoints: [], replacingKey: true)
                    await self.peerSync.librarySync?.scheduleAll()
                }, syncStatus: { [weak self] in await self?.peerSync.librarySync?.status() })
            let listener = LibraryHTTPServer(upgradeHandler: { [weak self] request in
                guard let self else { return .reject(.error("unavailable", "This sharing session has stopped.", status: 503)) }
                return await self.upgrade(request, generation: expectedGeneration)
            }) { [weak self] request in
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
            let portKey = Self.httpsPortKeyPrefix + (try await database.libraryID())
            // Only paired devices rely on a stable address. Before the first
            // pairing, an old occupied port must not prevent initial setup.
            let savedPort = pairedDevices.isEmpty ? nil : defaults.object(forKey: portKey) as? Int
            let address = try await exposure.start(loopbackPort: localPort, preferredHTTPSPort: savedPort)
            guard generation == expectedGeneration, !Task.isCancelled else { throw CancellationError() }
            defaults.set(address.port ?? 443, forKey: portKey)
            endpoint = address; isEnabled = true
            try await refreshExecutionRegistry()
            let identity = try await database.libraryIdentity()
            let descriptors = try await database.libraryExecutionWorkspaces()
            guard let local = descriptors.first(where: { $0.id == localExecutionWorkspaceID(libraryID: identity.libraryID) }) else {
                throw LibraryAPIError(code: "unavailable", message: "The local execution workspace could not be registered.")
            }
            let executionAuth = try loadExecutionAuthentication()
            // Grants from before provenance existed cannot prove who received
            // them; all but this Mac's own re-enroll through an active Mac.
            try await executionAuth.retireUnknownProvenance(keeping: identity.hostDeviceID)
            guard generation == expectedGeneration, !Task.isCancelled else { throw CancellationError() }
            // Each presented execution or inference grant is authorized live by
            // its own provenance: a delegated grant ends with its provisioning Mac.
            let authorizeGrant: InferenceHost.Authorize = { deviceID, provisionedBy in
                if deviceID == centralIdentity.hostDeviceID, provisionedBy == nil { return }
                guard await authentication.authorizesExecution(deviceID: deviceID, provisionedBy: provisionedBy) else {
                    throw LibraryAPIError(code: "unauthorized", message: "This device is no longer paired.")
                }
            }
            executionAPI = MacExecutionAPI(database: database, commands: model.libraryCommands,
                authentication: executionAuth, descriptor: local,
                isActive: { [weak self] in self?.generation == expectedGeneration && self?.endpoint != nil },
                authorizeDevice: { deviceID in
                    // This Mac, a grant it issued, or a live delegation from a Mac
                    // it still admits. Replicated membership never authorizes.
                    if deviceID == centralIdentity.hostDeviceID { return }
                    guard await authentication.mayExecute(deviceID: deviceID) else {
                        throw LibraryAPIError(code: "unauthorized", message: "This device is no longer paired.")
                    }
                }, authorizeGrant: authorizeGrant, members: try? await peerSync.members())
            // A stream that cannot start leaves the HTTP routes serving; its
            // upgrade answers 503 until the next start.
            if let directory = try? await peerSync.members(), let executionAPI {
                let registry = MemberSocketRegistry(members: directory)
                let stream = ExecutionStreamServer(database: database, source: executionAPI, members: directory, registry: registry)
                if (try? await stream.start()) != nil {
                    guard generation == expectedGeneration, !Task.isCancelled else { stream.stop(); throw CancellationError() }
                    memberSockets = registry; executionStream = stream
                    model.executionStreamChanged = { [weak stream, weak model] ids in
                        stream?.liveStateChanged(conversationIDs: ids)
                        // Waits on this Mac's sessions follow the same in-memory changes.
                        Task { await model?.sessionWakeUpsLocalChanged(ids) }
                    }
                } else { stream.stop() }
            }
            // Only a signed member request (a Mac or phone member). Other Macs
            // reach this Mac's bots with their member key; no grant is accepted.
            authorizeBots = { [weak self] request in
                guard MemberRequestVerifier.isSigned(request.headers) else {
                    throw LibraryAPIError(code: "unauthorized", message: "Sign this request with a member device key.")
                }
                guard let self else { throw LibraryAPIError(code: "unavailable", message: "This sharing session has stopped.") }
                _ = try await self.authenticateMember(request, allowing: [.mac, .ios])
            }
            inferenceHost = InferenceHost(authentication: executionAuth, descriptor: local,
                directory: try supportDirectory ?? ApplicationModel.dashboardSupportDirectory(),
                isActive: { [weak self] in self?.generation == expectedGeneration && self?.endpoint != nil }, authorize: authorizeGrant,
                members: try? await peerSync.members())
            isStarting = false; status = "Available to your paired devices"
            // Paired-Mac credential storage is independent of phone and library
            // availability. A failure is reported and retried, never fatal.
            await peerSync.restoreRecordingFailures()
            // This Mac's streams to every other machine open now; afterwards
            // only a registry or member change opens or closes one.
            await connectExecutionStreams()
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
                    await self.peerSync.synchronize()
                    await self.retryPendingRevocations()
                    await self.refreshStatus()
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

    private func handle(_ request: LibraryHTTPRequest, generation expected: UUID, libraryAPI: DeviceAPI) async -> LibraryHTTPResponse {
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
        let botsPath = path.hasPrefix("/wovenmatter/") ? String(path.dropFirst("/wovenmatter".count)) : path
        if botsPath.hasPrefix("/v1/bots/") {
            guard let authorizeBots, let host = model?.botsHost else { return .error("unavailable", "Bots on this Mac are starting.", status: 503) }
            do { try await authorizeBots(request) }
            catch { return .error("unauthorized", error.localizedDescription, status: 401) }
            return await host.remoteRequest(request, path: botsPath)
        }
        return await libraryAPI.handle(request)
    }

    /// Two upgrades: a member's live stream (`/v1/stream`), and its WebSocket
    /// to this Mac's bots runtime (`/v1/bots/ws`). Both are held in the member
    /// socket registry, so removing the member closes them.
    private func upgrade(_ request: LibraryHTTPRequest, generation expected: UUID) async -> WebSocketUpgradeDecision {
        guard generation == expected else { return .reject(.error("unavailable", "This sharing session has stopped.", status: 503)) }
        let path = request.target.split(separator: "?", maxSplits: 1).first.map(String.init) ?? request.target
        if path == "/" + StreamProtocol.path || path == "/wovenmatter/" + StreamProtocol.path {
            guard let executionStream else { return .reject(.error("unavailable", "This Mac's stream is starting.", status: 503)) }
            return await executionStream.upgrade(request)
        }
        guard path == "/v1/bots/ws" || path == "/wovenmatter/v1/bots/ws" else {
            return .reject(.error("not_found", "Unknown upgrade route.", status: 404))
        }
        guard authorizeBots != nil, let host = model?.botsHost else { return .reject(.error("unavailable", "Bots on this Mac are starting.", status: 503)) }
        let kinds: Set<MemberKind> = [.mac, .ios]
        let member: LibraryMember
        do {
            guard MemberRequestVerifier.isSigned(request.headers) else { throw MemberRequestError.missing }
            member = try await authenticateMember(request, allowing: kinds)
        } catch { return .reject(.error("unauthorized", error.localizedDescription, status: 401)) }
        let decision = host.remoteUpgrade(request)
        guard case let .tunnel(port, head, options) = decision else { return decision }
        var owned = options
        if let memberSockets { owned.owner = .init(registry: memberSockets, deviceID: member.deviceID, kinds: kinds) }
        return .tunnel(port: port, head: head, options: owned)
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
        let peerSync = peerSync
        Task { await peerSync.stopMembers() }
        server?.stop(); server = nil; executionAPI = nil; inferenceHost = nil; authorizeBots = nil
        executionStream?.stop(); executionStream = nil; memberSockets = nil
        model?.executionStreamChanged = nil
        for setup in linuxHostSetups.values { setup.task.cancel() }
        linuxHostSetups.removeAll()
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
    func revoke(_ deviceID: String, expected: PairedDevice? = nil) async {
        if model?.isBackendFrontend == true { await forward(.revoke(deviceID)); return }
        do { try await performRevocation(deviceID, expected: expected) }
        catch { errorMessage = error.localizedDescription }
    }

    /// Completes only after local library, execution and inference access are
    /// revoked and any unreachable workspace revocation is durably queued.
    /// Test seam: throws before local access is revoked, to prove a failed
    /// revocation is retried rather than recorded as applied.
    @ObservationIgnored var beforeLocalRevocation: (@MainActor (String) throws -> Void)?

    /// `recordsUnpair` is true for a user's unpair on this Mac, which becomes a
    /// signed event; applying another Mac's unpair never mints a new event.
    private func performRevocation(_ deviceID: String, expected: PairedDevice? = nil, recordsUnpair: Bool = true) async throws {
        guard !revokingDeviceIDs.contains(deviceID) else {
            throw LibraryAPIError(code: "revocation_pending", message: "This device is already being unpaired.")
        }
        revokingDeviceIDs.insert(deviceID)
        defer { revokingDeviceIDs.remove(deviceID) }
        do {
            try await loadAuthentication()
            if let expected, await authentication?.isCurrent(expected) != true {
                throw LibraryAPIError(code: "unauthorized", message: "This pairing has already changed.")
            }
            // A user's unpair is a signed event every paired Mac applies. The
            // signing key loads before any side effect: if it is unavailable
            // the unpair fails visibly and the device stays paired for a retry,
            // never revoked only on this Mac.
            let signer: PeerSelf?
            do { signer = recordsUnpair ? try await peerSync.identity() : nil }
            catch {
                throw LibraryAPIError(code: "signing_unavailable",
                    message: "This Mac’s pairing key is unavailable, so nothing was unpaired. Make sure this Mac is unlocked, then try again.")
            }
            // Persist the remote work list before revoking local access. An offline
            // workspace remains explicitly pending until its token is removed.
            if let database = model?.dashboardStore?.database {
                let descriptors = try await database.libraryExecutionWorkspaces()
                var pending = pendingRevocations
                let identity = try await database.libraryIdentity()
                let localID = localExecutionWorkspaceID(libraryID: identity.libraryID)
                let targets = descriptors.filter { $0.kind != .ios && $0.id != localID && $0.libraryID == identity.libraryID && $0.journalDeviceIDs.contains(deviceID) }.map(\.id)
                let workspaceIDs = Array(Set((pending[deviceID] ?? []) + targets)).sorted()
                if workspaceIDs.isEmpty { pending.removeValue(forKey: deviceID) }
                else { pending[deviceID] = workspaceIDs }
                pendingRevocations = pending
                // The device's own access is withdrawn: no in-flight
                // replacement for it may satisfy this cleanup.
                for id in workspaceIDs { replacementWindows[.init(deviceID: deviceID, workspaceID: id)]?.insert("") }
            }
            try beforeLocalRevocation?(deviceID)
            // Every execution and inference grant derived through this device
            // (a paired Mac delegating for its phones) is revoked too. Remote
            // cleanup is queued durably before local state changes; an offline
            // workspace stays pending until it is reachable.
            if let authentication {
                // Provenance is read across suspension points. A replacement
                // committed meanwhile (with other provenance) already removed
                // the token this provenance obtained and retired its record, so
                // its cleanup would only revoke the replacement.
                let issued = remoteIssuances
                let localID = try await model?.dashboardStore?.database.libraryIdentity().libraryID
                for delegation in await authentication.delegations(provisionedBy: deviceID)
                    where localID.map({ delegation.workspaceID != localExecutionWorkspaceID(libraryID: $0) }) ?? true {
                    let target = ExecutionTarget(deviceID: delegation.deviceID, workspaceID: delegation.workspaceID)
                    if let latest = remoteIssuances[target], latest.generation != issued[target]?.generation,
                       latest.provisionedBy != deviceID { continue }
                    enqueueRevocation(deviceID: delegation.deviceID, workspaceID: delegation.workspaceID, provenance: deviceID)
                }
            }
            try await loadExecutionAuthentication().revoke(provisionedBy: deviceID)
            if let signer {
                await authentication?.useIdentity(signer)
                try await authentication?.revoke(deviceID: deviceID, expected: expected)
                try await peerSync.removeMember(deviceID)
                try await queueInstallerRotations(installedBy: deviceID)
            } else {
                try await authentication?.revokeLocally(deviceID: deviceID)
            }
            try await authentication?.removeDelegations(provisionedBy: deviceID)
            try await model?.dashboardStore?.database.withdrawUnpairedMac(deviceID)
            try await loadExecutionAuthentication().revoke(deviceID: deviceID)
            try peerSync.revoke(deviceID)
            pairedDevices = await authentication?.devices() ?? []
            pairingPayload = nil; pairingExpiresAt = nil; lastSeenAt = nil; errorMessage = nil
            try await removeJournalGrants(deviceID: deviceID)
            await retryPendingRevocations()
        }
    }
    /// Linux hosts the removed Mac added hold that Mac's installer bearer;
    /// each is asked to replace it, durably retried until it answers.
    private func queueInstallerRotations(installedBy deviceID: String) async throws {
        guard let database = model?.dashboardStore?.database else { return }
        let hosts = try await database.libraryExecutionWorkspaces()
            .filter { $0.kind == .linux && !$0.deleted && $0.ownerDeviceID == deviceID }.map(\.id)
        guard !hosts.isEmpty else { return }
        pendingInstallerRotations = Array(Set(pendingInstallerRotations + hosts)).sorted()
    }

    private func retryInstallerRotations() async {
        guard let database = model?.dashboardStore?.database, !pendingInstallerRotations.isEmpty else { return }
        let workspaces = (try? await database.libraryExecutionWorkspaces()) ?? []
        for id in pendingInstallerRotations {
            guard let workspace = workspaces.first(where: { $0.id == id }), !workspace.deleted else {
                pendingInstallerRotations.removeAll { $0 == id }; continue
            }
            do {
                try await hostAdministration(for: workspace).rotateInstallerBearer()
                pendingInstallerRotations.removeAll { $0 == id }
            } catch { /* Retained until the host answers. */ }
        }
    }

    private var pendingInstallerRotations: [String] {
        get { defaults.stringArray(forKey: Self.pendingInstallerRotationsKey) ?? [] }
        set { defaults.set(newValue, forKey: Self.pendingInstallerRotationsKey) }
    }

    private var pendingRevocations: [String: [String]] {
        get { defaults.dictionary(forKey: Self.pendingRevocationsKey) as? [String: [String]] ?? [:] }
        set { defaults.set(newValue, forKey: Self.pendingRevocationsKey) }
    }

    /// One device's access on one remote workspace. A remote workspace keeps
    /// one token per device: each issuance replaces the previous token.
    private struct ExecutionTarget: Hashable { let deviceID: String; let workspaceID: String }
    /// The latest committed remote issuance per target, in commit order.
    private var remoteIssuances: [ExecutionTarget: (generation: Int, provisionedBy: String?)] = [:]
    private var remoteIssuanceGeneration = 0
    /// Cleanup queued while a replacement for the same target is in flight,
    /// keyed by the provenance being removed ("" for the device's own access).
    /// Only a committed replacement with other provenance supersedes it.
    private var replacementWindows: [ExecutionTarget: Set<String>] = [:]

    /// Test seam: stands in for remote workspace enrollment and device removal,
    /// keyed by workspace and device ID, so ordering is testable offline.
    struct RemoteExecutionRequests {
        var issue: @MainActor (_ workspaceID: String, _ deviceID: String) async throws -> ExecutionCredential
        var revoke: @MainActor (_ workspaceID: String, _ deviceID: String) async throws -> Void
    }
    @ObservationIgnored var remoteExecutionRequests: RemoteExecutionRequests?
    /// Test seam: carries signed requests to Linux hosts in process.
    @ObservationIgnored var remoteHostSend: MemberSignedHTTPClient.Send?

    func localExecutionWorkspaceID(libraryID: String) -> String {
        let key = Self.localExecutionIDKeyPrefix + libraryID
        if let value = defaults.string(forKey: key), UUID(uuidString: value) != nil { return value.lowercased() }
        let value = UUID().uuidString.lowercased(); defaults.set(value, forKey: key); return value
    }

    /// A Dev snapshot retires the execution owners it copied from its source.
    /// Test seam: fixtures exercise snapshot registry rules without a Dev bundle.
    @ObservationIgnored var retiresCopiedExecutionOwners = DevelopmentLaunch.isSnapshot

    /// Registry changes do not open connections, start containers, or move workspace files.
    func refreshExecutionRegistry() async throws {
        guard !registryRefreshInProgress, let model, let database = model.dashboardStore?.database else { return }
        registryRefreshInProgress = true
        let expectedGeneration = generation
        defer { registryRefreshInProgress = false }
        let identity = try await database.libraryIdentity()
        try await database.savePairedRemoteWorkspaces(model.remoteWorkspaces.workspaces)
        let existing = try await database.libraryExecutionWorkspaces()
        let localID = localExecutionWorkspaceID(libraryID: identity.libraryID)
        // Local folders are bound to `device:<dashboard device id>`, which is
        // neither `localID` nor the host device ID; naming it lets paired
        // devices group existing folders under this Mac without rewriting them.
        let folderOwnerID = (try? await model.executionWorkspaceIdentity(workspaceID: nil))
            .flatMap { ExecutionWorkspace.isValidFolderOwnerID($0) ? $0 : nil }
        if retiresCopiedExecutionOwners {
            // Upgrade existing snapshots too. New paired owners remain live; copied
            // owners retain their identity for history without becoming connections.
            // Only this library's own namespace is registered here. A paired
            // Mac's workspace keeps its own namespace and owner, and arrives
            // through synchronization before that Mac holds any grant here.
            let connected = await authentication?.devices() ?? []
            let paired = Set(connected.map(\.id))
            for var copied in existing where !copied.deleted && copied.retainedHistory != true && copied.libraryID == identity.libraryID
                && copied.id != localID && copied.ownerDeviceID != identity.hostDeviceID && !paired.contains(copied.ownerDeviceID) {
                guard generation == expectedGeneration, !Task.isCancelled else { return }
                copied.retainedHistory = true; copied.endpoint = nil
                _ = try await database.registerExecutionWorkspace(.init(workspace: copied, expectedRevision: copied.revision), deviceID: identity.hostDeviceID)
            }
        }
        var desired: [ExecutionWorkspace] = [
            .init(id: localID, libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
                  kind: .mac, name: DevelopmentLaunch.deviceName(), endpoint: endpoint,
                  capabilities: ["execution.v1", "history.central.v1", "inference.v1", StreamProtocol.capability], executionDeviceID: identity.hostDeviceID, developmentInstance: DevelopmentLaunch.instance,
                  // Paired devices show sessions here a clear message when a permission is missing.
                  macAccess: MacAccessSetupModel.current(keychainReady: model.keychainAccessReady),
                  folderOwnerID: folderOwnerID)
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
            _ = try await database.registerExecutionWorkspace(
                .init(workspace: workspace, expectedRevision: prior?.revision), deviceID: identity.hostDeviceID)
        }
        guard generation == expectedGeneration, !Task.isCancelled else { return }
        let previous = executionWorkspaces
        executionWorkspaces = try await database.libraryExecutionWorkspaces()
        if executionWorkspaces != previous { await connectExecutionStreams() }
        for configuration in model.remoteWorkspaces.workspaces {
            // Adoption and enrollment do not wait for an earlier enrollment.
            setUpLinuxHost(configuration)
            if let workspace = executionWorkspaces.first(where: { $0.id == configuration.id.uuidString.lowercased() }),
               workspace.kind == .linux, workspace.executionDeviceID != nil, !workspace.deleted {
                try? await ensureExecutionToolSettings(workspace: workspace, configuration: configuration)
            }
        }
    }

    /// Sets up a Linux host this Mac manages: adopts it (this Mac becomes its
    /// anchor and signs its member entry, `ensureLinuxMember`), then exposes and
    /// enrolls its workspace (`provisionCentralExecutionWorkspace`, which sets
    /// the registry row's endpoint and `executionDeviceID`). It starts as soon
    /// as the host is installed or gains its workspace (`restart`), and on each
    /// launch, and retries with backoff until both steps succeed. A bots-only
    /// host is only adopted.
    func setUpLinuxHost(_ configuration: RemoteWorkspaceConfiguration, restart: Bool = false) {
        guard let model, !model.isBackendFrontend, linuxHostSetupSteps != nil || !PairedMacDeviceStorage.isTestProcess else { return }
        let id = configuration.id.uuidString.lowercased()
        if restart {
            readyLinuxHosts.remove(id)
            linuxHostSetups.removeValue(forKey: id)?.task.cancel()
        }
        guard !readyLinuxHosts.contains(id), linuxHostSetups[id] == nil else { return }
        let token = UUID(), expectedGeneration = generation, workspaceID = configuration.id
        let task = Task { [weak self] in
            var delay = self?.linuxHostSetupRetry ?? .seconds(5)
            while !Task.isCancelled,
                  let done = await self?.attemptLinuxHostSetup(workspaceID, generation: expectedGeneration), !done {
                try? await Task.sleep(for: delay)
                delay = min(delay * 2, .seconds(600))
            }
            if self?.linuxHostSetups[id]?.id == token { self?.linuxHostSetups.removeValue(forKey: id) }
        }
        linuxHostSetups[id] = (token, task)
    }

    /// True once the host is set up, false to retry, nil when the host was
    /// removed or this Mac's service restarted (which sets it up again).
    private func attemptLinuxHostSetup(_ workspaceID: UUID, generation expected: UUID) async -> Bool? {
        guard generation == expected, let configuration = model?.remoteWorkspaces.configuration(id: workspaceID) else { return nil }
        do {
            try await completeLinuxHostSetup(configuration)
            guard generation == expected, !Task.isCancelled else { return nil }
            readyLinuxHosts.insert(workspaceID.uuidString.lowercased())
            return true
        } catch {
            NSLog("Setup of Linux host %@ is pending: %@", configuration.name, error.localizedDescription)
            return false
        }
    }

    /// One attempt at each step that has not succeeded; the first failure is rethrown.
    private func completeLinuxHostSetup(_ configuration: RemoteWorkspaceConfiguration) async throws {
        let steps = linuxHostSetupSteps ?? .init(adopt: { [weak self] in try await self?.ensureLinuxMember(configuration: $0) },
                                                 enroll: { [weak self] in _ = try await self?.provisionCentralExecutionWorkspace(id: $0) })
        var failure: (any Error)?
        do { try await steps.adopt(configuration) } catch { failure = error }
        if configuration.workspaceID != RemoteHostInstallMode.botsOnlyWorkspaceID {
            let id = configuration.id.uuidString.lowercased()
            let registered = try await model?.dashboardStore?.database.libraryExecutionWorkspaces().first { $0.id == id && !$0.deleted }
            if registered?.endpoint == nil || registered?.executionDeviceID == nil {
                do { try await steps.enroll(id) } catch { failure = failure ?? error }
            }
        }
        if let failure { throw failure }
    }

    func provisionExecutionWorkspace(id: String, device: PairedDevice) async throws -> ExecutionCredential {
        // Any queued device-only cleanup for this workspace drains before issuance
        // (provisionExecution completes pending revocations first). Only after the
        // direct grant is issued, replacing any delegated one, is stale
        // delegated provenance retired, still under the workspace guard.
        try await provisionExecution(id: id, deviceID: device.id, name: device.name, provisionedBy: nil, current: { [weak self] in
            await self?.authentication?.isCurrent(device) == true
        }, commit: { [weak self] in
            try await self?.authentication?.retireDelegations(deviceID: device.id, workspaceID: id)
        })
    }

    /// A paired Mac obtains this Mac's execution access for one of its own
    /// mobile devices. Provenance is recorded first: when that Mac is unpaired
    /// every grant derived through it is revoked, while this Mac's own grants
    /// for the same device remain.
    func provisionDelegatedExecution(id: String, deviceID: String, name: String, provisionedBy: String) async throws -> ExecutionCredential {
        guard let authentication = try? await peerAuthentication(), await authentication.mayDelegate(for: deviceID) else {
            throw LibraryAPIError(code: "unauthorized", message: "Only a paired Mac's own mobile device may receive this delegated grant.")
        }
        // Stage the request; earlier provenance for this device and workspace is
        // retired only once the replacement grant is actually issued.
        guard !revokingDeviceIDs.contains(provisionedBy) else {
            throw LibraryAPIError(code: "unauthorized", message: "The provisioning Mac is being unpaired.")
        }
        try await authentication.stageDelegation(deviceID: deviceID, workspaceID: id, provisionedBy: provisionedBy)
        do {
            // An unpair of the provisioning Mac may have read its delegations
            // before this one was staged, so any unpair in progress fails it.
            return try await provisionExecution(id: id, deviceID: deviceID, name: name, provisionedBy: provisionedBy, current: { [weak self] in
                guard self?.revokingDeviceIDs.contains(provisionedBy) == false else { return false }
                return await authentication.delegationActive(deviceID: deviceID, provisionedBy: provisionedBy)
            }, commit: {
                try await authentication.confirmDelegation(deviceID: deviceID, workspaceID: id, provisionedBy: provisionedBy)
            })
        } catch {
            try? await authentication.cancelStagedDelegation(deviceID: deviceID, workspaceID: id, provisionedBy: provisionedBy)
            throw error
        }
    }

    /// `commit` records the issued grant's provenance while the workspace guard
    /// is still held, so no unpair can read the provenance it replaces.
    private func provisionExecution(id: String, deviceID: String, name: String, provisionedBy: String?,
                                    current: @escaping @MainActor () async -> Bool,
                                    commit: @MainActor () async throws -> Void) async throws -> ExecutionCredential {
        guard UUID(uuidString: id) != nil, let model, let database = model.dashboardStore?.database,
              authentication != nil, try await deviceMayExecute(deviceID, workspaceID: id, current: current),
              !revokingDeviceIDs.contains(deviceID), !provisioningWorkspaceIDs.contains(id) else {
            throw LibraryAPIError(code: "unavailable", message: "This workspace is unavailable or another enrollment is in progress. Retry shortly.")
        }
        provisioningWorkspaceIDs.insert(id)
        defer { provisioningWorkspaceIDs.remove(id) }
        let identity = try await database.libraryIdentity()
        if let workspace = try await database.libraryExecutionWorkspaces().first(where: { $0.id == id && !$0.deleted }), workspace.libraryID != identity.libraryID {
            // A Linux host issues its own grants to any Mac member; only a
            // paired Mac's own workspace is asked through that Mac.
            let credential = workspace.kind == .linux && workspace.endpoint != nil
                ? try await provisionAtLinuxHost(workspace, deviceID: deviceID, name: name)
                : try await peerSync.provision(workspace: workspace, deviceID: deviceID)
            try await commit()
            return credential
        }
        if id == localExecutionWorkspaceID(libraryID: identity.libraryID) {
            guard let executionAPI else { throw LibraryAPIError(code: "unavailable", message: "This Mac’s workspace connection is not ready yet.") }
            let expectedGeneration = generation
            let credential = try await executionAPI.provision(deviceID: deviceID, provisionedBy: provisionedBy)
            guard generation == expectedGeneration, endpoint != nil,
                  try await deviceMayExecute(deviceID, workspaceID: id, current: current), !revokingDeviceIDs.contains(deviceID) else {
                try await loadExecutionAuthentication().revoke(deviceID: deviceID)
                throw LibraryAPIError(code: "unauthorized", message: "This device or sharing session was revoked during enrollment.")
            }
            try await commit()
            return credential
        }
        // Cleanup queued from here on, while the replacement is in flight, is
        // recorded with the provenance it removes.
        let target = ExecutionTarget(deviceID: deviceID, workspaceID: id)
        replacementWindows[target] = []
        defer { replacementWindows.removeValue(forKey: target) }
        try await completePendingRevocation(workspaceID: id, deviceID: deviceID)
        guard try await deviceMayExecute(deviceID, workspaceID: id, current: current), !revokingDeviceIDs.contains(deviceID) else {
            throw LibraryAPIError(code: "unauthorized", message: "This device was revoked during enrollment.")
        }
        let configuration = model.remoteWorkspaces.workspaces.first(where: { $0.id.uuidString.lowercased() == id })
        let registered = try await database.libraryExecutionWorkspaces().first { $0.id == id && !$0.deleted }
        var credential: ExecutionCredential
        if let remoteExecutionRequests {
            credential = try await remoteExecutionRequests.issue(id, deviceID)
        } else if let configuration {
            credential = try await model.remoteWorkspaces.provisionExecutionDevice(configuration: configuration,
                libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID, deviceID: deviceID, deviceName: name)
        } else if let registered, registered.kind == .linux, registered.endpoint != nil {
            credential = try await provisionAtLinuxHost(registered, deviceID: deviceID, name: name)
        } else {
            throw LibraryAPIError(code: "unknown_workspace", message: "This workspace's address has not reached this Mac yet. Retry after the devices synchronize.")
        }
        do {
            guard credential.deviceID == deviceID, credential.workspace.id == id,
                  credential.workspace.libraryID == identity.libraryID,
                  registered.map({ original in
                      original.ownerDeviceID == credential.workspace.ownerDeviceID && original.kind == credential.workspace.kind
                          && (original.kind != .mac || original.endpoint == credential.workspace.endpoint)
                          && (original.executionDeviceID == nil || original.executionDeviceID == credential.workspace.executionDeviceID)
                  }) ?? (configuration != nil) else {
                throw LibraryAPIError(code: "wrong_workspace", message: "The workspace returned an execution grant for a different identity.")
            }
            guard try await deviceMayExecute(deviceID, workspaceID: id, current: current), !revokingDeviceIDs.contains(deviceID) else {
                throw LibraryAPIError(code: "unauthorized", message: "This device was revoked during enrollment.")
            }
            let prior = try await database.libraryExecutionWorkspaces().first { $0.id == id }
            credential.workspace.journalDeviceIDs = Array(Set((prior?.journalDeviceIDs ?? []) + [deviceID])).sorted()
            credential.workspace.revision = prior?.revision ?? 0
            credential.workspace = try await database.registerExecutionWorkspace(
                .init(workspace: credential.workspace, expectedRevision: prior?.revision), deviceID: identity.hostDeviceID)
            guard try await deviceMayExecute(deviceID, workspaceID: id, current: current), !revokingDeviceIDs.contains(deviceID) else {
                try await removeJournalGrants(deviceID: deviceID)
                throw LibraryAPIError(code: "unauthorized", message: "This device was revoked during enrollment.")
            }
            if let configuration { try? await ensureExecutionToolSettings(workspace: credential.workspace, configuration: configuration) }
            guard try await deviceMayExecute(deviceID, workspaceID: id, current: current) else {
                throw LibraryAPIError(code: "unauthorized", message: "This device's execution access changed during enrollment.")
            }
            try await commit()
            // Committed: the workspace replaced the device's earlier token, so
            // cleanup queued meanwhile for other provenance is already satisfied.
            // The device's own revocation, or this provenance's, still applies.
            remoteIssuanceGeneration += 1
            remoteIssuances[target] = (remoteIssuanceGeneration, provisionedBy)
            if let superseded = replacementWindows[target], !superseded.isEmpty, !superseded.contains(provisionedBy ?? "") {
                var pending = pendingRevocations
                pending[deviceID]?.removeAll { $0 == id }
                if pending[deviceID]?.isEmpty == true { pending.removeValue(forKey: deviceID) }
                pendingRevocations = pending
                pendingDeviceRevocations = pending
            }
            return credential
        } catch {
            enqueueRevocation(deviceID: deviceID, workspaceID: id)
            await retryPendingRevocations()
            throw error
        }
    }

    /// Enrolls a Linux host this Mac added (`setUpLinuxHost`): exposes its
    /// execution API and registers the row's endpoint and `executionDeviceID`.
    /// Every member then reaches it with signed requests. Never exposed as a
    /// client HTTP route.
    func provisionCentralExecutionWorkspace(id: String) async throws -> ExecutionCredential {
        guard let model, !model.isBackendFrontend,
              let database = model.dashboardStore?.database, UUID(uuidString: id) != nil,
              !provisioningWorkspaceIDs.contains(id) else {
            throw LibraryAPIError(code: "unavailable", message: "This Mac’s execution owner is unavailable.")
        }
        provisioningWorkspaceIDs.insert(id)
        defer { provisioningWorkspaceIDs.remove(id) }
        let identity = try await database.libraryIdentity()
        let registered = try await database.libraryExecutionWorkspaces().first { $0.id == id && !$0.deleted }
        // Copied history is never enrolled.
        if let registered, registered.retainedHistory == true {
            throw LibraryAPIError(code: "unavailable", message: "\(registered.name) is retained history here and runs no work.")
        }
        guard let configuration = model.remoteWorkspaces.workspaces.first(where: { $0.id.uuidString.lowercased() == id }) else {
            throw LibraryAPIError(code: "unavailable", message: "Only the Mac that added this Linux host enrolls its workspace.")
        }
        try await completePendingRevocation(workspaceID: id, deviceID: identity.hostDeviceID)
        var credential = try await model.remoteWorkspaces.provisionExecutionDevice(configuration: configuration,
            libraryID: identity.libraryID, ownerDeviceID: identity.hostDeviceID,
            deviceID: identity.hostDeviceID, deviceName: Host.current().localizedName ?? "Mac")
        guard credential.deviceID == identity.hostDeviceID, credential.workspace.id == id,
              credential.workspace.libraryID == identity.libraryID,
              registered.map({ original in
                  original.ownerDeviceID == credential.workspace.ownerDeviceID && original.kind == credential.workspace.kind
                      && (original.kind != .mac || original.endpoint == credential.workspace.endpoint)
                      && (original.executionDeviceID == nil || original.executionDeviceID == credential.workspace.executionDeviceID)
              }) ?? true else {
            throw LibraryAPIError(code: "wrong_workspace", message: "The execution workspace returned a different identity.")
        }
        let prior = try await database.libraryExecutionWorkspaces().first { $0.id == id }
        credential.workspace.journalDeviceIDs = Array(Set((prior?.journalDeviceIDs ?? []) + [identity.hostDeviceID])).sorted()
        credential.workspace.revision = prior?.revision ?? 0
        credential.workspace = try await database.registerExecutionWorkspace(
            .init(workspace: credential.workspace, expectedRevision: prior?.revision), deviceID: identity.hostDeviceID)
        if let configuration = model.remoteWorkspaces.workspaces.first(where: { $0.id.uuidString.lowercased() == id }) {
            try? await ensureExecutionToolSettings(workspace: credential.workspace, configuration: configuration)
        }
        return credential
    }

    private func deviceMayExecute(_ deviceID: String, workspaceID: String, current: @MainActor () async -> Bool) async throws -> Bool {
        guard authentication != nil, let database = model?.dashboardStore?.database,
              !revokingDeviceIDs.contains(deviceID), await current() else { return false }
        guard try await database.libraryExecutionWorkspaces().contains(where: { $0.id == workspaceID && !$0.deleted }) else { return false }
        return await current()
    }

    func withdrawDevelopmentWorkspace() async throws {
        guard DevelopmentLaunch.mode != nil, let database = model?.dashboardStore?.database else { return }
        stop() // Cancel recovery as well as periodic registrations before withdrawal.
        do {
            let identity = try await database.libraryIdentity()
            let id = localExecutionWorkspaceID(libraryID: identity.libraryID)
            if var workspace = try await database.libraryExecutionWorkspaces().first(where: { $0.id == id && !$0.deleted }) {
                workspace.endpoint = nil
                _ = try await database.registerExecutionWorkspace(.init(workspace: workspace, expectedRevision: workspace.revision), deviceID: identity.hostDeviceID)
            }
        } catch {
            await startForCentralDatabase()
            throw error
        }
    }

    private func refreshStatusAndDevelopmentPresence(database: WorkspaceDatabase) async throws {
        pairedDevices = await authentication?.devices() ?? []
        let active = Set(pairedDevices.map(\.id))
        executionWorkspaces = try await database.libraryConnectionWorkspaces(activeDeviceIDs: active)
    }

    /// `provenance` names the Mac whose delegated grant is being removed; nil
    /// withdraws the device's access on that workspace regardless of origin.
    private func enqueueRevocation(deviceID: String, workspaceID: String, provenance: String? = nil) {
        replacementWindows[.init(deviceID: deviceID, workspaceID: workspaceID)]?.insert(provenance ?? "")
        var pending = pendingRevocations
        pending[deviceID] = Array(Set((pending[deviceID] ?? []) + [workspaceID])).sorted()
        pendingRevocations = pending
        pendingDeviceRevocations = pending
    }

    private func removeJournalGrants(deviceID: String) async throws {
        guard let database = model?.dashboardStore?.database else { return }
        let identity = try await database.libraryIdentity()
        for var workspace in try await database.libraryExecutionWorkspaces() where !workspace.deleted && workspace.libraryID == identity.libraryID && workspace.journalDeviceIDs.contains(deviceID) {
            let revision = workspace.revision
            workspace.journalDeviceIDs.removeAll { $0 == deviceID }
            _ = try await database.registerExecutionWorkspace(.init(workspace: workspace, expectedRevision: revision), deviceID: identity.hostDeviceID)
        }
    }

    /// Called only while holding the workspace operation guard. A replacement
    /// enrollment cannot race an old revocation or inherit its pending entry.
    private func completePendingRevocation(workspaceID: String, deviceID: String) async throws {
        guard pendingRevocations[deviceID]?.contains(workspaceID) == true, let model else { return }
        if let remoteExecutionRequests {
            try await remoteExecutionRequests.revoke(workspaceID, deviceID)
        } else if let configuration = model.remoteWorkspaces.workspaces.first(where: { $0.id.uuidString.lowercased() == workspaceID }) {
            try await model.remoteWorkspaces.revokeExecutionDevice(configuration: configuration, deviceID: deviceID)
        } else {
            throw LibraryAPIError(code: "revocation_pending", message: "Reconnect this workspace before enrolling this device again.")
        }
        var pending = pendingRevocations
        pending[deviceID]?.removeAll { $0 == workspaceID }
        if pending[deviceID]?.isEmpty == true { pending.removeValue(forKey: deviceID) }
        pendingRevocations = pending
    }

    func retryPendingRevocations() async {
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
        await retryInstallerRotations()
        let pendingMessage = "Device access changes are pending on workspaces that have not reconnected yet."
        if !pendingRevocations.isEmpty || !pendingInstallerRotations.isEmpty { errorMessage = pendingMessage }
        else if errorMessage == pendingMessage { errorMessage = nil }
    }

    var snapshot: LibraryHostSnapshot {
        .init(isEnabled: isEnabled, isStarting: isStarting, endpoint: endpoint, status: status,
              errorMessage: errorMessage, pairingPayload: pairingPayload, pairingExpiresAt: pairingExpiresAt,
              pairedDevices: pairedDevices, lastSeenAt: lastSeenAt, discoveredPeers: discoveredPeers,
              pendingPairingRequests: pendingPairingRequests, isDiscovering: isDiscovering, executionWorkspaces: executionWorkspaces,
              pendingDeviceRevocations: pendingRevocations, peerPairingStatus: peerSync.pairing.status, peerPairingError: peerSync.pairing.errorMessage, peerSyncErrors: peerSync.errors, peerRoutes: peerSync.routes, peerIdentity: discoveryIdentity,
              librarySync: peerSync.syncStatus)
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
            try await authentication.approvePairing(id: id, workspaceID: database.libraryID())
            await refreshStatus(); errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
    func denyPairing(id: String) async {
        if model?.isBackendFrontend == true { await forward(.denyPairing(id)); return }
        do { try await authentication?.denyPairing(id: id); await refreshStatus() }
        catch { errorMessage = error.localizedDescription }
    }
    private func forward(_ action: LibraryHostAction) async {
        guard let model else { return }
        do {
            guard let value = try await model.sendBackendCommand(.libraryHost(action)).libraryHost else { return }
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

    func peerAuthentication() async throws -> DeviceAuthentication {
        try await loadAuthentication()
        guard let authentication else { throw CancellationError() }
        return authentication
    }
    func peerRoute() async throws -> PairedMacRoute {
        guard let endpoint, let database = model?.dashboardStore?.database else { throw LibraryAPIError(code: "unavailable", message: "Wait for this Mac to connect to Tailscale before pairing.") }
        let identity = try await database.libraryIdentity()
        return .init(deviceID: identity.hostDeviceID, libraryID: identity.libraryID, endpoint: endpoint, name: DevelopmentLaunch.deviceName())
    }
    func pairWithPeer(_ peer: DiscoveredPeer) async {
        if model?.isBackendFrontend == true { await forward(.pairWithPeer(peer)); return }
        guard peer.advertisement.identity.deviceID != discoveryIdentity?.deviceID else { return }
        await peerSync.pairing.requestPairing(with: peer)
    }
    func pairAtEndpoint(_ endpoint: URL) async {
        if model?.isBackendFrontend == true { await forward(.pairAtEndpoint(endpoint)); return }
        do {
            let advertisement: DiscoveryAdvertisement = try await pairingNetwork.request(endpoint, path: "v1/discovery")
            guard advertisement.capabilities?.contains(PairedMacSyncController.capability) == true else { throw LibraryAPIError(code: "update_required", message: "Update both Macs before pairing their libraries.") }
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
    /// A member removal learned from a peer: withdraw this Mac's own grants
    /// and routes for that device without minting another removal.
    func applyMemberRemoval(_ deviceID: String) async {
        guard deviceID != discoveryIdentity?.deviceID else { return }
        do { try await performRevocation(deviceID, recordsUnpair: false) }
        catch { errorMessage = error.localizedDescription }
    }

    /// Verifies a signed member request for any route this Mac serves (for
    /// example the bots WebSocket upgrade) and returns the member.
    func authenticateMember(_ request: LibraryHTTPRequest, allowing kinds: Set<MemberKind> = Set(MemberKind.allCases)) async throws -> LibraryMember {
        try await peerSync.members().authenticate(request, allowing: kinds)
    }

    func applyPeerRevocations() async throws {
        guard let authentication else { return }
        var processed = Set(defaults.stringArray(forKey: Self.appliedPeerRevocationsKey) ?? [])
        var failure: (any Error)?
        for (id, events) in await authentication.revokedDeviceContexts().sorted(by: { $0.key < $1.key }) {
            let key = id + ":" + events.joined(separator: ",")
            guard !processed.contains(key) else { continue }
            // Mark applied only after local access is revoked; a transient
            // failure is retried on the next synchronization turn.
            do { try await performRevocation(id, recordsUnpair: false); processed.insert(key) } catch { failure = error }
            defaults.set(Array(processed).sorted(), forKey: Self.appliedPeerRevocationsKey)
        }
        pairedDevices = await authentication.devices()
        if let failure { throw failure }
    }

    private func loadExecutionAuthentication() throws -> ExecutionAuthentication {
        if let executionAuthentication { return executionAuthentication }
        let file = try (supportDirectory ?? ApplicationModel.dashboardSupportDirectory()).appending(path: "execution-devices.json")
        let value = try ExecutionAuthentication(fileURL: file)
        executionAuthentication = value
        return value
    }

    private func loadAuthentication() async throws {
        if authentication == nil {
            let file = try (supportDirectory ?? ApplicationModel.dashboardSupportDirectory()).appendingPathComponent(DeviceAuthentication.fileName)
            authentication = try DeviceAuthentication(fileURL: file)
        }
        pairedDevices = await authentication?.devices() ?? []
    }

    private func didPair() async {
        pairedDevices = await authentication?.devices() ?? []
        pairingPayload = nil; pairingExpiresAt = nil
    }

    /// Opens a stream to every registered workspace that serves one and closes
    /// those that left the registry: on start, and whenever the registry or the
    /// member list changes (this Mac's registry refresh, a peer sync that
    /// applied rows). Each stream reconnects by itself; nothing polls.
    func connectExecutionStreams() async {
        guard let model, !model.isBackendFrontend, let client = try? model.centralExecutionClient() else { return }
        await client.connectRegisteredWorkspaces()
    }
}

// Settings is a projection. Only the background execution owner opens the HTTP
// listener, holds pairing secrets, and owns the Tailscale Serve child.
enum LibraryHostAction: Codable, Sendable {
    case status, start, stop, createCode
    case revoke(String), approvePairing(String), denyPairing(String)
    case discover, pairWithPeer(DiscoveredPeer), pairAtEndpoint(URL), pairUsingLink(String), cancelPeerPairing
}

struct LibraryHostSnapshot: Codable, Sendable {
    let isEnabled: Bool
    let isStarting: Bool
    let endpoint: URL?
    let status: String
    let errorMessage: String?
    let pairingPayload: PairingPayload?
    let pairingExpiresAt: Date?
    let pairedDevices: [PairedDevice]
    let lastSeenAt: Date?
    let discoveredPeers: [DiscoveredPeer]
    let pendingPairingRequests: [PendingPairingRequest]
    let isDiscovering: Bool
    let executionWorkspaces: [ExecutionWorkspace]
    let pendingDeviceRevocations: [String: [String]]
    var peerPairingStatus: String? = nil
    var peerPairingError: String? = nil
    var peerSyncErrors: [String: String]? = nil
    var peerRoutes: [PairedMacRoute]? = nil
    var peerIdentity: PairingDeviceIdentity? = nil
    /// Every peer's synchronization state, including "update required".
    var librarySync: LibrarySyncStatus? = nil
}
