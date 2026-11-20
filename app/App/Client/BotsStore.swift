import Foundation
import Observation

/// The bots and the Forum, on the bots' home machine: bots, groups, threads, profiles, schedules,
/// onboarding and resources. There is one set of bots, on one machine chosen from the Woven
/// machines; every request goes through that machine's server.
@MainActor
@Observable
final class BotsStore {
    init() {}

    // MARK: Home machine

    /// The machine the bots live on; nil until one is chosen.
    private(set) var homeMachine: Machine?
    /// The bots runtime on the home machine.
    private(set) var state: BotsState = .off
    /// Why the runtime is in its state, when the server says.
    private(set) var message: String?
    /// The home machine's memory and disk, once its server has reported them.
    private(set) var capacity: BotMachineCapacity?
    /// The limits set for bots there; nil means the defaults.
    private(set) var resources: BotResourceSettings?
    /// A bots update or rebuild is running.
    private(set) var updating = false
    private(set) var progress: BotsUpdateProgress?
    /// Bots still on an older container image; Update bots moves them.
    private(set) var botsOnOlderImage = 0
    /// A home change or other host command is on its way.
    private(set) var busy = false
    private(set) var loadError: String?
    /// The server takes host commands (choose the home machine, transfer, turn off).
    private(set) var canChangeHome = false
    /// A one-line message the window shows once, then clears.
    var notice: String?

    var homeMachineID: String? { homeMachine?.id }
    /// "This Mac", or the home machine's name.
    var displayName: String {
        guard let homeMachine else { return "Bots" }
        return homeMachine.isThisMachine ? "This Mac" : homeMachine.name
    }

    // MARK: Bots runtime

    /// Connected to the bots runtime through the home machine's server.
    private(set) var isConnected = false
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
    /// Bumped when profiles, roles or bots change, so settings pages read again.
    private(set) var settingsRevision = 0
    /// Bumped when a bot's container changes.
    private(set) var environmentRevision = 0
    /// Bumped when a bot's memory changes.
    private(set) var memoryRevision = 0
    /// Composer text not sent yet, per open chat or room.
    let drafts = BotDraftStore()

    var isAvailable: Bool { homeMachine != nil && state == .ready }
    var layout: PiBotSidebarLayout { PiBotSidebarLayout(bots: bots, groups: groups) }

    func threads(for botID: String) -> [PiBotThread] { PiBotThread.sorted(threadsByBot[botID] ?? []) }

    // MARK: Woven MCP for bots

    /// Whether bots reach the Woven MCP and with which tools; nil until the server answers.
    private(set) var toolAccess: BotToolAccess?
    /// Every bot's Woven MCP calls are refused until reinstated.
    private(set) var toolsPaused = false
    /// Bots whose Woven MCP access was revoked one by one.
    private(set) var botsWithoutTools: Set<String> = []

    func mayUseWovenTools(_ botID: String) -> Bool { !botsWithoutTools.contains(botID) }

    func setToolsEnabled(_ enabled: Bool) async throws { throw ClientError.notConnected }
    func setToolGroup(_ group: WorkspaceToolGroup, enabled: Bool) async throws { throw ClientError.notConnected }
    func setToolsPaused(_ paused: Bool) async { loadError = ClientError.notConnected.localizedDescription }
    func setMayUseWovenTools(botID: String, _ allowed: Bool) async { loadError = ClientError.notConnected.localizedDescription }

    // MARK: Install on another machine

    /// Online tailnet machines that could become the bots' home; nil until searched.
    private(set) var devices: [BotDiscoveredDevice]?

    func discoverDevices() async throws { throw ClientError.notConnected }
    func installServer(hostName: String, userName: String?) async throws { throw ClientError.notConnected }

    // MARK: Host commands

    /// Reads the home machine's state and the bots again.
    func refresh() async {}
    /// Moves the bots to `machineID`: they stop, their folder is copied there, and they start there.
    func transfer(to machineID: String) async { loadError = ClientError.notConnected.localizedDescription }
    /// Turns the bots off on their home machine; their files and conversations stay.
    func turnOff() async { loadError = ClientError.notConnected.localizedDescription }
    func restart() async { loadError = ClientError.notConnected.localizedDescription }
    /// Stops running work, snapshots each bot, moves it to the current image, and rolls back on failure.
    func updateBots() async { loadError = ClientError.notConnected.localizedDescription }
    func setResources(_ settings: BotResourceSettings) async throws { throw ClientError.notConnected }

    // MARK: Sidebar commands

    func createBot(name: String) async -> PiBotSummary? { reportNotConnected(); return nil }
    func rename(botID: String, name: String) async { reportNotConnected() }
    func delete(botID: String) async { reportNotConnected() }
    func createGroup(name: String, adding botID: String? = nil) async { reportNotConnected() }
    func renameGroup(id: String, name: String) async { reportNotConnected() }
    func deleteGroup(id: String) async { reportNotConnected() }
    func moveGroup(id: String, by offset: Int) async { reportNotConnected() }
    func setGroup(botID: String, groupID: String?) async { reportNotConnected() }
    func setPinned(botID: String, conversationID: Int, pinned: Bool) async { reportNotConnected() }
    func loadThreads(botID: String) async {}

    // MARK: Forum

    func setForumPaused(_ paused: Bool) async { reportNotConnected() }
    func setForumThreadPinned(roomID: Int, pinned: Bool) async { reportNotConnected() }
    func setForumBotActive(botID: String, active: Bool) async { reportNotConnected() }
    func loadForumSchedules() async {}
    func deleteForumSchedule(id: String) async { reportNotConnected() }
    /// Reports whether the schedule was saved, so the form keeps it otherwise.
    func saveForumSchedule(_ draft: PiBotForumScheduleDraft) async -> Bool { reportNotConnected(); return false }

    // MARK: You and setup

    /// Reports whether the name was saved.
    func setUserName(_ name: String) async -> Bool { reportNotConnected(); return false }
    func refreshOnboarding(onError: (String) -> Void = { _ in }) async {}
    func setOnboardingMainModel(_ model: String) async throws { throw ClientError.notConnected }

    // MARK: Open chats and rooms

    @ObservationIgnored private var chats: [BotConversationKey: BotChatStore] = [:]
    @ObservationIgnored private var rooms: [Int?: ForumRoomStore] = [:]

    /// The open chat for one bot conversation (nil is its main channel), kept while the window lasts.
    func conversation(botID: String, conversationID: Int?) -> BotChatStore {
        let key = BotConversationKey(machineID: homeMachineID ?? "", botID: botID, conversationID: conversationID)
        if let chat = chats[key] { return chat }
        let chat = BotChatStore(key: key)
        chats[key] = chat
        return chat
    }

    /// The open Forum room (nil is the Forum itself).
    func forumRoom(roomID: Int?) -> ForumRoomStore {
        if let room = rooms[roomID] { return room }
        let room = ForumRoomStore(key: BotConversationKey(machineID: homeMachineID ?? "", botID: BotTarget.forumBotID,
                                                          conversationID: roomID))
        rooms[roomID] = room
        return room
    }

    private func reportNotConnected() {
        notice = ClientError.notConnected.localizedDescription
    }
}
