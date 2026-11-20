import Foundation
import Observation

/// One open chat, fed by the owning machine's server: its finished items, the
/// item in progress, run state, questions and approvals, settings, goal and
/// task progress. Commands send, stop, answer, change settings and page back.
@MainActor
@Observable
final class SessionStore {
    let sessionID: String
    let transcriptState = ConversationTranscriptState()

    /// Messages in order, the item in progress last while it streams.
    private(set) var messages: [WorkspaceMessageRecord] = []
    private(set) var runs: [WorkspaceRunRecord] = []
    private(set) var runActivities: [WorkspaceRunActivityRecord] = []
    private(set) var messagePresentations: [String: MessagePresentation] = [:]
    private(set) var runPresentations: [String: RunPresentation] = [:]
    private(set) var taskProgress: ConversationTaskProgress?
    private(set) var hasOlderMessages = false
    private(set) var isLoadingOlderMessages = false

    /// False while the owning machine cannot be reached: its saved items show and sending is disabled.
    private(set) var isOwnerReachable = false
    /// A turn is running on the owner.
    private(set) var isRunning = false
    /// Questions, approvals and forms the running turn waits on.
    private(set) var interactions: [SessionInteraction] = []
    /// The runtime's settings, once the owner has reported them.
    private(set) var settings: SessionSettings?
    private(set) var isLoadingSettings = false
    private(set) var isUpdatingSettings = false
    private(set) var goal: WorkspaceGoal?
    /// A macOS permission the owning Mac is missing for this session.
    private(set) var macAccessNotice: MacAccessSessionNotice?
    private(set) var error: String?

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    var hasUserMessage: Bool { messages.contains { $0.role == .user } }

    func setError(_ error: String?) {
        self.error = error
    }

    // MARK: Commands

    /// Subscribes to the owner's live view until the task is cancelled.
    func follow() async {}

    /// Reads the finished items again.
    func refresh() async {}

    /// Pages in older messages. Returns whether any arrived.
    @discardableResult
    func loadOlderMessages() async -> Bool { false }

    func send(_ input: AgentMessageInput) async throws {
        throw ClientError.notConnected
    }

    func stop() async {
        error = ClientError.notConnected.localizedDescription
    }

    func answer(_ interactionID: String, with response: SessionInteractionResponse) async {
        error = ClientError.notConnected.localizedDescription
    }

    func updateSettings(_ change: SessionSettingsChange) async {
        error = ClientError.notConnected.localizedDescription
    }

    func refreshSettings() async {}

    func updateGoal(_ mutation: WorkspaceGoalMutation) async throws {
        throw ClientError.notConnected
    }

    /// Moves a chat with no messages yet to another folder of its machine.
    func chooseFolder(_ folderID: String?) async throws {
        throw ClientError.notConnected
    }

    /// One activity's complete record, when the transcript's copy omits its details.
    func activityDetails(runID: String, activityID: String) async throws -> AgentRunActivity? {
        throw ClientError.notConnected
    }

    func subagentHistory(_ request: SubagentArchiveRequest) async throws -> SubagentArchivePage {
        throw ClientError.notConnected
    }
}
