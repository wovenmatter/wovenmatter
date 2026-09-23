import SwiftUI

struct DashboardCalendarField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(DashboardPalette.mutedForeground)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardCalendarInputStyle: ViewModifier {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
            .background(isEnabled && isHovering ? theme.palette.themeSoft : theme.palette.themeWhisper)
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}

struct DashboardCalendarMenuPicker<Option: Hashable>: View {
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                ForEach(options, id: \.self) { option in
                    Text(label(option)).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 8) {
                Text(label(selection))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                DashboardLucideIcon(glyph: .chevronDown, size: 12)
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(DashboardQuietButtonStyle())
        .accessibilityLabel(title)
        .accessibilityValue(label(selection))
    }
}

struct DashboardCalendarDetailStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            configuration.label
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
                .frame(width: 110, alignment: .leading)
            configuration.content
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
