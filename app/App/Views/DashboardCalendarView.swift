import SwiftUI
import AppKit
import WovenMatterCore

struct DashboardCalendarMonthLayout: Equatable {
    struct Day: Equatable, Identifiable {
        let date: Date
        let isInDisplayedMonth: Bool

        var id: Date { date }
    }

    let monthStart: Date
    let days: [Day]
    let weekdaySymbols: [String]

    init(displaying date: Date, calendar: Calendar) {
        let monthStart = calendar.dateInterval(of: .month, for: date)?.start
            ?? calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: monthStart)
        let leadingDays = (weekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leadingDays, to: monthStart)
            ?? monthStart
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstSymbolIndex = max(0, min(6, calendar.firstWeekday - 1))

        self.monthStart = monthStart
        days = (0..<42).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: gridStart) else {
                return nil
            }
            return Day(
                date: day,
                isInDisplayedMonth: calendar.isDate(
                    day,
                    equalTo: monthStart,
                    toGranularity: .month
                )
            )
        }
        weekdaySymbols = (0..<7).map { offset in
            symbols[(firstSymbolIndex + offset) % symbols.count]
        }
    }
}

enum DashboardCalendarClipboard {
    static let type = NSPasteboard.PasteboardType("com.wovenmatter.calendar-event")
    static func copy(_ draft: WorkspaceCalendarDraft) {
        guard let data = try? JSONEncoder().encode(draft) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: type)
    }
    static func read() -> WorkspaceCalendarDraft? {
        guard let data = NSPasteboard.general.data(forType: type), data.count <= 256 * 1_024 else { return nil }
        return try? JSONDecoder().decode(WorkspaceCalendarDraft.self, from: data)
    }
}

struct DashboardCalendarSelection: Identifiable {
    let id = UUID()
    let draft: WorkspaceCalendarDraft
    var occurrence: WorkspaceCalendarOccurrence?
}

enum DashboardCalendarEntryStyle: CaseIterable {
    case event, task, recurringEvent, recurringTask

    init(_ draft: WorkspaceCalendarDraft) {
        switch (draft.task != nil, draft.recurrence != nil) {
        case (false, false): self = .event
        case (true, false): self = .task
        case (false, true): self = .recurringEvent
        case (true, true): self = .recurringTask
        }
    }

    var title: String {
        switch self {
        case .event: "Events"
        case .task: "Scheduled Tasks"
        case .recurringEvent: "Reoccurring Events"
        case .recurringTask: "Reoccurring Scheduled Tasks"
        }
    }
}

struct DashboardCalendarSurface: View {
    @Environment(\.dashboardTheme) private var theme
    private var colors = DashboardCalendarColors()
    @Bindable var model: ApplicationModel
    var onOpenSession: (String) -> Void = { _ in }
    @State private var displayedMonth = Date()
    @State private var selectedDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @State private var selection: DashboardCalendarSelection?
    private let calendar = Calendar.autoupdatingCurrent
    private let columns = Array(repeating: GridItem(.flexible(minimum: 54), spacing: 6), count: 7)

    init(model: ApplicationModel, onOpenSession: @escaping (String) -> Void = { _ in }) {
        self.model = model
        self.onOpenSession = onOpenSession
    }

    private var layout: DashboardCalendarMonthLayout { .init(displaying: displayedMonth, calendar: calendar) }
    private var visibleRange: DateInterval {
        let start = layout.days.first?.date ?? selectedDate
        return .init(start: start, end: calendar.date(byAdding: .day, value: 42, to: start) ?? start)
    }
    private var occurrences: [WorkspaceCalendarOccurrence] {
        WorkspaceCalendarSchedule.visibleOccurrences(events: model.calendarItems, runs: model.calendarRuns, in: visibleRange)
    }

