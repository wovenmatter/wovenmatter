import AppKit
import SwiftUI
import WovenMatterClient
import WovenMatterCore

struct SettingsGeneralView: View {
    @Bindable var model: ApplicationModel
    var reservesRailControlSpace = false
    var onBack: () -> Void
    var onOpenCodex: () -> Void = {}
    var onOpenUpdates: () -> Void = {}
    @State private var updates = FleetUpdatesModel.shared

    @AppStorage(WovenTheme.storageKey) private var storedTheme = WovenTheme.green.rawValue
    @AppStorage(SidebarStyle.storageKey) private var storedSidebarStyle = SidebarStyle.defaultStyle.rawValue
    @AppStorage(PiDurableLogoStyle.storageKey) private var storedPiDurableLogoStyle =
        PiDurableLogoStyle.defaultStyle.rawValue
    @AppStorage(CodexLogoStyle.storageKey) private var storedCodexLogoStyle =
        CodexLogoStyle.defaultStyle.rawValue
    @AppStorage(WorkspaceSidebarVisibility.localWorkspace.storageKey) private var showsLocalWorkspace = true
    @AppStorage(WorkspaceSidebarVisibility.remoteWorkspaces.storageKey) private var showsRemoteWorkspaces = true

    private var themeBinding: Binding<WovenTheme> {
        Binding(
            get: { WovenTheme(rawValue: storedTheme) ?? .green },
            set: { storedTheme = $0.rawValue }
        )
    }

    private var sidebarStyleBinding: Binding<SidebarStyle> {
        Binding(
            get: {
                SidebarStyle(rawValue: storedSidebarStyle)
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
            versionSection
            appearanceSection
            SettingsConversationTitlesSection(model: model, onOpenCodex: onOpenCodex)
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
                WovenSegmentedSelector(options: WovenTheme.allCases, selection: themeBinding) { $0.title }
                    .frame(width: 300)
            }
            SettingsRow(title: "Sidebar layout", detail: sidebarStyleBinding.wrappedValue.detail) {
                WovenSegmentedSelector(options: SidebarStyle.allCases, selection: sidebarStyleBinding) { style in
                    style.title.replacingOccurrences(of: " Sidebar", with: "")
                }
                .frame(width: 300)
            }
            SettingsSummaryRow("Sidebar sections", detail: "Hide or show the workspace sections in the sidebar.") {
                Toggle(WorkspaceSidebarVisibility.localWorkspace.title, isOn: $showsLocalWorkspace)
                Toggle(WorkspaceSidebarVisibility.remoteWorkspaces.title, isOn: $showsRemoteWorkspaces)
                SettingsNote("Hides or shows these sidebar sections. Workspaces and chats stay active.")
            }
            SettingsSummaryRow("Agent icons", detail: "Choose how the Pi Durable and Codex icons look throughout the app.") {
                SettingsRow(title: "Pi Durable") {
                    SettingsPicker("Pi Durable icon", selection: Binding(
                        get: { piDurableLogoStyle }, set: { storedPiDurableLogoStyle = $0.rawValue }
                    ), options: PiDurableLogoStyle.allCases) { $0.displayName }
                }
                SettingsRow(title: "Codex") {
                    SettingsPicker("Codex icon", selection: Binding(
                        get: { codexLogoStyle }, set: { storedCodexLogoStyle = $0.rawValue }
                    ), options: CodexLogoStyle.allCases) { $0.displayName }
                }
            }
        }
    }

    private var piDurableLogoStyle: PiDurableLogoStyle {
        PiDurableLogoStyle(rawValue: storedPiDurableLogoStyle) ?? .defaultStyle
    }

    private var codexLogoStyle: CodexLogoStyle {
        CodexLogoStyle(rawValue: storedCodexLogoStyle) ?? .defaultStyle
    }

