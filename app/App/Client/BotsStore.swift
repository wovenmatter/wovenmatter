import Foundation
import Observation
import WovenProtocol

/// A bots request the runtime or the home machine's server refused, in its own words.
struct BotsCallError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }

    static let notConnected = BotsCallError(message: "Bots are not connected.")
}

/// The bots and the Forum, on the bots' home machine: bots, groups, threads, the Forum, onboarding
/// and resources. There is one set of bots, on one machine chosen from the Woven machines. The UI
/// connects to the home machine's server directly for the bots and the Forum; while that machine
/// is away, the bots and their chats show what this Mac's library holds.
@MainActor
@Observable
final class BotsStore {
    init() {}

    /// This Mac's server, for what the library holds.
    @ObservationIgnored private(set) weak var library: ServerConnection?
    @ObservationIgnored private weak var connections: MachineConnections?
    /// The home machine's server, connected to directly; this Mac's until a home is known.
    var server: ServerConnection? { connections?.connection(for: homeMachineID) ?? library }
    @ObservationIgnored private weak var machines: MachinesStore?
    @ObservationIgnored private weak var settings: SettingsStore?
    @ObservationIgnored private var following: Task<Void, Never>?

    /// Follows the bots on the home machine's server for as long as the app runs, moving to
    /// another machine's when the home changes. While the home machine cannot be reached the
    /// bots read as unreachable, from the library.
    func attach(_ connections: MachineConnections, machines: MachinesStore, settings: SettingsStore) {
        self.library = connections.local
        self.connections = connections
        self.machines = machines
        self.settings = settings
        following?.cancel()
        following = Task { [weak self] in
            while !Task.isCancelled {
                guard let server = self?.server else {
                    try? await Task.sleep(for: .milliseconds(500))
                    continue
                }
                let live = Task { [weak self] in
                    await server.follow(SubscribeBots(), reply: { [weak self] opened in
                        self?.apply(opened.status, reload: true)
                    }, event: { [weak self] event in
                        self?.receive(event)
                    })
                }
                while !Task.isCancelled, let self, self.server === server {
                    if !server.isConnected, server !== library, let home = homeMachineID, state != .unreachable {
                        apply(BotsStatus(homeMachineID: home, state: .unreachable), reload: true)
                    }
                    try? await Task.sleep(for: .milliseconds(500))
                }
                live.cancel()
            }
        }
    }

    // MARK: Home machine

    /// The runtime's state as the server last reported it.
    private var status: BotsStatus?

    /// The machine the bots live on; nil until one is chosen.
    var homeMachineID: String? { status?.homeMachineID ?? settings?.values[botsHomeSetting]?.string }
    var homeMachine: Machine? { homeMachineID.flatMap { id in machines?.machines.first { $0.id == id } } }

    /// The bots runtime on the home machine.
    var state: BotsState {
        guard homeMachineID != nil else { return .off }
        switch status?.state {
        case .ready: return .ready
        case .unreachable: return .unreachable
        case .failed: return .failed
        case .transferring: return .transferring
        case .off, .starting, nil: return .starting
        }
    }

    /// A transfer to another machine, while one runs.
    var transfer: BotsTransferProgress? { status?.transfer }
    /// Why the last transfer failed.
    private(set) var transferError: String?

    /// Moves the bots to `machineID`: the home machine's server stops them, sends them, and
    /// they start there. Returns once they run there or the transfer failed.
    func transfer(to machineID: String) async {
        transferError = nil
        do {
            guard let server else { throw ClientError.notConnected }
            _ = try await server.call(TransferBots(targetMachineID: machineID))
        } catch {
            transferError = (error as? ProtocolError)?.message ?? error.localizedDescription
        }
    }

    /// Why the runtime is in its state, when the server says.
    var message: String? { status?.message }
    /// The home machine's memory and disk, once its server has reported them.
    var capacity: BotMachineCapacity? {
        status?.capacity.map {
            BotMachineCapacity(memoryBytes: $0.memoryBytes, diskTotalBytes: $0.diskTotalBytes, diskFreeBytes: $0.diskFreeBytes,
                               diskUsedByBotsBytes: $0.diskUsedByBotsBytes)
        }
    }

    /// "This Mac", or the home machine's name.
    var displayName: String {
        guard let homeMachine else { return "Bots" }
        return homeMachine.isThisMachine ? "This Mac" : homeMachine.name
    }

