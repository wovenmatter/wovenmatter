import SwiftUI
import WovenMatterCore

struct DashboardCalendarEventSheet: View {
    @Environment(\.dashboardTheme) private var theme
    private var colors = DashboardCalendarColors()
    enum EditScope: String, CaseIterable { case series, detach }
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ApplicationModel
    @State private var selection: DashboardCalendarSelection
    let onOpenSession: (String) -> Void
    @State private var draft: WorkspaceCalendarDraft
    @State private var editing: Bool
    @State private var scope: EditScope = .series
    @State private var showsDelete = false

    init(model: ApplicationModel, selection: DashboardCalendarSelection, onOpenSession: @escaping (String) -> Void) {
        self.model = model; self.onOpenSession = onOpenSession
        _selection = State(initialValue: selection)
        _draft = State(initialValue: selection.draft)
        _editing = State(initialValue: selection.occurrence == nil)
    }
    private var event: WorkspaceCalendarItemRecord? { selection.occurrence?.event }
    private var isPastRun: Bool { selection.occurrence?.recordedRun != nil }
    private var isSeries: Bool { event?.calendar.recurrence != nil }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
        return value
    }
    private var run: WorkspaceCalendarRun? {
        if let recorded = selection.occurrence?.recordedRun { return recorded }
        guard let event else { return nil }
        let runs = model.calendarRuns.filter { $0.eventID == event.id && $0.status != "cancelled" }
        return runs.last { $0.scheduledAt == selection.occurrence?.startsAt } ?? (isSeries ? nil : runs.last)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing ? (event == nil ? "Add event" : "Edit event") : draft.title)
                    .font(.system(size: 20, weight: .semibold)).lineLimit(2)
                Spacer()
                if !editing { Button("Done") { dismiss() }.buttonStyle(DashboardQuietButtonStyle()).keyboardShortcut(.cancelAction) }
            }.padding(24)
            theme.palette.border.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if editing { editor } else { information }
                    if let event { attribution(event) }
                    if let error = model.calendarMutationError {
                        Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24)
            }.scrollIndicators(.never)
            theme.palette.border.frame(height: 1)
            footer.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 560).frame(minHeight: 400, maxHeight: 760)
        .background(DashboardPalette.background)
        .foregroundStyle(DashboardPalette.foreground)
        .confirmationDialog("Delete this event?", isPresented: $showsDelete) {
            if isSeries, let occurrence = selection.occurrence {
                Button("Delete this occurrence", role: .destructive) { remove(occurrence.index) }
                Button("Delete entire series", role: .destructive) { remove(nil) }
            } else { Button("Delete event", role: .destructive) { remove(nil) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Sessions that already ran will remain in your workspace.") }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isSeries {
                DashboardCalendarField("Apply changes to") {
                    DashboardSegmentedSelector(options: EditScope.allCases, selection: $scope) {
                        $0 == .series ? "Entire series" : "Detach this occurrence"
                    }
                }
                .onChange(of: scope) { _, scope in
                    if scope == .detach, let occurrence = selection.occurrence {
                        draft.startsAt = occurrence.startsAt; draft.endsAt = occurrence.endsAt; draft.recurrence = nil
                    } else if let event {
                        draft.startsAt = event.startDate ?? draft.startsAt; draft.endsAt = event.endDate
                        draft.recurrence = event.calendar.recurrence
                    }
                }
            }
            DashboardCalendarField("Title") {
                TextField("Event title", text: $draft.title)
                    .modifier(DashboardCalendarInputStyle())
            }
            DashboardCalendarField("Type") {
                DashboardSegmentedSelector(options: [false, true], selection: Binding(get: { draft.task != nil }, set: { enabled in
                    draft.task = enabled ? model.calendarTaskDefaults(runtime: .codex, workspaceID: nil, title: draft.title) : nil
                    if enabled { draft.allDay = false }
                })) { $0 ? "Scheduled task" : "Event" }
            }
            if draft.task == nil {
                Toggle("All-day event", isOn: $draft.allDay).toggleStyle(DashboardSwitchToggleStyle())
                    .onChange(of: draft.allDay) { _, allDay in
                        if allDay {
                            draft.startsAt = calendar.startOfDay(for: draft.startsAt)
                            draft.endsAt = calendar.date(byAdding: .day, value: 1, to: draft.startsAt)
                        } else { draft.endsAt = draft.startsAt.addingTimeInterval(3_600) }
                    }
            }
            HStack(alignment: .top, spacing: 16) {
                DashboardCalendarField("Starts") {
                    DatePicker("Starts", selection: $draft.startsAt, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                        .frame(minHeight: 36)
                }
                DashboardCalendarField("Ends") {
                    DatePicker("Ends", selection: endDate, in: draft.startsAt..., displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                        .frame(minHeight: 36)
                }
            }
            DashboardCalendarField("Time zone") {
                DashboardCalendarMenuPicker(title: "Time zone", selection: Binding(get: { draft.timeZoneID }, set: { draft = draft.changingTimeZone(to: $0) }),
                    options: Array(Set(TimeZone.knownTimeZoneIdentifiers + [draft.timeZoneID])).sorted()) {
                    $0.replacingOccurrences(of: "_", with: " ")
                }
            }
            if !isSeries || scope == .series {
                Toggle("Repeat", isOn: Binding(get: { draft.recurrence != nil }, set: { draft.recurrence = $0 ? .init(unit: .week) : nil }))
                    .toggleStyle(DashboardSwitchToggleStyle())
                if draft.recurrence != nil {
                    HStack {
                        Text("Every")
                        TextField("Interval", value: Binding(get: { draft.recurrence?.interval ?? 1 }, set: { draft.recurrence?.interval = $0 }), format: .number)
                            .modifier(DashboardCalendarInputStyle()).frame(width: 64)
                        DashboardCalendarMenuPicker(title: "Repeat unit", selection: Binding(get: { draft.recurrence?.unit ?? .week }, set: { draft.recurrence?.unit = $0 }),
                            options: WorkspaceCalendarRecurrence.Unit.allCases, label: { $0.title })
                    }
                }
            }
            DashboardCalendarField("Description") {
                TextField("Optional description", text: $draft.details, axis: .vertical)
                    .lineLimit(3...6).scrollIndicators(.never)
                    .modifier(DashboardCalendarInputStyle())
            }
            if draft.task != nil {
                theme.palette.border.frame(height: 1)
                DashboardCalendarTaskFields(model: model, task: Binding(get: { draft.task ?? model.calendarTaskDefaults(runtime: .codex, workspaceID: nil) }, set: { draft.task = $0 }), recurring: draft.recurrence != nil)
            }
        }
        .font(.system(size: 13))
        .environment(\.timeZone, calendar.timeZone)
        .onChange(of: draft.startsAt) { _, start in
            if draft.endsAt.map({ $0 <= start }) ?? true {
                draft.endsAt = calendar.date(byAdding: draft.allDay ? .day : .hour, value: 1, to: start)
            }
        }
    }

    private var endDate: Binding<Date> {
        Binding(get: {
            let end = draft.endsAt ?? draft.startsAt.addingTimeInterval(3_600)
            return draft.allDay ? calendar.date(byAdding: .day, value: -1, to: end) ?? end : end
        }, set: { draft.endsAt = draft.allDay ? calendar.date(byAdding: .day, value: 1, to: $0) : $0 })
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 16) {
            if isPastRun {
                Text("This run used an earlier schedule. View the event to change its current schedule.")
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            LabeledContent("Type", value: isPastRun ? "Past run" : draft.task == nil ? "Event" : "Scheduled task")
            LabeledContent("Starts", value: dateLabel(draft.startsAt))
            if let end = draft.endsAt { LabeledContent("Ends", value: dateLabel(draft.allDay ? calendar.date(byAdding: .day, value: -1, to: end) ?? end : end)) }
            LabeledContent("Time zone", value: draft.timeZoneID.replacingOccurrences(of: "_", with: " "))
            if let recurrence = draft.recurrence {
                LabeledContent("Repeats", value: recurrence.label).foregroundStyle(colors.color(for: DashboardCalendarEntryStyle(draft)))
            }
            if !draft.details.isEmpty { Text(draft.details).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let task = draft.task {
                theme.palette.border.frame(height: 1)
                LabeledContent("Agent", value: task.configuration.runtimeKind.displayName)
                LabeledContent("Model", value: task.configuration.model ?? "Agent default")
                LabeledContent("Thinking level", value: task.configuration.thinking ?? "Agent default")
                LabeledContent("Access", value: task.configuration.permission ?? "Agent default")
                LabeledContent("Tools", value: WorkspaceToolGroup.allCases.filter { task.configuration.tools.enabled.contains($0) }.map(\.title).joined(separator: ", "))
                LabeledContent("Work location", value: task.configuration.workspaceID.map { model.remoteWorkspaces.configuration(id: $0)?.name ?? "Unavailable workspace" } ?? "Local workspace")
                LabeledContent("Session folder", value: task.configuration.folderID.map { id in model.workspaceOverview?.folders.first { $0.id == id }?.name ?? "Unavailable folder" } ?? "All Workspace")
                if let directory = task.configuration.nativeWorkingDirectory { LabeledContent("Directory", value: directory).textSelection(.enabled) }
                if draft.recurrence != nil { LabeledContent("Session", value: task.sessionMode.title) }
                Text("Prompt").fontWeight(.medium)
                Text(task.prompt).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let run {
                theme.palette.border.frame(height: 1)
                LabeledContent("Status", value: run.statusLabel)
                if let error = run.error { Text(error).foregroundStyle(DashboardPalette.danger).fixedSize(horizontal: false, vertical: true) }
                Button("Open session") { dismiss(); onOpenSession(run.sessionID) }
                    .buttonStyle(DashboardPrimaryButtonStyle())
                    .disabled(model.workspaceOverview?.conversations.contains { $0.id == run.sessionID } != true)
            }
        }
        .font(.system(size: 13))
        .labeledContentStyle(DashboardCalendarDetailStyle())
    }

    private func attribution(_ event: WorkspaceCalendarItemRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            theme.palette.border.frame(height: 1).padding(.bottom, 5)
            Text("Created by \(event.calendar.createdBy.label)")
            if let author = event.calendar.editedBy {
                Text("Edited \(dashboardParsedDate(event.updatedAt)?.formatted(date: .abbreviated, time: .shortened) ?? event.updatedAt) by \(author.label)")
            }
        }.font(.system(size: 11.5)).foregroundStyle(DashboardPalette.mutedForeground)
    }

    private var footer: some View {
        HStack {
            if event != nil && !editing {
                if !isPastRun { Button("Delete", role: .destructive) { showsDelete = true }.buttonStyle(DashboardQuietButtonStyle()) }
                Button("Copy event") { DashboardCalendarClipboard.copy(draft) }
                    .buttonStyle(DashboardQuietButtonStyle()).keyboardShortcut("c", modifiers: .command)
            }
            Spacer()
            if editing {
                Button("Cancel") {
                    model.clearCalendarMutationError()
                    if event == nil { dismiss() } else { editing = false; draft = selection.draft }
                }.buttonStyle(DashboardQuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(model.isCreatingCalendarItem ? "Saving…" : "Save") {
                    Task {
                        if await model.saveCalendarEvent(draft, event: event, detaching: isSeries && scope == .detach ? selection.occurrence?.index : nil) { dismiss() }
                    }
                }.buttonStyle(DashboardPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(model.isCreatingCalendarItem || (try? draft.validated()) == nil)
            } else if isPastRun {
                Button("View event") { viewCurrentEvent() }.buttonStyle(DashboardPrimaryButtonStyle())
            } else {
                Button("Edit") {
                    draft = event.map(WorkspaceCalendarDraft.init) ?? selection.draft
                    scope = .series; editing = true; model.clearCalendarMutationError()
                }.buttonStyle(DashboardPrimaryButtonStyle())
            }
        }
    }
    private func viewCurrentEvent() {
        guard let eventID = event?.id, let event = model.calendarItems.first(where: { $0.id == eventID }),
              let start = event.startDate else { return }
        let index = event.calendar.recurrence == nil ? 0 : selection.occurrence?.index ?? 0
        let current = WorkspaceCalendarSchedule.occurrence(event, index: index)
            ?? WorkspaceCalendarSchedule.next(event, after: Date()).flatMap { date in
                WorkspaceCalendarSchedule.index(onOrBefore: date, start: start,
                    recurrence: event.calendar.recurrence, timeZoneID: event.calendar.timeZoneID)
                    .flatMap { WorkspaceCalendarSchedule.occurrence(event, index: $0) }
            }
        guard let current else { return }
        selection = .init(draft: current.draft, occurrence: current)
        draft = current.draft
        model.clearCalendarMutationError()
    }

    private func dateLabel(_ date: Date) -> String {
        let format = DateFormatter()
        format.timeZone = calendar.timeZone
        format.dateStyle = .medium
        format.timeStyle = draft.allDay ? .none : .short
        return format.string(from: date)
    }
    private func remove(_ occurrence: Int?) {
        guard let event else { return }
        Task { if await model.deleteCalendarEvent(event, occurrence: occurrence) { dismiss() } }
    }
}
