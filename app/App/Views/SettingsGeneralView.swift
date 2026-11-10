import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsGeneralView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void

    @AppStorage(DashboardTheme.storageKey) private var storedTheme = DashboardTheme.green.rawValue
    @AppStorage(DashboardSidebarStyle.storageKey) private var storedSidebarStyle = DashboardSidebarStyle.defaultStyle.rawValue
    @AppStorage(DashboardPiDurableLogoStyle.storageKey) private var storedPiDurableLogoStyle =
        DashboardPiDurableLogoStyle.defaultStyle.rawValue
    @AppStorage(DashboardCodexLogoStyle.storageKey) private var storedCodexLogoStyle =
        DashboardCodexLogoStyle.defaultStyle.rawValue
    @AppStorage(DashboardWorkspaceSidebarVisibility.localWorkspace.storageKey) private var showsLocalWorkspace = true
    @AppStorage(DashboardWorkspaceSidebarVisibility.remoteWorkspaces.storageKey) private var showsRemoteWorkspaces = true

    private var themeBinding: Binding<DashboardTheme> {
        Binding(
            get: { DashboardTheme(rawValue: storedTheme) ?? .green },
            set: { storedTheme = $0.rawValue }
        )
    }

    private var sidebarStyleBinding: Binding<DashboardSidebarStyle> {
        Binding(
            get: {
                DashboardSidebarStyle(rawValue: storedSidebarStyle)
                    ?? .defaultStyle
            },
            set: { storedSidebarStyle = $0.rawValue }
        )
    }

    var body: some View {
        SettingsPage(
            title: "General",
            reservesRailControlSpace: reservesRailControlSpace,
            onBack: onBack
        ) {
            appearanceSection
            softwareSection
            ProductAnalyticsSettingsSection(analytics: model.analytics)
        }
        .onChange(of: storedTheme) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .onChange(of: storedSidebarStyle) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
    }

    private var appearanceSection: some View {
        SettingsSection(title: "Appearance") {
            SettingsRow(title: "Theme") {
                DashboardSegmentedSelector(options: DashboardTheme.allCases, selection: themeBinding) { $0.title }
                    .frame(maxWidth: 300)
            }
            SettingsRow(title: "Sidebar layout", detail: sidebarStyleBinding.wrappedValue.detail) {
                DashboardSegmentedSelector(options: DashboardSidebarStyle.allCases, selection: sidebarStyleBinding) { style in
                    style.title.replacingOccurrences(of: " Sidebar", with: "")
                }
                .frame(maxWidth: 300)
            }
            SettingsSummaryRow("Sidebar sections", value: sidebarSectionsSummary) {
                Toggle(DashboardWorkspaceSidebarVisibility.localWorkspace.title, isOn: $showsLocalWorkspace)
                Toggle(DashboardWorkspaceSidebarVisibility.remoteWorkspaces.title, isOn: $showsRemoteWorkspaces)
                SettingsNote("Hides or shows these sidebar sections. Workspaces and chats stay active.")
            }
            SettingsSummaryRow("Agent icons", value: "\(piDurableLogoStyle.displayName), \(codexLogoStyle.displayName)") {
                SettingsRow(title: "Pi Durable") {
                    SettingsPicker("Pi Durable icon", selection: Binding(
                        get: { piDurableLogoStyle }, set: { storedPiDurableLogoStyle = $0.rawValue }
                    ), options: DashboardPiDurableLogoStyle.allCases) { $0.displayName }
                }
                SettingsRow(title: "Codex") {
                    SettingsPicker("Codex icon", selection: Binding(
                        get: { codexLogoStyle }, set: { storedCodexLogoStyle = $0.rawValue }
                    ), options: DashboardCodexLogoStyle.allCases) { $0.displayName }
                }
            }
        }
    }

    private var sidebarSectionsSummary: String {
        switch (showsLocalWorkspace, showsRemoteWorkspaces) {
        case (true, true): "Local and remote workspaces"
        case (true, false): "Local workspace"
        case (false, true): "Remote workspaces"
        case (false, false): "Hidden"
        }
    }

    private var piDurableLogoStyle: DashboardPiDurableLogoStyle {
        DashboardPiDurableLogoStyle(rawValue: storedPiDurableLogoStyle) ?? .defaultStyle
    }

    private var codexLogoStyle: DashboardCodexLogoStyle {
        DashboardCodexLogoStyle(rawValue: storedCodexLogoStyle) ?? .defaultStyle
    }

    private var softwareSection: some View {
        let updater = DesktopUpdater.shared
        return SettingsSection(title: "Software") {
            SettingsRow(title: "Woven Matter v\(currentVersion)", detail: updater.errorMessage) {
                Button("Check for updates") { updater.checkForUpdates() }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }
}
