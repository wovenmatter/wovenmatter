import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

struct PendingLocalACPPermission: Equatable, Identifiable {
    let id: UUID
    let conversationID: String
    let title: String
    let options: [LocalACPPermissionOption]
}

struct PendingLocalACPInteraction: Equatable, Identifiable {
    let id: UUID
    let conversationID: String
    let request: LocalACPInteractionRequest
}

struct PreparedLocalACPRuntimeInstall: Equatable, Identifiable {
    let definition: LocalACPRuntimeDefinition
    let preview: LocalACPInstallerPreview

    var id: AgentRuntimeKind { definition.runtimeKind }
}

struct ConversationTitleGenerationSettings: Equatable {
    var isEnabled: Bool
    var model: String
    var thinking: String
}

struct DashboardWorkspaceOverview: Equatable, Sendable {
    let folders: [WorkspaceFolderRecord]
    let conversations: [WorkspaceConversationRecord]
    let notes: [WorkspaceNoteRecord]

    init(_ workspace: WorkspaceSnapshot) {
        folders = workspace.folders
        conversations = workspace.conversations
        notes = workspace.notes
    }
}

@MainActor
@Observable
final class ApplicationModel {
    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    private(set) var state: State = .starting
    private(set) var localCLIAgents: [WorkspaceAgent] = []
    private(set) var buzzWorkspaceAgents: [WorkspaceAgent] = []
    private(set) var remoteWorkspaceAgents: [WorkspaceAgent] = []
    let remoteWorkspaces: RemoteWorkspacesModel
    private(set) var buzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
        links: [],
        enrollments: []
    )
    private(set) var buzzWorkspaceCandidates: [
        UUID: [BuzzWorkspaceAgentCandidate]
    ] = [:]
    private(set) var launchableBuzzWorkspaceEnrollmentIDs: Set<UUID> = []
    private(set) var checkingBuzzWorkspaceLinkIDs: Set<UUID> = []
    private(set) var mutatingBuzzWorkspaceEnrollmentIDs: Set<UUID> = []
    private(set) var buzzWorkspaceError: String?
    var openCode: OpenCodeModel?
    private(set) var remoteOpenCodes: [UUID: OpenCodeModel] = [:]
    private var remoteOpenCodeSyncGeneration = UUID()
    var openCodeInstances: [OpenCodeModel] { [openCode].compactMap { $0 } + Array(remoteOpenCodes.values) }

    func openCodeModel(for conversationID: String) -> OpenCodeModel? {
        openCodeInstances.first { $0.links[conversationID] != nil }
    }

    func synchronizeRemoteOpenCodeInstances() async {
        let generation = UUID()
        remoteOpenCodeSyncGeneration = generation
        guard let dashboardStore, let ownerDeviceID = try? await dashboardStore.dashboardDeviceID() else { return }
        guard remoteOpenCodeSyncGeneration == generation else { return }
        let configurations = remoteWorkspaces.workspaces
        let eligibleIDs = Set(configurations.map(\.id))
        for id in Array(remoteOpenCodes.keys) where !eligibleIDs.contains(id) {
            if let removed = remoteOpenCodes.removeValue(forKey: id) { await removed.suspendConnection() }
            guard remoteOpenCodeSyncGeneration == generation else { return }
        }
        for configuration in configurations {
            guard remoteOpenCodeSyncGeneration == generation,
                  remoteWorkspaces.configuration(id: configuration.id) == configuration else { return }
            if let existing = remoteOpenCodes[configuration.id], existing.remoteConfiguration != configuration {
                remoteOpenCodes[configuration.id] = nil
                await existing.suspendConnection()
                guard remoteOpenCodeSyncGeneration == generation,
                      remoteWorkspaces.configuration(id: configuration.id) == configuration else { return }
            }
            let instance: OpenCodeModel
            if let existing = remoteOpenCodes[configuration.id] { instance = existing }
            else {
                instance = OpenCodeModel(store: dashboardStore, ownerDeviceID: ownerDeviceID, defaults: applicationDefaults,
                    remoteConfiguration: configuration, remoteWorkspaces: remoteWorkspaces)
                instance.applyInitialSessionTools = { [weak self] id, tools in
                    guard let apply = self?.applyInitialSessionToolIDs else { throw ApplicationModelError.unavailableSessionTools }
                    try apply(id, tools)
                }
                remoteOpenCodes[configuration.id] = instance
                instance.onChange = { [weak self, weak instance] id in
                    guard let self, let instance, self.remoteOpenCodes[configuration.id] === instance else { return }
                    if instance.snapshots[id]?.active == true { self.localRunningConversationIDs.insert(id) }
                    else { self.localRunningConversationIDs.remove(id) }
                    await self.refreshWorkspaceIfChanged()
                    await self.refreshConversation(id: id)
                }
            }
            if remoteWorkspaces.isRuntimeEnabled(.opencode, in: configuration) {
                if !instance.isReady && !instance.isConnecting && instance.canRestoreAutomatically { await instance.restore() }
            } else { await instance.suspendConnection() }
        }
    }

    func prepareOpenCodeInstancesToQuit() async throws {
        for instance in openCodeInstances { try await instance.prepareToQuit() }
    }

    func restoreOpenCodeInstances() async {
        for instance in openCodeInstances { await instance.restore() }
        await synchronizeRemoteOpenCodeInstances()
    }

    func openCodeSettingsAgent(workspaceID: UUID?) async throws -> WorkspaceAgent {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        if let workspaceID {
            guard let configuration = remoteWorkspaces.configuration(id: workspaceID) else { throw ApplicationModelError.remoteHarnessUnavailable }
            _ = try await dashboardStore.ensureRemoteHarnessAgent(runtimeKind: .opencode,
                remoteWorkspaceID: workspaceID, remoteWorkspaceName: configuration.name)
            await refreshWorkspace()
        }
        guard let agent = try dashboardStore.database.dashboardAgents().first(where: {
            $0.runtimeKind == .opencode && (workspaceID == nil ? $0.governingPlane == .wovenmatterMacOS : $0.runtimeDeviceID == workspaceID)
        }) else { throw ApplicationModelError.localACPRuntimeUnavailable }
        return agent
    }

    func renameOpenCodeAgent(agentID: UUID, displayName: String) async throws {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        try dashboardStore.database.renameOpenCodeAgent(id: agentID, displayName: displayName)
        await refreshWorkspace()
    }

    func remoteOpenClawAgentID(for configuration: RemoteWorkspaceConfiguration) async throws -> UUID {
        guard let dashboardStore, remoteWorkspaces.configuration(id: configuration.id) == configuration else {
            throw ApplicationModelError.remoteHarnessUnavailable
        }
        let id = try await dashboardStore.ensureRemoteHarnessAgent(runtimeKind: .openclaw,
            remoteWorkspaceID: configuration.id, remoteWorkspaceName: configuration.name)
        await refreshWorkspace()
        return id
    }
    private(set) var openClawGatewayLinks: [OpenClawGatewayLink] = []
    private(set) var openClawGatewayErrors: [UUID: String] = [:]
    private(set) var openClawGatewayNotices: [UUID: String] = [:]
    private(set) var openClawGatewayOperationAgentIDs: Set<UUID> = []
    private(set) var openClawGatewayOperationStatuses: [
        UUID: OpenClawGatewayConnectionStatus
    ] = [:]
    private(set) var pendingOpenClawGatewayAgentID: UUID?
    private(set) var openClawHeartbeatConfigurations: [UUID: OpenClawHeartbeatConfiguration] = [:]
    private(set) var openClawHeartbeatMessages: [UUID: String] = [:]
    private(set) var openClawHeartbeatErrorAgentIDs: Set<UUID> = []
    private(set) var openClawHeartbeatSavingAgentIDs: Set<UUID> = []
    private(set) var openClawGatewaySessionMetadata: [String: LocalACPSessionMetadata] = [:]
    private(set) var openClawCronJobs: [OpenClawCronJob] = []
    private(set) var openClawCronRuns: [OpenClawCronRun] = []
    private(set) var isRefreshingOpenClawCron = false
    private(set) var openClawCronError: String?
    private(set) var openClawCronBusy = false
    private(set) var openClawResultRoutes: [UUID: [String: String]] = [:]
    private var lastOpenClawCronRefresh = Date.distantPast
    private var openClawGatewayConversationIDs: Set<String> = []
    private var buzzBoundLocalACPConversationIDs: Set<String> = []
    private(set) var workspaceOverview: DashboardWorkspaceOverview?
    private(set) var calendarItems: [WorkspaceCalendarItemRecord] = []
    private(set) var workspaceRevision: Int64 = 0
    private(set) var workspaceListRevision: Int64 = 0
    private(set) var macSurfaceProfile: SurfaceProfile?
    private(set) var workspaceError: String?
    private(set) var folderMutationError: String?
    private(set) var noteMutationError: String?
    var agentTools: WorkspaceAgentToolsModel?
    var activeSessionLimitPresented = false
    var pendingSessionAccess: [WorkspaceCoordinationAccessRequest] = []
    var sessionAccessError: String?
    @ObservationIgnored var toolRuntimeTask: Task<Void, Never>?
    @ObservationIgnored var toolCreationTasks: [String: Task<WovenMatterToolResponse, any Error>] = [:]
    @ObservationIgnored private var toolSessionAdmission = WorkspaceSessionAdmission()
    private(set) var calendarMutationError: String?
    private(set) var isCreatingCalendarItem = false
    private(set) var noteDrafts: [String: DashboardNoteDraft] = [:]
    var pendingComposerPrefills: [String: String] = [:]
    private(set) var localACPSessionMetadata: [
        String: LocalACPSessionMetadata
    ] = [:]
    private var localACPSessionRefreshLifecycle = LocalACPSessionRefreshLifecycle()
    var loadingLocalACPSessionIDs: Set<String> {
        localACPSessionRefreshLifecycle.loadingConversationIDs
    }
    private(set) var updatingLocalACPSessionIDs: Set<String> = []
    private(set) var localRunError: String?
    private(set) var localACPRuntimeAvailability: [LocalACPRuntimeAvailability] = []
    private(set) var localACPDatabaseReadyRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var localACPAgentReconciliationError: String?
    private(set) var checkingLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var localACPWorkspaceAvailability = LocalACPWorkspaceAvailability(
        state: .setupRequired,
        detail: "Set up the shared direct workspace before starting a chat.",
        rootPath: nil,
        repositoriesPath: nil,
        usesExternalRepositories: false
    )
    private(set) var databasesSnapshot = DashboardDatabasesSnapshot.empty
    private(set) var isRefreshingDatabases = false
    private(set) var databaseError: String?
    private(set) var updatingDatabasePreferenceIDs: Set<String> = []
    @ObservationIgnored
    private var databaseRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored
    private var databaseRefreshRequestedWhileRunning = false
    private(set) var titleGenerationSettings = ConversationTitleGenerationSettings(
        isEnabled: true,
        model: "",
        thinking: ""
    )
    private(set) var titleGenerationCapabilities: CodexTitleGenerationCapabilities?
    private(set) var titleGenerationStatus = "Waiting for Codex"
    private(set) var isRefreshingTitleGenerationCapabilities = false
    private(set) var runtimeInventories: [AgentRuntimeKind: RuntimeInventory] = [:]
    private(set) var runtimeFailures: [AgentRuntimeKind: Int] = [:]
    private(set) var runtimeFailureDetails: [AgentRuntimeKind: String] = [:]
    private(set) var checkingRuntimeInventory = false
    private(set) var checkingRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var checkedRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var updatingRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var failedRuntimeUpdateKinds: Set<AgentRuntimeKind> = []
    private var runtimeInventoryGeneration: UInt64 = 0
    private(set) var installingLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var preparedLocalACPRuntimeInstall:
        PreparedLocalACPRuntimeInstall?
    private(set) var pendingLocalACPPermissions: [PendingLocalACPPermission] = []
    private(set) var pendingLocalACPInteractions: [PendingLocalACPInteraction] = []
    private(set) var localRunningConversationIDs: Set<String> = []
    private(set) var conversationStatesByID: [String: DashboardConversationState] = [:]
    // Usage owns its observable state; these projections preserve the application API.
    private let usage: ApplicationUsageModel
    var localUsage: LocalUsageSnapshot? { usage.localUsage }
    var localUsageError: String? { usage.localUsageError }
    var isRefreshingUsageAnalytics: Bool { usage.isRefreshingUsageAnalytics }
    var isRefreshingUsageLimits: Bool { usage.isRefreshingUsageLimits }
    var isAuthorizingUsageCredential: Bool { usage.isAuthorizingUsageCredential }
    private(set) var isReconnectingSavedCredentials = false
    private(set) var credentialAccessStatus: String?
    var isRefreshingLocalUsage: Bool { usage.isRefreshingLocalUsage }
    var isOpenRouterCredentialConfigured: Bool { usage.isOpenRouterCredentialConfigured }
    var signingInUsageProviders: Set<ProviderKind> { usage.signingInUsageProviders }
    var hasAcknowledgedCredentialAccessDisclosure: Bool { usage.hasAcknowledgedCredentialAccessDisclosure }
    var enabledUsageProviders: Set<ProviderKind> { usage.enabledUsageProviders }
    var codexUsageWorkspaces: [CodexUsageWorkspace] { usage.codexUsageWorkspaces }
    var selectedCodexUsageWorkspaceID: String? { usage.selectedCodexUsageWorkspaceID }
    private var currentUsageRange: UsageTimeRange { usage.currentUsageRange }

    private(set) var enabledLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []
    private(set) var shownLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []

    private(set) var dashboardStore: DashboardStore?
    private var noteWriteBehind: DashboardNoteWriteBehind?
    private var dashboardStoreStarted = false
    private var dashboardStoreStartDeferredForNoteRecovery = false
    private var startupTask: Task<Void, Never>?
    private var conversationChangeTask: Task<Void, Never>?
    private var conversationChangeWorkers: [String: Task<Void, Never>] = [:]
    private var conversationChangeWorkerTokens: [String: UUID] = [:]
    private var pendingConversationChanges: [String: [DashboardConversationChange]] = [:]
    private var terminalRunIDsByConversation: [String: String] = [:]
    private var surfaceProfilePersistenceTask: Task<Void, Never>?
    private var surfaceProfilePersistenceGeneration = 0
    @ObservationIgnored
    private let localACPRuntimeResolver = LocalACPRuntimeResolver()
    @ObservationIgnored
    private let applicationDefaults: UserDefaults
    let sessionSelectionPreferences: SessionSelectionPreferences
    @ObservationIgnored var currentSessionToolIDs: ((String) -> [String]?)?
    @ObservationIgnored var sessionSelectionWorkspaceID: ((String) throws -> String?)?
    @ObservationIgnored var applyInitialSessionToolIDs: ((String, [String]) throws -> Void)?
    @ObservationIgnored var applyingSessionSelectionTasks: [String: Task<Void, any Error>] = [:]
    @ObservationIgnored
    private let localACPRuntimePreferences: LocalACPRuntimePreferences
    @ObservationIgnored
    private let localACPWorkspaceStore: LocalACPWorkspaceConfigurationStore
    @ObservationIgnored
    private let localACPRuntimeInstaller = LocalACPRuntimeInstaller()
    @ObservationIgnored
    private let conversationTitleGenerator = CodexConversationTitleGenerator()
    @ObservationIgnored
    private var localACPLaunchConfigurations: [
        AgentRuntimeKind: LocalACPRuntimeLaunchConfiguration
    ] = [:]
    @ObservationIgnored
    private var localACPRuntimeRefreshGeneration: UInt64 = 0
    @ObservationIgnored
    private var generatingConversationTitleIDs: Set<String> = []
    @ObservationIgnored
    private(set) var localACPWorkspaceLaunchConfiguration:
        LocalACPWorkspaceLaunchConfiguration?
    @ObservationIgnored
    private var localACPPermissionContinuations: [
        UUID: CheckedContinuation<String?, Never>
    ] = [:]
    @ObservationIgnored
    private var localACPInteractionContinuations: [
        UUID: CheckedContinuation<LocalACPInteractionResponse, Never>
    ] = [:]
    private var loggedDashboardRecordCounts: DashboardRecordCounts?
    private var noteRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    private var conversationAccessSequence: UInt64 = 0
    private static let initialConversationMessageLimit = 40
    private static let olderConversationMessageLimit = 40
    private static let maximumRetainedConversationCount = 50
    private static let titleGenerationEnabledDefaultsKey =
        "wovenmatter.title-generation.enabled"
    private static let titleGenerationModelDefaultsKey =
        "wovenmatter.title-generation.model"
    private static let titleGenerationThinkingDefaultsKey =
        "wovenmatter.title-generation.thinking"
    private static let buzzDiscoveryEnabledDefaultsKey =
        "wovenmatter.buzz.discovery-enabled"

    init(
        applicationDefaults: UserDefaults = .standard,
        dashboardStore: DashboardStore? = nil,
        startsAutomatically: Bool? = nil
    ) {
        self.applicationDefaults = applicationDefaults
        self.usage = ApplicationUsageModel(applicationDefaults: applicationDefaults)
        self.sessionSelectionPreferences = SessionSelectionPreferences(defaults: applicationDefaults)
        self.localACPRuntimePreferences = LocalACPRuntimePreferences(
            defaults: applicationDefaults
        )
        self.remoteWorkspaces = RemoteWorkspacesModel(defaults: applicationDefaults)
        self.localACPWorkspaceStore = LocalACPWorkspaceConfigurationStore()
        self.dashboardStore = dashboardStore
        let localACPRuntimePreferenceState = localACPRuntimePreferences.state
        enabledLocalACPRuntimeKinds =
            localACPRuntimePreferenceState.enabledRuntimeKinds
        shownLocalACPRuntimeKinds =
            localACPRuntimePreferenceState.shownRuntimeKinds
        if applicationDefaults.object(
            forKey: Self.titleGenerationEnabledDefaultsKey
        ) == nil {
            applicationDefaults.set(
                true,
                forKey: Self.titleGenerationEnabledDefaultsKey
            )
        }
        titleGenerationSettings = ConversationTitleGenerationSettings(
            isEnabled: applicationDefaults.bool(
                forKey: Self.titleGenerationEnabledDefaultsKey
            ),
            model: applicationDefaults.string(
                forKey: Self.titleGenerationModelDefaultsKey
            ) ?? "",
            thinking: applicationDefaults.string(
                forKey: Self.titleGenerationThinkingDefaultsKey
            ) ?? ""
        )
        let environment = ProcessInfo.processInfo.environment
        let isRunningTests = environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment.keys.contains("XCTestConfigurationFilePath")
        guard startsAutomatically ?? !isRunningTests else { return }
        startupTask = Task { await start() }
    }

    func conversationState(for id: String) -> DashboardConversationState? {
        conversationStatesByID[id]
    }

    func conversationError(for id: String) -> String? {
        conversationStatesByID[id]?.error
    }

    func retry() {
        state = .starting
        startupTask?.cancel()
        startupTask = Task { await start() }
    }

    private func start() async {
        do {
            conversationChangeTask?.cancel()
            for worker in conversationChangeWorkers.values { worker.cancel() }
            conversationChangeWorkers.removeAll()
            conversationChangeWorkerTokens.removeAll()
            pendingConversationChanges.removeAll()
            terminalRunIDsByConversation.removeAll()
            dashboardStoreStarted = false
            dashboardStoreStartDeferredForNoteRecovery = false
            let supportDirectory = try Self.dashboardSupportDirectory()
            NSLog(
                "Woven Matter dashboard database: %@",
                supportDirectory.appending(path: "workspace.sqlite").path
            )
            let dashboardStore = try DashboardStore(supportDirectory: supportDirectory)
            self.dashboardStore = dashboardStore
            try await dashboardStore.prepareLocalWorkspace()
            let openCode = OpenCodeModel(store: dashboardStore, ownerDeviceID: try await dashboardStore.dashboardDeviceID(), defaults: applicationDefaults)
            openCode.applyInitialSessionTools = { [weak self] id, tools in
                guard let apply = self?.applyInitialSessionToolIDs else { throw ApplicationModelError.unavailableSessionTools }
                try apply(id, tools)
            }
            self.openCode = openCode
            openCode.onChange = { [weak self, weak openCode] id in
                guard let self, let openCode else { return }
                if openCode.snapshots[id]?.active == true { self.localRunningConversationIDs.insert(id) }
                else { self.localRunningConversationIDs.remove(id) }
                await self.refreshWorkspaceIfChanged()
                await self.refreshConversation(id: id)
            }
            Task { await openCode.restore() }
            remoteWorkspaces.onRuntimeMaintenanceChanged = { [weak self] in
                await self?.synchronizeRemoteOpenCodeInstances()
            }
            remoteWorkspaces.refreshRuntimeMaintenanceAtStartup()
            await synchronizeRemoteOpenCodeInstances()
            localACPDatabaseReadyRuntimeKinds = Set(
                LocalACPRuntimeCatalog.definitions.map(\.runtimeKind)
            )
            try await loadMacSurfaceProfile(using: dashboardStore)
            let journal = DashboardNoteDraftJournal(
                fileURL: supportDirectory.appending(path: "note-draft-journal.ndjson")
            )
            let recoveredEntries = try journal.latestEntries()
            let writeBehind = DashboardNoteWriteBehind(
                journal: journal,
                update: { [database = dashboardStore.database] entry in
                    try database.persistNoteDraft(
                        id: entry.noteID,
                        title: entry.title,
                        content: entry.content,
                        folderID: entry.folderID,
                        createdAt: entry.createdAt
                    )
                },
                completion: { [weak self] entry, result in
                    Task { @MainActor [weak self] in
                        self?.completeNoteWrite(entry, result: result)
                    }
                }
            )
            noteWriteBehind = writeBehind
            toolRuntimeTask?.cancel()
            agentTools?.stop()
            agentTools = try WorkspaceAgentToolsModel(database: dashboardStore.database,
                sessionHandler: { [weak self] caller, command, request in
                    guard let self else { throw CancellationError() }
                    return try await self.handleSessionTool(callerID: caller, command: command, request: request)
                }, noteHandler: { [weak self] caller, request, requestID in
                    guard let self else { throw CancellationError() }
                    return try await self.handleAgentNote(callerID: caller, request: request, requestID: requestID)
                }, noteRestoreHandler: { [weak self] caller, noteID, versionID, revision, requestID in
                    guard let self else { throw CancellationError() }
                    guard self.flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
                    let response = try dashboardStore.database.restoreNoteAssetVersion(noteID: noteID, versionID: versionID,
                        expectedRevision: revision, callerConversationID: caller, requestID: requestID)
                    await self.adoptNoteEditingResponse(response)
                    return response
                }, usageHandler: { [weak self] command in
                    guard let self else { throw CancellationError() }
                    return try await self.handleAgentUsage(command)
                }, onMutation: { [weak self] in await self?.refreshWorkspace() })
            try dashboardStore.database.recoverToolDeliveries()
            try dashboardStore.database.recoverToolSessionCreations()
            try dashboardStore.database.cancelPendingCoordinationAccess()
            await refreshLocalACPWorkspace()
            await refreshBuzzWorkspaces()
            await refreshOpenClawGateways()
            await restoreOpenClawGatewayLinks()
            await refreshOpenClawCron()
            await refreshWorkspace()
            for entry in recoveredEntries {
                let note = workspaceOverview?.notes.first { $0.id == entry.noteID }
                noteDrafts[entry.noteID] = .recovered(from: entry, source: note)
            }
            do {
                try await writeBehind.replayAndFlush(recoveredEntries)
            } catch {
                dashboardStoreStartDeferredForNoteRecovery = true
                noteMutationError = error.localizedDescription
                for entry in recoveredEntries {
                    noteDrafts[entry.noteID]?.fail(error.localizedDescription)
                }
            }
            recoverPendingRemoteNoteEdits(store: dashboardStore)
            await refreshWorkspace()
            state = .ready
            startAgentToolRuntime()
            startDashboardStoreIfReady()
            Task { [weak self] in
                await self?.refreshDatabases()
            }

            guard !Task.isCancelled else { return }
            refreshLocalACPRuntimesNow()
            refreshRuntimeInventory()
            await refreshWorkspace()
            await refreshLocalUsage(
                range: currentUsageRange,
                refreshLimits: false,
                reason: .startup
            )
        } catch {
            guard !Task.isCancelled else { return }
            state = .failed(error.localizedDescription)
        }
    }


    func persistMacSurfaceProfileFromUserDefaults() {
        guard let current = macSurfaceProfile,
              let deviceID = current.deviceID else { return }
        let next = Self.surfaceProfile(
            deviceID: deviceID,
            id: current.id,
            userID: current.userID,
            localCLIAgentOrder: current.localCLIAgentOrder ?? [],
            revision: current.revision,
            createdAt: current.createdAt
        )
        scheduleMacSurfaceProfilePersistence(next)
    }

    private func scheduleMacSurfaceProfilePersistence(_ next: SurfaceProfile) {
        guard let dashboardStore, let current = macSurfaceProfile else { return }
        guard !Self.sameSurfacePreferences(current, next) else { return }
        macSurfaceProfile = next
        surfaceProfilePersistenceGeneration += 1
        let generation = surfaceProfilePersistenceGeneration
        surfaceProfilePersistenceTask?.cancel()
        surfaceProfilePersistenceTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                let updated = try await dashboardStore.updateMacSurfaceProfile(next)
                guard generation == surfaceProfilePersistenceGeneration else { return }
                macSurfaceProfile = updated
                Self.cacheSurfaceProfile(updated)
            } catch is CancellationError {
                return
            } catch {
                guard generation == surfaceProfilePersistenceGeneration else { return }
                macSurfaceProfile = current
                NSLog("Could not persist Mac surface profile: %@", error.localizedDescription)
            }
        }
    }

    private func loadMacSurfaceProfile(using store: DashboardStore) async throws {
        let deviceID = try await store.dashboardDeviceID()
        let bootstrap = Self.surfaceProfile(deviceID: deviceID)
        let profile = try await store.macSurfaceProfile(bootstrap: bootstrap)
        macSurfaceProfile = profile
        Self.cacheSurfaceProfile(profile)
    }

    private static func surfaceProfile(
        deviceID: UUID,
        id: String? = nil,
        userID: String = "local-operator",
        localCLIAgentOrder: [UUID] = [],
        revision: Int64 = 1,
        createdAt: Date = Date()
    ) -> SurfaceProfile {
        let defaults = UserDefaults.standard
        func string(_ key: String, fallback: String) -> String {
            defaults.string(forKey: key) ?? fallback
        }
        func bool(_ key: String, fallback: Bool) -> Bool {
            defaults.object(forKey: key) as? Bool ?? fallback
        }
        func double(_ key: String, fallback: Double) -> Double {
            defaults.object(forKey: key) as? Double ?? fallback
        }
        return SurfaceProfile(
            id: id ?? SurfaceProfile.macID(deviceID: deviceID),
            userID: userID,
            surface: .mac,
            deviceID: deviceID,
            theme: string(DashboardTheme.storageKey, fallback: DashboardTheme.green.rawValue),
            sidebarStyle: string(
                DashboardSidebarStyle.storageKey,
                fallback: DashboardSidebarStyle.defaultStyle.rawValue
            ),
            singleSidebarSide: string(
                DashboardSidebarSide.storageKey,
                fallback: DashboardSidebarSide.defaultSide.rawValue
            ),
            leftRailVisible: bool("wovenmatter.dashboard.left-rail", fallback: true),
            rightRailVisible: bool("wovenmatter.dashboard.right-rail", fallback: true),
            singleRailVisible: bool("wovenmatter.dashboard.single-rail", fallback: true),
            chatWidthPercent: double(
                "wovenmatter.dashboard.chat-width-percent",
                fallback: 58
            ),
            noteOnLeft: bool("wovenmatter.dashboard.note-on-left", fallback: false),
            workspaceMode: string(
                "wovenmatter.dashboard.workspace-mode",
                fallback: "chats"
            ),
            localCLIAgentOrder: localCLIAgentOrder,
            revision: revision,
            createdAt: createdAt,
            updatedAt: Date()
        )
    }

    private static func cacheSurfaceProfile(_ profile: SurfaceProfile) {
        let defaults = UserDefaults.standard
        defaults.set(profile.theme, forKey: DashboardTheme.storageKey)
        defaults.set(profile.sidebarStyle, forKey: DashboardSidebarStyle.storageKey)
        defaults.set(profile.singleSidebarSide, forKey: DashboardSidebarSide.storageKey)
        defaults.set(profile.leftRailVisible, forKey: "wovenmatter.dashboard.left-rail")
        defaults.set(profile.rightRailVisible, forKey: "wovenmatter.dashboard.right-rail")
        defaults.set(profile.singleRailVisible, forKey: "wovenmatter.dashboard.single-rail")
        defaults.set(profile.chatWidthPercent, forKey: "wovenmatter.dashboard.chat-width-percent")
        defaults.set(profile.noteOnLeft, forKey: "wovenmatter.dashboard.note-on-left")
        defaults.set(profile.workspaceMode, forKey: "wovenmatter.dashboard.workspace-mode")
    }

    private static func sameSurfacePreferences(
        _ lhs: SurfaceProfile,
        _ rhs: SurfaceProfile
    ) -> Bool {
        lhs.theme == rhs.theme
            && lhs.sidebarStyle == rhs.sidebarStyle
            && lhs.singleSidebarSide == rhs.singleSidebarSide
            && lhs.leftRailVisible == rhs.leftRailVisible
            && lhs.rightRailVisible == rhs.rightRailVisible
            && lhs.singleRailVisible == rhs.singleRailVisible
            && lhs.chatWidthPercent == rhs.chatWidthPercent
            && lhs.noteOnLeft == rhs.noteOnLeft
            && lhs.workspaceMode == rhs.workspaceMode
            && (lhs.localCLIAgentOrder ?? []) == (rhs.localCLIAgentOrder ?? [])
    }

    var orderedLocalCLIAgents: [WorkspaceAgent] {
        Self.orderLocalCLIAgents(
            localCLIAgents,
            preferredOrder: macSurfaceProfile?.localCLIAgentOrder ?? []
        )
    }

    var visibleOrderedLocalCLIAgents: [WorkspaceAgent] {
        let visibleRuntimeKinds = LocalACPRuntimePreferences.visibleRuntimeKinds(
            in: orderedLocalCLIAgents.map(\.runtimeKind),
            shownRuntimeKinds: shownLocalACPRuntimeKinds
        )
        let visibleRuntimeKindSet = Set(visibleRuntimeKinds)
        return orderedLocalCLIAgents.filter {
            visibleRuntimeKindSet.contains($0.runtimeKind)
        }
    }

    var orderedLocalACPRuntimeDefinitions: [LocalACPRuntimeDefinition] {
        Self.orderLocalACPRuntimeDefinitions(
            LocalACPRuntimeCatalog.definitions,
            agents: localCLIAgents,
            preferredOrder: macSurfaceProfile?.localCLIAgentOrder ?? []
        )
    }

    static func orderLocalACPRuntimeDefinitions(
        _ definitions: [LocalACPRuntimeDefinition],
        agents: [WorkspaceAgent],
        preferredOrder: [UUID]
    ) -> [LocalACPRuntimeDefinition] {
        let preferredRanks = Dictionary(
            uniqueKeysWithValues: preferredOrder.enumerated().map { ($0.element, $0.offset) }
        )
        var preferredRankByRuntime: [AgentRuntimeKind: Int] = [:]
        for agent in agents {
            guard let rank = preferredRanks[agent.id] else { continue }
            preferredRankByRuntime[agent.runtimeKind] = min(
                preferredRankByRuntime[agent.runtimeKind] ?? rank,
                rank
            )
        }
        return definitions.sorted { lhs, rhs in
            let lhsPreferred = preferredRankByRuntime[lhs.runtimeKind]
            let rhsPreferred = preferredRankByRuntime[rhs.runtimeKind]
            switch (lhsPreferred, rhsPreferred) {
            case let (lhsPreferred?, rhsPreferred?) where lhsPreferred != rhsPreferred:
                return lhsPreferred < rhsPreferred
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                return lhs.runtimeKind.presentationRank < rhs.runtimeKind.presentationRank
            }
        }
    }

    static func orderLocalCLIAgents(
        _ agents: [WorkspaceAgent],
        preferredOrder: [UUID]
    ) -> [WorkspaceAgent] {
        let preferredRanks = Dictionary(
            uniqueKeysWithValues: preferredOrder.enumerated().map { ($0.element, $0.offset) }
        )
        return agents.sorted { lhs, rhs in
            switch (preferredRanks[lhs.id], preferredRanks[rhs.id]) {
            case let (lhsRank?, rhsRank?) where lhsRank != rhsRank:
                return lhsRank < rhsRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            default:
                if lhs.runtimeKind != rhs.runtimeKind {
                    return lhs.runtimeKind.presentationRank < rhs.runtimeKind.presentationRank
                }
                let comparison = lhs.displayName.localizedCaseInsensitiveCompare(
                    rhs.displayName
                )
                if comparison != .orderedSame { return comparison == .orderedAscending }
                return lhs.id.uuidString < rhs.id.uuidString
            }
        }
    }

    func isLocalACPAgentReady(_ runtimeKind: AgentRuntimeKind) -> Bool {
        localACPDatabaseReadyRuntimeKinds.contains(runtimeKind)
    }

    private func startDashboardStoreIfReady() {
        guard !dashboardStoreStarted,
              !dashboardStoreStartDeferredForNoteRecovery,
              let dashboardStore else { return }
        dashboardStoreStarted = true
        conversationChangeTask?.cancel()
        let changes = dashboardStore.conversationChanges
        conversationChangeTask = Task { [weak self] in
            for await change in changes {
                guard !Task.isCancelled else { return }
                self?.enqueueConversationChange(change)
            }
        }
        Task { await dashboardStore.start() }
    }

    private func enqueueConversationChange(
        _ change: DashboardConversationChange
    ) {
        if case .composerPrefill(let text) = change.phase {
            pendingComposerPrefills[change.conversationID] = text
            return
        }
        // Metadata changes are independent of run content and must not replace
        // or be suppressed by a pending terminal notification.
        if case .configuration(let configuration) = change.phase {
            // The running adapter already supplied this snapshot. Preparing a
            // session here would turn its initial notification into a refresh
            // loop, keeping the composer loading while idle sessions restart.
            localACPSessionMetadata[change.conversationID] = LocalACPSessionMetadata(
                sessionKey: change.conversationID,
                model: configuration.model,
                thinking: configuration.thinking,
                modelOptions: configuration.modelOptions,
                thinkingLevels: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: configuration.permission,
                permissionOptions: configuration.permissionOptions,
                permissionOptionMetadata: configuration.permissionOptionMetadata,
                workingDirectory: configuration.workingDirectory
            )
            return
        }
        if change.phase == .content,
           terminalRunIDsByConversation[change.conversationID] == change.runID {
            return
        }
        if change.phase == .content,
           terminalRunIDsByConversation[change.conversationID] != change.runID {
            terminalRunIDsByConversation.removeValue(
                forKey: change.conversationID
            )
        }
        var pending = pendingConversationChanges[change.conversationID] ?? []
        if let last = pending.last, last.runID == change.runID {
            if last.phase == .terminal { return }
            pending[pending.count - 1] = change
        } else {
            pending.append(change)
        }
        pendingConversationChanges[change.conversationID] = pending
        guard conversationChangeWorkers[change.conversationID] == nil else {
            return
        }
        let conversationID = change.conversationID
        let token = UUID()
        conversationChangeWorkerTokens[conversationID] = token
        conversationChangeWorkers[conversationID] = Task { [weak self] in
            await self?.drainConversationChanges(
                conversationID: conversationID,
                token: token
            )
        }
    }

    private func drainConversationChanges(
        conversationID: String,
        token: UUID
    ) async {
        while !Task.isCancelled,
              var pending = pendingConversationChanges[conversationID],
              !pending.isEmpty {
            let change = pending.removeFirst()
            if pending.isEmpty {
                pendingConversationChanges.removeValue(forKey: conversationID)
            } else {
                pendingConversationChanges[conversationID] = pending
            }
            if change.phase == .content,
               terminalRunIDsByConversation[conversationID] == change.runID {
                continue
            }
            await applyConversationChange(change)
            if change.phase == .terminal {
                terminalRunIDsByConversation[conversationID] = change.runID
            }
        }
        guard conversationChangeWorkerTokens[conversationID] == token else {
            return
        }
        conversationChangeWorkers.removeValue(forKey: conversationID)
        conversationChangeWorkerTokens.removeValue(forKey: conversationID)
    }

    private func applyConversationChange(
        _ change: DashboardConversationChange
    ) async {
        await refreshConversation(id: change.conversationID)
        guard change.phase == .terminal else { return }
        if let dashboardStore {
            recoverPendingRemoteNoteEdit(
                runID: change.runID,
                conversationID: change.conversationID,
                store: dashboardStore
            )
        }
        await refreshWorkspaceIfChanged()
        finishAgentRunInteractions(conversationID: change.conversationID)
        trimConversationStateCacheIfNeeded()
        if let conversation = workspaceOverview?.conversations.first(where: {
            $0.id == change.conversationID
        }) {
            if openClawGatewayConversationIDs.contains(change.conversationID) {
                await refreshOpenClawGatewaySession(
                    conversationID: change.conversationID
                )
            } else if conversation.localRuntimeKind != nil {
                await refreshLocalACPSession(conversation: conversation)
            }
        }
        await refreshLocalUsage(
            range: currentUsageRange,
            refreshLimits: false,
            reason: .runCompleted
        )
    }

    private func recoverPendingRemoteNoteEdit(
        runID: String,
        conversationID: String,
        store: DashboardStore
    ) {
        guard flushNoteDrafts() else { return }
        guard let pending = (try? store.database.pendingRemoteNoteEdits())?
            .first(where: { $0.runID == runID }) else {
            try? store.database.dismissPendingRemoteNoteEdit(runID: runID)
            return
        }
        do {
            if let response = try processPendingRemoteNoteEdit(pending, store: store) {
                if adoptNoteEditingResponseDraft(response) {
                    Task { await refreshWorkspace() }
                }
            }
        } catch {
            try? store.database.dismissPendingRemoteNoteEdit(runID: runID)
            ensureConversationState(id: conversationID).setError(
                "The agent response was saved, but its note edit was not applied: \(error.localizedDescription)"
            )
        }
    }

    private static func dashboardSupportDirectory() throws -> URL {
        let fileManager = FileManager.default
        guard let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw ApplicationModelError.applicationSupportUnavailable
        }
        return applicationSupport.appending(path: WovenMatterWorkspacePaths.folderName, directoryHint: .isDirectory)
    }

    func refreshWorkspace() async {
        await refreshWorkspace(force: true)
    }

    private func refreshWorkspaceIfChanged() async {
        await refreshWorkspace(force: false)
    }

    private func refreshWorkspace(force: Bool) async {
        if Date().timeIntervalSince(lastOpenClawCronRefresh) >= 30 {
            lastOpenClawCronRefresh = Date()
            Task { await refreshOpenClawCron() }
        }
        if Date().timeIntervalSince(lastHermesCronRefresh) >= 30 {
            lastHermesCronRefresh = Date()
            Task { await refreshHermesCron() }
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let priorRevision = force || workspaceOverview == nil ? nil : workspaceRevision
            if let snapshot = try await dashboardStore.snapshot(ifChangedFrom: priorRevision) {
                apply(snapshot)
            }
            let reconciledRunning = try await dashboardStore
                .activeAgentConversationIDs()
            if localRunningConversationIDs != reconciledRunning {
                localRunningConversationIDs = reconciledRunning
                trimConversationStateCacheIfNeeded()
            }
            if workspaceError != nil {
                workspaceError = nil
            }
        } catch {
            workspaceError = error.localizedDescription
        }
    }

    func refreshConversation(id: String) async {
        let state = ensureConversationState(id: id)
        let generation = state.beginRefresh()
        do {
            guard let dashboardStore else { return }
            let page = try await dashboardStore.conversationHistoryPage(
                id: id,
                limit: Self.initialConversationMessageLimit
            )
            guard !Task.isCancelled, page.conversationID == id else { return }
            let previous = state.presentation
            let renderTask = Task.detached(priority: .userInitiated) { () -> DashboardConversationPresentation? in
                let window = previous?.window.refreshing(with: page)
                    ?? DashboardConversationWindow(page: page)
                guard previous?.window != window else { return nil }
                let messagesByID: [String: DashboardMessagePresentation]
                let runsByID: [String: DashboardRunPresentation]
                if let previous, previous.window.loadedOlderMessages {
                    var nextMessages = previous.messagesByID
                    for (messageID, presentation) in Self.renderMessagePresentations(
                        page.messages,
                        activities: page.activities,
                        runs: page.runs,
                        reusing: previous.messagesByID
                    ) {
                        nextMessages[messageID] = presentation
                    }
                    messagesByID = nextMessages
                    var nextRuns = previous.runsByID
                    for (runID, presentation) in Self.renderRunPresentations(
                        page.runs,
                        reusing: previous.runsByID
                    ) {
                        nextRuns[runID] = presentation
                    }
                    runsByID = nextRuns
                } else {
                    messagesByID = Self.renderMessagePresentations(
                        page.messages,
                        activities: page.activities,
                        runs: page.runs,
                        reusing: previous?.messagesByID ?? [:]
                    )
                    runsByID = Self.renderRunPresentations(
                        page.runs,
                        reusing: previous?.runsByID ?? [:]
                    )
                }
                return DashboardConversationPresentation(
                    window: window,
                    messagesByID: messagesByID,
                    runsByID: runsByID
                )
            }
            let presentation = await withTaskCancellationHandler {
                await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            guard !Task.isCancelled else { return }
            guard conversationStatesByID[id] === state,
                  state.isCurrentRefresh(generation) else { return }
            if let presentation { state.apply(presentation) }
            touchConversationState(state)
            state.setError(nil)
            workspaceError = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled,
                  conversationStatesByID[id] === state,
                  state.isCurrentRefresh(generation) else { return }
            state.setError(error.localizedDescription)
        }
    }

    @discardableResult
    func loadOlderConversationMessages(id: String) async -> Bool {
        guard let state = conversationStatesByID[id],
              !state.isLoadingOlderMessages,
              let current = state.presentation,
              current.window.conversationID == id,
              current.window.hasOlderMessages,
              let cursor = current.window.messages.first.map({
                  WorkspaceConversationHistoryCursor(createdAt: $0.createdAt, messageID: $0.id)
              }),
              let dashboardStore else {
            return false
        }
        state.setLoadingOlderMessages(true)
        defer { state.setLoadingOlderMessages(false) }
        do {
            let page = try await dashboardStore.conversationHistoryPage(
                id: id,
                before: cursor,
                limit: Self.olderConversationMessageLimit
            )
            guard !Task.isCancelled,
                  conversationStatesByID[id] === state else {
                return false
            }
            let renderTask = Task.detached(priority: .userInitiated) {
                let messagesByID = Self.renderMessagePresentations(
                    page.messages,
                    activities: page.activities,
                    runs: page.runs,
                    reusing: current.messagesByID
                )
                let runsByID = Self.renderRunPresentations(
                    page.runs,
                    reusing: current.runsByID
                )
                return (messages: messagesByID, runs: runsByID)
            }
            let renderedPage = await withTaskCancellationHandler {
                await renderTask.value
            } onCancel: {
                renderTask.cancel()
            }
            guard !Task.isCancelled,
                  let latest = state.presentation,
                  latest.window.conversationID == id else {
                return false
            }
            var messagesByID = renderedPage.messages
            for (messageID, presentation) in current.messagesByID {
                messagesByID[messageID] = presentation
            }
            for (messageID, presentation) in latest.messagesByID {
                messagesByID[messageID] = presentation
            }
            var runsByID = renderedPage.runs
            for (runID, presentation) in current.runsByID {
                runsByID[runID] = presentation
            }
            for (runID, presentation) in latest.runsByID {
                runsByID[runID] = presentation
            }
            let expandedWindow = current.window.prepending(page)
            state.apply(DashboardConversationPresentation(
                window: expandedWindow.mergingNewer(latest.window),
                messagesByID: messagesByID,
                runsByID: runsByID
            ))
            touchConversationState(state)
            workspaceError = nil
            return page.messages.isEmpty == false
        } catch is CancellationError {
            return false
        } catch {
            guard !Task.isCancelled else { return false }
            state.setError(error.localizedDescription)
            return false
        }
    }

    func ensureConversationState(id: String) -> DashboardConversationState {
        if let state = conversationStatesByID[id] {
            touchConversationState(state)
            return state
        }
        let state = DashboardConversationState(conversationID: id)
        touchConversationState(state)
        conversationStatesByID[id] = state
        trimConversationStateCacheIfNeeded()
        return state
    }

    private func touchConversationState(_ state: DashboardConversationState) {
        conversationAccessSequence &+= 1
        state.lastAccessSequence = conversationAccessSequence
    }

    private func trimConversationStateCacheIfNeeded() {
        let inactive = conversationStatesByID.values
            .filter {
                !localRunningConversationIDs.contains($0.conversationID)
                    && !$0.isLoadingOlderMessages
            }
            .sorted { $0.lastAccessSequence < $1.lastAccessSequence }
        guard inactive.count > Self.maximumRetainedConversationCount else { return }
        for state in inactive.prefix(
            inactive.count - Self.maximumRetainedConversationCount
        ) {
            conversationStatesByID.removeValue(forKey: state.conversationID)
        }
    }

    private nonisolated static func renderMessagePresentations(
        _ messages: [WorkspaceMessageRecord],
        activities: [WorkspaceRunActivityRecord],
        runs: [WorkspaceRunRecord],
        reusing previous: [String: DashboardMessagePresentation]
    ) -> [String: DashboardMessagePresentation] {
        var result: [String: DashboardMessagePresentation] = [:]
        let workRunsByReply = Dictionary(runs.compactMap { run in
            run.assistantMessageID.map { ($0, run.id) }
        }, uniquingKeysWith: { _, latest in latest })
        let activitiesByRun = Dictionary(grouping: activities.sorted(by: WorkspaceRunActivityRecord.precedes), by: \.runID)
        result.reserveCapacity(messages.count)
        for message in messages {
            guard !Task.isCancelled else { return result }
            // Older steering replies have no work disclosure of their own;
            // retain their complete canonical text instead of hiding commentary.
            let displayedBody = workRunsByReply[message.id].map { runID in
                AssistantTranscriptProjection(messageID: message.id,
                    content: message.content, activities: (activitiesByRun[runID] ?? []).map(\.activity)).body
            } ?? message.content
            if let existing = previous[message.id],
               existing.source == message.content,
               existing.displayedBody == displayedBody,
               existing.status == message.status,
               existing.createdAt == message.createdAt {
                result[message.id] = existing
                continue
            }
            result[message.id] = DashboardMessagePresentation(
                source: message.content,
                displayedBody: displayedBody,
                status: message.status,
                createdAt: message.createdAt,
                document: message.role == "assistant"
                    ? ConversationMarkdownDocument(
                        RemoteNoteEditEnvelope.redactingEnvelopes(in: displayedBody)
                    )
                    : nil
            )
        }
        return result
    }

    private nonisolated static func renderRunPresentations(
        _ runs: [WorkspaceRunRecord],
        reusing previous: [String: DashboardRunPresentation]
    ) -> [String: DashboardRunPresentation] {
        var result: [String: DashboardRunPresentation] = [:]
        result.reserveCapacity(runs.count)
        for run in runs {
            guard !Task.isCancelled else { return result }
            if let existing = previous[run.id], existing.source == run {
                result[run.id] = existing
                continue
            }
            let startedAt = (run.startedAt ?? run.createdAt).flatMap(dashboardParsedDate)
            let completedDuration: String?
            if run.status != "running",
               let startedAt,
               let endValue = run.completedAt ?? run.updatedAt,
               let completedAt = dashboardParsedDate(endValue) {
                completedDuration = dashboardRunDuration(completedAt.timeIntervalSince(startedAt))
            } else {
                completedDuration = nil
            }
            result[run.id] = DashboardRunPresentation(
                source: run,
                startedAt: startedAt,
                completedDuration: completedDuration
            )
        }
        return result
    }

    func markConversationRead(id: String) {
        guard workspaceOverview?.conversations.first(where: { $0.id == id })?.unread == true else { return }
        Task {
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                try await dashboardStore.markConversationRead(id: id)
                await refreshWorkspace()
            } catch {
                workspaceError = error.localizedDescription
            }
        }
    }

    func createFolder(name: String) async -> String? {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let folderID = try await dashboardStore.createFolder(name: name)
            await refreshWorkspace()
            return folderID
        } catch {
            folderMutationError = error.localizedDescription
            return nil
        }
    }

    func renameFolder(id: String, name: String) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.renameFolder(id: id, name: name)
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func setFolderPinned(id: String, isPinned: Bool) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.setFolderPinned(id: id, isPinned: isPinned)
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func moveFolder(id: String, direction: WorkspaceFolderMoveDirection) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            guard try await dashboardStore.moveFolder(
                id: id,
                direction: direction
            ) else {
                folderMutationError = "The folder could not be moved."
                return false
            }
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func deleteFolder(id: String) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.deleteFolder(id: id)
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func clearFolderMutationError() {
        folderMutationError = nil
    }

    func moveConversation(id: String, toFolderID folderID: String?) async -> Bool {
        folderMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let moved = try await dashboardStore.moveConversation(id: id, toFolderID: folderID)
            if !moved {
                folderMutationError = "The chat could not be moved."
                return false
            }
            await refreshWorkspace()
            return true
        } catch {
            folderMutationError = error.localizedDescription
            return false
        }
    }

    func createNote(
        folderID: String?,
        kind: NoteArtifactKind = .note
    ) async -> String? {
        noteMutationError = nil
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let noteID = try await dashboardStore.createNote(
                folderID: folderID,
                kind: kind
            )
            await refreshWorkspace()
            return noteID
        } catch {
            noteMutationError = error.localizedDescription
            return nil
        }
    }

    func createCalendarItem(
        title: String,
        startsAt: Date,
        endsAt: Date?,
        allDay: Bool
    ) async -> Bool {
        calendarMutationError = nil
        isCreatingCalendarItem = true
        defer { isCreatingCalendarItem = false }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.createCalendarItem(
                title: title,
                startsAt: startsAt,
                endsAt: endsAt,
                allDay: allDay
            )
            await refreshWorkspace()
            return true
        } catch {
            calendarMutationError = error.localizedDescription
            return false
        }
    }

    func clearCalendarMutationError() {
        calendarMutationError = nil
    }

    func noteDraft(for note: WorkspaceNoteRecord) -> DashboardNoteDraft {
        noteDrafts[note.id] ?? .initial(for: note)
    }

    func adoptNoteEditingResponse(_ response: NoteEditingResponse) async {
        guard adoptNoteEditingResponseDraft(response) else { return }
        await refreshWorkspace()
    }

    @discardableResult
    private func adoptNoteEditingResponseDraft(_ response: NoteEditingResponse) -> Bool {
        guard response.success, let document = response.document,
              let content = try? document.encoded() else { return false }
        if var draft = noteDrafts[response.noteID] {
            draft.title = response.title ?? draft.title
            draft.content = content
            draft.saveState = .saved
            draft.editRevision = 0
            draft.persistedRevision = 0
            draft.sourceUpdatedAt = response.revision
            noteDrafts[response.noteID] = draft
        }
        return true
    }

    func prepareNoteDraft(_ note: WorkspaceNoteRecord) {
        guard var draft = noteDrafts[note.id] else {
            noteDrafts[note.id] = noteDraft(for: note)
            return
        }
        draft.reconcile(with: note)
        noteDrafts[note.id] = draft
    }

    func updateNoteDraft(
        note: WorkspaceNoteRecord,
        title: String? = nil,
        content: String? = nil
    ) {
        prepareNoteDraft(note)
        guard var draft = noteDrafts[note.id] else { return }
        draft.edit(title: title, content: content)
        persistNoteDraft(note: note, draft: draft)
    }

    func retryNoteDraft(note: WorkspaceNoteRecord) {
        prepareNoteDraft(note)
        guard var draft = noteDrafts[note.id] else { return }
        draft.editRevision &+= 1
        draft.saveState = .saving
        persistNoteDraft(note: note, draft: draft)
    }

    private func persistNoteDraft(
        note: WorkspaceNoteRecord,
        draft: DashboardNoteDraft
    ) {
        var draft = draft
        guard let noteWriteBehind else {
            let error = ApplicationModelError.dashboardStoreUnavailable
            draft.fail(error.localizedDescription)
            noteDrafts[note.id] = draft
            noteMutationError = error.localizedDescription
            return
        }
        let entry = DashboardNoteJournalEntry(
            noteID: note.id,
            title: draft.title,
            content: draft.content,
            revision: draft.editRevision,
            folderID: note.folderID,
            createdAt: note.createdAt
        )
        noteDrafts[note.id] = draft
        noteWriteBehind.submit(entry)
    }

    @discardableResult
    func flushNoteDrafts() -> Bool {
        guard let noteWriteBehind else { return false }
        do {
            try noteWriteBehind.flush()
            return true
        } catch {
            noteMutationError = error.localizedDescription
            return false
        }
    }

    private func completeNoteWrite(
        _ entry: DashboardNoteJournalEntry,
        result: Result<Void, any Error>
    ) {
        guard var draft = noteDrafts[entry.noteID] else { return }
        switch result {
        case .success:
            draft.persistedRevision = max(draft.persistedRevision, entry.revision)
            if draft.editRevision == entry.revision {
                draft.saveState = .saved
            }
            let hasOutstandingWork = noteWriteBehind?.hasOutstandingWork()
            if hasOutstandingWork == false {
                noteMutationError = nil
            }
            noteDrafts[entry.noteID] = draft
            if dashboardStoreStartDeferredForNoteRecovery,
               hasOutstandingWork == false {
                dashboardStoreStartDeferredForNoteRecovery = false
                startDashboardStoreIfReady()
            }
            noteRefreshTask?.cancel()
            noteRefreshTask = Task {
                guard !Task.isCancelled else { return }
                await refreshWorkspace()
            }
        case .failure(let error):
            if draft.editRevision <= entry.revision {
                draft.fail(error.localizedDescription)
                noteDrafts[entry.noteID] = draft
                noteMutationError = error.localizedDescription
            }
        }
    }

    func clearNoteMutationError() {
        noteMutationError = nil
    }

    func refreshLocalUsage(
        range: UsageTimeRange,
        refreshLimits: Bool = false,
        reason: UsageRefreshReason = .manual,
        explicitCredentialAccess: Bool = false,
        interactiveProvider: ProviderKind? = nil
    ) async {
        await usage.refreshLocalUsage(
            range: range,
            refreshLimits: refreshLimits,
            reason: reason,
            explicitCredentialAccess: explicitCredentialAccess,
            interactiveProvider: interactiveProvider
        )
    }

    func usageDestinationAppeared(range: UsageTimeRange) async {
        await usage.usageDestinationAppeared(range: range)
    }

    func usageAnalyticsSelected(range: UsageTimeRange) async {
        await usage.usageAnalyticsSelected(range: range)
    }

    func saveOpenRouterAPIKey(_ value: String, range: UsageTimeRange) async {
        await usage.saveOpenRouterAPIKey(value, range: range)
    }

    func deleteOpenRouterAPIKey(range: UsageTimeRange) async {
        await usage.deleteOpenRouterAPIKey(range: range)
    }

    func acknowledgeCredentialAccessDisclosure() {
        usage.acknowledgeCredentialAccessDisclosure()
    }

    func reconnectSavedCredentials() async {
        guard !isReconnectingSavedCredentials, usage.beginCredentialAuthorization() else { return }
        isReconnectingSavedCredentials = true
        credentialAccessStatus = "Reconnecting saved credentials…"
        defer {
            usage.endCredentialAuthorization()
            isReconnectingSavedCredentials = false
        }
        acknowledgeCredentialAccessDisclosure()
        do {
            try await usage.authorizeSavedCredentials()
            if remoteWorkspaces.isCredentialAccessEnabled {
                for workspace in remoteWorkspaces.workspaces {
                    try Task.checkCancellation()
                    try await remoteWorkspaces.authorizeCredentialAccess(for: workspace)
                }
            }
            let links = openClawGatewayLinks.filter {
                $0.location != .remoteWorkspace || remoteWorkspaces.isCredentialAccessEnabled
            }
            if !links.isEmpty {
                guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
                for link in links {
                    try Task.checkCancellation()
                    guard openClawGatewayOperationAgentIDs.insert(link.agentID).inserted else {
                        throw CancellationError()
                    }
                    defer { openClawGatewayOperationAgentIDs.remove(link.agentID) }
                    try await dashboardStore.authorizeOpenClawGatewayCredentials(link)
                }
            }
            try Task.checkCancellation()
            await refreshLocalUsage(
                range: currentUsageRange,
                refreshLimits: true,
                reason: .credentialChanged
            )
            remoteWorkspaces.refreshAll()
            await refreshOpenClawGateways()
            credentialAccessStatus = "Saved credentials are ready. Automatic refreshes will stay silent."
        } catch is CancellationError {
            credentialAccessStatus = "Credential recovery stopped. Automatic refreshes will stay silent."
        } catch {
            credentialAccessStatus = "Credential recovery stopped: \(error.localizedDescription)"
        }
    }

    func isUsageProviderEnabled(_ provider: ProviderKind) -> Bool {
        usage.isUsageProviderEnabled(provider)
    }

    func enableUsageProvider(
        _ provider: ProviderKind,
        range: UsageTimeRange
    ) async {
        await usage.enableUsageProvider(provider, range: range)
    }

    func retryUsageProviderCredentialAccess(
        _ provider: ProviderKind,
        range: UsageTimeRange
    ) async {
        await usage.retryUsageProviderCredentialAccess(provider, range: range)
    }

    func selectCodexUsageWorkspace(
        _ workspaceID: String,
        range: UsageTimeRange
    ) async {
        await usage.selectCodexUsageWorkspace(workspaceID, range: range)
    }

    func disableUsageProvider(
        _ provider: ProviderKind,
        range: UsageTimeRange
    ) async {
        await usage.disableUsageProvider(provider, range: range)
    }

    func signInUsageProvider(_ provider: ProviderKind) {
        usage.signInUsageProvider(provider)
    }

    func reconnectSelectedCodexUsageWorkspace() {
        usage.reconnectSelectedCodexUsageWorkspace()
    }

    func isLocalACPRuntimeCredentialAccessEnabled(
        _ runtimeKind: AgentRuntimeKind
    ) -> Bool {
        enabledLocalACPRuntimeKinds.contains(runtimeKind)
    }

    func isLocalACPRuntimeShown(_ runtimeKind: AgentRuntimeKind) -> Bool {
        shownLocalACPRuntimeKinds.contains(runtimeKind)
    }

    func setLocalACPRuntimeShown(
        _ isShown: Bool,
        runtimeKind: AgentRuntimeKind
    ) {
        let state = localACPRuntimePreferences.setShown(
            isShown,
            for: runtimeKind
        )
        shownLocalACPRuntimeKinds = state.shownRuntimeKinds
    }

    func enableLocalACPRuntimeCredentialAccess(
        _ runtimeKind: AgentRuntimeKind
    ) {
        guard runtimeInventories[runtimeKind]?.isInstalled == true,
              installingLocalACPRuntimeKinds.isEmpty else { return }
        acknowledgeCredentialAccessDisclosure()
        let state = localACPRuntimePreferences.enable(runtimeKind)
        enabledLocalACPRuntimeKinds = state.enabledRuntimeKinds
        shownLocalACPRuntimeKinds = state.shownRuntimeKinds
        refreshLocalACPRuntimesNow(checkCredentialsFor: [runtimeKind])
    }

    func disableLocalACPRuntimeCredentialAccess(
        _ runtimeKind: AgentRuntimeKind
    ) {
        guard enabledLocalACPRuntimeKinds.contains(runtimeKind) else {
            return
        }
        if runtimeKind == .hermes, let launch = localACPLaunchConfigurations[.hermes], let home = launch.environment["HERMES_HOME"] {
            Task {
                do {
                    try await HermesGatewayService.shared.stopIfIdle(home: home)
                    let state = localACPRuntimePreferences.disable(runtimeKind)
                    enabledLocalACPRuntimeKinds = state.enabledRuntimeKinds
                    shownLocalACPRuntimeKinds = state.shownRuntimeKinds
                    refreshLocalACPRuntimesNow()
                } catch { localRunError = error.localizedDescription }
            }
            return
        }
        let state = localACPRuntimePreferences.disable(runtimeKind)
        enabledLocalACPRuntimeKinds = state.enabledRuntimeKinds
        shownLocalACPRuntimeKinds = state.shownRuntimeKinds
        refreshLocalACPRuntimesNow()
    }

    @discardableResult
    func sendAgentMessage(
        conversation: WorkspaceConversationRecord,
        content: String,
        note: WorkspaceNoteRecord? = nil
    ) async -> Bool {
        await sendAgentMessage(
            conversation: conversation,
            input: AgentMessageInput(text: content),
            note: note
        )
    }

    func stageMessageAttachments(
        _ files: [(url: URL, mimeType: String)]
    ) async throws -> [AgentMessageAttachmentDraft] {
        guard let dashboardStore else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        var staged: [AgentMessageAttachmentDraft] = []
        for file in files {
            staged.append(try await dashboardStore.stageMessageAttachment(
                fileURL: file.url,
                mimeType: file.mimeType
            ))
        }
        return staged
    }

    func noteAttachmentDraft(_ note: WorkspaceNoteRecord) -> AgentMessageAttachmentDraft {
        let folder = note.folderID.flatMap { folderID in
            workspaceOverview?.folders.first(where: { $0.id == folderID })
        }
        return .reference(AgentMessageReferenceDraft(
            kind: .note,
            resourceID: note.id,
            titleSnapshot: note.title,
            contentSnapshot: String(note.content.prefix(AgentMessageAttachmentLimits.maximumReferenceCharacters)),
            revisionSnapshot: note.updatedAt ?? note.createdAt ?? "",
            folderIDSnapshot: note.folderID,
            folderTitleSnapshot: folder?.name
        ))
    }

    func conversationAttachmentDraft(
        _ conversation: WorkspaceConversationRecord
    ) async throws -> AgentMessageAttachmentDraft {
        return .reference(AgentMessageReferenceDraft(
            kind: .conversation,
            resourceID: conversation.id,
            titleSnapshot: conversation.title,
            contentSnapshot: "",
            revisionSnapshot: conversation.lastMessageAt ?? "",
            folderIDSnapshot: conversation.folderID,
            folderTitleSnapshot: conversation.folderID.flatMap { folderID in
                workspaceOverview?.folders.first(where: { $0.id == folderID })?.name
            },
            agentCodenameSnapshot: conversation.agentCodename
        ))
    }

    @discardableResult
    func sendAgentMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        note: WorkspaceNoteRecord? = nil
    ) async -> Bool {
        let state = ensureConversationState(id: conversation.id)
        do {
            guard try await dispatchAgentMessage(conversation: conversation, input: input, note: note) else {
                activeSessionLimitPresented = true
                return false
            }
            state.setError(nil)
            return true
        } catch LocalACPSessionDatabaseError.steeringUnsupported {
            state.setError(ApplicationModelError.steeringUnavailable.localizedDescription)
        } catch { state.setError(error.localizedDescription) }
        return false
    }

    /// Both user and CLI delivery use this admission point. A false result means
    /// no dispatch occurred; callers decide whether to show the user limit alert.
    func dispatchAgentMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        note: WorkspaceNoteRecord? = nil
    ) async throws -> Bool {
        guard let dashboardStore, let agentTools else { throw ApplicationModelError.dashboardStoreUnavailable }
        guard !loadingLocalACPSessionIDs.contains(conversation.id),
              !updatingLocalACPSessionIDs.contains(conversation.id) else {
            throw ApplicationModelError.localSessionConfigurationInProgress
        }
        let decision = toolSessionAdmission.begin(conversation.id, running: runningToolSessionIDs,
            limit: agentTools.settings.maximumRunningSessions)
        if decision == .atCapacity { return false }
        if decision == .preparing { throw ApplicationModelError.localSessionConfigurationInProgress }
        let steering = decision == .steer
        defer { toolSessionAdmission.finish(conversation.id) }
        if conversation.localRuntimeKind == .hermes, conversation.remoteWorkspaceID == nil,
           !buzzBoundLocalACPConversationIDs.contains(conversation.id) {
            try requireLocalHermesLink(conversationID: conversation.id)
        }
        guard !usesLocallyInstalledRuntime(conversation) || installingLocalACPRuntimeKinds.isEmpty else {
            throw WorkspaceToolError.invalid("Wait for runtime installation or update to finish before sending a message.")
        }
        let normalized = AgentMessageInput(text: input.text.trimmingCharacters(in: .whitespacesAndNewlines),
            attachments: input.attachments, historyDeliveryID: input.historyDeliveryID)
        guard normalized.hasContent else { throw WorkspaceToolError.invalid("A message is required.") }
        for reference in normalized.references where reference.kind == .conversation {
            try dashboardStore.database.attachConversationReference(sourceID: conversation.id, targetID: reference.resourceID)
        }
        var context: AgentNoteContext?
        if let note, agentTools.policy(for: conversation.id).enabled.contains(.notes) {
            guard flushNoteDrafts() else { throw ApplicationModelError.noteDraftSaveFailed }
            let response = try dashboardStore.database.readNoteForEditing(id: note.id, callerConversationID: conversation.id)
            guard let revision = response.revision else { throw ApplicationModelError.noteContextUnavailable }
            context = AgentNoteContext(noteID: note.id, title: response.title ?? note.title, folderID: note.folderID, revision: revision)
        }
        let remote = conversation.remoteWorkspaceID.flatMap { remoteWorkspaces.configuration(id: $0) }
        if conversation.remoteWorkspaceID != nil, remote == nil { throw ApplicationModelError.remoteHarnessUnavailable }
        let discovery = try await agentTools.discovery(sessionID: conversation.id, remote: remote, noteID: context?.noteID)
        let deliveryContent = discovery + "\n\n" + normalized.text
        try Task.checkCancellation()
        if let deliveryID = normalized.historyDeliveryID {
            try dashboardStore.database.validateClaimedToolDelivery(id: deliveryID)
        }
        if !steering { localRunningConversationIDs.insert(conversation.id) }
        do {
            if conversation.localRuntimeKind == .opencode {
                guard let openCode = openCodeModel(for: conversation.id) else { throw OpenCodeError.message("This workspace's OpenCode connection is unavailable.") }
                try await openCode.send(conversation.id, input: normalized, discovery: discovery)
            } else if steering {
                if isOpenClawGatewayConversation(conversation.id) {
                    _ = try await dashboardStore.sendActiveOpenClawGatewayPrompt(conversationID: conversation.id, input: normalized, deliveryContent: deliveryContent)
                } else {
                    let staged = try await remoteWorkspaces.stagingFiles(of: normalized, in: conversation.remoteWorkspaceID)
                    _ = try await dashboardStore.sendActiveLocalACPPrompt(conversationID: conversation.id, input: staged, deliveryContent: deliveryContent)
                }
            } else if isOpenClawGatewayConversation(conversation.id) {
                _ = try await acceptOpenClawGatewayMessage(conversation: conversation, input: normalized,
                    deliveryContent: deliveryContent, noteContext: context, store: dashboardStore)
            } else {
                _ = try await acceptLocalAgentMessage(conversation: conversation, input: normalized,
                    deliveryContent: deliveryContent, noteContext: context, store: dashboardStore)
            }
        } catch {
            if !steering { localRunningConversationIDs.remove(conversation.id) }
            throw error
        }
        scheduleConversationTitleGeneration(conversation: conversation, firstPrompt: normalized.previewText)
        return true
    }

    var runningToolSessionIDs: Set<String> {
        localRunningConversationIDs.union(openCodeInstances.flatMap { instance in
            instance.snapshots.filter { $0.value.active }.map(\.key)
        })
    }

    private func processPendingRemoteNoteEdit(
        _ pending: PendingRemoteNoteEdit,
        store: DashboardStore
    ) throws -> NoteEditingResponse? {
        guard let envelope = try RemoteNoteEditEnvelope.extract(
            from: pending.assistantContent,
            nonce: pending.nonce,
            noteID: pending.noteID,
            expectedRevision: pending.expectedRevision,
            noteKind: pending.noteKind
        ) else {
            try store.database.dismissPendingRemoteNoteEdit(runID: pending.runID)
            return nil
        }
        let current = try store.database.readNoteForEditing(id: pending.noteID)
        guard current.success, let document = current.document else {
            throw ApplicationModelError.noteContextUnavailable
        }
        try envelope.validateApplying(to: document)
        return try store.database.applyPendingRemoteNoteEdit(
            pending,
            envelope: envelope,
            visibleAssistantContent: RemoteNoteEditEnvelope.redactingEnvelopes(
                in: pending.assistantContent
            )
        )
    }

    private func recoverPendingRemoteNoteEdits(store: DashboardStore) {
        guard flushNoteDrafts() else { return }
        for pending in (try? store.database.pendingRemoteNoteEdits()) ?? [] {
            do {
                if let response = try processPendingRemoteNoteEdit(pending, store: store) {
                    if adoptNoteEditingResponseDraft(response) {
                        Task { await refreshWorkspace() }
                    }
                }
            } catch {
                try? store.database.dismissPendingRemoteNoteEdit(runID: pending.runID)
                noteMutationError = "A recovered remote note edit was not applied: \(error.localizedDescription)"
            }
        }
        try? store.database.dismissTerminalRemoteNoteEdits()
    }

    func canAgentEditOpenNote(_ conversation: WorkspaceConversationRecord?) -> Bool {
        guard let conversation else { return false }
        return conversation.localRuntimeKind != nil && agentTools?.policy(for: conversation.id).enabled.contains(.notes) == true
    }

    private func acceptOpenClawGatewayMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        deliveryContent: String,
        noteContext: AgentNoteContext?,
        store: DashboardStore
    ) async throws -> LocalACPRunIdentifiers {
        guard openClawGatewayConversationIDs.contains(conversation.id) else {
            throw OpenClawGatewayClientError.invalidEndpoint
        }
        return try await store.acceptOpenClawGatewayPrompt(
            conversationID: conversation.id,
            input: input,
            deliveryContent: deliveryContent,
            noteContext: noteContext,
            onPermission: { request in
                await self.requestLocalACPPermission(
                    conversationID: conversation.id,
                    request: request
                )
            }
        )
    }

    private func acceptLocalAgentMessage(
        conversation: WorkspaceConversationRecord,
        input: AgentMessageInput,
        deliveryContent: String,
        noteContext: AgentNoteContext?,
        store: DashboardStore
    ) async throws -> LocalACPRunIdentifiers {
        guard let runtimeKind = conversation.localRuntimeKind else {
            throw ApplicationModelError.localACPRuntimeUnavailable
        }
        let isBuzzWorkspaceSession = buzzBoundLocalACPConversationIDs.contains(
            conversation.id
        )
        let context = try directACPLaunchContext(
            conversation: conversation,
            runtimeKind: runtimeKind,
            isBuzzWorkspaceSession: isBuzzWorkspaceSession
        )
        let launch = context?.launch
        let workspace = context?.workspace
        guard isBuzzWorkspaceSession || (launch != nil && workspace != nil) else {
            throw ApplicationModelError.localACPRuntimeUnavailable
        }
        if runtimeKind == .pi, !input.files.isEmpty {
            throw AgentMessageAttachmentError.unsupportedForAgent(
                "Pi RPC does not expose a file attachment contract yet."
            )
        }
        let input = try await remoteWorkspaces.stagingFiles(of: input, in: conversation.remoteWorkspaceID)
        return try await store.acceptLocalACPPrompt(
            conversationID: conversation.id,
            input: input,
            deliveryContent: deliveryContent,
            noteContext: noteContext,
            launch: launch,
            workspace: workspace,
            onPermission: { request in
                await self.requestLocalACPPermission(
                    conversationID: conversation.id,
                    request: request
                )
            },
            onInteraction: { request in
                await self.requestLocalACPInteraction(
                    conversationID: conversation.id,
                    request: request
                )
            }
        )
    }

    private func finishAgentRunInteractions(conversationID: String) {
        let permissionIDs = pendingLocalACPPermissions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        cancelLocalACPInteractions(conversationID: conversationID)
    }

    func isLocalACPSessionLaunchAvailable(_ conversation: WorkspaceConversationRecord) -> Bool {
        guard let runtimeKind = conversation.localRuntimeKind else { return false }
        if buzzBoundLocalACPConversationIDs.contains(conversation.id) { return true }
        if let workspaceID = conversation.remoteWorkspaceID {
            guard let configuration = remoteWorkspaces.configuration(id: workspaceID) else { return false }
            return remoteWorkspaces.isHarnessReady(runtimeKind, in: configuration)
        }
        return localACPLaunchConfigurations[runtimeKind] != nil
            && localACPWorkspaceLaunchConfiguration != nil
    }

    func refreshLocalACPSession(
        conversation: WorkspaceConversationRecord
    ) async {
        do { try await applyPendingSessionSelections(conversationID: conversation.id) }
        catch { ensureConversationState(id: conversation.id).setError(error.localizedDescription); return }
        if conversation.localRuntimeKind == .opencode {
            if let openCode = openCodeModel(for: conversation.id), openCode.isEnabled, let link = openCode.links[conversation.id] {
                await openCode.coordinator.watch(link)
            }
            return
        }
        guard let runtimeKind = conversation.localRuntimeKind else {
            return
        }
        let isBuzzWorkspaceSession = buzzBoundLocalACPConversationIDs.contains(
            conversation.id
        )
        let context = try? directACPLaunchContext(
            conversation: conversation,
            runtimeKind: runtimeKind,
            isBuzzWorkspaceSession: isBuzzWorkspaceSession
        )
        let launch = context?.launch
        let workspace = context?.workspace
        guard isBuzzWorkspaceSession || (launch != nil && workspace != nil) else {
            return
        }
        let request = localACPSessionRefreshLifecycle.beginRefresh(
            for: conversation.id
        )
        defer { localACPSessionRefreshLifecycle.finish(request) }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let configuration = try await dashboardStore
                .localACPSessionConfiguration(
                    conversationID: conversation.id,
                    launch: launch,
                    workspace: workspace
                )
            guard !Task.isCancelled,
                  localACPSessionRefreshLifecycle.isCurrent(request) else {
                return
            }
            localACPSessionMetadata[conversation.id] = LocalACPSessionMetadata(
                sessionKey: conversation.id,
                model: configuration.model,
                thinking: configuration.thinking,
                modelOptions: configuration.modelOptions,
                thinkingLevels: configuration.thinkingOptions,
                slashCommands: configuration.slashCommands,
                modelOptionMetadata: configuration.modelOptionMetadata,
                thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                permission: configuration.permission,
                permissionOptions: configuration.permissionOptions,
                permissionOptionMetadata: configuration.permissionOptionMetadata,
                workingDirectory: configuration.workingDirectory
            )
            if let metadata = localACPSessionMetadata[conversation.id] {
                recordConfirmedSessionSelections(conversationID: conversation.id, metadata: metadata)
            }
            ensureConversationState(id: conversation.id).setError(nil)
        } catch {
            guard !Task.isCancelled,
                  localACPSessionRefreshLifecycle.isCurrent(request) else {
                return
            }
            ensureConversationState(id: conversation.id).setError(
                error.localizedDescription
            )
        }
    }

    func beginSessionSelectionApplication(conversationID: String) throws {
        guard !localRunningConversationIDs.contains(conversationID) else { throw ApplicationModelError.steeringUnavailable }
        guard updatingLocalACPSessionIDs.insert(conversationID).inserted else {
            throw ApplicationModelError.localSessionConfigurationInProgress
        }
    }

    func endSessionSelectionApplication(conversationID: String) {
        updatingLocalACPSessionIDs.remove(conversationID)
    }

    func publishSessionSelectionMetadata(_ metadata: LocalACPSessionMetadata, conversationID: String, gateway: Bool) {
        if gateway { openClawGatewaySessionMetadata[conversationID] = metadata }
        else { localACPSessionMetadata[conversationID] = metadata }
    }

    func updateLocalACPSession(
        conversation: WorkspaceConversationRecord,
        model: String? = nil,
        thinking: String? = nil,
        permission: String? = nil
    ) {
        guard let runtimeKind = conversation.localRuntimeKind,
              model != nil || thinking != nil || permission != nil else { return }
        let permission = runtimeKind == .pi ? nil : permission
        if retryPendingSessionSelections(conversationID: conversation.id,
            selections: SessionSelections(model: model, thinking: thinking, permission: permission)) { return }
        guard !localRunningConversationIDs.contains(conversation.id),
              updatingLocalACPSessionIDs.insert(conversation.id).inserted else {
            return
        }
        let isBuzzWorkspaceSession = buzzBoundLocalACPConversationIDs.contains(
            conversation.id
        )
        let context = try? directACPLaunchContext(
            conversation: conversation,
            runtimeKind: runtimeKind,
            isBuzzWorkspaceSession: isBuzzWorkspaceSession
        )
        let launch = context?.launch
        let workspace = context?.workspace
        guard isBuzzWorkspaceSession || (launch != nil && workspace != nil) else {
            updatingLocalACPSessionIDs.remove(conversation.id)
            return
        }
        localRunError = nil
        ensureConversationState(id: conversation.id).setError(nil)
        Task {
            defer { updatingLocalACPSessionIDs.remove(conversation.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                let configuration = try await dashboardStore
                    .updateLocalACPSessionConfiguration(
                        conversationID: conversation.id,
                        model: model,
                        thinking: thinking,
                        permission: permission,
                        launch: launch,
                        workspace: workspace
                    )
                localACPSessionMetadata[conversation.id] =
                    LocalACPSessionMetadata(
                        sessionKey: conversation.id,
                        model: configuration.model,
                        thinking: configuration.thinking,
                        modelOptions: configuration.modelOptions,
                        thinkingLevels: configuration.thinkingOptions,
                        slashCommands: configuration.slashCommands,
                        modelOptionMetadata: configuration.modelOptionMetadata,
                        thinkingOptionMetadata: configuration.thinkingOptionMetadata,
                        permission: configuration.permission,
                        permissionOptions: configuration.permissionOptions,
                        permissionOptionMetadata: configuration.permissionOptionMetadata,
                        workingDirectory: configuration.workingDirectory
                    )
                if let metadata = localACPSessionMetadata[conversation.id] {
                    recordConfirmedSessionSelections(conversationID: conversation.id, metadata: metadata)
                }
            } catch {
                ensureConversationState(id: conversation.id).setError(
                    error.localizedDescription
                )
            }
        }
    }

    /// Reads the retained usage index without refreshing providers or credentials.
    func recordedUsageSamples(from start: Date, to end: Date, limit: Int, offset: Int) async throws -> [UsageSample] {
        try await usage.recordedUsageSamples(from: start, to: end, limit: limit, offset: offset)
    }

    func defaultToolWorkingDirectory(workspaceID: UUID?) throws -> String {
        if let workspaceID {
            guard let workspace = remoteWorkspaces.configuration(id: workspaceID) else { throw ApplicationModelError.remoteHarnessUnavailable }
            return remoteWorkspaces.remoteWorkspaceRoot(for: workspace)
        }
        guard let workspace = localACPWorkspaceLaunchConfiguration else { throw ApplicationModelError.localACPRuntimeUnavailable }
        return workspace.rootURL.path
    }

    func prepareCreatedOpenClawSession(_ target: WorkspaceConversationRecord,
                                       configuration: WorkspaceSessionCreationConfiguration) async throws {
        guard let store = dashboardStore, let agentID = target.agentID.flatMap(UUID.init(uuidString:)),
              isOpenClawGatewayLinked(agentID: agentID) else {
            throw WorkspaceToolError.invalid("Connect OpenClaw in this workspace's settings before creating its sessions.")
        }
        let descriptor = try? store.database.openClawGatewaySession(conversationID: target.id)
        let key = descriptor?.sessionKey ?? "agent:main:wovenmatter:\(target.id)"
        let directory: URL
        if let path = configuration.nativeWorkingDirectory { directory = URL(fileURLWithPath: path) }
        else if let workspaceID = target.remoteWorkspaceID, let workspace = remoteWorkspaces.configuration(id: workspaceID) {
            directory = URL(fileURLWithPath: remoteWorkspaces.remoteWorkspaceRoot(for: workspace))
        } else if let workspace = localACPWorkspaceLaunchConfiguration { directory = workspace.rootURL }
        else { throw ApplicationModelError.localACPRuntimeUnavailable }
        try await store.createOpenClawWorkspaceSession(agentID: agentID, sessionKey: key, cwd: directory, recover: true)
        if descriptor == nil {
            try await store.attachOpenClawGatewaySession(conversationID: target.id, agentID: agentID, sessionKey: key)
        }
        openClawGatewayConversationIDs.insert(target.id)
    }

    func createLocalACPSession(
        runtimeKind: AgentRuntimeKind,
        requestedConversationID: UUID? = nil,
        nativeWorkingDirectory: URL? = nil,
        initialTitle: String? = nil,
        nativeWorkspaceID: String? = nil
    ) async -> String? {
        if runtimeKind == .hermes {
            do { try requireLocalHermesLink(openSettings: true) }
            catch { localRunError = error.localizedDescription; return nil }
        }
        if runtimeKind == .opencode {
            do {
                guard let openCode else { throw OpenCodeError.message("OpenCode is still starting.") }
                guard let workspace = localACPWorkspaceLaunchConfiguration else { throw ApplicationModelError.localACPRuntimeUnavailable }
                let id = try await openCode.create(workspace: nativeWorkingDirectory ?? workspace.rootURL, requestedConversationID: requestedConversationID, title: initialTitle, nativeWorkspaceID: nativeWorkspaceID)
                await refreshWorkspace()
                return id
            } catch { localRunError = error.localizedDescription; return nil }
        }
        guard localACPLaunchConfigurations[runtimeKind] != nil,
              let creationWorkspace = localACPWorkspaceLaunchConfiguration,
              isLocalACPAgentReady(runtimeKind) else {
            localRunError = ApplicationModelError.localACPRuntimeUnavailable.localizedDescription
            return nil
        }
        let capturedDefaults = sessionSelectionPreferences.defaults(harness: runtimeKind.rawValue,
            workspace: "local:" + creationWorkspace.rootURL.standardizedFileURL.path)
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let openClawAgent = runtimeKind == .openclaw
                ? localCLIAgents.first(where: { $0.runtimeKind == .openclaw }) : nil
            let gatewayKey = Self.openClawSessionKey(conversationID: (requestedConversationID ?? UUID()).uuidString.lowercased())
            if let agent = openClawAgent, isOpenClawGatewayLinked(agentID: agent.id),
               let workspace = localACPWorkspaceLaunchConfiguration {
                try await dashboardStore.createOpenClawWorkspaceSession(agentID: agent.id, sessionKey: gatewayKey,
                    cwd: nativeWorkingDirectory ?? workspace.rootURL, recover: requestedConversationID != nil)
            }
            let conversationID = try await dashboardStore.createLocalACPSession(
                runtimeKind: runtimeKind,
                title: "New \(runtimeKind.displayName) chat",
                requestedConversationID: requestedConversationID
            )
            if runtimeKind == .openclaw,
               let agent = localCLIAgents.first(where: { $0.runtimeKind == .openclaw }),
               isOpenClawGatewayLinked(agentID: agent.id) {
                try await dashboardStore.attachOpenClawGatewaySession(
                    conversationID: conversationID,
                    agentID: agent.id,
                    sessionKey: gatewayKey
                )
                openClawGatewayConversationIDs.insert(conversationID)
            }
            do { try await prepareNewSessionSelections(conversationID: conversationID, capturedDefaults: capturedDefaults) }
            catch { ensureConversationState(id: conversationID).setError(error.localizedDescription) }
            localRunError = nil
            await refreshWorkspace()
            return conversationID
        } catch {
            NSLog(
                "Could not create %@ local ACP chat: %@",
                runtimeKind.rawValue,
                String(describing: error)
            )
            localRunError = error is WorkspaceDatabaseError
                ? "Woven Matter could not save this local chat. Reopen the app and try again."
                : error.localizedDescription
            return nil
        }
    }

    func createRemoteACPSession(
        target: RemoteHarnessChatTarget,
        requestedConversationID: UUID? = nil,
        nativeWorkingDirectory: URL? = nil,
        initialTitle: String? = nil,
        nativeWorkspaceID: String? = nil
    ) async -> String? {
        guard remoteWorkspaces.isHarnessReady(
            target.harness.id,
            in: target.configuration
        ) else {
            localRunError = "This remote harness is not ready. Refresh it in Settings and try again."
            return nil
        }
        let capturedDefaults = sessionSelectionPreferences.defaults(harness: target.harness.id.rawValue,
            workspace: "remote:" + target.configuration.id.uuidString.lowercased())
        do {
            if target.harness.id == .opencode {
                await synchronizeRemoteOpenCodeInstances()
                guard let instance = remoteOpenCodes[target.configuration.id] else {
                    throw ApplicationModelError.remoteHarnessUnavailable
                }
                try await instance.connectLocal()
                let directory = remoteWorkspaces.remoteWorkspaceRoot(for: target.configuration)
                let id = try await instance.create(workspace: nativeWorkingDirectory ?? URL(fileURLWithPath: directory), requestedConversationID: requestedConversationID, title: initialTitle, nativeWorkspaceID: nativeWorkspaceID)
                await refreshWorkspace()
                return id
            }
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            var unlinkedOpenClawAgentID: UUID?
            let conversationID = try await dashboardStore.createRemoteACPSession(
                runtimeKind: target.harness.id,
                remoteWorkspaceID: target.configuration.id,
                remoteWorkspaceName: target.configuration.name,
                title: "New \(target.harness.displayName) chat",
                requestedConversationID: requestedConversationID
            )
            if target.harness.id == .openclaw {
                let agentID = try await dashboardStore.ensureRemoteHarnessAgent(
                    runtimeKind: .openclaw,
                    remoteWorkspaceID: target.configuration.id,
                    remoteWorkspaceName: target.configuration.name
                )
                if isOpenClawGatewayLinked(agentID: agentID) {
                    try await dashboardStore.attachOpenClawGatewaySession(
                        conversationID: conversationID,
                        agentID: agentID,
                        sessionKey: Self.openClawSessionKey(
                            conversationID: conversationID
                        )
                    )
                    openClawGatewayConversationIDs.insert(conversationID)
                } else {
                    unlinkedOpenClawAgentID = agentID
                }
            }
            do { try await prepareNewSessionSelections(conversationID: conversationID, capturedDefaults: capturedDefaults) }
            catch { ensureConversationState(id: conversationID).setError(error.localizedDescription) }
            localRunError = nil
            await refreshWorkspace()
            pendingOpenClawGatewayAgentID = unlinkedOpenClawAgentID
            return conversationID
        } catch {
            localRunError = error.localizedDescription
            return nil
        }
    }

    func directACPLaunchContext(
        conversation: WorkspaceConversationRecord,
        runtimeKind: AgentRuntimeKind,
        isBuzzWorkspaceSession: Bool
    ) throws -> RemoteHarnessLaunchContext? {
        if isBuzzWorkspaceSession { return nil }
        let savedDirectory = try dashboardStore?.database.toolSessionCreationConfiguration(targetID: conversation.id)?.nativeWorkingDirectory
        let inheritedRoot = savedDirectory.map { URL(fileURLWithPath: $0) }
        if let remoteWorkspaceID = conversation.remoteWorkspaceID {
            guard let configuration = remoteWorkspaces.configuration(
                id: remoteWorkspaceID
            ), remoteWorkspaces.isHarnessReady(runtimeKind, in: configuration) else {
                throw ApplicationModelError.remoteHarnessUnavailable
            }
            let processDirectory = localACPWorkspaceLaunchConfiguration?.rootURL
                ?? FileManager.default.homeDirectoryForCurrentUser
            if runtimeKind == .hermes {
                guard let connection = remoteHermesConnections[remoteWorkspaceID] else {
                    throw HermesGatewayError.message("Connect Hermes in this remote workspace's settings first.")
                }
                let encoded = try JSONEncoder().encode(connection).base64EncodedString()
                let workspaceRoot = URL(fileURLWithPath: remoteWorkspaces.remoteWorkspaceRoot(for: configuration))
                let root = inheritedRoot ?? workspaceRoot
                return RemoteHarnessLaunchContext(launch: LocalACPRuntimeLaunchConfiguration(runtimeKind: .hermes,
                    executableURL: URL(fileURLWithPath: "/usr/bin/ssh"), arguments: [], environment: ["WOVENMATTER_HERMES_CONNECTION": encoded],
                    processWorkingDirectoryURL: processDirectory), workspace: LocalACPWorkspaceLaunchConfiguration(rootURL: root, repositoriesURL: workspaceRoot.appending(path: "REPOS"), databasesURL: workspaceRoot.appending(path: "Databases")))
            }
            return try RemoteHarnessLaunchResolver.resolve(
                configuration: configuration,
                runtimeKind: runtimeKind,
                processWorkingDirectory: processDirectory,
                workspaceRoot: URL(fileURLWithPath: remoteWorkspaces.remoteWorkspaceRoot(for: configuration)),
                workingDirectory: inheritedRoot
            )
        }
        if runtimeKind == .hermes { try requireLocalHermesLink(conversationID: conversation.id) }
        guard let launch = localACPLaunchConfigurations[runtimeKind],
              let workspace = localACPWorkspaceLaunchConfiguration else {
            throw ApplicationModelError.localACPRuntimeUnavailable
        }
        if let inheritedRoot {
            var scopedLaunch = LocalACPRuntimeLaunchConfiguration(runtimeKind: launch.runtimeKind,
                executableURL: launch.executableURL, arguments: launch.arguments, environment: launch.environment,
                environmentKeysToRemove: launch.environmentKeysToRemove,
                environmentKeyPrefixesToRemove: launch.environmentKeyPrefixesToRemove,
                processWorkingDirectoryURL: inheritedRoot)
            scopedLaunch.historyRecorder = launch.historyRecorder
            return .init(launch: scopedLaunch, workspace: .init(rootURL: inheritedRoot,
                repositoriesURL: workspace.repositoriesURL, databasesURL: workspace.databasesURL))
        }
        return RemoteHarnessLaunchContext(
            launch: launch,
            workspace: workspace
        )
    }

    func createBuzzWorkspaceLocalACPSession(
        enrollment: BuzzWorkspaceAgentEnrollment
    ) async -> String? {
        guard launchableBuzzWorkspaceEnrollmentIDs.contains(enrollment.id) else {
            localRunError = "The selected Buzz agent is not available from its linked workspace."
            return nil
        }
        let capturedDefaults = sessionSelectionPreferences.defaults(harness: enrollment.runtimeKind?.rawValue ?? enrollment.harnessIdentifier,
            workspace: "buzz:" + enrollment.workspaceLinkID.uuidString.lowercased())
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let conversationID = try await dashboardStore
                .createBuzzWorkspaceLocalACPSession(
                    enrollmentID: enrollment.id,
                    title: "New \(enrollment.displayNameSnapshot) chat"
                )
            buzzBoundLocalACPConversationIDs.insert(conversationID)
            if isOpenClawGatewayLinked(agentID: enrollment.id) {
                try await dashboardStore.attachOpenClawGatewaySession(
                    conversationID: conversationID,
                    agentID: enrollment.id,
                    sessionKey: Self.openClawSessionKey(conversationID: conversationID)
                )
                openClawGatewayConversationIDs.insert(conversationID)
            }
            do { try await prepareNewSessionSelections(conversationID: conversationID, capturedDefaults: capturedDefaults) }
            catch { ensureConversationState(id: conversationID).setError(error.localizedDescription) }
            localRunError = nil
            await refreshWorkspace()
            return conversationID
        } catch {
            localRunError = error.localizedDescription
            await refreshBuzzWorkspaces()
            return nil
        }
    }

    func refreshRuntimeInventory() {
        guard !checkingRuntimeInventory, checkingRuntimeKinds.isEmpty, installingLocalACPRuntimeKinds.isEmpty,
              preparedLocalACPRuntimeInstall == nil else { return }
        checkingRuntimeInventory = true
        runtimeInventoryGeneration &+= 1
        let generation = runtimeInventoryGeneration
        let enabled = enabledLocalACPRuntimeKinds
        let openCodeEnabled = openCode?.isEnabled == true
        Task {
            defer { checkingRuntimeInventory = false }
            await openCode?.resolveExecutable()
            let selectedOpenCode = openCode?.runtimeExecutable
            for definition in LocalACPRuntimeCatalog.definitions {
                guard installingLocalACPRuntimeKinds.isEmpty else { return }
                let kind = definition.runtimeKind
                checkingRuntimeKinds.insert(kind)
                let checkLatest = kind == .opencode ? openCodeEnabled : enabled.contains(kind)
                let inventory = await Task.detached(priority: .utility) {
                    await RuntimeMaintenance.inspect(kind, checkLatest: checkLatest, selectedOpenCode: selectedOpenCode)
                }.value
                checkingRuntimeKinds.remove(kind)
                guard installingLocalACPRuntimeKinds.isEmpty, generation == runtimeInventoryGeneration else { return }
                runtimeInventories[kind] = inventory
                if checkLatest { checkedRuntimeKinds.insert(kind) }
            }
        }
    }

    func checkRuntimeUpdate(_ kind: AgentRuntimeKind) {
        guard !checkingRuntimeInventory, checkingRuntimeKinds.insert(kind).inserted else { return }
        guard installingLocalACPRuntimeKinds.isEmpty, openCode?.isInstalling != true else {
            checkingRuntimeKinds.remove(kind)
            return
        }
        let generation = runtimeInventoryGeneration
        Task {
            defer { checkingRuntimeKinds.remove(kind) }
            if kind == .opencode { await openCode?.resolveExecutable() }
            let selectedOpenCode = openCode?.runtimeExecutable
            let inventory = await Task.detached(priority: .utility) {
                await RuntimeMaintenance.inspect(kind, checkLatest: true, selectedOpenCode: selectedOpenCode)
            }.value
            guard installingLocalACPRuntimeKinds.isEmpty, generation == runtimeInventoryGeneration else { return }
            runtimeInventories[kind] = inventory
            checkedRuntimeKinds.insert(kind)
        }
    }

    func runtimeDiagnostic(_ kind: AgentRuntimeKind) -> String {
        RuntimeMaintenance.diagnostic(inventory: runtimeInventories[kind], kind: kind,
            attempts: runtimeFailures[kind, default: 0], failure: runtimeFailureDetails[kind] ?? "unknown")
    }

    private func recordRuntimeFailure(_ kind: AgentRuntimeKind, error: any Error, update: Bool = false) {
        runtimeFailures[kind, default: 0] += 1
        if update { failedRuntimeUpdateKinds.insert(kind) }
        // Never copy arbitrary subprocess output or URLs into diagnostics.
        let category: String
        if let failure = error as? RuntimeMaintenanceError { category = failure.localizedDescription }
        else if let failure = error as? LocalACPRuntimeInstallError {
            switch failure {
            case .installFailed: category = "Installer exited unsuccessfully (output omitted)."
            case .executableMissing: category = "Installer did not produce the required executable."
            default: category = failure.localizedDescription
            }
        } else { category = "Runtime operation failed (private details omitted)." }
        runtimeFailureDetails[kind] = category
        localRunError = category
    }

    private func usesLocallyInstalledRuntime(_ conversation: WorkspaceConversationRecord) -> Bool {
        conversation.localRuntimeKind != nil && conversation.remoteWorkspaceID == nil
            && !buzzBoundLocalACPConversationIDs.contains(conversation.id)
            && !isOpenClawGatewayConversation(conversation.id)
    }

    var localRuntimeMaintenanceHasActiveConversation: Bool {
        localRunningConversationIDs.contains { id in
            if buzzBoundLocalACPConversationIDs.contains(id) || isOpenClawGatewayConversation(id) { return false }
            // A newly accepted turn may precede the workspace snapshot refresh.
            // Keep maintenance blocked until its execution location is known.
            guard let conversation = workspaceOverview?.conversations.first(where: { $0.id == id }) else { return true }
            return usesLocallyInstalledRuntime(conversation)
        }
    }

    func installLocalACPRuntimeComponent(_ runtimeKind: AgentRuntimeKind) {
        // Finish the initial inventory before an install invalidates its generation.
        // Otherwise the remaining runtime rows can be left without an inventory.
        guard !checkingRuntimeInventory, installingLocalACPRuntimeKinds.isEmpty, openCode?.isInstalling != true, preparedLocalACPRuntimeInstall == nil,
              !localRuntimeMaintenanceHasActiveConversation,
              let definition = LocalACPRuntimeCatalog.definition(for: runtimeKind) else { return }
        let inventory = runtimeInventories[runtimeKind]
        let cliMissing = definition.underlyingCLIName.map { name in
            inventory?.components.contains { $0.name == name + " (sign-in CLI)" && !$0.present } == true
        } ?? false
        let needsCLI = cliMissing || (definition.adapterPackage == nil && inventory?.isInstalled != true)
        if needsCLI {
            runtimeInventoryGeneration &+= 1
            installingLocalACPRuntimeKinds.insert(runtimeKind)
            localRunError = nil
            Task {
                defer { installingLocalACPRuntimeKinds.remove(runtimeKind) }
                do {
                    let preview = try await localACPRuntimeInstaller.prepareCLIInstall(definition)
                    preparedLocalACPRuntimeInstall = PreparedLocalACPRuntimeInstall(definition: definition, preview: preview)
                } catch { recordRuntimeFailure(runtimeKind, error: error) }
            }
        } else { performRuntimeMaintenance(definition, update: false) }
    }

    func updateRuntime(_ kind: AgentRuntimeKind) {
        guard let definition = LocalACPRuntimeCatalog.definition(for: kind) else { return }
        performRuntimeMaintenance(definition, update: true)
    }

    func confirmPreparedLocalACPRuntimeInstall() {
        guard let prepared = preparedLocalACPRuntimeInstall else { return }
        preparedLocalACPRuntimeInstall = nil
        performRuntimeMaintenance(prepared.definition, update: false, preview: prepared.preview)
    }

    func cancelPreparedLocalACPRuntimeInstall() { preparedLocalACPRuntimeInstall = nil }

    private func performRuntimeMaintenance(_ definition: LocalACPRuntimeDefinition, update: Bool,
                                          preview: LocalACPInstallerPreview? = nil) {
        let kind = definition.runtimeKind
        guard !checkingRuntimeInventory, installingLocalACPRuntimeKinds.isEmpty, openCode?.isInstalling != true,
              preparedLocalACPRuntimeInstall == nil, !localRuntimeMaintenanceHasActiveConversation else { return }
        runtimeInventoryGeneration &+= 1
        installingLocalACPRuntimeKinds.insert(kind)
        if update { updatingRuntimeKinds.insert(kind) }
        localRunError = nil
        let installer = localACPRuntimeInstaller
        let before = runtimeInventories[kind]
        Task {
            defer { installingLocalACPRuntimeKinds.remove(kind); updatingRuntimeKinds.remove(kind) }
            do {
                if let preview {
                    _ = try await installer.install(definition, component: .cli,
                        expectedSourceSHA256: preview.sha256, expectedPackageSpec: preview.packageSpec)
                }
                if let package = definition.adapterPackage ?? (kind == .pi && preview == nil ? RuntimeMaintenance.npmPackage(kind) : nil) {
                    // Resolve a concrete version before npm is allowed to mutate anything.
                    let version: String
                    do { version = try await RuntimeMaintenance.registryVersion(package) }
                    catch {
                        guard !update, let pinned = definition.minimumAdapterVersion else { throw error }
                        version = pinned
                    }
                    _ = try await installer.installPackage(package, version: version, executableName: definition.commandName)
                } else if update {
                    try await RuntimeMaintenance.updateNative(kind, executable: before?.components.first?.executable)
                }
                if update, definition.adapterPackage != nil,
                   let cli = before?.components.first(where: { $0.name.hasSuffix("(sign-in CLI)") && $0.outdated }) {
                    try await RuntimeMaintenance.updateNative(kind, executable: cli.executable)
                }
                let inventory = await Task.detached(priority: .utility) {
                    await RuntimeMaintenance.inspect(kind, checkLatest: true)
                }.value
                runtimeInventories[kind] = inventory
                checkedRuntimeKinds.insert(kind)
                guard inventory.isInstalled else { throw RuntimeMaintenanceError.verification }
                if update {
                    // Success requires the outdated components to reach the observed
                    // target, not merely an exit-zero updater or a changed PATH.
                    for component in before?.components.filter(\.outdated) ?? [] {
                        guard let after = inventory.components.first(where: { $0.name == component.name }),
                              let installed = after.installed, let target = component.latest,
                              installed == target || RuntimeMaintenance.version(target, precedes: installed)
                        else { throw RuntimeMaintenanceError.verification }
                    }
                }
                runtimeFailures[kind] = 0; runtimeFailureDetails[kind] = nil
                failedRuntimeUpdateKinds.remove(kind)
                await refreshLocalACPRuntimes()
            } catch { recordRuntimeFailure(kind, error: error, update: update) }
        }
    }

    private(set) var pendingHermesSettingsAgentID: UUID?
    private(set) var hermesGatewayConnections: [UUID: HermesGatewayConnection] = [:]
    private(set) var hermesCronJobs: [UUID: [HermesValue]] = [:]
    private(set) var hermesCronResults: [UUID: [HermesScheduledResult]] = [:]
    private(set) var hermesResultRoutes: [UUID: [String: String]] = [:]
    private(set) var hermesCronErrors: [UUID: String] = [:]
    private(set) var isRefreshingHermesCron = false
    private var lastHermesCronRefresh = Date.distantPast
    private(set) var remoteHermesConnections: [UUID: HermesGatewayConnection] = [:]
    private(set) var hermesGatewayCheckedAt: [UUID: Date] = [:]

    func dismissPendingHermesSettings() { pendingHermesSettingsAgentID = nil }

    private func requireLocalHermesLink(conversationID: String? = nil, openSettings: Bool = false) throws {
        guard let agent = localCLIAgents.first(where: { $0.runtimeKind == .hermes }) else {
            throw HermesGatewayError.message("Enable Hermes in Local agent workspace first.")
        }
        guard isHermesGatewayLinked(agentID: agent.id) else {
            if openSettings { pendingHermesSettingsAgentID = agent.id }
            throw HermesGatewayError.message("Connect this Hermes agent's Gateway in Settings before starting or continuing a chat.")
        }
        if let conversationID,
           let stored = try dashboardStore?.database.localACPSession(conversationID: conversationID).acpSessionID,
           let home = HermesGatewayClient.parseIdentity(stored).home,
           home != applicationDefaults.string(forKey: "hermes.gateway.link." + agent.id.uuidString) {
            throw HermesGatewayError.message("This chat belongs to another Hermes profile. Select and connect that profile before continuing.")
        }
    }

    func isHermesGatewayLinked(agentID: UUID) -> Bool {
        guard enabledLocalACPRuntimeKinds.contains(.hermes),
              let launch = localACPLaunchConfigurations[.hermes] else { return false }
        let home = launch.environment["HERMES_HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".hermes").path
        return applicationDefaults.string(forKey: "hermes.gateway.link." + agentID.uuidString) == home
    }

    func connectHermesGateway(agentID: UUID, restart: Bool = false) async throws {
        guard localCLIAgents.contains(where: { $0.id == agentID && $0.runtimeKind == .hermes }) else {
            throw HermesGatewayError.message("This Hermes agent is no longer available.")
        }
        hermesGatewayConnections[agentID] = nil
        let connected: HermesGatewayConnection
        if restart {
            let current = try await hermesGatewayConnection()
            try await HermesGatewayService.shared.stopIfIdle(home: current.home)
        }
        connected = try await hermesGatewayConnection()
        let client = HermesGatewayRPC(connection: connected)
        do {
            try await client.connect()
            let setup = try await client.call("setup.runtime_check")
            guard setup["ok"].bool else {
                throw HermesGatewayError.message("Hermes needs provider setup. Run hermes model for this profile, then reconnect.")
            }
            await client.disconnect()
        } catch { await client.disconnect(); throw error }
        hermesGatewayConnections[agentID] = connected
        hermesGatewayCheckedAt[agentID] = Date()
        localRunError = nil
        applicationDefaults.set(connected.home, forKey: "hermes.gateway.link." + agentID.uuidString)
    }

    func invalidateHermesGatewayConnection(agentID: UUID, expected: HermesGatewayConnection) {
        guard hermesGatewayConnections[agentID] == expected else { return }
        hermesGatewayConnections[agentID] = nil
    }

    func unlinkHermesGateway(agentID: UUID) {
        hermesGatewayConnections[agentID] = nil
        hermesGatewayCheckedAt[agentID] = nil
        applicationDefaults.removeObject(forKey: "hermes.gateway.link." + agentID.uuidString)
    }

    func renameHermesAgent(agentID: UUID, displayName: String) async throws {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        try dashboardStore.database.renameHermesAgent(id: agentID, displayName: displayName)
        await refreshWorkspace()
    }

    var hermesCronAgents: [WorkspaceAgent] {
        localCLIAgents.filter { $0.runtimeKind == .hermes && isHermesGatewayLinked(agentID:$0.id) }
          + remoteWorkspaceAgents.filter { agent in
              agent.runtimeKind == .hermes && agent.runtimeDeviceID.map { applicationDefaults.bool(forKey:"hermes.remote.link." + $0.uuidString) } == true
          }
    }

    private func cronHermesConnection(agent: WorkspaceAgent) async throws -> HermesGatewayConnection {
        if let workspaceID = agent.runtimeDeviceID, let configuration = remoteWorkspaces.configuration(id:workspaceID) {
            let connection = try await remoteWorkspaces.prepareHermesConnection(for:configuration)
            remoteHermesConnections[workspaceID] = connection
            return connection
        }
        guard isHermesGatewayLinked(agentID:agent.id) else { throw HermesGatewayError.message("Connect Hermes in Settings first.") }
        return try await hermesGatewayConnection()
    }

    func refreshHermesCron() async {
        guard !isRefreshingHermesCron, let dashboardStore else { return }
        isRefreshingHermesCron = true
        lastHermesCronRefresh = Date()
        defer { isRefreshingHermesCron = false }
        for agent in hermesCronAgents {
            do {
                let connection = try await cronHermesConnection(agent:agent)
                let query = try await HermesDelivery.profileQuery(connection:connection)
                let document = try await HermesSessionHistory.fetch(connection:connection,path:"/api/cron/jobs" + query)
                guard case .array(let jobs) = document, jobs.allSatisfy({!$0["id"].text.isEmpty}) else {
                    throw HermesGatewayError.message("Hermes returned an incomplete scheduled-job list.")
                }
                hermesCronJobs[agent.id] = jobs
                let sourcePrefix=connection.identity + "::"
                hermesResultRoutes[agent.id] = Dictionary(uniqueKeysWithValues: try dashboardStore.database.hermesResultRoutes(agentID:agent.id).filter{$0.key.hasPrefix(sourcePrefix)}.map{(String($0.key.dropFirst(sourcePrefix.count)),$0.value)})
                let owner = try await dashboardStore.dashboardDeviceID()
                var offset = 0
                var all:[HermesScheduledResult] = []
                var collectionError: String?
                while true {
                    try Task.checkCancellation()
                    let page:[HermesScheduledResult]
                    if let workspaceID=connection.remoteWorkspaceID, let configuration=remoteWorkspaces.configuration(id:workspaceID) {
                        page = try await remoteWorkspaces.hermesResults(for:configuration,offset:offset)
                    } else {
                        page = try HermesResultQueue.read(home:connection.home,offset:offset)
                    }
                    guard hermesCronAgents.contains(where:{$0.id == agent.id}) else { throw CancellationError() }
                    for result in page {
                      do {
                        _ = try dashboardStore.database.collectHermesResult(agentID:agent.id,jobID:connection.identity + "::" + result.jobID,runID:result.runID,
                            title:jobs.first(where:{$0["id"].text == result.jobID})?["name"].string ?? "Hermes scheduled result",output:result.output,
                            ownerDeviceID:owner,remoteWorkspaceID:connection.remoteWorkspaceID,
                            remoteWorkspaceName:connection.remoteWorkspaceID.flatMap{remoteWorkspaces.configuration(id:$0)?.name} ?? "")
                      } catch { collectionError = collectionError ?? error.localizedDescription }
                    }
                    all.append(contentsOf:page)
                    if page.count < 100 { break }
                    offset += page.count
                }
                hermesCronResults[agent.id] = all
                hermesCronErrors[agent.id] = collectionError
            } catch { hermesCronErrors[agent.id] = error.localizedDescription }
        }
    }

    func continueHermesResult(agent:WorkspaceAgent,result:HermesScheduledResult) async -> String? {
        guard let dashboardStore else { return nil }
        do {
            let connection=try await cronHermesConnection(agent:agent)
            let existing=try dashboardStore.database.hermesResultConversation(agentID:agent.id,jobID:connection.identity + "::" + result.jobID,runID:result.runID)
            let id:String
            if let existing { id=existing }
            else if let workspaceID=connection.remoteWorkspaceID,let configuration=remoteWorkspaces.configuration(id:workspaceID) {
                id=try await dashboardStore.createRemoteACPSession(runtimeKind:.hermes,remoteWorkspaceID:workspaceID,remoteWorkspaceName:configuration.name,title:"Hermes scheduled result")
            } else {
                guard let created=await createLocalACPSession(runtimeKind:.hermes) else { return nil }
                id=created
            }
            pendingComposerPrefills[id]="Discuss this scheduled result.\n\n" + result.output
            await refreshWorkspace()
            return id
        } catch { hermesCronErrors[agent.id]=error.localizedDescription;return nil }
    }

    private func hermesDeliveryTargets(agentID:UUID,jobID:String) -> String {
        let current=hermesCronJobs[agentID]?.first(where:{$0["id"].text == jobID})?["deliver"].string ?? "local"
        var targets=current.split(separator:",").map{String($0).trimmingCharacters(in:.whitespaces)}.filter{!$0.isEmpty && $0 != "local" && !$0.hasPrefix("wovenmatter:")}
        targets.append("wovenmatter:" + jobID)
        return targets.joined(separator:",")
    }

    func createHermesCron(agent:WorkspaceAgent,name:String,schedule:String,prompt:String) async -> Bool {
        do {
            let connection=try await cronHermesConnection(agent:agent)
            let job = try await HermesSessionHistory.fetch(connection:connection,path:"/api/cron/jobs" + (try await HermesDelivery.profileQuery(connection:connection)),method:"POST",
                body:["name":.string(name),"schedule":.string(schedule),"prompt":.string(prompt),"paused":.bool(true),"deliver":"local"])
            guard let jobID = job["id"].string, !jobID.isEmpty else { throw HermesGatewayError.message("Hermes created no identifiable scheduled job.") }
            await refreshHermesCron()
            await setHermesResultRoute(agent: agent, jobID: jobID, destination: "")
            return true
        } catch { hermesCronErrors[agent.id]=error.localizedDescription;return false }
    }

    func setHermesResultRoute(agent:WorkspaceAgent, jobID:String, destination:String) async {
        guard let dashboardStore else { return }
        do {
            var connection = try await cronHermesConnection(agent:agent)
            let needsRestart = try await HermesDelivery.enable(connection:connection)
            if needsRestart, let workspaceID=connection.remoteWorkspaceID, let configuration=remoteWorkspaces.configuration(id:workspaceID) {
                try await remoteWorkspaces.restartHermes(for:configuration)
            } else if needsRestart { try await HermesGatewayService.shared.stopIfIdle(home:connection.home) }
            connection = try await cronHermesConnection(agent:agent)
            let id = jobID.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!
            _ = try await HermesSessionHistory.fetch(connection:connection,path:"/api/cron/jobs/" + id + (try await HermesDelivery.profileQuery(connection:connection)),method:"PUT",
                body:["updates":["deliver":.string(hermesDeliveryTargets(agentID:agent.id,jobID:jobID))]])
            try dashboardStore.database.setHermesResultRoute(agentID:agent.id,jobID:connection.identity + "::" + jobID,destination:destination)
            await refreshHermesCron()
            await refreshWorkspace()
        } catch { hermesCronErrors[agent.id] = error.localizedDescription }
    }

    func changeHermesCron(agent:WorkspaceAgent,jobID:String,action:String) async {
        guard ["pause","resume"].contains(action) else { return }
        do {
            let connection=try await cronHermesConnection(agent:agent)
            let id=jobID.addingPercentEncoding(withAllowedCharacters:.alphanumerics)!
            _ = try await HermesSessionHistory.fetch(connection:connection,path:"/api/cron/jobs/"+id+"/"+action + (try await HermesDelivery.profileQuery(connection:connection)),method:"POST")
            await refreshHermesCron()
        } catch { hermesCronErrors[agent.id]=error.localizedDescription }
    }

    func stopRemoteHermes(_ configuration:RemoteWorkspaceConfiguration) async throws {
        applicationDefaults.set(false,forKey:"hermes.remote.link." + configuration.id.uuidString)
        do { try await remoteWorkspaces.restartHermes(for:configuration,action:"stop") }
        catch { applicationDefaults.set(true,forKey:"hermes.remote.link." + configuration.id.uuidString);throw error }
        remoteHermesConnections[configuration.id]=nil
        remoteWorkspaces.refresh(configuration)
    }

    func connectRemoteHermes(_ configuration: RemoteWorkspaceConfiguration) async throws {
        let connection = try await remoteWorkspaces.prepareHermesConnection(for: configuration)
        let rpc = HermesGatewayRPC(connection: connection)
        do { try await rpc.connect(); await rpc.disconnect() }
        catch { await rpc.disconnect(); throw error }
        guard remoteWorkspaces.configuration(id: configuration.id) == configuration else { throw CancellationError() }
        remoteHermesConnections[configuration.id] = connection
        applicationDefaults.set(true, forKey:"hermes.remote.link." + configuration.id.uuidString)
        remoteWorkspaces.refresh(configuration)
    }

    func hermesGatewayConnection() async throws -> HermesGatewayConnection {
        guard enabledLocalACPRuntimeKinds.contains(.hermes), let launch = localACPLaunchConfigurations[.hermes] else {
            throw HermesGatewayError.message("Enable Hermes in Local agent workspace, then refresh this page.")
        }
        return try await HermesGatewayService.shared.ensure(launch: launch)
    }

    func knownHermesSessions(home: String) throws -> Set<String> {
        try dashboardStore?.database.knownHermesSessionIDs(home: home) ?? []
    }

    func importHermesSession(connection: HermesGatewayConnection, sessionID: String) async throws {
        guard let dashboardStore else { throw ApplicationModelError.dashboardStoreUnavailable }
        try requireLocalHermesLink()
        guard localCLIAgents.contains(where: { $0.runtimeKind == .hermes && hermesGatewayConnections[$0.id] == connection }) else {
            throw HermesGatewayError.message("The Hermes connection changed. Reconnect before importing.")
        }
        guard try !dashboardStore.database.knownHermesSessionIDs(home: connection.home).contains(sessionID) else { return }
        let snapshot = try await HermesSessionHistory.load(connection: connection, sessionID: sessionID)
        let owner = try await dashboardStore.dashboardDeviceID()
        _ = try dashboardStore.database.createLocalACPSession(runtimeKind: .hermes, title: snapshot.title,
            ownerDeviceID: owner, createdAt: snapshot.createdAt, hermesImport: snapshot)
        await refreshWorkspace()
    }

    func refreshLocalACPRuntimesNow(checkCredentialsFor runtimeKinds: Set<AgentRuntimeKind> = []) {
        Task { await refreshLocalACPRuntimes(checkCredentialsFor: runtimeKinds) }
    }

    func setTitleGenerationEnabled(_ enabled: Bool) {
        titleGenerationSettings.isEnabled = enabled
        applicationDefaults.set(
            enabled,
            forKey: Self.titleGenerationEnabledDefaultsKey
        )
    }

    func setTitleGenerationModel(_ model: String) {
        titleGenerationSettings.model = model
        applicationDefaults.set(
            model,
            forKey: Self.titleGenerationModelDefaultsKey
        )
    }

    func setTitleGenerationThinking(_ thinking: String) {
        titleGenerationSettings.thinking = thinking
        applicationDefaults.set(
            thinking,
            forKey: Self.titleGenerationThinkingDefaultsKey
        )
    }

    func refreshTitleGenerationCapabilitiesNow() {
        Task { await refreshTitleGenerationCapabilities() }
    }

    func setUpLocalACPWorkspace(homeDirectory: URL) {
        Task {
            do {
                try await localACPWorkspaceStore.setUpWorkspace(
                    in: homeDirectory
                )
                localRunError = nil
                await refreshLocalACPWorkspace()
                await refreshLocalACPRuntimes()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func configureLocalACPRepositories(_ repositoriesURL: URL?) {
        Task {
            do {
                try await localACPWorkspaceStore.configureRepositories(
                    repositoriesURL
                )
                localRunError = nil
                await refreshLocalACPWorkspace()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func configureLocalACPDatabases(_ databasesURL: URL?) {
        Task {
            do {
                try await localACPWorkspaceStore.configureDatabases(databasesURL)
                localRunError = nil
                await refreshLocalACPWorkspace()
                await refreshDatabases()
            } catch {
                localRunError = error.localizedDescription
            }
        }
    }

    func resolveLocalACPPermission(id: UUID, optionID: String?) {
        guard let continuation = localACPPermissionContinuations.removeValue(forKey: id) else {
            return
        }
        pendingLocalACPPermissions.removeAll { $0.id == id }
        continuation.resume(returning: optionID)
    }

    func resolveLocalACPInteraction(
        id: UUID,
        response: LocalACPInteractionResponse
    ) {
        guard let continuation = localACPInteractionContinuations.removeValue(
            forKey: id
        ) else { return }
        pendingLocalACPInteractions.removeAll { $0.id == id }
        continuation.resume(returning: response)
    }

    func cancelLocalACPPrompt(conversationID: String) {
        if let openCode = openCodeModel(for: conversationID), openCode.links[conversationID] != nil {
            openCode.perform { _ = try await openCode.sessionCall(conversationID, "/interrupt", method: "POST") }
            return
        }
        let permissionIDs = pendingLocalACPPermissions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        cancelLocalACPInteractions(conversationID: conversationID)
        Task {
            await dashboardStore?.cancelLocalACPPrompt(conversationID: conversationID)
        }
    }

    func shutdownLocalACPSessions() {
        toolRuntimeTask?.cancel()
        agentTools?.stop()
        for task in toolCreationTasks.values { task.cancel() }
        toolCreationTasks.removeAll()
        try? dashboardStore?.database.cancelPendingCoordinationAccess()
        pendingSessionAccess.removeAll()
        for task in applyingSessionSelectionTasks.values { task.cancel() }
        applyingSessionSelectionTasks.removeAll()
        let permissionIDs = pendingLocalACPPermissions.map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        let interactionIDs = pendingLocalACPInteractions.map(\.id)
        for interactionID in interactionIDs {
            resolveLocalACPInteraction(id: interactionID, response: .cancelled)
        }
        LocalACPClient.terminateAllProcesses()
        PiRPCClient.terminateAllProcesses()
        Task { for instance in openCodeInstances { await instance.coordinator.shutdown() }; await dashboardStore?.shutdownLocalACPSessions() }
    }

    private func requestLocalACPPermission(
        conversationID: String,
        request: LocalACPPermissionRequest
    ) async -> String? {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                localACPPermissionContinuations[id] = continuation
                pendingLocalACPPermissions.append(PendingLocalACPPermission(
                    id: id,
                    conversationID: conversationID,
                    title: request.title,
                    options: request.options
                ))
                if Task.isCancelled {
                    resolveLocalACPPermission(id: id, optionID: nil)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveLocalACPPermission(id: id, optionID: nil)
            }
        }
    }

    private func requestLocalACPInteraction(
        conversationID: String,
        request: LocalACPInteractionRequest
    ) async -> LocalACPInteractionResponse {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                localACPInteractionContinuations[id] = continuation
                pendingLocalACPInteractions.append(PendingLocalACPInteraction(
                    id: id,
                    conversationID: conversationID,
                    request: request
                ))
                if Task.isCancelled {
                    resolveLocalACPInteraction(id: id, response: .cancelled)
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.resolveLocalACPInteraction(id: id, response: .cancelled)
            }
        }
    }

    private func cancelLocalACPInteractions(conversationID: String) {
        let interactionIDs = pendingLocalACPInteractions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for interactionID in interactionIDs {
            resolveLocalACPInteraction(id: interactionID, response: .cancelled)
        }
    }

    private func refreshLocalACPRuntimes(checkCredentialsFor runtimeKinds: Set<AgentRuntimeKind> = []) async {
        localACPRuntimeRefreshGeneration &+= 1
        let generation = localACPRuntimeRefreshGeneration
        let enabledRuntimeKinds = enabledLocalACPRuntimeKinds
        checkingLocalACPRuntimeKinds = Set(
            LocalACPRuntimeCatalog.definitions.compactMap {
                enabledRuntimeKinds.contains($0.runtimeKind)
                    && runtimeKinds.contains($0.runtimeKind)
                    ? $0.runtimeKind : nil
            }
        )
        defer {
            if generation == localACPRuntimeRefreshGeneration {
                checkingLocalACPRuntimeKinds.removeAll()
            }
        }
        let previousResolutions = Dictionary(uniqueKeysWithValues: localACPRuntimeAvailability.map {
            ($0.runtimeKind, LocalACPRuntimeResolution(
                availability: $0,
                launchConfiguration: localACPLaunchConfigurations[$0.runtimeKind]
            ))
        })
        let resolver = localACPRuntimeResolver
        let definitions = LocalACPRuntimeCatalog.definitions
        let workingDirectory = localACPWorkspaceLaunchConfiguration?.rootURL
            ?? FileManager.default.homeDirectoryForCurrentUser
        let resolutions = await Task.detached(priority: .utility) {
            let resolver = resolver.snapshottingExecutableSearchDirectories()
            var resolutions: [LocalACPRuntimeResolution] = []
            for definition in definitions {
                let discovered = resolver.resolve(
                    runtimeKind: definition.runtimeKind
                )
                guard enabledRuntimeKinds.contains(definition.runtimeKind)
                else {
                    if let executablePath = discovered.availability.executablePath,
                       discovered.launchConfiguration != nil {
                        resolutions.append(LocalACPRuntimeResolution(
                            availability: LocalACPRuntimeAvailability(
                                runtimeKind: definition.runtimeKind,
                                displayName: definition.displayName,
                                state: .authenticationRequired,
                                detail: "Enable \(definition.displayName) before Woven Matter starts it or checks its account credentials.",
                                executablePath: executablePath
                            ),
                            launchConfiguration: nil
                        ))
                    } else {
                        resolutions.append(discovered)
                    }
                    continue
                }
                resolutions.append(await LocalACPRuntimeVerifier.refresh(
                    definition: definition,
                    resolution: discovered,
                    workingDirectory: workingDirectory,
                    credentialCheckRuntimeKinds: runtimeKinds,
                    previousResolution: previousResolutions[definition.runtimeKind]
                ))
            }
            return resolutions
        }.value
        guard !Task.isCancelled,
              generation == localACPRuntimeRefreshGeneration else {
            return
        }
        localACPRuntimeAvailability = resolutions.map(\.availability)
        localACPLaunchConfigurations = resolutions.reduce(into: [:]) {
            configurations, resolution in
            if let launchConfiguration = resolution.launchConfiguration {
                configurations[resolution.availability.runtimeKind] =
                    launchConfiguration
            }
        }
        let statuses = Dictionary(
            uniqueKeysWithValues: resolutions.map { resolution in
                let status: AgentRuntimeStatus = switch resolution.availability.state {
                case .ready: .ready
                case .authenticationRequired: .needsAuthentication
                case .executableUnavailable: .failed
                case .cliMissing, .adapterMissing, .adapterOutdated: .offline
                }
                return (resolution.availability.runtimeKind, status)
            }
        )
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            try await dashboardStore.reconcileLocalCLIAgentCatalog(statuses: statuses)
            localACPDatabaseReadyRuntimeKinds = Set(statuses.keys)
            localACPAgentReconciliationError = nil
            await refreshWorkspace()
        } catch {
            localACPDatabaseReadyRuntimeKinds.removeAll()
            localACPAgentReconciliationError =
                "The local workspace could not save Local CLI agents. Reopen Woven Matter and try again."
            NSLog(
                "Could not reconcile local CLI agents: %@",
                String(describing: error)
            )
        }
        // Loading title options starts a Codex session. Keep discovery passive;
        // the existing Refresh options action requests that work explicitly.
        if localACPLaunchConfigurations[.codex] == nil {
            titleGenerationCapabilities = nil
            titleGenerationStatus = "Codex CLI and codex-acp must be ready"
        } else if titleGenerationCapabilities == nil {
            titleGenerationStatus = "Refresh options to load Codex models"
        }
    }

    private func refreshTitleGenerationCapabilities() async {
        guard !isRefreshingTitleGenerationCapabilities,
              let launch = localACPLaunchConfigurations[.codex],
              let workspace = localACPWorkspaceLaunchConfiguration else {
            titleGenerationCapabilities = nil
            titleGenerationStatus = "Codex CLI and codex-acp must be ready"
            return
        }
        isRefreshingTitleGenerationCapabilities = true
        defer { isRefreshingTitleGenerationCapabilities = false }
        do {
            let capabilities = try await conversationTitleGenerator.discover(
                launch: launch,
                workspace: workspace
            )
            titleGenerationCapabilities = capabilities
            if !capabilities.models.contains(titleGenerationSettings.model),
               let model = capabilities.currentModel ?? capabilities.models.first {
                setTitleGenerationModel(model)
            }
            if !capabilities.thinkingLevels.contains(titleGenerationSettings.thinking),
               let thinking = capabilities.currentThinking
                    ?? capabilities.thinkingLevels.first {
                setTitleGenerationThinking(thinking)
            }
            titleGenerationStatus = "Ready through your local Codex account"
        } catch {
            titleGenerationCapabilities = nil
            titleGenerationStatus = error.localizedDescription
        }
    }

    private func scheduleConversationTitleGeneration(
        conversation: WorkspaceConversationRecord,
        firstPrompt: String
    ) {
        guard titleGenerationSettings.isEnabled,
              conversation.title.hasPrefix("New "),
              conversation.title.hasSuffix(" chat"),
              let launch = localACPLaunchConfigurations[.codex],
              let workspace = localACPWorkspaceLaunchConfiguration,
              let dashboardStore,
              generatingConversationTitleIDs.insert(conversation.id).inserted else { return }
        let expectedTitle = conversation.title
        let selectedModel = titleGenerationSettings.model.isEmpty
            ? nil : titleGenerationSettings.model
        let selectedThinking = titleGenerationSettings.thinking.isEmpty
            ? nil : titleGenerationSettings.thinking
        Task {
            defer { generatingConversationTitleIDs.remove(conversation.id) }
            do {
                let generatedTitle = try await conversationTitleGenerator.generate(
                    firstPrompt: firstPrompt,
                    model: selectedModel,
                    thinking: selectedThinking,
                    launch: launch,
                    workspace: workspace
                )
                if try await dashboardStore.updateConversationTitleIfCurrent(
                    id: conversation.id,
                    expectedTitle: expectedTitle,
                    title: generatedTitle
                ) {
                    await refreshWorkspace()
                }
            } catch {
                NSLog(
                    "Could not generate title for conversation %@: %@",
                    conversation.id,
                    String(describing: error)
                )
            }
        }
    }

    private func refreshLocalACPWorkspace() async {
        let resolution = await localACPWorkspaceStore.resolve()
        localACPWorkspaceAvailability = resolution.availability
        localACPWorkspaceLaunchConfiguration = resolution.launchConfiguration
    }

    func refreshDatabases() async {
        if isRefreshingDatabases {
            databaseRefreshRequestedWhileRunning = true
            await withCheckedContinuation { continuation in
                databaseRefreshWaiters.append(continuation)
            }
            return
        }
        isRefreshingDatabases = true
        defer {
            isRefreshingDatabases = false
            let waiters = databaseRefreshWaiters
            databaseRefreshWaiters.removeAll(keepingCapacity: true)
            for waiter in waiters { waiter.resume() }
        }

        repeat {
            databaseRefreshRequestedWhileRunning = false
            var sources: [DashboardDatabaseSource] = []
            if let root = localACPWorkspaceLaunchConfiguration?.databasesURL {
                do {
                    let rows = try await Task.detached(priority: .utility) {
                        try AgentDatabaseCatalog.list(at: root)
                    }.value
                    sources.append(Self.databaseSource(
                        id: "local",
                        name: "Local workspace",
                        kind: .local,
                        detail: root.path,
                        rows: rows,
                        allowsCreation: true,
                        allowsExternalLinks: true
                    ))
                } catch {
                    sources.append(DashboardDatabaseSource(
                        id: "local",
                        name: "Local workspace",
                        kind: .local,
                        detail: root.path,
                        databases: [],
                        error: error.localizedDescription,
                        allowsCreation: true,
                        allowsExternalLinks: true
                    ))
                }
            } else {
                sources.append(DashboardDatabaseSource(
                    id: "local",
                    name: "Local workspace",
                    kind: .local,
                    detail: "Set up the local agent workspace in Settings.",
                    databases: [],
                    error: localACPWorkspaceAvailability.detail,
                    allowsCreation: false,
                    allowsExternalLinks: false
                ))
            }

            let remoteCatalogIdentity = remoteWorkspaces.databaseCatalogIdentity
            let configurations = remoteCatalogIdentity.configurations
            for configuration in configurations {
                let sourceID = Self.remoteDatabaseSourceID(configuration.id)
                do {
                    let rows = try await remoteWorkspaces.databases(for: configuration)
                    sources.append(DashboardDatabaseSource(
                        id: sourceID, name: configuration.name, kind: .remote,
                        detail: "\(configuration.hostName) · Databases",
                        databases: rows.map { DashboardAgentDatabase(
                            sourceID: sourceID, databaseID: $0.id, name: $0.name,
                            preference: $0.preference, localURL: nil, isExternal: false
                        ) }, error: nil, allowsCreation: true, allowsExternalLinks: false
                    ))
                } catch {
                    sources.append(DashboardDatabaseSource(
                        id: sourceID, name: configuration.name, kind: .remote,
                        detail: configuration.hostName, databases: [],
                        error: error is CancellationError ? "Workspace connection changed. Refresh to reconnect." : error.localizedDescription,
                        allowsCreation: false, allowsExternalLinks: false
                    ))
                }
            }
            for link in buzzWorkspaceSnapshot.links where link.isEnabled {
                let sourceID = "buzz:\(link.id.uuidString.lowercased())"
                let root = link.localWorkspaceURL.appending(
                    path: LocalACPWorkspaceProvisioner.databasesDirectoryName,
                    directoryHint: .isDirectory
                )
                do {
                    let rows = try await Task.detached(priority: .utility) {
                        try AgentDatabaseCatalog.list(at: root)
                    }.value
                    sources.append(Self.databaseSource(
                        id: sourceID,
                        name: link.displayName,
                        kind: .buzz,
                        detail: root.path,
                        rows: rows
                    ))
                } catch {
                    sources.append(DashboardDatabaseSource(
                        id: sourceID,
                        name: link.displayName,
                        kind: .buzz,
                        detail: root.path,
                        databases: [],
                        error: error.localizedDescription,
                        allowsCreation: false,
                        allowsExternalLinks: false
                    ))
                }
            }

            guard remoteCatalogIdentity == remoteWorkspaces.databaseCatalogIdentity else {
                databaseRefreshRequestedWhileRunning = true
                continue
            }
            databasesSnapshot = DashboardDatabasesSnapshot(sources: sources)
        } while databaseRefreshRequestedWhileRunning
    }

    static func remoteDatabaseSourceID(_ id: UUID) -> String {
        "remote:\(id.uuidString.lowercased())"
    }

    private func remoteDatabaseConfiguration(sourceID: String) -> RemoteWorkspaceConfiguration? {
        remoteWorkspaces.workspaces.first { Self.remoteDatabaseSourceID($0.id) == sourceID }
    }

    @discardableResult
    func createDatabase(sourceID: String, name: String, preference: AgentDatabasePreference) async -> String? {
        if sourceID == "local" { return await createLocalDatabase(name: name, preference: preference) }
        guard let configuration = remoteDatabaseConfiguration(sourceID: sourceID) else {
            databaseError = "Choose an available workspace."
            return nil
        }
        do {
            let row = try await remoteWorkspaces.createDatabase(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines), preference: preference, in: configuration)
            databaseError = nil
            await refreshDatabases()
            return "\(sourceID):\(row.id)"
        } catch {
            databaseError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func createLocalDatabase(
        name: String,
        preference: AgentDatabasePreference
    ) async -> String? {
        guard let root = localACPWorkspaceLaunchConfiguration?.databasesURL else {
            databaseError = "Set up the local agent workspace before creating a database."
            return nil
        }
        do {
            let database = try await Task.detached(priority: .userInitiated) {
                try AgentDatabaseCatalog.create(
                    named: name,
                    preference: preference,
                    in: root
                )
            }.value
            databaseError = nil
            await refreshDatabases()
            return "local:\(database.id)"
        } catch {
            databaseError = error.localizedDescription
            return nil
        }
    }

    @discardableResult
    func registerExternalDatabase(_ url: URL) async -> String? {
        guard let root = localACPWorkspaceLaunchConfiguration?.databasesURL else {
            databaseError = "Set up the local agent workspace before linking a database."
            return nil
        }
        do {
            let database = try await Task.detached(priority: .userInitiated) {
                try AgentDatabaseCatalog.registerExternal(url, in: root)
            }.value
            databaseError = nil
            await refreshDatabases()
            return "local:\(database.id)"
        } catch {
            databaseError = error.localizedDescription
            return nil
        }
    }

    func updateDatabasePreference(
        _ preference: AgentDatabasePreference,
        database: DashboardAgentDatabase
    ) async {
        guard updatingDatabasePreferenceIDs.insert(database.id).inserted else { return }
        defer { updatingDatabasePreferenceIDs.remove(database.id) }
        do {
            if let configuration = remoteDatabaseConfiguration(sourceID: database.sourceID) {
                try await remoteWorkspaces.setDatabasePreference(preference, databaseID: database.databaseID, in: configuration)
            } else if let url = database.localURL {
                try await Task.detached(priority: .userInitiated) {
                    try AgentDatabaseCatalog.setPreference(preference, for: url)
                }.value
            } else {
                throw DashboardDatabaseLinkError.databaseUnavailable
            }
            databaseError = nil
            await refreshDatabases()
        } catch {
            databaseError = error.localizedDescription
        }
    }

    func clearDatabaseError() {
        databaseError = nil
    }

    func linkedData(for link: DatabaseArtifactLink) async throws -> DatabaseTabularData {
        if let configuration = remoteDatabaseConfiguration(sourceID: link.sourceID) {
            let result = try await remoteWorkspaces.databaseData(for: link, in: configuration)
            let identity = remoteWorkspaces.databaseCatalogIdentity
            let data = try await Task.detached(priority: .utility) {
                if let query = result.query { return try DatabaseLinkedData.load(queryResponse: query) }
                guard let encoded = result.jsonBase64, let data = Data(base64Encoded: encoded) else {
                    throw DashboardDatabaseLinkError.remoteDataUnavailable
                }
                return try DatabaseLinkedData.load(data: data, fileExtension: "json", preference: .json, sqliteQuery: nil)
            }.value
            guard identity == remoteWorkspaces.databaseCatalogIdentity else { throw CancellationError() }
            try Task.checkCancellation()
            return data
        }
        var database = databasesSnapshot.database(
            sourceID: link.sourceID,
            databaseID: link.databaseID
        )
        if database == nil {
            await refreshDatabases()
            database = databasesSnapshot.database(
                sourceID: link.sourceID,
                databaseID: link.databaseID
            )
        }
        guard let database else {
            throw DashboardDatabaseLinkError.databaseUnavailable
        }
        if let databaseURL = database.localURL {
            return try await Task.detached(priority: .utility) {
                let fileExtension = URL(
                    fileURLWithPath: link.relativePath
                ).pathExtension.lowercased()
                if DatabaseLinkedData.requiresSQLiteFileAccess(
                    fileExtension: fileExtension,
                    preference: database.preference
                ) {
                    return try AgentDatabaseCatalog.withConfinedSQLiteFile(
                        relativePath: link.relativePath,
                        in: databaseURL
                    ) { stagedURL in
                        try DatabaseLinkedData.load(
                            from: stagedURL,
                            preference: .sqlite,
                            sqliteQuery: link.sqliteQuery
                        )
                    }
                }
                let data = try AgentDatabaseCatalog.readDataFile(
                    relativePath: link.relativePath,
                    in: databaseURL,
                    maximumBytes: DatabaseLinkedData.maximumFileBytes
                )
                return try DatabaseLinkedData.load(
                    data: data,
                    fileExtension: fileExtension,
                    preference: database.preference,
                    sqliteQuery: link.sqliteQuery
                )
            }.value
        }

        throw DashboardDatabaseLinkError.remoteDataUnavailable
    }

    private nonisolated static func databaseSource(
        id: String,
        name: String,
        kind: DashboardDatabaseSourceKind,
        detail: String,
        rows: [LocalAgentDatabase],
        allowsCreation: Bool = false,
        allowsExternalLinks: Bool = false
    ) -> DashboardDatabaseSource {
        DashboardDatabaseSource(
            id: id,
            name: name,
            kind: kind,
            detail: detail,
            databases: rows.map {
                DashboardAgentDatabase(
                    sourceID: id,
                    databaseID: $0.id,
                    name: $0.name,
                    preference: $0.preference,
                    localURL: $0.url,
                    isExternal: $0.isExternal
                )
            },
            error: nil,
            allowsCreation: allowsCreation,
            allowsExternalLinks: allowsExternalLinks
        )
    }


    var buzzWorkspaceLinks: [BuzzWorkspaceLink] {
        buzzWorkspaceSnapshot.links
    }

    var buzzWorkspaceAgentEnrollments: [BuzzWorkspaceAgentEnrollment] {
        buzzWorkspaceSnapshot.enrollments
    }

    func isBuzzWorkspaceAgentLaunchable(
        _ enrollment: BuzzWorkspaceAgentEnrollment
    ) -> Bool {
        launchableBuzzWorkspaceEnrollmentIDs.contains(enrollment.id)
    }

    func setBuzzDiscoveryEnabled(_ enabled: Bool) {
        applicationDefaults.set(
            enabled,
            forKey: Self.buzzDiscoveryEnabledDefaultsKey
        )
        Task {
            if enabled {
                await refreshBuzzWorkspaces()
            } else {
                buzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
                    links: [],
                    enrollments: []
                )
                buzzWorkspaceCandidates.removeAll()
                launchableBuzzWorkspaceEnrollmentIDs.removeAll()
                buzzWorkspaceAgents = []
            }
            await refreshWorkspace()
        }
    }

    @discardableResult
    func addLocalBuzzWorkspace(
        displayName: String,
        workspacePath rawWorkspacePath: String,
        agentStorePath rawAgentStorePath: String
    ) async -> Bool {
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            buzzWorkspaceError = "Enter a workspace name."
            return false
        }
        let workspaceURL = Self.expandedLocalFileURL(rawWorkspacePath)
        let storeURL = Self.expandedLocalFileURL(rawAgentStorePath)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: workspaceURL.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            buzzWorkspaceError = "The selected Buzz workspace folder is unavailable."
            return false
        }
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            buzzWorkspaceError = "The selected Buzz agent catalog is unavailable."
            return false
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            let link = BuzzWorkspaceLink(
                displayName: cleanName,
                localWorkspaceURL: workspaceURL,
                localAgentStoreURL: storeURL
            )
            try await dashboardStore.saveBuzzWorkspace(link)
            buzzWorkspaceError = nil
            await refreshBuzzWorkspaces()
            await refreshWorkspace()
            return true
        } catch {
            buzzWorkspaceError = error.localizedDescription
            return false
        }
    }

    func discoverBuzzWorkspaceAgents(_ link: BuzzWorkspaceLink) {
        guard checkingBuzzWorkspaceLinkIDs.insert(link.id).inserted else { return }
        buzzWorkspaceError = nil
        Task {
            defer { checkingBuzzWorkspaceLinkIDs.remove(link.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                buzzWorkspaceCandidates[link.id] = try await dashboardStore
                    .discoverBuzzWorkspaceAgents(linkID: link.id)
            } catch {
                buzzWorkspaceCandidates[link.id] = []
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func enrollBuzzWorkspaceAgent(_ candidate: BuzzWorkspaceAgentCandidate) {
        Task {
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                let enrollment = try await dashboardStore
                    .enrollBuzzWorkspaceAgent(candidate)
                mutatingBuzzWorkspaceEnrollmentIDs.insert(enrollment.id)
                defer { mutatingBuzzWorkspaceEnrollmentIDs.remove(enrollment.id) }
                buzzWorkspaceError = nil
                await refreshBuzzWorkspaces()
                await refreshWorkspace()
            } catch {
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func removeBuzzWorkspaceAgentEnrollment(
        _ enrollment: BuzzWorkspaceAgentEnrollment
    ) {
        guard mutatingBuzzWorkspaceEnrollmentIDs.insert(enrollment.id).inserted else {
            return
        }
        Task {
            defer { mutatingBuzzWorkspaceEnrollmentIDs.remove(enrollment.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                try await dashboardStore.removeBuzzWorkspaceAgentEnrollment(
                    id: enrollment.id
                )
                buzzWorkspaceError = nil
                await refreshBuzzWorkspaces()
                await refreshWorkspace()
            } catch {
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    func deleteBuzzWorkspace(_ link: BuzzWorkspaceLink) {
        guard checkingBuzzWorkspaceLinkIDs.insert(link.id).inserted else { return }
        Task {
            defer { checkingBuzzWorkspaceLinkIDs.remove(link.id) }
            do {
                guard let dashboardStore else {
                    throw ApplicationModelError.dashboardStoreUnavailable
                }
                try await dashboardStore.deleteBuzzWorkspace(id: link.id)
                buzzWorkspaceCandidates.removeValue(forKey: link.id)
                buzzWorkspaceError = nil
                await refreshBuzzWorkspaces()
                await refreshWorkspace()
            } catch {
                buzzWorkspaceError = error.localizedDescription
            }
        }
    }

    private func refreshBuzzWorkspaces() async {
        guard applicationDefaults.bool(
            forKey: Self.buzzDiscoveryEnabledDefaultsKey
        ) else {
            buzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
                links: [],
                enrollments: []
            )
            launchableBuzzWorkspaceEnrollmentIDs.removeAll()
            return
        }
        do {
            guard let dashboardStore else {
                throw ApplicationModelError.dashboardStoreUnavailable
            }
            launchableBuzzWorkspaceEnrollmentIDs = try await dashboardStore
                .reconcileBuzzWorkspaceAgents()
            buzzWorkspaceSnapshot = try await dashboardStore.buzzWorkspaceSnapshot()
            buzzBoundLocalACPConversationIDs = try await dashboardStore
                .buzzBoundLocalACPConversationIDs()
            buzzWorkspaceError = nil
        } catch {
            launchableBuzzWorkspaceEnrollmentIDs.removeAll()
            buzzWorkspaceError = error.localizedDescription
        }
    }

    func isOpenClawGatewayLinked(agentID: UUID) -> Bool {
        openClawGatewayLinks.contains { $0.agentID == agentID }
    }

    func isOpenClawGatewayConversation(_ conversationID: String) -> Bool {
        openClawGatewayConversationIDs.contains(conversationID)
    }

    func openClawGatewayLink(agentID: UUID) -> OpenClawGatewayLink? {
        openClawGatewayLinks.first { $0.agentID == agentID }
    }

    func renameOpenClawAgent(agentID: UUID, displayName: String) {
        guard let dashboardStore else { return }
        guard !openClawGatewayOperationAgentIDs.contains(agentID) else { return }
        let cleanName = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            openClawGatewayErrors[agentID] = "Enter a Woven Matter agent name."
            return
        }
        openClawGatewayOperationAgentIDs.insert(agentID)
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer { openClawGatewayOperationAgentIDs.remove(agentID) }
            do {
                try await dashboardStore.renameOpenClawAgent(
                    agentID: agentID,
                    displayName: cleanName
                )
                await refreshWorkspace()
                openClawGatewayNotices[agentID] = "Woven Matter name updated."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
            }
        }
    }

    func linkOpenClawGateway(agent: WorkspaceAgent) {
        guard agent.runtimeKind == .openclaw, let dashboardStore else {
            openClawGatewayErrors[agent.id] = OpenClawGatewayEndpointResolutionError
                .openClawRequired.localizedDescription
            return
        }
        guard openClawGatewayOperationAgentIDs.insert(agent.id).inserted else { return }
        openClawGatewayOperationStatuses[agent.id] = .connecting
        openClawGatewayErrors[agent.id] = nil
        openClawGatewayNotices[agent.id] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agent.id)
                openClawGatewayOperationStatuses[agent.id] = nil
            }
            do {
                let link = try await preparedOpenClawGatewayLink(
                    for: agent,
                    status: .connecting,
                    authorizeCredentials: true
                )
                let linked = try await dashboardStore.linkOpenClawGateway(link)
                if linked.connectionStatus == .ready {
                    try await dashboardStore.syncOpenClawCron(agentID: agent.id)
                }
                await refreshOpenClawGateways()
                await loadOpenClawCronSnapshot()
                openClawGatewayNotices[agent.id] = "Gateway connected and healthy."
            } catch {
                openClawGatewayErrors[agent.id] = error.localizedDescription
                await refreshOpenClawGateways()
            }
        }
    }

    func confirmPendingOpenClawGatewayLink() {
        guard let agentID = pendingOpenClawGatewayAgentID else { return }
        pendingOpenClawGatewayAgentID = nil
        guard let agent = openClawAgent(agentID: agentID) else { return }
        linkOpenClawGateway(agent: agent)
    }

    func dismissPendingOpenClawGatewayLink() {
        pendingOpenClawGatewayAgentID = nil
    }

    func unlinkOpenClawGateway(agentID: UUID) {
        guard let dashboardStore else { return }
        guard openClawGatewayOperationAgentIDs.insert(agentID).inserted else { return }
        openClawGatewayOperationStatuses[agentID] = .unlinking
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agentID)
                openClawGatewayOperationStatuses[agentID] = nil
            }
            do {
                try await dashboardStore.unlinkOpenClawGateway(agentID: agentID)
                await refreshOpenClawGateways()
                openClawGatewayNotices[agentID] = "Gateway unlinked from this Mac."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
            }
        }
    }

    func reconnectOpenClawGateway(agentID: UUID) {
        guard let existing = openClawGatewayLink(agentID: agentID),
              let agent = openClawAgent(agentID: agentID),
              let dashboardStore else { return }
        guard openClawGatewayOperationAgentIDs.insert(agentID).inserted else { return }
        openClawGatewayOperationStatuses[agentID] = .reconnecting
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agentID)
                openClawGatewayOperationStatuses[agentID] = nil
            }
            do {
                _ = try await dashboardStore.markOpenClawGateway(
                    agentID: agentID,
                    status: .reconnecting
                )
                await refreshOpenClawGateways()
                let link = try await preparedOpenClawGatewayLink(
                    for: agent,
                    existing: existing,
                    status: .reconnecting,
                    authorizeCredentials: true
                )
                _ = try await dashboardStore.linkOpenClawGateway(link)
                await refreshOpenClawGateways()
                openClawGatewayNotices[agentID] = "Gateway reconnected and healthy."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
                _ = try? await dashboardStore.markOpenClawGateway(
                    agentID: agentID,
                    status: .unavailable
                )
                await refreshOpenClawGateways()
            }
        }
    }

    func restartOpenClawGateway(agentID: UUID) {
        guard let existing = openClawGatewayLink(agentID: agentID),
              let agent = openClawAgent(agentID: agentID),
              let dashboardStore else { return }
        guard openClawGatewayOperationAgentIDs.insert(agentID).inserted else { return }
        openClawGatewayOperationStatuses[agentID] = .restarting
        openClawGatewayErrors[agentID] = nil
        openClawGatewayNotices[agentID] = nil
        Task {
            defer {
                openClawGatewayOperationAgentIDs.remove(agentID)
                openClawGatewayOperationStatuses[agentID] = nil
            }
            do {
                if existing.location == .localAgentWorkspace || existing.location == .buzzLocal {
                    let prepared = try await preparedOpenClawGatewayLink(
                        for: agent,
                        existing: existing,
                        status: .reconnecting,
                        authorizeCredentials: true
                    )
                    _ = try await dashboardStore.linkOpenClawGateway(prepared)
                } else {
                    try await dashboardStore.authorizeOpenClawGatewayCredentials(existing)
                }
                _ = try await dashboardStore.restartOpenClawGateway(agentID: agentID)
                await refreshOpenClawGateways()
                openClawGatewayNotices[agentID] = "Gateway restarted, reconnected, and passed health checks."
            } catch {
                openClawGatewayErrors[agentID] = error.localizedDescription
                _ = try? await dashboardStore.markOpenClawGateway(
                    agentID: agentID,
                    status: .unavailable
                )
                await refreshOpenClawGateways()
            }
        }
    }

    func refreshOpenClawGatewayStatus(agentID: UUID) async {
        guard openClawGatewayLink(agentID: agentID) != nil,
              !openClawGatewayOperationAgentIDs.contains(agentID),
              let dashboardStore else { return }
        do {
            _ = try await dashboardStore.refreshOpenClawGatewayStatus(agentID: agentID)
            openClawGatewayErrors[agentID] = nil
        } catch {
            openClawGatewayErrors[agentID] = error.localizedDescription
        }
        await refreshOpenClawGateways()
    }

    func loadOpenClawHeartbeat(agentID: UUID) async {
        guard let dashboardStore else { return }
        do {
            openClawHeartbeatConfigurations[agentID] = try await dashboardStore
                .openClawHeartbeatConfiguration(agentID: agentID)
            openClawHeartbeatMessages[agentID] = nil
            openClawHeartbeatErrorAgentIDs.remove(agentID)
        } catch {
            openClawHeartbeatMessages[agentID] = error.localizedDescription
            openClawHeartbeatErrorAgentIDs.insert(agentID)
        }
    }

    func saveOpenClawHeartbeat(
        agentID: UUID,
        configuration: OpenClawHeartbeatConfiguration
    ) {
        guard let dashboardStore else { return }
        openClawHeartbeatSavingAgentIDs.insert(agentID)
        openClawHeartbeatMessages[agentID] = nil
        Task {
            defer { openClawHeartbeatSavingAgentIDs.remove(agentID) }
            do {
                openClawHeartbeatConfigurations[agentID] = try await dashboardStore
                    .updateOpenClawHeartbeat(
                        agentID: agentID,
                        configuration: configuration
                    )
                openClawHeartbeatMessages[agentID] = "Heartbeat saved and confirmed by OpenClaw."
                openClawHeartbeatErrorAgentIDs.remove(agentID)
            } catch {
                openClawHeartbeatMessages[agentID] = error.localizedDescription
                openClawHeartbeatErrorAgentIDs.insert(agentID)
            }
        }
    }

    private func openClawAgent(agentID: UUID) -> WorkspaceAgent? {
        (localCLIAgents + remoteWorkspaceAgents + buzzWorkspaceAgents)
            .first { $0.id == agentID }
    }

    private func preparedOpenClawGatewayLink(
        for agent: WorkspaceAgent,
        existing: OpenClawGatewayLink? = nil,
        status: OpenClawGatewayConnectionStatus,
        authorizeCredentials: Bool = false
    ) async throws -> OpenClawGatewayLink {
        guard let dashboardStore else {
            throw ApplicationModelError.dashboardStoreUnavailable
        }
        let location: OpenClawGatewayLocation
        let endpoint: OpenClawGatewayEndpoint
        if agent.governingPlane == .remoteWorkspace {
            location = .remoteWorkspace
            guard let remoteWorkspaceID = agent.runtimeDeviceID,
                  let configuration = remoteWorkspaces.configuration(
                    id: remoteWorkspaceID
                  ) else {
                throw ApplicationModelError.remoteHarnessUnavailable
            }
            if authorizeCredentials {
                try await remoteWorkspaces.authorizeCredentialAccess(for: configuration)
            }
            let connection = try await remoteWorkspaces.prepareOpenClawGateway(
                for: configuration
            )
            await dashboardStore.configureOpenClawGatewayTransport(
                agentID: agent.id,
                endpoint: connection.endpoint,
                requestHeaders: connection.requestHeaders
            )
            endpoint = connection.endpoint
        } else if let enrollment = buzzWorkspaceSnapshot.enrollments
            .first(where: { $0.id == agent.id }) {
            location = .buzzLocal
            endpoint = try await dashboardStore.prepareBuzzLocalOpenClawGateway(
                enrollmentID: enrollment.id,
                workspaceLinkID: enrollment.workspaceLinkID,
                remoteAgentID: enrollment.agentID
            )
        } else {
            location = .localAgentWorkspace
            guard let workspace = localACPWorkspaceLaunchConfiguration else {
                throw ApplicationModelError.localACPRuntimeUnavailable
            }
            endpoint = try await dashboardStore.prepareLocalWorkspaceOpenClawGateway(
                agentID: agent.id,
                workingDirectory: workspace.rootURL
            )
        }
        let link = OpenClawGatewayLink(
            agentID: agent.id,
            location: location,
            endpoint: endpoint,
            status: status.rawValue,
            openClawVersion: existing?.openClawVersion,
            lastConnectedAt: existing?.lastConnectedAt,
            lastError: nil,
            linkedAt: existing?.linkedAt ?? Date(),
            updatedAt: Date()
        )
        if authorizeCredentials {
            try await dashboardStore.authorizeOpenClawGatewayCredentials(link)
        }
        return link
    }

    func cancelOpenClawGatewayPrompt(conversationID: String) {
        let permissionIDs = pendingLocalACPPermissions
            .filter { $0.conversationID == conversationID }
            .map(\.id)
        for permissionID in permissionIDs {
            resolveLocalACPPermission(id: permissionID, optionID: nil)
        }
        Task {
            guard let dashboardStore else { return }
            do {
                try await dashboardStore.cancelOpenClawGatewayPrompt(
                    conversationID: conversationID
                )
                ensureConversationState(id: conversationID).setError(nil)
            } catch {
                await refreshConversation(id: conversationID)
                ensureConversationState(id: conversationID).setError(
                    "Unable to stop OpenClaw Gateway run: \(error.localizedDescription)"
                )
            }
        }
    }

    func patchOpenClawGatewaySession(
        conversationID: String,
        model: String?,
        thinkingLevel: String?,
        permission: String? = nil
    ) {
        guard model != nil || thinkingLevel != nil || permission != nil else { return }
        if retryPendingSessionSelections(conversationID: conversationID,
            selections: SessionSelections(model: model, thinking: thinkingLevel, permission: permission)) { return }
        guard let dashboardStore,
              !localRunningConversationIDs.contains(conversationID),
              updatingLocalACPSessionIDs.insert(conversationID).inserted else { return }
        Task {
            defer { updatingLocalACPSessionIDs.remove(conversationID) }
            do {
                _ = try await dashboardStore
                    .patchOpenClawGatewaySession(
                        conversationID: conversationID,
                        preferences: OpenClawSessionPreferences(
                            model: model,
                            thinkingLevel: thinkingLevel,
                            permissionMode: permission
                        )
                    )
                openClawGatewaySessionMetadata[conversationID] = try await dashboardStore
                    .openClawGatewaySessionMetadata(conversationID: conversationID)
                if let metadata = openClawGatewaySessionMetadata[conversationID] {
                    recordConfirmedSessionSelections(conversationID: conversationID, metadata: metadata)
                }
                ensureConversationState(id: conversationID).setError(nil)
            } catch {
                ensureConversationState(id: conversationID).setError(
                    error.localizedDescription
                )
            }
        }
    }

    func refreshOpenClawGatewaySession(conversationID: String) async {
        guard let dashboardStore else { return }
        do {
            try await applyPendingSessionSelections(conversationID: conversationID)
            _ = try await dashboardStore.synchronizeOpenClawSession(conversationID: conversationID)
            openClawGatewaySessionMetadata[conversationID] = try await dashboardStore
                .openClawGatewaySessionMetadata(conversationID: conversationID)
            if let metadata = openClawGatewaySessionMetadata[conversationID] {
                recordConfirmedSessionSelections(conversationID: conversationID, metadata: metadata)
            }
            ensureConversationState(id: conversationID).setError(nil)
        } catch {
            ensureConversationState(id: conversationID).setError(
                error.localizedDescription
            )
        }
    }

    private func refreshOpenClawGateways() async {
        do {
            guard let dashboardStore else { return }
            openClawGatewayLinks = try await dashboardStore.openClawGatewayLinks()
            openClawGatewayConversationIDs = try await dashboardStore
                .openClawGatewayConversationIDs()
        } catch {
            for link in openClawGatewayLinks {
                openClawGatewayErrors[link.agentID] = error.localizedDescription
            }
        }
    }

    func openClawNativeSessions(agentID: UUID, offset: Int = 0) async throws -> (sessions: [OpenClawGatewaySession], nextOffset: Int?) {
        guard let dashboardStore else { throw OpenClawGatewayClientError.connectionClosed }
        return try await dashboardStore.openClawNativeSessions(agentID: agentID, offset: offset)
    }

    func importOpenClawSession(agentID: UUID, session: OpenClawGatewaySession) async throws {
        guard let dashboardStore else { throw OpenClawGatewayClientError.connectionClosed }
        _ = try await dashboardStore.importOpenClawSession(agentID: agentID, session: session)
        await refreshOpenClawGateways()
        await refreshWorkspace()
    }

    private func restoreOpenClawGatewayLinks() async {
        guard let dashboardStore else { return }
        for persisted in openClawGatewayLinks {
            do {
                var link = persisted
                switch persisted.location {
                case .buzzLocal:
                    guard let enrollment = buzzWorkspaceSnapshot.enrollments.first(where: {
                        $0.id == persisted.agentID
                    }) else { throw BuzzWorkspaceDatabaseError.enrollmentNotFound }
                    link.endpoint = try await dashboardStore.prepareBuzzLocalOpenClawGateway(
                        enrollmentID: enrollment.id,
                        workspaceLinkID: enrollment.workspaceLinkID,
                        remoteAgentID: enrollment.agentID
                    )
                case .localAgentWorkspace:
                    guard let workspace = localACPWorkspaceLaunchConfiguration else {
                        throw ApplicationModelError.localACPRuntimeUnavailable
                    }
                    link.endpoint = try await dashboardStore.prepareLocalWorkspaceOpenClawGateway(
                        agentID: persisted.agentID,
                        workingDirectory: workspace.rootURL
                    )
                case .remoteWorkspace:
                    // Remote workspace tokens are intentionally not read during
                    // app startup. The user can reconnect this gateway from its
                    // workspace controls when they want Keychain access.
                    continue
                }
                _ = try await dashboardStore.linkOpenClawGateway(link)
            } catch {
                openClawGatewayErrors[persisted.agentID] = error.localizedDescription
            }
        }
        await refreshOpenClawGateways()
    }

    func refreshOpenClawCron() async {
        guard !isRefreshingOpenClawCron, let dashboardStore else { return }
        isRefreshingOpenClawCron = true
        lastOpenClawCronRefresh = Date()
        defer { isRefreshingOpenClawCron = false }
        var failures: [String] = []
        for link in openClawGatewayLinks {
            do {
                try await dashboardStore.syncOpenClawCron(agentID: link.agentID)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        await loadOpenClawCronSnapshot()
        openClawCronError = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    func saveOpenClawCron(agentID: UUID, job: OpenClawCronJob?, name: String, message: String,
                          expression: String, timeZone: String, declarationKey: String,
                          destination: String, preserveSchedule: Bool = false) async -> String? {
        guard let dashboardStore, !openClawCronBusy else { return "Another job change is in progress." }
        openClawCronBusy = true
        defer { openClawCronBusy = false }
        do {
            if let job {
                var patch: [String: GatewayJSONValue] = ["name": .string(name),
                    "schedule": .object(["kind": .string("cron"), "expr": .string(expression), "tz": .string(timeZone)])]
                if preserveSchedule { patch.removeValue(forKey: "schedule") }
                if !message.isEmpty { patch["payload"] = .object(["message": .string(message)]) }
                try await dashboardStore.updateOpenClawCron(job: job, patch: .object(patch))
                try await dashboardStore.setOpenClawResultRoute(agentID: agentID, jobID: job.id, destination: destination)
            } else {
                try await dashboardStore.createOpenClawCron(agentID: agentID, name: name, message: message,
                    expression: expression, timeZone: timeZone, declarationKey: declarationKey, destination: destination)
            }
            await refreshOpenClawCron()
            return nil
        } catch {
            return error.localizedDescription + " Refresh the job list before retrying; the Gateway may have accepted the change."
        }
    }

    func performOpenClawCronAction(job: OpenClawCronJob, action: String) {
        guard let dashboardStore, !openClawCronBusy else { return }
        openClawCronBusy = true
        Task {
            defer { openClawCronBusy = false }
            do {
                if action == "toggle" {
                    try await dashboardStore.updateOpenClawCron(job: job, patch: .object(["enabled": .bool(!job.enabled)]))
                } else {
                    try await dashboardStore.performOpenClawCronAction(job: job, action: action)
                }
                await refreshOpenClawCron()
            } catch {
                openClawCronError = error.localizedDescription + " Refresh before retrying; this action was not automatically retried."
            }
        }
    }

    func setOpenClawResultRoute(job: OpenClawCronJob, destination: String) {
        guard let dashboardStore else { return }
        Task {
            do {
                try await dashboardStore.setOpenClawResultRoute(agentID: job.agentID, jobID: job.id, destination: destination)
                await loadOpenClawCronSnapshot()
                await refreshOpenClawCron()
                await refreshWorkspace()
            } catch { openClawCronError = error.localizedDescription }
        }
    }

    func emptyOpenClawCronTrash() {
        guard let dashboardStore else { return }
        Task {
            do {
                try await dashboardStore.emptyOpenClawCronTrash()
                await loadOpenClawCronSnapshot()
            } catch {
                openClawCronError = error.localizedDescription
            }
        }
    }

    func createOpenClawContextConversation(
        agentID: UUID,
        context: String? = nil
    ) async -> String? {
        let conversationID: String?
        if let enrollment = buzzWorkspaceSnapshot.enrollments.first(where: {
            $0.id == agentID
        }) {
            conversationID = await createBuzzWorkspaceLocalACPSession(
                enrollment: enrollment
            )
        } else if localCLIAgents.contains(where: {
            $0.id == agentID && $0.runtimeKind == .openclaw
        }) {
            conversationID = await createLocalACPSession(runtimeKind: .openclaw)
        } else {
            localRunError = "The selected OpenClaw is no longer available."
            return nil
        }
        guard let conversationID else { return nil }
        if let context,
           let conversation = workspaceOverview?.conversations.first(where: {
               $0.id == conversationID
           }) {
            _ = await sendAgentMessage(
                conversation: conversation,
                content: context
            )
        }
        return conversationID
    }

    private func loadOpenClawCronSnapshot() async {
        guard let dashboardStore else { return }
        do {
            openClawCronJobs = try await dashboardStore.openClawCronJobs()
            openClawCronRuns = try await dashboardStore.openClawCronRuns()
            for link in openClawGatewayLinks {
                openClawResultRoutes[link.agentID] = try await dashboardStore.openClawResultRoutes(agentID: link.agentID)
            }
        } catch {
            openClawCronError = error.localizedDescription
        }
    }

    private static func openClawSessionKey(conversationID: String) -> String {
        "agent:main:wovenmatter:\(conversationID)"
    }

    private static func expandedLocalFileURL(_ rawPath: String) -> URL {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed == "~" {
            expanded = FileManager.default.homeDirectoryForCurrentUser.path
        } else if trimmed.hasPrefix("~/") {
            expanded = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: String(trimmed.dropFirst(2)))
                .path
        } else {
            expanded = trimmed
        }
        return URL(filePath: expanded).standardizedFileURL
    }

    private func apply(_ snapshot: DashboardStoreSnapshot) {
        if loggedDashboardRecordCounts != snapshot.recordCounts {
            let counts = snapshot.recordCounts
            NSLog(
                "Dashboard database counts profiles=%d folders=%d notes=%d agents=%d conversations=%d messages=%d runs=%d calendar_items=%d revision=%lld",
                counts.profiles,
                counts.folders,
                counts.notes,
                counts.agents,
                counts.conversations,
                counts.messages,
                counts.runs,
                counts.calendarItems,
                snapshot.workspace.revision
            )
            loggedDashboardRecordCounts = counts
        }
        let nextLocalCLIAgents = snapshot.agents.filter {
            $0.governingPlane == .wovenmatterMacOS
                && !($0.platformCodename?.hasPrefix("buzz-workspace:") ?? false)
        }
        let buzzDiscoveryEnabled = applicationDefaults.bool(
            forKey: Self.buzzDiscoveryEnabledDefaultsKey
        )
        let nextBuzzWorkspaceAgents = snapshot.agents.filter {
            buzzDiscoveryEnabled
                && $0.governingPlane == .wovenmatterMacOS
                && ($0.platformCodename?.hasPrefix("buzz-workspace:") ?? false)
        }
        let nextRemoteWorkspaceAgents = snapshot.agents.filter {
            $0.governingPlane == .remoteWorkspace
        }
        if localCLIAgents != nextLocalCLIAgents {
            localCLIAgents = nextLocalCLIAgents
        }
        if buzzWorkspaceAgents != nextBuzzWorkspaceAgents {
            buzzWorkspaceAgents = nextBuzzWorkspaceAgents
        }
        if remoteWorkspaceAgents != nextRemoteWorkspaceAgents {
            remoteWorkspaceAgents = nextRemoteWorkspaceAgents
        }
        if calendarItems != snapshot.calendarItems {
            calendarItems = snapshot.calendarItems
        }
        let nextOverview = DashboardWorkspaceOverview(snapshot.workspace)
        if workspaceOverview?.folders != nextOverview.folders
            || workspaceOverview?.conversations != nextOverview.conversations
            || workspaceOverview?.notes != nextOverview.notes {
            workspaceListRevision &+= 1
        }
        if workspaceOverview != nextOverview { workspaceOverview = nextOverview }
        let retainedConversationIDs = Set(snapshot.workspace.conversations.map(\.id))
        let removedConversationIDs = conversationStatesByID.keys.filter {
            !retainedConversationIDs.contains($0)
        }
        for conversationID in removedConversationIDs {
            conversationStatesByID.removeValue(forKey: conversationID)
        }
        if workspaceRevision != snapshot.revision {
            workspaceRevision = snapshot.revision
        }
    }

}

enum ApplicationModelError: LocalizedError {
    case applicationSupportUnavailable
    case dashboardStoreUnavailable
    case localACPRuntimeUnavailable
    case remoteHarnessUnavailable
    case unavailableSessionTools
    case localSessionConfigurationInProgress
    case steeringUnavailable
    case activeTurnLimitReached
    case noteContextUnavailable
    case noteDraftSaveFailed

    var errorDescription: String? {
        switch self {
        case .applicationSupportUnavailable:
            "The dashboard database location is unavailable."
        case .dashboardStoreUnavailable:
            "The dashboard database is still starting."
        case .localACPRuntimeUnavailable:
            "This local ACP runtime is unavailable. Open Settings to install or update its CLI or adapter, then try again."
        case .remoteHarnessUnavailable:
            "This remote harness is unavailable. Start and refresh its workspace in Settings, then try again."
        case .unavailableSessionTools:
            "Tool selections are unavailable in this build."
        case .localSessionConfigurationInProgress:
            "Wait for this chat's settings change to finish."
        case .steeringUnavailable:
            "This agent is still working in this chat. Try again when the current turn finishes."
        case .activeTurnLimitReached:
            "Woven Matter is already handling a large number of active turns. Let one finish, then try again."
        case .noteContextUnavailable:
            "The open note could not be attached to this run. Wait for it to finish saving, then try again."
        case .noteDraftSaveFailed:
            "The latest note draft could not be saved on this Mac. Your draft is preserved; retry after saving succeeds."
        }
    }
}
