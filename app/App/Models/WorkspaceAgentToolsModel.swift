import Foundation
import Observation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

enum ExecutorControl: Codable, Sendable {
    case setup(ExecutorConfiguration, prepareHost: Bool = false), refresh, dashboard
    case selection(session: String, profiles: Set<String>)
    case enabled(session: String, enabled: Bool)
}

enum BackendToolsMutation: Codable, Sendable {
    case executor(ExecutorControl)
    case saveSettings(WorkspaceToolSettings, base: WorkspaceToolSettings? = nil)
    case saveTimer(WorkspaceSessionTimer)
    case setEnabled(group: WorkspaceToolGroup, enabled: Bool, sessionID: String, confirmedPausingTimers: Bool)
    case endCoordination(sessionID: String)
    case notifications(sessionID: String, enabled: Bool)
    case pauseTimer(id: String, paused: Bool)
    case removeTimer(id: String)
    case goal(sessionID: String, mutation: WorkspaceGoalMutation)
}

@MainActor @Observable
final class WorkspaceAgentToolsModel {
    typealias SessionHandler = @MainActor (String, WovenMatterToolCommand, WovenMatterToolRequest) async throws -> WovenMatterToolResponse
    typealias NoteHandler = @MainActor (String, NoteEditingRequest, String) async throws -> NoteEditingResponse
    typealias NoteRestoreHandler = @MainActor (String, String, String, String, String) async throws -> NoteEditingResponse
    typealias UsageHandler = @MainActor (WovenMatterToolCommand) async throws -> WovenMatterToolResponse
    typealias CalendarTaskHandler = @MainActor (String, WovenMatterToolCommand, WorkspaceCalendarTask?) async throws -> WorkspaceCalendarTask
    var executorControl: (@MainActor (ExecutorControl) async throws -> URL?)?
    private let executorHandler: SessionHandler?
    var automationHandler: SessionHandler?
    var automationDidDisable: (@MainActor (String) async -> Void)?
    var executorDashboardURL: URL?
    var executorBusy = false
    func controlExecutor(_ control: ExecutorControl) async throws {
        guard let executorControl else { throw WorkspaceToolError.invalid("Executor manager is unavailable.") }
        executorBusy = true
        defer { executorBusy = false }
        executorDashboardURL = try await executorControl(control)
        try await reload()
    }
    var goalControl: (@MainActor (String, WorkspaceGoalMutation) async throws -> Void)?
    var backendMutation: (@MainActor (BackendToolsMutation) async throws -> Void)?
    private let passiveProjection: Bool
    private var pendingSettingsWrites = 0
    private var settingsEditGeneration = UUID()
    private var committedSettings: WorkspaceToolSettings
    private var mutationTask: Task<Void, Never>?
    let calendarTaskHandler: CalendarTaskHandler?
    var calendarProjection: (@MainActor () async throws -> Void)?
    var replicaReadHandler: (@MainActor (WovenMatterToolRequest, WovenMatterToolCommand, String) async throws -> WovenMatterToolResponse?)?
    let database: WorkspaceDatabase
    private(set) var settings: WorkspaceToolSettings
    private(set) var sessionPolicies: [String: WorkspaceSessionTools] = [:]
    private(set) var relationships: [String: WorkspaceSessionRelationship] = [:]
    private(set) var timers: [WorkspaceSessionTimer] = []
    private(set) var goals: [String: WorkspaceGoal] = [:]
    private(set) var receipts: [String: [WorkspaceSessionDelivery]] = [:]
    private var reloadGeneration = UUID()
    private var observedSessions: [UUID: String] = [:]
    private(set) var hasOlderReceipts: Set<String> = []
    var error: String?
    private var mcpHost: WovenMCPHost?
    #if COMPANION_FACADE_TESTS
    @ObservationIgnored var companionFixtureMCPConnection: ((String, WovenMCPConnection, RemoteWorkspaceConfiguration?) async -> WovenMCPConnection)?
    #endif
    private var remoteBridges: [String: WovenMCPRemoteBridge] = [:]
    private var remoteBridgeCredentials: [String: String] = [:]
    private var pendingBridges: [String: Task<WovenMCPRemoteBridge, any Error>] = [:]
    private var stopped = false
    private var receiptPageRequests: [String: UUID] = [:]
    private let sessionHandler: SessionHandler
    private let noteHandler: NoteHandler
    private let noteRestoreHandler: NoteRestoreHandler
    private let usageHandler: UsageHandler
    private let onMutation: @MainActor () async -> Void

