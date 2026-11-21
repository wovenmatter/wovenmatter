import SwiftUI

/// The header every tab's root page starts with: Settings at the leading
/// edge, the title (with an optional line beneath it, and an optional action
/// on tapping it), and one action at the trailing edge.
struct TabRootHeader<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var onTitleTap: (() -> Void)? = nil
    /// What tapping the title shows, for VoiceOver.
    var titleHint = "Shows new chats and recent chats"
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.presentSettings) private var presentSettings
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        HStack(spacing: 8) {
            // On iPad, Settings sits at the bottom of the rail instead.
            if sizeClass != .regular {
                Button(action: presentSettings) {
                    LucideIcon(glyph: .settings, size: 20).frame(width: 44, height: 44)
                }
                .buttonStyle(WovenIconButtonStyle())
                .hoverEffect(.highlight)
                .accessibilityLabel("Settings")
                .accessibilityIdentifier("open-settings")
            }
            titleBlock
            Spacer(minLength: 0)
            trailing()
                .buttonStyle(WovenIconButtonStyle())
                .hoverEffect(.highlight)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }

    @ViewBuilder private var titleBlock: some View {
        let label = VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) {
                Text(title).font(.headline).lineLimit(1)
                if onTitleTap != nil {
                    LucideIcon(glyph: .chevronDown, size: 12).foregroundStyle(WovenPalette.mutedForeground)
                }
            }
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(WovenPalette.mutedForeground).lineLimit(1)
            }
        }
        .frame(minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        if let onTitleTap {
            Button(action: onTitleTap) { label }
                .buttonStyle(.plain)
                .accessibilityIdentifier("tab-title")
                .accessibilityHint(titleHint)
        } else {
            label.accessibilityAddTraits(.isHeader).accessibilityIdentifier("tab-title")
        }
    }
}

extension TabRootHeader where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle, onTitleTap: nil) { EmptyView() }
    }
}

/// A harness's logo, or a generic chip for a runtime without one.
struct AgentIcon: View {
    let runtime: AgentRuntimeKind?
    var size: CGFloat = 22

    var body: some View {
        if let runtime {
            HarnessLogoIcon(logo: HarnessLogo(runtimeKind: runtime), size: size)
        } else {
            LucideIcon(glyph: .cpu, size: size)
        }
    }
}

// Asset-backed labels, so native menus draw the same Lucide glyphs as rows.
extension Label where Title == Text, Icon == Image {
    init(_ title: String, glyph: LucideGlyph) {
        self.init { Text(title) } icon: { Image(glyph.rawValue) }
    }
}

private struct MobilePageSurface: ViewModifier {
    @Environment(\.wovenTheme) private var theme

    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(theme.palette.workspace.ignoresSafeArea())
    }
}

extension View {
    /// A sheet over the tabs, in the app's theme: sheets do not inherit it.
    func sheetTheme(_ theme: WovenTheme) -> some View {
        environment(\.wovenTheme, theme)
            .preferredColorScheme(theme.colorScheme)
            .tint(theme.palette.themeAccent)
    }

    /// A page on the theme's workspace colour.
    func mobilePageSurface() -> some View { modifier(MobilePageSurface()) }
}
