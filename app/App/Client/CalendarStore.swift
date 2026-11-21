import Foundation
import Observation
import WovenProtocol

/// Scheduler entries on every machine, their runs, and the task defaults and options the calendar sheet offers.
/// This Mac's server lists every machine's entries from its library; a change is sent to the server of the
/// machine that runs the entry, which alone writes it. Timers and wake-ups belong to their sessions and are not shown.
@MainActor
@Observable
final class CalendarStore {
    /// Every machine's events and scheduled tasks. Each belongs to the machine whose scheduler runs it.
    private(set) var entries: [CalendarEntry] = []
    /// The last run of each scheduled task, as its machine reports it.
    private(set) var runs: [CalendarRun] = []
    /// The last create, edit or delete that failed.
    var mutationError: String?
    private(set) var isSaving = false

    @ObservationIgnored private weak var server: ServerConnection?
    @ObservationIgnored private weak var workspace: WorkspaceStore?
    @ObservationIgnored private weak var machines: MachinesStore?
    /// The entries as the servers sent them, for what the sheet does not edit.
    @ObservationIgnored private var schedules: [String: ScheduleEntry] = [:]

    init() {}

    func attach(_ server: ServerConnection, workspace: WorkspaceStore, machines: MachinesStore) {
        self.server = server
        self.workspace = workspace
        self.machines = machines
    }

    func clearMutationError() {
        mutationError = nil
    }

    func entry(id: String) -> CalendarEntry? {
        entries.first { $0.id == id }
    }

    /// Lists the entries again, with the state each owner reports for its own.
    func reload() async {
        guard let server, server.isConnected, let listed = try? await server.call(ListSchedules()) else { return }
        var all = listed.filter { $0.kind == .task || $0.kind == .event }
        let here = server.remote?.machine.id
        for machineID in Set(all.map(\.machineID)) where machineID != here {
            guard let owner = try? workspace?.server(for: machineID), owner.isConnected,
                  let theirs = try? await owner.call(ListSchedules()) else { continue }
            let states = Dictionary(theirs.filter { $0.machineID == machineID }.map { ($0.id, $0.state) }, uniquingKeysWith: { $1 })
            for index in all.indices where all[index].machineID == machineID {
                all[index].state = states[all[index].id] ?? nil
            }
        }
        schedules = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        let mapped = all.map(entry)
        if mapped != entries { entries = mapped }
        let lastRuns = all.compactMap(run)
        if lastRuns != runs { runs = lastRuns }
    }

    /// A new task's fields for a runtime. Unset settings run with the agent's default.
    func taskDefaults(runtime: AgentRuntimeKind, title: String = "") -> CalendarTask {
        CalendarTask(prompt: "", configuration: CalendarTaskConfiguration(runtimeKind: runtime, title: title))
    }

    /// The models, thinking levels and permission modes the task's runtime offers on its machine.
    func taskOptions(for task: CalendarTask, machineID: String?) async throws -> SessionSettings {
        guard let workspace else { throw ClientError.notConnected }
        let runtime = task.configuration.runtimeKind
        guard let configuration = try await workspace.server(for: machineID).call(GetRuntimeConfiguration(runtime: runtime.runtime)) else {
            throw RuntimeOptionsUnknown(runtime: runtime)
        }
        func metadata(_ options: [SessionOption]) -> [String: SessionOptionMetadata] {
            Dictionary(options.map { ($0.id, SessionOptionMetadata(name: $0.name, description: $0.detail)) },
                       uniquingKeysWith: { first, _ in first })
        }
        return SessionSettings(
            model: configuration.model, thinking: configuration.thinking, permission: configuration.permission,
            modelOptions: configuration.models.map(\.id), thinkingLevels: configuration.thinkingLevels.map(\.id),
            permissionOptions: configuration.permissionModes.map(\.id),
            modelOptionMetadata: metadata(configuration.models),
            thinkingOptionMetadata: metadata(configuration.thinkingLevels),
            permissionOptionMetadata: metadata(configuration.permissionModes))
    }

    /// Creates or updates an entry on the draft's machine. With `detaching`, that
    /// occurrence of a series becomes its own entry. Returns whether it was saved.
    func save(_ draft: CalendarDraft, entry: CalendarEntry?, detaching occurrence: Int? = nil) async -> Bool {
        let value: CalendarDraft
        do {
            value = try draft.validated()
        } catch {
            mutationError = error.localizedDescription
            return false
        }
        guard let machineID = value.machineID ?? machines?.thisMachine?.id else {
            mutationError = ClientError.notConnected.localizedDescription
            return false
        }
        isSaving = true
        defer { isSaving = false }
        do {
            let existing = entry.flatMap { schedules[$0.id] }
            let schedule = Self.schedule(value, on: machineID, keeping: occurrence == nil ? existing : nil)
            if let occurrence, let entry {
                _ = try await owner(machineID).call(SaveSchedule(draft: schedule))
                _ = try await owner(entry.machineID).call(DeleteSchedule(id: entry.id, occurrence: occurrence))
            } else if let entry, entry.machineID != machineID {
                // An entry belongs to one machine: it moves by being made there and deleted here.
                _ = try await owner(machineID).call(SaveSchedule(draft: schedule))
                _ = try await owner(entry.machineID).call(DeleteSchedule(id: entry.id))
            } else {
                _ = try await owner(machineID).call(SaveSchedule(id: entry?.id, draft: schedule))
            }
            mutationError = nil
        } catch {
            mutationError = error.localizedDescription
            await reload()
            return false
        }
        await reload()
        return true
    }