    init(database: WorkspaceDatabase, sessionHandler: @escaping SessionHandler,
         noteHandler: @escaping NoteHandler, noteRestoreHandler: @escaping NoteRestoreHandler, usageHandler: @escaping UsageHandler,
         calendarTaskHandler: CalendarTaskHandler? = nil, executorHandler: SessionHandler? = nil, executorControl: (@MainActor (ExecutorControl) async throws -> URL?)? = nil, goalControl: (@MainActor (String, WorkspaceGoalMutation) async throws -> Void)? = nil, passiveProjection: Bool = false, onMutation: @escaping @MainActor () async -> Void) async throws {
        self.executorHandler = executorHandler
        self.executorControl = executorControl
        self.goalControl = goalControl
        self.passiveProjection = passiveProjection
        self.calendarTaskHandler = calendarTaskHandler
        self.database = database
        let settings = try await database.toolSettings()
        self.settings = settings
        self.committedSettings = settings
        self.sessionHandler = sessionHandler
        self.noteHandler = noteHandler
        self.noteRestoreHandler = noteRestoreHandler
        self.usageHandler = usageHandler
        self.onMutation = onMutation
        try await reload()
        if !passiveProjection { _ = try await ensureMCPHost().start() }
    }

    convenience init(projection database: WorkspaceDatabase, executorControl: (@MainActor (ExecutorControl) async throws -> URL?)? = nil,
                     send: @escaping @MainActor (BackendToolsMutation) async throws -> Void) async throws {
        try await self.init(database: database,
            sessionHandler: { _, _, _ in throw CancellationError() },
            noteHandler: { _, _, _ in throw CancellationError() },
            noteRestoreHandler: { _, _, _, _, _ in throw CancellationError() },
            usageHandler: { _ in throw CancellationError() }, passiveProjection: true, onMutation: {})
        backendMutation = send
        self.executorControl = executorControl
    }

    private func enqueue(_ mutation: BackendToolsMutation) {
        guard let backendMutation else { return }
        let previous = mutationTask
        mutationTask = Task {
            await previous?.value
            do {
                try await backendMutation(mutation)
                try await reload()
                error = nil
            } catch { self.error = error.localizedDescription }
        }
    }

    func setEnabledFromUI(_ group: WorkspaceToolGroup, enabled: Bool, sessionID: String, confirmedPausingTimers: Bool = false) async throws {
        if let backendMutation {
            try await backendMutation(.setEnabled(group: group, enabled: enabled,
                sessionID: sessionID, confirmedPausingTimers: confirmedPausingTimers))
            try await reload()
        } else { try await setEnabled(group, enabled: enabled, sessionID: sessionID, confirmedPausingTimers: confirmedPausingTimers) }
    }

    func reload(policyIDs: Set<String> = []) async throws {
        guard !stopped else { return }
        let generation = UUID()
        reloadGeneration = generation
        let mayPublishSettings = pendingSettingsWrites == 0
        let observed = Set(observedSessions.values)
        let oldest = Dictionary(uniqueKeysWithValues: observed.compactMap { id in
            receipts[id]?.last.map { (id, $0.id) }
        })
        let snapshot = try await database.toolStateSnapshot(sessionIDs: observed.union(sessionPolicies.keys).union(policyIDs),
            oldestReceipts: oldest, receiptSessionIDs: observed)
        let goals = Dictionary(uniqueKeysWithValues: try await database.sessionGoals().map { ($0.sessionID, $0) })
        guard generation == reloadGeneration, !stopped, !Task.isCancelled else { return }
        if self.goals != goals { self.goals = goals }
        if mayPublishSettings, pendingSettingsWrites == 0 {
            committedSettings = snapshot.settings
            if settings != snapshot.settings { settings = snapshot.settings }
        }
        let relationships = Dictionary(uniqueKeysWithValues: snapshot.relationships.map { ($0.sessionID, $0) })
        if self.relationships != relationships { self.relationships = relationships }
        if timers != snapshot.timers { timers = snapshot.timers }
        if sessionPolicies != snapshot.policies { sessionPolicies = snapshot.policies }
        for id in observed.intersection(observedSessions.values) {
            guard receipts[id]?.last?.id == oldest[id] else { continue }
            let rows = snapshot.receipts[id] ?? []
            if oldest[id] != nil { publishReceipts(rows, for: id) }
            else {
                publishReceipts(Array(rows.prefix(200)), for: id)
                setHasOlderReceipts(rows.count > 200, for: id)
            }
        }
    }

    func observeSessionFromUI(_ id: String?, token: UUID) {
        updateObservedSession(id, token: token)
        if id != nil {
            Task { do { try await reload() } catch { self.error = error.localizedDescription } }
        }
    }

