import AppKit
import CryptoKit
import LibraryClient
import Foundation
import Observation
import WovenMatterShared
import WovenMatterCore
import WovenMatterDashboardStore

/// A Dev client build owns a replica, never another copy of the authoritative database.
/// The portable store journals edits and command identities before network submission.
@MainActor @Observable
final class CentralLibraryClientModel {
    let analytics = MobileAnalyticsModel()
    private(set) var state = MobileStoreState()
    private(set) var credential: MobileCredential?
    private(set) var online = false
    private(set) var synchronization = MobileSynchronizationStatus()
    private var nextCentralRefresh = Date.distantPast
    private var centralFailures = 0
    private var nextDirectRefresh: [String: Date] = [:]
    private var directFailures: [String: Int] = [:]
    private(set) var refreshing = false
    private(set) var initialized = false
    var errorMessage: String?
    var status = "Not connected"
    var selectedConversationID: String?
    var selectedExecutionWorkspaceID = "central"
    private(set) var journal = WorkspaceJournalState()
    private(set) var directOnline: Set<String> = []
    private(set) var artifacts: [LibraryArtifactManifest] = []
    private var directClients: [String: WorkspaceClient] = [:]
    /// Workspaces whose direct grant was rejected and not yet replaced. The IDs
    /// (no secrets) persist across launches, bound to this library and device,
    /// bounded by the registered workspaces, and are retried on each reachable
    /// central refresh.
    private struct PendingReenrollment: Codable, Equatable {
        var libraryID: String; var deviceID: String; var workspaceIDs: [String]
    }
    private static let pendingReenrollmentLimit = 64
    private var pendingReenrollmentURL: URL { executionDirectory.appending(path: "pending-direct-enrollment.json") }
    private var pendingReenrollment: Set<String> {
        get {
            // Before the replica's binding is known, nothing is applied or discarded.
            guard state.workspaceID != nil, let data = try? Data(contentsOf: pendingReenrollmentURL) else { return [] }
            guard let saved = try? JSONDecoder().decode(PendingReenrollment.self, from: data),
                  saved.libraryID == state.workspaceID, saved.deviceID == state.deviceID else {
                // Another library's or device's intent is never applied here.
                try? FileManager.default.removeItem(at: pendingReenrollmentURL); return []
            }
            return Set(saved.workspaceIDs.prefix(Self.pendingReenrollmentLimit))
        }
        set {
            let ids = Array(newValue.sorted().prefix(Self.pendingReenrollmentLimit))
            guard !ids.isEmpty, let libraryID = state.workspaceID else {
                try? FileManager.default.removeItem(at: pendingReenrollmentURL); return
            }
            let value = PendingReenrollment(libraryID: libraryID, deviceID: state.deviceID, workspaceIDs: ids)
            guard (try? Data(contentsOf: pendingReenrollmentURL)).flatMap({ try? JSONDecoder().decode(PendingReenrollment.self, from: $0) }) != value else { return }
            do {
                try FileManager.default.createDirectory(at: executionDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(value).write(to: pendingReenrollmentURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch { deviceConnectionsError = error.localizedDescription }
        }
    }
    private(set) var localExecution: SecondaryMacExecutionWorkspace?
    private(set) var localExecutionBusy = false
    private(set) var sharingLocalExecution = false
    private var localHost: SecondaryMacExecutionHost?
    private let makeLocalHost: @MainActor (SecondaryMacExecutionWorkspace, URL) -> SecondaryMacExecutionHost
    private var executionPreparedForTransition = false
    private var publishedManagement: ExecutionManagementGrant?
    private(set) var draftNotes: [String: LibraryNote] = [:]
    private var writeTask: Task<Void, Never>?
    private var writeFailures: [String: String] = [:]
    private var noteWriteVersions: [String: Int] = [:]
    private var requiresLocalExecution = false
    private var connectionGeneration = UUID()
    private let makeLocalExecution: @MainActor (URL, MobileStore) async throws -> SecondaryMacExecutionWorkspace
    private let clearWorkspaceCredential: @MainActor (String) throws -> Void
    private let enrollWorkspace: (@MainActor (String) async throws -> DirectWorkspaceCredential)?
    private let saveWorkspaceCredential: @MainActor (DirectWorkspaceCredential) throws -> Void
    private let makeWorkspaceTransport: @MainActor (DirectWorkspaceCredential) throws -> any ExecutionWorkspaceTransport
    private let executionDirectoryOverride: URL?
    var deviceConnectionsError: String?
    @ObservationIgnored private var initializationTask: Task<Void, Never>?
    private var nextLocalSharingAttempt = Date.distantPast
    private var nextDevelopmentConnection = Date.distantPast
    private var connectingDevelopment = false
    private var running = false
    private(set) var preparingTransition = false
    private(set) var localSharingBusy = false
    private let store: MobileStore?
    private var engine: MobileSyncEngine?
    private var transport: HTTPSLibraryTransport?

    // MARK: Live host stream (client mode)

    /// Opens a client-mode build's stream to its live host for one credential
    /// (nil: none, as in every other build). Its connector admits the Dev
    /// stream key on the same-user socket before each attempt and records the
    /// route there in `route`.
    typealias LiveStreamFactory = @MainActor (_ credential: MobileCredential?, _ deviceID: String,
                                              _ route: DevelopmentLiveStream.Route) -> StreamConnection?
    private let makeLiveStream: LiveStreamFactory
    @ObservationIgnored private var liveStream: DevelopmentLiveStream?
    /// The credential the stream was opened for; a new pairing opens a new one.
    private var liveStreamCredential: String?
    /// While the live host's stream is open nothing here runs on a timer:
    /// `library` items start library sync, and the open chats stream.
    private(set) var liveStreamOpen = false
    private(set) var liveStreamProblem: String?
    /// Chats this server's windows hold open (`followConversation`).
    private(set) var followedConversationIDs: Set<String> = []
    private var livePending: [PendingInteraction] = []
    private var liveTranscripts: [String: LibraryTranscript] = [:]
    private var liveCapabilities: [String: HarnessCapabilities] = [:]
    private var liveSessions: [String: SessionSettings] = [:]
    /// Chats the live host does not serve live; read once instead.
    private var liveEnded: Set<String> = []
    private var liveReloadScheduled = false
    /// Tells the windows that follow these relayed chats to read them again.
    var liveRelayChanged: ((Set<String>) -> Void)?
    /// A `library` item, a stream that opened or a local change asks for one library pass.
    private var centralSyncRequested = false
    /// The fallback library timer, only while no live host stream is open (an
    /// older host without `development.stream`, or the host unreachable).
    static let fallbackCentralInterval: TimeInterval = 15
    static let fallbackActiveCentralInterval: TimeInterval = 2
    /// This Mac's own Tailscale Serve child is checked this often while shared (no reads).
    static let localSharingCheckInterval: TimeInterval = 30
    private var nextLocalSharingCheck = Date.distantFuture
    /// This Mac's execution database tells us when its sessions or library
    /// changed; its history is captured at most this often while they change.
    static let localCaptureInterval: TimeInterval = 1
    private var lastLocalCapture = Date.distantPast
    @ObservationIgnored private var localObservers: (database: WorkspaceDatabase, ids: [UUID])?
    @ObservationIgnored private var wakeContinuation: CheckedContinuation<Void, Never>?
    @ObservationIgnored private var wakeTimer: Task<Void, Never>?
    @ObservationIgnored private var wakeRequested = false

    init(store: MobileStore? = nil, transport: (any LibraryTransport)? = nil,
         assets: WorkspaceAssetSession? = nil,
         executionDirectory: URL? = nil,
         makeLocalExecution: (@MainActor (URL, MobileStore) async throws -> SecondaryMacExecutionWorkspace)? = nil,
         makeLocalHost: @escaping @MainActor (SecondaryMacExecutionWorkspace, URL) -> SecondaryMacExecutionHost = {
             SecondaryMacExecutionHost(workspace: $0, directory: $1)
         },
         clearWorkspaceCredential: @escaping @MainActor (String) throws -> Void = { try WorkspaceCredentialVault.clear(workspaceID: $0) },
         enrollWorkspace: (@MainActor (String) async throws -> DirectWorkspaceCredential)? = nil,
         saveWorkspaceCredential: @escaping @MainActor (DirectWorkspaceCredential) throws -> Void = { try WorkspaceCredentialVault.save($0) },
         makeWorkspaceTransport: @escaping @MainActor (DirectWorkspaceCredential) throws -> any ExecutionWorkspaceTransport = {
             try HTTPSExecutionWorkspaceTransport(credential: $0)
         },
         makeLiveStream: @escaping LiveStreamFactory = CentralLibraryClientModel.developmentLiveStream) {
        self.makeLiveStream = makeLiveStream
        self.makeLocalExecution = makeLocalExecution ?? { directory, replica in
            try await SecondaryMacExecutionWorkspace.create(directory: directory, replica: replica, assets: assets)
        }
        self.makeLocalHost = makeLocalHost
        self.clearWorkspaceCredential = clearWorkspaceCredential
        self.enrollWorkspace = enrollWorkspace
        self.saveWorkspaceCredential = saveWorkspaceCredential
        self.makeWorkspaceTransport = makeWorkspaceTransport
        self.executionDirectoryOverride = executionDirectory
        if let store {
            self.store = store
            if let transport { engine = MobileSyncEngine(store: store, transport: transport) }
            return
        }
        do {
            let root = IsolatedTestWorkspace.supportDirectory
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appending(path: WovenMatterWorkspacePaths.folderName, directoryHint: .isDirectory)
            self.store = try MobileStore(file: root.appending(path: "LibraryClient/library.json"))
        } catch {
            self.store = nil
            errorMessage = "The local library could not open: " + error.localizedDescription
        }
    }

    var folders: [LibraryFolder] { state.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var notes: [LibraryNote] { state.notes.values.sorted { $0.updatedAt > $1.updatedAt } }
    var conversations: [LibraryConversation] { state.conversations.values.sorted { $0.updatedAt > $1.updatedAt } }
    var executionWorkspaces: [ExecutionWorkspace] { journal.workspaces.values.filter { !$0.deleted }.sorted { $0.name < $1.name } }
    @ObservationIgnored lazy var devicePairing = MacPairingController(identity: { [weak self] in
        guard let self else { return .init(deviceID: "00000000-0000-4000-8000-000000000000", deviceName: "Mac", metadata: .init(kind: .mac)) }
        return .init(deviceID: self.state.deviceID, deviceName: DevelopmentLaunch.deviceName(),
            metadata: .init(kind: .mac, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String, developmentInstance: DevelopmentLaunch.instance))
    }, onPaired: { [weak self] endpoint, response in
        guard let self else { throw CancellationError() }
        try await self.acceptPairing(endpoint: endpoint, response: response)
    })
    var canControl: Bool { canControl(workspaceID: selectedExecutionWorkspaceID) }
    func canControl(workspaceID: String?) -> Bool {
        !preparingTransition && ((workspaceID ?? "central") == "central" ? online : directOnline.contains(workspaceID ?? "central"))
    }

    func initialize() async {
        if let initializationTask { await initializationTask.value; return }
        guard !initialized else { return }
        let task = Task { await self.initializeState() }
        initializationTask = task
        await task.value
        initializationTask = nil
    }
    private func initializeState() async {
        if let store {
            do { try await store.restoreExecutionProjection() } catch { errorMessage = error.localizedDescription }
        }
        if let store { await analytics.configure(store.analytics, transport: transport) }
        await reload()
        defer { initialized = true }
        guard engine == nil else { return }
        do {
            credential = try MobileCredentialVault.load()
            if DevelopmentLaunch.isClient { await reconnectDevelopmentLibrary() }
            try configureTransport()
            try configureDirectClients()
            if let store { await analytics.configure(store.analytics, transport: transport) }
        } catch { errorMessage = error.localizedDescription }
    }
    func reconnectDevelopmentLibrary() async {
        guard credential == nil, !preparingTransition, !connectingDevelopment else { return }
        connectingDevelopment = true
        defer { connectingDevelopment = false; nextDevelopmentConnection = Date().addingTimeInterval(5) }
        let generation = connectionGeneration
        do {
            // Only the public half of this instance's stream key leaves it.
            let key = try? DevelopmentStreamKey.loadOrCreate(deviceID: state.deviceID).publicKey.rawRepresentation
            let connection = try await DevelopmentLaunch.connect(deviceID: state.deviceID, memberKey: key)
            guard !Task.isCancelled, !preparingTransition, connectionGeneration == generation, credential == nil else { return }
            try await acceptPairing(endpoint: connection.endpoint, response: connection.pairing)
            deviceConnectionsError = nil
        } catch {
            deviceConnectionsError = "The live library is unavailable: " + error.localizedDescription
            status = deviceConnectionsError ?? "Waiting for live library"
        }
    }
    func run() async {
        guard !running else { return }; running = true
        defer { running = false }
        await initializeClientWorkspace()
        // Nothing here ticks. Each pass does what is due, then waits for the
        // next event (a stream item, a local change, a write) or the next
        // retry a failure scheduled. With the live host's stream open and
        // nothing failing, it waits for events alone.
        while !Task.isCancelled {
            if DevelopmentLaunch.isClient, credential == nil, nextDevelopmentConnection <= Date() {
                await reconnectDevelopmentLibrary()
            }
            await refresh(background: true)
            await reconcileLiveStream()
            await waitForWork(until: nextScheduledWork())
        }
        await closeLiveStream()
    }

    /// The earliest retry or fallback that is due, or nil when only events remain.
    func nextScheduledWork() -> Date? {
        var dates: [Date] = []
        if DevelopmentLaunch.isClient, credential == nil { dates.append(nextDevelopmentConnection) }
        if requiresLocalExecution, engine != nil, !sharingLocalExecution { dates.append(nextLocalSharingAttempt) }
        if sharingLocalExecution { dates.append(nextLocalSharingCheck) }
        if engine != nil { dates.append(centralSyncRequested ? .distantPast : nextCentralRefresh) }
        dates += directClients.keys.map { nextDirectRefresh[$0] ?? .distantPast }
        return dates.filter { $0 != .distantFuture }.min()
    }

    /// Wakes the loop now: a stream item, a local change or a write needs a pass.
    func wakeRun() {
        wakeRequested = true
        wakeTimer?.cancel(); wakeTimer = nil
        let waiter = wakeContinuation; wakeContinuation = nil
        waiter?.resume()
    }

    private func waitForWork(until date: Date?) async {
        guard !wakeRequested else { wakeRequested = false; return }
        if let date, date <= Date() { return }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                wakeContinuation = continuation
                if let date {
                    let delay = max(0, date.timeIntervalSinceNow)
                    wakeTimer = Task { [weak self] in
                        do { try await Task.sleep(for: .milliseconds(Int64(delay * 1_000) + 1)) } catch { return }
                        self?.wakeRun()
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.wakeRun() }
        }
        wakeRequested = false
    }
    func initializeClientWorkspace() async {
        requiresLocalExecution = true
        await initialize()
        await enableLocalExecution()
    }
    func acceptPairing(endpoint: URL, response: PairResponse) async throws {
        guard let store else { throw MobileStore.Failure.incompatibleStore }
        guard response.protocolVersion == LibraryProtocol.version, response.deviceID == state.deviceID else {
            throw MobileConnectionError.invalidResponse
        }
        let value = MobileCredential(endpoint: endpoint, workspaceID: response.workspaceID, deviceID: response.deviceID, token: response.credential)
        _ = try HTTPSLibraryTransport(credential: value)
        try await store.bindWorkspace(response.workspaceID)
        try MobileCredentialVault.save(value)
        connectionGeneration = UUID(); credential = value
        try configureTransport()
        // Re-pairing may reuse this Mac's existing executor after Unpair stopped sharing.
        if localExecution != nil { await startLocalSharing() }
        await refresh()
    }
    private func configureTransport() throws {
        guard let credential, let store else { return }
        guard credential.deviceID == state.deviceID else {
            throw LibraryAPIError(code: "device_identity_changed", message: "Pair this Mac with the central database again. Its local replica has a different device identity.")
        }
        let transport = try HTTPSLibraryTransport(credential: credential, metadata: MacPairingController.metadata)
        self.transport = transport; engine = MobileSyncEngine(store: store, transport: transport)
    }
    func reload() async {
        await analytics.refresh()
        if let store {
            state = await store.snapshot(); journal = await store.journal.snapshot(); artifacts = await store.artifacts.manifests().filter { !$0.deleted }
            let generation = connectionGeneration
            let value: MobileSynchronizationStatus
            if let engine { value = await engine.synchronizationStatus() }
            else { value = await MobileSyncEngine.localSynchronizationStatus(store: store) }
            if generation == connectionGeneration { synchronization = value }
        }
        if DevelopmentLaunch.isClient, let model = localExecution?.model {
            model.liveLibraryClient = self
            await model.updateDevelopmentReplica(DevelopmentReplicaSnapshot(self))
        }
    }
    func attachExecutionWorkspace(_ workspace: ExecutionWorkspace, transport: any ExecutionWorkspaceTransport) async throws {
        guard let store else { throw MobileStore.Failure.incompatibleStore }
        let publisher = workspace.executionDeviceID ?? (workspace.kind == .linux ? nil : workspace.ownerDeviceID)
        try await store.journal.upsertWorkspace(workspace, pending: publisher == (await store.snapshot()).deviceID)
        directClients[workspace.id] = WorkspaceClient(store: store, workspaceID: workspace.id, transport: transport)
        await reload()
    }
    func artifactURL(_ artifact: LibraryArtifactManifest) async throws -> URL {
        let local: URL
        if let cached = await store?.artifacts.localURL(id: artifact.id) { local = cached }
        else if let engine { local = try await engine.ensureArtifactCached(artifact.id) }
        else { throw LibraryAPIError(code: "not_downloaded", message: "Reconnect to download this saved artifact.") }
        let directory = FileManager.default.temporaryDirectory.appending(path: "WovenMatterClientPreview/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let title = URL(fileURLWithPath: artifact.title).lastPathComponent
        let url = directory.appending(path: title.isEmpty || title == "." || title == ".." ? "Artifact" : title)
        try FileManager.default.copyItem(at: local, to: url)
        return url
    }
    private var executionDirectory: URL {
        if let executionDirectoryOverride { return executionDirectoryOverride }
        let root = IsolatedTestWorkspace.supportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: WovenMatterWorkspacePaths.folderName)
        return root.appending(path: "LibraryClient/Execution/" + state.deviceID)
    }
    func enableLocalExecution() async {
        guard !preparingTransition, !localExecutionBusy, state.workspaceID != nil, let store else { return }
        if localExecution != nil { await startLocalSharing(); return }
        localExecutionBusy = true; defer { localExecutionBusy = false }
        do {
            let workspace = try await makeLocalExecution(executionDirectory, store)
            try await attachExecutionWorkspace(workspace.descriptor, transport: workspace)
            localExecution = workspace
            observeLocalExecution(workspace.database)
            if DevelopmentLaunch.isClient { workspace.model.liveLibraryClient = self }
            await startLocalSharing()
            await selectExecutionWorkspace(workspace.descriptor.id)
        } catch { errorMessage = error.localizedDescription }
    }
    func startLocalSharing() async {
        // A retained replica/executor survives Unpair, but it must stay private
        // until a central pairing configures a synchronization engine again.
        guard !preparingTransition, !localSharingBusy, engine != nil,
              let localExecution, !sharingLocalExecution, let store else { return }
        let expectedConnection = connectionGeneration
        localSharingBusy = true; defer { localSharingBusy = false }
        nextLocalSharingAttempt = Date().addingTimeInterval(5)
        deviceConnectionsError = nil
        do {
            let host = localHost ?? makeLocalHost(localExecution, executionDirectory)
            localHost = host
            let previousPort = journal.workspaces[localExecution.descriptor.id]?.endpoint?.port
            try await host.start(preferredHTTPSPort: previousPort)
            guard !preparingTransition, engine != nil, connectionGeneration == expectedConnection else { throw CancellationError() }
            sharingLocalExecution = true
            var descriptor = localExecution.descriptor
            descriptor.revision = journal.workspaces[descriptor.id]?.revision ?? 0
            try await store.journal.upsertWorkspace(descriptor)
            guard !preparingTransition, engine != nil, connectionGeneration == expectedConnection else { throw CancellationError() }
            nextLocalSharingAttempt = .distantPast
            await refresh()
        } catch {
            localHost?.stop(); try? await localHost?.waitUntilStopped()
            sharingLocalExecution = false; publishedManagement = nil
            try? await localExecution.setEndpoint(nil)
            deviceConnectionsError = error.localizedDescription
        }
    }
    func stopLocalSharing() async {
        guard !localSharingBusy else { return }
        localSharingBusy = true; defer { localSharingBusy = false }
        localHost?.stop()
        do { try await localHost?.waitUntilStopped() } catch { errorMessage = error.localizedDescription; return }
        sharingLocalExecution = false; publishedManagement = nil
        nextLocalSharingAttempt = .distantPast
        if let localExecution, let store {
            do {
                try await localExecution.setEndpoint(nil)
                var descriptor = localExecution.descriptor
                descriptor.revision = journal.workspaces[descriptor.id]?.revision ?? 0
                try await store.journal.upsertWorkspace(descriptor)
            } catch { errorMessage = error.localizedDescription }
        }
    }
    func prepareForRoleChange() async throws {
        guard !localExecutionBusy, !localSharingBusy else {
            throw LibraryAPIError(code: "operation_in_progress", message: "Wait for the current client operation to finish before restarting or quitting.")
        }
        preparingTransition = true
        do {
            try await flushLocalWrites()
            try await localExecution?.prepareToStop()
            executionPreparedForTransition = localExecution != nil
            localHost?.stop(); try await localHost?.waitUntilStopped()
            localHost = nil; sharingLocalExecution = false; publishedManagement = nil
        } catch {
            await restoreExecutionAfterFailedTransition()
            throw error
        }
    }
    func restoreExecutionAfterFailedTransition() async {
        preparingTransition = false
        guard executionPreparedForTransition else { return }
        executionPreparedForTransition = false
        if let id = localExecution?.descriptor.id { directClients[id] = nil; directOnline.remove(id) }
        localExecution = nil
        await enableLocalExecution()
    }
    func prepareForQuit() async throws {
        try await prepareForRoleChange()
        if DevelopmentLaunch.mode != nil {
            await stopLocalSharing()
            // Withdraw the route before ending the local presence lease. Saved
            // changes remain journaled if the central library is offline.
            _ = try? await engine?.synchronize()
            await engine?.cancelSynchronization()
            try? await transport?.suspendDevelopmentConnection()
            // The stream closes first; the disconnect then revokes its key on the live host.
            await closeLiveStream()
            if DevelopmentLaunch.isClient, let credential { try? await DevelopmentLaunch.disconnect(deviceID: state.deviceID, credential: credential.token) }
        }
    }

    // MARK: Live host stream

    /// The real connector of a client-mode build: before each attempt it
    /// admits this instance's stream key with its current Dev credential on
    /// the live host's same-user socket, then opens the host's loopback
    /// development listener, signed for the member ID the host returned.
    static func developmentLiveStream(credential: MobileCredential?, deviceID: String,
                                      route: DevelopmentLiveStream.Route) -> StreamConnection? {
        guard DevelopmentLaunch.isClient, let credential, let key = try? DevelopmentStreamKey.loadOrCreate(deviceID: deviceID) else { return nil }
        let signer = MemberRequestSigner(deviceID: deviceID, key: key)
        let request = DevelopmentStreamRequest(deviceID: deviceID, credential: credential.token, memberKey: key.publicKey.rawRepresentation)
        return StreamConnection {
            let admitted = try await DevelopmentLaunch.admitStream(request)
            route.current = admitted
            let url = WebSocketStreamTransport.loopbackURL(port: admitted.port)
            let headers = try signer.headers(method: "GET", target: StreamEndpoint.target(of: url), audience: admitted.audience)
            return WebSocketStreamTransport.loopback(port: admitted.port, headers: headers)
        }
    }

    /// Whether `conversationID` is a live host chat that the stream follows now.
    func streams(_ conversationID: String) -> Bool {
        liveStreamOpen && followedConversationIDs.contains(conversationID) && executionOwner(for: conversationID) == nil
            && !liveEnded.contains(conversationID)
    }

    /// A window of this server opened a chat another machine runs (the live
    /// host or another): it follows the host's stream while it stays open.
    func followConversation(_ id: String) {
        guard followedConversationIDs.insert(id).inserted else { return }
        Task { await self.followOnStream() }
    }

    func unfollowConversation(_ id: String) {
        guard followedConversationIDs.remove(id) != nil else { return }
        liveTranscripts.removeValue(forKey: id); liveCapabilities.removeValue(forKey: id)
        liveSessions.removeValue(forKey: id); liveEnded.remove(id)
        Task { await self.followOnStream() }
    }

    private func followOnStream() async {
        await liveStream?.follow(followedConversationIDs.filter { executionOwner(for: $0) == nil })
    }

    private func relayChanged(_ ids: Set<String>) {
        let ids = ids.intersection(followedConversationIDs)
        guard !ids.isEmpty else { return }
        if let liveRelayChanged { liveRelayChanged(ids) } else { localExecution?.model.windowStreamRelayChanged(ids) }
    }

    /// One stream per credential, opened once this replica knows its library.
    private func reconcileLiveStream() async {
        guard !preparingTransition, engine != nil, let libraryID = state.workspaceID, let store else { await closeLiveStream(); return }
        let key = credential?.token ?? ""
        if liveStream != nil, liveStreamCredential == key { return }
        await closeLiveStream()
        let route = DevelopmentLiveStream.Route()
        guard let connection = makeLiveStream(credential, state.deviceID, route) else { return }
        let stream = DevelopmentLiveStream(libraryID: libraryID, store: store, connection: connection, route: route) { [weak self] update in
            await self?.liveStreamUpdate(update)
        }
        liveStream = stream; liveStreamCredential = key
        await stream.start()
        await followOnStream()
    }

    func closeLiveStream() async {
        guard let stream = liveStream else { return }
        liveStream = nil; liveStreamCredential = nil
        await stream.close()
        setLiveStreamOpen(false)
    }

    private func setLiveStreamOpen(_ open: Bool) {
        guard open != liveStreamOpen else { return }
        liveStreamOpen = open
        if open {
            // Catch up once on what changed while closed; then items drive sync.
            centralSyncRequested = true
        } else {
            livePending = []; liveTranscripts = [:]; liveCapabilities = [:]; liveSessions = [:]; liveEnded = []
            // The fallback timer resumes until the stream opens again.
            nextCentralRefresh = min(nextCentralRefresh, Date().addingTimeInterval(Self.fallbackActiveCentralInterval))
        }
        wakeRun()
        relayChanged(followedConversationIDs)
    }

    private func liveStreamUpdate(_ update: DevelopmentLiveStream.Update) async {
        switch update {
        case .state(let state):
            switch state {
            case .open: liveStreamProblem = nil; setLiveStreamOpen(true)
            case .memberRemoved:
                liveStreamProblem = "The live library host revoked this development client's stream key."
                setLiveStreamOpen(false)
            case .waiting(let error):
                liveStreamProblem = error?.localizedDescription
                setLiveStreamOpen(false)
            case .idle, .connecting: setLiveStreamOpen(false)
            }
        case .conversations:
            scheduleLiveReload()
        case .pending(let interactions):
            let changed = Set((livePending + interactions).map(\.conversationID))
            livePending = interactions
            relayChanged(changed)
        case .library(let cursor):
            guard let store, cursor > (await store.snapshot().cursor) else { return }
            centralSyncRequested = true; wakeRun()
        case .transcript(let id, let transcript):
            liveTranscripts[id] = transcript; relayChanged([id])
        case .capabilities(let id, let value):
            liveCapabilities[id] = value; relayChanged([id])
        case .session(let id, let value):
            guard liveSessions[id] != value else { return }
            liveSessions[id] = value; relayChanged([id])
        case .ended(let id):
            liveEnded.insert(id); relayChanged([id])
        case .workspaceEnded(let error):
            // Without `workspace` items nothing says when to sync: the 15 s / 2 s
            // fallback runs until the next connection subscribes again.
            liveStreamProblem = error?.message ?? "The live library host stopped its stream. Woven Matter reconnects automatically."
            setLiveStreamOpen(false)
        }
    }

    /// Session summaries reach the replica projection at most every 50 ms.
    private func scheduleLiveReload() {
        guard !liveReloadScheduled else { return }
        liveReloadScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self else { return }
            self.liveReloadScheduled = false
            await self.reload()
        }
    }

    /// This Mac's execution database committed session or library changes:
    /// its history is captured on the next pass, at most once a second.
    private func observeLocalExecution(_ database: WorkspaceDatabase) {
        if let localObservers {
            for id in localObservers.ids {
                localObservers.database.removeExecutionStreamObserver(id); localObservers.database.removeLibraryChangeObserver(id)
            }
        }
        let changed: @Sendable (Int64) -> Void = { [weak self] _ in Task { @MainActor in self?.localExecutionChanged() } }
        localObservers = (database, [database.observeExecutionStreamChanges(changed), database.observeLibraryChanges(changed)])
    }

    private func localExecutionChanged() {
        guard let id = localExecution?.descriptor.id else { return }
        let due = max(Date(), lastLocalCapture.addingTimeInterval(Self.localCaptureInterval))
        if (nextDirectRefresh[id] ?? .distantPast) > due { nextDirectRefresh[id] = due }
        wakeRun()
    }

    /// A captured change or a queued edit waits for the library: one pass now.
    private func requestCentralSyncIfPending() async {
        guard let store, engine != nil else { return }
        let journal = await store.journal.snapshot()
        let outbox = await store.snapshot().outbox
        guard !journal.pendingEventIDs.isEmpty || !journal.pendingRegistrations.isEmpty || !outbox.isEmpty else { return }
        centralSyncRequested = true; wakeRun()
    }
    /// This device's credential for its central library's namespace, or for a
    /// workspace another paired Mac owns, checked against that workspace's
    /// registered namespace and endpoint.
    private func acceptsWorkspaceCredential(_ credential: DirectWorkspaceCredential) -> Bool {
        WorkspaceCredentialPolicy.accepts(credential, deviceID: state.deviceID, libraryID: state.workspaceID,
            registered: journal.workspaces[credential.workspaceID])
    }
    private func configureDirectClients() throws {
        guard credential != nil, let store else { return }
        for workspace in executionWorkspaces where directClients[workspace.id] == nil {
            if let credential = try WorkspaceCredentialVault.load(workspaceID: workspace.id) {
                guard credential.workspaceID == workspace.id, acceptsWorkspaceCredential(credential) else { continue }
                let connection = try makeWorkspaceTransport(credential)
                directClients[workspace.id] = WorkspaceClient(store: store, workspaceID: workspace.id, transport: connection)
            }
        }
    }
    func selectExecutionWorkspace(_ id: String) async {
        selectedExecutionWorkspaceID = id
        selectedConversationID = nil
        await refreshDirectWorkspace()
    }
    private func refreshDirectWorkspace(_ requestedID: String? = nil) async {
        let workspaceID = requestedID ?? selectedExecutionWorkspaceID
        guard let client = directClients[workspaceID] else { return }
        do {
            try await client.refresh()
            guard directClients[workspaceID] === client else { return }
            if let id = selectedConversationID, executionOwner(for: id) == workspaceID {
                _ = try await client.refreshTranscript(id)
            }
            guard directClients[workspaceID] === client else { return }
            directOnline.insert(workspaceID); directFailures[workspaceID] = 0
            // Read again only on an event: for this Mac's own execution a change
            // in its database; for another machine a library pass, an opened
            // chat or an action. Nothing reads a workspace on a timer.
            nextDirectRefresh[workspaceID] = .distantFuture
            if workspaceID == localExecution?.descriptor.id {
                lastLocalCapture = Date()
                await requestCentralSyncIfPending()
            }
        } catch {
            guard directClients[workspaceID] === client else { return }
            directOnline.remove(workspaceID)
            if Self.revokesDirectAccess(error), workspaceID != localExecution?.descriptor.id {
                directClients[workspaceID] = nil
                do {
                    try clearWorkspaceCredential(workspaceID)
                    pendingReenrollment.insert(workspaceID)
                    await reenrollDirectWorkspace(workspaceID)
                } catch { deviceConnectionsError = error.localizedDescription }
            }
            let failures = min((directFailures[workspaceID] ?? 0) + 1, 5); directFailures[workspaceID] = failures
            nextDirectRefresh[workspaceID] = Date().addingTimeInterval(min(60, pow(2, Double(failures))))
        }
        await reload()
    }
    /// The execution transport reports a rejected bearer as `.revoked`; older
    /// transports surfaced the raw status.
    nonisolated static func revokesDirectAccess(_ error: any Error) -> Bool {
        switch error as? MobileConnectionError {
        case .revoked: true
        case .http(let status, _): status == 401 || status == 403
        default: false
        }
    }
    /// A retired or revoked direct grant is replaced through the central
    /// library. Until that succeeds the workspace stays pending and is retried
    /// on each reachable central refresh; the stale token is never presented.
    private func retryPendingReenrollments() async {
        let pending = pendingReenrollment.intersection(executionWorkspaces.map(\.id))
        pendingReenrollment = pending
        for id in pending.sorted() where directClients[id] == nil { await reenrollDirectWorkspace(id) }
    }
    private func reenrollDirectWorkspace(_ workspaceID: String) async {
        let transport = transport
        guard let store, let enroll = enrollWorkspace ?? transport.map({ transport in
            { try await transport.executionCredential(workspaceID: $0) }
        }) else { return }
        let generation = connectionGeneration
        do {
            let issued = try await enroll(workspaceID)
            guard generation == connectionGeneration, directClients[workspaceID] == nil else { return }
            guard issued.workspaceID == workspaceID, acceptsWorkspaceCredential(issued) else {
                throw MobileStore.Failure.wrongWorkspace
            }
            let client = WorkspaceClient(store: store, workspaceID: workspaceID, transport: try makeWorkspaceTransport(issued))
            try saveWorkspaceCredential(issued)
            directClients[workspaceID] = client
            pendingReenrollment.remove(workspaceID)
        } catch { deviceConnectionsError = error.localizedDescription }
    }
    private func refreshAllExecutionWorkspaces(background: Bool) async {
        let ids = directClients.keys.filter { !background || (nextDirectRefresh[$0] ?? .distantPast) <= Date() }
        await withTaskGroup(of: Void.self) { group in
            for id in ids { group.addTask { await self.refreshDirectWorkspace(id) } }
        }
    }
    func refresh(background: Bool = false) async {
        guard !preparingTransition, !refreshing else { return }
        if requiresLocalExecution, localExecution == nil { await enableLocalExecution() }
        if sharingLocalExecution, !localSharingBusy, localHost?.isRunning != true {
            await stopLocalSharing()
        }
        nextLocalSharingCheck = sharingLocalExecution ? Date().addingTimeInterval(Self.localSharingCheckInterval) : .distantFuture
        if requiresLocalExecution, !sharingLocalExecution, !localSharingBusy, engine != nil,
           !background || nextLocalSharingAttempt <= Date() {
            await startLocalSharing()
        }
        refreshing = true; defer { refreshing = false }
        if sharingLocalExecution, let localExecution, let store, (try? await localExecution.refreshMacAccess()) == true {
            var descriptor = localExecution.descriptor
            descriptor.revision = journal.workspaces[descriptor.id]?.revision ?? 0
            try? await store.journal.upsertWorkspace(descriptor)
        }
        async let directRefresh: Void = refreshAllExecutionWorkspaces(background: background)
        guard let engine, !background || centralSyncRequested || nextCentralRefresh <= Date() else { await directRefresh; return }
        centralSyncRequested = false
        let expectedConnection = connectionGeneration
        do {
            try await flushLocalWrites()
            do { try await engine.synchronize() }
            catch {
                if case MobileStore.Failure.wrongWorkspace = error { throw error }
                if case MobileStore.Failure.incompatibleStore = error { throw error }
                guard await engine.synchronizationStatus().centralReachable == true else { throw error }
            }
            guard connectionGeneration == expectedConnection else { await directRefresh; return }
            try await engine.recoverCommandReceipts()
            if let id = selectedConversationID, executionOwner(for: id) == nil, !streams(id) {
                try await engine.refreshTranscript(id)
            }
            guard connectionGeneration == expectedConnection else { await directRefresh; return }
            online = true; status = "Connected"
            try configureDirectClients()
            await retryPendingReenrollments()
            guard connectionGeneration == expectedConnection else { await directRefresh; return }
            if let grant = localHost?.managementGrant, publishedManagement != grant, let transport {
                try await transport.registerExecutionManagement(grant); publishedManagement = grant
            }
        } catch {
            guard connectionGeneration == expectedConnection else { await directRefresh; return }
            let syncStatus = await engine.synchronizationStatus()
            guard connectionGeneration == expectedConnection else { await directRefresh; return }
            online = syncStatus.centralReachable == true
            status = online ? "Connected" : credential == nil ? "Not connected" : "Disconnected"
            if error is MobileStore.Failure { errorMessage = error.localizedDescription }
        }
        if online { centralFailures = 0 }
        else { centralFailures = min(centralFailures + 1, 5) }
        let hasActiveRuns = state.conversations.values.contains { $0.activeRunID != nil }
        if !online { nextCentralRefresh = Date().addingTimeInterval(min(60, pow(2, Double(centralFailures)))) }
        // With the live host's stream open its `library` items start the next
        // pass; without one the fallback timer runs.
        else if liveStreamOpen { nextCentralRefresh = .distantFuture }
        else { nextCentralRefresh = Date().addingTimeInterval(hasActiveRuns ? Self.fallbackActiveCentralInterval : Self.fallbackCentralInterval) }
        await directRefresh
        if online, background {
            // History other machines wrote reached the library: read their
            // workspaces again on the next pass.
            for id in directClients.keys where id != localExecution?.descriptor.id { nextDirectRefresh[id] = .distantPast }
        }
        await reload()
        // Followed chats the stream does not carry are read again from what this pass brought.
        let unstreamed = followedConversationIDs.filter { !streams($0) }
        if !unstreamed.isEmpty { relayChanged(unstreamed) }
    }
    func flushLocalWrites() async throws {
        await writeTask?.value
        if let failure = writeFailures.values.first { throw LibraryAPIError(code: "local_write_failed", message: failure) }
    }
    private func enqueueWrite(key: String, _ operation: @escaping @MainActor (MobileStore) async throws -> Void) {
        guard !preparingTransition, let store else { return }
        let previous = writeTask
        writeTask = Task {
            await previous?.value
            do { try await operation(store); writeFailures[key] = nil; await engine?.scheduleSynchronization(); await reload() }
            catch { writeFailures[key] = error.localizedDescription; errorMessage = "Could not save locally: " + error.localizedDescription }
        }
    }
    func editNote(_ note: LibraryNote, title: String? = nil, content: String? = nil, folderID: String? = nil) {
        guard !preparingTransition else { return }
        var draft = draftNotes[note.id] ?? note
        if let title { draft.title = title }; if let content { draft.content = content }
        if let folderID { draft.folderID = folderID.isEmpty ? nil : folderID }
        let base = draftNotes[note.id] ?? note
        draftNotes[note.id] = draft
        let version = (noteWriteVersions[note.id] ?? 0) + 1
        noteWriteVersions[note.id] = version
        enqueueWrite(key: "note:" + note.id) { [weak self] store in
            try await store.editNote(id: draft.id, title: draft.title, content: draft.content, folderID: draft.folderID, base: base)
            await self?.analytics.record(.active)
            if self?.noteWriteVersions[note.id] == version { self?.draftNotes[note.id] = nil }
        }
    }
    func selectConversation(_ id: String?) async {
        selectedConversationID = id
        guard let id else { return }
        selectedExecutionWorkspaceID = executionOwner(for: id) ?? "central"
        do {
            if let owner = executionOwner(for: id), let client = directClients[owner] {
                _ = try await client.refreshTranscript(id)
            } else if executionOwner(for: id) == nil {
                try await engine?.refreshTranscript(id)
            }
            await reload()
        }
        catch { /* The persisted transcript remains readable offline. */ }
    }
    private func launchConversation(_ requested: MobileLaunchRecord) async throws -> MobileLaunchRecord {
        guard !preparingTransition else { throw LibraryAPIError(code: "stopping", message: "This client is restarting or quitting.") }
        let owner = requested.create.workspaceID ?? requested.create.routeID ?? "central"
        if owner == "central", let engine { return try await engine.startConversation(requested) }
        guard let client = directClients[owner] else { throw MobileConnectionError.offline }
        return try await client.startConversation(requested)
    }
    private func submit(_ command: LibraryCommand, workspaceID: String) async throws -> LibraryCommandReceipt {
        guard !preparingTransition else { throw LibraryAPIError(code: "stopping", message: "This client is restarting or quitting.") }
        if workspaceID == "central", let engine { return try await engine.submit(command) }
        guard let client = directClients[workspaceID] else { throw MobileConnectionError.offline }
        var routed = command; routed.workspaceID = workspaceID
        return try await client.submit(routed)
    }
    func executionOwner(for conversationID: String) -> String? {
        journal.conversationWorkspaceIDs[conversationID]
    }

    func isForeignConversation(_ id: String) -> Bool {
        state.conversations[id] != nil && executionOwner(for: id) != localExecution?.descriptor.id
    }

    func desktopSend(id: String, text: String, beforeDispatch: () throws -> Void = {}) async throws {
        let snapshot = try await desktopExecution(.refresh(conversationID: id))
        let command = LibraryCommand(deviceID: state.deviceID, kind: snapshot.transcript?.activeRunID == nil ? .send : .steer,
            conversationID: id, runID: snapshot.transcript?.activeRunID, text: text)
        try beforeDispatch()
        try requireAccepted(await submit(command, workspaceID: executionOwner(for: id) ?? "central"))
        await refresh()
    }

    /// One activity as a client-mode build can read it: the row its owner's
    /// transcript carries. (These clients are the phone's, which have no
    /// details route yet; their transport belongs to the iPhone app.)
    func desktopActivityDetails(conversationID: String, runID: String, activityID: String) async throws -> LibraryActivity {
        if let owner = executionOwner(for: conversationID), let client = directClients[owner],
           let row = try await client.refreshTranscript(conversationID).activities.first(where: { $0.id == activityID }) { return row }
        guard let engine, let row = try await engine.transcriptActivityDetail(conversationID, activityID: activityID) else {
            throw MobileConnectionError.offline
        }
        return row
    }

    func desktopExecution(_ action: FederatedExecutionAction) async throws -> FederatedExecutionSnapshot {
        let id: String
        var earlier: LibraryTranscript?
        switch action {
        case .refresh(let value): id = value
        case .stop(let value, let run):
            id = value
            try requireAccepted(await submit(.init(deviceID: state.deviceID, kind: .stop, conversationID: id, runID: run), workspaceID: executionOwner(for: id) ?? "central"))
        case .respond(let interaction, let response):
            id = interaction.conversationID
            try requireAccepted(await submit(.init(deviceID: state.deviceID, kind: .respond, conversationID: id,
                runID: interaction.runID, interactionID: interaction.id, response: response), workspaceID: executionOwner(for: id) ?? "central"))
        case .configure(let value, let command):
            id = value
            try requireAccepted(await submit(.init(deviceID: state.deviceID, kind: .workspace, conversationID: id, workspaceAction: command), workspaceID: executionOwner(for: id) ?? "central"))
        case .close(let value):
            // The window let go of the chat: it leaves the stream. Nothing is read.
            unfollowConversation(value)
            return heldSnapshot(value)
        case .earlier(let value, let before):
            id = value
            if let owner = executionOwner(for: id), let client = directClients[owner] { earlier = try await client.earlierTranscript(id, before: before) }
            else { earlier = try await transport?.transcript(id, before: before) }
        }
        // A chat the live host's stream follows is answered from its items;
        // an action's effect arrives there too. Nothing is read over HTTP.
        if earlier == nil, streams(id) { return heldSnapshot(id) }
        let owner = executionOwner(for: id) ?? "central"
        var provider: HarnessCapabilities?
        var interactions: [PendingInteraction] = []
        var refreshError: String?
        do {
        if owner == "central", let engine {
            try await engine.refreshTranscript(id)
            provider = try? await transport?.capabilities(id)
            interactions = (try? await engine.pending()) ?? []
        } else if let client = directClients[owner] {
            try await client.refresh()
            provider = try? await client.capabilities(id)
            interactions = (try? await client.pending()) ?? []
        }
        } catch { refreshError = error.localizedDescription }
        await reload()
        var settings: SessionSettings?
        if case .session(let value) = try? await workspace(.session(id: id)) { settings = value }
        let descriptor = journal.workspaces[owner] ?? ExecutionWorkspace(id: owner,
            libraryID: state.workspaceID ?? "", ownerDeviceID: owner, kind: .mac, name: "Production", capabilities: ["execution.v1"])
        return .init(workspace: descriptor, transcript: earlier ?? state.transcripts[id] ?? journal.transcripts[id],
            capability: provider, interactions: interactions.filter { $0.conversationID == id }, session: settings,
            online: refreshError == nil && (owner == "central" ? online : directOnline.contains(owner)), error: refreshError)
    }

    /// What this server holds for a chat without reading anything: the live
    /// host's stream items for a followed chat, else the replica's copy.
    private func heldSnapshot(_ id: String) -> FederatedExecutionSnapshot {
        let owner = executionOwner(for: id) ?? "central"
        let descriptor = journal.workspaces[owner] ?? ExecutionWorkspace(id: owner,
            libraryID: state.workspaceID ?? "", ownerDeviceID: owner, kind: .mac, name: "Production", capabilities: ["execution.v1"])
        let streamed = streams(id)
        return .init(workspace: descriptor, transcript: liveTranscripts[id] ?? state.transcripts[id] ?? journal.transcripts[id],
            capability: liveCapabilities[id], interactions: streamed ? livePending.filter { $0.conversationID == id } : [],
            session: liveSessions[id], online: streamed || (owner == "central" ? online : directOnline.contains(owner)),
            error: streamed ? nil : liveStreamProblem)
    }
    func workspace(_ read: LibraryWorkspaceRead) async throws -> LibraryWorkspaceResult {
        if let store {
            switch read {
            case .calendar(let from, let to): return .calendar(try await store.calendar.events(from: from, to: to))
            case .scheduledTasks: return .scheduledTasks(await store.calendar.scheduledTasks())
            default: break
            }
        }
        let conversationID: String?
        switch read {
        case .session(let id), .exportConversation(let id, _): conversationID = id
        default: conversationID = nil
        }
        if let conversationID, let owner = executionOwner(for: conversationID) {
            guard let client = directClients[owner] else { throw MobileConnectionError.offline }
            return try await client.readWorkspace(read)
        }
        guard let engine else { throw MobileConnectionError.offline }
        return try await engine.readWorkspace(read)
    }
    @discardableResult func perform(_ action: LibraryWorkspaceAction) async -> Bool {
        let conversationID: String?
        switch action {
        case .goal(let id, _), .conversation(let id, _, _, _), .configureSession(let id, _, _, _), .sessionTools(let id, _, _): conversationID = id
        default: conversationID = nil
        }
        let owner = conversationID.flatMap { executionOwner(for: $0) } ?? "central"
        do {
            try requireAccepted(await submit(.init(deviceID: state.deviceID, kind: .workspace, conversationID: conversationID, workspaceAction: action), workspaceID: owner))
            if action.qualifiesForAnalytics { await analytics.record(.active) }
            await refresh(); return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
    func linkedData(note: LibraryNote, tableID: String? = nil) async throws -> LinkedDataPreview {
        guard online, let engine else { throw MobileConnectionError.offline }
        let result = try await engine.linkedData(note: note, tableID: tableID)
        guard state.notes[note.id]?.revision == note.revision else { throw CancellationError() }
        return result
    }
    func canonicalNote(_ id: String) async throws -> LibraryNote {
        guard let engine, let store else { throw MobileStore.Failure.missingNote }
        try await flushLocalWrites()
        try await engine.synchronize(); await reload(); return try await store.canonicalNote(id: id)
    }
    func exportFile(_ read: LibraryWorkspaceRead) async throws -> URL {
        guard case .file(let file) = try await workspace(read) else { throw MobileConnectionError.invalidResponse }
        let directory = FileManager.default.temporaryDirectory.appending(path: "WovenMatterClientPreview/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = URL(fileURLWithPath: file.name).lastPathComponent
        let output = directory.appending(path: name.isEmpty || name == "." || name == ".." ? "Artifact" : name)
        try file.data.write(to: output, options: .atomic)
        return output
    }
    private func requireAccepted(_ receipt: LibraryCommandReceipt) throws {
        guard receipt.status == .accepted || receipt.status == .completed else {
            throw LibraryAPIError(code: "command_pending", message: receipt.message ?? "The command outcome is not confirmed. Check its receipt before retrying.")
        }
    }
}
