import Foundation
import Observation

/// Scheduler entries on every machine, their runs, and the task defaults and options the calendar sheet offers.
@MainActor
@Observable
final class CalendarStore {
    /// Every machine's entries. Each belongs to the machine whose scheduler runs it.
    private(set) var entries: [CalendarEntry] = []
    /// Past and active runs of scheduled tasks, oldest first.
    private(set) var runs: [CalendarRun] = []
    /// The last create, edit or delete that failed.
    var mutationError: String?
    private(set) var isSaving = false

    init() {}

    func clearMutationError() {
        mutationError = nil
    }

    func entry(id: String) -> CalendarEntry? {
        entries.first { $0.id == id }
    }

    /// A new task's fields for a runtime. Unset settings run with the agent's default.
    func taskDefaults(runtime: AgentRuntimeKind, title: String = "") -> CalendarTask {
        CalendarTask(prompt: "", configuration: CalendarTaskConfiguration(runtimeKind: runtime, title: title))
    }

    /// The models, thinking levels and permission modes the task's runtime offers on its machine.
    func taskOptions(for task: CalendarTask, machineID: String?) async throws -> SessionSettings {
        throw ClientError.notConnected
    }

    /// Creates or updates an entry on the draft's machine. With `detaching`, that
    /// occurrence of a series becomes its own entry. Returns whether it was saved.
    func save(_ draft: CalendarDraft, entry: CalendarEntry?, detaching occurrence: Int? = nil) async -> Bool {
        do {
            _ = try draft.validated()
        } catch {
            mutationError = error.localizedDescription
            return false
        }
        mutationError = ClientError.notConnected.localizedDescription
        return false
    }

    /// Deletes an entry, or one occurrence of a series. Returns whether it was deleted.
    func delete(_ entry: CalendarEntry, occurrence: Int?) async -> Bool {
        mutationError = ClientError.notConnected.localizedDescription
        return false
    }
}