    private func items(on day: Date, from occurrences: [WorkspaceCalendarOccurrence]) -> [WorkspaceCalendarOccurrence] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return occurrences.filter {
            let interval = $0.displayInterval(in: calendar)
            return interval.start < end && interval.end > start
        }
    }

    var body: some View {
        let occurrences = occurrences
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 20) {
                    monthCard(occurrences)
                    selectedDayCard(items(on: selectedDate, from: occurrences))
                    if let error = model.calendarMutationError {
                        Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger)
                    }
                    legend
                }
                .frame(maxWidth: 1_080).frame(maxWidth: .infinity)
                .padding(.horizontal, 32).padding(.top, 24).padding(.bottom, 40)
            }.scrollIndicators(.never)
        }
        .background(theme.palette.workspace)
        .sheet(item: $selection) { item in
            DashboardCalendarEventSheet(model: model, selection: item, onOpenSession: onOpenSession)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            DashboardLucideIcon(glyph: .calendarDaysControl, size: 18)
                .frame(width: 36, height: 36).background(DashboardPalette.muted)
                .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius))
            Text("Calendar").font(.system(size: 22, weight: .semibold)).tracking(-0.3)
            Spacer()
            Button("Paste event") { paste(on: selectedDate) }
                .buttonStyle(DashboardQuietButtonStyle()).keyboardShortcut("v", modifiers: .command)
                .help("Paste a copied calendar event onto the selected day")
            Button("Add event") { add(on: selectedDate) }.buttonStyle(DashboardPrimaryButtonStyle())
        }.padding(.horizontal, 32).padding(.top, 56)
    }

    private func monthCard(_ occurrences: [WorkspaceCalendarOccurrence]) -> some View {
        DashboardCard(showsBorder: false, showsBackground: false) {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Text(layout.monthStart.formatted(.dateTime.month(.wide).year())).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Button("Today") { displayedMonth = Date(); selectedDate = calendar.startOfDay(for: Date()) }
                        .buttonStyle(DashboardQuietButtonStyle())
                    navigation(.arrowLeft, "Previous month", -1)
                    navigation(.arrowRight, "Next month", 1)
                }
                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(layout.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol.uppercased()).font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(DashboardPalette.mutedForeground).padding(.vertical, 3)
                    }
                    ForEach(layout.days) { day in dayCell(day, occurrences: items(on: day.date, from: occurrences)) }
                }
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Legend").font(.system(size: 11, weight: .medium))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    legendItems
                }
                .fixedSize(horizontal: true, vertical: false)
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 8) {
                    legendItems
                }
            }
        }
        .foregroundStyle(DashboardPalette.mutedForeground)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }

    private var legendItems: some View {
        ForEach(DashboardCalendarEntryStyle.allCases, id: \.self) { style in
            DashboardCalendarLegendItem(style: style, selection: colors.selection(for: style))
        }
    }

    private func dayCell(_ day: DashboardCalendarMonthLayout.Day, occurrences: [WorkspaceCalendarOccurrence]) -> some View {
        let selected = calendar.isDate(day.date, inSameDayAs: selectedDate)
        let today = calendar.isDateInToday(day.date)
        return VStack(alignment: .leading, spacing: 5) {
            Button {
                select(day.date)
            } label: {
                Text(day.date.formatted(.dateTime.day())).font(.system(size: 11.5, weight: today ? .bold : .medium))
                    .foregroundStyle(today ? DashboardPalette.primaryForeground : DashboardPalette.foreground)
                    .frame(width: 25, height: 25).background(today ? DashboardPalette.primary : .clear, in: Circle())
            }.buttonStyle(.plain).accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
            ForEach(occurrences.prefix(3)) { occurrence in
                let style = DashboardCalendarEntryStyle(occurrence.draft)
                Button { open(occurrence) } label: {
                    HStack(spacing: 4) {
                        Circle().fill(colors.color(for: style)).frame(width: 5, height: 5)
                        Text(occurrence.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                .accessibilityLabel(occurrence.title + ", " + style.title)
                .help(occurrence.title + (occurrence.recurrence.map { " · " + $0.label } ?? ""))
                .contextMenu { Button("Open event") { open(occurrence) }; Button("Copy event") { DashboardCalendarClipboard.copy(occurrence.draft) } }
            }
            if occurrences.count > 3 {
                Button("+\(occurrences.count - 3) more") { select(day.date) }
                    .font(.system(size: 10)).buttonStyle(.plain).foregroundStyle(DashboardPalette.mutedForeground)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: 91, alignment: .topLeading).padding(8)
        .background(selected ? theme.palette.themeSoft : DashboardPalette.muted.opacity(0.32), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? theme.palette.border : theme.palette.border.opacity(0.65), lineWidth: selected ? 1.5 : 1) }
        .opacity(day.isInDisplayedMonth ? 1 : 0.5)
        .contentShape(Rectangle()).onTapGesture { select(day.date) }
        .contextMenu {
            Button("Add event") { add(on: day.date) }
            Button("Paste event") { paste(on: day.date) }
        }
    }

    private func selectedDayCard(_ occurrences: [WorkspaceCalendarOccurrence]) -> some View {
        DashboardCard(showsBorder: false, showsBackground: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Add event") { add(on: selectedDate) }.buttonStyle(DashboardQuietButtonStyle())
                }
                if occurrences.isEmpty { Text("No events.").font(.system(size: 12.5)).foregroundStyle(DashboardPalette.mutedForeground) }
                ForEach(occurrences) { occurrence in
                    let style = DashboardCalendarEntryStyle(occurrence.draft)
                    Button { open(occurrence) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(colors.color(for: style)).frame(width: 7, height: 7)
                            Text(occurrence.allDay ? "All day" : occurrence.startsAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11.5)).frame(width: 75, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(occurrence.title).font(.system(size: 13, weight: .medium))
                                Text(occurrence.recordedRun != nil ? "Past run" : style.title)
                                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            }
                            Spacer()
                            if let repeatRule = occurrence.recurrence {
                                Text(repeatRule.label).font(.system(size: 11)).foregroundStyle(colors.color(for: style))
                            }
                            if let run = model.calendarRuns.last(where: { $0.eventID == occurrence.event.id && $0.scheduledAt == occurrence.startsAt }) {
                                Text(run.statusLabel).font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            }
                            DashboardLucideIcon(glyph: .arrowRight, size: 12)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(DashboardQuietButtonStyle())
                }
            }
        }
    }

    private func navigation(_ glyph: DashboardLucideGlyph, _ label: String, _ offset: Int) -> some View {
        Button {
            if let month = calendar.date(byAdding: .month, value: offset, to: layout.monthStart) {
                displayedMonth = month; selectedDate = month
            }
        } label: { DashboardLucideIcon(glyph: glyph, size: 14) }
        .buttonStyle(DashboardQuietButtonStyle()).accessibilityLabel(label)
    }
    private func select(_ date: Date) {
        selectedDate = calendar.startOfDay(for: date)
        if !calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month) { displayedMonth = date }
    }
    private func open(_ occurrence: WorkspaceCalendarOccurrence) {
        model.clearCalendarMutationError()
        selection = .init(draft: occurrence.draft, occurrence: occurrence)
    }
    private func add(on day: Date) {
        model.clearCalendarMutationError()
        let start = calendar.isDateInToday(day) ? calendar.dateInterval(of: .hour, for: Date())?.end ?? Date()
            : calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day) ?? day
        selection = .init(draft: .init(startsAt: start, endsAt: start.addingTimeInterval(3_600)))
    }
    private func paste(on day: Date) {
        guard let draft = DashboardCalendarClipboard.read() else {
            model.calendarMutationError = "Copy a calendar event first."; return
        }
        model.clearCalendarMutationError()
        selection = .init(draft: draft.copied(to: day))
    }
}