    func observeSession(_ id: String?, token: UUID) async {
        updateObservedSession(id, token: token)
        if id != nil { do { try await reload() } catch { self.error = error.localizedDescription } }
    }

    private func updateObservedSession(_ id: String?, token: UUID) {
        reloadGeneration = UUID()
        observedSessions[token] = id
        let active = Set(observedSessions.values)
        receiptPageRequests = receiptPageRequests.filter { active.contains($0.key) }
        let retainedReceipts = receipts.filter { active.contains($0.key) }
        if receipts != retainedReceipts { receipts = retainedReceipts }
        let retainedOlderReceipts = hasOlderReceipts.intersection(active)
        if hasOlderReceipts != retainedOlderReceipts { hasOlderReceipts = retainedOlderReceipts }
    }

    private func publishReceipts(_ value: [WorkspaceSessionDelivery], for id: String) {
        // Polling must not invalidate the conversation on an unchanged snapshot.
        // Compare the complete payload, including status and native command,
        // rather than just receipt IDs or count.
        guard receipts[id] != value else { return }
        receipts[id] = value
    }

    private func setHasOlderReceipts(_ value: Bool, for id: String) {
        guard hasOlderReceipts.contains(id) != value else { return }
        if value { hasOlderReceipts.insert(id) } else { hasOlderReceipts.remove(id) }
    }

    func loadOlderReceipts(sessionID: String) async {
        reloadGeneration = UUID()
        guard let oldestID = receipts[sessionID]?.last?.id, !stopped else { return }
        let request = UUID()
        receiptPageRequests[sessionID] = request
        defer { if receiptPageRequests[sessionID] == request { receiptPageRequests[sessionID] = nil } }
        do {
            let page = try await database.sessionDeliveries(sessionID: sessionID, limit: 201,
                beforeID: oldestID, activityOnly: true)
            guard !stopped, !Task.isCancelled, receiptPageRequests[sessionID] == request,
                  observedSessions.values.contains(sessionID),
                  receipts[sessionID]?.last?.id == oldestID else { return }
            // Preserve new arrivals and fence snapshots captured before this window grew.
            reloadGeneration = UUID()
            let current = receipts[sessionID] ?? []
            let known = Set(current.map(\.id))
            publishReceipts(current + page.prefix(200).filter { !known.contains($0.id) }, for: sessionID)
            setHasOlderReceipts(page.count > 200, for: sessionID)
        } catch is CancellationError { }
        catch { if !stopped, receiptPageRequests[sessionID] == request { self.error = error.localizedDescription } }
    }

