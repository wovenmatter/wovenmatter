import Foundation
import Observation

/// Woven tool settings, session timers, session relationships and delivery receipts, and the Executor app.
@MainActor
@Observable
final class AgentToolsStore {
    init() {}

    private(set) var settings = WorkspaceToolSettings()
    private(set) var sessionPolicies: [String: WorkspaceSessionTools] = [:]
    private(set) var relationships: [String: WorkspaceSessionRelationship] = [:]
    /// Deliveries to and from each observed session, newest first.
    private(set) var receipts: [String: [WorkspaceSessionDelivery]] = [:]
    private(set) var hasOlderReceipts: Set<String> = []
    /// Sessions asking to read and coordinate another while conversation history is off.
    private(set) var pendingSessionAccess: [SessionAccessRequest] = []
    private(set) var executorDashboardURL: URL?
    private(set) var executorBusy = false
    /// The last settings change that failed.
    var error: String?

    /// The tools one session may use.
    func policy(for sessionID: String) -> WorkspaceSessionTools {
        sessionPolicies[sessionID] ?? WorkspaceSessionTools(enabled: settings.enabledByDefault)
    }

    /// Follow one session's receipts while a view shows it; nil stops following for `token`.
    func observeSessionFromUI(_ sessionID: String?, token: UUID) {}

    func loadOlderReceipts(sessionID: String) async {}

    func saveSettingsFromUI(_ value: WorkspaceToolSettings) {
        error = ClientError.notConnected.localizedDescription
    }

    func setEnabledFromUI(_ group: WorkspaceToolGroup, enabled: Bool, sessionID: String,
                          confirmedPausingTimers: Bool = false) async throws {
        throw ClientError.notConnected
    }

    func controlExecutor(_ control: ExecutorControl) async throws {
        throw ClientError.notConnected
    }

    func endCoordination(sessionID: String) async {
        error = ClientError.notConnected.localizedDescription
    }

    func setNotifications(sessionID: String, enabled: Bool) async {
        error = ClientError.notConnected.localizedDescription
    }

    func saveTimer(_ timer: WorkspaceSessionTimer) async throws {
        throw ClientError.notConnected
    }

    func resolveSessionToolAccess(id: String, allowed: Bool) async {
        pendingSessionAccess.removeAll { $0.id == id }
    }

    // MARK: Used by bots

    /// Every Woven timer, as the server reports them.
    private(set) var timers: [WorkspaceSessionTimer] = []

    /// A bot's own timers on the bots' home machine: active ones soonest first, then paused ones.
    func timers(forBot botID: String, on machineID: String) -> [WorkspaceSessionTimer] {
        timers.filter { $0.botID == botID && $0.machineID == machineID }.sorted {
            ($0.isPaused ? 1 : 0, $0.nextFireAt, $0.id) < ($1.isPaused ? 1 : 0, $1.nextFireAt, $1.id)
        }
    }

    func pauseTimer(_ timer: WorkspaceSessionTimer, paused: Bool) async {}

    func removeTimer(_ timer: WorkspaceSessionTimer) async {}
}

/// A Woven timer: an instruction that reaches a session, or a bot, when it fires.
struct WorkspaceSessionTimer: Identifiable, Equatable, Sendable {
    let id: String
    /// The session it reaches; nil for a bot's timer.
    var sessionID: String?
    /// The bot it reaches, on `machineID`, for a bot's timer.
    var botID: String?
    var machineID: String?
    var instruction: String
    var nextFireAt: Date
    var intervalSeconds: TimeInterval?
    var isPaused: Bool
}