    /// Makes `machineID` the bots' first home. This Mac's server refuses while any machine it
    /// reaches knows of bots: moving the bots is a transfer, not a new home.
    func chooseHome(_ machineID: String) async {
        guard homeMachineID == nil else { return }
        do {
            guard let library else { throw ClientError.notConnected }
            _ = try await library.call(ChooseBotsHome(machineID: machineID))
            loadError = nil
        } catch {
            loadError = (error as? ProtocolError)?.message ?? error.localizedDescription
        }
    }

    // MARK: Resources

    private static let resourcesSetting = "bots.resources"

    /// The limits set for bots there; nil means the defaults.
    var resources: BotResourceSettings? {
        guard let fields = settings?.values[Self.resourcesSetting]?.objectValue else { return nil }
        func bytes(_ key: String) -> Int64? { fields[key]?.int.map(Int64.init) }
        return BotResourceSettings(poolBytes: bytes("poolBytes"), perBotBytes: bytes("perBotBytes"), diskBytes: bytes("diskBytes"))
    }

    func setResources(_ resources: BotResourceSettings) async throws {
        guard let settings else { throw ClientError.notConnected }
        func bytes(_ value: Int64?) -> JSONValue { value.map { .integer($0) } ?? .null }
        try await settings.set(Self.resourcesSetting, to: .object([
            "poolBytes": bytes(resources.poolBytes), "perBotBytes": bytes(resources.perBotBytes), "diskBytes": bytes(resources.diskBytes),
        ]))
    }

    // MARK: Bot access

    /// Every bot's Woven tools are paused.
    var toolsPaused: Bool { wovenTools["paused"]?.bool ?? false }
    private var deniedBots: [String] { (wovenTools["denied"]?.array ?? []).compactMap(\.string) }
    private var wovenTools: [String: JSONValue] { settings?.values[botsWovenToolsSetting]?.objectValue ?? [:] }

    func mayUseWovenTools(_ botID: String) -> Bool { !deniedBots.contains(botID) }

    func setToolsPaused(_ paused: Bool) async throws {
        try await setWovenTools(paused: paused, denied: deniedBots)
    }

    func setMayUseWovenTools(botID: String, _ allowed: Bool) async throws {
        var denied = deniedBots.filter { $0 != botID }
        if !allowed { denied.append(botID) }
        try await setWovenTools(paused: toolsPaused, denied: denied)
    }

    private func setWovenTools(paused: Bool, denied: [String]) async throws {
        guard let settings else { throw ClientError.notConnected }
        try await settings.set(botsWovenToolsSetting, to: .object(["paused": .bool(paused), "denied": .array(denied.map(JSONValue.string))]))
    }

    // MARK: Bots runtime

    /// Connected to the bots runtime on the home machine's server.
    var isConnected: Bool { state == .ready && server?.isConnected == true }
    /// The home machine is away: the bots and their chats show what the library holds.
    var isReadingSaved: Bool { homeMachineID != nil && state == .unreachable }
    var isAvailable: Bool { homeMachine != nil && state == .ready }

    private(set) var hasLoadedBots = false
    private(set) var bots: [PiBotSummary] = []
    private(set) var groups: [PiBotGroup] = []
    /// Each bot's threads, once loaded.
    private(set) var threadsByBot: [String: [PiBotThread]] = [:]
    private(set) var forum: PiBotForumState?
    private(set) var forumSchedules: [PiBotForumSchedule]?
    private(set) var onboarding: PiBotOnboardingStatus?
    /// What the bots call the user.
    private(set) var userName = ""
    /// A bots update is running.
    private(set) var updating = false
    private(set) var progress: BotsUpdateProgress?
    /// Bots still on an older container image; Update bots moves them.
    private(set) var botsOnOlderImage = 0
    private(set) var loadError: String?
    /// Bumped when profiles, roles or bots change, so settings pages read again.
    private(set) var settingsRevision = 0
    /// Bumped when a bot's container changes.
    private(set) var environmentRevision = 0
    /// Bumped when a bot's memory changes.
    private(set) var memoryRevision = 0
    /// A one-line message the window shows once, then clears.
    var notice: String?
    /// Composer text not sent yet, per open chat or room.
    let drafts = BotDraftStore()

    var layout: PiBotSidebarLayout { PiBotSidebarLayout(bots: bots, groups: groups) }

    func threads(for botID: String) -> [PiBotThread] { PiBotThread.sorted(threadsByBot[botID] ?? []) }

