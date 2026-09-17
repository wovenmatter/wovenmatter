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

struct UsageAnalyticsRefreshKey: Hashable, Sendable {
    let range: String
    let enabledProviders: [String]
    let allowsCredentialAccess: Bool
}

struct UsageLimitsRefreshKey: Hashable, Sendable {
    let enabledProviders: [String]
    let allowsCredentialAccess: Bool
    let keychainInteraction: String
    let selectedCodexWorkspaceID: String?
}

@MainActor
@Observable
final class ApplicationModel {
    enum State: Equatable {
        case starting
        case ready
        case failed(String)
    }

    var state: State = .starting
    private(set) var localCLIAgents: [WorkspaceAgent] = []
    var buzzWorkspaceAgents: [WorkspaceAgent] = []
    private(set) var remoteWorkspaceAgents: [WorkspaceAgent] = []
    let remoteWorkspaces: RemoteWorkspacesModel
    var buzzWorkspaceSnapshot = BuzzWorkspaceSnapshot(
        links: [],
        enrollments: []
    )
    var buzzWorkspaceCandidates: [
        UUID: [BuzzWorkspaceAgentCandidate]
    ] = [:]
    var launchableBuzzWorkspaceEnrollmentIDs: Set<UUID> = []
    var checkingBuzzWorkspaceLinkIDs: Set<UUID> = []
    var mutatingBuzzWorkspaceEnrollmentIDs: Set<UUID> = []
    var buzzWorkspaceError: String?
    var openCode: OpenCodeModel?
    var remoteOpenCodes: [UUID: OpenCodeModel] = [:]
    var remoteOpenCodeSyncGeneration = UUID()
    var openCodeInstances: [OpenCodeModel] { [openCode].compactMap { $0 } + Array(remoteOpenCodes.values) }
    var openClawGatewayLinks: [OpenClawGatewayLink] = []
    var openClawGatewayErrors: [UUID: String] = [:]
    var openClawGatewayNotices: [UUID: String] = [:]
    var openClawGatewayOperationAgentIDs: Set<UUID> = []
    var openClawGatewayOperationStatuses: [
        UUID: OpenClawGatewayConnectionStatus
    ] = [:]
    var pendingOpenClawGatewayAgentID: UUID?
    var openClawHeartbeatConfigurations: [UUID: OpenClawHeartbeatConfiguration] = [:]
    var openClawHeartbeatMessages: [UUID: String] = [:]
    var openClawHeartbeatErrorAgentIDs: Set<UUID> = []
    var openClawHeartbeatSavingAgentIDs: Set<UUID> = []
    var openClawGatewaySessionMetadata: [String: LocalACPSessionMetadata] = [:]
    var openClawCronJobs: [OpenClawCronJob] = []
    var openClawCronRuns: [OpenClawCronRun] = []
    var isRefreshingOpenClawCron = false
    var openClawCronError: String?
    var openClawCronBusy = false
    var openClawResultRoutes: [UUID: [String: String]] = [:]
    var lastOpenClawCronRefresh = Date.distantPast
    var openClawGatewayConversationIDs: Set<String> = []
    var buzzBoundLocalACPConversationIDs: Set<String> = []
    private(set) var workspaceOverview: DashboardWorkspaceOverview?
    private(set) var calendarItems: [WorkspaceCalendarItemRecord] = []
    private(set) var workspaceRevision: Int64 = 0
    private(set) var workspaceListRevision: Int64 = 0
    private(set) var macSurfaceProfile: SurfaceProfile?
    var workspaceError: String?
    var folderMutationError: String?
    var noteMutationError: String?
    private(set) var noteEditingSocketPath: String?
    var calendarMutationError: String?
    var isCreatingCalendarItem = false
    var noteDrafts: [String: DashboardNoteDraft] = [:]
    var pendingComposerPrefills: [String: String] = [:]
    var localACPSessionMetadata: [
        String: LocalACPSessionMetadata
    ] = [:]
    var localACPSessionRefreshLifecycle = LocalACPSessionRefreshLifecycle()
    var loadingLocalACPSessionIDs: Set<String> {
        localACPSessionRefreshLifecycle.loadingConversationIDs
    }
    var updatingLocalACPSessionIDs: Set<String> = []
    var localRunError: String?
    var localACPRuntimeAvailability: [LocalACPRuntimeAvailability] = []
    var localACPDatabaseReadyRuntimeKinds: Set<AgentRuntimeKind> = []
    var localACPAgentReconciliationError: String?
    var checkingLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []
    var localACPWorkspaceAvailability = LocalACPWorkspaceAvailability(
        state: .setupRequired,
        detail: "Set up the shared direct workspace before starting a chat.",
        rootPath: nil,
        repositoriesPath: nil,
        usesExternalRepositories: false
    )
    var databasesSnapshot = DashboardDatabasesSnapshot.empty
    var isRefreshingDatabases = false
    var databaseError: String?
    var updatingDatabasePreferenceIDs: Set<String> = []
    @ObservationIgnored
    var databaseRefreshWaiters: [CheckedContinuation<Void, Never>] = []
    @ObservationIgnored
    var databaseRefreshRequestedWhileRunning = false
    var titleGenerationSettings = ConversationTitleGenerationSettings(
        isEnabled: true,
        model: "",
        thinking: ""
    )
    var titleGenerationCapabilities: CodexTitleGenerationCapabilities?
    var titleGenerationStatus = "Waiting for Codex"
    var isRefreshingTitleGenerationCapabilities = false
    var runtimeInventories: [AgentRuntimeKind: RuntimeInventory] = [:]
    var runtimeFailures: [AgentRuntimeKind: Int] = [:]
    var runtimeFailureDetails: [AgentRuntimeKind: String] = [:]
    var checkingRuntimeInventory = false
    var checkingRuntimeKinds: Set<AgentRuntimeKind> = []
    var checkedRuntimeKinds: Set<AgentRuntimeKind> = []
    var updatingRuntimeKinds: Set<AgentRuntimeKind> = []
    var failedRuntimeUpdateKinds: Set<AgentRuntimeKind> = []
    var runtimeInventoryGeneration: UInt64 = 0
    var installingLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []
    var preparedLocalACPRuntimeInstall:
        PreparedLocalACPRuntimeInstall?
    var pendingLocalACPPermissions: [PendingLocalACPPermission] = []
    var pendingLocalACPInteractions: [PendingLocalACPInteraction] = []
    var localRunningConversationIDs: Set<String> = []
    var conversationStatesByID: [String: DashboardConversationState] = [:]
    var localUsage: LocalUsageSnapshot?
    var localUsageError: String?
    var isRefreshingUsageAnalytics = false
    var isRefreshingUsageLimits = false
    var isRefreshingLocalUsage: Bool {
        isRefreshingUsageAnalytics || isRefreshingUsageLimits
    }
    var isOpenRouterCredentialConfigured = false
    var signingInUsageProviders: Set<ProviderKind> = []
    var hasAcknowledgedCredentialAccessDisclosure = false
    var enabledUsageProviders: Set<ProviderKind> = []
    var codexUsageWorkspaces: [CodexUsageWorkspace] = []
    var selectedCodexUsageWorkspaceID: String?
    var enabledLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []
    var shownLocalACPRuntimeKinds: Set<AgentRuntimeKind> = []

