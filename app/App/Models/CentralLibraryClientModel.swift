import AppKit
import CompanionClient
import Foundation
import Observation
import WovenMatterCompanion

enum CentralLibraryClientConfiguration {
    static let preferenceKey = LocalExecutionRole.libraryClientPreferenceKey
    static func isEnabled(defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: preferenceKey) }
}

/// A secondary Mac owns a replica, never another copy of the authoritative database.
/// The portable store journals edits and command identities before network submission.
@MainActor @Observable
final class CentralLibraryClientModel {
    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", folders = "Folders", chats = "Chats", notes = "Notes", library = "Library", calendar = "Calendar", browser = "Browser", trash = "Trash", settings = "Settings"
        var id: String { rawValue }
        var icon: DashboardLucideGlyph {
            switch self {
            case .home: .house
            case .folders: .folder
            case .chats: .messageSquare
            case .notes: .fileText
            case .library: .libraryBig
            case .calendar: .calendarDays
            case .browser: .compass
            case .trash: .trash
            case .settings: .settings
            }
        }
    }
    let analytics = MobileAnalyticsModel()
    var section: Section = .home
    private(set) var state = MobileStoreState()
    private(set) var credential: MobileCredential?
    private(set) var online = false
    private(set) var synchronization = MobileSynchronizationStatus()
    private(set) var connectedDevices: [CompanionDeviceConnection] = []
    private var nextCentralRefresh = Date.distantPast
    private var centralFailures = 0
    private var nextDirectRefresh: [String: Date] = [:]
    private var directFailures: [String: Int] = [:]
    private var nextRosterRefresh = Date.distantPast
    private(set) var refreshing = false
    private(set) var initialized = false
    private(set) var providers: [CompanionProvider] = []
    private(set) var pending: [CompanionPendingInteraction] = []
    private(set) var sending = false
    var errorMessage: String?
    var status = "Not connected"
    var selectedFolderID: String?
    var selectedNoteID: String?
    var selectedConversationID: String?
    var selectedProviderID = ""
    var selectedExecutionWorkspaceID = "central"
    private(set) var journal = WorkspaceJournalState()
    private(set) var directOnline: Set<String> = []
    private(set) var artifacts: [CompanionArtifactManifest] = []
    var clientStore: MobileStore? { store }
    private var directClients: [String: WorkspaceClient] = [:]
    private var centralProviders: [CompanionProvider] = []
    private var centralPending: [CompanionPendingInteraction] = []
    private var directProviders: [String: [CompanionProvider]] = [:]
    private var directPending: [String: [CompanionPendingInteraction]] = [:]
    var pairingText = ""
    private(set) var localExecution: SecondaryMacExecutionWorkspace?
    private(set) var localExecutionBusy = false
    private(set) var sharingLocalExecution = false
    private var localHost: SecondaryMacExecutionHost?
    private var executionPreparedForTransition = false
    private var publishedManagement: CompanionExecutionManagementGrant?
    private static let localSharingKey = "wovenmatter.client.share-execution"
    private(set) var draftNotes: [String: CompanionNote] = [:]
    private(set) var olderTranscripts: [String: CompanionTranscript] = [:]
    private var chatDrafts: [String: MobileChatDraft] = [:]
    private var writeTask: Task<Void, Never>?
    private var writeFailures: [String: String] = [:]
    private var noteWriteVersions: [String: Int] = [:]
    private var requiresLocalExecution = false
    private var connectionGeneration = UUID()
    private let makeLocalExecution: @MainActor (URL, MobileStore) async throws -> SecondaryMacExecutionWorkspace
    private let saveCentralCredential: @MainActor (MobileCredential) throws -> Void
    private let clearWorkspaceCredential: @MainActor (String) throws -> Void
    private let clearCentralCredential: @MainActor () throws -> Void
    private let executionDirectoryOverride: URL?
    private let preferences: UserDefaults
    var deviceConnectionsError: String?
    private var booted = false
    private var running = false
    private(set) var preparingTransition = false
    private(set) var localSharingBusy = false
    private var sessionProviders: [String: CompanionProvider] = [:]
    var calendarRevision = 0
    private let store: MobileStore?
    private var engine: MobileSyncEngine?
    private var transport: HTTPSCompanionTransport?

    init(store: MobileStore? = nil, transport: (any CompanionTransport)? = nil,
         assets: WorkspaceAssetSession? = nil,
         executionDirectory: URL? = nil, preferences: UserDefaults = .standard,
         makeLocalExecution: (@MainActor (URL, MobileStore) async throws -> SecondaryMacExecutionWorkspace)? = nil,
         saveCentralCredential: @escaping @MainActor (MobileCredential) throws -> Void = { try MobileCredentialVault.save($0) },
         clearCentralCredential: @escaping @MainActor () throws -> Void = { try MobileCredentialVault.clear() },
         clearWorkspaceCredential: @escaping @MainActor (String) throws -> Void = { try WorkspaceCredentialVault.clear(workspaceID: $0) }) {
        self.makeLocalExecution = makeLocalExecution ?? { directory, replica in
            try await SecondaryMacExecutionWorkspace.create(directory: directory, replica: replica, assets: assets)
        }
        self.clearCentralCredential = clearCentralCredential
        self.clearWorkspaceCredential = clearWorkspaceCredential
        self.saveCentralCredential = saveCentralCredential
        self.executionDirectoryOverride = executionDirectory
        self.preferences = preferences
        if let store {
            self.store = store
            if let transport { engine = MobileSyncEngine(store: store, transport: transport) }
            return
        }
        do {
            let root = CompanionTestWorkspace.supportDirectory
                ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                    .appending(path: WovenMatterWorkspacePaths.folderName, directoryHint: .isDirectory)
            self.store = try MobileStore(file: root.appending(path: "LibraryClient/library.json"))
        } catch {
            self.store = nil
            errorMessage = "The local library could not open: " + error.localizedDescription
        }
    }

    var folders: [CompanionFolder] { state.folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending } }
    var notes: [CompanionNote] { state.notes.values.sorted { $0.updatedAt > $1.updatedAt } }
    var conversations: [CompanionConversation] { state.conversations.values.sorted { $0.updatedAt > $1.updatedAt } }
    var selectedNote: CompanionNote? { selectedNoteID.flatMap { draftNotes[$0] ?? state.notes[$0] } }
    var selectedConversation: CompanionConversation? { selectedConversationID.flatMap { state.conversations[$0] } }
    var transcript: CompanionTranscript? {
        guard let id = selectedConversationID else { return nil }
        let current = state.transcripts[id]
        guard var earlier = olderTranscripts[id], let current else { return current }
        let ids = Set(current.messages.map(\.id))
        earlier.messages = earlier.messages.filter { !ids.contains($0.id) } + current.messages
        let activityIDs = Set(current.activities.map(\.id))
        earlier.activities = earlier.activities.filter { !activityIDs.contains($0.id) } + current.activities
        earlier.activeRunID = current.activeRunID
        return earlier
    }
    var activeRunID: String? { transcript?.activeRunID ?? selectedConversation?.activeRunID }
    var activeProvider: CompanionProvider? {
        if let id = selectedConversationID, let provider = sessionProviders[id] { return provider }
        return providers.first { $0.id == (selectedConversation?.providerID ?? selectedProviderID) }
    }
    var currentPending: [CompanionPendingInteraction] { pending.filter { $0.conversationID == selectedConversationID } }
    var calendarCentralProviders: [CompanionProvider] { centralProviders }
    var calendarLocalProviders: [CompanionProvider] { localExecution.flatMap { directProviders[$0.descriptor.id] } ?? [] }
    var executionWorkspaces: [CompanionExecutionWorkspace] { journal.workspaces.values.filter { !$0.deleted }.sorted { $0.name < $1.name } }
    func hasDirectAccess(_ workspaceID: String) -> Bool { directClients[workspaceID] != nil }
    @ObservationIgnored lazy var devicePairing = CompanionMacPairingController(identity: { [weak self] in
        guard let self else { return .init(deviceID: "00000000-0000-4000-8000-000000000000", deviceName: "Mac", metadata: .init(kind: .mac)) }
        return .init(deviceID: self.state.deviceID, deviceName: Host.current().localizedName ?? "This Mac",
            metadata: .init(kind: .mac, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String))
    }, onPaired: { [weak self] endpoint, response in
        guard let self else { throw CancellationError() }
        try await self.acceptPairing(endpoint: endpoint, response: response)
    })
    var canControl: Bool { canControl(workspaceID: selectedExecutionWorkspaceID) }
    func canControl(workspaceID: String?) -> Bool {
        !preparingTransition && ((workspaceID ?? "central") == "central" ? online : directOnline.contains(workspaceID ?? "central"))
    }
    var pendingLaunches: [MobileLaunchRecord] { state.launches.filter { !$0.accepted && !$0.terminalFailure } }
    var uncertainCommands: [MobileCommandRecord] { (state.commands + Array(journal.commands.values)).filter { $0.receipt == nil || $0.receipt?.status == .outcomeUnknown } }
    private var draftKey: String { selectedConversationID ?? "new-chat" }
    var composer: String {
        get { (chatDrafts[draftKey] ?? state.chatDrafts[draftKey])?.text ?? "" }
        set {
            guard !preparingTransition else { return }
            let key = draftKey
            var value = chatDrafts[key] ?? state.chatDrafts[key] ?? .init(text: "")
            value.text = newValue; value.providerID = selectedProviderID
            chatDrafts[key] = value
            enqueueWrite(key: "chat:" + key) { try await $0.saveChatDraft(key: key, draft: value) }
        }
    }

    var contextNoteID: String {
        get { (chatDrafts[draftKey] ?? state.chatDrafts[draftKey])?.noteID ?? "" }
        set {
            guard !preparingTransition else { return }
            let key = draftKey
            var draft = chatDrafts[key] ?? state.chatDrafts[key] ?? .init(text: "")
            draft.noteID = newValue.isEmpty ? nil : newValue
            chatDrafts[key] = draft
            enqueueWrite(key: "chat:" + key) { try await $0.saveChatDraft(key: key, draft: draft) }
        }
    }
    var canAttachNote: Bool { selectedExecutionWorkspaceID == "central" || selectedExecutionWorkspaceID == localExecution?.descriptor.id }

    func initialize() async {
        guard !booted else { return }; booted = true
        if let store {
            do { try await store.restoreExecutionProjection() } catch { errorMessage = error.localizedDescription }
        }
        if let store { await analytics.configure(store.analytics, transport: transport) }
        await reload()
        defer { initialized = true }
        guard engine == nil else { return }
        do {
            credential = try MobileCredentialVault.load()
            try configureTransport()
            try configureDirectClients()
            if let store { await analytics.configure(store.analytics, transport: transport) }
        } catch { errorMessage = error.localizedDescription }
    }
    func run() async {
        guard !running else { return }; running = true
        defer { running = false }
        await initializeClientWorkspace()
        if credential == nil { section = .settings }
        while !Task.isCancelled {
            await refresh(background: true)
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }
    func initializeClientWorkspace() async {
        requiresLocalExecution = true
        await initialize()
        await enableLocalExecution()
    }
    @discardableResult func pair(_ text: String) async -> Bool {
        guard let store, let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            deviceConnectionsError = "Paste the pairing link from your central database."; return false
        }
        do {
            let payload = try CompanionPairingPayload.parseURL(url)
            let local = await store.snapshot()
            let value = try await HTTPSCompanionTransport.pair(payload, deviceID: local.deviceID,
                deviceName: Host.current().localizedName ?? "Woven Matter Mac", metadata: CompanionMacPairingController.metadata)
            try await acceptPairing(endpoint: value.endpoint, response: .init(workspaceID: value.workspaceID, deviceID: value.deviceID, credential: value.token))
            return true
        } catch { deviceConnectionsError = error.localizedDescription; return false }
    }
    func acceptPairing(endpoint: URL, response: CompanionPairResponse) async throws {
        guard let store else { throw MobileStore.Failure.incompatibleStore }
        guard response.protocolVersion == CompanionProtocol.version, response.deviceID == state.deviceID else {
            throw MobileConnectionError.invalidResponse
        }
        let value = MobileCredential(endpoint: endpoint, workspaceID: response.workspaceID, deviceID: response.deviceID, token: response.credential)
        _ = try HTTPSCompanionTransport(credential: value)
        try await store.bindWorkspace(response.workspaceID)
        try saveCentralCredential(value)
        connectionGeneration = UUID(); credential = value
        try configureTransport(); pairingText = ""
        await refresh()
    }
    func disconnectCentralLibrary() async {
        guard !preparingTransition else { return }
        do {
            try await flushLocalWrites()
            try clearCentralCredential()
            devicePairing.cancelRequest(); devicePairing.stopPairingMode()
            connectionGeneration = UUID()
            let previousEngine = engine
            credential = nil; engine = nil; transport = nil; connectedDevices = []
            let remoteIDs = Set(directClients.keys).union(journal.workspaces.keys)
                .subtracting([localExecution?.descriptor.id ?? state.deviceID])
            for id in remoteIDs {
                directClients.removeValue(forKey: id); directOnline.remove(id)
                directProviders.removeValue(forKey: id); directPending.removeValue(forKey: id)
            }
            await previousEngine?.cancelSynchronization()
            for id in remoteIDs { try clearWorkspaceCredential(id) }
            if sharingLocalExecution { await stopLocalSharing() }
            centralProviders = []; centralPending = []; online = false; status = "Not connected"
            publishedManagement = nil
            updateExecutionPresentation()
            await reload()
        } catch { deviceConnectionsError = error.localizedDescription }
    }
    private func configureTransport() throws {
        guard let credential, let store else { return }
        guard credential.deviceID == state.deviceID else {
            throw CompanionAPIError(code: "device_identity_changed", message: "Pair this Mac with the central database again. Its local replica has a different device identity.")
        }
        let transport = try HTTPSCompanionTransport(credential: credential)
        self.transport = transport; engine = MobileSyncEngine(store: store, transport: transport)
    }
    func configureUpdateAnalytics(_ analytics: ProductAnalyticsModel) async {
        if let store { await analytics.configure(client: store.analytics) }
    }
    func reload() async {
        await analytics.refresh()
        calendarRevision &+= 1
        if let store {
            state = await store.snapshot(); journal = await store.journal.snapshot(); artifacts = await store.artifacts.manifests().filter { !$0.deleted }
            let generation = connectionGeneration
            let value: MobileSynchronizationStatus
            if let engine { value = await engine.synchronizationStatus() }
            else { value = await MobileSyncEngine.localSynchronizationStatus(store: store) }
            if generation == connectionGeneration { synchronization = value }
        }
    }
    func attachExecutionWorkspace(_ workspace: CompanionExecutionWorkspace, transport: any ExecutionWorkspaceTransport) async throws {
        guard let store else { throw MobileStore.Failure.incompatibleStore }
        let publisher = workspace.executionDeviceID ?? (workspace.kind == .linux ? nil : workspace.ownerDeviceID)
        try await store.journal.upsertWorkspace(workspace, pending: publisher == (await store.snapshot()).deviceID)
        directClients[workspace.id] = WorkspaceClient(store: store, workspaceID: workspace.id, transport: transport)
        await reload()
    }
    func artifactURL(_ artifact: CompanionArtifactManifest) async throws -> URL {
        let local: URL
        if let cached = await store?.artifacts.localURL(id: artifact.id) { local = cached }
        else if let engine { local = try await engine.ensureArtifactCached(artifact.id) }
        else { throw CompanionAPIError(code: "not_downloaded", message: "Reconnect to download this saved artifact.") }
        let directory = FileManager.default.temporaryDirectory.appending(path: "WovenMatterClientPreview/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let title = URL(fileURLWithPath: artifact.title).lastPathComponent
        let url = directory.appending(path: title.isEmpty || title == "." || title == ".." ? "Artifact" : title)
        try FileManager.default.copyItem(at: local, to: url)
        return url
    }
    func keepArtifactOffline(_ id: String) async throws {
        try await store?.artifacts.setPinned(id, true)
        if let engine { try await engine.keepArtifactOffline(id) }
        await reload()
    }
    func keepConversationOffline(_ id: String) async throws {
        try await store?.setTranscriptPinned(id, true)
        if let engine { try await engine.keepTranscriptOffline(id) }
        await reload()
    }
    private var executionDirectory: URL {
        if let executionDirectoryOverride { return executionDirectoryOverride }
        let root = CompanionTestWorkspace.supportDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: WovenMatterWorkspacePaths.folderName)
        return root.appending(path: "LibraryClient/Execution/" + state.deviceID)
    }
    func enableLocalExecution() async {
        guard !preparingTransition, !localExecutionBusy, localExecution == nil, state.workspaceID != nil, let store else { return }
        localExecutionBusy = true; defer { localExecutionBusy = false }
        do {
            let workspace = try await makeLocalExecution(executionDirectory, store)
            try await attachExecutionWorkspace(workspace.descriptor, transport: workspace)
            localExecution = workspace
            if preferences.object(forKey: Self.localSharingKey) as? Bool ?? true { await startLocalSharing() }
            await selectExecutionWorkspace(workspace.descriptor.id)
        } catch { errorMessage = error.localizedDescription }
    }
    func startLocalSharing() async {
        guard !preparingTransition, !localSharingBusy, let localExecution, !sharingLocalExecution, let store else { return }
        localSharingBusy = true; defer { localSharingBusy = false }
        deviceConnectionsError = nil
        do {
            let host = localHost ?? SecondaryMacExecutionHost(workspace: localExecution, directory: executionDirectory)
            localHost = host
            let previousPort = journal.workspaces[localExecution.descriptor.id]?.endpoint?.port
            try await host.start(preferredHTTPSPort: previousPort)
            guard !preparingTransition else { throw CancellationError() }
            sharingLocalExecution = true
            var descriptor = localExecution.descriptor
            descriptor.revision = journal.workspaces[descriptor.id]?.revision ?? 0
            try await store.journal.upsertWorkspace(descriptor)
            preferences.set(true, forKey: Self.localSharingKey)
            await refresh()
        } catch {
            localHost?.stop(); try? await localHost?.waitUntilStopped()
            deviceConnectionsError = error.localizedDescription
        }
    }
    func stopLocalSharing() async {
        guard !localSharingBusy else { return }
        localSharingBusy = true; defer { localSharingBusy = false }
        localHost?.stop()
        do { try await localHost?.waitUntilStopped() } catch { errorMessage = error.localizedDescription; return }
        sharingLocalExecution = false; publishedManagement = nil
        preferences.set(false, forKey: Self.localSharingKey)
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
        guard !sending, !localExecutionBusy, !localSharingBusy else {
            throw CompanionAPIError(code: "operation_in_progress", message: "Wait for the current client operation to finish before restarting or quitting.")
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
    func prepareForQuit() async throws { try await prepareForRoleChange() }
    private func configureDirectClients() throws {
        guard credential != nil, let store else { return }
        for workspace in executionWorkspaces where directClients[workspace.id] == nil {
            if let credential = try WorkspaceCredentialVault.load(workspaceID: workspace.id) {
                guard credential.deviceID == state.deviceID, credential.libraryID == state.workspaceID else { continue }
                let connection = try HTTPSExecutionWorkspaceTransport(credential: credential)
                directClients[workspace.id] = WorkspaceClient(store: store, workspaceID: workspace.id, transport: connection)
            }
        }
    }
    func enableDirectAccess(_ workspaceID: String) async {
        guard let transport else { return }
        let generation = connectionGeneration
        do {
            let value = try await transport.executionCredential(workspaceID: workspaceID)
            guard generation == connectionGeneration else { return }
            try WorkspaceCredentialVault.save(value)
            try configureDirectClients()
            selectedExecutionWorkspaceID = workspaceID
            await selectExecutionWorkspace(workspaceID)
        } catch { errorMessage = error.localizedDescription }
    }
    func selectExecutionWorkspace(_ id: String) async {
        selectedExecutionWorkspaceID = id
        selectedConversationID = nil; selectedProviderID = ""
        await refreshDirectWorkspace()
        updateExecutionPresentation()
    }
    private func updateExecutionPresentation() {
        providers = selectedExecutionWorkspaceID == "central" ? centralProviders : (directProviders[selectedExecutionWorkspaceID] ?? [])
        pending = centralPending + directPending.values.flatMap { $0 }
        if !providers.contains(where: { $0.id == selectedProviderID }) { selectedProviderID = providers.first(where: \.available)?.id ?? "" }
    }
    private func refreshDirectWorkspace(_ requestedID: String? = nil) async {
        let workspaceID = requestedID ?? selectedExecutionWorkspaceID
        guard let client = directClients[workspaceID] else { return }
        do {
            try await client.refresh()
            let receivedProviders = try await client.providers()
            let receivedPending = try await client.pending()
            guard directClients[workspaceID] === client else { return }
            directProviders[workspaceID] = receivedProviders
            directPending[workspaceID] = receivedPending
            if let id = selectedConversationID, executionOwner(for: id) == workspaceID {
                _ = try await client.refreshTranscript(id)
                sessionProviders[id] = try? await client.capabilities(id)
            }
            guard directClients[workspaceID] === client else { return }
            directOnline.insert(workspaceID); directFailures[workspaceID] = 0
            let active = state.conversations.values.contains { executionOwner(for: $0.id) == workspaceID && $0.activeRunID != nil }
            nextDirectRefresh[workspaceID] = Date().addingTimeInterval(workspaceID == localExecution?.descriptor.id || active ? 2 : 15)
        } catch {
            guard directClients[workspaceID] === client else { return }
            directOnline.remove(workspaceID)
            if case MobileConnectionError.http(let status, _) = error, status == 401 || status == 403,
               workspaceID != localExecution?.descriptor.id {
                directClients[workspaceID] = nil; directProviders[workspaceID] = nil; directPending[workspaceID] = nil
                do { try clearWorkspaceCredential(workspaceID) } catch { deviceConnectionsError = error.localizedDescription }
            }
            let failures = min((directFailures[workspaceID] ?? 0) + 1, 5); directFailures[workspaceID] = failures
            nextDirectRefresh[workspaceID] = Date().addingTimeInterval(min(60, pow(2, Double(failures))))
        }
        await reload(); updateExecutionPresentation()
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
        refreshing = true; defer { refreshing = false }
        async let directRefresh: Void = refreshAllExecutionWorkspaces(background: background)
        guard let engine, !background || nextCentralRefresh <= Date() else { await directRefresh; return }
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
            let receivedProviders = try await engine.providers()
            let receivedPending = try await engine.pending()
            try await engine.recoverCommandReceipts()
            if let id = selectedConversationID, executionOwner(for: id) == nil {
                try await engine.refreshTranscript(id)
                sessionProviders[id] = try? await transport?.capabilities(id)
            }
            guard connectionGeneration == expectedConnection else { await directRefresh; return }
            centralProviders = receivedProviders; centralPending = receivedPending
            online = true; status = "Connected"
            if nextRosterRefresh <= Date(), let transport {
                let roster = try? await transport.deviceConnections()
                guard connectionGeneration == expectedConnection else { await directRefresh; return }
                if let roster { connectedDevices = roster }
                nextRosterRefresh = Date().addingTimeInterval(60)
            }
            try configureDirectClients()
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
        nextCentralRefresh = Date().addingTimeInterval(online ? (hasActiveRuns ? 2 : 15) : min(60, pow(2, Double(centralFailures))))
        await directRefresh
        await reload(); updateExecutionPresentation()
    }
    func flushLocalWrites() async throws {
        await writeTask?.value
        if let failure = writeFailures.values.first { throw CompanionAPIError(code: "local_write_failed", message: failure) }
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
    func editNote(_ note: CompanionNote, title: String? = nil, content: String? = nil, folderID: String? = nil) {
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
    func createNote(kind: NoteArtifactKind = .note) async {
        guard !preparingTransition, let store else { return }
        do {
            let content = try NoteDocument(kind: kind).encoded()
            let note = try await store.createNote(folderID: selectedFolderID, title: "Untitled " + kind.displayName, content: content)
            await analytics.record(.active)
            await engine?.scheduleSynchronization(); await reload(); selectedNoteID = note.id; section = .notes
        } catch { errorMessage = error.localizedDescription }
    }
    func createFolder(_ name: String) async {
        guard !preparingTransition, let store, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        do { selectedFolderID = try await store.createFolder(name: name).id; await analytics.record(.active); await engine?.scheduleSynchronization(); await reload(); section = .folders }
        catch { errorMessage = error.localizedDescription }
    }
    func selectNote(_ id: String) async {
        selectedNoteID = id; section = .notes
        await store?.protectOpenNote(id)
        guard let transport, state.uncachedNoteIDs.contains(id) else { return }
        do { try await store?.cacheNote(transport.note(id)); await reload() }
        catch { errorMessage = "This note is not saved on this Mac yet. Reconnect to download it." }
    }
    func selectConversation(_ id: String?) async {
        selectedConversationID = id; section = .chats
        guard let id else { return }
        selectedExecutionWorkspaceID = executionOwner(for: id) ?? "central"
        updateExecutionPresentation()
        do {
            if let owner = executionOwner(for: id), let client = directClients[owner] {
                _ = try await client.refreshTranscript(id); sessionProviders[id] = try? await client.capabilities(id)
            } else if executionOwner(for: id) == nil {
                try await engine?.refreshTranscript(id); sessionProviders[id] = try? await transport?.capabilities(id)
            }
            await reload()
        }
        catch { /* The persisted transcript remains readable offline. */ }
    }
    func olderMessages() async {
        guard let id = selectedConversationID, let current = transcript, let cursor = current.olderCursor else { return }
        do {
            let page: CompanionTranscript
            if let owner = executionOwner(for: id), let client = directClients[owner] { page = try await client.earlierTranscript(id, before: cursor) }
            else if let engine { page = try await engine.earlierTranscript(id, before: cursor) }
            else { throw MobileConnectionError.offline }
            var combined = olderTranscripts[id] ?? current
            let ids = Set(combined.messages.map(\.id))
            combined.messages = page.messages.filter { !ids.contains($0.id) } + combined.messages
            let activityIDs = Set(combined.activities.map(\.id))
            combined.activities = page.activities.filter { !activityIDs.contains($0.id) } + combined.activities
            combined.olderCursor = page.olderCursor; olderTranscripts[id] = combined
        } catch { errorMessage = error.localizedDescription }
    }
    func send() async {
        guard !sending, canControl, !composer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let text = composer, key = draftKey, workspaceID = selectedExecutionWorkspaceID
        let target = selectedConversationID, runID = activeRunID, provider = activeProvider
        let deviceID = state.deviceID, folderID = selectedFolderID
        let noteID = contextNoteID.isEmpty ? nil : contextNoteID
        sending = true; defer { sending = false }
        do {
            try await flushLocalWrites()
            var noteRevision: Int64?
            if let noteID {
                if workspaceID == "central" { noteRevision = try await canonicalNote(noteID).revision }
                else if workspaceID == localExecution?.descriptor.id {
                    guard let note = state.notes[noteID], state.conflicts[noteID] == nil else { throw MobileStore.Failure.conflictingNote }
                    noteRevision = note.revision
                } else {
                    throw CompanionAPIError(code: "note_context_unavailable", message: "Use the central database route to attach a shared note to this workspace’s agent.")
                }
            }
            if let id = target {
                guard runID == nil || provider?.canSteer == true else {
                    throw CompanionAPIError(code: "steering_unavailable", message: "Wait for this run to finish or stop it before sending another message.")
                }
                let known = uncertainCommands.first { $0.command.conversationID == id && ($0.command.kind == .send || $0.command.kind == .steer) }
                if let known, known.command.text != text || known.command.noteID != noteID {
                    throw CompanionAPIError(code: "pending_command", message: "Resolve the unconfirmed request from Home before sending different input.")
                }
                let command = known?.command ?? CompanionCommand(deviceID: deviceID, kind: runID == nil ? .send : .steer,
                    conversationID: id, runID: runID, text: text, noteID: noteID, noteRevision: noteRevision)
                try requireAccepted(await submit(command, workspaceID: workspaceID))
            } else {
                guard let provider, provider.available, provider.canStart else { return }
                let pending = pendingLaunches.first { ($0.create.workspaceID ?? $0.create.routeID ?? "central") == workspaceID }
                if let pending, pending.initialSend.text != text || pending.initialSend.noteID != noteID {
                    throw CompanionAPIError(code: "pending_launch", message: "Continue the saved new-chat request from Home before starting a different one.")
                }
                let conversationID = pending?.create.conversationID ?? UUID().uuidString.lowercased()
                let launch = pending ?? MobileLaunchRecord(
                    create: .init(deviceID: deviceID, kind: .createSession, conversationID: conversationID, providerID: provider.id,
                        folderID: folderID, workspaceID: workspaceID == "central" ? nil : workspaceID),
                    initialSend: .init(deviceID: deviceID, kind: .send, conversationID: conversationID, text: text, noteID: noteID, noteRevision: noteRevision))
                let result = try await launchConversation(launch)
                guard result.accepted else {
                    throw CompanionAPIError(code: "pending_launch", message: result.sendReceipt?.message ?? result.createReceipt?.message ?? "The start request is saved. Check its receipt before continuing.")
                }
                if selectedConversationID == target, selectedExecutionWorkspaceID == workspaceID { selectedConversationID = conversationID }
            }
            if chatDrafts[key]?.text == text || chatDrafts[key] == nil {
                try await store?.saveChatDraft(key: key, draft: .init(text: "")); chatDrafts[key] = nil
            }
            await refresh()
        } catch { errorMessage = error.localizedDescription; await reload() }
    }
    private func launchConversation(_ requested: MobileLaunchRecord) async throws -> MobileLaunchRecord {
        guard !preparingTransition else { throw CompanionAPIError(code: "stopping", message: "This client is restarting or quitting.") }
        let owner = requested.create.workspaceID ?? requested.create.routeID ?? "central"
        if owner == "central", let engine { return try await engine.startConversation(requested) }
        guard let client = directClients[owner] else { throw MobileConnectionError.offline }
        return try await client.startConversation(requested)
    }
    private func submit(_ command: CompanionCommand, workspaceID: String) async throws -> CompanionCommandReceipt {
        guard !preparingTransition else { throw CompanionAPIError(code: "stopping", message: "This client is restarting or quitting.") }
        if workspaceID == "central", let engine { return try await engine.submit(command) }
        guard let client = directClients[workspaceID] else { throw MobileConnectionError.offline }
        var routed = command; routed.workspaceID = workspaceID
        return try await client.submit(routed)
    }
    func executionOwner(for conversationID: String) -> String? {
        journal.conversationWorkspaceIDs[conversationID]
    }
    func continueLaunch(_ launch: MobileLaunchRecord) async {
        guard !sending else { return }; sending = true; defer { sending = false }
        do {
            let result = try await launchConversation(launch)
            if result.accepted {
                selectedExecutionWorkspaceID = launch.create.workspaceID ?? launch.create.routeID ?? "central"
                selectedConversationID = result.createReceipt?.conversationID
                let draft = chatDrafts["new-chat"] ?? state.chatDrafts["new-chat"]
                if draft?.text == launch.initialSend.text {
                    try await store?.saveChatDraft(key: "new-chat", draft: .init(text: "")); chatDrafts["new-chat"] = nil
                }
            }
            await refresh()
        } catch { errorMessage = error.localizedDescription; await reload() }
    }
    func retryCommand(_ command: CompanionCommand) async {
        let owner = command.workspaceID ?? command.conversationID.flatMap { executionOwner(for: $0) } ?? "central"
        do { try requireAccepted(await submit(command, workspaceID: owner)); await refresh() }
        catch { errorMessage = error.localizedDescription }
    }
    func stop() async {
        guard let id = selectedConversationID, let run = activeRunID else { return }
        await retryCommand(.init(deviceID: state.deviceID, kind: .stop, conversationID: id, runID: run))
    }
    func respond(_ interaction: CompanionPendingInteraction, response: CompanionInteractionResponse) async {
        await retryCommand(.init(deviceID: state.deviceID, kind: .respond, conversationID: interaction.conversationID,
            runID: interaction.runID, interactionID: interaction.id, response: response))
    }
    func calendarConflicts() async -> [String: MobileCalendarConflict] { await store?.calendar.conflicts() ?? [:] }
    func resolveCalendarConflict(_ id: String, keepLocal: Bool) async {
        guard let calendar = store?.calendar else { return }
        do {
            if keepLocal, let conflict = await calendar.conflicts()[id], conflict.remote?.deleted == true {
                let copyID = UUID().uuidString.lowercased()
                _ = try await calendar.save(id: copyID, expectedRevision: nil, draft: conflict.local.event.draft,
                    ownerDeviceID: conflict.local.ownerDeviceID, requestID: copyID)
                try await calendar.resolveConflict(id: id, keepLocal: false)
            } else { try await calendar.resolveConflict(id: id, keepLocal: keepLocal) }
            await projectLocalCalendar()
            await engine?.scheduleSynchronization(); await reload()
        } catch { errorMessage = error.localizedDescription }
    }
    func workspace(_ read: CompanionWorkspaceRead) async throws -> CompanionWorkspaceResult {
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
    private func projectLocalCalendar() async {
        do { try await localExecution?.reconcileCalendar() }
        catch { errorMessage = "The calendar change was saved locally. " + error.localizedDescription }
    }
    @discardableResult func perform(_ action: CompanionWorkspaceAction) async -> Bool {
        if let store {
            do {
                switch action {
                case .saveCalendar(let id, let revision, let draft):
                    let previous = await store.calendar.record(id: id)
                    let owner = previous?.event.draft.task != nil ? previous?.ownerDeviceID :
                        (draft.task?.workspaceID == localExecution?.descriptor.id && localExecution != nil ? state.deviceID : nil)
                    _ = try await store.calendar.save(id: id, expectedRevision: revision, draft: draft, ownerDeviceID: owner)
                    if action.qualifiesForAnalytics { await analytics.record(.active) }
                    await projectLocalCalendar()
                    await engine?.scheduleSynchronization(); await reload(); return true
                case .deleteCalendar(let id, let revision, let occurrence):
                    try await store.calendar.delete(id: id, expectedRevision: revision, occurrence: occurrence)
                    if action.qualifiesForAnalytics { await analytics.record(.active) }
                    await projectLocalCalendar()
                    await engine?.scheduleSynchronization(); await reload(); return true
                default: break
                }
            } catch { errorMessage = error.localizedDescription; return false }
        }
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
    func linkedData(note: CompanionNote, tableID: String? = nil) async throws -> CompanionLinkedData {
        guard online, let engine else { throw MobileConnectionError.offline }
        let result = try await engine.linkedData(note: note, tableID: tableID)
        guard state.notes[note.id]?.revision == note.revision else { throw CancellationError() }
        return result
    }
    func canonicalNote(_ id: String) async throws -> CompanionNote {
        guard let engine, let store else { throw MobileStore.Failure.missingNote }
        try await flushLocalWrites()
        try await engine.synchronize(); await reload(); return try await store.canonicalNote(id: id)
    }
    func preserveConflict(_ id: String) async {
        guard let store else { return }
        do { selectedNoteID = try await store.preserveConflictAsCopy(id: id).id; await engine?.scheduleSynchronization(); await reload(); section = .notes }
        catch { errorMessage = error.localizedDescription }
    }
    func exportFile(_ read: CompanionWorkspaceRead) async throws -> URL {
        guard case .file(let file) = try await workspace(read) else { throw MobileConnectionError.invalidResponse }
        let directory = FileManager.default.temporaryDirectory.appending(path: "WovenMatterClientPreview/" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = URL(fileURLWithPath: file.name).lastPathComponent
        let output = directory.appending(path: name.isEmpty || name == "." || name == ".." ? "Artifact" : name)
        try file.data.write(to: output, options: .atomic)
        return output
    }
    private func requireAccepted(_ receipt: CompanionCommandReceipt) throws {
        guard receipt.status == .accepted || receipt.status == .completed else {
            throw CompanionAPIError(code: "command_pending", message: receipt.message ?? "The command outcome is not confirmed. Check its receipt before retrying.")
        }
    }
}
