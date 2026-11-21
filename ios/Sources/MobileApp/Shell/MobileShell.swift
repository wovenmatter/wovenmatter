import SwiftUI
import UIKit

/// The app's frame: the four tabs, each with its own navigation stack and
/// state, switched by the bottom bar on iPhone and a leading rail on iPad.
/// Settings opens over them.
struct MobileShell: View {
    @Bindable var model: MobileModel
    @Environment(\.wovenTheme) private var theme
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var keyboardVisible = false

    var body: some View {
        HStack(spacing: 0) {
            if sizeClass == .regular {
                MobileRail(model: model)
            }
            VStack(spacing: 0) {
                tabs
                if sizeClass != .regular && !keyboardVisible {
                    MobileTabBar(selection: model.tab, fadesAbove: !model.showsComposerOnBar, select: model.select)
                }
            }
        }
        .background(theme.palette.workspace.ignoresSafeArea())
        .background(MobileKeyboardDismissal())
        .overlay(alignment: .top) { MobileDictationFeedback() }
        .environment(\.presentSettings, { model.openSettings() })
        .environment(\.workspaceApplicationModel, model.app)
        .environment(\.openWorkspaceConversation, { model.open(sessionID: $0) })
        .sheet(isPresented: $model.settingsPresented) {
            SettingsRoot(model: model)
                .environment(\.wovenTheme, theme)
                .preferredColorScheme(theme.colorScheme)
                .tint(theme.palette.themeAccent)
        }
        // Dictation inserts into the composer it started in, so it ends when that page leaves.
        .onChange(of: model.tab) { _, _ in MobileDictation.shared.stop() }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardVisible = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardVisible = false
        }
    }

    /// Every tab stays alive, so each keeps its stack, scroll position and
    /// drafts while another is showing.
    private var tabs: some View {
        ZStack {
            ForEach(MobileModel.Tab.allCases) { tab in
                let selected = model.tab == tab
                NavigationStack(path: path(tab)) {
                    root(tab)
                        .toolbar(.hidden, for: .navigationBar)
                        .mobilePageSurface()
                }
                .opacity(selected ? 1 : 0)
                .allowsHitTesting(selected)
                .accessibilityHidden(!selected)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func path(_ tab: MobileModel.Tab) -> Binding<NavigationPath> {
        Binding(get: { model.paths[tab] ?? NavigationPath() }, set: { model.paths[tab] = $0 })
    }

    @ViewBuilder
    private func root(_ tab: MobileModel.Tab) -> some View {
        switch tab {
        case .chat: ChatTab(model: model)
        case .bots: BotsTab(model: model)
        case .folders: FoldersTab(model: model)
        case .artifacts: ArtifactsTab(model: model)
        }
    }
}

extension EnvironmentValues {
    /// Opens Settings over the tabs.
    @Entry var presentSettings: @MainActor () -> Void = {}
}

/// The iPad's leading rail: the same four destinations, Settings at the bottom.
private struct MobileRail: View {
    @Bindable var model: MobileModel
    @Environment(\.wovenTheme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Woven Matter")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.top, 20)
                .padding(.bottom, 16)
            ForEach(MobileModel.Tab.allCases) { tab in
                MobileRailRow(glyph: tab.glyph, title: tab.title, selected: model.tab == tab) { model.select(tab) }
                    .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
            Spacer(minLength: 0)
            MobileRailRow(glyph: .settings, title: "Settings", selected: false) { model.openSettings() }
                .accessibilityIdentifier("open-settings")
                .padding(.bottom, 12)
        }
        .padding(.horizontal, 12)
        .frame(width: WovenMetrics.railWidth)
        .background((theme == .dark ? theme.palette.railFill : theme.palette.themeWhisper).ignoresSafeArea())
    }
}

private struct MobileRailRow: View {
    @Environment(\.wovenTheme) private var theme
    let glyph: LucideGlyph
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                LucideIcon(glyph: glyph, size: 20).frame(width: 24)
                Text(title).font(.body.weight(selected ? .semibold : .regular))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(selected ? theme.palette.themeSoft : .clear,
                        in: RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: WovenMetrics.controlRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverEffect(.highlight)
        .foregroundStyle(selected ? WovenPalette.foreground : WovenPalette.mutedForeground)
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