    /// The first row: the version of Woven Matter on this Mac, a check for a newer release, and
    /// the Updates page (every device and harness).
    private var versionSection: some View {
        SettingsSection {
            SettingsRow(title: versionTitle, detail: versionDetail) {
                if updates.checking { ProgressView().controlSize(.small) }
                Button(updates.checking ? "Checking…" : "Check for updates") { Task { await updates.checkAll() } }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(updates.checking || updates.running)
                Button("Updates", action: onOpenUpdates)
                    .buttonStyle(SettingsQuietButtonStyle())
            }
        }
        .task { updates.loadIfNeeded() }
    }

    private var versionTitle: String {
        updates.isDevelopmentBuild ? "Woven Matter development build" : "Woven Matter \(updates.thisMacVersion ?? "")"
    }

    private var versionDetail: String? {
        if updates.running { return "Updating…" }
        if updates.isDevelopmentBuild { return "Built from source, so it doesn't update itself." }
        if updates.thisMacIsBehind, let latest = updates.release?.version { return "Woven Matter \(latest) is available." }
        if updates.checkedAt != nil {
            let others = updates.availableCount
            return others == 0 ? "Up to date." : "Up to date. Other updates are waiting in Updates."
        }
        return nil
    }
}

/// Conversation titles use the Codex account on this Mac, so the section shows that
/// account and links to the Codex page, where it signs in.
private struct SettingsConversationTitlesSection: View {
    @Bindable var model: ApplicationModel
    let onOpenCodex: () -> Void

    private var settings: ConversationTitleGenerationSettings { model.titleGenerationSettings }
    private var codex: AgentSignInStatus? { model.harnessSignIn.statuses[.codex] }
    private var signedIn: Bool { ["verified", "credentials_present"].contains(codex?.state ?? "") }

    private var accountValue: String {
        if signedIn { return codex?.accounts?.first?.name ?? "Signed in" }
        if codex == nil || model.harnessSignIn.checking.contains(.codex) { return "Checking…" }
        return codex?.state == "not_installed" ? "Codex isn't installed" : "Not signed in"
    }

    var body: some View {
        SettingsSection(title: "Conversation titles", detail: "Names new chats from their first message using your Codex account on this Mac.") {
            SettingsToggleRow(
                title: "Generate titles",
                detail: settings.isEnabled ? model.titleGenerationStatus : nil,
                isOn: Binding(get: { settings.isEnabled }, set: { model.setTitleGenerationEnabled($0) })
            )
            SettingsSummaryLink(title: "Codex account", value: accountValue,
                                tone: codex == nil ? nil : signedIn ? .good : .warning, action: onOpenCodex)
            if settings.isEnabled {
                if signedIn {
                    SettingsRow(title: "Model") {
                        SettingsPicker(
                            "Title model",
                            selection: Binding(get: { settings.model }, set: { model.setTitleGenerationModel($0) }),
                            options: options(model.titleGenerationCapabilities?.models, selected: settings.model)
                        ) { $0 }
                    }
                    SettingsRow(title: "Thinking level") {
                        SettingsPicker(
                            "Title thinking level",
                            selection: Binding(get: { settings.thinking }, set: { model.setTitleGenerationThinking($0) }),
                            options: options(model.titleGenerationCapabilities?.thinkingLevels, selected: settings.thinking)
                        ) { $0.capitalized }
                    }
                    Button(model.isRefreshingTitleGenerationCapabilities ? "Checking…" : "Refresh options") {
                        model.refreshTitleGenerationCapabilitiesNow()
                    }
                    .buttonStyle(SettingsQuietButtonStyle())
                    .disabled(model.isRefreshingTitleGenerationCapabilities)
                } else {
                    SettingsNote("Sign in to Codex to choose a model and thinking level.")
                }
            }
        }
        .task { await model.refreshHarnessSignIn(.codex) }
    }

    private func options(_ available: [String]?, selected: String) -> [String] {
        let available = available ?? []
        return available.contains(selected) ? available : [selected] + available
    }
}
