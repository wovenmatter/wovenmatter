import SwiftUI

/// The iPhone's bottom bar: icon-only tabs spread evenly on the page itself,
/// with no plate or divider. The selected icon sits full-strength on a
/// capsule; the others are quieter. Content scrolls beneath it into a soft
/// fade. It hides while the keyboard is up.
struct MobileTabBar: View {
    let selection: MobileModel.Tab
    /// Whether content above fades into the bar. A tab whose own bottom stack
    /// sits on the bar (the Chat tab's composer) brings its own fade.
    var fadesAbove = true
    let select: (MobileModel.Tab) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MobileModel.Tab.allCases) { tab in
                MobileTabButton(tab: tab, selected: tab == selection, highlight: highlight) {
                    if reduceMotion { select(tab) } else { withAnimation(.snappy(duration: 0.22)) { select(tab) } }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background { MobileBottomFade(fades: fadesAbove) }
    }
}

private struct MobileTabButton: View {
    @Environment(\.wovenTheme) private var theme
    let tab: MobileModel.Tab
    let selected: Bool
    let highlight: Namespace.ID
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LucideIcon(glyph: tab.glyph, size: 22)
                .foregroundStyle(selected ? WovenPalette.foreground : WovenPalette.mutedForeground)
                .frame(width: 68, height: 44)
                .background {
                    if selected {
                        Capsule(style: .continuous)
                            .fill(theme.palette.themeSoft)
                            .matchedGeometryEffect(id: "selected-tab", in: highlight)
                    }
                }
                .contentShape(.hoverEffect, Capsule(style: .continuous))
                .hoverEffect(.highlight)
                .frame(maxWidth: .infinity, minHeight: 48)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("tab-\(tab.rawValue)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What sits behind the composer and the bar: the page colour, fading in over
/// the content above so it never ends at a hard edge. Solid under Reduce
/// Transparency.
struct MobileBottomFade: View {
    var fades = true
    @Environment(\.wovenTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let page = theme.palette.workspace
        let fades = fades && !reduceTransparency
        VStack(spacing: 0) {
            if fades {
                LinearGradient(colors: [page.opacity(0), page.opacity(0.85), page], startPoint: .top, endPoint: .bottom)
                    .frame(height: 28)
            }
            page
        }
        .padding(.top, fades ? -28 : 0)
        .ignoresSafeArea(edges: .bottom)
        .allowsHitTesting(false)
    }
}