    /// Bot chats and Forum rooms as the library holds them.
    @ObservationIgnored private var savedChats: [SavedBotChat] = []
    /// Bots whose threads have been asked for, so a change reads them again.
    @ObservationIgnored private var loadedThreads: Set<String> = []
    /// Whether the last status was live; a change reopens every open chat.
    @ObservationIgnored private var wasLive: Bool?

    /// Reads the bots again: from the runtime, or from the library while the home machine is away.
    func refresh() async {
        if isConnected { await loadLive() } else if isReadingSaved { await loadSaved() }
    }

    func apply(_ status: BotsStatus, reload: Bool = false) {
        self.status = status
        let live = state == .ready
        let changed = wasLive != live
        wasLive = live
        if changed {
            for chat in chats.values { chat.reopen() }
            for room in rooms.values { room.reopen() }
        }
        if changed || reload { Task { await refresh() } }
    }

    private func receive(_ event: BotsEvent) {
        switch event {
        case .status(let status): apply(status)
        case .message(let value):
            guard let message = try? value.decode(BotsWire.Message.self) else { return }
            receive(message)
        }
    }

    private func receive(_ message: BotsWire.Message) {
        switch message {
        case .botsChanged:
            settingsRevision += 1
            Task { await loadBots() }
        case .groupsChanged: Task { await loadGroups() }
        case .threadsChanged(let botID):
            if loadedThreads.contains(botID) { Task { await loadThreads(botID: botID) } }
        case .memoryChanged: memoryRevision += 1
        case .forumChanged: Task { await loadForum() }
        case .userChanged: Task { await loadUserName() }
        case .environmentChanged: environmentRevision += 1
        case .runtimeUpdate(let botID, let phase, let error):
            // The run's last word stays on screen; a later run replaces it.
            progress = BotsUpdateProgress(botID: botID, phase: phase, error: error)
            if phase == "done" {
                updating = false
                Task { await loadRuntimeStatus(); await loadBots() }
            }
        case .event, .forumPost, .forumThinking: break
        }
    }

    private func loadLive() async {
        async let bots: Void = loadBots()
        async let groups: Void = loadGroups()
        async let forum: Void = loadForum()
        async let user: Void = loadUserName()
        async let onboarding: Void = refreshOnboarding()
        async let runtime: Void = loadRuntimeStatus()
        _ = await (bots, groups, forum, user, onboarding, runtime)
        for botID in loadedThreads { await loadThreads(botID: botID) }
    }

    private func loadBots() async {
        await load { [self] in
            let list = try await call("bots.list", as: BotsWire.BotsList.self)
            guard isConnected else { return }
            bots = list.bots.map(PiBotSummary.init)
            hasLoadedBots = true
        }
    }

    private func loadGroups() async {
        await load { [self] in
            let list = try await call("groups.list", as: BotsWire.GroupsList.self)
            if isConnected { groups = list.groups.map(PiBotGroup.init) }
        }
    }

    private func loadForum() async {
        await load { [self] in
            let state = try await call("forum.get", as: BotsWire.ForumState.self)
            if isConnected { forum = PiBotForumState(state) }
        }
    }

    private func loadUserName() async {
        await load { [self] in
            let user = try await call("user.get", as: BotsWire.UserName.self)
            if isConnected { userName = user.name }
        }
    }

    private func loadRuntimeStatus() async {
        await load { [self] in
            botsOnOlderImage = try await call("runtime.status", as: BotsWire.RuntimeStatus.self).image?.staleBots ?? 0
        }
    }

