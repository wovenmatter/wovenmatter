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
    @State private var showsCredentialDisclosure = false

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
        .task { await model.checkSavedCredentialAccess() }
        .onReceive(NotificationCenter.default.publisher(for: KeychainAccess.accessNeedsAttention).receive(on: DispatchQueue.main)) { _ in
            model.keychainAccessNeedsAttention()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            if !model.isReconnectingSavedCredentials { Task { await model.checkSavedCredentialAccess() } }
        }
        .onChange(of: storedTheme) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .onChange(of: storedSidebarStyle) { _, _ in
            model.persistMacSurfaceProfileFromUserDefaults()
        }
        .sheet(isPresented: $showsCredentialDisclosure) {
            CredentialAccessDisclosureView(
                purpose: "Use saved credentials across the Woven Matter features you enable, including website sessions and passwords.",
                onEnable: {
                    showsCredentialDisclosure = false
                    Task { await model.reconnectSavedCredentials() }
                },
                onCancel: { showsCredentialDisclosure = false }
            )
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
            credentialAccessRow
        }
    }

    private var credentialAccessRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            SettingsRow(title: "Keychain access", detail: "Credentials are stored in Apple Keychain.") {
                SettingsStatus(model.isReconnectingSavedCredentials ? "Checking…"
                    : model.keychainAccessReady == true ? "Access ready"
                    : model.keychainAccessReady == false ? "Access needs attention"
                    : model.hasAcknowledgedCredentialAccessDisclosure ? "Checking…" : "Not enabled",
                    tone: model.keychainAccessReady == false ? .warning : model.keychainAccessReady == true ? .good : .neutral)
                    .help(model.credentialAccessStatus ?? "Enable access to use saved credentials.")
                Button(model.isReconnectingSavedCredentials ? "Checking…"
                       : model.keychainAccessReady == true ? "Check access"
                       : model.hasAcknowledgedCredentialAccessDisclosure || model.keychainAccessReady == false
                         ? "Restore Keychain access" : "Enable Keychain access") {
                    if model.keychainAccessReady == true {
                        Task { await model.checkSavedCredentialAccess() }
                    } else if model.hasAcknowledgedCredentialAccessDisclosure {
                        Task { await model.reconnectSavedCredentials() }
                    } else {
                        showsCredentialDisclosure = true
                    }
                }
                .buttonStyle(SettingsQuietButtonStyle())
                .disabled(model.isAuthorizingUsageCredential || model.isReconnectingSavedCredentials)
            }
            if model.keychainAccessReady != true {
                SettingsNote("Choose Always Allow when macOS asks to avoid repeated prompts.")
            }
        }
    }

    private var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? "0.0.0"
    }
}