    var dashboardStore: DashboardStore?
    var noteWriteBehind: DashboardNoteWriteBehind?
    @ObservationIgnored
    private var noteEditingService: WovenNoteService?
    private var dashboardStoreStarted = false
    var dashboardStoreStartDeferredForNoteRecovery = false
    private var startupTask: Task<Void, Never>?
    // Change-pipeline bookkeeping is mutated on every stream flush and is
    // never read by a view, so it must not participate in observation.
    @ObservationIgnored private var conversationChangeTask: Task<Void, Never>?
    @ObservationIgnored var conversationChangeWorkers: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var conversationChangeWorkerTokens: [String: UUID] = [:]
    @ObservationIgnored var pendingConversationChanges: [String: [DashboardConversationChange]] = [:]
    @ObservationIgnored var terminalRunIDsByConversation: [String: String] = [:]
    private var surfaceProfilePersistenceTask: Task<Void, Never>?
    private var surfaceProfilePersistenceGeneration = 0
    @ObservationIgnored
    let localACPRuntimeResolver = LocalACPRuntimeResolver()
    @ObservationIgnored
    let localUsageService = LocalUsageService()
    @ObservationIgnored
    var usageAnalyticsRequestID: UUID?
    @ObservationIgnored
    var usageLimitsRequestID: UUID?
    @ObservationIgnored
    let usageAnalyticsRefreshCoordinator = UsageRefreshCoordinator<
        UsageAnalyticsRefreshKey,
        UsageAnalyticsSnapshot
    >()
    @ObservationIgnored
    let usageLimitsRefreshCoordinator = UsageRefreshCoordinator<
        UsageLimitsRefreshKey,
        LocalUsageLimitsSnapshot
    >()
    @ObservationIgnored
    let applicationDefaults: UserDefaults
    @ObservationIgnored
    let localACPRuntimePreferences: LocalACPRuntimePreferences
    @ObservationIgnored
    let localACPWorkspaceStore: LocalACPWorkspaceConfigurationStore
    @ObservationIgnored
    let localACPRuntimeInstaller = LocalACPRuntimeInstaller()
    @ObservationIgnored
    let conversationTitleGenerator = CodexConversationTitleGenerator()
    @ObservationIgnored
    var localACPLaunchConfigurations: [
        AgentRuntimeKind: LocalACPRuntimeLaunchConfiguration
    ] = [:]
    @ObservationIgnored
    var localACPRuntimeRefreshGeneration: UInt64 = 0
    @ObservationIgnored
    var generatingConversationTitleIDs: Set<String> = []
    @ObservationIgnored
    var localACPWorkspaceLaunchConfiguration:
        LocalACPWorkspaceLaunchConfiguration?
    @ObservationIgnored
    var localACPPermissionContinuations: [
        UUID: CheckedContinuation<String?, Never>
    ] = [:]
    @ObservationIgnored
    var localACPInteractionContinuations: [
        UUID: CheckedContinuation<LocalACPInteractionResponse, Never>
    ] = [:]
    private var loggedDashboardRecordCounts: DashboardRecordCounts?
    var noteRefreshTask: Task<Void, Never>?
    @ObservationIgnored
    var conversationAccessSequence: UInt64 = 0
    static let initialConversationMessageLimit = 40
    static let olderConversationMessageLimit = 40
    static let maximumRetainedConversationCount = 50
    /// Minimum spacing between content refreshes of one conversation. Writers
    /// already coalesce at ~75ms; this bounds the aggregate across publishers.
    static let minimumContentRefreshInterval = Duration.milliseconds(80)
    @ObservationIgnored
    var lastContentRefreshByConversation: [String: ContinuousClock.Instant] = [:]
    static let maximumActiveTurnCount = 120
    static let titleGenerationEnabledDefaultsKey =
        "wovenmatter.title-generation.enabled"
    static let titleGenerationModelDefaultsKey =
        "wovenmatter.title-generation.model"
    static let titleGenerationThinkingDefaultsKey =
        "wovenmatter.title-generation.thinking"
    static let buzzDiscoveryEnabledDefaultsKey =
        "wovenmatter.buzz.discovery-enabled"
    static let openRouterCredentialConfiguredDefaultsKey =
        "wovenmatter.openrouter-credential.configured"
    static let credentialAccessDisclosureDefaultsKey =
        "wovenmatter.credential-access.disclosure-acknowledged"
    var pendingHermesSettingsAgentID: UUID?
    var hermesGatewayConnections: [UUID: HermesGatewayConnection] = [:]
    var hermesCronJobs: [UUID: [HermesValue]] = [:]
    var hermesCronResults: [UUID: [HermesScheduledResult]] = [:]
    var hermesResultRoutes: [UUID: [String: String]] = [:]
    var hermesCronErrors: [UUID: String] = [:]
    var isRefreshingHermesCron = false
    var lastHermesCronRefresh = Date.distantPast
    var remoteHermesConnections: [UUID: HermesGatewayConnection] = [:]
    var hermesGatewayCheckedAt: [UUID: Date] = [:]

