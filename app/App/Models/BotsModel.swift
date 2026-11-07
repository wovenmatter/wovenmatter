import Foundation
import Observation
import WovenMatterClient
import WovenMatterCore

/// The window's view of bots: sidebar data from Pi Bot's own socket, and deployment
/// state projected from whichever process owns the runtime.
@MainActor @Observable
final class BotsModel {
    private(set) var runtime = PiBotRuntimeSnapshot()
    private(set) var connection = PiBotClient.ConnectionState.closed
    private(set) var bots: [PiBotSummary] = []
    private(set) var groups: [PiBotGroup] = []
    private(set) var threadsByBot: [String: [PiBotThread]] = [:]
    private(set) var capabilities: Set<String> = []
    private(set) var onboarding: PiBotOnboardingStatus?
    /// The bot list has arrived from this server at least once.
    private(set) var hasLoadedBots = false
    private(set) var loadError: String?
    var notice: String?

    @ObservationIgnored var perform: (@MainActor (BotsCommand) async throws -> BotsCommandResult)?
    @ObservationIgnored private var client: PiBotClient?
    @ObservationIgnored private var clientBase: URL?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var loadedThreads = Set<String>()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var conversations: [BotConversationKey: BotConversationController] = [:]
    @ObservationIgnored private var loginObservers: [String: (PiBotLoginEvent) -> Void] = [:]
    @ObservationIgnored private var loginBacklog = PiBotLoginBacklog()
    @ObservationIgnored private var memoryObservers: [UUID: (String) -> Void] = [:]
    /// Bumped when the server says its bots, or the settings behind them, changed.
    private(set) var settingsRevision = 0

    /// Unsent text and attachments, by bot and conversation. Closing a pane keeps them.
    let drafts = BotDraftStore()

    /// The socket Settings and conversations use. Nil until a server is ready.
    var connectedClient: PiBotClient? { connection == .open ? client : nil }

    var layout: PiBotSidebarLayout { PiBotSidebarLayout(bots: bots, groups: groups) }
    var isConnected: Bool { connection == .open }
    var supportsGroups: Bool { capabilities.contains("groups") }

    func threads(for botID: String) -> [PiBotThread] {
        PiBotThread.sorted(threadsByBot[botID] ?? [])
    }

    func name(for target: DashboardBotTarget) -> String? {
        bots.first { $0.id == target.botID }?.name
    }

    func send(_ command: BotsCommand) async throws -> BotsCommandResult {
        guard let perform else { throw PiBotHostError.command("Bots are still starting.") }
        let result = try await perform(command)
        apply(result.snapshot)
        return result
    }

    func refreshRuntime() async {
        do { _ = try await send(.status) }
        catch { loadError = error.localizedDescription }
    }

    func apply(_ snapshot: PiBotRuntimeSnapshot) {
        let base = snapshot.phase == .ready ? snapshot.baseURL : nil
        // Each device has its own bots, so its sidebar must not outlive the switch. A
        // reconnect to the same place keeps what is on screen.
        let moved = snapshot.target.map { next in runtime.target.map { !$0.isSameDevice(as: next) || $0.ownership != next.ownership } ?? false } ?? (runtime.target != nil)
        let replaced = snapshot.health?.installationId != nil && runtime.health?.installationId != nil
            && snapshot.health?.installationId != runtime.health?.installationId
        if moved || replaced {
            disconnect()
            bots = []
            groups = []
            threadsByBot = [:]
            loadedThreads = []
            onboarding = nil
            hasLoadedBots = false
            forgetConversations()
        }
        runtime = snapshot
        guard base != clientBase else { return }
        disconnect()
        guard let base else { return }
        clientBase = base
        let (stream, continuation) = AsyncStream<PiBotClient.Event>.makeStream()
        let next = PiBotClient(baseURL: base) { continuation.yield($0) }
        client = next
        eventTask = Task { [weak self] in
            for await event in stream { self?.handle(event) }
        }
        Task { await next.connect() }
    }

    private func disconnect() {
        eventTask?.cancel(); eventTask = nil
        if let client { Task { await client.invalidate() } }
        client = nil; clientBase = nil
        loginObservers = [:]
        loginBacklog.removeAll()
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
        let key = BotConversationKey(botID: botID, conversationID: conversationID)
        if let existing = conversations[key] { return existing }
        // Conversations nobody is looking at don't accumulate over a long session.
        if conversations.count >= 16 {
            for (other, controller) in conversations where !controller.isAttached { conversations[other] = nil }
        }
        let controller = BotConversationController(bots: self, key: key)
        conversations[key] = controller
        return controller
    }

    private func forgetConversations() {
        conversations.values.forEach { $0.forget() }
        conversations = [:]
    }

    /// Asks a client that has been told to restart to come back promptly.
    func expectRestart() { if let client { Task { await client.expectRestart() } } }

    /// Runs `body` until cancelled with each login event for `loginID`.
    func observeLogin(_ loginID: String, _ observer: @escaping (PiBotLoginEvent) -> Void) {
        loginObservers[loginID] = observer
        for event in loginBacklog.take(loginID: loginID) { observer(event) }
    }
    func stopObservingLogin(_ loginID: String) { loginObservers[loginID] = nil }

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
            capabilities = Set(health.capabilities ?? [])
            scheduleRefresh()
            conversations.values.forEach { $0.connectionOpened() }
            Task { await refreshOnboarding() }
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
            for controller in conversations.values where controller.key.botID == botID && controller.viewedID == conversationID {
                controller.receive(event)
            }
        case .login(let loginID, let event):
            if let observer = loginObservers[loginID] { observer(event) }
            else { loginBacklog.append(event, loginID: loginID) }
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
        do {
            let latest = try await client.bots()
            let latestGroups = capabilities.contains("groups") ? try await client.groups() : []
            guard client === self.client else { return }
            bots = latest
            hasLoadedBots = true
            groups = latestGroups
            loadError = nil
            let present = Set(latest.map(\.id))
            threadsByBot = threadsByBot.filter { present.contains($0.key) }
            loadedThreads.formIntersection(present)
            for botID in loadedThreads { await loadThreads(botID: botID) }
        } catch {
            guard client === self.client else { return }
            loadError = error.localizedDescription
        }
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
        guard let client = connectedClient else { notice = "Bots are not connected."; return }
        do { try await work(client) }
        catch { notice = error.localizedDescription }
    }

    func createBot(name: String) async -> PiBotSummary? {
        guard let client = connectedClient else { notice = "Bots are not connected."; return nil }
        do {
            let bot = try await client.createBot(name: name)
            await reload()
            return bot
        } catch {
            notice = error.localizedDescription
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
}