    func endCoordination(sessionID: String) async {
        if passiveProjection { enqueue(.endCoordination(sessionID: sessionID)); return }
        do { try await database.endCoordination(targetID: sessionID); try await reload(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func setNotifications(sessionID: String, enabled: Bool) async {
        if passiveProjection { enqueue(.notifications(sessionID: sessionID, enabled: enabled)); return }
        do {
            if let source = try await database.sessionRelationship(sessionID).coordinatorID {
                try await database.setCoordinationNotifications(sourceID: source, targetID: sessionID, enabled: enabled)
            }
            try await reload(); error = nil
        } catch { self.error = error.localizedDescription }
    }

    func pauseTimer(_ timer: WorkspaceSessionTimer, paused: Bool) async {
        if passiveProjection { enqueue(.pauseTimer(id: timer.id, paused: paused)); return }
        do { try await database.pauseSessionTimer(id: timer.id, paused: paused); try await reload(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func removeTimer(_ timer: WorkspaceSessionTimer) async {
        if passiveProjection { enqueue(.removeTimer(id: timer.id)); return }
        do { try await database.removeSessionTimer(id: timer.id); try await reload(); error = nil }
        catch { self.error = error.localizedDescription }
    }

    /// SwiftUI reads a published value; loading is done by observeSession/reload.
    func policy(for sessionID: String) -> WorkspaceSessionTools {
        sessionPolicies[sessionID] ?? WorkspaceSessionTools(enabled: [])
    }

    func saveSettingsFromUI(_ value: WorkspaceToolSettings) {
        let generation = UUID()
        settingsEditGeneration = generation
        reloadGeneration = UUID()
        settings = value
        pendingSettingsWrites += 1
        let previous = mutationTask
        mutationTask = Task {
            await previous?.value
            // Compare against the last completed write, so a queued toggle can
            // undo its predecessor and a failed predecessor can be retried.
            let base = committedSettings
            var failure: String?
            do {
                if let backendMutation { try await backendMutation(.saveSettings(value, base: base)) }
                else { try await database.saveToolSettings(value, from: base) }
                committedSettings = value
            } catch { failure = error.localizedDescription }
            pendingSettingsWrites -= 1
            guard settingsEditGeneration == generation, pendingSettingsWrites == 0, !stopped else { return }
            guard let failure else { error = nil; return }

            // A failed optimistic edit must not keep displaying unsaved defaults.
            // Preserve newer edits, and reconcile an uncertain backend reply with
            // its committed database value without allowing a stale read to win.
            settings = committedSettings
            error = failure
            let rollbackGeneration = UUID()
            reloadGeneration = rollbackGeneration
            if let saved = try? await database.toolSettings() {
                guard settingsEditGeneration == generation, pendingSettingsWrites == 0,
                      reloadGeneration == rollbackGeneration, !stopped else { return }
                committedSettings = saved
                if settings != saved { settings = saved }
            }
        }
    }

    func saveTimer(_ timer: WorkspaceSessionTimer) async throws {
        if let backendMutation { try await backendMutation(.saveTimer(timer)) }
        else { _ = try await database.saveSessionTimer(timer, callerID: timer.sessionID) }
        try await reload()
    }

    func saveSettings(_ value: WorkspaceToolSettings) async {
        saveSettingsFromUI(value)
        await mutationTask?.value
    }

    func setEnabled(_ group: WorkspaceToolGroup, enabled: Bool, sessionID: String, confirmedPausingTimers: Bool = false) async throws {
        guard !passiveProjection else { throw WorkspaceToolError.invalid("Use the background service to change session tools.") }
        if group == .executor {
            guard let executorControl else { throw WorkspaceToolError.invalid("Executor manager is unavailable.") }
            _ = try await executorControl(.enabled(session: sessionID, enabled: enabled))
            try await reload(policyIDs: [sessionID])
            return
        }
        let policy = try await database.setSessionToolEnabled(group, enabled: enabled, sessionID: sessionID,
            confirmedPausingTimers: confirmedPausingTimers)
        sessionPolicies[sessionID] = policy
        if [.browser, .computer].contains(group), !enabled { await automationDidDisable?(sessionID) }
        try await reload()
    }

    private func ensureMCPHost() throws -> WovenMCPHost {
        guard !passiveProjection, !stopped else { throw CancellationError() }
        if let mcpHost { return mcpHost }
        let host = try WovenMCPHost(database: database) { [weak self] request, callerID in
            guard let self else { return .init(success: false, error: "Woven MCP stopped.", code: "unavailable") }
            return await self.handle(request, callerID: callerID)
        }
        host.botNotificationSink = botNotificationSink
        mcpHost = host
        return host
    }

    var botNotificationSink: (@MainActor (WovenBotNotification) async throws -> Void)? {
        didSet { mcpHost?.botNotificationSink = botNotificationSink }
    }

    func mcpEndpoint() async throws -> String { try await ensureMCPHost().start() }

    func issueBotKey(machineID: String, botID: String, botName: String) async throws -> WovenBotMCPGrant {
        try await ensureMCPHost().issueBotKey(machineID: machineID, botID: botID, botName: botName)
    }

    func revokeBotKey(callerID: String, sticky: Bool) throws {
        try ensureMCPHost().revokeBotKey(callerID: callerID, sticky: sticky)
    }

    func reinstateBot(callerID: String) async throws { try await ensureMCPHost().reinstateBot(callerID: callerID) }

    func setBotsPaused(machineID: String, paused: Bool) async throws {
        try await ensureMCPHost().setBotsPaused(machineID: machineID, paused: paused)
    }

    func botCallers() async throws -> [WovenBotCaller] { try await database.botCallers() }

    func trackBotDispatch(callerID: String, fence: AgentDispatchFence) throws -> UUID? {
        guard WovenMCPCaller.parseBot(callerID) != nil else { return nil }
        return try ensureMCPHost().trackBotDispatch(callerID: callerID, fence: fence)
    }

    func finishBotDispatch(_ id: UUID?) { mcpHost?.finishBotDispatch(id) }

    func deliverBotNotification(_ delivery: WorkspaceSessionDelivery) async throws -> Bool {
        try await ensureMCPHost().deliverBotNotification(delivery)
    }

    func mcpAccess(_ action: WovenMCPAccessAction) async throws -> WovenMCPAccessSnapshot {
        let snapshot = try await ensureMCPHost().access(action)
        try await reload()
        return snapshot
    }

    func handleMCP(_ request: CompanionHTTPRequest) async -> CompanionHTTPResponse? {
        guard !passiveProjection, !stopped else { return nil }
        do { return await (try ensureMCPHost()).handle(request) }
        catch { return .error("unavailable", "Woven MCP is unavailable.", status: 503) }
    }

    func mcpContext(sessionID: String, remote: RemoteWorkspaceConfiguration? = nil, captureID: String) async throws -> WovenMCPConnection {
        let local = try await ensureMCPHost().connection(sessionID: sessionID, captureID: captureID.isEmpty ? nil : captureID)
        #if COMPANION_FACADE_TESTS
        if let companionFixtureMCPConnection { return await companionFixtureMCPConnection(sessionID, local, remote) }
        #endif
        guard let remote else { return local }
        let bridge: WovenMCPRemoteBridge
        if let current = remoteBridges[sessionID], current.isRunning, remoteBridgeCredentials[sessionID] == local.bearerToken { bridge = current }
        else {
            remoteBridges.removeValue(forKey: sessionID)?.stop()
            let pending: Task<WovenMCPRemoteBridge, any Error>
            if let existing = pendingBridges[sessionID] { pending = existing }
            else {
                pending = Task { try await WovenMCPRemoteBridge.start(configuration: remote, localConnection: local) }
                pendingBridges[sessionID] = pending
            }
            defer { pendingBridges.removeValue(forKey: sessionID) }
            bridge = try await pending.value
            guard !stopped else { bridge.stop(); throw CancellationError() }
            remoteBridges[sessionID] = bridge
            remoteBridgeCredentials[sessionID] = local.bearerToken
        }
        let connection = try bridge.remoteConnection
        return .init(endpointURL: connection.endpointURL, bearerToken: connection.bearerToken, captureID: local.captureID, sessionID: sessionID)
    }

    func revokeSessionMCP(_ sessionID: String) {
        pendingBridges.removeValue(forKey: sessionID)?.cancel()
        remoteBridges.removeValue(forKey: sessionID)?.stop()
        remoteBridgeCredentials.removeValue(forKey: sessionID)
        mcpHost?.revokeSession(sessionID)
    }

    func stop() {
        stopped = true
        reloadGeneration = UUID()
        receiptPageRequests.removeAll()
        for pending in pendingBridges.values { pending.cancel() }
        pendingBridges.removeAll()
        for bridge in remoteBridges.values { bridge.stop() }
        remoteBridges.removeAll(); remoteBridgeCredentials.removeAll()
        mcpHost?.stop(); mcpHost = nil
    }

    func handle(_ request: WovenMatterToolRequest, callerID: String) async -> WovenMatterToolResponse {
        await execute(request, callerID: callerID).bounded()
    }

    private func execute(_ request: WovenMatterToolRequest, callerID: String) async -> WovenMatterToolResponse {
        guard !passiveProjection else { return .init(success: false, error: "Tool execution belongs to the background service.") }
        let session = sessionHandler, note = noteHandler, restore = noteRestoreHandler, usage = usageHandler
        let onMutation = onMutation
        var handlers = WorkspaceToolHandlers(afterExecution: { [weak self] in
            try await self?.reload()
            await onMutation()
        })
        handlers.session = { caller, command, request in try await session(caller, command, request) }
        handlers.note = { caller, edit, requestID in try await note(caller, edit, requestID) }
        handlers.noteRestore = { caller, noteID, versionID, revision, requestID in
            try await restore(caller, noteID, versionID, revision, requestID)
        }
        handlers.usage = { command in try await usage(command) }
        if let handler = calendarTaskHandler {
            handlers.calendarTask = { caller, command, existing in try await handler(caller, command, existing) }
        }
        if let projection = calendarProjection { handlers.calendarProjection = { try await projection() } }
        if let handler = replicaReadHandler {
            handlers.replicaRead = { request, command, caller in try await handler(request, command, caller) }
        }
        if let handler = automationHandler {
            handlers.automation = { caller, command, request in try await handler(caller, command, request) }
        }
        if let handler = executorHandler {
            handlers.executor = { caller, command, request in try await handler(caller, command, request) }
        }
        return await WorkspaceToolExecutor(database: database).execute(request, callerID: callerID, handlers: handlers)
    }

    func library(_ command: WovenMatterToolCommand, callerID: String) async throws -> WovenMatterToolResponse {
        try await WorkspaceToolExecutor(database: database).library(command, callerID: callerID)
    }

    static func date(_ raw: String) throws -> Date { try WorkspaceToolExecutor.date(raw) }
}
