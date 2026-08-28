import SwiftUI
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

struct DashboardCalendarEventDraft: Equatable {
    var title = ""
    var startsAt: Date
    var endsAt: Date
    var allDay = false

    init(selectedDate: Date, calendar: Calendar = .autoupdatingCurrent, now: Date = Date()) {
        let day = calendar.startOfDay(for: selectedDate)
        let start: Date
        if calendar.isDate(selectedDate, inSameDayAs: now) {
            let nextHour = calendar.dateInterval(of: .hour, for: now)?.end ?? now
            start = nextHour
        } else {
            start = calendar.date(byAdding: .hour, value: 9, to: day) ?? day
        }
        startsAt = start
        endsAt = calendar.date(byAdding: .hour, value: 1, to: start) ?? start
    }
}

struct DashboardCalendarSurface: View {
    @Environment(\.dashboardTheme) private var theme
    @Bindable var model: ApplicationModel
    @State private var displayedMonth = Date()
    @State private var selectedDate = Calendar.autoupdatingCurrent.startOfDay(for: Date())
    @State private var eventDraft = DashboardCalendarEventDraft(selectedDate: Date())
    @State private var showingAddEvent = false

    private let calendar = Calendar.autoupdatingCurrent
    private let columns = Array(
        repeating: GridItem(.flexible(minimum: 54), spacing: 6),
        count: 7
    )

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(spacing: 14) {
                    monthCard
                    selectedDayCard
                }
                .frame(maxWidth: 920)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 24)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.never)
        }
        .background(theme.palette.workspace)
        .sheet(isPresented: $showingAddEvent) {
            DashboardAddCalendarEventSheet(
                model: model,
                draft: $eventDraft
            )
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            DashboardLucideIcon(glyph: .calendarDaysControl, size: 18)
                .foregroundStyle(DashboardPalette.primary)
                .frame(width: 36, height: 36)
                .background(DashboardPalette.muted)
                .clipShape(RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                ))
            VStack(alignment: .leading, spacing: 3) {
                Text("Calendar")
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.3)
                Text("Events, reminders, and scheduled agent work.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            Spacer()
            Button(action: presentAddEvent) {
                HStack(spacing: 7) {
                    DashboardLucideIcon(glyph: .plus, size: 14)
                    Text("Add event")
                }
            }
            .buttonStyle(DashboardPrimaryButtonStyle())
        }
        .padding(.horizontal, 32)
        .padding(.top, 56)
    }

    private var monthCard: some View {
        let layout = DashboardCalendarMonthLayout(displaying: displayedMonth, calendar: calendar)
        return DashboardCard {
            VStack(spacing: 14) {
                HStack(spacing: 8) {
                    Text(layout.monthStart.formatted(.dateTime.month(.wide).year()))
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DashboardPalette.foreground)
                    Spacer()
                    Button("Today") {
                        let today = Date()
                        displayedMonth = today
                        selectedDate = calendar.startOfDay(for: today)
                    }
                    .buttonStyle(DashboardQuietButtonStyle())
                    monthNavigationButton(
                        glyph: .arrowLeft,
                        label: "Previous month",
                        offset: -1
                    )
                    monthNavigationButton(
                        glyph: .arrowRight,
                        label: "Next month",
                        offset: 1
                    )
                }

                LazyVGrid(columns: columns, spacing: 6) {
                    ForEach(Array(layout.weekdaySymbols.enumerated()), id: \.offset) { _, symbol in
                        Text(symbol.uppercased())
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(1.1)
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 3)
                    }
                    ForEach(layout.days) { day in
                        dayCell(day)
                    }
                }
            }
        }
    }

    private var selectedDayCard: some View {
        let items = items(on: selectedDate)
        return DashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        DashboardSectionHeading(title: "Selected day")
                        Text(selectedDate.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                            .font(.system(size: 15, weight: .semibold))
                    }
                    Spacer()
                    Button("Add event", action: presentAddEvent)
                        .buttonStyle(DashboardQuietButtonStyle())
                }
                if items.isEmpty {
                    Text("No events scheduled for this day.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                } else {
                    VStack(spacing: 8) {
                        ForEach(items) { item in
                            HStack(spacing: 10) {
                                Circle()
                                    .fill(DashboardPalette.primary)
                                    .frame(width: 7, height: 7)
                                Text(timeLabel(for: item))
                                    .font(.system(size: 11.5, weight: .medium))
                                    .foregroundStyle(DashboardPalette.mutedForeground)
                                    .frame(width: 70, alignment: .leading)
                                Text(item.title)
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(DashboardPalette.foreground)
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
        }
    }

    private func dayCell(_ day: DashboardCalendarMonthLayout.Day) -> some View {
        let dayItems = items(on: day.date)
        let selected = calendar.isDate(day.date, inSameDayAs: selectedDate)
        let today = calendar.isDateInToday(day.date)
        return Button {
            selectedDate = calendar.startOfDay(for: day.date)
            if !day.isInDisplayedMonth {
                displayedMonth = day.date
            }
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(day.date.formatted(.dateTime.day()))
                    .font(.system(size: 11.5, weight: today ? .bold : .medium))
                    .foregroundStyle(today ? DashboardPalette.primaryForeground : DashboardPalette.foreground)
                    .frame(width: 25, height: 25)
                    .background(today ? DashboardPalette.primary : .clear, in: Circle())
                ForEach(Array(dayItems.prefix(2))) { item in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(DashboardPalette.primary)
                            .frame(width: 5, height: 5)
                        Text(item.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                    }
                }
                if dayItems.count > 2 {
                    Text("+\(dayItems.count - 2) more")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(DashboardPalette.foreground)
            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
            .padding(8)
            .background(
                selected ? theme.palette.themeSoft : DashboardPalette.muted.opacity(0.32),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(
                        selected ? theme.palette.themeRing : theme.palette.border.opacity(0.65),
                        lineWidth: selected ? 1.5 : 1
                    )
            }
            .opacity(day.isInDisplayedMonth ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.date.formatted(date: .complete, time: .omitted))
    }

    private func monthNavigationButton(
        glyph: DashboardLucideGlyph,
        label: String,
        offset: Int
    ) -> some View {
        Button {
            if let month = calendar.date(byAdding: .month, value: offset, to: displayedMonth) {
                displayedMonth = month
            }
        } label: {
            DashboardLucideIcon(glyph: glyph, size: 14)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(DashboardQuietButtonStyle())
        .accessibilityLabel(label)
    }

    private func items(on day: Date) -> [WorkspaceCalendarItemRecord] {
        model.calendarItems
            .filter { item in
                item.startDate.map { calendar.isDate($0, inSameDayAs: day) } == true
            }
            .sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }
    }

    private func timeLabel(for item: WorkspaceCalendarItemRecord) -> String {
        guard !item.allDay, let start = item.startDate else { return "All day" }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private func presentAddEvent() {
        model.clearCalendarMutationError()
        eventDraft = DashboardCalendarEventDraft(selectedDate: selectedDate)
        showingAddEvent = true
    }
}

private struct DashboardAddCalendarEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var model: ApplicationModel
    @Binding var draft: DashboardCalendarEventDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add event")
                    .font(.system(size: 20, weight: .semibold))
                Text("Create an event in your Woven Matter calendar.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }

            VStack(alignment: .leading, spacing: 12) {
                TextField("Event title", text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                Toggle("All-day event", isOn: $draft.allDay)
                DatePicker(
                    "Starts",
                    selection: $draft.startsAt,
                    displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute]
                )
                DatePicker(
                    "Ends",
                    selection: $draft.endsAt,
                    in: draft.startsAt...,
                    displayedComponents: draft.allDay ? [.date] : [.date, .hourAndMinute]
                )
            }
            .onChange(of: draft.startsAt) { _, startsAt in
                if draft.endsAt <= startsAt {
                    draft.endsAt = Calendar.autoupdatingCurrent.date(
                        byAdding: .hour,
                        value: 1,
                        to: startsAt
                    ) ?? startsAt.addingTimeInterval(3_600)
                }
            }

            if let error = model.calendarMutationError {
                HStack(alignment: .top, spacing: 8) {
                    DashboardLucideIcon(glyph: .alertCircle, size: 14)
                    Text(error)
                        .font(.system(size: 11.5))
                }
                .foregroundStyle(DashboardPalette.danger)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(DashboardQuietButtonStyle())
                Button {
                    Task {
                        let created = await model.createCalendarItem(
                            title: draft.title,
                            startsAt: draft.startsAt,
                            endsAt: draft.endsAt,
                            allDay: draft.allDay
                        )
                        if created { dismiss() }
                    }
                } label: {
                    if model.isCreatingCalendarItem {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 58)
                    } else {
                        Text("Add event")
                    }
                }
                .buttonStyle(DashboardPrimaryButtonStyle())
                .disabled(
                    draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || draft.endsAt <= draft.startsAt
                        || model.isCreatingCalendarItem
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 430)
        .background(DashboardPalette.background)
    }
}
