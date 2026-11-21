import Foundation
import Observation
import WovenProtocol

/// Which groups of Woven tools each session may use, the defaults for new chats, and each
/// session's timers and wake-ups. A session's choice is a field of the session, written through
/// this Mac's server; the defaults are a synced setting. Timers are entries of the scheduler on
/// the session's machine: this Mac's server lists every machine's, and a change goes to the
/// server of the machine that runs it.
@MainActor
@Observable
final class AgentToolsStore {
    init() {}

    /// Every session's timers and wake-ups.
    private(set) var timers: [WorkspaceSessionTimer] = []
    /// The last change that failed.
    var error: String?

    /// What each session says about its tools, from the library.
    private var sessions: [String: Session] = [:]
    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var workspace: WorkspaceStore?
    @ObservationIgnored private weak var settingsStore: SettingsStore?
    /// The scheduler entries behind `timers`, for the fields the editor does not show.
    @ObservationIgnored private var schedules: [String: ScheduleEntry] = [:]

    func attach(_ server: ServerConnection, workspace: WorkspaceStore, settings: SettingsStore) {
        self.server = server
        self.workspace = workspace
        settingsStore = settings
    }

    /// Reads the sessions' tool choices and every session's timers and wake-ups again.
    func reload() async {
        guard let server, server.isConnected else { return }
        if let listed = try? await server.call(ListSessions(includeArchived: true)) {
            let byID = Dictionary(listed.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            if byID != sessions { sessions = byID }
        }
        if let listed = try? await server.call(ListSchedules()) {
            let entries = listed.filter { ($0.kind == .timer || $0.kind == .wakeUp) && $0.draft.sessionID != nil }
            schedules = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
            let mapped = entries.compactMap(Self.timer).sorted { ($0.nextFireAt, $0.id) < ($1.nextFireAt, $1.id) }
            if mapped != timers { timers = mapped }
        }
    }

    // MARK: Tool groups

    /// The groups new chats may use.
    var settings: WorkspaceToolSettings {
        guard let names = settingsStore?.values[ToolGroup.defaultsSetting]?.array else { return WorkspaceToolSettings() }
        return WorkspaceToolSettings(enabledByDefault: Self.groups(names))
    }

    /// The tools every known session may use.
    var sessionPolicies: [String: WorkspaceSessionTools] {
        sessions.mapValues(policy)
    }

    /// The tools one session may use: its own choice, else its runtime's defaults for new chats
    /// on its machine or every machine, else the defaults for every new chat. The server decides
    /// the same way.
    func policy(for sessionID: String) -> WorkspaceSessionTools {
        sessions[sessionID].map(policy) ?? WorkspaceSessionTools(enabled: settings.enabledByDefault)
    }

    private func policy(_ session: Session) -> WorkspaceSessionTools {
        if let tools = session.tools { return WorkspaceSessionTools(enabled: tools) }
        let values = settingsStore?.values ?? [:]
        let runtime = session.runtime.rawValue
        let defaults = values["agentDefaults.\(runtime).\(session.machineID)"] ?? values["agentDefaults.\(runtime)"]
        if let names = defaults?["tools"]?.array { return WorkspaceSessionTools(enabled: Self.groups(names)) }
        return WorkspaceSessionTools(enabled: settings.enabledByDefault)
    }

    private static func groups(_ names: [WovenProtocol.JSONValue]) -> Set<ToolGroup> {
        Set(names.compactMap { $0.string.flatMap(ToolGroup.init(rawValue:)) })
    }

    func saveSettingsFromUI(_ value: WorkspaceToolSettings) {
        Task {
            do {
                guard let settingsStore else { throw ClientError.notConnected }
                try await settingsStore.set(ToolGroup.defaultsSetting,
                                            to: .array(value.enabledByDefault.map(\.rawValue).sorted().map(WovenProtocol.JSONValue.string)))
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Allows or refuses one group for a session. Refusing timers pauses the session's active
    /// timers, once the person has confirmed it.
    func setEnabledFromUI(_ group: WorkspaceToolGroup, enabled: Bool, sessionID: String,
                          confirmedPausingTimers: Bool = false) async throws {
        guard let workspace else { throw ClientError.notConnected }
        let active = timers.filter { $0.sessionID == sessionID && !$0.isPaused }
        if group == .timers, !enabled, !active.isEmpty {
            guard confirmedPausingTimers else { throw WorkspaceToolError.timerPauseConfirmation }
            for timer in active { try await setPaused(timer, true) }
        }
        var groups = policy(for: sessionID).enabled
        if enabled { groups.insert(group) } else { groups.remove(group) }
        let updated = try await workspace.server(for: nil).call(UpdateSession(sessionID: sessionID, tools: groups))
        sessions[updated.id] = updated
        if group == .timers, !enabled { await reload() }
    }

    // MARK: Timers

    /// Creates or changes a timer on its session's machine.
    func saveTimer(_ timer: WorkspaceSessionTimer) async throws {
        try timer.validate()
        var draft = schedules[timer.id]?.draft ?? ScheduleDraft(
            machineID: timer.machineID, kind: .timer, title: "Timer", sessionID: timer.sessionID,
            startsAt: timer.nextFireAt, showsOnCalendar: false)
        draft.prompt = timer.instruction
        draft.startsAt = timer.nextFireAt
        if timer.intervalSeconds != Self.seconds(draft.recurrence) {
            draft.recurrence = timer.intervalSeconds.map(Self.recurrence)
        }
        try await save(timer.isNew ? nil : timer.id, draft)
    }

    func pauseTimer(_ timer: WorkspaceSessionTimer, paused: Bool) async {
        do {
            try await setPaused(timer, paused)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
    }

    func removeTimer(_ timer: WorkspaceSessionTimer) async {
        do {
            guard let workspace else { throw ClientError.notConnected }
            _ = try await workspace.server(for: timer.machineID).call(DeleteSchedule(id: timer.id))
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
    }

    private func setPaused(_ timer: WorkspaceSessionTimer, _ paused: Bool) async throws {
        guard var draft = schedules[timer.id]?.draft else { return }
        draft.enabled = !paused
        try await save(timer.id, draft)
    }

    private func save(_ id: String?, _ draft: ScheduleDraft) async throws {
        guard let workspace else { throw ClientError.notConnected }
        _ = try await workspace.server(for: draft.machineID).call(SaveSchedule(id: id, draft: draft))
        await reload()
    }

    private static func timer(_ entry: ScheduleEntry) -> WorkspaceSessionTimer? {
        let draft = entry.draft
        guard let sessionID = draft.sessionID else { return nil }
        let now = Date()
        let next = entry.state?.nextFireAt
            ?? (draft.startsAt >= now ? draft.startsAt : draft.firstOccurrence(after: now) ?? draft.startsAt)
        return WorkspaceSessionTimer(id: entry.id, sessionID: sessionID, machineID: entry.machineID, instruction: draft.prompt,
                                     nextFireAt: next, intervalSeconds: seconds(draft.recurrence), isPaused: !draft.enabled)
    }

    private static func seconds(_ recurrence: Recurrence?) -> TimeInterval? {
        guard let recurrence else { return nil }
        let unit: TimeInterval = switch recurrence.unit {
        case .minute: 60
        case .hour: 3_600
        case .day: 86_400
        case .week: 604_800
        case .month: 2_592_000
        }
        return unit * TimeInterval(recurrence.interval)
    }

    /// The scheduler repeats in whole minutes or larger units.
    private static func recurrence(_ seconds: TimeInterval) -> Recurrence {
        let minutes = max(1, Int((seconds / 60).rounded()))
        for (unit, size) in [(Recurrence.Unit.week, 10_080), (.day, 1_440), (.hour, 60)] where minutes % size == 0 {
            return Recurrence(unit: unit, interval: minutes / size)
        }
        return Recurrence(unit: .minute, interval: minutes)
    }
}
