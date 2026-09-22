import SwiftUI

enum DashboardCalendarColor: String, CaseIterable {
    case cognac
    case britishRacingGreen = "green"
    case green = "lime"
    case blue, purple, red, pink, orange, yellow, black

    init?(rawValue: String) {
        // Carry existing selections into the renamed palette.
        switch rawValue {
        case "amber": self = .cognac
        case "teal": self = .green
        case "gray": self = .black
        default:
            guard let color = Self.allCases.first(where: { $0.rawValue == rawValue }) else { return nil }
            self = color
        }
    }

    var title: String {
        switch self {
        case .britishRacingGreen: "British Racing Green"
        case .green: "Green"
        case .blue: "Royal blue"
        default: rawValue.capitalized
        }
    }

    var color: Color {
        switch self {
        case .cognac: DashboardPalette.calendarRecurringTask
        case .britishRacingGreen: DashboardPalette.calendarEvent
        case .green: .hex(0x84CC16)
        case .blue: DashboardPalette.calendarTask
        case .purple: DashboardPalette.calendarRecurringEvent
        case .red: .hex(0xD23F3F)
        case .pink: .hex(0xD75A95)
        case .orange: .hex(0xE67E22)
        case .yellow: .hex(0xE6B800)
        case .black: .black
        }
    }
}

struct DashboardCalendarColors: DynamicProperty {
    @AppStorage("wovenmatter.calendar.color.event") private var event = DashboardCalendarColor.britishRacingGreen
    @AppStorage("wovenmatter.calendar.color.task") private var task = DashboardCalendarColor.blue
    @AppStorage("wovenmatter.calendar.color.recurring-event") private var recurringEvent = DashboardCalendarColor.purple
    @AppStorage("wovenmatter.calendar.color.recurring-task") private var recurringTask = DashboardCalendarColor.cognac

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
                                Text(option.title).lineLimit(1)
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
            .frame(width: 440)
            .onExitCommand { showsColors = false }
        }
    }
}
