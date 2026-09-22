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

struct DashboardCalendarSurface: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    var onOpenSession: (String) -> Void = { _ in }
    @State private var displayedMonth = Date()
    @State private var selectedDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @State private var selection: DashboardCalendarSelection?
    private let calendar = Calendar.autoupdatingCurrent
    private let columns = Array(repeating: GridItem(.flexible(minimum: 54), spacing: 6), count: 7)

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
        DashboardCard(showsBackground: false) {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Text(layout.monthStart.formatted(.dateTime.month(.wide).year())).font(.system(size: 16, weight: .semibold))
                    Spacer()
                    Label { Text("Recurring").font(.system(size: 11)) } icon: {
                        Circle().fill(DashboardPalette.calendarRecurring).frame(width: 7, height: 7)
                    }.foregroundStyle(DashboardPalette.mutedForeground)
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
                Button { open(occurrence) } label: {
                    HStack(spacing: 4) {
                        Circle().fill(color(occurrence)).frame(width: 5, height: 5)
                        Text(occurrence.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                    }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }.buttonStyle(.plain)
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
        DashboardCard(showsBackground: false) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day())).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Button("Add event") { add(on: selectedDate) }.buttonStyle(DashboardQuietButtonStyle())
                }
                if occurrences.isEmpty { Text("No events.").font(.system(size: 12.5)).foregroundStyle(DashboardPalette.mutedForeground) }
                ForEach(occurrences) { occurrence in
                    Button { open(occurrence) } label: {
                        HStack(spacing: 12) {
                            Circle().fill(color(occurrence)).frame(width: 7, height: 7)
                            Text(occurrence.allDay ? "All day" : occurrence.startsAt.formatted(date: .omitted, time: .shortened))
                                .font(.system(size: 11.5)).frame(width: 75, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(occurrence.title).font(.system(size: 13, weight: .medium))
                                Text(occurrence.recordedRun != nil ? "Past run" : occurrence.event.calendar.task == nil ? "Event" : "Scheduled task")
                                    .font(.system(size: 11)).foregroundStyle(DashboardPalette.mutedForeground)
                            }
                            Spacer()
                            if let repeatRule = occurrence.recurrence {
                                Text(repeatRule.label).font(.system(size: 11)).foregroundStyle(DashboardPalette.calendarRecurring)
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
    private func color(_ occurrence: WorkspaceCalendarOccurrence) -> Color {
        occurrence.recurrence == nil ? DashboardPalette.primary : DashboardPalette.calendarRecurring
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
