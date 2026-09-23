// Isolated, provider-free host for the production calendar views. Its database
// lives in a temporary directory; it never opens the user's Woven Matter store.
import SwiftUI
import Observation
import WovenMatterCore
import WovenMatterClient
import WovenMatterDashboardStore

struct RemoteHarnessChatTarget: Equatable, Identifiable {
    let configuration: RemoteWorkspaceConfiguration
    let harness: RemoteHarnessStatus
    var id: String { configuration.id.uuidString + harness.id.rawValue }
}
struct CalendarFixtureWorkspaces {
    let workspaces = [RemoteWorkspaceConfiguration(name: "Remote workspace", workspaceID: "fixture", hostName: "fixture.invalid")]
    func configuration(id: UUID) -> RemoteWorkspaceConfiguration? { workspaces.first { $0.id == id } }
}
func dashboardParsedDate(_ value: String) -> Date? {
    (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
        ?? (try? Date.ISO8601FormatStyle().parse(value))
}

@MainActor @Observable final class ApplicationModel {
    let database: WorkspaceDatabase
    let remoteWorkspaces = CalendarFixtureWorkspaces()
    var workspaceOverview: WorkspaceSnapshot?
    var calendarItems: [WorkspaceCalendarItemRecord] = []
    var calendarRuns: [WorkspaceCalendarRun] = []
    var calendarMutationError: String?
    var remoteCalendarGatewayErrors: [UUID: String] = [:]
    var isCreatingCalendarItem = false
    init() {
        let root = FileManager.default.temporaryDirectory.appending(path: "wm-calendar-ui-" + UUID().uuidString)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        database = try! WorkspaceDatabase(url: root.appending(path: "workspace.sqlite"))
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: Date())
        let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        _ = try! database.createFolder(name: "Product")
        _ = try! database.saveCalendarEvent(draft: .init(title: "Project review", details: "Discuss the next milestone.", startsAt: start,
            endsAt: start.addingTimeInterval(3600)), creating: true)
        var scheduled = calendarTaskDefaults(runtime: .codex, workspaceID: nil, title: "Daily project summary")
        scheduled.prompt = "Summarize the project changes and identify the next useful task."
        let id = try! database.saveCalendarEvent(draft: .init(title: "Daily project summary", startsAt: start.addingTimeInterval(7200),
            endsAt: start.addingTimeInterval(9000), recurrence: .init(unit: .day), task: scheduled), creating: true)
        _ = try! database.saveCalendarEvent(draft: .init(title: "Planning day", startsAt: day, allDay: true), creating: true)
        if let run = try! database.dueCalendarRuns(now: start.addingTimeInterval(7200)).first(where: { $0.eventID == id }) {
            _ = try! database.createLocalACPSession(runtimeKind: .codex, title: "Summary", ownerDeviceID: UUID(), requestedConversationID: UUID(uuidString: run.sessionID))
            _ = try! database.prepareCalendarDelivery(runID: run.id, now: start.addingTimeInterval(7200))
            _ = try! database.claimToolDelivery(id: run.id)
            try! database.setToolDeliveryStatus(id: run.id, status: "accepted")
            try! database.settleCalendarRuns()
            let event = try! database.calendarItems().first { $0.id == id }!
            var changed = WorkspaceCalendarDraft(event)
            changed.title = "Daily release review"
            changed.startsAt = start.addingTimeInterval(10800)
            changed.endsAt = start.addingTimeInterval(12600)
            changed.task?.prompt = "Review the release checklist and report any blockers."
            try! database.saveCalendarEvent(id: id, draft: changed, creating: false, now: start.addingTimeInterval(10801))
        }
        _ = try! database.saveCalendarEvent(draft: .init(title: "Weekly planning", startsAt: start.addingTimeInterval(18000),
            endsAt: start.addingTimeInterval(21600), recurrence: .init(unit: .week)), creating: true)
        _ = try! database.saveCalendarEvent(draft: .init(title: "One-time project summary", startsAt: start.addingTimeInterval(21600),
            endsAt: start.addingTimeInterval(23400), task: scheduled), creating: true)
        refresh()
    }
    func refresh() {
        workspaceOverview = try! database.workspaceOverview()
        calendarItems = try! database.calendarItems()
        calendarRuns = try! database.calendarRuns()
    }
    func clearCalendarMutationError() { calendarMutationError = nil }
    func calendarTaskDefaults(runtime: AgentRuntimeKind, workspaceID: UUID?, title: String = "") -> WorkspaceCalendarTask {
        .init(prompt: "", configuration: .init(runtimeKind: runtime, workspaceID: workspaceID, title: title,
            model: "fixture-model", thinking: "high", permission: "read-only", nativeWorkingDirectory: "/tmp/project"))
    }
    func calendarTaskMetadata(_ task: WorkspaceCalendarTask) async throws -> LocalACPSessionMetadata {
        .init(sessionKey: "fixture", model: task.configuration.model, thinking: task.configuration.thinking,
            modelOptions: ["fixture-model", "fixture-fast"], thinkingLevels: ["low", "medium", "high"],
            permission: task.configuration.permission, permissionOptions: ["read-only", "workspace-write", "full-access"])
    }
    func saveCalendarEvent(_ draft: WorkspaceCalendarDraft, event: WorkspaceCalendarItemRecord? = nil, detaching occurrence: Int? = nil) async -> Bool {
        do {
            try database.saveCalendarEvent(id: event?.id ?? UUID().uuidString.lowercased(), draft: draft, creating: event == nil,
                expectedRevision: event?.calendar.revision, detaching: occurrence)
            refresh(); return true
        } catch { calendarMutationError = error.localizedDescription; return false }
    }
    func deleteCalendarEvent(_ event: WorkspaceCalendarItemRecord, occurrence: Int? = nil) async -> Bool {
        do {
            try database.deleteCalendarEvent(id: event.id, occurrence: occurrence, expectedRevision: event.calendar.revision)
            refresh(); return true
        } catch { calendarMutationError = error.localizedDescription; return false }
    }
}

@main struct CalendarUIFixture: App {
    @State private var model = ApplicationModel()
    @State private var openedSession: String?
    var body: some Scene {
        WindowGroup("Calendar Preview") {
            DashboardCalendarSurface(model: model, onOpenSession: { openedSession = $0 })
                .environment(\.dashboardTheme, CommandLine.arguments.contains("--cognac") ? .cognac : .green)
                .frame(maxWidth: CommandLine.arguments.contains("--narrow") ? 600 : nil)
                .frame(minWidth: 600, minHeight: 650)
                .alert("Session opened", isPresented: Binding(get: { openedSession != nil }, set: { if !$0 { openedSession = nil } })) {
                    Button("OK") { openedSession = nil }
                } message: { Text(openedSession ?? "") }
        }.defaultSize(width: 960, height: 920)
    }
}
