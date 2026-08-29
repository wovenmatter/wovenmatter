import AppKit
import SwiftUI

struct SettingsPage<Content: View>: View {
    let title: String
    var detail: String? = nil
    var reservesRailControlSpace = false
    var backTitle = "Settings"
    var onBack: (() -> Void)? = nil
    @ViewBuilder var content: Content

    init(
        title: String,
        detail: String? = nil,
        reservesRailControlSpace: Bool = false,
        backTitle: String = "Settings",
        onBack: (() -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.reservesRailControlSpace = reservesRailControlSpace
        self.backTitle = backTitle
        self.onBack = onBack
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    if let onBack {
                        SettingsBackButton(title: backTitle, action: onBack)
                    }
                    Text(title)
                        .font(.system(size: 22, weight: .semibold))
                        .tracking(-0.35)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 13))
                            .foregroundStyle(DashboardPalette.mutedForeground)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.bottom, 4)
                content
            }
            .frame(maxWidth: 1_080, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, reservesRailControlSpace ? 76 : 28)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollIndicators(.never)
        .contentShape(Rectangle())
        .onTapGesture {
            NSApp.keyWindow?.makeFirstResponder(nil)
        }
    }
}

struct SettingsBackButton: View {
    @Environment(\.dashboardTheme) private var theme
    let title: String
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                DashboardLucideIcon(glyph: .arrowLeft, size: 10)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .background(isHovering ? theme.palette.themeWhisper : Color.clear)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct SettingsDestinationRow<Icon: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let title: String
    let detail: String
    @ViewBuilder var icon: Icon
    let action: () -> Void
    @State private var isHovering = false

    init(
        title: String,
        detail: String,
        @ViewBuilder icon: () -> Icon,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.detail = detail
        self.icon = icon()
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                icon
                    .frame(width: 16, height: 16)
                    .foregroundStyle(DashboardPalette.mutedForeground)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DashboardPalette.foreground)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DashboardPalette.mutedForeground.opacity(0.55))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(isHovering ? theme.palette.themeWhisper : Color.clear)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

struct SettingsCard<Content: View>: View {
    @Environment(\.dashboardTheme) private var theme
    let title: String
    var detail: String? = nil
    @ViewBuilder var content: Content

    init(title: String, detail: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.detail = detail
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                if let detail {
                    Text(detail)
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content
        }
        .padding(16)
        .background(theme.palette.workspace)
        .clipShape(DashboardShapes.card)
    }
}

struct SettingsField<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.25)
                .foregroundStyle(DashboardPalette.mutedForeground)
            content
        }
    }
}

struct SettingsInset<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.vertical, 6)
    }
}

struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Dropdown picker

/// Compact dropdown styled and sized exactly like a SettingsQuietButtonStyle
/// button so it aligns with neighboring action buttons. Uses a Button +
/// popover instead of Menu/Picker: native menu styles add internal padding
/// that breaks edge alignment and tint the label with the accent color.
struct SettingsMenuPicker: View {
    @Environment(\.dashboardTheme) private var theme
    @State private var isHovering = false
    @State private var isPresented = false

    let selection: String
    let options: [String]
    var capitalizeOptions: Bool = false
    var width: CGFloat = 180
    let onSelect: (String) -> Void

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                Text(selection.isEmpty ? "Select…" : label(for: selection))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(DashboardPalette.foreground)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DashboardPalette.mutedForeground)
            }
            .padding(.horizontal, 12)
            .frame(width: width, height: 36, alignment: .leading)
            .background(theme.palette.themeSoft.opacity(isHovering ? 0.72 : 0))
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .onHover { isHovering = $0 }
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                if options.isEmpty {
                    Text("No options available")
                        .font(.system(size: 12.5))
                        .foregroundStyle(DashboardPalette.mutedForeground)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                } else {
                    ForEach(options, id: \.self) { option in
                        Button {
                            onSelect(option)
                            isPresented = false
                        } label: {
                            HStack {
                                Text(label(for: option))
                                    .font(.system(size: 13))
                                    .foregroundStyle(DashboardPalette.foreground)
                                Spacer()
                                if option == selection {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(DashboardPalette.primary)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(6)
            .frame(minWidth: width)
        }
    }

    private func label(for option: String) -> String {
        capitalizeOptions ? option.capitalized : option
    }
}

struct SettingsEmpty: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12.5))
            .foregroundStyle(DashboardPalette.mutedForeground)
            .padding(.vertical, 4)
    }
}

struct SettingsError: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DashboardPalette.danger)
            .textSelection(.enabled)
    }
}

struct SettingsValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundStyle(DashboardPalette.mutedForeground)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 13, weight: .medium))
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}

enum SettingsPillTone {
    case neutral
    case warning
}

struct SettingsPill: View {
    @Environment(\.dashboardTheme) private var theme
    let text: String
    let tone: SettingsPillTone

    init(_ text: String, tone: SettingsPillTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(tone == .warning ? DashboardPalette.warning : DashboardPalette.mutedForeground)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tone == .warning ? DashboardPalette.warning.opacity(0.1) : theme.palette.themeSoft)
            .clipShape(Capsule())
    }
}

struct SettingsThemePreview: View {
    let theme: DashboardTheme

    private var railFill: Color {
        theme == .green
            ? .hex(0x004225, opacity: 0.16)
            : .hex(0xFFFFFF, opacity: 0.96)
    }

    var body: some View {
        HStack(spacing: 8) {
            previewRail
            VStack(alignment: .leading, spacing: 5) {
                Spacer()
                Capsule()
                    .fill(DashboardPalette.primary)
                    .frame(width: 32, height: 6)
                Capsule()
                    .fill(Color.black.opacity(0.06))
                    .frame(height: 6)
            }
            .padding(8)
            .frame(maxWidth: .infinity)
            .background {
                theme.palette.workspace
                    .overlay(theme.palette.themeWhisper)
            }
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
            )
            previewRail
        }
        .padding(8)
        .frame(height: 80)
        .background(theme.palette.workspace)
        .clipShape(DashboardShapes.card)
        .shadow(color: .hex(0x0A1F16, opacity: 0.07), radius: 6, y: 2)
    }

    private var previewRail: some View {
        RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous)
            .fill(railFill)
            .frame(width: 32)
            .shadow(
                color: theme == .cognac ? Color.hex(0x4D2D15, opacity: 0.08) : .clear,
                radius: 7,
                y: 3
            )
    }
}

struct SettingsInputModifier: ViewModifier {
    @Environment(\.dashboardTheme) private var theme
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 12)
            .frame(minHeight: 40)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focused($focused)
            .background(theme.palette.workspace)
            .clipShape(
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: DashboardMetrics.controlRadius,
                    style: .continuous
                )
                .stroke(
                    focused ? theme.palette.themeRing : DashboardPalette.mutedForeground.opacity(0.3),
                    lineWidth: focused ? 1.5 : 1
                )
            }
    }
}

extension View {
    func settingsInput() -> some View {
        modifier(SettingsInputModifier())
    }
}

struct SettingsQuietButtonStyle: ButtonStyle {
    @Environment(\.dashboardTheme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(DashboardPalette.foreground)
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            .background(
                theme.palette.themeSoft.opacity(
                    configuration.isPressed ? 1 : (isHovering ? 0.72 : 0)
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: DashboardMetrics.controlRadius, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
            .onHover { isHovering = $0 }
    }
}