/// A list presentation of the same schedules used by Calendar. Calendar visibility
/// changes presentation only; tasks keep their existing identity and run history.
struct DashboardScheduledTasksSurface: View {
    @Bindable var model: ApplicationModel
    @Binding var provider: String
    let onOpenSession: (String) -> Void
    @State private var selection: DashboardCalendarSelection?

    private var calendarTasks: Bool { provider == "Calendar Tasks" }
    private var tasks: [WorkspaceCalendarItemRecord] {
        model.calendarItems.filter {
            $0.calendar.task != nil && $0.calendar.showsOnCalendar == calendarTasks
        }.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                heading
                tabs
                HStack(alignment: .top) {
                    Text(calendarTasks
                        ? "Tasks shown on your calendar. Create or manage them here."
                        : "Schedule a task to run once, or as a reoccurring task. Add tasks to your calendar whenever you like.")
                        .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                    Spacer()
                    Button("New task") { newTask() }.buttonStyle(DashboardPrimaryButtonStyle())
                }
                Text("Local tasks run while Woven Matter is open or background execution is enabled. Remote tasks run on their workspace when its background execution is enabled.")
                    .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            }.padding(.horizontal, 32).padding(.top, 48).padding(.bottom, 20)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if tasks.isEmpty {
                        Text(calendarTasks ? "No calendar tasks." : "No scheduled tasks.")
                            .font(.system(size: 13)).foregroundStyle(DashboardPalette.mutedForeground)
                    }
                    ForEach(tasks) { task in taskRow(task) }
                    ForEach(model.remoteCalendarGatewayErrors.keys.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                        Text("\(model.remoteWorkspaces.configuration(id: id)?.name ?? "Remote workspace"): \(model.remoteCalendarGatewayErrors[id] ?? "")")
                            .font(.system(size: 12)).foregroundStyle(DashboardPalette.danger)
                    }
                    if let error = model.calendarMutationError { Text(error).font(.system(size: 12)).foregroundStyle(DashboardPalette.danger) }
                }.frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 32).padding(.bottom, 32)
            }.scrollIndicators(.never)
        }
        .sheet(item: $selection) { item in
            DashboardCalendarEventSheet(model: model, selection: item,
                onOpenSession: onOpenSession, tasksOnly: true)
        }
    }

    private var heading: some View {
        HStack(spacing: 12) {
            DashboardLucideIcon(glyph: .calendarClockControl, size: 18)
                .foregroundStyle(DashboardPalette.primary).frame(width: 36, height: 36)
                .background(DashboardPalette.muted)
                .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius))
            Text("Scheduled Tasks").font(.system(size: 22, weight: .semibold))
        }
    }
    private var tabs: some View {
        DashboardSegmentedSelector(options: ["Scheduled Tasks", "Calendar Tasks", "Hermes", "OpenClaw"],
            selection: $provider) { $0 }.frame(width: 440)
    }
    private func newTask() {
        model.clearCalendarMutationError()
        var draft = WorkspaceCalendarDraft(startsAt: Date().addingTimeInterval(3_600),
            task: model.calendarTaskDefaults(runtime: .codex, workspaceID: nil))
        draft.showsOnCalendar = calendarTasks
        selection = .init(draft: draft)
    }
    private func taskRow(_ item: WorkspaceCalendarItemRecord) -> some View {
        let run = model.calendarRuns.last { $0.eventID == item.id && $0.status != "cancelled" }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Button {
                    model.clearCalendarMutationError()
                    let occurrence = WorkspaceCalendarOccurrence(event: item, index: 0,
                        startsAt: item.startDate ?? Date(), endsAt: item.endDate)
                    selection = .init(draft: WorkspaceCalendarDraft(item), occurrence: occurrence)
                } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(item.title).font(.system(size: 14, weight: .semibold))
                        Text(item.calendar.task?.configuration.runtimeKind.displayName ?? "Agent")
                            .font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button(calendarTasks ? "Remove from calendar" : "Add to calendar") {
                    var draft = WorkspaceCalendarDraft(item)
                    draft.showsOnCalendar.toggle()
                    Task { _ = await model.saveCalendarEvent(draft, event: item) }
                }.buttonStyle(DashboardQuietButtonStyle()).disabled(model.isCreatingCalendarItem)
            }
            HStack(spacing: 12) {
                if let start = item.startDate {
                    Text(start.formatted(date: .abbreviated, time: .shortened))
                }
                if let recurrence = item.calendar.recurrence { Text(recurrence.label) }
                if let run { Text(run.statusLabel) }
            }.font(.system(size: 12)).foregroundStyle(DashboardPalette.mutedForeground)
            if let prompt = item.calendar.task?.prompt {
                Text(prompt).font(.system(size: 13)).lineLimit(2)
            }
            if let run, model.workspaceOverview?.conversations.contains(where: { $0.id == run.sessionID }) == true {
                Button("Open session") { onOpenSession(run.sessionID) }
                    .buttonStyle(DashboardQuietButtonStyle())
            }
        }.padding(.vertical, 8)
    }
}
