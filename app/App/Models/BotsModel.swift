import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore
import WovenMatterDashboardStore

/// The window's view of bots on every machine: one session per machine whose Woven
/// server hosts bots, plus host state projected from the process that owns execution.
@MainActor @Observable
final class BotsModel {
    private(set) var machines: [BotMachine] = []
    private(set) var thisMachineID: String?
    private(set) var thisMacVersion: String?
    private(set) var callers: [WovenBotCaller] = []
    private(set) var devices: [BotDiscoveredDevice]?
    private(set) var syncErrors: [String] = []
    private(set) var botMCP: WorkspaceExternalMCPSettings?
    private(set) var sessions: [String: BotMachineSession] = [:]
    private(set) var loadError: String?
    private(set) var busy = false
    var notice: String?

    @ObservationIgnored var perform: (@MainActor (BotsCommand) async throws -> BotsCommandResult)?
    /// Unsent text and attachments, by machine, bot and conversation. Closing a pane keeps them.
    let drafts = BotDraftStore()

    var thisMachine: BotMachine? { machines.first { $0.kind == .thisMac } }
    /// Machines that can show bots, this Mac first.
    var botMachines: [BotMachine] { machines.filter { $0.socket != nil } }
    var orderedSessions: [BotMachineSession] { botMachines.compactMap { sessions[$0.id] } }
    var versionReport: BotVersionReport { .init(thisMacVersion: thisMacVersion, machines: machines, syncErrors: syncErrors) }

    func session(for machineID: String) -> BotMachineSession? { sessions[machineID] }

    func name(for target: DashboardBotTarget) -> String? {
        sessions[target.machineID]?.bots.first { $0.id == target.botID }?.name
    }

    @discardableResult
    func send(_ command: BotsCommand) async throws -> BotsCommandResult {
        guard let perform else { throw BotsError.unavailable("Bots are still starting.") }
        busy = true
        defer { busy = false }
        let result = try await perform(command)
        apply(result)
        return result
    }

    /// Runs a command and reports a failure as a notice.
    func attempt(_ command: BotsCommand) async {
        do { try await send(command) } catch { notice = error.localizedDescription }
    }

    @ObservationIgnored private var refreshLoop: Task<Void, Never>?

    /// Other machines come and go without telling this one, so look again now and then.
    func startRefreshing() {
        refreshLoop?.cancel()
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        do { try await send(.status); loadError = nil }
        catch { loadError = error.localizedDescription }
    }

    func apply(_ result: BotsCommandResult) {
        machines = result.machines
        thisMachineID = result.thisMachineID
        thisMacVersion = result.thisMacVersion
        callers = result.callers
        if let devices = result.devices { self.devices = devices }
        syncErrors = result.syncErrors
        botMCP = result.botMCP
        let live = Dictionary(uniqueKeysWithValues: botMachines.map { ($0.id, $0) })
        for (id, session) in sessions where live[id] == nil {
            session.disconnect()
            sessions[id] = nil
        }
        for (id, machine) in live {
            let session = sessions[id] ?? BotMachineSession(machineID: id, drafts: drafts, notice: { [weak self] in self?.notice = $0 },
                                                            signSocket: { [weak self] url, audience in try await self?.socketHeaders(url, audience) ?? [:] })
            sessions[id] = session
            session.apply(machine)
        }
    }

    /// Signed upgrade headers from the process that holds this Mac's member key.
    func socketHeaders(_ url: URL, _ audience: String) async throws -> [String: String] {
        guard let perform else { throw BotsError.unavailable("Bots are still starting.") }
        guard let headers = try await perform(.signSocket(url: url, audience: audience)).socketHeaders else {
            throw BotsError.unavailable("This Mac could not sign the bots connection.")
        }
        return headers
    }

    func conversation(_ target: DashboardBotTarget) -> BotConversationController? {
        sessions[target.machineID]?.conversation(botID: target.botID, conversationID: target.conversationID)
    }
}

/// One machine's bots runtime: its socket, sidebar data and open conversations.
@MainActor @Observable
final class BotMachineSession: Identifiable {
    let machineID: String
    nonisolated var id: String { machineID }
    private(set) var machine: BotMachine
    private(set) var connection = PiBotClient.ConnectionState.closed
    private(set) var bots: [PiBotSummary] = []
    private(set) var groups: [PiBotGroup] = []
    private(set) var threadsByBot: [String: [PiBotThread]] = [:]
    private(set) var capabilities: Set<String> = []
    private(set) var health: PiBotHealth?
    private(set) var onboarding: PiBotOnboardingStatus?
    private(set) var runtimeStatus: PiBotRuntimeStatus?
    private(set) var progress: PiBotRuntimeProgress?
    /// A `runtime.update` run is in progress.
    private(set) var updating = false
    /// The last container state each bot's runtime announced.
    private(set) var environmentStates: [String: String] = [:]
    private(set) var environmentRevision = 0
    /// The bot list has arrived from this machine at least once.
    private(set) var hasLoadedBots = false
    private(set) var loadError: String?
    /// Bumped when the runtime says its bots, or the settings behind them, changed.
    private(set) var settingsRevision = 0
    let drafts: BotDraftStore