    /// The bots and their chats as the library holds them.
    private func loadSaved() async {
        guard let library, let home = homeMachineID else { return }
        do {
            let saved = try await library.call(ListSavedBots())
            guard !isConnected else { return }
            savedChats = saved.chats.filter { $0.session.machineID == home }
            bots = saved.bots.filter { $0.homeMachineID == home && !$0.trashed }
                .sorted { ($0.isAdmin ? 0 : 1, $0.createdAt) < ($1.isAdmin ? 0 : 1, $1.createdAt) }
                .map(PiBotSummary.init(saved:))
            groups = []
            threadsByBot = Dictionary(uniqueKeysWithValues: bots.map { bot in
                (bot.id, savedChats.filter { $0.kind == .thread && $0.botID == bot.id }.map(PiBotThread.init(saved:)))
            })
            forum = PiBotForumState(paused: false, bots: [],
                                    threads: savedChats.filter { $0.kind == .forumThread }.map(PiBotForumThread.init(saved:)))
            onboarding = nil
            hasLoadedBots = true
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// A bot's saved conversation: its main channel when `conversationID` is nil.
    func savedChat(botID: String, conversationID: Int?) -> SavedBotChat? {
        savedChats.first { chat in
            chat.botID == botID && (conversationID.map { chat.conversationID == $0 } ?? (chat.kind == .main))
        }
    }

    /// A saved Forum room: the Forum itself when `roomID` is nil.
    func savedForumRoom(roomID: Int?) -> SavedBotChat? {
        savedChats.first { chat in
            roomID.map { chat.kind == .forumThread && chat.conversationID == $0 } ?? (chat.kind == .forum)
        }
    }

    // MARK: Requests

    /// One request of `bots/src/protocol.ts`, to the home machine's server.
    func call(_ type: String, _ fields: [String: JSONValue] = [:]) async throws -> JSONValue {
        guard let server, isConnected else { throw BotsCallError.notConnected }
        var request = fields
        request["type"] = .string(type)
        do {
            return try await server.call(BotsCall(request: .object(request)))
        } catch let error as ProtocolError {
            throw BotsCallError(message: error.message)
        }
    }

    func call<T: Decodable>(_ type: String, _ fields: [String: JSONValue] = [:], as: T.Type) async throws -> T {
        try await call(type, fields).decode(T.self)
    }

    /// A read: its failure is reported where the bots' state shows.
    private func load(_ work: () async throws -> Void) async {
        do {
            try await work()
            loadError = nil
        } catch is CancellationError {
        } catch {
            loadError = error.localizedDescription
        }
    }

    /// A command from the sidebar or a chat: its failure shows once in the window.
    private func attempt(_ work: () async throws -> Void) async {
        do { try await work() } catch { notice = error.localizedDescription }
    }

    // MARK: Sidebar commands

    func createBot(name: String) async -> PiBotSummary? {
        var created: PiBotSummary?
        await attempt { created = PiBotSummary(try await call("bots.create", ["name": .string(name)], as: BotsWire.BotResult.self).bot) }
        await loadBots()
        return created
    }

    func rename(botID: String, name: String) async {
        await attempt { _ = try await call("bots.rename", ["botId": .string(botID), "name": .string(name)]) }
        await loadBots()
    }

    func delete(botID: String) async {
        await attempt { _ = try await call("bots.delete", ["botId": .string(botID)]) }
        await loadBots()
    }

    func createGroup(name: String, adding botID: String? = nil) async {
        await attempt {
            let group = try await call("groups.create", ["name": .string(name)], as: BotsWire.GroupResult.self).group
            if let botID {
                _ = try await call("bots.setGroup", ["botId": .string(botID), "groupId": .string(group.id)])
            }
        }
        await loadGroups()
        await loadBots()
    }

    func renameGroup(id: String, name: String) async {
        await attempt { _ = try await call("groups.rename", ["groupId": .string(id), "name": .string(name)]) }
        await loadGroups()
    }

    func deleteGroup(id: String) async {
        await attempt { _ = try await call("groups.delete", ["groupId": .string(id)]) }
        await loadGroups()
        await loadBots()
    }

    func moveGroup(id: String, by offset: Int) async {
        var ids = groups.sorted { ($0.position, $0.id) < ($1.position, $1.id) }.map(\.id)
        guard let index = ids.firstIndex(of: id), ids.indices.contains(index + offset) else { return }
        ids.swapAt(index, index + offset)
        await attempt { _ = try await call("groups.reorder", ["groupIds": .array(ids.map(JSONValue.string))]) }
        await loadGroups()
    }

    func setGroup(botID: String, groupID: String?) async {
        await attempt { _ = try await call("bots.setGroup", ["botId": .string(botID), "groupId": groupID.map(JSONValue.string) ?? .null]) }
        await loadBots()
    }

    func setPinned(botID: String, conversationID: Int, pinned: Bool) async {
        await attempt {
            _ = try await call("thread.setPinned", ["botId": .string(botID), "conversationId": .integer(Int64(conversationID)),
                                                    "pinned": .bool(pinned)])
        }
        await loadThreads(botID: botID)
    }

    func loadThreads(botID: String) async {
        guard isConnected else { return }
        loadedThreads.insert(botID)
        await load { [self] in
            let list = try await call("threads.list", ["botId": .string(botID)], as: BotsWire.ThreadsList.self)
            if isConnected { threadsByBot[botID] = list.threads.map(PiBotThread.init) }
        }
    }

    // MARK: Forum

    func setForumPaused(_ paused: Bool) async {
        await attempt { forum = PiBotForumState(try await call("forum.setPaused", ["paused": .bool(paused)], as: BotsWire.ForumState.self)) }
    }

    func setForumThreadPinned(roomID: Int, pinned: Bool) async {
        await attempt { _ = try await call("forum.thread.setPinned", ["roomId": .integer(Int64(roomID)), "pinned": .bool(pinned)]) }
        await loadForum()
    }

    func setForumBotActive(botID: String, active: Bool) async {
        await attempt {
            forum = PiBotForumState(try await call("forum.setBotActive", ["botId": .string(botID), "active": .bool(active)],
                                                   as: BotsWire.ForumState.self))
        }
    }

    /// Re-reads the Forum's state, after a thread was started from a post.
    func refreshForum() async { await loadForum() }

    func loadForumSchedules() async {
        guard isConnected else { return }
        await load { [self] in
            forumSchedules = try await call("forum.schedules.list", as: BotsWire.ForumSchedulesList.self).schedules.map(PiBotForumSchedule.init)
        }
    }

    func deleteForumSchedule(id: String) async {
        await attempt {
            forumSchedules = try await call("forum.schedules.delete", ["scheduleId": .string(id)], as: BotsWire.ForumSchedulesList.self)
                .schedules.map(PiBotForumSchedule.init)
        }
    }

    /// Reports whether the schedule was saved, so the form keeps it otherwise.
    func saveForumSchedule(_ draft: PiBotForumScheduleDraft) async -> Bool {
        var saved = false
        await attempt {
            forumSchedules = try await call("forum.schedules.save", ["schedule": draft.wire], as: BotsWire.ForumSchedulesList.self)
                .schedules.map(PiBotForumSchedule.init)
            saved = true
        }
        return saved
    }

    // MARK: You and setup

    /// Reports whether the name was saved.
    func setUserName(_ name: String) async -> Bool {
        var saved = false
        await attempt {
            userName = try await call("user.setName", ["name": .string(name.trimmingCharacters(in: .whitespacesAndNewlines))],
                                      as: BotsWire.UserName.self).name
            saved = true
        }
        return saved
    }

    func refreshOnboarding(onError: (String) -> Void = { _ in }) async {
        guard isConnected else { return }
        do {
            let status = try await call("onboarding.status", as: BotsWire.OnboardingStatus.self)
            onboarding = PiBotOnboardingStatus(mainModel: status.mainModel, mainModelAvailable: status.mainModelAvailable,
                                               signedIn: status.signedIn, needed: status.needed)
        } catch {
            loadError = error.localizedDescription
            onError(error.localizedDescription)
        }
    }

    func setOnboardingMainModel(_ model: String) async throws {
        _ = try await call("onboarding.setMainModel", ["model": .string(model)])
        settingsRevision += 1
        await refreshOnboarding()
    }

    // MARK: Updates

    /// Stops running work, snapshots each bot, moves it to the current image, and rolls back on
    /// failure. Progress arrives as `runtime.update` pushes.
    func updateBots() async {
        guard !updating else { return }
        updating = true
        progress = BotsUpdateProgress(botID: nil, phase: "stopping", error: nil)
        do {
            _ = try await call("runtime.update")
        } catch {
            updating = false
            progress = nil
            notice = error.localizedDescription
        }
    }

    // MARK: Open chats and rooms

    @ObservationIgnored private var chats: [BotConversationKey: BotChatStore] = [:]
    @ObservationIgnored private var rooms: [Int?: ForumRoomStore] = [:]

    /// The open chat for one bot conversation (nil is its main channel), kept while the window lasts.
    func conversation(botID: String, conversationID: Int?) -> BotChatStore {
        let key = BotConversationKey(machineID: homeMachineID ?? "", botID: botID, conversationID: conversationID)
        if let chat = chats[key] { return chat }
        let chat = BotChatStore(key: key, bots: self)
        chats[key] = chat
        return chat
    }

    /// The open Forum room (nil is the Forum itself).
    func forumRoom(roomID: Int?) -> ForumRoomStore {
        if let room = rooms[roomID] { return room }
        let room = ForumRoomStore(key: BotConversationKey(machineID: homeMachineID ?? "", botID: BotTarget.forumBotID,
                                                          conversationID: roomID), bots: self)
        rooms[roomID] = room
        return room
    }
}
