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
    private(set) var loadError: String?
    var notice: String?

    @ObservationIgnored var perform: (@MainActor (BotsCommand) async throws -> BotsCommandResult)?
    @ObservationIgnored private var client: PiBotClient?
    @ObservationIgnored private var clientBase: URL?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var loadedThreads = Set<String>()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?

    let webSessions = BotWebSessionStore()

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
        connection = .closed
        capabilities = []
    }

    private func handle(_ event: PiBotClient.Event) {
        switch event {
        case .state(let state):
            connection = state
        case .hello(let health):
            capabilities = Set(health.capabilities ?? [])
            scheduleRefresh()
        case .botsChanged, .groupsChanged:
            scheduleRefresh()
        case .threadsChanged(let botID):
            if loadedThreads.contains(botID) { Task { await loadThreads(botID: botID) } }
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
        guard let client else { notice = "Bots are not connected."; return }
        do { try await work(client) }
        catch { notice = error.localizedDescription }
    }

    func createBot(name: String) async -> PiBotSummary? {
        guard let client else { notice = "Bots are not connected."; return nil }
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
