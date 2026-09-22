import SwiftUI

enum DashboardCalendarColor: String, CaseIterable {
    case green, blue, purple, amber, red, pink, orange, yellow, teal, gray

    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .green: DashboardPalette.calendarEvent
        case .blue: DashboardPalette.calendarTask
        case .purple: DashboardPalette.calendarRecurringEvent
        case .amber: DashboardPalette.calendarRecurringTask
        case .red: .hex(0xB94E48)
        case .pink: .hex(0xAD527C)
        case .orange: .hex(0xBC642A)
        case .yellow: .hex(0x94751D)
        case .teal: .hex(0x287F7C)
        case .gray: .hex(0x6C7478)
        }
    }
}

struct DashboardCalendarColors: DynamicProperty {
    @AppStorage("wovenmatter.calendar.color.event") private var event = DashboardCalendarColor.green
    @AppStorage("wovenmatter.calendar.color.task") private var task = DashboardCalendarColor.blue
    @AppStorage("wovenmatter.calendar.color.recurring-event") private var recurringEvent = DashboardCalendarColor.purple
    @AppStorage("wovenmatter.calendar.color.recurring-task") private var recurringTask = DashboardCalendarColor.amber

    func selection(for style: DashboardCalendarEntryStyle) -> Binding<DashboardCalendarColor> {
        switch style {
        case .event: $event
        case .task: $task
        case .recurringEvent: $recurringEvent
        case .recurringTask: $recurringTask
        }
    }

    func color(for style: DashboardCalendarEntryStyle) -> Color {
        selection(for: style).wrappedValue.color
    }
}

struct DashboardCalendarLegendItem: View {
    let style: DashboardCalendarEntryStyle
    @Binding var selection: DashboardCalendarColor
    @State private var showsColors = false

    var body: some View {
        Button {
            showsColors.toggle()
        } label: {
            HStack(spacing: 8) {
                Circle().fill(selection.color).frame(width: 7, height: 7)
                    .accessibilityHidden(true)
                Text(style.title).font(.system(size: 11.5))
                DashboardLucideIcon(glyph: .chevronDown, size: 10)
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
        }
        .buttonStyle(DashboardQuietButtonStyle())
        .help("Change the color for \(style.title.lowercased())")
        .accessibilityLabel("\(style.title) color")
        .accessibilityValue(selection.title)
        .popover(isPresented: $showsColors, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: 12) {
                Text(style.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DashboardPalette.foreground)
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                    ForEach(DashboardCalendarColor.allCases, id: \.self) { option in
                        Button {
                            selection = option
                            showsColors = false
                        } label: {
                            HStack(spacing: 8) {
                                Circle().fill(option.color).frame(width: 10, height: 10)
                                    .accessibilityHidden(true)
                                Text(option.title)
                                Spacer(minLength: 0)
                                if option == selection {
                                    DashboardLucideIcon(glyph: .check, size: 12)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(DashboardQuietButtonStyle())
                        .accessibilityLabel(option.title)
                        .accessibilityAddTraits(option == selection ? .isSelected : [])
                    }
                }
            }
            .padding(16)
            .frame(width: 300)
            .onExitCommand { showsColors = false }
        }
    }
}