    @ObservationIgnored private let report: (String) -> Void
    @ObservationIgnored private let signSocket: @MainActor @Sendable (URL, String) async throws -> [String: String]
    @ObservationIgnored private var client: PiBotClient?
    @ObservationIgnored private var clientEndpoint: BotSocketEndpoint?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var loadedThreads = Set<String>()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var reloads = 0
    @ObservationIgnored private var conversations: [BotConversationKey: BotConversationController] = [:]
    @ObservationIgnored private var memoryObservers: [UUID: (String) -> Void] = [:]

    init(machineID: String, drafts: BotDraftStore, notice: @escaping (String) -> Void = { _ in },
         signSocket: @escaping @MainActor @Sendable (URL, String) async throws -> [String: String] = { _, _ in
             throw BotsError.unavailable("Bots on other machines need this Mac's member key.")
         }) {
        self.machineID = machineID
        self.drafts = drafts
        report = notice
        self.signSocket = signSocket
        machine = BotMachine(id: machineID, name: "", kind: .linux, state: .unreachable)
    }

    /// The socket Settings and conversations use. Nil until the machine's runtime answers.
    var connectedClient: PiBotClient? { connection == .open ? client : nil }
    var layout: PiBotSidebarLayout { PiBotSidebarLayout(bots: bots, groups: groups) }
    var isConnected: Bool { connection == .open }
    var supportsGroups: Bool { capabilities.contains("groups") }
    /// Old runtimes lack the protocol the bot UI runs on.
    var isCompatible: Bool { health == nil || (health?.supports("groups") == true && health?.supports("message.context") == true) }
    var isAvailable: Bool { machine.state == .ready && isCompatible }
    var displayName: String { machine.displayName }

    func threads(for botID: String) -> [PiBotThread] { PiBotThread.sorted(threadsByBot[botID] ?? []) }

    func apply(_ next: BotMachine) {
        machine = next
        let endpoint = next.state == .ready ? next.socket : nil
        guard endpoint != clientEndpoint else { return }
        // A different socket is a different runtime: nothing on screen applies.
        disconnect()
        bots = []; groups = []; threadsByBot = [:]; loadedThreads = []; onboarding = nil; hasLoadedBots = false
        forgetConversations()
        guard let endpoint else { return }
        clientEndpoint = endpoint
        let (stream, continuation) = AsyncStream<PiBotClient.Event>.makeStream()
        // Another member's socket is signed afresh for every connection attempt.
        var authorize: PiBotClient.Authorize?
        if let audience = endpoint.audience {
            let sign = signSocket
            authorize = { @Sendable url in try await sign(url, audience) }
        }
        let next = PiBotClient(socketURL: endpoint.url, bearer: endpoint.isSigned ? nil : endpoint.bearer, authorize: authorize) { continuation.yield($0) }
        client = next
        eventTask = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
        Task { await next.connect() }
    }

    func disconnect() {
        eventTask?.cancel(); eventTask = nil
        if let client { Task { await client.invalidate() } }
        client = nil; clientEndpoint = nil
        setConnection(.closed)
        capabilities = []
    }

    private func setConnection(_ state: PiBotClient.ConnectionState) {
        guard connection != state else { return }
        connection = state
        if state != .open { conversations.values.forEach { $0.connectionLost() } }
    }

    // MARK: Conversations

    /// The one state for a conversation, shared by every panel showing it.
    func conversation(botID: String, conversationID: Int?) -> BotConversationController {
        let key = BotConversationKey(machineID: machineID, botID: botID, conversationID: conversationID)
        if let existing = conversations[key] { return existing }
        // Conversations nobody is looking at don't accumulate over a long session.
        if conversations.count >= 16 {
            for (other, controller) in conversations where !controller.isAttached { conversations[other] = nil }
        }
        let controller = BotConversationController(session: self, key: key)
        conversations[key] = controller
        return controller
    }

    private func forgetConversations() {
        conversations.values.forEach { $0.forget() }
        conversations = [:]
    }

    func observeMemory(_ observer: @escaping (String) -> Void) -> UUID {
        let token = UUID()
        memoryObservers[token] = observer
        return token
    }
    func stopObservingMemory(_ token: UUID) { memoryObservers[token] = nil }

    func refreshOnboarding(onError: ((String) -> Void)? = nil) async {
        guard let client = connectedClient else { return }
        do {
            let status = try await client.onboardingStatus()
            guard client === self.client else { return }
            onboarding = status
        } catch {
            guard client === self.client else { return }
            loadError = error.localizedDescription
            onError?(error.localizedDescription)
        }
    }

