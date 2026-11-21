import SwiftUI
import UIKit

/// The pages Settings opens, on its own navigation stack.
enum SettingsPage: Hashable {
    case machines
    /// Connecting again with a new code, once machines are connected.
    case connect
    case device
    case quickChat
    case providers
    /// One provider's sign-ins and keys, by its row's id in `ProviderRow`.
    case provider(String)
    /// A model server; nil adds one.
    case modelServer(String?)
    case defaultModel
    case composerModels
    case appearance
    case dictation
}

/// "iPhone" or "iPad", for wording that names this device.
@MainActor
enum ThisDevice {
    static var kind: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    static var glyph: LucideGlyph { UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .smartphone }
    /// The app's release, which every machine it syncs with must share.
    static var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
}

enum SettingsTone {
    case neutral, good, warning

    var color: Color {
        switch self {
        case .neutral: WovenPalette.mutedForeground.opacity(0.6)
        case .good: WovenPalette.success
        case .warning: WovenPalette.warning
        }
    }
}

/// A status dot and its word: the one readiness treatment in Settings.
struct SettingsStatusLabel: View {
    let text: String
    var tone: SettingsTone = .neutral

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(tone.color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(.subheadline).foregroundStyle(WovenPalette.mutedForeground)
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
    }
}

/// A row that opens another page: an optional icon, the title, its current
/// value with an optional status dot, and a chevron.
struct SettingsLinkRow: View {
    let title: String
    var glyph: LucideGlyph? = nil
    var detail: String? = nil
    var value: String? = nil
    var tone: SettingsTone? = nil
    let page: SettingsPage
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 20

    var body: some View {
        NavigationLink(value: page) {
            HStack(spacing: 12) {
                if let glyph {
                    LucideIcon(glyph: glyph, size: iconSize).frame(width: iconSize + 4).foregroundStyle(WovenPalette.foreground)
                }
                SettingsRowLayout(title: title, detail: detail) {
                    if let value {
                        if let tone {
                            SettingsStatusLabel(text: value, tone: tone)
                        } else {
                            Text(value).font(.subheadline).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1)
                        }
                    }
                }
            }
            .frame(minHeight: 44)
        }
        .settingsRow()
        .accessibilityLabel(title)
        .accessibilityValue(value ?? "")
    }
}

/// A row with a title, an optional secondary line, and a control on the right.
struct SettingsControlRow<Accessory: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var accessory: Accessory

    var body: some View {
        SettingsRowLayout(title: title, detail: detail) { accessory }
            .frame(minHeight: 44)
            .settingsRow()
    }
}

/// A title and optional secondary line, with the trailing part on the right;
/// at the accessibility text sizes the trailing part goes beneath them.
struct SettingsRowLayout<Trailing: View>: View {
    let title: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let label = VStack(alignment: .leading, spacing: 2) {
            Text(title).foregroundStyle(WovenPalette.foreground)
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(WovenPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                label
                trailing
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        } else {
            HStack(spacing: 12) {
                label.layoutPriority(1)
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

/// A full-width action in its own row: quiet, or destructive in the danger colour.
struct SettingsActionRow: View {
    let title: String
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(destructive ? WovenPalette.danger : WovenPalette.primary)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .settingsRow()
    }
}

/// One quiet line under a section's rows: progress, a note, or an error.
struct SettingsCaption: View {
    let text: String
    var isError = false

    init(_ text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(isError ? WovenPalette.danger : WovenPalette.mutedForeground)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
    }
}

/// A section heading with at most one sentence under it.
struct SettingsHeader: View {
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline).foregroundStyle(WovenPalette.foreground)
            if let detail {
                Text(detail).font(.subheadline).foregroundStyle(WovenPalette.mutedForeground)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textCase(nil)
        .padding(.leading, -16)
        .padding(.bottom, 2)
    }
}

private struct SettingsRowModifier: ViewModifier {
    @Environment(\.wovenTheme) private var theme

    func body(content: Content) -> some View {
        content.listRowBackground(theme.palette.themeWhisper)
    }
}

private struct SettingsFieldRowModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
    }
}

extension View {
    /// A Settings row on the theme's whisper surface.
    func settingsRow() -> some View { modifier(SettingsRowModifier()) }
    /// A text field's row: the field brings its own surface.
    func settingsFieldRow() -> some View { modifier(SettingsFieldRowModifier()) }

    /// A Settings page: a list on the workspace colour with an inline title.
    func settingsPage(_ title: String) -> some View {
        listSectionSpacing(.compact)
            .mobilePageSurface()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// Copies text and says so for a moment.
struct CopyButton: View {
    let title: String
    let value: String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : title) {
            UIPasteboard.general.string = value
            copied = true
        }
        .buttonStyle(WovenQuietButtonStyle())
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

/// A page's one primary action, full width under its fields.
struct SettingsPrimaryButton: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).frame(maxWidth: .infinity)
        }
        .buttonStyle(WovenPrimaryButtonStyle())
        .settingsFieldRow()
    }
}
