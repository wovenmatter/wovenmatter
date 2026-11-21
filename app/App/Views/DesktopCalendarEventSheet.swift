import SwiftUI

struct DesktopCalendarEventSheet: View {
    @Environment(\.wovenTheme) private var theme
    private var colors = CalendarColors()
    enum EditScope: String, CaseIterable { case series, detach }
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ApplicationModel
    @State private var selection: CalendarSelection
    let onOpenSession: (String) -> Void
    let tasksOnly: Bool
    @State private var draft: CalendarDraft
    @State private var editing: Bool
    @State private var scope: EditScope = .series
    @State private var showsDelete = false

    init(model: ApplicationModel, selection: CalendarSelection, onOpenSession: @escaping (String) -> Void, tasksOnly: Bool = false) {
        self.model = model; self.onOpenSession = onOpenSession; self.tasksOnly = tasksOnly
        _selection = State(initialValue: selection)
        _draft = State(initialValue: selection.draft)
        _editing = State(initialValue: selection.occurrence == nil)
    }
    private var event: CalendarEntry? { selection.occurrence?.entry }
    private var isPastRun: Bool { selection.occurrence?.recordedRun != nil }
    private var isSeries: Bool { event?.recurrence != nil }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: draft.timeZoneID) ?? .current
        return value
    }
    private var run: CalendarRun? {
        if let recorded = selection.occurrence?.recordedRun { return recorded }
        guard let event else { return nil }
        let runs = model.calendar.runs.filter { $0.entryID == event.id && $0.status != .cancelled }
        return runs.last { $0.scheduledAt == selection.occurrence?.startsAt } ?? (isSeries ? nil : runs.last)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editing ? (event == nil ? (draft.task != nil ? "Add task" : "Add event") : (draft.task != nil ? "Edit task" : "Edit event")) : draft.title)
                    .font(.system(size: 20, weight: .semibold)).lineLimit(2)
                Spacer()
                if !editing { Button("Done") { dismiss() }.buttonStyle(WovenQuietButtonStyle()).keyboardShortcut(.cancelAction) }
            }.padding(24)
            theme.palette.border.frame(height: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if editing { editor } else { information }
                    if let event { attribution(event) }
                    if let error = model.calendar.mutationError {
                        Text(error).font(.system(size: 12)).foregroundStyle(WovenPalette.danger).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(24)
            }.scrollIndicators(.never)
            theme.palette.border.frame(height: 1)
            footer.padding(.horizontal, 24).padding(.vertical, 16)
        }
        .frame(width: 560).frame(minHeight: 400, maxHeight: 760)
        .background(WovenPalette.background)
        .foregroundStyle(WovenPalette.foreground)
        .confirmationDialog("Delete this event?", isPresented: $showsDelete) {
            if isSeries, let occurrence = selection.occurrence {
                Button("Delete this occurrence", role: .destructive) { remove(occurrence.index) }
                Button("Delete entire series", role: .destructive) { remove(nil) }
            } else { Button("Delete event", role: .destructive) { remove(nil) } }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Sessions that already ran will remain in your library.") }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 18) {
            if isSeries {
                CalendarField("Apply changes to") {
                    WovenSegmentedSelector(options: EditScope.allCases, selection: $scope) {
                        $0 == .series ? "Entire series" : "Detach this occurrence"
                    }
                }
                .onChange(of: scope) { _, scope in
                    if scope == .detach, let occurrence = selection.occurrence {
                        draft.startsAt = occurrence.startsAt; draft.endsAt = occurrence.endsAt; draft.recurrence = nil
                    } else if let event {
                        draft.startsAt = event.startsAt; draft.endsAt = event.endsAt
                        draft.recurrence = event.recurrence
                    }
                }
            }
            CalendarField("Title") {
                TextField(draft.task != nil ? "Task title" : "Event title", text: $draft.title)
                    .modifier(CalendarInputStyle())
            }
            if !tasksOnly {
                CalendarField("Type") {
                    WovenSegmentedSelector(options: [false, true], selection: Binding(get: { draft.task != nil }, set: { enabled in
                        draft.task = enabled ? model.calendar.taskDefaults(runtime: .codex, title: draft.title) : nil
                        if enabled { draft.allDay = false }
                    })) { $0 ? "Scheduled task" : "Event" }
                }
            }
            if draft.task != nil {
                Toggle("Show on calendar", isOn: $draft.showsOnCalendar)
                    .toggleStyle(CompactSwitchToggleStyle())
            }
            if draft.task == nil {
                Toggle("All-day event", isOn: $draft.allDay).toggleStyle(CompactSwitchToggleStyle())
                    .onChange(of: draft.allDay) { _, allDay in
                        if allDay {
                            draft.startsAt = calendar.startOfDay(for: draft.startsAt)
                            draft.endsAt = calendar.date(byAdding: .day, value: 1, to: draft.startsAt)
                        } else { draft.endsAt = draft.startsAt.addingTimeInterval(3_600) }
                    }
            }
            HStack(alignment: .top, spacing: 16) {
                CalendarField("Starts") {
                    DatePicker("Starts", selection: $draft.startsAt, displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                        .frame(minHeight: 36)
                }
                CalendarField("Ends") {
                    DatePicker("Ends", selection: endDate, in: draft.startsAt..., displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute])
                        .labelsHidden().datePickerStyle(.compact)
                        .frame(minHeight: 36)
                }
            }
            CalendarField("Time zone") {
                CalendarMenuPicker(title: "Time zone", selection: Binding(get: { draft.timeZoneID }, set: { draft = draft.changingTimeZone(to: $0) }),
                    options: Array(Set(TimeZone.knownTimeZoneIdentifiers + [draft.timeZoneID])).sorted()) {
                    $0.replacingOccurrences(of: "_", with: " ")
                }
            }
            if !isSeries || scope == .series {
                Toggle("Repeat", isOn: Binding(get: { draft.recurrence != nil }, set: { draft.recurrence = $0 ? .init(unit: .week) : nil }))
                    .toggleStyle(CompactSwitchToggleStyle())
                if draft.recurrence != nil {
                    HStack {
                        Text("Every")
                        TextField("Interval", value: Binding(get: { draft.recurrence?.interval ?? 1 }, set: { draft.recurrence?.interval = $0 }), format: .number)
                            .modifier(CalendarInputStyle()).frame(width: 64)
                        CalendarMenuPicker(title: "Repeat unit", selection: Binding(get: { draft.recurrence?.unit ?? .week }, set: { draft.recurrence?.unit = $0 }),
                            options: CalendarRecurrence.Unit.calendarCases, label: { $0.title })
                    }
                }
            }
            CalendarField("Description") {
                TextField("Optional description", text: $draft.details, axis: .vertical)
                    .lineLimit(3...6).scrollIndicators(.never)
                    .modifier(CalendarInputStyle())
            }
            if draft.task != nil {
                theme.palette.border.frame(height: 1)
                CalendarTaskFields(model: model, task: Binding(get: { draft.task ?? model.calendar.taskDefaults(runtime: .codex) }, set: { draft.task = $0 }), machineID: $draft.machineID, recurring: draft.recurrence != nil)
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
                    .foregroundStyle(WovenPalette.mutedForeground)
            }
            LabeledContent("Type", value: isPastRun ? "Past run" : draft.task == nil ? "Event" : "Scheduled task")
            LabeledContent("Starts", value: dateLabel(draft.startsAt))
            if let end = draft.endsAt { LabeledContent("Ends", value: dateLabel(draft.allDay ? calendar.date(byAdding: .day, value: -1, to: end) ?? end : end)) }
            LabeledContent("Time zone", value: draft.timeZoneID.replacingOccurrences(of: "_", with: " "))
            if let recurrence = draft.recurrence {
                LabeledContent("Repeats", value: recurrence.label).foregroundStyle(colors.color(for: CalendarEntryStyle(draft)))
            }
            if !draft.details.isEmpty { Text(draft.details).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
            if let task = draft.task {
                theme.palette.border.frame(height: 1)
                LabeledContent("Agent", value: task.configuration.runtimeKind.displayName)
                LabeledContent("Model", value: task.configuration.model ?? "Agent default")
                LabeledContent("Thinking level", value: task.configuration.thinking ?? "Agent default")
                LabeledContent("Access", value: task.configuration.permission ?? "Agent default")
                LabeledContent("Work location", value: CalendarTaskFields.machineName(draft.machineID, in: model))
                LabeledContent("Session folder", value: task.configuration.folderID.map { id in model.workspace.workspaceOverview?.folders.first { $0.id == id }?.name ?? "Unavailable folder" } ?? "All Workspaces")
                if let directory = task.configuration.workingDirectory { LabeledContent("Directory", value: directory).textSelection(.enabled) }
                if draft.recurrence != nil { LabeledContent("Session", value: task.sessionMode.title) }
                Text("Prompt").fontWeight(.medium)
                Text(task.prompt).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            if let run {
                theme.palette.border.frame(height: 1)
                LabeledContent("Status", value: run.statusLabel)
                if let error = run.error { Text(error).foregroundStyle(WovenPalette.danger).fixedSize(horizontal: false, vertical: true) }
                Button("Open session") { dismiss(); onOpenSession(run.sessionID) }
                    .buttonStyle(WovenPrimaryButtonStyle())
                    .disabled(model.workspace.workspaceOverview?.conversations.contains { $0.id == run.sessionID } != true)
            }
        }
        .font(.system(size: 13))
        .labeledContentStyle(CalendarDetailStyle())
    }

    private func attribution(_ event: CalendarEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            theme.palette.border.frame(height: 1).padding(.bottom, 5)
            Text("Created by \(event.createdBy.label)")
            if let author = event.editedBy, let editedAt = event.editedAt {
                Text("Edited \(editedAt.formatted(date: .abbreviated, time: .shortened)) by \(author.label)")
            }
        }.font(.system(size: 11.5)).foregroundStyle(WovenPalette.mutedForeground)
    }

    private var footer: some View {
        HStack {
            if event != nil && !editing {
                if !isPastRun { Button("Delete", role: .destructive) { showsDelete = true }.buttonStyle(WovenQuietButtonStyle()) }
                Button("Copy event") { CalendarClipboard.copy(draft) }
                    .buttonStyle(WovenQuietButtonStyle()).keyboardShortcut("c", modifiers: .command)
            }
            Spacer()
            if editing {
                Button("Cancel") {
                    model.calendar.clearMutationError()
                    if event == nil { dismiss() } else { editing = false; draft = selection.draft }
                }.buttonStyle(WovenQuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button(model.calendar.isSaving ? "Saving…" : "Save") {
                    Task {
                        if await model.calendar.save(draft, entry: event, detaching: isSeries && scope == .detach ? selection.occurrence?.index : nil) { dismiss() }
                    }
                }.buttonStyle(WovenPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(model.calendar.isSaving || (try? draft.validated()) == nil)
            } else if isPastRun {
                Button("View event") { viewCurrentEvent() }.buttonStyle(WovenPrimaryButtonStyle())
            } else {
                Button("Edit") {
                    draft = event.map(CalendarDraft.init) ?? selection.draft
                    scope = .series; editing = true; model.calendar.clearMutationError()
                }.buttonStyle(WovenPrimaryButtonStyle())
            }
        }
    }
    private func viewCurrentEvent() {
        guard let eventID = event?.id, let event = model.calendar.entry(id: eventID) else { return }
        let index = event.recurrence == nil ? 0 : selection.occurrence?.index ?? 0
        let current = CalendarSchedule.occurrence(event, index: index)
            ?? CalendarSchedule.next(event, after: Date()).flatMap { date in
                CalendarSchedule.index(onOrBefore: date, start: event.startsAt,
                    recurrence: event.recurrence, timeZoneID: event.timeZoneID)
                    .flatMap { CalendarSchedule.occurrence(event, index: $0) }
            }
        guard let current else { return }
        selection = .init(draft: current.draft, occurrence: current)
        draft = current.draft
        model.calendar.clearMutationError()
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
        Task { if await model.calendar.delete(event, occurrence: occurrence) { dismiss() } }
    }
}