    private func handle(_ event: PiBotClient.Event) {
        switch event {
        case .state(let state):
            setConnection(state)
        case .hello(let health):
            self.health = health
            capabilities = Set(health.capabilities ?? [])
            scheduleRefresh()
            conversations.values.forEach { $0.connectionOpened() }
            Task { await refreshOnboarding(); await refreshRuntimeStatus() }
        case .botsChanged:
            settingsRevision += 1
            scheduleRefresh()
        case .groupsChanged:
            scheduleRefresh()
        case .threadsChanged(let botID):
            if loadedThreads.contains(botID) { Task { await loadThreads(botID: botID) } }
        case .memoryChanged(let botID):
            memoryObservers.values.forEach { $0(botID) }
        case .conversation(let botID, let conversationID, let event):
            for controller in conversations.values where controller.key.botID == botID {
                controller.receive(conversationID: conversationID, event)
            }
        case .runtimeProgress(let progress):
            // The run's last word stays on screen; a later run replaces it.
            self.progress = progress
            if progress.isFinished { updating = false; Task { await refreshRuntimeStatus(); await reload() } }
        case .environmentChanged(let botID, let state):
            environmentRevision += 1
            environmentStates[botID] = state
        }
    }

    /// Bursts of change notifications collapse into one reload.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            await self?.reload()
        }
    }

    func reload() async {
        guard let client else { return }
        reloads += 1
        let current = reloads
        do {
            let latest = try await client.bots()
            let latestGroups = capabilities.contains("groups") ? try await client.groups() : []
            // A reload that finishes late must not undo a newer one.
            guard client === self.client, current == reloads else { return }
            bots = latest
            hasLoadedBots = true
            groups = latestGroups
            loadError = nil
            let present = Set(latest.map(\.id))
            threadsByBot = threadsByBot.filter { present.contains($0.key) }
            loadedThreads.formIntersection(present)
            await refreshOnboarding()
            for botID in loadedThreads { await loadThreads(botID: botID) }
        } catch {
            guard client === self.client, current == reloads else { return }
            loadError = error.localizedDescription
        }
    }

    func refreshRuntimeStatus() async {
        guard let client = connectedClient else { return }
        if let status = try? await client.runtimeStatus(), client === self.client { runtimeStatus = status }
    }

    func loadThreads(botID: String) async {
        guard let client else { return }
        loadedThreads.insert(botID)
        do {
            let threads = try await client.threads(botID: botID)
            guard client === self.client else { return }
            threadsByBot[botID] = threads
        } catch {
            guard client === self.client else { return }
            loadError = error.localizedDescription
        }
    }

    private func attempt(_ work: (PiBotClient) async throws -> Void) async {
        guard let client = connectedClient else { report("Bots on \(displayName) are not connected."); return }
        do { try await work(client) }
        catch { report(error.localizedDescription) }
    }

    func createBot(name: String) async -> PiBotSummary? {
        guard let client = connectedClient else { report("Bots on \(displayName) are not connected."); return nil }
        do {
            let bot = try await client.createBot(name: name)
            await reload()
            return bot
        } catch {
            report(error.localizedDescription)
            return nil
        }
    }

    func rename(botID: String, name: String) async { await attempt { try await $0.renameBot(id: botID, name: name) }; await reload() }
    func delete(botID: String) async { await attempt { try await $0.deleteBot(id: botID) }; await reload() }
    func setGroup(botID: String, groupID: String?) async { await attempt { try await $0.setGroup(botID: botID, groupID: groupID) }; await reload() }
    func renameGroup(id: String, name: String) async { await attempt { try await $0.renameGroup(id: id, name: name) }; await reload() }
    func deleteGroup(id: String) async { await attempt { try await $0.deleteGroup(id: id) }; await reload() }

    func createGroup(name: String, adding botID: String? = nil) async {
        await attempt { client in
            let group = try await client.createGroup(name: name)
            if let botID { try await client.setGroup(botID: botID, groupID: group.id) }
        }
        await reload()
    }

    func moveGroup(id: String, by offset: Int) async {
        var ids = groups.sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        await attempt { try await $0.reorderGroups(ids: ids) }
        await reload()
    }

    func setPinned(botID: String, conversationID: Int, pinned: Bool) async {
        await attempt { try await $0.setPinned(botID: botID, conversationID: conversationID, pinned: pinned) }
        await loadThreads(botID: botID)
    }

    /// Starts updating every bot here: each is snapshotted, updated and health-checked,
    /// and rolled back on failure. Progress arrives as `runtime.update` pushes.
    func updateBots() async {
        guard !updating else { return }
        updating = true
        progress = .init(phase: "stopping")
        await attempt { try await $0.updateBots() }
        if connectedClient == nil { updating = false }
    }

    /// Waits for a running update to finish, for "Update everything".
    func waitForUpdate(timeout: Duration = .seconds(3_600)) async {
        let deadline = ContinuousClock.now + timeout
        while updating, ContinuousClock.now < deadline, connection == .open || connection == .connecting {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    func rebuild(botID: String) async {
        await attempt { try await $0.rebuildBot(id: botID) }
        await reload()
    }
}