    init(
        applicationDefaults: UserDefaults = .standard,
        dashboardStore: DashboardStore? = nil,
        startsAutomatically: Bool? = nil
    ) {
        self.applicationDefaults = applicationDefaults
        self.localACPRuntimePreferences = LocalACPRuntimePreferences(
            defaults: applicationDefaults
        )
        self.remoteWorkspaces = RemoteWorkspacesModel(defaults: applicationDefaults)
        self.localACPWorkspaceStore = LocalACPWorkspaceConfigurationStore()
        self.dashboardStore = dashboardStore
        isOpenRouterCredentialConfigured = applicationDefaults.bool(
            forKey: Self.openRouterCredentialConfiguredDefaultsKey
        )
        hasAcknowledgedCredentialAccessDisclosure = applicationDefaults.bool(
            forKey: Self.credentialAccessDisclosureDefaultsKey
        )
        selectedCodexUsageWorkspaceID = CodexUsageWorkspacePreferences(
            defaults: applicationDefaults
        ).selectedWorkspaceID
        enabledUsageProviders = UsageProviderPreferences(
            defaults: applicationDefaults
        ).enabledProviders
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
            lastContentRefreshByConversation.removeAll()
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
            let noteSocketURL = supportDirectory.appending(path: "woven-note.sock")
            let noteEditingService = WovenNoteService(socketURL: noteSocketURL) {
                [weak self, dashboardStore] request in
                do {
                    guard await self?.flushNoteDrafts() == true else {
                        throw ApplicationModelError.noteDraftSaveFailed
                    }
                    let response = try await dashboardStore.handleNoteEditingRequest(request)
                    await self?.adoptNoteEditingResponse(response)
                    return response
                } catch {
                    return NoteEditingResponse(
                        success: false,
                        noteID: request.noteID,
                        error: error.localizedDescription
                    )
                }
            }
            try noteEditingService.start()
            self.noteEditingService = noteEditingService
            noteEditingSocketPath = noteSocketURL.path
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

    func startDashboardStoreIfReady() {
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
    func apply(_ snapshot: DashboardStoreSnapshot) {
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
            lastContentRefreshByConversation.removeValue(forKey: conversationID)
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
        case .localSessionConfigurationInProgress:
            "Wait for this direct chat to finish loading its model and thinking settings."
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