    /// Deletes an entry, or one occurrence of a series. Returns whether it was deleted.
    func delete(_ entry: CalendarEntry, occurrence: Int?) async -> Bool {
        isSaving = true
        defer { isSaving = false }
        do {
            _ = try await owner(entry.machineID).call(DeleteSchedule(id: entry.id, occurrence: occurrence))
            mutationError = nil
        } catch {
            mutationError = error.localizedDescription
            return false
        }
        await reload()
        return true
    }

    private func owner(_ machineID: String) throws -> ServerConnection {
        guard let workspace else { throw ClientError.notConnected }
        return try workspace.server(for: machineID)
    }

    // MARK: Mapping

    private static func schedule(_ draft: CalendarDraft, on machineID: String, keeping existing: ScheduleEntry?) -> ScheduleDraft {
        let task = draft.task
        let configuration = task?.configuration
        let runtime = configuration?.runtimeKind.runtime
        // A task's session stays while it runs the same runtime on the same machine.
        let keepsSession = existing.map { $0.machineID == machineID && $0.draft.runtime == runtime } ?? false
        return ScheduleDraft(
            machineID: machineID, kind: task == nil ? .event : .task, title: draft.title, details: draft.details,
            prompt: task?.prompt ?? "", sessionID: keepsSession ? existing?.draft.sessionID : nil,
            newSessionEachRun: task?.sessionMode == .new, runtime: runtime, folderID: configuration?.folderID,
            directory: configuration?.workingDirectory, model: configuration?.model, thinking: configuration?.thinking,
            permission: configuration?.permission, startsAt: draft.startsAt, endsAt: draft.endsAt, allDay: draft.allDay,
            timeZone: draft.timeZoneID,
            recurrence: draft.recurrence.map { Recurrence(unit: $0.unit.scheduleUnit, interval: $0.interval) },
            excluded: existing?.draft.excluded ?? [], showsOnCalendar: draft.showsOnCalendar,
            enabled: existing?.draft.enabled ?? true)
    }

    private func author(_ sessionID: String?) -> CalendarAuthor {
        let session = sessionID.flatMap { workspace?.conversation(id: $0) }
        return CalendarAuthor(sessionID: sessionID, runtimeKind: session?.runtimeKind, sessionTitle: session?.title)
    }

    private func task(_ schedule: ScheduleEntry) -> CalendarTask? {
        let draft = schedule.draft
        guard schedule.kind == .task else { return nil }
        let runtime = draft.runtime.flatMap(AgentRuntimeKind.init(runtime:)) ?? .codex
        return CalendarTask(
            prompt: draft.prompt,
            configuration: CalendarTaskConfiguration(runtimeKind: runtime, folderID: draft.folderID, title: draft.title,
                                                     model: draft.model, thinking: draft.thinking, permission: draft.permission,
                                                     workingDirectory: draft.directory),
            sessionMode: draft.newSessionEachRun ? .new : .same)
    }

    private func entry(_ schedule: ScheduleEntry) -> CalendarEntry {
        let draft = schedule.draft
        return CalendarEntry(
            id: schedule.id, machineID: schedule.machineID, title: draft.title, details: draft.details,
            startsAt: draft.startsAt, endsAt: draft.endsAt, allDay: draft.allDay, timeZoneID: draft.timeZone,
            recurrence: draft.recurrence.map { CalendarRecurrence(unit: .init($0.unit), interval: $0.interval) },
            task: task(schedule), showsOnCalendar: schedule.kind == .event || draft.showsOnCalendar,
            excludedOccurrences: Set(draft.excluded), createdBy: author(schedule.createdBy),
            editedBy: schedule.editedAt == nil ? nil : author(schedule.editedBy), editedAt: schedule.editedAt)
    }

    private func run(_ schedule: ScheduleEntry) -> CalendarRun? {
        guard let state = schedule.state, let firedAt = state.lastFiredAt, let task = task(schedule) else { return nil }
        return CalendarRun(
            id: schedule.id + ":" + String(firedAt.timeIntervalSince1970), entryID: schedule.id,
            occurrenceIndex: schedule.draft.occurrenceIndex(onOrBefore: firedAt) ?? 0, scheduledAt: firedAt,
            sessionID: state.lastSessionID ?? schedule.draft.sessionID ?? "", task: task,
            status: state.lastError == nil ? .completed : .failed, error: state.lastError, title: schedule.draft.title)
    }
}

extension CalendarRecurrence.Unit {
    init(_ unit: Recurrence.Unit) {
        switch unit {
        case .minute: self = .minute
        case .hour: self = .hour
        case .day: self = .day
        case .week: self = .week
        case .month: self = .month
        }
    }

    var scheduleUnit: Recurrence.Unit {
        switch self {
        case .minute: .minute
        case .hour: .hour
        case .day: .day
        case .week: .week
        case .month: .month
        }
    }
}
